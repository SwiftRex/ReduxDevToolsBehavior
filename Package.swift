// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ReduxDevToolsBehavior",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(name: "ReduxDevToolsBehavior", targets: ["ReduxDevToolsBehavior"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SwiftRex/SwiftRex.git", branch: "main"),
        .package(url: "https://github.com/luizmb/NetworkTools.git", branch: "feature/websocket-bonjour-targets"),
        .package(url: "https://github.com/luizmb/FP.git", from: "1.8.1"),
    ],
    targets: [
        .target(
            name: "ReduxDevToolsBehavior",
            dependencies: [
                .product(name: "SwiftRex",            package: "SwiftRex"),
                .product(name: "SwiftRex.Concurrency", package: "SwiftRex"),
                .product(name: "WebSocketClient",      package: "NetworkTools"),
                .product(name: "BonjourService",       package: "NetworkTools"),
                .product(name: "FP",                   package: "FP"),
            ]
        ),
        .testTarget(
            name: "ReduxDevToolsBehaviorTests",
            dependencies: [
                "ReduxDevToolsBehavior",
                .product(name: "SwiftRex",         package: "SwiftRex"),
                .product(name: "SwiftRex.Testing", package: "SwiftRex"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
