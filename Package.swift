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
    targets: [
        .executableTarget(
            name: "GlassDB",
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
