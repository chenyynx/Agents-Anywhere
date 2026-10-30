// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentsAnywhereClient",
    platforms: [.macOS(.v15), .iOS("26.2")],
    dependencies: [
        // Route B's row store engine, pinned exactly as decided on 2026-10-21.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "ClientCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Agents Anywhere/Agents Anywhere",
            exclude: [
                "App", "Assets.xcassets", "Resources", "Services", "Stores", "Views",
                "ios-dark.icon", "Business/AccountAvatarProcessor.swift",
            ],
            sources: ["API", "Network", "Models", "Domain", "Business", "Repositories"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "ClientCoreTests",
            dependencies: ["ClientCore"],
            path: "Tests/ClientCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ],
    swiftLanguageModes: [.v5]
)
