// TouchScreenMapping.swift
// Какой экран у какого сенсорного монитора.
//
// macOS не связывает USB-дигитайзер с дисплеем, поэтому экран выбирается так:
//   1. Калибровка касанием (HIDTouchReader.assign) — сохраняется в UserDefaults и важнее всего.
//   2. Общий порт USB-C: монитор с одним кабелем USB-C выводит изображение и USB на один порт.
//      Номер порта у дигитайзера — старший байт USB LocationID (usb-drdN), у дисплея — старшая
//      цифра PortID в DisplayAttributes фреймбуфера (atcN): 0x01120000 ↔ PortID 0x10 и т.д.
//      Проверено на Mac mini M4 с двумя мониторами; PortID — недокументированное свойство.
//   3. Остальные — по порядку на свободные невстроенные экраны (слева направо).

import AppKit
import IOKit

enum TouchScreenMapping {
    static let defaultsKey = "TouchScreenAssignments"   // [ключ дигитайзера: UUID дисплея]

    /// Ключ дигитайзера, стабильный между перезапусками. Одинаковые мониторы (те же VID/PID,
    /// без серийного номера) различаются только USB-портом.
    static func key(_ device: IOHIDDevice) -> String {
        func int(_ k: String) -> Int { IOHIDDeviceGetProperty(device, k as CFString) as? Int ?? 0 }
        return String(format: "%04x:%04x@%08x", int(kIOHIDVendorIDKey), int(kIOHIDProductIDKey), int(kIOHIDLocationIDKey))
    }

    /// Номер порта USB-C, к которому подключён дигитайзер (старший байт LocationID), или nil.
    static func usbPort(_ device: IOHIDDevice) -> Int? {
        guard IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String == "USB",
              let location = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int,
              location != 0 else { return nil }
        return location >> 24
    }

    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static func uuid(_ display: CGDirectDisplayID) -> String? {
        guard let u = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, u) as String
    }

    /// Порт USB-C каждого внешнего дисплея: PortID из DisplayAttributes фреймбуфера.
    /// Фреймбуфер с дисплеем сопоставляется по EDID (производитель, модель, серийный номер);
    /// если у двух дисплеев EDID одинаковый — их порты неизвестны.
    static func displayPorts() -> [CGDirectDisplayID: Int] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"),
                                           &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }

        var byIdentity: [[Int]: [Int]] = [:]   // [vendor, model, serial] → порты
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let attrs = IORegistryEntryCreateCFProperty(service, "DisplayAttributes" as CFString, nil, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let port = attrs["PortID"] as? Int,
                  let product = attrs["ProductAttributes"] as? [String: Any] else { continue }
            let identity = [product["LegacyManufacturerID"] as? Int ?? -1, product["ProductID"] as? Int ?? -1,
                            product["SerialNumber"] as? Int ?? -1]
            byIdentity[identity, default: []].append(port >> 4)
        }

        var result: [CGDirectDisplayID: Int] = [:]
        let screens = NSScreen.screens.map(displayID)
        for display in screens {
            let identity = [Int(CGDisplayVendorNumber(display)), Int(CGDisplayModelNumber(display)),
                            Int(CGDisplaySerialNumber(display))]
            let sameIdentity = screens.filter {
                [Int(CGDisplayVendorNumber($0)), Int(CGDisplayModelNumber($0)), Int(CGDisplaySerialNumber($0))] == identity
            }
            guard sameIdentity.count == 1, let ports = byIdentity[identity], ports.count == 1 else { continue }
            result[display] = ports[0]
        }
        return result
    }
}
