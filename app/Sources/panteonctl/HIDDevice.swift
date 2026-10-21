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

// Открывает устройство ЭКСКЛЮЗИВНО (seize): на время работы перехватывает ввод с
// клавиатуры, чтобы наши output-отчёты не смешивались с обычными нажатиями
// (иначе возникают фантомные «залипшие» клавиши). Закрытие возвращает ввод.
func openDeviceSeized(_ c: HIDCollection) -> IOReturn {
    return IOHIDDeviceOpen(c.device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
}

// Закрывает устройство.
func closeDevice(_ c: HIDCollection) {
    IOHIDDeviceClose(c.device, IOOptionBits(kIOHIDOptionsTypeNone))
}

// Отправляет feature-отчёт на устройство (альтернативный канал команд).
func sendFeatureReport(_ c: HIDCollection, reportID: UInt8, bytes: [UInt8]) -> IOReturn {
    return bytes.withUnsafeBufferPointer { ptr in
        IOHIDDeviceSetReport(c.device, kIOHIDReportTypeFeature, CFIndex(reportID), ptr.baseAddress!, bytes.count)
    }
}

// Выбирает коллекцию с feature-отчётом нужного размера (канал команд через feature).
func featureCollection(_ cols: [HIDCollection]) -> HIDCollection? {
    return cols.filter { $0.maxFeatureReportSize >= 64 }
        .max { $0.maxFeatureReportSize < $1.maxFeatureReportSize }
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

// Пытается прочитать feature-отчёт с устройства (альтернативный канал ответа).
func getFeatureReport(_ c: HIDCollection, reportID: UInt8, length: Int) -> (IOReturn, [UInt8]) {
    var buf = [UInt8](repeating: 0, count: length)
    var len = length
    let r = buf.withUnsafeMutableBufferPointer { ptr -> IOReturn in
        IOHIDDeviceGetReport(c.device, kIOHIDReportTypeFeature, CFIndex(reportID), ptr.baseAddress!, &len)
    }
    return (r, Array(buf.prefix(len)))
}

// Ищет коллекции по VID/PID и конкретной usage page (напр. vendor 0xFF00).
func findCollections(usagePage: Int) -> [HIDCollection] {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let matching: [String: Any] = [
        kIOHIDVendorIDKey as String: PanteonID.vendorID,
        kIOHIDProductIDKey as String: PanteonID.productID,
        kIOHIDPrimaryUsagePageKey as String: usagePage,
    ]
    IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
    IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
    guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
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
}

// Читает сырой HID report descriptor устройства (неразрушающе).
func getReportDescriptor(_ c: HIDCollection) -> [UInt8] {
    guard let data = IOHIDDeviceGetProperty(c.device, kIOHIDReportDescriptorKey as CFString) as? Data else {
        return []
    }
    return [UInt8](data)
}

// Контейнер для ответа устройства (input-отчёт приходит в C-колбэк).
final class InputCapture {
    var data: [UInt8] = []
    var got = false
}

// Отправляет команду и ждёт input-ответ от устройства (неразрушающе для query/read).
// Устройство кладёт ответ в input-отчёт; читаем его через колбэк + прокрутку RunLoop.
func sendCommandAndRead(_ c: HIDCollection, packet: [UInt8], reportID: UInt8, timeout: TimeInterval) -> [UInt8]? {
    let capacity = max(c.maxInputReportSize, 64)
    let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
    defer { reportBuffer.deallocate() }

    let capture = InputCapture()
    let ctx = Unmanaged.passUnretained(capture).toOpaque()

    // Колбэк вызывается при приходе input-отчёта; копируем байты в контейнер.
    IOHIDDeviceRegisterInputReportCallback(
        c.device, reportBuffer, capacity,
        { context, _, _, _, _, report, reportLength in
            guard let context = context else { return }
            let cap = Unmanaged<InputCapture>.fromOpaque(context).takeUnretainedValue()
            cap.data = Array(UnsafeBufferPointer(start: report, count: reportLength))
            cap.got = true
        },
        ctx
    )
    IOHIDDeviceScheduleWithRunLoop(c.device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    defer {
        IOHIDDeviceUnscheduleFromRunLoop(c.device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        // Снимаем колбэк, чтобы буфер не использовался после выхода.
        IOHIDDeviceRegisterInputReportCallback(c.device, reportBuffer, capacity, nil, nil)
    }

    // Отправляем команду.
    let r = sendOutputReport(c, reportID: reportID, bytes: packet)
    if r != kIOReturnSuccess { return nil }

    // Крутим RunLoop до ответа или таймаута.
    let deadline = Date().addingTimeInterval(timeout)
    while !capture.got && Date() < deadline {
        CFRunLoopRunInMode(.defaultMode, 0.05, true)
    }
    return capture.got ? capture.data : nil
}

// Отправляет команду как нумерованный отчёт: report ID = первый байт команды,
// payload = остальные байты (на macOS report ID передаётся отдельно от данных).
func sendNumbered(_ c: HIDCollection, command: [UInt8]) -> IOReturn {
    let reportID = command[0]
    let payload = Array(command.dropFirst())
    return sendOutputReport(c, reportID: reportID, bytes: payload)
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
