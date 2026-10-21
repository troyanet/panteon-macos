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

// Разбор аргументов: пока только `info` (по умолчанию тоже `info`).
let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : "info"

switch command {
case "info":
    exit(runInfo())
default:
    print("panteonctl — утилита для клавиатуры PANTEON T20 PRO")
    print("Команды:")
    print("  info   показать HID-коллекции устройства (только чтение)")
    exit(2)
}
