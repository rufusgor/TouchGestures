// Calibration.swift — «Коснитесь этого экрана»: по очереди на каждом экране, чтобы связать
// сенсорные мониторы с дисплеями, если автоматическое сопоставление ошиблось.

import AppKit
import TouchCore

final class CalibrationController {
    private let reader: HIDTouchReader
    private var screens: [NSScreen] = []
    private var index = 0
    private var window: NSWindow?
    private var keyMonitor: Any?
    private let onFinish: () -> Void

    init(reader: HIDTouchReader, onFinish: @escaping () -> Void) {
        self.reader = reader
        self.onFinish = onFinish
    }

    func start() {
        screens = NSScreen.screens
        index = 0
        NSApp.activate(ignoringOtherApps: true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.finish(); return nil }   // Esc — отмена
            return event
        }
        showCurrent()
    }

    private func showCurrent() {
        window?.orderOut(nil)
        guard index < screens.count else { finish(); return }
        let screen = screens[index]

        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.backgroundColor = NSColor.black.withAlphaComponent(0.85)
        w.isOpaque = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let title = NSTextField(labelWithString: "Коснитесь этого экрана пальцем")
        title.font = .systemFont(ofSize: 40, weight: .semibold)
        title.textColor = .white
        let detail = NSTextField(labelWithString:
            "Экран «\(screen.localizedName)», \(index + 1) из \(screens.count). " +
            "Если он не сенсорный — нажмите «Пропустить» мышью. Esc — отмена.")
        detail.font = .systemFont(ofSize: 17)
        detail.textColor = NSColor.white.withAlphaComponent(0.8)
        let skip = NSButton(title: "Пропустить", target: self, action: #selector(skipScreen))
        skip.bezelStyle = .rounded

        let stack = NSStackView(views: [title, detail, skip])
        stack.orientation = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        w.contentView = content
        w.makeKeyAndOrderFront(nil)
        window = w

        reader.beginCalibration { [weak self] deviceKey in
            guard let self else { return }
            reader.assign(deviceKey: deviceKey, to: screen)
            index += 1
            showCurrent()
        }
    }

    @objc private func skipScreen() {
        index += 1
        showCurrent()
    }

    private func finish() {
        reader.endCalibration()
        window?.orderOut(nil)
        window = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        onFinish()
    }
}
