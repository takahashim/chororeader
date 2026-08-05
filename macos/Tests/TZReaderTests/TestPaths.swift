import Foundation

/// テストから共有資産（検証用フィクスチャ）を指すための位置。
/// 実装がリポジトリ内で移動しても、ここだけ直せば済むようにまとめておく。
enum TestPaths {
    /// リポジトリの根。このファイルは macos/Tests/TZReaderTests/ にある。
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // TZReaderTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // macos
        .deletingLastPathComponent()   // リポジトリの根

    static func fixture(_ name: String) -> URL {
        repositoryRoot.appendingPathComponent("conformance/fixtures/\(name)")
    }

    static func markdownFixture(_ name: String) -> URL {
        repositoryRoot.appendingPathComponent("conformance/fixtures-md/\(name)")
    }
}
