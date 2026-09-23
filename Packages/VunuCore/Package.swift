// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VunuCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "VunuCore", targets: ["VunuCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "VunuCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "GRDB", package: "GRDB.swift"),
                "VunuObjC",
            ],
            path: "Sources/VunuCore",
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "VunuObjC",
            path: "Sources/VunuObjC"
        ),
        .testTarget(
            name: "VunuCoreTests",
            dependencies: ["VunuCore"],
            path: "Tests/VunuCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
