// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceMemosCLI",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "vmemo", targets: ["VMemo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "VMemo",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "VMemoTests",
            dependencies: ["VMemo"],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
