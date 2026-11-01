// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeKun",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ClaudeKun", path: "Sources/ClaudeKun")
    ]
)
