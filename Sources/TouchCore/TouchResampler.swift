// TouchResampler.swift
// Выравнивает кадры касаний по обновлению экрана (как touch resampling в Android/iOS).
//
// Панель шлёт отчёты ~100 Гц с неровным шагом 8–14 мс, а до программы они доходят ещё
// и пачками (два отчёта за 1–4 мс после паузы до 40 мс). Если передавать их в систему как есть,
// на один кадр экрана приходится то два события, то ни одного — движение дёргается.
// Здесь на каждый кадр экрана выдаётся ровно один кадр касаний: позиции интерполируются
// по аппаратным меткам времени на момент «кадр экрана − latency» отдельно для каждого пальца,
// при опоздании отчёта — немного экстраполируются.
//
// Смена набора пальцев (касание, отпускание, палец пропал или вернулся) передаётся сразу,
// без ожидания кадра экрана.
//
// Использование:
//   let resampler = TouchResampler()
//   reader.onFrame = { resampler.process($0) }
//   resampler.onFrame = { mouse.process($0); gestures.process($0) }

import AppKit

public final class TouchResampler {
    /// Кадры, выровненные по обновлению экрана.
    public var onFrame: (([TouchPoint]) -> Void)?

    /// Насколько момент выборки отстаёт от кадра экрана. Чуть больше периода отчётов (8–14 мс):
    /// почти всегда есть отчёты по обе стороны, и позиция интерполируется, а не угадывается.
    /// Подобрано по записи прокрутки на ILITEK: 12 мс — меньше всего рывков (8 мс — больше
    /// экстраполяции, 16 мс — хуже редкие рывки).
    public var latency: TimeInterval = 0.012
    /// Максимум экстраполяции, если очередной отчёт запаздывает.
    public var maxExtrapolation: TimeInterval = 0.008
    /// Если отчётов нет дольше — палец считается неподвижным (панель при слабом касании
    /// замолкает до 160 мс), экстраполяция не делается.
    public var staleInterval: TimeInterval = 0.03
    /// Минимальный интервал между двумя отчётами для оценки скорости: отчёты, пришедшие пачкой
    /// (1–2 мс), дают бессмысленную скорость, и экстраполяция по ним улетает.
    public var minVelocityInterval: TimeInterval = 0.004

    /// Последние отчёты по каждому пальцу. История ведётся отдельно для каждого: панель при прокрутке
    /// теряет один палец по нескольку раз в секунду, и общий сброс истории давал на каждой потере
    /// кадр вне ритма экрана и остановку на 10–20 мс, пока не накопятся новые отчёты (подлагивание).
    private var tracks: [Int: [TouchPoint]] = [:]
    private var ids: [Int] = []   // пальцы последнего отчёта
    private var lastEmitted: [TouchPoint] = []
    private var link: CADisplayLink?
    private weak var linkScreen: NSScreen?

    public init() {}

    public func process(_ frame: [TouchPoint]) {
        let newIDs = frame.map(\.id)
        if frame.isEmpty, !ids.isEmpty {
            // Отпускание: сначала точная последняя позиция пальцев, затем пустой кадр — сразу.
            let last = ids.compactMap { tracks[$0]?.last }
            if !same(last, lastEmitted) { emit(last) }
        }
        for p in frame {
            tracks[p.id, default: []].append(p)
            if tracks[p.id]!.count > 4 { tracks[p.id]!.removeFirst() }
        }
        tracks = tracks.filter { newIDs.contains($0.key) }   // пропавшие пальцы забываем

        guard newIDs != ids else { return }
        // Сменился набор пальцев (касание, отпускание, палец пропал или вернулся) — кадр сразу, без ожидания
        // кадра экрана. Оставшиеся пальцы — в выровненной позиции, как в соседних кадрах, новые — как есть.
        ids = newIDs
        emit(frame.isEmpty ? [] : sample(at: CACurrentMediaTime() - latency))
        setActive(frame.first?.location)
    }

    // MARK: - Кадр экрана

    @objc private func tick(_ link: CADisplayLink) {
        guard !ids.isEmpty else { return }
        let frame = sample(at: link.timestamp - latency)
        guard !same(frame, lastEmitted) else { return }   // палец неподвижен — не шлём повторы
        emit(frame)
    }

    private func sample(at t: TimeInterval) -> [TouchPoint] {
        ids.compactMap { id in tracks[id].map { sample($0, at: t) } }
    }

    private func sample(_ track: [TouchPoint], at t: TimeInterval) -> TouchPoint {
        let last = track[track.count - 1]
        guard track.count >= 2 else { return last }

        // Пара отчётов вокруг t: интерполяция.
        for i in stride(from: track.count - 1, to: 0, by: -1) {
            let a = track[i - 1], b = track[i]
            guard b.timestamp > a.timestamp else { continue }
            if t >= a.timestamp && t <= b.timestamp {
                return blend(a, b, (t - a.timestamp) / (b.timestamp - a.timestamp), at: t)
            }
        }
        if t < track[0].timestamp { return track[0] }

        // t позже последнего отчёта: немного экстраполируем по двум последним, если они свежие.
        let prev = track[track.count - 2]
        let gap = last.timestamp - prev.timestamp
        guard gap >= minVelocityInterval, gap < staleInterval, t - last.timestamp < staleInterval else { return last }
        let ahead = min(t - last.timestamp, maxExtrapolation)
        return blend(prev, last, 1 + ahead / gap, at: last.timestamp + ahead)
    }

    private func blend(_ p: TouchPoint, _ q: TouchPoint, _ k: Double, at t: TimeInterval) -> TouchPoint {
        TouchPoint(id: q.id, location: CGPoint(x: p.location.x + (q.location.x - p.location.x) * k,
                                               y: p.location.y + (q.location.y - p.location.y) * k),
                   timestamp: t)
    }

    private func emit(_ frame: [TouchPoint]) {
        lastEmitted = frame
        onFrame?(frame)
    }

    private func same(_ a: [TouchPoint], _ b: [TouchPoint]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.id == $1.id && $0.location == $1.location }
    }

    // MARK: - Display link

    /// Display link работает только пока на экране есть пальцы — и с частотой того экрана,
    /// которого касаются (у мониторов она разная: 60, 144 Гц).
    private func setActive(_ touch: CGPoint?) {
        if let touch {
            let screen = NSScreen.screens.first { NSMouseInRect(touch, $0.frame, false) } ?? NSScreen.main
            if link == nil || linkScreen !== screen {
                link?.invalidate()
                link = screen?.displayLink(target: self, selector: #selector(tick(_:)))
                link?.add(to: .main, forMode: .common)
                linkScreen = screen
            }
            link?.isPaused = false
        } else {
            link?.isPaused = true
        }
    }
}
