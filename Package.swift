// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuickTalk",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "QuickTalk",
            path: "Sources/QuickTalk"
        )
    ]
)
