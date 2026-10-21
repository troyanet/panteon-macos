// Тонкая обёртка над IOKit HID для поиска и инспекции клавиатуры PANTEON.
// На этом этапе — только ЧТЕНИЕ: перечисление устройства и его HID-коллекций.
// Никакой записи в устройство здесь нет (безопасно).
import Foundation
import IOKit
import IOKit.hid

// Идентификаторы нашей клавиатуры (Evision/Sinowealth).
enum PanteonID {
    static let vendorID: Int = 0x320F
    static let productID: Int = 0x5080
    // Служебный канал подсветки/команд — vendor-specific usage page.
    static let vendorUsagePage: Int = 0xFF00
}

// Описание одной HID-коллекции устройства (их у клавиатуры несколько).
struct HIDCollection {
    let usagePage: Int
    let usage: Int
    let maxInputReportSize: Int
    let maxOutputReportSize: Int
    let maxFeatureReportSize: Int
    let product: String
    let device: IOHIDDevice
}

enum HIDError: Error, CustomStringConvertible {
    case notFound
    var description: String {
        switch self {
        case .notFound: return "Клавиатура PANTEON (320F:5080) не найдена. Подключена ли она?"
        }
    }
}

// Читает целочисленное свойство HID-устройства, либо 0, если его нет.
private func intProp(_ device: IOHIDDevice, _ key: CFString) -> Int {
    guard let value = IOHIDDeviceGetProperty(device, key) as? Int else { return 0 }
    return value
}

// Читает строковое свойство HID-устройства, либо "".
private func strProp(_ device: IOHIDDevice, _ key: CFString) -> String {
    guard let value = IOHIDDeviceGetProperty(device, key) as? String else { return "" }
    return value
}

// Человекочитаемое имя кода возврата IOKit (для диагностики).
func ioReturnName(_ r: IOReturn) -> String {
    switch r {
    case kIOReturnSuccess: return "success"
    case kIOReturnNotPermitted: return "not permitted (нужно разрешение Input Monitoring?)"
    case kIOReturnNotPrivileged: return "not privileged (нужны права)"
    case kIOReturnNotOpen: return "device not open"
    case kIOReturnUnsupported: return "unsupported (неверный reportID/тип?)"
    case kIOReturnExclusiveAccess: return "exclusive access (занято другим процессом)"
    default: return "0x" + String(format: "%08x", UInt32(bitPattern: r))
    }
}

// Открывает устройство для отправки отчётов. Без захвата ввода (seize=false).
func openDevice(_ c: HIDCollection) -> IOReturn {
    return IOHIDDeviceOpen(c.device, IOOptionBits(kIOHIDOptionsTypeNone))
}

// Закрывает устройство.
func closeDevice(_ c: HIDCollection) {
    IOHIDDeviceClose(c.device, IOOptionBits(kIOHIDOptionsTypeNone))
}

// Отправляет output-отчёт на устройство. reportID — номер отчёта (0, если нумерации нет).
func sendOutputReport(_ c: HIDCollection, reportID: UInt8, bytes: [UInt8]) -> IOReturn {
    return bytes.withUnsafeBufferPointer { ptr in
        IOHIDDeviceSetReport(
            c.device,
            kIOHIDReportTypeOutput,
            CFIndex(reportID),
            ptr.baseAddress!,
            bytes.count
        )
    }
}

// Выбирает коллекцию-канал команд: с максимальным output-отчётом (нужно 64 байта).
func commandCollection(_ cols: [HIDCollection]) -> HIDCollection? {
    return cols.filter { $0.maxOutputReportSize >= Panteon.commandLength }
        .max { $0.maxOutputReportSize < $1.maxOutputReportSize }
}

// Находит все HID-коллекции нашей клавиатуры по VID/PID.
func findPanteonCollections() throws -> [HIDCollection] {
    // Менеджер HID без опций — мы только перечисляем, не захватываем устройство.
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

    // Фильтр соответствия по VendorID и ProductID.
    let matching: [String: Any] = [
        kIOHIDVendorIDKey as String: PanteonID.vendorID,
        kIOHIDProductIDKey as String: PanteonID.productID,
    ]
    IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

    // Открываем менеджер (без захвата устройств) и забираем совпавшие устройства.
    IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

    guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !set.isEmpty else {
        throw HIDError.notFound
    }

    // Собираем описания коллекций.
    return set.map { device in
        HIDCollection(
            usagePage: intProp(device, kIOHIDPrimaryUsagePageKey as CFString),
            usage: intProp(device, kIOHIDPrimaryUsageKey as CFString),
            maxInputReportSize: intProp(device, kIOHIDMaxInputReportSizeKey as CFString),
            maxOutputReportSize: intProp(device, kIOHIDMaxOutputReportSizeKey as CFString),
            maxFeatureReportSize: intProp(device, kIOHIDMaxFeatureReportSizeKey as CFString),
            product: strProp(device, kIOHIDProductKey as CFString),
            device: device
        )
    }
    // Стабильный порядок вывода: по usage page, затем usage.
    .sorted { ($0.usagePage, $0.usage) < ($1.usagePage, $1.usage) }
}
