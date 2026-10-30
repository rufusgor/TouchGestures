// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MultiTouchDemo",
    platforms: [.macOS(.v14)],
    targets: [
        // Ядро: чтение мультитача с тачскрина, эмуляция мыши и жестов тачпада.
        .target(
            name: "TouchCore",
            path: "Sources/TouchCore",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("AppKit"), .linkedFramework("IOUSBHost")]
        ),
        // Демо-окно с отображением распознанных жестов.
        .executableTarget(
            name: "MultiTouchDemo",
            dependencies: ["TouchCore"],
            path: "Sources/MultiTouchDemo"
        ),
        // Приложение в строке меню (без Дока); собирается в .app скриптом scripts/build-app.sh.
        .executableTarget(
            name: "TouchGestures",
            dependencies: ["TouchCore"],
            path: "Sources/TouchGestures",
            linkerSettings: [.linkedFramework("ServiceManagement")]
        )
    ]
)
