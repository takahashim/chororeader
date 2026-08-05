// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ReadiumMacBuild",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "./swift-toolkit-patched"),
    ],
    targets: [
        .target(
            name: "ReadiumMacBuild",
            dependencies: [
                .product(name: "ReadiumShared", package: "swift-toolkit-patched"),
                .product(name: "ReadiumStreamer", package: "swift-toolkit-patched"),
            ]
        ),
    ]
)
