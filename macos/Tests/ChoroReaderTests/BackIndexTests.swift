import PDFKit
import XCTest
@testable import ChoroReader

/// 巻末の用語索引を見つけるところ。
///
/// **入れないと決めた紙面を、確実に外す。** 外しすぎると本文が消えるので、
/// 「拾う」より「拾いすぎない」方を厚く見る。
final class BackIndexTests: XCTestCase {
    private func entry(_ title: String, _ href: String) -> TOCEntry {
        TOCEntry(title: title, href: href)
    }

    private func publication(order: [String], toc: [TOCEntry]) -> EPUBPublication {
        EPUBPublication(title: "架空の本", authors: [], language: "ja", identifier: nil,
                        readingOrder: order.map { Link(href: $0, mediaType: "application/xhtml+xml") },
                        tableOfContents: toc, coverHref: nil,
                        layout: .reflowable, direction: .ltr)
    }

    private var chapters: [String] {
        (1 ... 10).map { "OEBPS/c\($0).xhtml" } + ["OEBPS/index.xhtml", "OEBPS/colophon.xhtml"]
    }

    // MARK: - 名前

    func test_索引の名前を見分ける() {
        for name in ["索引", "さくいん", "用語索引", "事項索引", "Index", "index", " 索 引 ", "　索引　"] {
            XCTAssertTrue(BackIndex.isIndexName(name), "「\(name)」を索引と見なせていない")
        }
    }

    /// **部分一致にしない。** 「索引の作り方」のような節を巻き込む。
    func test_索引を含むだけの見出しは索引ではない() {
        for name in ["索引の作り方", "全文索引", "索引と検索", "Indexing", "付録", ""] {
            XCTAssertFalse(BackIndex.isIndexName(name), "「\(name)」を索引と見なしている")
        }
    }

    // MARK: - EPUB

    func test_目次から索引の範囲を取る() throws {
        let made = try XCTUnwrap(BackIndex.range(in: publication(order: chapters, toc: [
            entry("第 1 章", "OEBPS/c1.xhtml"),
            entry("索引", "OEBPS/index.xhtml"),
            entry("奥付", "OEBPS/colophon.xhtml"),
        ])))
        XCTAssertEqual(made, 10 ..< 11, "索引の章だけを外していない")
    }

    /// 次の項目が無ければ本の末尾まで。
    func test_索引の後に項目が無ければ末尾まで() throws {
        let made = try XCTUnwrap(BackIndex.range(in: publication(order: chapters, toc: [
            entry("第 1 章", "OEBPS/c1.xhtml"),
            entry("索引", "OEBPS/index.xhtml"),
        ])))
        XCTAssertEqual(made, 10 ..< 12)
    }

    /// **巻末に無ければ触らない。** 本文の途中の「索引」の節は本文である。
    func test_本文の途中の索引は外さない() {
        let made = BackIndex.range(in: publication(order: chapters, toc: [
            entry("索引とは何か", "OEBPS/c2.xhtml"),
            entry("索引", "OEBPS/c3.xhtml"),
        ]))
        XCTAssertNil(made, "本文の途中を外している")
    }

    func test_索引が無ければ何も外さない() {
        let made = BackIndex.range(in: publication(order: chapters, toc: [
            entry("第 1 章", "OEBPS/c1.xhtml"),
            entry("奥付", "OEBPS/colophon.xhtml"),
        ]))
        XCTAssertNil(made)
    }

    /// 目次が空でも落ちないこと。目次を持たない本はある。
    func test_目次が無ければ何も外さない() {
        XCTAssertNil(BackIndex.range(in: publication(order: chapters, toc: [])))
    }

    // MARK: - PDF

    /// ページごとの節の見出しから、始まりと終わりが決まること。
    func test_ページの見出しから索引の範囲を取る() throws {
        var titles = [String](repeating: "第 1 章", count: 100)
        for page in 95 ..< 99 { titles[page] = "索引" }
        titles[99] = "奥付"
        XCTAssertEqual(BackIndex.range(pageTitles: titles), 95 ..< 99)
    }

    /// 最後まで索引のとき。
    func test_索引が最後まで続く() throws {
        var titles = [String](repeating: "第 1 章", count: 100)
        for page in 96 ..< 100 { titles[page] = "索引" }
        XCTAssertEqual(BackIndex.range(pageTitles: titles), 96 ..< 100)
    }

    func test_本文の途中の索引の節は外さない() {
        var titles = [String](repeating: "第 1 章", count: 100)
        for page in 20 ..< 24 { titles[page] = "索引" }
        XCTAssertNil(BackIndex.range(pageTitles: titles), "本文の途中を外している")
    }

    func test_見出しが無くても落ちない() {
        XCTAssertNil(BackIndex.range(pageTitles: []))
        XCTAssertNil(BackIndex.range(pageTitles: [String](repeating: "", count: 10)))
    }
}
