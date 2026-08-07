import XCTest
@testable import ChoroReader

/// 節への切り分け。
///
/// 二字組索引より細かく切る（章ではなく節）ので、既存の検査では守られない。
/// 同梱のサンプルで実際に切ってみる。
final class SemanticUnitsTests: XCTestCase {
    private func sample(_ name: String) throws -> URL {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil))
        return url
    }

    func test_EPUBを節に切る() throws {
        let source = try XCTUnwrap(SearchIndexStore.open(sample("sample-reflowable.epub")))
        // 同梱のサンプルは読み方を見せるためのもので短い。下限を下げて中身を見る。
        let pieces = SemanticUnits.pieces(of: source, leastCharacters: 40)
        XCTAssertFalse(pieces.isEmpty, "1 つも切り出せていない")

        for piece in pieces {
            XCTAssertNotNil(piece.unit.locator.href, "EPUB なのに飛び先に章が無い")
            XCTAssertNil(piece.unit.locator.page)
            XCTAssertFalse(piece.text.isEmpty)
            XCTAssertFalse(piece.unit.excerpt.isEmpty, "見分けるための抜き書きが無い")
            XCTAssertLessThanOrEqual(piece.unit.excerpt.count, 121)
            XCTAssertTrue((0 ... 1).contains(piece.unit.locator.progression),
                          "章内の位置が範囲の外：\(piece.unit.locator.progression)")
        }
    }

    func test_PDFを節に切る() throws {
        let source = try XCTUnwrap(SearchIndexStore.open(sample("sample.pdf")))
        let pieces = SemanticUnits.pieces(of: source, leastCharacters: 40)
        XCTAssertFalse(pieces.isEmpty)
        for piece in pieces {
            XCTAssertNotNil(piece.unit.locator.page, "PDF なのに飛び先に頁が無い")
            XCTAssertNil(piece.unit.locator.href)
        }
    }

    /// 節は章より細かいこと。
    ///
    /// **ここが崩れても動く。** 章のまま切っていても索引はでき、検索も返る。
    /// ただ「この節は何の話か」が混ざるので、静かに質が落ちるだけである。
    func test_見出しで割れている() throws {
        let html = """
        <html><body>
        <p>\(String(repeating: "前書きの文である。", count: 40))</p>
        <h2 id="one">はじめの節</h2>
        <p>\(String(repeating: "はじめの節の本文である。", count: 40))</p>
        <h2>つぎの節</h2>
        <p>\(String(repeating: "つぎの節の本文である。", count: 40))</p>
        </body></html>
        """
        let pieces = SemanticUnits.pieces(of: .epub(resources: OneFile(html: html),
                                                    publication: publication()))
        XCTAssertEqual(pieces.count, 3, "見出しで割れていない")
        XCTAssertEqual(pieces.map(\.unit.heading), ["", "はじめの節", "つぎの節"])
        // 見出しに id があれば、そこへ直に飛ぶ
        XCTAssertEqual(pieces[1].unit.locator.fragment, "one")
        XCTAssertNil(pieces[2].unit.locator.fragment)
        // 位置は章の中で進む
        XCTAssertLessThan(pieces[0].unit.locator.progression, pieces[1].unit.locator.progression)
        XCTAssertLessThan(pieces[1].unit.locator.progression, pieces[2].unit.locator.progression)
        // 節の本文だけが入っていて、隣の節は混ざらない
        XCTAssertTrue(pieces[1].text.contains("はじめの節の本文"))
        XCTAssertFalse(pieces[1].text.contains("つぎの節の本文"))
    }

    /// 短すぎるものは載せない。扉や章番号だけの頁を拾わないため。
    func test_短すぎる節は載せない() throws {
        let html = "<html><body><h2>扉</h2><p>短い。</p></body></html>"
        let pieces = SemanticUnits.pieces(of: .epub(resources: OneFile(html: html),
                                                    publication: publication()))
        XCTAssertTrue(pieces.isEmpty)
    }

    // MARK: - 差し替え

    private func publication() -> EPUBPublication {
        EPUBPublication(title: "架空の本", authors: ["架空太郎"], language: "ja", identifier: nil,
                        readingOrder: [Link(href: "text.xhtml", mediaType: "application/xhtml+xml")],
                        tableOfContents: [], coverHref: nil,
                        layout: .reflowable, direction: .ltr)
    }

    private final class OneFile: ResourceProvider {
        let html: String
        init(html: String) { self.html = html }
        func read(_ path: String) throws -> Data { Data(html.utf8) }
        func contains(_ path: String) -> Bool { true }
    }
}

extension SemanticUnitsTests {
    /// 既定の下限が本当に効いていること。
    /// **下限が 0 になっていても、索引はできるし検索も返る。**
    /// 扉や章番号だけの節が候補に湧くだけなので、検査で押さえる。
    func test_既定の下限が効いている() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sample-reflowable.epub",
                                                  withExtension: nil))
        let source = try XCTUnwrap(SearchIndexStore.open(url))
        XCTAssertGreaterThan(SemanticUnits.pieces(of: source, leastCharacters: 40).count, 0)
        XCTAssertEqual(SemanticUnits.pieces(of: source).count, 0,
                       "サンプルは既定の下限（\(SemanticUnits.defaultLeastCharacters) 字）に届かないはず")
    }
}
