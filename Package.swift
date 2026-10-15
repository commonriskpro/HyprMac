// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HyprMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "HyprMac",
            targets: ["HyprMac"]
        )
    ],
    targets: [
        .executableTarget(
            name: "HyprMac",
            path: "Sources/HyprMac",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("QuartzCore")
            ]
        )
    ]
)
