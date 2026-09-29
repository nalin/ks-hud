// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "KSHud",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "KSHud", path: "Sources/KSHud"),
    ]
)
