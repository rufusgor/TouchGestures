// MultiTouch.swift
// Пункт 3: настоящий мультитач с тачскрина через IOHIDManager
// + распознаватель pinch / rotate / two-finger pan.
//
// Отчёты дигитайзера читаются целиком (input report callback) и разбираются
// по report descriptor устройства. Покоэлементный value callback не подходит:
// он срабатывает только при изменении значения, и неизменившиеся поля
// (TipSwitch, ContactCount, координата неподвижного пальца) теряются.
//
// Требования:
//   - Разрешение «Мониторинг ввода» (Privacy & Security → Input Monitoring).
//   - App Sandbox выключен, либо entitlement com.apple.security.device.usb.
//
// Использование:
//   let reader = HIDTouchReader()
//   reader.screen = touchScreen            // необязательно, см. HIDTouchReader.guessTouchScreen()
//   let recognizer = MultiTouchRecognizer()
//   reader.onFrame = { recognizer.process($0) }
//   recognizer.onGesture = { gesture in
//       singleTouch.isSuspended = recognizer.isActive
//       // применить к видео/таймлайну
//   }
//   try reader.start()

import AppKit
import IOKit.hid
import IOUSBHost

// MARK: - Модель касания

public struct TouchPoint {
    public let id: Int
    /// Глобальные координаты экрана (Cocoa, origin внизу слева).
    public let location: CGPoint
    /// Время отчёта дигитайзера, с (часы CACurrentMediaTime / mach_absolute_time).
    public let timestamp: TimeInterval

    public init(id: Int, location: CGPoint, timestamp: TimeInterval = CACurrentMediaTime()) {
        self.id = id
        self.location = location
        self.timestamp = timestamp
    }

    /// Перевод в координаты view.
    public func location(in view: NSView) -> CGPoint? {
        guard let window = view.window else { return nil }
        let inWindow = window.convertPoint(fromScreen: location)
        return view.convert(inWindow, from: nil)
    }
}

// MARK: - Разбор report descriptor

/// Положение одного поля во входном отчёте.
struct HIDField {
    let bitOffset: Int
    let bitSize: Int
    let logicalMin: Int
    let logicalMax: Int

    func value(in report: UnsafeBufferPointer<UInt8>) -> Int? {
        guard bitSize > 0, bitSize <= 32, (bitOffset + bitSize + 7) / 8 <= report.count else { return nil }
        var raw = 0
        for i in 0..<bitSize {
            let bit = bitOffset + i
            if report[bit >> 3] & (1 << (bit & 7)) != 0 { raw |= 1 << i }
        }
        if logicalMin < 0, raw & (1 << (bitSize - 1)) != 0 { raw -= 1 << bitSize }
        return raw
    }

    /// Значение, приведённое к 0...1 по логическому диапазону.
    func normalized(in report: UnsafeBufferPointer<UInt8>) -> CGFloat? {
        guard let v = value(in: report), logicalMax > logicalMin else { return nil }
        return min(max(CGFloat(v - logicalMin) / CGFloat(logicalMax - logicalMin), 0), 1)
    }
}

/// Раскладка одного входного отчёта с касаниями.
struct TouchReportLayout {
    struct Finger {
        var tip: HIDField?
        var contactID: HIDField?
        var x: HIDField?
        var y: HIDField?
    }

    var fingers: [Finger] = []
    var contactCount: HIDField?
}

enum HIDDescriptorParser {
    // Расширенные usage: page << 16 | usage.
    private static let finger: UInt32       = 0x000D_0022
    private static let tipSwitch: UInt32    = 0x000D_0042
    private static let contactID: UInt32    = 0x000D_0051
    private static let contactCount: UInt32 = 0x000D_0054
    private static let x: UInt32            = 0x0001_0030
    private static let y: UInt32            = 0x0001_0031
    private static let contactCountMax: UInt32 = 0x000D_0055
    private static let certificationBlob: UInt32 = 0xFF00_00C5

    /// Раскладки входных отчётов по report ID (0 — устройство без report ID).
    /// `usesReportIDs` — первый байт отчёта является report ID.
    /// `startupFeatureIDs` — feature-отчёты, которые Windows читает при подключении
    /// (Contact Count Maximum, блоб сертификации 0xC5); см. `TouchFrameAssembler`.
    static func touchLayouts(_ d: [UInt8])
        -> (layouts: [UInt8: TouchReportLayout], usesReportIDs: Bool, startupFeatureIDs: [UInt8]) {
        struct Globals {
            var page: UInt32 = 0
            var logicalMin = 0
            var logicalMaxRaw: UInt32 = 0
            var logicalMaxSize = 0
            var reportSize = 0
            var reportCount = 0
            var reportID: UInt8 = 0

            // Logical Maximum знаковый, только если Logical Minimum отрицательный.
            var logicalMax: Int {
                guard logicalMin < 0, logicalMaxSize > 0 else { return Int(logicalMaxRaw) }
                return HIDDescriptorParser.signExtend(logicalMaxRaw, logicalMaxSize)
            }
        }

        var g = Globals()
        var globalStack: [Globals] = []
        var usages: [UInt32] = []
        var usageMin: UInt32?, usageMax: UInt32?
        var usesReportIDs = false
        var offsets: [UInt8: Int] = [:]
        /// Стек коллекций: номер коллекции Finger или nil для прочих.
        var collections: [Int?] = []
        var fingerSerial = 0
        var fingers: [UInt8: [Int: TouchReportLayout.Finger]] = [:]
        var counts: [UInt8: HIDField] = [:]
        var startupFeatureIDs = Set<UInt8>()

        func extended(_ u: UInt32, _ size: Int) -> UInt32 { size == 4 ? u : g.page << 16 | u }

        var i = 0
        while i < d.count {
            let prefix = d[i]
            if prefix == 0xFE {   // long item, в дигитайзерах не встречается
                guard i + 1 < d.count else { break }
                i += 3 + Int(d[i + 1])
                continue
            }
            let size = [0, 1, 2, 4][Int(prefix & 0x03)]
            guard i + 1 + size <= d.count else { break }
            var u: UInt32 = 0
            for k in 0..<size { u |= UInt32(d[i + 1 + k]) << (8 * k) }
            i += 1 + size

            let type = (prefix >> 2) & 0x03, tag = prefix >> 4
            switch type {
            case 0:   // Main
                switch tag {
                case 0x8:   // Input
                    let constant = u & 0x01 != 0, variable = u & 0x02 != 0
                    let rid = g.reportID
                    var offset = offsets[rid] ?? (usesReportIDs ? 8 : 0)
                    for n in 0..<g.reportCount {
                        defer { offset += g.reportSize }
                        guard !constant, variable else { continue }
                        let usage: UInt32?
                        if !usages.isEmpty {
                            usage = usages[min(n, usages.count - 1)]
                        } else if let lo = usageMin, let hi = usageMax, lo + UInt32(n) <= hi {
                            usage = lo + UInt32(n)
                        } else {
                            usage = nil
                        }
                        guard let usage else { continue }

                        let field = HIDField(bitOffset: offset, bitSize: g.reportSize,
                                             logicalMin: g.logicalMin, logicalMax: g.logicalMax)
                        if usage == contactCount { counts[rid] = field; continue }
                        guard let f = collections.last(where: { $0 != nil }) ?? nil else { continue }
                        switch usage {
                        case tipSwitch: fingers[rid, default: [:]][f, default: .init()].tip = field
                        case contactID: fingers[rid, default: [:]][f, default: .init()].contactID = field
                        case x:         fingers[rid, default: [:]][f, default: .init()].x = field
                        case y:         fingers[rid, default: [:]][f, default: .init()].y = field
                        default:        break
                        }
                    }
                    offsets[rid] = offset
                case 0xB:   // Feature
                    if usages.contains(contactCountMax) || usages.contains(certificationBlob) {
                        startupFeatureIDs.insert(g.reportID)
                    }
                case 0xA:   // Collection
                    let usage = usages.first ?? usageMin
                    if usage == finger {
                        collections.append(fingerSerial)
                        fingerSerial += 1
                    } else {
                        collections.append(nil)
                    }
                case 0xC:   // End Collection
                    _ = collections.popLast()
                default:    // Output — на входной отчёт не влияет
                    break
                }
                usages.removeAll()
                usageMin = nil
                usageMax = nil
            case 1:   // Global
                switch tag {
                case 0x0: g.page = u
                case 0x1: g.logicalMin = size > 0 ? signExtend(u, size) : 0
                case 0x2: g.logicalMaxRaw = u; g.logicalMaxSize = size
                case 0x7: g.reportSize = Int(u)
                case 0x8: g.reportID = UInt8(truncatingIfNeeded: u); usesReportIDs = true
                case 0x9: g.reportCount = Int(u)
                case 0xA: globalStack.append(g)
                case 0xB: g = globalStack.popLast() ?? g
                default:  break
                }
            case 2:   // Local
                switch tag {
                case 0x0: usages.append(extended(u, size))
                case 0x1: usageMin = extended(u, size)
                case 0x2: usageMax = extended(u, size)
                default:  break
                }
            default:
                break
            }
        }

        var layouts: [UInt8: TouchReportLayout] = [:]
        for (rid, byCollection) in fingers {
            let list = byCollection.sorted { $0.key < $1.key }.map(\.value)
                .filter { $0.contactID != nil && $0.x != nil && $0.y != nil }
            guard !list.isEmpty else { continue }
            layouts[rid] = TouchReportLayout(fingers: list, contactCount: counts[rid])
        }
        return (layouts, usesReportIDs, startupFeatureIDs.sorted())
    }

    private static func signExtend(_ u: UInt32, _ size: Int) -> Int {
        let bits = size * 8
        let v = Int(u)
        return v & (1 << (bits - 1)) != 0 ? v - (1 << bits) : v
    }
}

// MARK: - Сборка кадров

/// Собирает полный кадр касаний из отчётов одного устройства.
/// Учитывает hybrid mode: если пальцев больше, чем слотов в отчёте, кадр приходит
/// несколькими отчётами — в первом ContactCount равен общему числу касаний, в остальных 0.
struct TouchFrameAssembler {
    let layouts: [UInt8: TouchReportLayout]
    let usesReportIDs: Bool
    /// Feature-отчёты, которые нужно прочитать при подключении. Многие панели (например, ILITEK)
    /// до этого шлют касания только как мышь, а мультитач-интерфейс молчит.
    let startupFeatureIDs: [UInt8]

    /// Касания кадра, который ещё собирается (нормализованные 0...1, origin вверху слева).
    private var pending: [Int: CGPoint] = [:]
    /// Сколько касаний ещё ожидается в текущем кадре.
    private var expected = 0

    init(descriptor: [UInt8]) {
        (layouts, usesReportIDs, startupFeatureIDs) = HIDDescriptorParser.touchLayouts(descriptor)
    }

    var isTouchDevice: Bool { !layouts.isEmpty }

    /// Возвращает полный кадр, когда он собран; nil — кадр ещё не завершён или отчёт не про касания.
    mutating func feed(_ report: UnsafeBufferPointer<UInt8>) -> [Int: CGPoint]? {
        let rid = usesReportIDs ? (report.first ?? 0) : 0
        guard let layout = layouts[rid] else { return nil }

        // Без ContactCount каждый отчёт — полный кадр по всем слотам.
        let count = layout.contactCount.map { $0.value(in: report) ?? 0 } ?? layout.fingers.count
        if count > 0 {
            pending.removeAll()
            expected = count
        } else if expected == 0 {
            // ContactCount = 0 вне кадра: некоторые устройства так сообщают, что пальцев нет.
            let anyTip = layout.fingers.contains { ($0.tip?.value(in: report) ?? 0) != 0 }
            return anyTip ? nil : [:]
        }

        for f in layout.fingers where expected > 0 {
            expected -= 1
            guard let id = f.contactID?.value(in: report) else { continue }
            let touching = f.tip.map { ($0.value(in: report) ?? 0) != 0 } ?? true
            guard touching, let x = f.x?.normalized(in: report), let y = f.y?.normalized(in: report)
            else { continue }
            pending[id] = CGPoint(x: x, y: y)
        }
        return expected == 0 ? pending : nil
    }
}

// MARK: - Чтение HID

public enum HIDTouchError: Error {
    case accessDenied
    case openFailed(IOReturn)
}

public final class HIDTouchReader {
    /// Вызывается на главном потоке после каждого полного кадра от дигитайзера.
    public var onFrame: (([TouchPoint]) -> Void)?

    /// Экран для всех сенсорных мониторов сразу. nil — у каждого монитора свой экран,
    /// см. TouchScreenMapping (калибровка, общий порт USB-C, по порядку).
    public var screen: NSScreen?

    /// Вызывается при подключении и отключении сенсорных мониторов; аргумент — их названия.
    public var onDevicesChanged: (([String]) -> Void)?

    /// Отладка: каждый входной отчёт касаний как есть (до разбора).
    public var onRawReport: ((UnsafeBufferPointer<UInt8>) -> Void)?

    /// Названия подключённых сенсорных мониторов.
    public var deviceNames: [String] {
        devices.keys.map { IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String ?? "?" }.sorted()
    }

    /// Сенсорные мониторы и их экраны: «ILITEK-TP (порт 3) → AQ14T, по порту USB-C».
    public var deviceDescriptions: [String] {
        refreshAssignmentsIfNeeded()
        return devices.keys.sorted { TouchScreenMapping.key($0) < TouchScreenMapping.key($1) }.map { device in
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
            let port = TouchScreenMapping.usbPort(device).map { " (порт \($0))" } ?? ""
            guard let a = assignments[device], let screen = Self.screen(withID: a.display) else {
                return name + port + " → экран не найден"
            }
            return "\(name)\(port) → \(screen.localizedName), \(a.how)"
        }
    }

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var devices: [IOHIDDevice: TouchFrameAssembler] = [:]

    /// Экран каждого монитора и как он выбран; пересчитывается при смене устройств и экранов.
    private var assignments: [IOHIDDevice: (display: CGDirectDisplayID, how: String)] = [:]
    private var assignmentsValid = false
    private var screenObserver: Any?

    /// Монитор, касания которого сейчас обрабатываются: пальцы на двух мониторах сразу
    /// не должны складываться в один жест.
    private var activeDevice: IOHIDDevice?
    private var lastFrameTime: [IOHIDDevice: TimeInterval] = [:]

    /// Калибровка: вместо обработки касаний сообщает, какого монитора коснулись.
    private var calibrationHandler: ((String) -> Void)?
    private var touching = Set<IOHIDDevice>()

    public init() {}

    /// Экран сенсорного монитора: аргумент `-touchScreen <N>` (индекс в NSScreen.screens)
    /// или такой же ключ в UserDefaults, иначе первый невстроенный экран, иначе главный.
    public static func guessTouchScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let index = UserDefaults.standard.object(forKey: "touchScreen") as? Int ??
                       Int(UserDefaults.standard.string(forKey: "touchScreen") ?? ""),
           screens.indices.contains(index) {
            return screens[index]
        }
        let external = screens.first { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return false }
            return CGDisplayIsBuiltin(n.uint32Value) == 0
        }
        return external ?? NSScreen.main
    }

    public func start() throws {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            // Покажет системный запрос; после выдачи прав нужен перезапуск приложения.
            guard IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) else { throw HIDTouchError.accessDenied }
        }

        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: Int(kHIDPage_Digitizer),
            kIOHIDDeviceUsageKey: Int(kHIDUsage_Dig_TouchScreen)
        ] as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<HIDTouchReader>.fromOpaque(ctx).takeUnretainedValue().deviceAdded(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<HIDTouchReader>.fromOpaque(ctx).takeUnretainedValue().deviceRemoved(device)
        }, ctx)
        // С аппаратной меткой времени: доставка отчётов до программы неравномерна (пачки и паузы),
        // а время прихода отчёта в драйвер — точное.
        IOHIDManagerRegisterInputReportWithTimeStampCallback(manager, { ctx, _, sender, _, _, report, length, time in
            guard let ctx, let sender else { return }
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            Unmanaged<HIDTouchReader>.fromOpaque(ctx).takeUnretainedValue()
                .handleReport(device, UnsafeBufferPointer(start: report, count: length), time: time)
        }, ctx)

        // Во всех режимах цикла: пока приложение в режиме отслеживания (открыто меню, перетаскивается
        // окно, модальная панель), отчёты в .defaultMode не доставляются — касания замирают, а отпустить
        // кнопку мыши, начавшую это отслеживание, некому. Получалось зависание до ~17 с.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.invalidateAssignments()
        }

        let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else { throw HIDTouchError.openFailed(r) }
    }

    // MARK: Экраны мониторов

    /// Следующее касание любого монитора вызовет `handler` с ключом этого монитора;
    /// касания при этом не обрабатываются. Для калибровки: «коснитесь этого экрана».
    public func beginCalibration(_ handler: @escaping (_ deviceKey: String) -> Void) {
        if activeDevice != nil {
            activeDevice = nil
            onFrame?([])
        }
        calibrationHandler = handler
    }

    public func endCalibration() {
        calibrationHandler = nil
    }

    /// Запомнить, что монитор с ключом `deviceKey` (из `beginCalibration`) — это `screen`.
    public func assign(deviceKey: String, to screen: NSScreen) {
        guard let uuid = TouchScreenMapping.uuid(TouchScreenMapping.displayID(screen)) else { return }
        var saved = UserDefaults.standard.dictionary(forKey: TouchScreenMapping.defaultsKey) as? [String: String] ?? [:]
        saved[deviceKey] = uuid
        UserDefaults.standard.set(saved, forKey: TouchScreenMapping.defaultsKey)
        invalidateAssignments()
    }

    /// Забыть калибровку — экраны снова выбираются автоматически.
    public func resetAssignments() {
        UserDefaults.standard.removeObject(forKey: TouchScreenMapping.defaultsKey)
        invalidateAssignments()
    }

    private func invalidateAssignments() {
        assignmentsValid = false
        onDevicesChanged?(deviceNames)
    }

    private func refreshAssignmentsIfNeeded() {
        guard !assignmentsValid else { return }
        assignmentsValid = true

        let screens = NSScreen.screens
        let ids = screens.map(TouchScreenMapping.displayID)
        let saved = UserDefaults.standard.dictionary(forKey: TouchScreenMapping.defaultsKey) as? [String: String] ?? [:]
        let ports = TouchScreenMapping.displayPorts()
        let ordered = devices.keys.sorted { TouchScreenMapping.key($0) < TouchScreenMapping.key($1) }
        var result: [IOHIDDevice: (display: CGDirectDisplayID, how: String)] = [:]
        var used = Set<CGDirectDisplayID>()

        // 1. Калибровка.
        for device in ordered {
            guard let uuid = saved[TouchScreenMapping.key(device)],
                  let id = ids.first(where: { TouchScreenMapping.uuid($0) == uuid }) else { continue }
            result[device] = (id, "калибровка")
            used.insert(id)
        }
        // 2. Общий порт USB-C.
        for device in ordered where result[device] == nil {
            guard let port = TouchScreenMapping.usbPort(device),
                  let id = ids.first(where: { ports[$0] == port && !used.contains($0) }) else { continue }
            result[device] = (id, "по порту USB-C")
            used.insert(id)
        }
        // 3. По порядку на свободные невстроенные экраны, слева направо.
        var free = screens.filter {
            let id = TouchScreenMapping.displayID($0)
            return !used.contains(id) && CGDisplayIsBuiltin(id) == 0
        }.sorted { $0.frame.minX < $1.frame.minX }.map(TouchScreenMapping.displayID)
        for device in ordered where result[device] == nil {
            if !free.isEmpty {
                result[device] = (free.removeFirst(), "по порядку")
            } else if let fallback = Self.guessTouchScreen() {
                result[device] = (TouchScreenMapping.displayID(fallback), "по умолчанию")
            }
        }
        assignments = result
    }

    private static func screen(withID id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { TouchScreenMapping.displayID($0) == id }
    }

    private func targetScreen(for device: IOHIDDevice) -> NSScreen? {
        if let screen { return screen }
        refreshAssignmentsIfNeeded()
        return assignments[device].flatMap { Self.screen(withID: $0.display) } ?? Self.guessTouchScreen()
    }

    public func stop() {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        devices.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    deinit { stop() }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// mach_absolute_time → секунды на тех же часах, что CACurrentMediaTime.
    private static func seconds(machTime: UInt64) -> TimeInterval {
        machTime == 0 ? CACurrentMediaTime()
                      : Double(machTime) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    /// Возвращает мониторы в режим мыши: переподключает их USB-устройства, как выдёргивание кабеля.
    /// Вызывать перед `stop()` при выходе из приложения — иначе панель остаётся в мультитач-режиме
    /// и не работает как мышь, пока её не переподключат.
    public func restoreMouseMode() {
        var done = Set<UInt64>()
        for device in devices.keys {
            guard let usb = usbDevice(of: IOHIDDeviceGetService(device)) else { continue }
            defer { IOObjectRelease(usb) }
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(usb, &id)
            guard done.insert(id).inserted else { continue }   // у одного USB-устройства несколько HID-интерфейсов
            do {
                try IOUSBHostDevice(__ioService: usb, options: [], queue: nil, interestHandler: nil).reset()
            } catch {
                NSLog("HIDTouchReader: USB reset: %@", "\(error)")
            }
        }
    }

    /// Ближайший предок IOUSBHostDevice в дереве IOService (с +1 retain) или nil.
    private func usbDevice(of service: io_service_t) -> io_registry_entry_t? {
        var entry = service
        IOObjectRetain(entry)
        while entry != 0 {
            if IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 { return entry }
            var parent: io_registry_entry_t = 0
            let r = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard r == KERN_SUCCESS else { return nil }
            entry = parent
        }
        return nil
    }

    // MARK: Устройства и отчёты

    private func deviceAdded(_ device: IOHIDDevice) {
        guard let data = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data
        else { return }
        let assembler = TouchFrameAssembler(descriptor: [UInt8](data))
        guard assembler.isTouchDevice else { return }
        devices[device] = assembler
        invalidateAssignments()

        // Как Windows: читаем Contact Count Maximum / блоб 0xC5, после этого панель включает мультитач-отчёты.
        let size = IOHIDDeviceGetProperty(device, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int ?? 0
        for id in assembler.startupFeatureIDs {
            var buf = [UInt8](repeating: 0, count: max(size, 1))
            var len = buf.count
            let r = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(id), &buf, &len)
            if r != kIOReturnSuccess { NSLog("HIDTouchReader: feature report %d: 0x%x", id, r) }
        }
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        guard devices.removeValue(forKey: device) != nil else { return }
        touching.remove(device)
        lastFrameTime[device] = nil
        if activeDevice == device {
            activeDevice = nil
            onFrame?([])   // пальцы этого устройства больше не на экране
        }
        invalidateAssignments()
    }

    private func handleReport(_ device: IOHIDDevice, _ report: UnsafeBufferPointer<UInt8>, time: UInt64) {
        onRawReport?(report)
        guard let frame = devices[device]?.feed(report) else { return }
        let timestamp = Self.seconds(machTime: time)

        if let calibrationHandler {
            // Калибровка: сообщаем о касании (переход «нет пальцев → есть»), сами касания не обрабатываем.
            if frame.isEmpty {
                touching.remove(device)
            } else if touching.insert(device).inserted {
                calibrationHandler(TouchScreenMapping.key(device))
            }
            return
        }

        // Пока заняты пальцы одного монитора, касания другого пропускаем. Если активный монитор
        // замолчал без отпускания (потерян отчёт), через 0.5 с он больше не блокирует остальные.
        if let active = activeDevice, active != device {
            guard timestamp - (lastFrameTime[active] ?? 0) > 0.5 else { return }
            activeDevice = nil
            onFrame?([])
        }
        lastFrameTime[device] = timestamp
        activeDevice = frame.isEmpty ? nil : device

        guard let rect = targetScreen(for: device)?.frame else { return }
        let touches = frame.map { id, n in
            TouchPoint(id: id, location: CGPoint(
                x: rect.minX + n.x * rect.width,
                y: rect.maxY - n.y * rect.height),   // HID: y вниз, Cocoa: y вверх
                timestamp: timestamp)
        }.sorted { $0.id < $1.id }

        onFrame?(touches)
    }
}

// MARK: - Распознаватель мультитач-жестов

public enum MultiTouchGesture {
    case began(center: CGPoint)
    /// scale — относительно начала жеста (1.0 = без изменений),
    /// rotation — радианы, translation — смещение центра в pt.
    case changed(scale: CGFloat, rotation: CGFloat, translation: CGVector, center: CGPoint)
    case ended
}

public final class MultiTouchRecognizer {
    public var onGesture: ((MultiTouchGesture) -> Void)?

    /// Порог в pt, после которого жест считается начавшимся (защита от дрожания).
    public var slop: CGFloat = 8

    /// Сколько секунд пара пальцев может «пропадать», прежде чем жест закончится.
    /// Панели иногда теряют палец на 1–2 кадра (ILITEK — около 30–40 мс).
    public var dropoutTolerance: TimeInterval = 0.1

    public private(set) var isActive = false
    private var start: (ids: [Int], a: CGPoint, b: CGPoint)?
    private var pendingEnd: DispatchWorkItem?

    public init() {}

    public func process(_ touches: [TouchPoint]) {
        guard touches.count == 2 else {
            guard start != nil, pendingEnd == nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.finish() }
            pendingEnd = work
            DispatchQueue.main.asyncAfter(deadline: .now() + dropoutTolerance, execute: work)
            return
        }
        pendingEnd?.cancel()
        pendingEnd = nil

        let ids = touches.map(\.id)
        let a = touches[0].location, b = touches[1].location

        // Новая пара пальцев — новый жест.
        guard let s = start, s.ids == ids else {
            finish()
            start = (ids, a, b)
            return
        }

        let d0 = distance(s.a, s.b), d = distance(a, b)
        let c0 = mid(s.a, s.b), c = mid(a, b)
        let translation = CGVector(dx: c.x - c0.x, dy: c.y - c0.y)

        if !isActive {
            let moved = max(abs(d - d0), hypot(translation.dx, translation.dy))
            guard moved > slop else { return }
            isActive = true
            onGesture?(.began(center: c0))
        }

        let rotation = normalizeAngle(angle(a, b) - angle(s.a, s.b))
        onGesture?(.changed(scale: d0 > 0 ? d / d0 : 1,
                            rotation: rotation,
                            translation: translation,
                            center: c))
    }

    private func finish() {
        pendingEnd?.cancel()
        pendingEnd = nil
        start = nil
        guard isActive else { return }
        isActive = false   // до .ended, чтобы обработчик видел уже завершённый жест
        onGesture?(.ended)
    }

    private func distance(_ p: CGPoint, _ q: CGPoint) -> CGFloat { hypot(q.x - p.x, q.y - p.y) }
    private func mid(_ p: CGPoint, _ q: CGPoint) -> CGPoint { CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2) }
    private func angle(_ p: CGPoint, _ q: CGPoint) -> CGFloat { atan2(q.y - p.y, q.x - p.x) }
    private func normalizeAngle(_ a: CGFloat) -> CGFloat {
        var r = a
        while r > .pi { r -= 2 * .pi }
        while r < -.pi { r += 2 * .pi }
        return r
    }
}
