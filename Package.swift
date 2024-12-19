// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MenuBarMonitor",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MenuBarMonitor", targets: ["MenuBarMonitor"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "MenuBarMonitor",
            dependencies: []
        )
    ]
)
