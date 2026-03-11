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
        .package(url: "https://github.com/vapor/vapor.git", from: "4.118.0")
    ],
    targets: [
        .target(
            name: "OrchardCore"
        ),
        .executableTarget(
            name: "OrchardControlPlane",
            dependencies: [
                "OrchardCore",
                .product(name: "Vapor", package: "vapor")
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
        )
    ]
)
