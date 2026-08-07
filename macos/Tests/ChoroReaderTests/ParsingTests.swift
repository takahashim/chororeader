import XCTest
@testable import ChoroReader

/// 実在する日本語技術書で確認する。合成した EPUB では現実の方言を検出できないため。
///
/// 書籍そのものは再配布できないので、位置をリポジトリへ入れない。
/// `macos/Tests/local-books.json`（追跡しない）か環境変数で渡し、無ければそのテストは飛ばす。
enum Fixtures {
    static var gihyo: String { path(for: "gihyo") }
    static var review: String { path(for: "review") }

    static func archive(_ path: String) throws -> ZipArchive {
        try XCTSkipUnless(!path.isEmpty && FileManager.default.fileExists(atPath: path),
                          "検証用の実書籍がありません。macos/Tests/local-books.json を用意すると実行されます。")
        return try ZipArchive(url: URL(fileURLWithPath: path))
    }

    private static let configured: [String: String] = {
        let file = TestPaths.repositoryRoot.appendingPathComponent("macos/Tests/local-books.json")
        guard let data = try? Data(contentsOf: file),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }()

    private static func path(for key: String) -> String {
        // 環境変数を優先する。CI で別の書籍を指したいときのため。
        if let fromEnvironment = ProcessInfo.processInfo.environment["CHORO_BOOK_\(key.uppercased())"] {
            return fromEnvironment
        }
        return configured[key] ?? ""
    }
}

final class ZipArchiveTests: XCTestCase {
    func testReadsMimetypeAndContainer() throws {
        let archive = try Fixtures.archive(Fixtures.gihyo)

        // mimetype は無圧縮で格納される決まりになっている。
        let mimetype = try archive.read("mimetype")
        XCTAssertEqual(String(data: mimetype, encoding: .utf8), "application/epub+zip")

        // container.xml は deflate 圧縮されている。展開経路の確認になる。
        let container = try archive.read("META-INF/container.xml")
        let text = String(data: container, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("rootfile"), "container.xml を展開できていない")
    }

    func testMissingEntryThrows() throws {
        let archive = try Fixtures.archive(Fixtures.gihyo)
        XCTAssertThrowsError(try archive.read("no/such/file.xhtml"))
    }
}

final class EPUBParserTests: XCTestCase {
    func testParsesGihyoBook() throws {
        let publication = try EPUBParser.parse(Fixtures.archive(Fixtures.gihyo))

        // 書名そのものは書かない。名乗っていることだけを見る。
        // 実在の書籍の題名をリポジトリへ入れると、位置を外へ出さない意味が薄れる。
        XCTAssertFalse(publication.title.isEmpty, "題名を名乗っていない")
        XCTAssertNotEqual(publication.title, "(無題)", "題名を拾えていない")
        XCTAssertGreaterThan(publication.readingOrder.count, 50, "読み順が短すぎる")
        XCTAssertEqual(publication.layout, .reflowable)
        XCTAssertFalse(publication.tableOfContents.isEmpty)

        // spine の href はアーカイブ先頭からのパスへ正規化されている必要がある。
        let first = publication.readingOrder[0].href
        XCTAssertTrue(first.hasPrefix("OEBPS/"), "href が OPF 基準で解決されていない: \(first)")
    }

    func testParsesReVIEWBook() throws {
        let archive = try Fixtures.archive(Fixtures.review)
        let publication = try EPUBParser.parse(archive)

        // spine の itemref は 16 個あるが、1 つは linear="no"（本文の流れに入れない補助ページ）。
        // 読み順からは外し、目次やリンクからは開けるままにする。
        XCTAssertEqual(publication.readingOrder.count, 15)
        XCTAssertFalse(publication.tableOfContents.isEmpty)

        for link in publication.readingOrder {
            XCTAssertTrue(archive.contains(link.href), "読み順の参照先が存在しない: \(link.href)")
        }
    }

    func testTOCEntriesPointAtRealResources() throws {
        let archive = try Fixtures.archive(Fixtures.gihyo)
        let publication = try EPUBParser.parse(archive)

        var checked = 0
        func walk(_ entries: [TOCEntry]) {
            for entry in entries {
                if let href = entry.href {
                    XCTAssertTrue(archive.contains(href), "目次の参照先が存在しない: \(href)")
                    checked += 1
                }
                walk(entry.children)
            }
        }
        walk(publication.tableOfContents)
        XCTAssertGreaterThan(checked, 10, "目次の検証件数が少なすぎる")
    }

    func testResolveNormalizesRelativePaths() {
        XCTAssertEqual(EPUBParser.resolve(base: "OEBPS/text", href: "../images/a.png"), "OEBPS/images/a.png")
        XCTAssertEqual(EPUBParser.resolve(base: "OEBPS/text", href: "./ch01.xhtml"), "OEBPS/text/ch01.xhtml")
        XCTAssertEqual(EPUBParser.resolve(base: "OEBPS", href: "/absolute.xhtml"), "absolute.xhtml")
        XCTAssertEqual(EPUBParser.resolve(base: "a/b/c", href: "../../d.xhtml"), "a/d.xhtml")
        // アーカイブの外へ出ようとする参照は、先頭で止まる。
        XCTAssertEqual(EPUBParser.resolve(base: "", href: "../../etc/passwd"), "etc/passwd")
        XCTAssertEqual(EPUBParser.resolve(base: "OEBPS", href: "text%2Fch01.xhtml"), "OEBPS/text/ch01.xhtml")
    }

    func testStripFragment() {
        XCTAssertEqual(EPUBParser.stripFragment("ch01.xhtml#sec2").path, "ch01.xhtml")
        XCTAssertEqual(EPUBParser.stripFragment("ch01.xhtml#sec2").fragment, "sec2")
        XCTAssertNil(EPUBParser.stripFragment("ch01.xhtml").fragment)
    }
}
