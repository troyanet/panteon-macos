// Сборка командных пакетов для клавиатуры (канал команд, 64 байта).
// Формат восстановлен из родного ПО (см. docs/protocol-notes.md):
//   [0]      = opcode (4 для команд настройки)
//   [1..2]   = контрольная сумма = сумма байтов [3..63], little-endian
//   [3]      = субкоманда
//   [4..]    = параметры
// Контрольная сумма ОБЯЗАТЕЛЬНА — без неё команда невалидна.
import Foundation

enum Panteon {
    // Длина командного пакета.
    static let commandLength = 64
    // Opcode команд настройки.
    static let opcode: UInt8 = 4
    // Субкоманда-запрос: неразрушающая, родное ПО шлёт её для опроса.
    static let subQuery: UInt8 = 0xAA

    // Считает 16-битную контрольную сумму: сумма байтов с индекса 3 до конца.
    static func checksum(_ buf: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        for i in 3..<buf.count { sum &+= UInt32(buf[i]) }
        return UInt16(sum & 0xFFFF)
    }

    // Собирает командный пакет: заполняет opcode, субкоманду, параметры и сумму.
    static func buildCommand(sub: UInt8, params: [UInt8] = []) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: commandLength)
        buf[0] = opcode
        buf[3] = sub
        // Параметры идут с индекса 4.
        for (i, p) in params.enumerated() where 4 + i < commandLength {
            buf[4 + i] = p
        }
        // Контрольная сумма считается по уже заполненным [3..63].
        let cs = checksum(buf)
        buf[1] = UInt8(cs & 0xFF)
        buf[2] = UInt8((cs >> 8) & 0xFF)
        return buf
    }

    // Готовый неразрушающий запрос состояния.
    static func queryCommand() -> [UInt8] {
        return buildCommand(sub: subQuery)
    }

    // --- Подсветка ---------------------------------------------------------
    // Субкоманда записи блока памяти устройства (из декомпиляции FUN_00479f20).
    static let subWriteBlock: UInt8 = 6
    // Номера режимов (таблица из родного ПО, см. docs/protocol-notes.md).
    static let modeStatic: UInt8 = 6

    // Собирает write-команду: пишет data по адресу addr в память устройства.
    // Формат: [3]=субкоманда, [4]=длина куска, [5..6]=адрес(LE), [8..]=данные.
    static func buildWriteBlock(sub: UInt8, addr: UInt16, data: [UInt8]) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: commandLength)
        buf[0] = opcode
        buf[3] = sub
        buf[4] = UInt8(data.count)            // длина куска
        buf[5] = UInt8(addr & 0xFF)           // адрес (младший байт)
        buf[6] = UInt8((addr >> 8) & 0xFF)    // адрес (старший байт)
        for (i, b) in data.enumerated() where 8 + i < commandLength {
            buf[8 + i] = b                    // данные блока с offset 8
        }
        let cs = checksum(buf)
        buf[1] = UInt8(cs & 0xFF)
        buf[2] = UInt8((cs >> 8) & 0xFF)
        return buf
    }

    // Собирает 21-байтный блок настроек подсветки (раскладка из FUN_004434f0).
    // [0]=режим [1]=яркость [2]=скорость [3]=Fx [4]=MultiColor [5..7]=RGB.
    static func lightBlock(mode: UInt8, brightness: UInt8, speed: UInt8,
                           r: UInt8, g: UInt8, b: UInt8, multiColor: Bool) -> [UInt8] {
        var blk = [UInt8](repeating: 0, count: 0x15) // 21 байт
        blk[0] = mode
        blk[1] = min(brightness, 4)   // яркость 0..4
        blk[2] = min(speed, 5)        // скорость 0..5
        blk[3] = 0                    // Fx
        blk[4] = multiColor ? 1 : 0
        blk[5] = r
        blk[6] = g
        blk[7] = b
        return blk
    }

    // Шаг размещения параметров каждого режима в памяти устройства (из FUN_00485a60:
    // read субкомандой 5, адрес = режим * 0x19 = режим * 25).
    static let modeStride: UInt16 = 0x19

    // Субкоманда чтения блока памяти устройства (парная к записи; из FUN_0047a1a0).
    static let subReadBlock: UInt8 = 5

    // Команда чтения: запросить len байт по адресу addr.
    static func buildReadCommand(addr: UInt16, len: UInt8) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: commandLength)
        buf[0] = opcode
        buf[3] = subReadBlock
        buf[4] = len
        buf[5] = UInt8(addr & 0xFF)
        buf[6] = UInt8((addr >> 8) & 0xFF)
        let cs = checksum(buf)
        buf[1] = UInt8(cs & 0xFF)
        buf[2] = UInt8((cs >> 8) & 0xFF)
        return buf
    }

    // Команда выбора активного режима: пишет 1 байт режима по адресу 0.
    static func selectModeCommand(mode: UInt8) -> [UInt8] {
        return buildWriteBlock(sub: subWriteBlock, addr: 0, data: [mode])
    }

    // Команда записи параметров режима (цвет/яркость/скорость) по адресу режим*25.
    static func writeModeParamsCommand(mode: UInt8, brightness: UInt8, speed: UInt8,
                                       r: UInt8, g: UInt8, b: UInt8, multiColor: Bool) -> [UInt8] {
        let blk = lightBlock(mode: mode, brightness: brightness, speed: speed,
                             r: r, g: g, b: b, multiColor: multiColor)
        let addr = UInt16(mode) &* modeStride
        return buildWriteBlock(sub: subWriteBlock, addr: addr, data: blk)
    }
}
