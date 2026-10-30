// main.swift — TouchGestures: значок в строке меню, без Дока (LSUIElement в Info.plist).
// Пока приложение запущено, сенсорный монитор работает в мультитач-режиме:
// один палец — мышь, два и три — жесты тачпада, курсор при касании скрыт.
// При выходе монитор возвращается в режим мыши.
// Сборка .app: scripts/build-app.sh

import AppKit
import ServiceManagement
import TouchCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let reader = HIDTouchReader()
    private let mouse = TouchMouseEmulator()
    private let gestures = TrackpadGestureEmulator()
    private let resampler = TouchResampler()
    private var cursor: TouchCursorHider?
    private var calibration: CalibrationController?
    private var started = false
    private var inputMonitoringDenied = false
    private var retryTimer: Timer?
    /// Держит App Nap выключенным: касания обрабатываются в реальном времени.
    private let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
        reason: "Обработка касаний сенсорного монитора")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Кадры выравниваются по обновлению экрана — плавное движение без рывков.
        let log = GestureLog.shared
        reader.onFrame = { [weak self] touches in
            log.frame("R", touches)
            self?.resampler.process(touches)
        }
        resampler.onFrame = { [weak self] touches in
            log.frame("S", touches)
            self?.cursor?.process(touches)
            self?.mouse.process(touches)
            self?.gestures.process(touches)
        }
        if log.isEnabled {
            mouse.onButtonEvent = { log.event($0) }
            gestures.onEvent = { log.event($0) }
        }
        reader.onDevicesChanged = { [weak self] _ in self?.updateIcon() }

        TouchMouseEmulator.requestAccess()   // системный запрос «Универсального доступа», если его нет
        tryStart()
        if !started {
            // Разрешения выдаются в Системных настройках — ждём их без перезапуска.
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tryStart() }
        }
        updateIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        GestureLog.shared.flush()
        guard started else { return }
        cursor?.show()
        reader.restoreMouseMode()
        reader.stop()
    }

    // MARK: - Запуск

    private func tryStart() {
        guard !started else { return }
        // Без «Универсального доступа» мультитач не включаем: эмулировать мышь будет нечем,
        // и монитор перестанет реагировать на касания.
        guard TouchMouseEmulator.isTrusted else { updateIcon(); return }
        do {
            try reader.start()
            started = true
            cursor = TouchCursorHider()   // глобальный монитор мыши требует «Универсального доступа»
            inputMonitoringDenied = false
            retryTimer?.invalidate()
            retryTimer = nil
        } catch HIDTouchError.accessDenied {
            inputMonitoringDenied = true
        } catch {
            NSLog("TouchGestures: %@", "\(error)")
        }
        updateIcon()
    }

    private var problem: String? {
        if !TouchMouseEmulator.isTrusted { return "Нужен доступ: Универсальный доступ" }
        if inputMonitoringDenied { return "Нужен доступ: Мониторинг ввода" }
        if !started { return "Не удалось открыть HID" }
        if reader.deviceNames.isEmpty { return "Сенсорный монитор не подключён" }
        return nil
    }

    private func updateIcon() {
        let ok = problem == nil
        let image = NSImage(systemSymbolName: ok ? "hand.tap" : "hand.raised.slash",
                            accessibilityDescription: "Жесты сенсорного монитора")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = problem ?? reader.deviceDescriptions.joined(separator: "\n")
    }

    // MARK: - Меню

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        for line in problem.map({ [$0] }) ?? reader.deviceDescriptions {
            menu.addItem(withTitle: line, action: nil, keyEquivalent: "").isEnabled = false
        }

        if !TouchMouseEmulator.isTrusted {
            addItem(menu, "Открыть настройки «Универсальный доступ»…", #selector(openAccessibility))
        }
        if inputMonitoringDenied {
            addItem(menu, "Открыть настройки «Мониторинг ввода»…", #selector(openInputMonitoring))
        }

        if started, !reader.deviceNames.isEmpty {
            menu.addItem(.separator())
            addItem(menu, "Настроить сенсорные мониторы…", #selector(calibrate))
            addItem(menu, "Сбросить настройку мониторов", #selector(resetCalibration))
        }

        menu.addItem(.separator())
        let login = addItem(menu, "Запускать при входе в систему", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off

        menu.addItem(.separator())
        addItem(menu, "Выйти", #selector(NSApplication.terminate(_:)), key: "q").target = NSApp
    }

    @objc private func calibrate() {
        guard calibration == nil else { return }
        calibration = CalibrationController(reader: reader) { [weak self] in
            self?.calibration = nil
            self?.updateIcon()
        }
        calibration?.start()
    }

    @objc private func resetCalibration() {
        reader.resetAssignments()
    }

    @discardableResult
    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openAccessibility() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func openInputMonitoring() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private func openSettings(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Не удалось изменить автозапуск"
            alert.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
