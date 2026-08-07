import XCTest
@testable import ChoroReader

/// 当たった段落の本文を、原書から切り出すところ。
///
/// **索引に控えないと決めた代わりに、ここが効かないと一覧が空欄で並ぶ。**
/// 目印が外れることはある（組み方の都合で本文が一致しない）ので、
/// そのときも何かは出ることを押さえる。
final class PassageTextTests: XCTestCase {
    private func book(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("choro-passage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("META-INF"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("OEBPS"),
                                                withIntermediateDirectories: true)
        func put(_ t: String, _ p: String) throws {
            try Data(t.utf8).write(to: directory.appendingPathComponent(p))
        }
        try put("application/epub+zip", "mimetype")
        try put("<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>",
                "META-INF/container.xml")
        try put("<?xml version=\"1.0\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"id\">urn:uuid:k</dc:identifier><dc:title>架空</dc:title><dc:language>ja</dc:language></metadata><manifest><item id=\"t\" href=\"text.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"t\"/></spine></package>",
                "OEBPS/content.opf")
        try put("<?xml version=\"1.0\" encoding=\"utf-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>架空</title></head><body>\(body)</body></html>",
                "OEBPS/text.xhtml")

        let url = directory.appendingPathComponent("book.epub")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = directory
        zip.arguments = ["-q", "-X", url.path, "mimetype", "META-INF/container.xml",
                         "OEBPS/content.opf", "OEBPS/text.xhtml"]
        try zip.run()
        zip.waitUntilExit()
        return url
    }

    /// その段落のところから切り出すこと。
    ///
    /// **繰り返しの多い本文で外れやすい。** 目印だけで探すと手前の同じ並びに当たるので、
    /// わざと「先頭の段落である。」が続く本文で試す（実際にこれで捕まえた）。
    func test_その段落のところから切り出す() throws {
        let body = "<p>" + String(repeating: "先頭の段落である。", count: 60) + "</p><p>"
            + String(repeating: "二つめの段落である。", count: 60) + "</p>"
        let url = try book(body)
        let pieces = SemanticUnits.pieces(of: try XCTUnwrap(SearchIndexStore.open(url)))
        XCTAssertGreaterThan(pieces.count, 1)

        let read = PassageText.read(pieces.map(\.unit), from: url)
        XCTAssertEqual(read.count, pieces.count, "読めていない単位がある")
        for (at, piece) in pieces.enumerated() {
            let head = try XCTUnwrap(read[at]).replacingOccurrences(of: "…", with: "")
            XCTAssertTrue(piece.text.hasPrefix(head), "その段落の頭から切り出せていない")
        }
        // 後ろの段落は、後ろの文から始まる
        let last = try XCTUnwrap(read[pieces.count - 1])
        XCTAssertTrue(last.hasPrefix("二つめ"), "先頭の段落が出ている")
    }

    /// 長さに頭を打つこと。
    func test_長さに頭を打つ() throws {
        let url = try book("<p>" + String(repeating: "架空の一節である。", count: 200) + "</p>")
        let pieces = SemanticUnits.pieces(of: try XCTUnwrap(SearchIndexStore.open(url)))
        let read = PassageText.read(pieces.map(\.unit), from: url, limit: 40)
        for text in read.values {
            XCTAssertLessThanOrEqual(text.count, 41, "頭を打てていない")
        }
    }

    /// **目印が外れても何かは出す。** 空欄が並ぶより、章の頭が出ている方がましである。
    func test_目印が外れても何かは出す() throws {
        let url = try book("<p>" + String(repeating: "架空の一節である。", count: 60) + "</p>")
        var unit = try XCTUnwrap(SemanticUnits.pieces(of: try XCTUnwrap(SearchIndexStore.open(url))).first).unit
        unit.locator.text = "この本には出てこない文字列である"

        let read = PassageText.read([unit], from: url)
        let text = try XCTUnwrap(read[0], "外れたら何も出さなくなっている")
        XCTAssertTrue(text.hasPrefix("架空の一節"))
    }

    func test_読めない書籍では何も返さない() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("choro-none.epub")
        let unit = SemanticUnit(locator: Locator(href: "text.xhtml", progression: 0), heading: "")
        XCTAssertTrue(PassageText.read([unit], from: missing).isEmpty)
    }
}
