import PDFKit
import XCTest
@testable import ChoroReader

/// 書籍が名乗っていることを、形式ごとに拾えること。
@MainActor
final class BookPropertiesTests: XCTestCase {
    private func properties(_ name: String) throws -> BookProperties {
        let url = TestPaths.fixture(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        let document = try BookDocument(url: url)
        return BookProperties.make(document: document, file: BookProperties.FileFacts.read(url))
    }

    private func value(_ properties: BookProperties, _ label: String) -> String? {
        properties.sections.flatMap(\.items).first { $0.label == label }?.value
    }

    func test_EPUB_の書誌を拾う() throws {
        let found = try properties("epub3-basic.epub")
        XCTAssertEqual(value(found, "題名"), "基本の書籍")
        XCTAssertEqual(value(found, "著者"), "山田 太郎")
        XCTAssertEqual(value(found, "形式"), "リフロー型 EPUB")
        XCTAssertEqual(value(found, "綴じ方向"), "左開き")
        XCTAssertNotNil(value(found, "章の数"))
    }

    func test_右開きと固定レイアウトを見分ける() throws {
        XCTAssertEqual(value(try properties("rtl.epub"), "綴じ方向"), "右開き")
        XCTAssertEqual(value(try properties("fixed-layout.epub"), "形式"), "固定レイアウト EPUB")
    }

    func test_ファイルの素性も並ぶ() throws {
        let found = try properties("epub3-basic.epub")
        XCTAssertEqual(value(found, "名前"), "epub3-basic.epub")
        XCTAssertNotNil(value(found, "大きさ"))
        XCTAssertNotNil(value(found, "場所"))
    }

    /// 名乗っていない項目は並べない。空欄を出しても読む人の役に立たない。
    func test_名乗っていない項目は出さない() throws {
        let found = try properties("epub3-basic.epub")
        for item in found.sections.flatMap(\.items) {
            XCTAssertFalse(item.value.trimmingCharacters(in: .whitespaces).isEmpty,
                           "「\(item.label)」が空のまま並んでいる")
        }
    }

    func test_PDF_のページ数と文字の層を拾う() throws {
        let url = TestPaths.repositoryRoot.appendingPathComponent("samples/sample.pdf")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        let document = try BookDocument(url: url)
        let found = BookProperties.make(document: document, file: BookProperties.FileFacts.read(url))

        XCTAssertEqual(value(found, "形式"), "PDF")
        XCTAssertNotNil(value(found, "ページ数"))
        XCTAssertNotNil(value(found, "版"))
        // 同梱のサンプルは文字を持つ。持たない PDF は検索できないので、そう言う。
        XCTAssertEqual(value(found, "文字の層"), "有り")
        XCTAssertNotNil(value(found, "ページの大きさ"))
    }

    func test_書き写せる形になる() throws {
        let text = try properties("epub3-basic.epub").asText
        XCTAssertTrue(text.contains("書誌"), text)
        XCTAssertTrue(text.contains("基本の書籍"), text)
        XCTAssertTrue(text.contains("ファイル"), text)
    }
}

/// 書棚からは、開いていない書籍のことも尋ねられる。
@MainActor
final class BookPropertiesFromFileTests: XCTestCase {
    private func value(_ properties: BookProperties, _ label: String) -> String? {
        properties.sections.flatMap(\.items).first { $0.label == label }?.value
    }

    func test_開かずにファイルから読める() throws {
        let url = TestPaths.fixture("epub3-basic.epub")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        let found = BookProperties.read(url)
        XCTAssertEqual(value(found, "題名"), "基本の書籍")
        XCTAssertEqual(value(found, "名前"), "epub3-basic.epub")
    }

    /// 開けない書籍でも、ファイルの素性までは出す。何も出ないより手掛かりになる。
    func test_開けない書籍でもファイルの素性は出す() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("choro-壊れた.epub")
        try Data("これは EPUB ではない".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let found = BookProperties.read(url)
        XCTAssertEqual(value(found, "名前"), "choro-壊れた.epub")
        XCTAssertNil(value(found, "題名"), "開けていないのに書誌が出ている")
    }
}
