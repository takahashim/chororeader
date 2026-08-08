import XCTest
@testable import ChoroReader

/// 点を並びに直すところ。**モデルが無くても回る。**
///
/// 推論の一致は `CrossEncoderTests` が見る。ここで見るのは、その点を
/// どう並びに直すかである。落とす・取り違えるといった事故はこちら側で起きる。
final class RerankingTests: XCTestCase {
    private func passage(_ name: String, score: Float) -> RelatedPassage {
        RelatedPassage(book: LibraryEntry(id: BookID(url: URL(fileURLWithPath: "/架空/\(name).epub")),
                                          path: "/架空/\(name).epub", bookmarkData: nil,
                                          title: name, authors: [], format: .reflowableEPUB,
                                          lastOpenedAt: Date(timeIntervalSince1970: 0)),
                       unit: SemanticUnit(locator: Locator(href: "OEBPS/\(name).xhtml",
                                                           progression: 0.1, text: name),
                                          heading: "", section: 0),
                       score: score)
    }

    func test_点の高い順に並べ直す() {
        let candidates = [passage("あ", score: 0.9), passage("い", score: 0.8),
                          passage("う", score: 0.7)]
        let made = Reranking.order(candidates, scored: candidates, by: [-3, 5, 1])
        XCTAssertEqual(made.passages.map(\.book.title), ["い", "う", "あ"])
    }

    /// **元の順位を控えること。** 効いたかどうかは、動いた幅でしか見せられない。
    func test_元の順位を控える() {
        let candidates = [passage("あ", score: 0.9), passage("い", score: 0.8)]
        let made = Reranking.order(candidates, scored: candidates, by: [0, 1])
        XCTAssertEqual(made.wasAt[candidates[0].id], 0)
        XCTAssertEqual(made.wasAt[candidates[1].id], 1)
    }

    /// **本文を読めなかった候補は末尾へ回す。落とさない。**
    ///
    /// 意味検索は件数を出さないので、黙って減らすと人は気付けない。
    func test_点の付かなかった候補も残る() {
        let candidates = [passage("あ", score: 0.9), passage("い", score: 0.8),
                          passage("う", score: 0.7)]
        // 「い」だけ本文が読めなかった場面。
        let ready = [candidates[0], candidates[2]]
        let made = Reranking.order(candidates, scored: ready, by: [-1, 4])
        XCTAssertEqual(made.passages.map(\.book.title), ["う", "あ", "い"])
        XCTAssertNil(made.relevance[candidates[1].id], "点の無いものに点が付いている")
    }

    /// 均す向き。**逆にすると並びが裏返る。**
    func test_均した値は点の順を保つ() {
        XCTAssertEqual(Reranking.relevance(0), 0.5, accuracy: 1e-6)
        XCTAssertGreaterThan(Reranking.relevance(5), Reranking.relevance(-9))
        XCTAssertGreaterThan(Reranking.relevance(-2), 0)
        XCTAssertLessThan(Reranking.relevance(9), 1)
    }

    /// 均しても順は変わらないこと。表示の点と並びが食い違うと、壊れて見える。
    func test_均した後も並びは同じ() {
        let candidates = [passage("あ", score: 0.9), passage("い", score: 0.8),
                          passage("う", score: 0.7)]
        let scores: [Float] = [-3, 5, 1]
        let made = Reranking.order(candidates, scored: candidates, by: scores)
        let shown = made.passages.compactMap { made.relevance[$0.id] }
        XCTAssertEqual(shown, shown.sorted(by: >), "点の並びと行の並びが食い違う")
    }
}
