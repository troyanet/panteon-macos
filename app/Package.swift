// swift-tools-version:6.0
// Пакет SwiftPM для утилиты управления клавиатурой PANTEON T20 PRO.
import PackageDescription

let package = Package(
    name: "panteonctl",
    platforms: [
        // Минимальная версия macOS; IOKit HID доступен давно.
        .macOS(.v13)
    ],
    targets: [
        // Исполняемая CLI-утилита. IOKit и CoreFoundation берутся из SDK,
        // отдельные зависимости не нужны.
        .executableTarget(
            name: "panteonctl",
            path: "Sources/panteonctl"
        )
    ]
)
