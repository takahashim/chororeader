import XCTest
@testable import ChoroReader

/// 「いま読んでいるのはどの節か」の判定。
///
/// **ここが 1 つずれても症状が出ない。** 関連箇所は出るし、それらしくも見える。
/// ただ隣の節を種にしているので、静かに的が外れるだけである。
final class RelatedPassagesTests: XCTestCase {
    private func index(_ units: [SemanticUnit]) -> SemanticIndex {
        SemanticIndex(model: "m", dimension: 2, units: units,
                      vectors: Array(repeating: Float(0), count: units.count * 2), truncated: 0)
    }

    private func epub(_ href: String, _ progression: Double, _ heading: String) -> SemanticUnit {
        SemanticUnit(locator: Locator(href: href, progression: progression),
                     heading: heading, excerpt: "架空の抜き書き")
    }

    private func pdf(_ page: Int, _ heading: String) -> SemanticUnit {
        SemanticUnit(locator: Locator(page: page, progression: Double(page) / 100),
                     heading: heading, excerpt: "架空の抜き書き")
    }

    // MARK: - EPUB

    func test_章の中で位置を越えない最後の節を選ぶ() {
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
        XCTAssertEqual(heading(at: 0.4), "一の二", "節の頭ちょうどで前の節を選んでいる")
        XCTAssertEqual(heading(at: 0.79), "一の二")
        XCTAssertEqual(heading(at: 1.0), "一の三")
        XCTAssertEqual(heading(at: 0.5, "ch2.xhtml"), "二の一", "章を跨いで選んでいる")
    }

    /// 章の頭に節が無いことがある（前書きが短くて落ちたとき）。
    /// **そこで諦めると、章の頭では関連箇所が出ない。**
    func test_章の頭に節が無ければその章の最初を選ぶ() {
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

    func test_頁を越えない最後の節を選ぶ() {
        let made = index([pdf(0, "はじめ"), pdf(10, "なか"), pdf(20, "おわり")])
        func heading(atPage page: Int) -> String? {
            RelatedPassages.unit(for: Locator(page: page, progression: 0), in: made)
                .map { made.units[$0].heading }
        }
        XCTAssertEqual(heading(atPage: 0), "はじめ")
        XCTAssertEqual(heading(atPage: 9), "はじめ")
        XCTAssertEqual(heading(atPage: 10), "なか", "節の頭ちょうどで前の節を選んでいる")
        XCTAssertEqual(heading(atPage: 30), "おわり")
    }

    /// 索引の最初の節より前の頁にいることがある（表紙・目次）。
    func test_最初の節より前なら最初を選ぶ() {
        let made = index([pdf(5, "はじめ"), pdf(10, "なか")])
        let at = RelatedPassages.unit(for: Locator(page: 0, progression: 0), in: made)
        XCTAssertEqual(at.map { made.units[$0].heading }, "はじめ")
    }

    func test_空の索引では選ばない() {
        XCTAssertNil(RelatedPassages.unit(for: Locator(page: 3, progression: 0), in: index([])))
    }
}
