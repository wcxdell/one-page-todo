// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OnePage",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "OnePage", targets: ["OnePage"])],
    targets: [.executableTarget(name: "OnePage"), .testTarget(name: "OnePageTests", dependencies: ["OnePage"])]
)
