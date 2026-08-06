// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TZReader",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TZReader",
            path: "Sources/TZReader",
            // 書籍を 1 冊も持たないマシンでも読み方を確かめられるよう、サンプルを同梱する。
            // 実体は samples/ にあり、ruby samples/build.rb で作り直せる。
            resources: [.copy("Resources/sample-reflowable.epub"),
                        .copy("Resources/sample-fixed.epub"),
                        .copy("Resources/sample.pdf")],
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
