// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Baton",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "baton-mcp", targets: ["BatonMCP"]),
        .executable(name: "BatonApp", targets: ["BatonApp"]),
        .library(name: "BatonCore", targets: ["BatonCore"]),
    ],
    targets: [
        .target(
            name: "BatonCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "BatonMCP",
            dependencies: ["BatonCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "BatonApp",
            dependencies: ["BatonCore"],
            // The bundle scripts copy these. SwiftPM must not treat them as
            // resources, or it warns and wraps them in a resource bundle.
            exclude: ["Resources/Info.plist", "Resources/Baton.entitlements"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BatonCoreTests",
            dependencies: ["BatonCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
