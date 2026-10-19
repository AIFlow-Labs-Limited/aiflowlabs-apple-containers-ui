// swift-tools-version: 6.2
// Container Desktop — a native macOS UI for Apple's `container` runtime.
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "ContainerDesktop",
    platforms: [.macOS("26")],
    products: [
        .executable(name: "ContainerDesktop", targets: ["ContainerDesktop"]),
        .library(name: "ContainerKit", targets: ["ContainerKit"]),
        .library(name: "ContainerKitMock", targets: ["ContainerKitMock"]),
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
    ],
    dependencies: [
        // Embedded terminal for `container exec -it` / `container machine run`.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.9.0"),
    ],
    targets: [
        // MARK: Domain + backend contract + CLI backend (no UI, no AppKit)
        .target(
            name: "ContainerKit",
            swiftSettings: swiftSettings
        ),
        // MARK: Fixture-driven backend for previews, UI development and tests
        .target(
            name: "ContainerKitMock",
            dependencies: ["ContainerKit"],
            resources: [.copy("Resources/cli-1.5.0")],
            swiftSettings: swiftSettings
        ),
        // MARK: Design tokens + reusable SwiftUI components (no business logic)
        .target(
            name: "DesignSystem",
            dependencies: ["ContainerKit"],
            swiftSettings: swiftSettings
        ),
        // MARK: Observable stores, polling, settings, command bus (SwiftUI-agnostic where possible)
        .target(
            name: "AppCore",
            dependencies: ["ContainerKit"],
            swiftSettings: swiftSettings
        ),
        // MARK: The app
        .executableTarget(
            name: "ContainerDesktop",
            dependencies: [
                "ContainerKit", "ContainerKitMock", "AppCore", "DesignSystem",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ContainerKitTests",
            dependencies: ["ContainerKit", "ContainerKitMock"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: ["AppCore", "ContainerKitMock", "DesignSystem"],
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
