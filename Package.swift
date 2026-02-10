// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "KeynoteSidekick",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "KeynoteSidekickCore", targets: ["KeynoteSidekickCore"]),
        .library(name: "KeynoteSidekickAdapters", targets: ["KeynoteSidekickAdapters"]),
        .executable(name: "keynote-sidekick", targets: ["KeynoteSidekickCLI"])
    ],
    targets: [
        .target(
            name: "KeynoteSidekickCore"
        ),
        .target(
            name: "KeynoteSidekickAdapters",
            dependencies: ["KeynoteSidekickCore"]
        ),
        .executableTarget(
            name: "KeynoteSidekickCLI",
            dependencies: ["KeynoteSidekickAdapters", "KeynoteSidekickCore"]
        ),
        .testTarget(
            name: "KeynoteSidekickCoreTests",
            dependencies: ["KeynoteSidekickCore", "KeynoteSidekickAdapters"]
        ),
        .testTarget(
            name: "KeynoteSidekickCLITests",
            dependencies: ["KeynoteSidekickCLI"]
        )
    ]
)
