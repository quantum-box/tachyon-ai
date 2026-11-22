// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TachyonAI",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "TachyonAI",
            path: "Sources/TachyonAI"
        )
    ]
)
