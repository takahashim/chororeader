import XCTest
@testable import ChoroReader

/// フォルダの中から書籍を探すところ。
@MainActor
final class BookFinderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("choro-finder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func put(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func names(_ found: [URL]) -> [String] {
        found.map { $0.lastPathComponent }
    }

    func test_下の階層まで探す() throws {
        _ = try put("a.epub")
        _ = try put("技術評論社/2026/b.pdf")
        _ = try put("その他/c.epub")

        let found = BookFinder.books(in: root)
        XCTAssertEqual(Set(names(found)), ["a.epub", "b.pdf", "c.epub"])
    }

    func test_書籍でないものは拾わない() throws {
        _ = try put("a.epub")
        _ = try put("readme.txt")
        _ = try put("表紙.png")
        _ = try put("bundle.mobi")

        XCTAssertEqual(names(try XCTUnwrap(BookFinder.books(in: root))), ["a.epub"])
    }

    func test_大文字の拡張子も拾う() throws {
        _ = try put("A.EPUB")
        _ = try put("B.Pdf")
        XCTAssertEqual(Set(names(BookFinder.books(in: root))), ["A.EPUB", "B.Pdf"])
    }

    func test_隠しファイルは拾わない() throws {
        _ = try put("a.epub")
        _ = try put(".隠し.epub")
        XCTAssertEqual(names(BookFinder.books(in: root)), ["a.epub"])
    }

    /// 深さに頭を打つ。書籍と関係ない木を際限なく舐めないため。
    func test_深すぎるところは見ない() throws {
        _ = try put("1/2/3/4/5/6/7/深い.epub")
        _ = try put("1/浅い.epub")

        let found = BookFinder.books(in: root, maxDepth: 2)
        XCTAssertEqual(names(found), ["浅い.epub"])
    }

    /// 取り込みの進み方が毎回同じになるよう、道筋の順に並べる。
    func test_道筋の順に並ぶ() throws {
        _ = try put("z/1.epub")
        _ = try put("a/2.epub")
        _ = try put("m/3.epub")

        XCTAssertEqual(names(BookFinder.books(in: root)), ["2.epub", "3.epub", "1.epub"])
    }

    func test_無いフォルダでは空を返す() {
        let missing = root.appendingPathComponent("どこにも無い")
        XCTAssertTrue(BookFinder.books(in: missing).isEmpty)
    }
}

/// 開かずに書棚へ加えるところ。
@MainActor
final class LibraryRegisterTests: XCTestCase {
    func test_開かずに加えられて_二度目は加わらない() throws {
        let url = TestPaths.fixture("epub3-basic.epub")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        let store = LibraryStore.shared
        let id = BookID(url: url)
        let existed = store.entry(for: id) != nil
        defer { if !existed { store.remove(id) } }
        if existed { store.remove(id) }

        XCTAssertTrue(store.register(url), "加わっていない")
        XCTAssertEqual(store.entry(for: id)?.title, "基本の書籍")
        XCTAssertFalse(store.register(url), "二度目も加えている")
    }

    /// 取り込んだ書籍が「いま開いた」ことになると、書棚の先頭を埋めてしまう。
    func test_取り込みは並びの先頭を奪わない() throws {
        let url = TestPaths.fixture("epub3-basic.epub")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        let store = LibraryStore.shared
        let id = BookID(url: url)
        store.remove(id)
        defer { store.remove(id) }

        store.register(url)
        let stamp = try XCTUnwrap(store.entry(for: id)?.lastOpenedAt)
        XCTAssertLessThan(stamp, Date().addingTimeInterval(-1),
                          "取り込んだ時刻が入っている。ファイルの更新日時にすること")
    }

    func test_書籍でないものは加えない() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("choro-これは本ではない.epub")
        try Data("ただの文字".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(LibraryStore.shared.register(url))
    }
}

/// まとめて外すところ。書類が紛れ込んだ書棚を掃除するのに要る。
@MainActor
final class LibraryBulkRemoveTests: XCTestCase {
    private var root: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("choro-bulk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = LibraryStore.shared
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func putBooks(_ count: Int) throws -> [BookID] {
        let source = TestPaths.fixture("epub3-basic.epub")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path))
        return try (0 ..< count).map { at in
            let url = root.appendingPathComponent("\(at).epub")
            try FileManager.default.copyItem(at: source, to: url)
            XCTAssertTrue(store.register(url))
            return BookID(url: url)
        }
    }

    func test_選んだものだけをまとめて外す() throws {
        let ids = try putBooks(5)
        defer { store.remove(Set(ids)) }

        store.remove(Set(ids.prefix(3)))

        for id in ids.prefix(3) { XCTAssertNil(store.entry(for: id), "外れていない") }
        for id in ids.suffix(2) { XCTAssertNotNil(store.entry(for: id), "選んでいないものまで外している") }
    }

    func test_空を渡しても何も起きない() throws {
        let ids = try putBooks(2)
        defer { store.remove(Set(ids)) }
        store.remove(Set<BookID>())
        for id in ids { XCTAssertNotNil(store.entry(for: id)) }
    }
}
