// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BrightnessBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "BrightnessBar", path: "Sources/BrightnessBar")
    ]
)
