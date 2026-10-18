// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenuBarKiller",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "menubarkiller",
            path: "Sources",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "/System/Library/PrivateFrameworks"])
            ]
        )
    ]
)

