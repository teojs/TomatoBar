// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "TomatoBar",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "TomatoBar", targets: ["TomatoBar"])
    ],
    targets: [
        .executableTarget(
            name: "TomatoBar",
            path: "Sources/TomatoBar"
        )
    ]
)
