import XCTest
@testable import ChoroReader

/// 段落への切り分け。
///
/// **粒度が粗くても症状は出ない。** 索引はできるし検索も返る。
/// ただ節を単位にしていた頃は、着いた先が節の頭で、一覧に出る文も節の冒頭だった。
/// なぜ当たったのかが見えないので、渡る理由が立たない。
///
/// 段落であること・飛び先が段落を指すこと・出す文が当たった段落そのものであること、を押さえる。
final class SemanticUnitsTests: XCTestCase {
    private func sample(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil))
    }

    /// 節ではなく段落に切れていること。
    func test_節を段落に割る() throws {
        // 狙いの長さ（400 字）の何倍かにする。短いと 1 つに収まって、割れているか分からない。
        let body = (0 ..< 24)
            .map { "これは架空の技術書の第 \($0) 段落である。" + String(repeating: "説明が続く。", count: 12) }
            .joined(separator: "\n")
        let pieces = SemanticUnits.pieces(of: .epub(resources: OneFile("<h2>架空の節</h2><p>\(body)</p>"),
                                                    publication: publication()))
        XCTAssertGreaterThan(pieces.count, 3, "節がまるごと 1 単位になっている")
        for piece in pieces {
            XCTAssertEqual(piece.unit.heading, "架空の節", "どの節の話かが失われている")
            // 極端に長い単位は「平均されたベクトル」になり、的が絞れない
            XCTAssertLessThan(piece.text.count, SemanticUnits.targetCharacters * 3,
                              "段落が長すぎる：\(piece.text.count) 字")
            XCTAssertGreaterThanOrEqual(piece.text.count, SemanticUnits.defaultLeastCharacters)
        }
    }

    /// **索引に本文を控えないこと。**
    ///
    /// 一度は抜き書き 160 字を控えていて、測ると本の 35% が原文のまま入っていた。
    /// 二字組索引が本文を持たないのと揃える。持つのは飛び先の目印（30 字）だけで、
    /// これは寄せるために要るものである。
    func test_索引に本文を控えない() throws {
        let body = String(repeating: "先頭の段落である。", count: 60) + "\n"
            + String(repeating: "二つめの段落である。", count: 60)
        let pieces = SemanticUnits.pieces(of: .epub(resources: OneFile("<p>\(body)</p>"),
                                                    publication: publication()))
        XCTAssertGreaterThan(pieces.count, 1)

        let bodyChars = pieces.reduce(0) { $0 + $1.text.count }
        let keptChars = pieces.reduce(0) { $0 + ($1.unit.locator.text?.count ?? 0) + $1.unit.heading.count }
        let kept = Double(keptChars) / Double(bodyChars)
        XCTAssertLessThan(kept, 0.15, "本文を控えすぎている（\(Int(kept * 100))%）")
    }

    /// 飛び先に本文の目印が載ること。
    /// **これが無いと、着くのは章やページの頭までである。**
    func test_飛び先に本文の目印が載る() throws {
        let body = String(repeating: "架空の一節である。", count: 30)
        let pieces = SemanticUnits.pieces(of: .epub(resources: OneFile("<p>\(body)</p>"),
                                                    publication: publication()))
        let first = try XCTUnwrap(pieces.first)
        let anchor = try XCTUnwrap(first.unit.locator.text)
        XCTAssertTrue(first.text.hasPrefix(anchor), "目印が段落の頭と一致しない")
        // 長すぎる目印は、組み方の違いで一致しなくなる
        XCTAssertLessThanOrEqual(anchor.count, 30)
    }

    /// 章の中で位置が進むこと。目印が外れたときの落ち先になる。
    func test_章の中で位置が進む() throws {
        let body = (0 ..< 8).map { _ in String(repeating: "架空の一節である。", count: 30) }
            .joined(separator: "\n")
        let pieces = SemanticUnits.pieces(of: .epub(resources: OneFile("<p>\(body)</p>"),
                                                    publication: publication()))
        let progressions = pieces.map(\.unit.locator.progression)
        XCTAssertEqual(progressions, progressions.sorted(), "位置が進んでいない")
        XCTAssertEqual(progressions.first ?? -1, 0, accuracy: 1e-6)
        XCTAssertLessThan(progressions.last ?? 2, 1)
    }

    /// 短い切れ端を独り立ちさせないこと。
    /// **させると、文脈の無いベクトルが索引を埋める。**
    func test_短い切れ端は前に足す() throws {
        let body = String(repeating: "本体の段落である。", count: 50) + "\n短い。"
        let pieces = SemanticUnits.pieces(of: .epub(resources: OneFile("<p>\(body)</p>"),
                                                    publication: publication()))
        XCTAssertFalse(pieces.contains { $0.text.count < SemanticUnits.defaultLeastCharacters },
                       "短い切れ端が独り立ちしている")
        XCTAssertTrue(pieces.last!.text.hasSuffix("短い。"), "端数が捨てられている")
    }

    func test_短すぎる本文は載せない() throws {
        let pieces = SemanticUnits.pieces(of: .epub(resources: OneFile("<h2>扉</h2><p>短い。</p>"),
                                                    publication: publication()))
        XCTAssertTrue(pieces.isEmpty)
    }

    // MARK: - 実物

    /// PDF はページごとに切ること。
    /// **節の範囲でまとめると、着いた先が節の頭になる。**
    func test_PDFはページごとに切る() throws {
        let source = try XCTUnwrap(SearchIndexStore.open(sample("sample.pdf")))
        let pieces = SemanticUnits.pieces(of: source, leastCharacters: 20)
        XCTAssertFalse(pieces.isEmpty)
        for piece in pieces {
            XCTAssertNotNil(piece.unit.locator.page, "PDF なのに飛び先に頁が無い")
            XCTAssertNil(piece.unit.locator.href)
        }
    }

    func test_EPUBを切れる() throws {
        let source = try XCTUnwrap(SearchIndexStore.open(sample("sample-reflowable.epub")))
        let pieces = SemanticUnits.pieces(of: source, leastCharacters: 40)
        XCTAssertFalse(pieces.isEmpty)
        for piece in pieces {
            XCTAssertNotNil(piece.unit.locator.href)
            XCTAssertNotNil(piece.unit.locator.text, "寄せるための目印が無い")
        }
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
        init(_ body: String) { html = "<html><body>\(body)</body></html>" }
        func read(_ path: String) throws -> Data { Data(html.utf8) }
        func contains(_ path: String) -> Bool { true }
    }
}
