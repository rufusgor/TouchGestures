// TouchMouseEmulator.swift
// Эмуляция мыши одним пальцем по кадрам из HIDTouchReader.
// После включения мультитач-режима панель перестаёт работать как мышь, поэтому касание
// одним пальцем превращается в системные события — как раньше это делала прошивка панели:
//   - тап — левый клик (несколько тапов подряд — двойной/тройной клик);
//   - сдвиг пальца дальше `slop` — нажатие и перетаскивание;
//   - удержание без сдвига `longPressDuration` — правый клик (контекстное меню).
// Кнопка нажимается только когда понятно, что это за касание, поэтому мультитач-жест
// (второй палец лёг до сдвига/удержания) кликов не порождает.
//
// Требования: разрешение «Универсальный доступ» (Privacy & Security → Accessibility).
//
// Использование:
//   let mouse = TouchMouseEmulator()
//   reader.onFrame = { mouse.process($0); recognizer.process($0) }

import AppKit

public final class TouchMouseEmulator {
    /// Сдвиг (pt), после которого касание становится перетаскиванием.
    public var slop: CGFloat = 15
    /// Время удержания без сдвига до правого клика.
    public var longPressDuration: TimeInterval = 0.6
    /// На сколько pt можно промахнуться между тапами, чтобы они считались двойным кликом.
    public var doubleClickRadius: CGFloat = 30
    /// Сколько палец может «пропадать», прежде чем касание считается отпущенным.
    /// Панели теряют палец на 1–2 кадра (ILITEK — 30–40 мс) и иногда выдают ему новый ID.
    public var dropoutTolerance: TimeInterval = 0.08
    /// Насколько близко (pt) должен появиться палец с новым ID, чтобы считаться тем же.
    public var reacquireRadius: CGFloat = 60
    /// Перетаскивание начинается не раньше, чем через столько после касания: второй палец
    /// прокрутки ложится через 10–130 мс, и за это время первый успевает сдвинуться на 20–30 pt.
    /// Путь не теряется — кнопка нажимается в точке касания.
    public var dragDelay: TimeInterval = 0.15

    /// Отладка: вызывается для каждого нажатия и отпускания кнопки.
    public var onButtonEvent: ((String) -> Void)?
    /// Для проверки по записанным касаниям: события не отправляются в систему, только onButtonEvent.
    public var dryRun = false

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Показывает системный запрос, если доступа нет; после выдачи прав нужен перезапуск приложения.
    @discardableResult
    public static func requestAccess() -> Bool {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    private struct Contact {
        var id: Int
        let start: CGPoint
        var at: CGPoint
        let startTime = ProcessInfo.processInfo.systemUptime
    }

    private enum Phase {
        case touching   // палец лежит, ещё не ясно: тап, перетаскивание или удержание
        case dragging   // левая кнопка нажата
        case held       // правый клик уже отправлен, ждём отпускания
    }

    private enum State {
        case idle
        case active(Contact, Phase)
        /// Мультитач-жест: мышь не трогаем, пока не поднимут все пальцы.
        case suppressed
    }

    private var state = State.idle
    private var liftWork: DispatchWorkItem?
    private var holdWork: DispatchWorkItem?
    private var clickCount = 0
    private var lastClick: (at: CGPoint, time: TimeInterval)?
    private let source = CGEventSource(stateID: .hidSystemState)
    private var dragEvents = 0

    public init() {}

    public func process(_ touches: [TouchPoint]) {
        switch state {
        case .idle:
            guard let t = touches.first else { return }
            guard touches.count == 1 else { state = .suppressed; return }
            begin(t)

        case .active(var c, let phase):
            guard touches.count <= 1 else {
                cancel(&holdWork)
                cancel(&liftWork)
                if phase == .dragging { post(.leftMouseUp, c.at) }
                state = .suppressed
                return
            }
            guard let t = touches.first else { scheduleLift(); return }
            // Палец вернулся после пропадания (или с новым ID) далеко от прежнего места, пока не ясно,
            // что это за касание, — это новое касание, а не прыжок. Так ведёт себя прошивка ILITEK,
            // когда ложится второй палец: на ~20 мс теряет все касания и отдаёт ID первого пальца
            // второму, и «прыжок» на десятки pt превращался в перетаскивание.
            if phase == .touching, liftWork != nil || t.id != c.id, distance(t.location, c.at) > slop {
                cancel(&liftWork)
                cancel(&holdWork)
                begin(t)
                return
            }
            if t.id != c.id {
                // Новый ID: тот же палец после пропадания или новое касание.
                guard distance(t.location, c.at) <= reacquireRadius else {
                    lift()
                    process(touches)
                    return
                }
                c.id = t.id
            }
            cancel(&liftWork)
            guard t.location != c.at else { state = .active(c, phase); return }
            c.at = t.location

            switch phase {
            case .touching where distance(c.at, c.start) > slop
                && ProcessInfo.processInfo.systemUptime - c.startTime >= dragDelay:
                cancel(&holdWork)
                clickCount = 1
                lastClick = nil
                post(.leftMouseDown, c.start)
                post(.leftMouseDragged, c.at)
                state = .active(c, .dragging)
            case .touching, .held:
                post(.mouseMoved, c.at)
                state = .active(c, phase)
            case .dragging:
                post(.leftMouseDragged, c.at)
                state = .active(c, .dragging)
            }

        case .suppressed:
            if touches.isEmpty { scheduleLift() } else { cancel(&liftWork) }
        }
    }

    // MARK: - Фазы

    private func begin(_ t: TouchPoint) {
        state = .active(Contact(id: t.id, start: t.location, at: t.location), .touching)
        post(.mouseMoved, t.location)
        let work = DispatchWorkItem { [weak self] in self?.hold() }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + longPressDuration, execute: work)
    }

    private func hold() {
        holdWork = nil
        guard case .active(let c, .touching) = state else { return }
        clickCount = 1
        lastClick = nil
        post(.rightMouseDown, c.at, button: .right)
        post(.rightMouseUp, c.at, button: .right)
        state = .active(c, .held)
    }

    private func scheduleLift() {
        guard liftWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.lift() }
        liftWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dropoutTolerance, execute: work)
    }

    private func lift() {
        cancel(&liftWork)
        cancel(&holdWork)
        defer { state = .idle }
        guard case .active(let c, let phase) = state else { return }
        switch phase {
        case .touching where distance(c.at, c.start) > slop:
            // Быстрый взмах короче dragDelay — короткое перетаскивание, а не клик.
            clickCount = 1
            lastClick = nil
            post(.leftMouseDown, c.start)
            post(.leftMouseDragged, c.at)
            post(.leftMouseUp, c.at)
        case .touching: click(at: c.start)
        case .dragging: post(.leftMouseUp, c.at)
        case .held:     break
        }
    }

    private func click(at p: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastClick, now - last.time <= NSEvent.doubleClickInterval,
           distance(p, last.at) <= doubleClickRadius {
            clickCount += 1
        } else {
            clickCount = 1
        }
        // Повторные клики — в точку первого, чтобы приложение не сочло их кликами по разным местам.
        let at = clickCount > 1 ? lastClick!.at : p
        post(.leftMouseDown, at)
        post(.leftMouseUp, at)
        lastClick = (at, now)
    }

    // MARK: - Вспомогательное

    private func cancel(_ work: inout DispatchWorkItem?) {
        work?.cancel()
        work = nil
    }

    private func distance(_ p: CGPoint, _ q: CGPoint) -> CGFloat { hypot(q.x - p.x, q.y - p.y) }

    private func post(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton = .left) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                              mouseCursorPosition: p.quartz, mouseButton: button) else { return }
        e.flags = .physicalKeyboard   // без «залипших» модификаторов — иначе тап мог стать Control-кликом
        if type != .mouseMoved { e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount)) }
        if !dryRun { e.post(tap: .cghidEventTap) }

        switch type {
        case .mouseMoved:
            break
        case .leftMouseDragged:
            dragEvents += 1
        default:
            let drag = type == .leftMouseUp && dragEvents > 0 ? " (перетаскивание: \(dragEvents) событий)" : ""
            onButtonEvent?(String(format: "мышь: %@ ×%d (%.0f, %.0f)", "\(type.debugName)", clickCount, p.x, p.y) + drag)
            dragEvents = 0
        }
    }
}

private extension CGEventType {
    var debugName: String {
        switch self {
        case .leftMouseDown:  return "leftDown"
        case .leftMouseUp:    return "leftUp"
        case .rightMouseDown: return "rightDown"
        case .rightMouseUp:   return "rightUp"
        default:              return "\(rawValue)"
        }
    }
}
