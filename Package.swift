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
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0")
    ],
    targets: [
        .executableTarget(
            name: "GlassDB",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MySQLNIO", package: "mysql-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio")
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
