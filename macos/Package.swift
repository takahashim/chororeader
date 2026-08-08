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
        // モデルを Core ML の束へ変換する道具。**アプリには入れない。**
        // アプリは成果物を使うだけである（spec-local-ai.md 第 4.6 節）。
        // 実行体と分けてあるのは、中身を検査から触るためである。
        .target(
            name: "ChoroConvert",
            path: "Sources/ChoroConvert",
            // weight.bin の形式は coremltools 由来（BSD-3-Clause）。告知を運ぶ。
            exclude: ["LICENSE-COREMLTOOLS-BSD"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            // 名前も置き場所もライブラリ（ChoroConvert）と変えてある。
            // macOS のファイル名は大文字小文字を区別しないので、
            // 同じ綴りだと 1 つの場所・1 つの中間物になってしまう。
            name: "choro-convert",
            dependencies: ["ChoroConvert"],
            path: "Sources/ConvertCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ChoroConvertTests",
            dependencies: ["ChoroConvert"],
            path: "Tests/ChoroConvertTests",
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
