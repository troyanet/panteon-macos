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

        // Первый байт пакета = opcode(4). Пробуем как номер отчёта и как ненумерованный (0).
        for rid: UInt8 in [0, pkt[0]] {
            let r = sendOutputReport(cmd, reportID: rid, bytes: pkt)
            print("  SetReport(reportID=\(rid)) → \(ioReturnName(r))")
            if r == kIOReturnSuccess {
                print("✅ Команда принята устройством (канал связи работает).")
                return 0
            }
        }
        FileHandle.standardError.write(Data("Не удалось отправить команду ни с одним reportID.\n".utf8))
        return 1
    } catch {
        FileHandle.standardError.write(Data("Ошибка: \(error)\n".utf8))
        return 1
    }
}

// Разбор аргументов: `info` (по умолчанию) или `query`.
let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : "info"

switch command {
case "info":
    exit(runInfo())
case "query":
    exit(runQuery())
default:
    print("panteonctl — утилита для клавиатуры PANTEON T20 PRO")
    print("Команды:")
    print("  info    показать HID-коллекции устройства (только чтение)")
    print("  query   отправить безопасный запрос 0xAA (проверка связи, ничего не меняет)")
    exit(2)
}
