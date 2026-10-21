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
}
