// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TZReader",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TZReader",
            path: "Sources/TZReader",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TZReaderTests",
            dependencies: ["TZReader"],
            path: "Tests/TZReaderTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
