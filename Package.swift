// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "TomatoApp",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "TomatoApp", targets: ["TomatoApp"])
    ],
    targets: [
        .executableTarget(
            name: "TomatoApp",
            path: "Sources/TomatoApp"
        )
    ]
)
