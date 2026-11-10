// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RouterBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "RouterBar",
            path: "Sources/RouterBar"
        )
    ],
    swiftLanguageModes: [.v5]
)
