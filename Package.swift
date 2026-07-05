// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "GlassDB",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "GlassDB", targets: ["GlassDB"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0")
    ],
    targets: [
        .executableTarget(
            name: "GlassDB",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "GlassDBTests",
            dependencies: ["GlassDB"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
