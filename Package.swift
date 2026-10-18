// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HyprMac",
    platforms: [
        .macOS(.v15)
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
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("QuartzCore")
            ]
        ),
        .testTarget(
            name: "HyprMacTests",
            dependencies: ["HyprMac"],
            path: "Tests/HyprMacTests"
        )
    ]
)
