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

    // 2) Печатаем HID report descriptor каждой коллекции — он показывает
    //    report ID, размеры output/feature и vendor-usage (где служебный канал).
    guard let all = try? findPanteonCollections() else { return 1 }
    for (i, c) in all.enumerated() {
        let desc = getReportDescriptor(c)
        print("\n[\(i)] usage=0x\(String(c.usage, radix: 16)) report descriptor (\(desc.count) байт):")
        // Печатаем по 16 байт в строке.
        var line = ""
        for (j, b) in desc.enumerated() {
            line += String(format: "%02x ", b)
            if j % 16 == 15 { print("  \(line)"); line = "" }
        }
        if !line.isEmpty { print("  \(line)") }
    }
    return 0
}

// Устанавливает статичный цвет подсветки. Аргументы: R G B [яркость].
// Это ПЕРВАЯ реальная запись настроек в устройство — печатаем пакет перед отправкой.
func runStatic(_ a: [String]) -> Int32 {
    guard a.count >= 3, let r = UInt8(a[0]), let g = UInt8(a[1]), let b = UInt8(a[2]) else {
        FileHandle.standardError.write(Data("Использование: panteonctl static <R 0-255> <G> <B> [яркость 0-4]\n".utf8))
        return 2
    }
    let brightness = a.count >= 4 ? (UInt8(a[3]) ?? 3) : 3

    do {
        let collections = try findPanteonCollections()
        guard let cmd = commandCollection(collections) else {
            FileHandle.standardError.write(Data("Канал команд не найден\n".utf8))
            return 1
        }
        print("Статичный цвет R=\(r) G=\(g) B=\(b) яркость=\(brightness)")

        let opened = openDevice(cmd)
        guard opened == kIOReturnSuccess else {
            FileHandle.standardError.write(Data("Не удалось открыть устройство: \(ioReturnName(opened))\n".utf8))
            return 1
        }
        defer { closeDevice(cmd) }

        // Последовательность применения режима (канал reportID=4):
        // 1) подготовка → 2) выбрать активный режим (addr 0) →
        // 3) записать параметры режима (addr режим*25) → 4) применение.
        // FUN_00485d10: prepare(1) → write всей 21-байтной структуры по адресу 0 → apply(2).
        let prepare = Panteon.buildCommand(sub: 1)
        let block = Panteon.lightBlock(mode: Panteon.modeStatic, brightness: brightness, speed: 2,
                                       r: r, g: g, b: b, multiColor: false)
        let write = Panteon.buildWriteBlock(sub: Panteon.subWriteBlock, addr: 0, data: block)
        let apply = Panteon.buildCommand(sub: 2)

        // payload без ведущего байта (report ID = 4 передаётся отдельно).
        let r1 = sendNumbered(cmd, command: prepare)
        print("  1) подготовка        → \(ioReturnName(r1))")
        let r2 = sendNumbered(cmd, command: write)
        print("  2) запись блока(addr0)→ \(ioReturnName(r2))")
        usleep(10_000) // родное ПО делает Sleep(10) перед применением
        let r3 = sendNumbered(cmd, command: apply)
        print("  3) применение        → \(ioReturnName(r3))")

        print("✅ Последовательность отправлена. Посмотри на клавиатуру — стал ли цвет статичным красным?")
        return 0
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
case "probe":
    exit(runProbe())
case "static":
    exit(runStatic(Array(args.dropFirst(2))))
default:
    print("panteonctl — утилита для клавиатуры PANTEON T20 PRO")
    print("Команды:")
    print("  info    показать HID-коллекции устройства (только чтение)")
    print("  query   отправить безопасный запрос 0xAA (проверка связи, ничего не меняет)")
    print("  static <R> <G> <B> [яркость 0-4]   задать статичный цвет подсветки")
    exit(2)
}
