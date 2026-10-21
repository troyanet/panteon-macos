// CLI утилиты panteonctl. На текущем этапе поддержана одна безопасная
// команда `info` — она только читает и печатает HID-коллекции клавиатуры.
import Foundation

// Печатает найденные HID-коллекции клавиатуры (диагностика, без записи).
func runInfo() -> Int32 {
    do {
        let collections = try findPanteonCollections()
        print("Найдена клавиатура PANTEON (320F:5080), HID-коллекций: \(collections.count)\n")
        for (i, c) in collections.enumerated() {
            // UsagePage 0xFF00 — наш служебный канал (команды/подсветка).
            let vendor = c.usagePage == PanteonID.vendorUsagePage ? "  ← служебный канал (0xFF00)" : ""
            print("[\(i)] usagePage=0x\(String(c.usagePage, radix: 16)) usage=0x\(String(c.usage, radix: 16))\(vendor)")
            print("    product=\"\(c.product)\"")
            print("    reports: input=\(c.maxInputReportSize) output=\(c.maxOutputReportSize) feature=\(c.maxFeatureReportSize)")
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("Ошибка: \(error)\n".utf8))
        return 1
    }
}

// Отправляет НЕРАЗРУШАЮЩИЙ запрос (0xAA) и проверяет, что канал связи работает.
// Эта команда у родного ПО используется для опроса и ничего не меняет.
func runQuery() -> Int32 {
    do {
        let collections = try findPanteonCollections()
        guard let cmd = commandCollection(collections) else {
            FileHandle.standardError.write(Data("Нет коллекции с output>=64 (канал команд не найден)\n".utf8))
            return 1
        }
        print("Канал команд: usagePage=0x\(String(cmd.usagePage, radix: 16)) output=\(cmd.maxOutputReportSize)")

        // Открываем устройство для отправки.
        let opened = openDevice(cmd)
        guard opened == kIOReturnSuccess else {
            FileHandle.standardError.write(Data("Не удалось открыть устройство: \(ioReturnName(opened))\n".utf8))
            return 1
        }
        defer { closeDevice(cmd) }

        // Собираем безопасный пакет-запрос и печатаем его для наглядности.
        let pkt = Panteon.queryCommand()
        let hex = pkt.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
        print("Отправляю query (первые 8 байт): \(hex) …  (len=\(pkt.count))")

        // Отправляем запрос и ждём ответ (input-отчёт), таймаут 0.8 c.
        if let resp = sendCommandAndRead(cmd, packet: pkt, reportID: 0, timeout: 0.8) {
            let rhex = resp.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
            print("✅ Команда принята, получен ответ (\(resp.count) байт):")
            print("  \(rhex)\(resp.count > 32 ? " …" : "")")
            return 0
        }
        // Ответа нет, но проверим хотя бы факт успешной отправки.
        let r = sendOutputReport(cmd, reportID: 0, bytes: pkt)
        print("Ответ не получен (таймаут). Отправка: \(ioReturnName(r))")
        return r == kIOReturnSuccess ? 0 : 1
    } catch {
        FileHandle.standardError.write(Data("Ошибка: \(error)\n".utf8))
        return 1
    }
}

// Диагностика каналов ответа: ищет vendor-коллекцию 0xFF00 и пробует feature-чтение.
func runProbe() -> Int32 {
    // 1) Пытаемся найти служебную vendor-коллекцию 0xFF00 (на Windows через неё шли команды).
    let vendor = findCollections(usagePage: PanteonID.vendorUsagePage)
    print("Vendor-коллекции (0xFF00): \(vendor.count)")
    for c in vendor {
        print("  usage=0x\(String(c.usage, radix: 16)) input=\(c.maxInputReportSize) output=\(c.maxOutputReportSize) feature=\(c.maxFeatureReportSize)")
    }

    // 2) Пробуем feature-чтение на всех коллекциях (возможный канал ответа).
    guard let all = try? findPanteonCollections() else { return 1 }
    for (i, c) in all.enumerated() where c.maxFeatureReportSize > 1 {
        guard openDevice(c) == kIOReturnSuccess else { continue }
        defer { closeDevice(c) }
        for rid: UInt8 in [0, 4] {
            let (r, data) = getFeatureReport(c, reportID: rid, length: max(c.maxFeatureReportSize, 64))
            if r == kIOReturnSuccess && data.contains(where: { $0 != 0 }) {
                let hex = data.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
                print("[\(i)] feature(reportID=\(rid)) → \(hex)")
            } else {
                print("[\(i)] feature(reportID=\(rid)) → \(ioReturnName(r))\(data.allSatisfy { $0 == 0 } ? " (нули)" : "")")
            }
        }
    }
    return 0
}

// Разбор аргументов: `info` (по умолчанию) или `query`.
let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : "info"

switch command {
case "info":
    exit(runInfo())
case "query":
    exit(runQuery())
case "probe":
    exit(runProbe())
default:
    print("panteonctl — утилита для клавиатуры PANTEON T20 PRO")
    print("Команды:")
    print("  info    показать HID-коллекции устройства (только чтение)")
    print("  query   отправить безопасный запрос 0xAA (проверка связи, ничего не меняет)")
    exit(2)
}
