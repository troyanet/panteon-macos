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

        let prepare = Panteon.buildCommand(sub: 1)
        let block = Panteon.lightBlock(mode: Panteon.modeStatic, brightness: brightness, speed: 2,
                                       r: r, g: g, b: b, multiColor: false)
        let write = Panteon.buildWriteBlock(sub: Panteon.subWriteBlock, addr: 0, data: block)
        let apply = Panteon.buildCommand(sub: 2)

        // Гипотеза: команды идут FEATURE-отчётом на коллекцию с feature=64 (b1 02 в descriptor).
        guard let feat = featureCollection(collections) else {
            FileHandle.standardError.write(Data("Нет коллекции с feature>=64\n".utf8)); return 1
        }
        guard openDevice(feat) == kIOReturnSuccess else {
            FileHandle.standardError.write(Data("Не удалось открыть feature-коллекцию\n".utf8)); return 1
        }
        defer { closeDevice(feat) }
        print("Канал: FEATURE на коллекции usage=0x\(String(feat.usage, radix: 16)) feature=\(feat.maxFeatureReportSize)")
        // Feature-отчёт ненумерованный: reportID=0, полный 64-байтный буфер.
        let f1 = sendFeatureReport(feat, reportID: 0, bytes: prepare)
        print("  1) подготовка → \(ioReturnName(f1))")
        let f2 = sendFeatureReport(feat, reportID: 0, bytes: write)
        print("  2) запись     → \(ioReturnName(f2))")
        usleep(10_000)
        let f3 = sendFeatureReport(feat, reportID: 0, bytes: apply)
        print("  3) применение → \(ioReturnName(f3))")
        print("✅ Отправлено FEATURE-отчётом. Посмотри на клавиатуру — стал ли цвет статичным красным?")
        return 0
    } catch {
        FileHandle.standardError.write(Data("Ошибка: \(error)\n".utf8))
        return 1
    }
}

// Диагностика: послать произвольный режим N с цветом, чтобы увидеть реакцию.
// Аргументы: <режим N> [R G B] [яркость]. Помогает понять, что реально меняется.
func runMode(_ a: [String]) -> Int32 {
    guard a.count >= 1, let mode = UInt8(a[0]) else {
        FileHandle.standardError.write(Data("Использование: panteonctl mode <N> [R G B] [яркость]\n".utf8))
        return 2
    }
    let r = a.count >= 4 ? (UInt8(a[1]) ?? 255) : 255
    let g = a.count >= 4 ? (UInt8(a[2]) ?? 0) : 0
    let b = a.count >= 4 ? (UInt8(a[3]) ?? 0) : 0
    let brightness = a.count >= 5 ? (UInt8(a[4]) ?? 4) : 4

    do {
        let collections = try findPanteonCollections()
        guard let cmd = commandCollection(collections) else { return 1 }
        guard openDevice(cmd) == kIOReturnSuccess else {
            FileHandle.standardError.write(Data("Не удалось открыть устройство\n".utf8)); return 1
        }
        defer { closeDevice(cmd) }

        let block = Panteon.lightBlock(mode: mode, brightness: brightness, speed: 2,
                                       r: r, g: g, b: b, multiColor: false)
        let prepare = Panteon.buildCommand(sub: 1)
        let write = Panteon.buildWriteBlock(sub: Panteon.subWriteBlock, addr: 0, data: block)
        let apply = Panteon.buildCommand(sub: 2)

        _ = sendNumbered(cmd, command: prepare)
        _ = sendNumbered(cmd, command: write)
        usleep(10_000)
        _ = sendNumbered(cmd, command: apply)
        print("Отправлен режим \(mode) (R=\(r) G=\(g) B=\(b) яркость=\(brightness)). Что изменилось на клавиатуре?")
        return 0
    } catch {
        FileHandle.standardError.write(Data("Ошибка: \(error)\n".utf8)); return 1
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
case "mode":
    exit(runMode(Array(args.dropFirst(2))))
default:
    print("panteonctl — утилита для клавиатуры PANTEON T20 PRO")
    print("Команды:")
    print("  info    показать HID-коллекции устройства (только чтение)")
    print("  query   отправить безопасный запрос 0xAA (проверка связи, ничего не меняет)")
    print("  static <R> <G> <B> [яркость 0-4]   задать статичный цвет подсветки")
    exit(2)
}
