// swift-tools-version:5.9
// The Mac app as a Swift package, for the quick development loop
// (scripts/build-app.sh, scripts/dev.sh, `--transcribe`). Releases are built
// from TachyonAI.xcodeproj, which also has the iOS app.
import PackageDescription

let package = Package(
    name: "TachyonAI",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "TachyonAI",
            path: ".",
            sources: ["Mac", "Shared"]
        )
    ]
)
