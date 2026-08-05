// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EPUBViewSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "EPUBViewSpike",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
