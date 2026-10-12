// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Baton",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "BatonCore", targets: ["BatonCore"])
    ],
    targets: [
        .target(name: "BatonCore", path: "Sources/BatonCore"),
        .executableTarget(name: "BatonProbe", dependencies: ["BatonCore"], path: "Sources/BatonProbe"),
        .testTarget(name: "BatonCoreTests", dependencies: ["BatonCore"], path: "Tests/BatonCoreTests")
    ]
)
