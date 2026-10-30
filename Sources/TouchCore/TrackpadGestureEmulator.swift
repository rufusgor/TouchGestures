// TrackpadGestureEmulator.swift
// Жесты тачпада во всей системе по кадрам из HIDTouchReader:
//   - 2 пальца, сдвиг      — плавная прокрутка с фазами и инерцией (контент следует за пальцами);
//   - 2 пальца, pinch      — magnify (масштаб в Safari, Preview, Maps…);
//   - 2 пальца, поворот    — rotate;
//   - 2 пальца, тап        — правый клик;
//   - 3+ пальца, свайп     — вверх: Mission Control, вниз: окна приложения,
//                            влево/вправо: соседний рабочий стол.
// Прокрутка и магнификация отправляются как события тачпада (CGEvent в HID-поток),
// поэтому приложения получают обычные scrollWheel / magnify / rotate.
// Свайпы тремя пальцами — системные сочетания ⌃↑ ⌃↓ ⌃← ⌃→ (Настройки → Клавиатура → Сочетания
// клавиш → Mission Control должны быть включены — по умолчанию так и есть).
//
// В отличие от тачпада, который шлёт magnify и rotate вместе весь жест, здесь жест фиксируется
// в начале (прокрутка, масштаб или поворот): на вертикальном сенсорном экране пальцы при
// разведении почти всегда немного поворачиваются, а при повороте — расходятся, и без фиксации
// pinch и поворот путаются.
//
// События масштаба и поворота — недокументированные поля CGEvent (тип 29, поля 110/113/114/132);
// проверено на macOS 27, в будущих версиях может перестать работать.
//
// Требования: разрешение «Универсальный доступ».
//
// Использование:
//   let gestures = TrackpadGestureEmulator()
//   reader.onFrame = { mouse.process($0); gestures.process($0) }

import AppKit

public final class TrackpadGestureEmulator {
    /// Сдвиг (pt), после которого жест считается начавшимся.
    public var slop: CGFloat = 10
    /// Сдвиг пальцев (pt), по которому выбирается тип жеста: прокрутка, масштаб или поворот.
    /// Больше `slop`, чтобы выбор делался по устойчивому движению, а не по дрожанию.
    public var decisionDistance: CGFloat = 16
    /// Тап двумя пальцами (правый клик) — только если пальцы ближе этого (pt; ~4 см на 16" 1280 pt).
    /// Дальше — это два отдельных тапа, перекрывшиеся по времени.
    public var twoFingerTapMaxSpread: CGFloat = 160
    /// Максимальная длительность тапа двумя пальцами.
    public var tapDuration: TimeInterval = 0.3
    /// Сколько пальцы могут «пропадать», прежде чем жест закончится. ILITEK при прокрутке
    /// теряет палец на 35–110 мс по нескольку раз в секунду.
    public var dropoutTolerance: TimeInterval = 0.15
    /// Какую долю ещё не отданного пути (накопленного до выбора типа жеста) добавлять в каждый кадр:
    /// 0.35 — догоняет примерно за 6–8 кадров (~50 мс на 144 Гц) без скачка.
    public var catchUpFraction: CGFloat = 0.35
    /// Поперечный сдвиг (pt), после которого фиксация оси прокрутки снимается (см. Session.axis).
    public var axisUnlockDistance: CGFloat = 30
    /// Путь (pt) свайпа тремя пальцами.
    public var swipeDistance: CGFloat = 80
    /// Минимальная скорость (pt/s) в момент отпускания для инерционной прокрутки.
    public var momentumMinVelocity: CGFloat = 300
    /// Затухание скорости инерции за 1/60 с (на экранах с другой частотой пересчитывается по времени).
    public var momentumFriction: CGFloat = 0.95

    /// Отладка: описание каждого отправленного жеста.
    public var onEvent: ((String) -> Void)?
    /// Для проверки по записанным касаниям: события не отправляются в систему, только onEvent.
    public var dryRun = false

    private enum Mode { case undecided, scroll, zoom, rotate, finished }

    private struct Session {
        let fingers: Int
        let startTime: TimeInterval
        let startCentroid: CGPoint
        /// Где пальцы коснулись экрана, по порядку касания (по возрастанию ID).
        let startPoints: [CGPoint]
        /// Последние позиции пальцев по ID. Сдвиг считается только по пальцам, которые есть и в прошлом,
        /// и в текущем кадре: панель теряет палец на 35–110 мс и возвращает его иногда с новым ID,
        /// и центр по всем пальцам при этом прыгает (прокрутка дёргалась, инерция уходила не туда).
        var last: [Int: CGPoint]
        /// Центр пальцев, накопленный по таким сдвигам, — без скачков.
        var center: CGPoint
        /// Расстояние и угол между двумя пальцами в прошлом кадре — если это были те же два пальца.
        var pair: (ids: [Int], span: CGFloat, angle: CGFloat)?
        /// Накопленные с начала разведение и поворот (путь одного пальца, pt) — для выбора типа жеста.
        var pinchPath: CGFloat = 0
        var arcPath: CGFloat = 0
        /// Разведение и поворот на момент выбора типа жеста — чтобы считать движение после него.
        var pinchAtDecision: CGFloat = 0
        var arcAtDecision: CGFloat = 0
        /// Накопленные масштаб и поворот (рад) — отправляются целиком, когда тип жеста выбран.
        var scale: CGFloat = 1
        var rotation: CGFloat = 0
        /// Путь, накопленный до выбора типа жеста, — отдаётся не разом, а догоняется за несколько кадров
        /// (catchUpFraction): разом это был скачок масштаба на 15–40% в начале каждого pinch.
        var pendingScroll = CGVector.zero
        var pendingZoom: CGFloat = 0       // логарифм масштаба
        var pendingRotation: CGFloat = 0   // радианы
        var mode = Mode.undecided
        /// Жест начался во время инерции или сразу после другого жеста: тап двумя пальцами здесь
        /// не правый клик. При быстрых повторных взмахах панель на ~50 мс теряет все пальцы, и обрывки
        /// взмахов выглядели как тапы; на тачпаде такое касание тоже только останавливает прокрутку.
        var afterGesture = false
        /// Тип жеста уже исправлялся (прокрутка → масштаб/поворот, масштаб → поворот) — второй раз не меняем.
        var corrected = false
        /// Пока тип не выбран, пропадал палец: следующий полный кадр — новая точка отсчёта.
        var rebaseline = false
        /// Ось прокрутки: если в начале одна ось вдвое преобладает, прокрутка идёт только по ней
        /// (пальцы на экране редко идут строго вертикально — список в Finder «плыл» вбок).
        /// Фиксация мягкая, как в iOS: снимается до конца жеста, если поперечное движение
        /// становится существенным (в браузере страницу двигают в разные стороны одним жестом).
        var axis = CGVector(dx: 1, dy: 1)
        var lockCenter: CGPoint?
        var moved = false
        var samples: [(t: TimeInterval, p: CGPoint)] = []
    }

    private var session: Session?
    private var endWork: DispatchWorkItem?
    private var momentum: CADisplayLink?
    private var momentumTime: CFTimeInterval = 0
    private var lastGestureEnd: TimeInterval = 0
    private var momentumVelocity = CGVector.zero
    private var momentumPhase: Int64 = 0
    private var scrollRemainder = CGVector.zero
    private let source = CGEventSource(stateID: .hidSystemState)

    // CGEvent: фазы скролла/жестов и недокументированные поля жестов.
    private enum Phase { static let began: Int64 = 1, changed: Int64 = 2, ended: Int64 = 4 }
    private enum Momentum { static let begin: Int64 = 1, `continue`: Int64 = 2, end: Int64 = 3 }
    private static let gestureType = CGEventType(rawValue: 29)!
    private static let gestureHIDType = CGEventField(rawValue: 110)!
    private static let gestureZoom = CGEventField(rawValue: 113)!
    private static let gestureRotation = CGEventField(rawValue: 114)!
    private static let gesturePhase = CGEventField(rawValue: 132)!
    private static let hidZoom: Int64 = 8, hidRotation: Int64 = 5

    public init() {}

    public func process(_ touches: [TouchPoint]) {
        let coasting = momentum != nil
        if !touches.isEmpty { stopMomentum() }   // касание останавливает инерцию, как на тачпаде

        guard var s = session else {
            if touches.count >= 2 {
                begin(touches)
                session?.afterGesture = coasting || ProcessInfo.processInfo.systemUptime - lastGestureEnd < 0.4
            }
            return
        }

        // Третий палец лёг сразу после первых двух — это жест тремя пальцами.
        if touches.count > s.fingers, s.mode == .undecided,
           ProcessInfo.processInfo.systemUptime - s.startTime < 0.15 {
            begin(touches)
            return
        }

        // Все пальцы подняты, а прокрутка (масштаб, поворот) уже идёт — конец сразу: инерция начинается
        // без паузы (раньше ждали dropoutTolerance, и после отпускания список 150 мс стоял). Пропадание
        // всех пальцев посреди прокрутки у ILITEK — 1 раз на ~40 прокруток. Пока тип жеста не выбран,
        // ждём как обычно: в начале быстрого взмаха панель теряет все пальцы на 30–50 мс, и обрывок
        // взмаха иначе выглядел бы тапом двумя пальцами.
        if touches.isEmpty, s.mode != .undecided {
            endWork?.cancel()
            end(immediately: true)
            return
        }
        // Пальцев меньше, чем в жесте: жест закончился или палец пропал. Ждём dropoutTolerance,
        // а прокрутка тем временем продолжается по оставшимся пальцам.
        if touches.count < s.fingers {
            scheduleEnd()
        } else {
            endWork?.cancel()
            endWork = nil
        }
        guard !touches.isEmpty else { return }
        // Пока тип жеста не выбран, кадры с пропавшим пальцем не учитываем, а после его возвращения
        // начинаем отсчёт от новых позиций: выбор — только по кадрам, где все пальцы видны подряд.
        // Сдвиг центра по одному оставшемуся пальцу — это его полное движение, как будто оба едут
        // вместе (pinch выбирался как прокрутка), а «движение» вернувшегося пальца после 50–80 мс
        // пропадания часто на деле повторное касание в другом месте (прокрутка выбиралась поворотом).
        if s.mode == .undecided, touches.count < s.fingers {
            s.rebaseline = true
            // Оставшийся палец уехал далеко (> 2 × decisionDistance), а второго нет — прокрутка:
            // при быстрой прокрутке панель бывает видит второй палец лишь эпизодически.
            if let t = touches.first(where: { s.last[$0.id] != nil }), let p = s.last[t.id] {
                let path = CGVector(dx: t.location.x - p.x, dy: t.location.y - p.y)
                if hypot(path.dx, path.dy) > slop { s.moved = true }
                if hypot(path.dx, path.dy) > 2 * decisionDistance {
                    s.center.x += path.dx
                    s.center.y += path.dy
                    s.last = Dictionary(touches.map { ($0.id, $0.location) }, uniquingKeysWith: { a, _ in a })
                    s.rebaseline = false
                    beginScroll(&s, path: CGVector(dx: s.center.x - s.startCentroid.x, dy: s.center.y - s.startCentroid.y))
                    onEvent?(String(format: "трекпад: прокрутка начало (одним пальцем, сдвиг %.0f pt)", hypot(path.dx, path.dy)))
                }
            }
            session = s
            return
        }
        if s.rebaseline {
            s.rebaseline = false
            s.last = Dictionary(touches.map { ($0.id, $0.location) }, uniquingKeysWith: { a, _ in a })
            if touches.count == 2 {
                let a = touches[0].location, b = touches[1].location
                s.pair = (touches.map(\.id), distance(a, b), atan2(b.y - a.y, b.x - a.x))
            }
            session = s
            return
        }

        var sum = CGVector.zero, common = 0
        for t in touches {
            guard let p = s.last[t.id] else { continue }
            sum.dx += t.location.x - p.x
            sum.dy += t.location.y - p.y
            common += 1
        }
        let delta = common > 0 ? CGVector(dx: sum.dx / CGFloat(common), dy: sum.dy / CGFloat(common)) : .zero
        s.last = Dictionary(touches.map { ($0.id, $0.location) }, uniquingKeysWith: { a, _ in a })
        s.center.x += delta.dx
        s.center.y += delta.dy

        // Время кадра — аппаратная метка отчёта: скорость для инерции считается точнее,
        // чем по времени доставки.
        let now = touches[0].timestamp
        s.samples = s.samples.filter { now - $0.t < 0.08 } + [(now, s.center)]

        if s.fingers >= 3 {
            swipe(&s)
        } else {
            twoFingers(&s, touches, delta)
        }
        session = s
    }

    // MARK: - Жесты

    private func begin(_ touches: [TouchPoint]) {
        let n = CGFloat(touches.count)
        let c = CGPoint(x: touches.map(\.location.x).reduce(0, +) / n, y: touches.map(\.location.y).reduce(0, +) / n)
        var s = Session(fingers: min(touches.count, 3), startTime: ProcessInfo.processInfo.systemUptime,
                        startCentroid: c, startPoints: touches.sorted { $0.id < $1.id }.map(\.location),
                        last: Dictionary(touches.map { ($0.id, $0.location) },
                                                           uniquingKeysWith: { a, _ in a }),
                        center: c)
        if touches.count == 2 {
            let a = touches[0].location, b = touches[1].location
            s.pair = (touches.map(\.id), distance(a, b), atan2(b.y - a.y, b.x - a.x))
        }
        session = s
        // События тачпада получает окно под курсором — переносим курсор под пальцы.
        postMouse(.mouseMoved, c)
    }

    private func twoFingers(_ s: inout Session, _ touches: [TouchPoint], _ delta: CGVector) {
        // Разведение и поворот — только по тем же двум пальцам, что в прошлом кадре.
        var ratio: CGFloat = 1, dAngle: CGFloat = 0
        if touches.count == 2 {
            let ids = touches.map(\.id), a = touches[0].location, b = touches[1].location
            let span = distance(a, b), angle = atan2(b.y - a.y, b.x - a.x)
            if let p = s.pair, p.ids == ids, p.span > 0 {
                ratio = span / p.span
                dAngle = angleDelta(angle, p.angle)
                // Всё — путь одного пальца: при разведении каждый палец проходит половину изменения.
                s.pinchPath += (span - p.span) / 2
                s.arcPath += dAngle * span / 2
            }
            s.pair = (ids, span, angle)
        } else {
            s.pair = nil
        }
        s.scale *= ratio
        s.rotation += dAngle

        let pan = distance(s.center, s.startCentroid)
        let pinch = abs(s.pinchPath), arc = abs(s.arcPath)
        if max(pan, pinch, arc) > slop { s.moved = true }

        // Тип жеста — по тому, какое движение пальцев больше: сдвиг центра, разведение или поворот.
        // Путь до порога (уже включает этот кадр) догоняется постепенно — см. Session.pendingZoom.
        var delta = delta
        if s.mode == .undecided {
            guard max(pan, pinch, arc) > decisionDistance else { return }
            // Почти ничья (поворот вокруг почти неподвижного пальца сдвигает центр на столько же, на сколько
            // идёт поворот) — ждём, пока один вариант не опередит остальные на 20%, но не дальше 2 × порога.
            let ranked = [pan, pinch, arc].sorted(by: >)
            if ranked[0] < 1.2 * ranked[1], ranked[0] <= 2 * decisionDistance { return }
            s.pinchAtDecision = s.pinchPath
            s.arcAtDecision = s.arcPath
            if pan >= pinch, pan >= arc {
                beginScroll(&s, path: CGVector(dx: s.center.x - s.startCentroid.x, dy: s.center.y - s.startCentroid.y))
                onEvent?(String(format: "трекпад: прокрутка начало (pinch %.0f, поворот %.0f, сдвиг %.0f pt)", pinch, arc, pan))
            } else if pinch >= arc {
                s.mode = .zoom
                postGesture(Self.hidZoom, Self.gestureZoom, 0, Phase.began, s.center)
                s.pendingZoom = log(s.scale)
                onEvent?(String(format: "трекпад: масштаб начало (pinch %.0f, поворот %.0f, сдвиг %.0f pt)", pinch, arc, pan))
            } else {
                s.mode = .rotate
                postGesture(Self.hidRotation, Self.gestureRotation, 0, Phase.began, s.center)
                s.pendingRotation = s.rotation
                onEvent?(String(format: "трекпад: поворот начало (pinch %.0f, поворот %.0f, сдвиг %.0f pt)", pinch, arc, pan))
            }
            delta = .zero
            ratio = 1
            dAngle = 0
        }

        // Исправление выбора, один раз за жест. В первые 16 pt масштаб или поворот вокруг почти неподвижного
        // пальца и прокрутка с отстающим пальцем выглядят одинаково, а дальше различаются; pinch,
        // в который потом добавили вращение, — поворот.
        if !s.corrected {
            let early = ProcessInfo.processInfo.systemUptime - s.startTime < 0.6 && pan < 80
            let pinchSince = abs(s.pinchPath - s.pinchAtDecision), arcSince = abs(s.arcPath - s.arcAtDecision)
            var target: Mode?
            if s.mode == .scroll, early, pinch > 24, pinch > 1.3 * pan, pinch >= arc { target = .zoom }
            if s.mode == .scroll, early, arc > 24, arc > 1.3 * pan, arc > pinch { target = .rotate }
            if s.mode == .zoom, arcSince > 30, arcSince > 1.5 * pinchSince { target = .rotate }
            if let target {
                switchMode(&s, to: target)
                ratio = 1      // уже в накопленном масштабе/повороте
                dAngle = 0
                onEvent?(String(format: "трекпад: исправлено на «%@» (pinch %.0f, поворот %.0f, сдвиг %.0f pt)",
                                target == .zoom ? "масштаб" : "поворот", pinch, arc, pan))
            }
        }

        if s.mode == .scroll, s.lockCenter != nil, axisLockBroken(s) {
            s.axis = CGVector(dx: 1, dy: 1)
            s.lockCenter = nil
            onEvent?("трекпад: прокрутка — фиксация оси снята")
        }

        emitChange(&s, scroll: delta, zoom: ratio, rotation: dAngle, catchUp: catchUpFraction)
    }

    /// Изменение за кадр плюс доля пути, накопленного до выбора типа жеста (catchUp = 1 — весь остаток).
    private func emitChange(_ s: inout Session, scroll: CGVector, zoom: CGFloat, rotation: CGFloat, catchUp: CGFloat) {
        func take(_ v: inout CGFloat, tiny: CGFloat) -> CGFloat {
            let part = abs(v) < tiny ? v : v * catchUp
            v -= part
            return part
        }
        switch s.mode {
        case .scroll:
            let d = CGVector(dx: scroll.dx + take(&s.pendingScroll.dx, tiny: 0.5),
                             dy: scroll.dy + take(&s.pendingScroll.dy, tiny: 0.5))
            guard d != .zero else { return }
            postScroll(CGVector(dx: d.dx * s.axis.dx, dy: d.dy * s.axis.dy), phase: Phase.changed)
        case .zoom:
            let r = zoom * exp(take(&s.pendingZoom, tiny: 0.002))
            guard r != 1 else { return }
            postGesture(Self.hidZoom, Self.gestureZoom, Double(r - 1), Phase.changed, s.center)
        case .rotate:
            let a = rotation + take(&s.pendingRotation, tiny: 0.002)
            guard a != 0 else { return }
            postGesture(Self.hidRotation, Self.gestureRotation, Double(a * 180 / .pi), Phase.changed, s.center)
        default:
            break
        }
    }

    /// Смена типа жеста посреди него: текущий завершается, новый начинается с накопленного с начала жеста.
    private func switchMode(_ s: inout Session, to mode: Mode) {
        s.corrected = true
        switch s.mode {
        case .scroll:
            s.pendingScroll = .zero
            postScroll(.zero, phase: Phase.ended)
        case .zoom:
            s.pendingZoom = 0
            postGesture(Self.hidZoom, Self.gestureZoom, 0, Phase.ended, s.center)
        default:
            break
        }
        s.mode = mode
        switch mode {
        case .zoom:
            postGesture(Self.hidZoom, Self.gestureZoom, 0, Phase.began, s.center)
            s.pendingZoom = log(s.scale)
        case .rotate:
            postGesture(Self.hidRotation, Self.gestureRotation, 0, Phase.began, s.center)
            s.pendingRotation = s.rotation
        default:
            break
        }
    }

    /// Начало прокрутки; `path` — путь, накопленный до выбора типа жеста (догоняется постепенно).
    private func beginScroll(_ s: inout Session, path: CGVector) {
        s.mode = .scroll
        scrollRemainder = .zero
        if abs(path.dy) > 2 * abs(path.dx) { s.axis = CGVector(dx: 0, dy: 1) }
        if abs(path.dx) > 2 * abs(path.dy) { s.axis = CGVector(dx: 1, dy: 0) }
        if s.axis.dx == 0 || s.axis.dy == 0 { s.lockCenter = s.center }
        postScroll(.zero, phase: Phase.began)
        s.pendingScroll = path
    }

    /// Поперечное движение стало существенным: за последние ~80 мс поперёк больше, чем вдоль
    /// (сменили направление), или с начала жеста поперёк > axisUnlockDistance и больше 40%
    /// основного пути (ведут по диагонали).
    private func axisLockBroken(_ s: Session) -> Bool {
        guard let lock = s.lockCenter else { return false }
        let vertical = s.axis.dx == 0
        func split(_ v: CGVector) -> (main: CGFloat, cross: CGFloat) {
            vertical ? (abs(v.dy), abs(v.dx)) : (abs(v.dx), abs(v.dy))
        }
        let total = split(CGVector(dx: s.center.x - lock.x, dy: s.center.y - lock.y))
        if total.cross > axisUnlockDistance, total.cross > total.main * 0.4 { return true }
        guard let first = s.samples.first, let last = s.samples.last else { return false }
        let recent = split(CGVector(dx: last.p.x - first.p.x, dy: last.p.y - first.p.y))
        return recent.cross > axisUnlockDistance * 2 / 3 && recent.cross > recent.main
    }

    private func swipe(_ s: inout Session) {
        guard s.mode == .undecided else { return }
        let dx = s.center.x - s.startCentroid.x, dy = s.center.y - s.startCentroid.y
        guard max(abs(dx), abs(dy)) > swipeDistance else { return }
        s.mode = .finished
        // Коды клавиш: ← 123, → 124, ↓ 125, ↑ 126. Как на тачпаде: свайп влево — рабочий стол справа.
        let (key, name): (CGKeyCode, String) = abs(dx) > abs(dy)
            ? (dx < 0 ? (124, "рабочий стол →") : (123, "рабочий стол ←"))
            : (dy > 0 ? (126, "Mission Control") : (125, "окна приложения"))
        postShortcut(key)
        onEvent?("трекпад: свайп тремя пальцами — \(name)")
    }

    private func scheduleEnd() {
        guard endWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.end(immediately: false) }
        endWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dropoutTolerance, execute: work)
    }

    private func end(immediately: Bool) {
        endWork = nil
        guard var s = session else { return }
        session = nil
        emitChange(&s, scroll: .zero, zoom: 1, rotation: 0, catchUp: 1)   // остаток накопленного пути

        let duration = ProcessInfo.processInfo.systemUptime - s.startTime - (immediately ? 0 : dropoutTolerance)
        if s.mode != .undecided || s.afterGesture { lastGestureEnd = ProcessInfo.processInfo.systemUptime }
        switch s.mode {
        case .undecided where s.fingers == 2 && !s.moved && !s.afterGesture && duration <= tapDuration:
            let spread = distance(s.startPoints[0], s.startPoints[1])
            if spread <= twoFingerTapMaxSpread {
                postMouse(.rightMouseDown, s.startCentroid, button: .right)
                postMouse(.rightMouseUp, s.startCentroid, button: .right)
                onEvent?(String(format: "трекпад: тап двумя пальцами — правый клик (пальцы в %.0f pt)", spread))
            } else {
                // Пальцы далеко друг от друга — это два отдельных тапа, перекрывшиеся по времени
                // (второй палец коснулся раньше, чем отпустили первый): левый клик в каждой точке.
                for p in s.startPoints {
                    postMouse(.leftMouseDown, p)
                    postMouse(.leftMouseUp, p)
                }
                onEvent?(String(format: "трекпад: два отдельных тапа (пальцы в %.0f pt) — левые клики", spread))
            }
        case .scroll:
            postScroll(.zero, phase: Phase.ended)
            onEvent?("трекпад: прокрутка конец")
            let v = velocity(s.samples)
            startMomentum(CGVector(dx: v.dx * s.axis.dx, dy: v.dy * s.axis.dy), at: s.center)
        case .zoom:
            postGesture(Self.hidZoom, Self.gestureZoom, 0, Phase.ended, s.center)
            onEvent?("трекпад: масштаб конец")
        case .rotate:
            postGesture(Self.hidRotation, Self.gestureRotation, 0, Phase.ended, s.center)
            onEvent?("трекпад: поворот конец")
        default:
            break
        }
    }

    // MARK: - Инерция

    /// Инерция идёт с частотой экрана, где был жест (144 Гц на AQ16TH), а не от таймера 60 Гц:
    /// затухание считается по реальному времени между кадрами.
    private func startMomentum(_ v: CGVector, at point: CGPoint) {
        guard hypot(v.dx, v.dy) > momentumMinVelocity else { return }
        momentumVelocity = v
        momentumPhase = Momentum.begin
        momentumTime = CACurrentMediaTime()
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        let link = screen?.displayLink(target: LinkTarget { [weak self] link in self?.momentumTick(link) },
                                       selector: #selector(LinkTarget.fire(_:)))
        link?.add(to: .main, forMode: .common)   // и во время отслеживания меню/перетаскивания
        momentum = link
    }

    private func momentumTick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = min(max(now - momentumTime, 0.001), 0.05)
        momentumTime = now
        let decay = pow(momentumFriction, CGFloat(dt * 60))
        momentumVelocity.dx *= decay
        momentumVelocity.dy *= decay
        guard hypot(momentumVelocity.dx, momentumVelocity.dy) > 20 else { stopMomentum(); return }
        postScroll(CGVector(dx: momentumVelocity.dx * dt, dy: momentumVelocity.dy * dt),
                   phase: 0, momentum: momentumPhase)
        momentumPhase = Momentum.continue
    }

    private func stopMomentum() {
        guard let link = momentum else { return }
        link.invalidate()
        momentum = nil
        postScroll(.zero, phase: 0, momentum: Momentum.end)
    }

    /// Цель для CADisplayLink (нужен NSObject); замыкание держит эмулятор слабо.
    private final class LinkTarget: NSObject {
        let handler: (CADisplayLink) -> Void
        init(_ handler: @escaping (CADisplayLink) -> Void) { self.handler = handler }
        @objc func fire(_ link: CADisplayLink) { handler(link) }
    }

    // MARK: - Геометрия

    private func distance(_ p: CGPoint, _ q: CGPoint) -> CGFloat { hypot(q.x - p.x, q.y - p.y) }

    /// Разность углов прямой через два пальца, в (-π/2, π/2]: не зависит от порядка пальцев,
    /// поэтому смена ID после пропадания пальца не даёт скачка на 180°.
    private func angleDelta(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        var d = a - b
        while d > .pi / 2 { d -= .pi }
        while d <= -.pi / 2 { d += .pi }
        return d
    }

    /// Скорость по последним 80 мс — наклон прямой методом наименьших квадратов:
    /// устойчивее к единичному неровному отчёту, чем разность первой и последней точки.
    private func velocity(_ samples: [(t: TimeInterval, p: CGPoint)]) -> CGVector {
        guard samples.count >= 3, let first = samples.first, let last = samples.last,
              last.t - first.t > 0.02 else { return .zero }
        let n = CGFloat(samples.count)
        let ts = samples.map { CGFloat($0.t - first.t) }
        let mt = ts.reduce(0, +) / n
        let mx = samples.map(\.p.x).reduce(0, +) / n, my = samples.map(\.p.y).reduce(0, +) / n
        var stt: CGFloat = 0, stx: CGFloat = 0, sty: CGFloat = 0
        for (t, s) in zip(ts, samples) {
            stt += (t - mt) * (t - mt)
            stx += (t - mt) * (s.p.x - mx)
            sty += (t - mt) * (s.p.y - my)
        }
        return stt > 0 ? CGVector(dx: stx / stt, dy: sty / stt) : .zero
    }

    // MARK: - Отправка событий

    /// `d` — сдвиг пальцев в координатах Cocoa; контент следует за пальцами.
    private func postScroll(_ d: CGVector, phase: Int64, momentum: Int64 = 0) {
        // Колесо: wheel1 > 0 — контент вниз, wheel2 > 0 — контент вправо. В Cocoa y растёт вверх.
        let x = d.dx + scrollRemainder.dx, y = -d.dy + scrollRemainder.dy
        let ix = x.rounded(), iy = y.rounded()
        scrollRemainder = CGVector(dx: x - ix, dy: y - iy)
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: Int32(iy), wheel2: Int32(ix), wheel3: 0) else { return }
        e.flags = .physicalKeyboard   // с залипшим Control прокрутка стала бы масштабом экрана
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        if dryRun {
            onEvent?(String(format: "  колесо %d %d (фаза %d, инерция %d)", Int(iy), Int(ix), phase, momentum))
        } else {
            e.post(tap: .cghidEventTap)
        }
    }

    private func postGesture(_ hidType: Int64, _ field: CGEventField, _ value: Double, _ phase: Int64,
                             _ p: CGPoint) {
        guard let e = CGEvent(source: source) else { return }
        e.type = Self.gestureType
        e.flags = .physicalKeyboard
        e.location = p.quartz
        e.setIntegerValueField(Self.gestureHIDType, value: hidType)
        e.setIntegerValueField(Self.gesturePhase, value: phase)
        e.setDoubleValueField(field, value: value)
        if dryRun {
            onEvent?(String(format: "  жест %d %.5f (фаза %d)", Int(hidType), value, Int(phase)))
        } else {
            e.post(tap: .cghidEventTap)
        }
    }

    private func postMouse(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton = .left) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                              mouseCursorPosition: p.quartz, mouseButton: button) else { return }
        e.flags = .physicalKeyboard
        if type != .mouseMoved { e.setIntegerValueField(.mouseEventClickState, value: 1) }
        if !dryRun { e.post(tap: .cghidEventTap) }
    }

    /// ⌃ + стрелка — как с настоящей клавиатуры: нажать Control, стрелку, отпустить оба.
    /// Раньше уходили только стрелки с флагом Control, без нажатия и отпускания самого Control;
    /// Mission Control перехватывал сочетание, и система считала Control зажатым — следующие тапы
    /// становились Control-кликами (контекстное меню).
    private func postShortcut(_ key: CGKeyCode) {
        let control: CGKeyCode = 59   // kVK_Control
        let steps: [(CGKeyCode, Bool, CGEventFlags)] = [
            (control, true, .maskControl),
            (key, true, [.maskControl, .maskSecondaryFn]),   // стрелки идут с флагом Fn, как с клавиатуры
            (key, false, [.maskControl, .maskSecondaryFn]),
            (control, false, []),
        ]
        for (code, down, flags) in steps {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            if !dryRun { e.post(tap: .cghidEventTap) }
        }
    }
}

extension CGPoint {
    /// Глобальные координаты Cocoa (origin внизу слева главного экрана) → Quartz (origin вверху слева).
    var quartz: CGPoint { CGPoint(x: x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - y) }
}

extension CGEventFlags {
    /// Модификаторы, которые сейчас зажаты на настоящей клавиатуре. Ими помечаются все события эмуляторов:
    /// новое CGEvent берёт флаги из общего состояния сессии, и «залипший» после синтетического сочетания
    /// Control превращал тап в Control-клик (контекстное меню), а прокрутку — в масштаб экрана.
    static var physicalKeyboard: CGEventFlags {
        CGEventSource.flagsState(.hidSystemState).intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
    }
}
