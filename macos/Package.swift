// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ChoroReader",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ChoroReader",
            path: "Sources/ChoroReader",
            // 書籍を 1 冊も持たないマシンでも読み方を確かめられるよう、サンプルを同梱する。
            // 実体は samples/ にあり、ruby samples/build.rb で作り直せる。
            resources: [.copy("Resources/sample-reflowable.epub"),
                        .copy("Resources/sample-fixed.epub"),
                        .copy("Resources/sample.pdf")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ChoroReaderTests",
            dependencies: ["ChoroReader"],
            path: "Tests/ChoroReaderTests",
            // 期待値は道筋で読む（TestPaths）。束ねる必要は無いので、資源にはしない。
            exclude: ["Fixtures"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
