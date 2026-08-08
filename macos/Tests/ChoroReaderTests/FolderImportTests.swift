import XCTest
@testable import ChoroReader

/// 落として取り込むところ。**書籍は開かない。**
///
/// 開いていた頃は、まとめて落とすと落とした数だけ窓が開いた。
/// 窓が開かないことは検査で押さえられないが、**書棚に載ること**と、
/// **何が起きたかを言葉で返すこと**は押さえられる。
@MainActor
final class FolderImportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("落として取り込む-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 同梱の見本を写す。実書籍は使わない。
    private func sample(_ name: String = "sample.pdf", to place: URL? = nil) throws -> URL {
        let source = TestPaths.repositoryRoot.appendingPathComponent("samples/\(name)")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path))
        let target = (place ?? directory!).appendingPathComponent("\(UUID().uuidString)-\(name)")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    private func settled(_ importing: FolderImport) async {
        for _ in 0 ..< 200 where importing.running || importing.summary == nil {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func test_落としたものが書棚に載る() async throws {
        let store = LibraryStore(fileURL: directory.appendingPathComponent("library.json"))
        let importing = FolderImport()
        let book = try sample()
        importing.drop([book], into: store)
        await settled(importing)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(importing.added, 1)
        XCTAssertEqual(importing.summary, "1 冊を加えました")
    }

    /// **フォルダを落としたら中を辿る。** 走査は中身を読まないので速い。
    func test_フォルダを落としたら中を辿る() async throws {
        let store = LibraryStore(fileURL: directory.appendingPathComponent("library.json"))
        let importing = FolderImport()
        let nested = directory.appendingPathComponent("奥", isDirectory: true)
        _ = try sample(to: nested)
        _ = try sample(to: nested)

        importing.drop([nested], into: store)
        await settled(importing)
        XCTAssertEqual(store.entries.count, 2)
    }

    /// **既にあるものは触らない。** 読書位置も並び順も、取り込みで動かさない。
    func test_同じものを二度落としても増えない() async throws {
        let store = LibraryStore(fileURL: directory.appendingPathComponent("library.json"))
        let importing = FolderImport()
        let book = try sample()

        importing.drop([book], into: store)
        await settled(importing)
        importing.summary = nil
        importing.drop([book], into: store)
        await settled(importing)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(importing.added, 0)
        XCTAssertEqual(importing.already, 1)
        XCTAssertEqual(importing.summary, "1 冊は、すべて書棚にありました")
    }

    /// **壊れた書籍と、書籍でないものを分けて言う。**
    ///
    /// 拡張子が EPUB や PDF なのに読めないのは、壊れているか、名前だけのものである。
    func test_読めない書籍は読めないと言う() async throws {
        let store = LibraryStore(fileURL: directory.appendingPathComponent("library.json"))
        let importing = FolderImport()
        let broken = directory.appendingPathComponent("架空の壊れた本.epub")
        try Data("これは zip ではない".utf8).write(to: broken)

        importing.drop([broken], into: store)
        await settled(importing)

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(importing.failed, 1)
        XCTAssertEqual(importing.summary, "0 冊を加えました（1 冊は読めませんでした）")
    }

    /// **読めなかったものを黙らせない。**
    ///
    /// 落としたのに増えないと、見落としたのか、既にあったのか、
    /// そもそも書籍でなかったのかが分からない。
    func test_書籍でないものは言葉で返す() async throws {
        let store = LibraryStore(fileURL: directory.appendingPathComponent("library.json"))
        let importing = FolderImport()
        let text = directory.appendingPathComponent("架空のメモ.txt")
        try "架空の中身".write(to: text, atomically: true, encoding: .utf8)

        importing.drop([text], into: store)
        await settled(importing)

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(importing.summary, "EPUB と PDF ではありませんでした")
    }

    /// 落とした一部だけが入る、ということが無いこと。
    func test_まとめて落としても全部入る() async throws {
        let store = LibraryStore(fileURL: directory.appendingPathComponent("library.json"))
        let importing = FolderImport()
        var books: [URL] = []
        for _ in 0 ..< 5 { books.append(try sample()) }

        importing.drop(books, into: store)
        await settled(importing)
        XCTAssertEqual(store.entries.count, 5)
        XCTAssertEqual(importing.summary, "5 冊を加えました")
    }
}
