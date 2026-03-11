// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Orchard",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "OrchardCore",
            targets: ["OrchardCore"]
        ),
        .executable(
            name: "OrchardControlPlane",
            targets: ["OrchardControlPlane"]
        ),
        .executable(
            name: "OrchardAgent",
            targets: ["OrchardAgent"]
        ),
        .executable(
            name: "OrchardCompanionApp",
            targets: ["OrchardCompanionApp"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.118.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.10.0"),
        .package(url: "https://github.com/vapor/fluent-kit.git", from: "1.52.2"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.7.0")
    ],
    targets: [
        .target(
            name: "OrchardCore"
        ),
        .executableTarget(
            name: "OrchardControlPlane",
            dependencies: [
                "OrchardCore",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQL", package: "fluent-kit"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver")
            ]
        ),
        .executableTarget(
            name: "OrchardAgent",
            dependencies: ["OrchardCore"]
        ),
        .executableTarget(
            name: "OrchardCompanionApp",
            dependencies: ["OrchardCore"]
        ),
        .testTarget(
            name: "OrchardCoreTests",
            dependencies: ["OrchardCore"]
        ),
        .testTarget(
            name: "OrchardControlPlaneTests",
            dependencies: [
                "OrchardCore",
                "OrchardControlPlane",
                .product(name: "XCTVapor", package: "vapor"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver")
            ]
        ),
        .testTarget(
            name: "OrchardAgentTests",
            dependencies: [
                "OrchardCore",
                "OrchardAgent"
            ]
        ),
        .testTarget(
            name: "OrchardIntegrationTests",
            dependencies: [
                "OrchardCore",
                "OrchardAgent",
                "OrchardControlPlane",
                .product(name: "Vapor", package: "vapor")
            ]
        )
    ]
)
