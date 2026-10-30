// TouchCursorHider.swift
// Скрывает курсор при касании сенсорного экрана и показывает снова, когда двигают настоящую
// мышь или тачпад — как в Windows и на iPad. Наши собственные (эмулированные) движения мыши
// курсор не показывают: они отличаются по PID источника события.
//
// Фоновое приложение (LSUIElement) обычным CGDisplayHideCursor курсор не скрывает, поэтому
// соединению с WindowServer выставляется недокументированное свойство «SetsCursorInBackground»
// (так делают утилиты, скрывающие курсор). В будущих версиях macOS может перестать работать.
//
// Требования: «Универсальный доступ» (глобальный монитор событий мыши).
//
// Использование:
//   let cursor = TouchCursorHider()
//   reader.onFrame = { cursor.process($0); mouse.process($0) }

import AppKit

public final class TouchCursorHider {
    private var hidden = false
    private var monitor: Any?
    private let pid = Int64(ProcessInfo.processInfo.processIdentifier)

    public init() {
        Self.allowCursorControlInBackground()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) {
            [weak self] event in
            guard let self, let source = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID),
                  source != pid else { return }
            show()   // движение настоящей мыши или тачпада
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        show()
    }

    public func process(_ touches: [TouchPoint]) {
        if !touches.isEmpty { hide() }
    }

    public func show() {
        guard hidden else { return }
        hidden = false
        CGDisplayShowCursor(CGMainDisplayID())
    }

    private func hide() {
        guard !hidden else { return }
        hidden = true
        CGDisplayHideCursor(CGMainDisplayID())
    }

    private static func allowCursorControlInBackground() {
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let all = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        guard let c = dlsym(all, "_CGSDefaultConnection"), let p = dlsym(all, "CGSSetConnectionProperty") else {
            NSLog("TouchCursorHider: CGS API недоступен, курсор будет скрываться только в активном приложении")
            return
        }
        let connection = unsafeBitCast(c, to: DefaultConnection.self)()
        _ = unsafeBitCast(p, to: SetProperty.self)(connection, connection,
                                                   "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}
