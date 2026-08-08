import XCTest
@testable import ChoroReader

/// 「いま読んでいるのはどの段落か」の判定。
///
/// 関連箇所は**選んだところ**から引くようにしたので、この判定は主役ではなくなった。
/// それでも位置から種を採る道は残してあり、**1 つずれても症状は出ない**
/// （それらしい結果が出て、静かに的が外れるだけである）。
final class RelatedPassagesTests: XCTestCase {
    private func index(_ units: [SemanticUnit]) -> SemanticIndex {
        SemanticIndex(model: "m", dimension: 2, units: units,
                      vectors: Array(repeating: Float(0), count: units.count * 2), truncated: 0)
    }

    private func epub(_ href: String, _ progression: Double, _ heading: String) -> SemanticUnit {
        SemanticUnit(locator: Locator(href: href, progression: progression),
                     heading: heading, section: 0)
    }

    private func pdf(_ page: Int, _ heading: String) -> SemanticUnit {
        SemanticUnit(locator: Locator(page: page, progression: Double(page) / 100),
                     heading: heading, section: 0)
    }

    // MARK: - EPUB

    func test_章の中で位置を越えない最後の段落を選ぶ() {
        let made = index([
            epub("ch1.xhtml", 0.0, "一の一"),
            epub("ch1.xhtml", 0.4, "一の二"),
            epub("ch1.xhtml", 0.8, "一の三"),
            epub("ch2.xhtml", 0.0, "二の一"),
        ])
        func heading(at progression: Double, _ href: String = "ch1.xhtml") -> String? {
            RelatedPassages.unit(for: Locator(href: href, progression: progression), in: made)
                .map { made.units[$0].heading }
        }
        XCTAssertEqual(heading(at: 0.0), "一の一")
        XCTAssertEqual(heading(at: 0.39), "一の一")
        XCTAssertEqual(heading(at: 0.4), "一の二", "段落の頭ちょうどで前の段落を選んでいる")
        XCTAssertEqual(heading(at: 0.79), "一の二")
        XCTAssertEqual(heading(at: 1.0), "一の三")
        XCTAssertEqual(heading(at: 0.5, "ch2.xhtml"), "二の一", "章を跨いで選んでいる")
    }

    /// 章の頭に段落が無いことがある（前書きが短くて落ちたとき）。
    /// **そこで諦めると、章の頭では種が採れない。**
    func test_章の頭に段落が無ければその章の最初を選ぶ() {
        let made = index([
            epub("ch1.xhtml", 0.5, "一の二"),
            epub("ch2.xhtml", 0.3, "二の一"),
        ])
        let at = RelatedPassages.unit(for: Locator(href: "ch2.xhtml", progression: 0.0), in: made)
        XCTAssertEqual(at.map { made.units[$0].heading }, "二の一")
    }

    func test_知らない章なら選ばない() {
        let made = index([epub("ch1.xhtml", 0.0, "一の一")])
        XCTAssertNil(RelatedPassages.unit(for: Locator(href: "ch9.xhtml", progression: 0.5), in: made))
    }

    // MARK: - PDF

    func test_頁を越えない最後の段落を選ぶ() {
        let made = index([pdf(0, "はじめ"), pdf(10, "なか"), pdf(20, "おわり")])
        func heading(atPage page: Int) -> String? {
            RelatedPassages.unit(for: Locator(page: page, progression: 0), in: made)
                .map { made.units[$0].heading }
        }
        XCTAssertEqual(heading(atPage: 0), "はじめ")
        XCTAssertEqual(heading(atPage: 9), "はじめ")
        XCTAssertEqual(heading(atPage: 10), "なか", "段落の頭ちょうどで前の段落を選んでいる")
        XCTAssertEqual(heading(atPage: 30), "おわり")
    }

    /// 索引の最初の段落より前の頁にいることがある（表紙・目次）。
    func test_最初の段落より前なら最初を選ぶ() {
        let made = index([pdf(5, "はじめ"), pdf(10, "なか")])
        let at = RelatedPassages.unit(for: Locator(page: 0, progression: 0), in: made)
        XCTAssertEqual(at.map { made.units[$0].heading }, "はじめ")
    }

    func test_空の索引では選ばない() {
        XCTAssertNil(RelatedPassages.unit(for: Locator(page: 3, progression: 0), in: index([])))
    }
}

/// 渡されたベクトルから、他の書籍の近い箇所を選ぶところ。
extension RelatedPassagesTests {
    /// 遠いものを出さないこと。
    ///
    /// **下を切らないと、蔵書のどこかしらが必ず並ぶ。**
    /// 関係の無いものが常に出ると、出ていること自体が信用されなくなる。
    func test_下限が効いている() {
        for limits in [SemanticFinder.Limits.related, .search] {
            XCTAssertGreaterThan(limits.leastScore, 0.3, "下限が緩すぎる。何でも並ぶことになる")
            XCTAssertLessThan(limits.leastScore, 0.9, "下限が厳しすぎる。まず出なくなる")
            XCTAssertGreaterThan(limits.perBook, 0)
            XCTAssertGreaterThan(limits.total, limits.perBook)
        }
        // 関連箇所は本文どうし（同じ接頭辞）なので点が高く出る。下限もそのぶん高い。
        XCTAssertGreaterThan(SemanticFinder.Limits.related.leastScore,
                             SemanticFinder.Limits.search.leastScore)
    }
}
