import XCTest
@testable import ChoroReader

/// 覚えたフォルダと書棚の差分。
///
/// ここが間違うと、まだある本を「見つからない」と言ったり、
/// 場所が変わった本を二重に並べたりする。外す提案の的が外れると本を失う。
@MainActor
final class FolderSyncTests: XCTestCase {
    private var root: URL!
    private var store: LibraryStore!
    private var added: [BookID] = []

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("choro-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = LibraryStore.shared
    }

    override func tearDownWithError() throws {
        for id in added { store.remove(id) }
        added = []
        try? FileManager.default.removeItem(at: root)
    }

    /// 本物の EPUB を置く。書棚へ加えるには中身が要る。
    @discardableResult
    private func putBook(_ name: String) throws -> URL {
        let source = TestPaths.fixture("epub3-basic.epub")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path))
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }

    private func register(_ url: URL) {
        XCTAssertTrue(store.register(url))
        added.append(BookID(url: url))
    }

    func test_新しい書籍を増えたに数える() throws {
        let url = try putBook("新しい.epub")
        let plan = FolderSync.plan(folders: [root], store: store)
        XCTAssertEqual(plan.added.map(\.lastPathComponent), ["新しい.epub"])
        XCTAssertTrue(plan.missing.isEmpty)
        _ = url
    }

    func test_既にある書籍は増えたに数えない() throws {
        let url = try putBook("ある.epub")
        register(url)
        let plan = FolderSync.plan(folders: [root], store: store)
        XCTAssertTrue(plan.added.isEmpty, "二重に加えようとしている")
        XCTAssertTrue(plan.missing.isEmpty)
    }

    func test_消えた書籍を見つからないに数える() throws {
        let url = try putBook("消える.epub")
        register(url)
        try FileManager.default.removeItem(at: url)

        let plan = FolderSync.plan(folders: [root], store: store)
        XCTAssertEqual(plan.missing.map(\.path), [url.path])
    }

    /// 覚えたフォルダの外から開いた書籍は、同期の対象にしない。
    /// そこまで「見つからない」と言い出すと、外す提案が的外れになる。
    func test_フォルダの外の書籍には手を出さない() throws {
        let outside = try putBook("外/よそ.epub")
        register(outside)
        let inside = root.appendingPathComponent("中", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)

        let plan = FolderSync.plan(folders: [inside], store: store)
        XCTAssertTrue(plan.missing.isEmpty, "フォルダの外の書籍を外そうとしている")
    }

    /// 場所が変わった書籍は、二重に並べず付け替える。
    ///
    /// しおり（Security-Scoped Bookmark）が移動を追えることに乗っている。
    /// 追えなくなると「見つからない」＋「増えた」に割れ、読書位置が置き去りになる。
    func test_移動した書籍は付け替える() throws {
        let from = try putBook("元.epub")
        register(from)
        let id = BookID(url: from)
        let to = root.appendingPathComponent("下/先.epub")
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: from, to: to)
        added.append(BookID(url: to))

        let plan = FolderSync.plan(folders: [root], store: store)
        XCTAssertTrue(plan.added.isEmpty, "移動した書籍を二重に加えようとしている")
        XCTAssertTrue(plan.missing.isEmpty, "移動した書籍を見失っている")
        XCTAssertEqual(plan.moved.map { $0.to.lastPathComponent }, ["先.epub"])

        FolderSync.apply(plan, to: store, removeMissing: false)
        XCTAssertNil(store.entry(for: id), "古い場所の項目が残っている")
        let moved = try XCTUnwrap(store.entry(for: BookID(url: to)))
        XCTAssertEqual(moved.title, "基本の書籍", "持ち物を連れていっていない")
    }

    func test_変わりが無ければ空になる() throws {
        register(try putBook("そのまま.epub"))
        XCTAssertTrue(FolderSync.plan(folders: [root], store: store).isEmpty)
    }

    func test_道筋が下にあるかを見分ける() {
        let base = URL(fileURLWithPath: "/tmp/蔵書")
        XCTAssertTrue(FolderSync.isUnder("/tmp/蔵書/a.epub", [base]))
        XCTAssertTrue(FolderSync.isUnder("/tmp/蔵書/技術評論社/b.epub", [base]))
        XCTAssertFalse(FolderSync.isUnder("/tmp/蔵書2/c.epub", [base]), "名前の頭が同じだけで下と見なしている")
        XCTAssertFalse(FolderSync.isUnder("/tmp/ほか/d.epub", [base]))
    }

    /// 当てるところ。既定では外さない。
    func test_外すかどうかは選べる() throws {
        let url = try putBook("消える.epub")
        register(url)
        let id = BookID(url: url)
        try FileManager.default.removeItem(at: url)
        let plan = FolderSync.plan(folders: [root], store: store)

        FolderSync.apply(plan, to: store, removeMissing: false)
        XCTAssertNotNil(store.entry(for: id), "外さない約束なのに外している")

        FolderSync.apply(plan, to: store, removeMissing: true)
        XCTAssertNil(store.entry(for: id), "外していない")
    }
}

/// 覚えたフォルダの持ち方。
@MainActor
final class WatchedFoldersTests: XCTestCase {
    private func fresh() -> WatchedFolders {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("choro-folders-\(UUID().uuidString).json")
        return WatchedFolders(fileURL: url)
    }

    func test_覚えて忘れられる() {
        let folders = fresh()
        folders.remember(URL(fileURLWithPath: "/tmp/蔵書"))
        XCTAssertEqual(folders.folders.map(\.name), ["蔵書"])
        folders.forget("/tmp/蔵書")
        XCTAssertTrue(folders.folders.isEmpty)
    }

    func test_同じところを二度覚えない() {
        let folders = fresh()
        folders.remember(URL(fileURLWithPath: "/tmp/蔵書"))
        folders.remember(URL(fileURLWithPath: "/tmp/蔵書/"))
        XCTAssertEqual(folders.folders.count, 1)
    }

    func test_無いフォルダは解けない() {
        let folders = fresh()
        folders.remember(URL(fileURLWithPath: "/tmp/どこにも無い-\(UUID().uuidString)"))
        XCTAssertNil(folders.resolve(folders.folders[0]))
    }
}
