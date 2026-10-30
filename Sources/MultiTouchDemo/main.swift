// main.swift — демо: окно, в котором отображаются распознанные жесты.
// Запуск: swift run  (или собрать и запустить .build/debug/MultiTouchDemo)

import AppKit
import TouchCore

final class GestureView: NSView {
    let label = NSTextField(labelWithString: "Коснитесь экрана…")
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        label.font = .monospacedSystemFont(ofSize: 18, weight: .medium)
        label.frame = NSRect(x: 20, y: 20, width: 900, height: 60)
        label.autoresizingMask = [.width]
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String) {
        label.stringValue = text
        print(text)
    }

    // События тачпада, которые приложение получает от TrackpadGestureEmulator.
    private var scrolled = CGPoint.zero, zoom: CGFloat = 1, rotation: CGFloat = 0

    override func scrollWheel(with e: NSEvent) {
        if e.phase == .began { scrolled = .zero }
        scrolled.x += e.scrollingDeltaX
        scrolled.y += e.scrollingDeltaY
        let text = String(format: "scrollWheel (%.0f, %.0f)", scrolled.x, scrolled.y)
        if e.phase == .ended || e.momentumPhase == .ended {
            show(text + (e.momentumPhase == .ended ? "  [инерция конец]" : "  [конец]"))
        } else {
            label.stringValue = text + (e.momentumPhase.isEmpty ? "" : "  [инерция]")
        }
    }

    override func magnify(with e: NSEvent) {
        if e.phase == .began { zoom = 1 }
        zoom *= 1 + e.magnification
        let text = String(format: "magnify ×%.2f", zoom)
        if e.phase == .ended { show(text + "  [конец]") } else { label.stringValue = text }
    }

    override func rotate(with e: NSEvent) {
        if e.phase == .began { rotation = 0 }
        rotation += CGFloat(e.rotation)
        let text = String(format: "rotate %.0f°", rotation)
        if e.phase == .ended { show(text + "  [конец]") } else { label.stringValue = text }
    }

    override func rightMouseDown(with e: NSEvent) {
        show(String(format: "rightMouseDown (%.0f, %.0f)", e.locationInWindow.x, e.locationInWindow.y))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, SingleTouchGesturesDelegate {
    private var window: NSWindow!
    private var view: GestureView!
    private var singleTouch: SingleTouchGestures!
    private let reader = HIDTouchReader()
    private let recognizer = MultiTouchRecognizer()
    private let mouse = TouchMouseEmulator()
    private let gestures = TrackpadGestureEmulator()
    private let resampler = TouchResampler()
    private let diagnostics = FreezeDiagnostics()

    func applicationDidFinishLaunching(_ notification: Notification) {
        view = GestureView(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
        window = NSWindow(contentRect: view.frame,
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "MultiTouch Demo"
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)

        // Пункт 1
        singleTouch = SingleTouchGestures(view: view)
        singleTouch.delegate = self

        // Пункт 3
        // Экран тачскрина: внешний монитор или `swift run MultiTouchDemo -touchScreen <N>`.
        // Один палец — эмулируемая мышь (панель в мультитач-режиме сама мышью больше не работает),
        // два и больше — жесты тачпада во всей системе.
        reader.onRawReport = { [weak self] report in self?.diagnostics.report(report) }
        reader.onFrame = { [weak self] touches in
            self?.diagnostics.raw(touches)
            self?.resampler.process(touches)
        }
        resampler.onFrame = { [weak self] touches in
            self?.diagnostics.resampled(touches)
            self?.mouse.process(touches)
            self?.gestures.process(touches)
            self?.recognizer.process(touches)
        }
        mouse.onButtonEvent = { print($0) }
        gestures.onEvent = { print($0) }
        recognizer.onGesture = { [weak self] g in
            guard let self else { return }
            singleTouch.isSuspended = recognizer.isActive
            // Сами жесты окно получает как события тачпада (scrollWheel/magnify/rotate) — см. GestureView.
            if case .ended = g { print("2 пальца: конец") }
        }
        // Без «Универсального доступа» мультитач не включаем: иначе тач перестанет работать как мышь.
        if !TouchMouseEmulator.requestAccess() {
            view.show("Нет доступа к «Универсальному доступу» — дайте его и перезапустите. Пока работает только мышь.")
        } else {
            do {
                try reader.start()
            } catch {
                view.show("HID недоступен: \(error). Дайте доступ в «Мониторинг ввода» и перезапустите.")
            }
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: SingleTouchGesturesDelegate

    func singleTouchDidDoubleTap(at point: NSPoint) {
        view.show(String(format: "double tap (%.0f, %.0f)", point.x, point.y))
    }

    func singleTouchDidPan(translation: NSPoint, state: NSGestureRecognizer.State) {
        guard state == .changed else { return }
        view.show(String(format: "pan (%.0f, %.0f)", translation.x, translation.y))
    }

    func singleTouchDidSwipe(_ direction: SwipeDirection) {
        view.show("swipe \(direction)")
    }
}

/// Диагностика зависаний: паузы в отчётах панели (по аппаратным меткам и по доставке),
/// паузы в выводе после выравнивания и остановки главного потока.
final class FreezeDiagnostics {
    private var lastRaw: (hw: TimeInterval, cb: TimeInterval, n: Int)?
    private var lastOut: (t: TimeInterval, n: Int)?
    private var rawCount = 0, outCount = 0
    private var pong = CACurrentMediaTime()
    private let t0 = CACurrentMediaTime()

    init() {
        Thread.detachNewThread { [weak self] in
            var stalled = false
            while let self {
                DispatchQueue.main.async { self.pong = CACurrentMediaTime() }
                Thread.sleep(forTimeInterval: 0.05)
                let lag = CACurrentMediaTime() - self.pong
                if lag > 0.2, !stalled { stalled = true; self.log("ГЛАВНЫЙ ПОТОК стоит > 200 мс") }
                if lag < 0.1, stalled { stalled = false; self.log("главный поток ожил") }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, rawCount > 0 || outCount > 0 else { return }
            log("за 1 с: отчётов \(rawCount), после выравнивания \(outCount)")
            rawCount = 0
            outCount = 0
        }
    }

    func raw(_ touches: [TouchPoint]) {
        rawCount += 1
        let cb = CACurrentMediaTime(), hw = touches.first?.timestamp ?? cb
        if let l = lastRaw, l.n > 0, touches.count > 0 {
            if hw - l.hw > 0.3 { log(String(format: "пауза панели %.0f мс (по аппаратным меткам)", (hw - l.hw) * 1000)) }
            if cb - l.cb > 0.3 { log(String(format: "пауза доставки %.0f мс", (cb - l.cb) * 1000)) }
            if l.hw - cb > 0.05 || cb - hw > 0.5 { log(String(format: "метка времени не сходится: отчёт %.3f, сейчас %.3f", hw - t0, cb - t0)) }
        }
        lastRaw = (hw, cb, touches.count)
    }

    private var lastReportLog = 0.0

    /// Отчёт с первым пальцем ровно в (0, 0) — пишем байты (не чаще раза в секунду).
    func report(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard bytes.count >= 6, bytes[1] & 0x40 != 0, bytes[2] == 0, bytes[3] == 0, bytes[4] == 0, bytes[5] == 0,
              CACurrentMediaTime() - lastReportLog > 1 else { return }
        lastReportLog = CACurrentMediaTime()
        log("отчёт с касанием в (0,0), \(bytes.count) байт: " + bytes.map { String(format: "%02x", $0) }.joined(separator: " "))
    }

    func resampled(_ touches: [TouchPoint]) {
        outCount += 1
        let t = CACurrentMediaTime()
        if let l = lastOut, l.n > 0, t - l.t > 0.3 {
            log(String(format: "пауза вывода %.0f мс (пальцев %d → %d)", (t - l.t) * 1000, l.n, touches.count))
        }
        lastOut = (t, touches.count)
    }

    private func log(_ s: String) {
        print(String(format: "[%7.2f] ", CACurrentMediaTime() - t0) + s)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
