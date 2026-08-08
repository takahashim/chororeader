import XCTest
@testable import ChoroReader

/// 近さで並べる規則。
///
/// **以前は蔵書を自分で取りに行っていて差し替えられず、検査が書けなかった。**
/// そのせいで「自分の索引が無いと必ず空になる」という不具合が、
/// 使ってみるまで分からなかった。渡してもらう形にしたので、ここで押さえる。
final class SemanticFinderTests: XCTestCase {
    private func entry(_ name: String) -> LibraryEntry {
        LibraryEntry(id: BookID(url: URL(fileURLWithPath: "/tmp/\(name).epub")),
                     path: "/tmp/\(name).epub", bookmarkData: nil,
                     title: name, authors: [], format: .reflowableEPUB,
                     lastOpenedAt: Date(timeIntervalSince1970: 0))
    }

    /// 指した向きだけが立っている索引。dimension 次元のうち `axes` 番目を 1 にする。
    private func index(_ axes: [Int], dimension: Int = 4) -> SemanticIndex {
        var units: [SemanticUnit] = []
        var vectors: [Float] = []
        for (at, axis) in axes.enumerated() {
            units.append(SemanticUnit(locator: Locator(page: at, progression: 0),
                                      heading: "第 \(at) 節", section: at))
            var one = [Float](repeating: 0, count: dimension)
            one[axis] = 1
            vectors.append(contentsOf: one)
        }
        return SemanticIndex(model: "m", dimension: dimension, units: units,
                             vectors: vectors, truncated: 0)
    }

    private func query(_ axis: Int, dimension: Int = 4) -> [Float] {
        var made = [Float](repeating: 0, count: dimension)
        made[axis] = 1
        return made
    }

    private let loose = SemanticFinder.Limits(perBook: 2, leastScore: 0.5, total: 10)

    func test_近い順に並ぶ() {
        let found = SemanticFinder.rank(query(1), over: [
            (entry("a"), index([0, 1])),   // 1 本目に一致する向きがある
            (entry("b"), index([2, 3])),   // 一致しない
        ], limits: loose)
        XCTAssertEqual(found.count, 1, "遠いものまで出ている")
        XCTAssertEqual(found.first?.book.title, "a")
        XCTAssertEqual(found.first?.score ?? 0, 1, accuracy: 1e-5)
    }

    /// 1 冊が結果を埋め尽くさないこと。
    func test_1冊からの数に頭を打つ() {
        let found = SemanticFinder.rank(query(0), over: [(entry("a"), index([0, 0, 0, 0, 0]))],
                                        limits: SemanticFinder.Limits(perBook: 2, leastScore: 0.5, total: 10))
        XCTAssertEqual(found.count, 2, "1 冊から出しすぎている")
    }

    func test_全体の数にも頭を打つ() {
        let books = (0 ..< 8).map { (entry("b\($0)"), index([0])) }
        let found = SemanticFinder.rank(query(0), over: books,
                                        limits: SemanticFinder.Limits(perBook: 2, leastScore: 0.5, total: 3))
        XCTAssertEqual(found.count, 3)
    }

    /// **次元は問いの側で決まる。**
    ///
    /// 以前は「手本の索引」を渡させていて、自分の索引がまだ無いときに
    /// 次元 0 の偽物を渡すことになり、どの書籍とも一致せず黙って空が返った。
    /// いちばん使いたい場面（自分の本を読み込む前）でそうなっていた。
    func test_自分の索引が無くても引ける() {
        let found = SemanticFinder.rank(query(1), over: [(entry("a"), index([1]))], limits: loose)
        XCTAssertEqual(found.count, 1, "自分の索引が無いと引けない作りに戻っている")
    }

    /// 次元の違う索引は混ぜない。**混ぜると、ずれた内積が黙って返る。**
    func test_次元の違う索引は混ぜない() {
        let found = SemanticFinder.rank(query(0, dimension: 4),
                                        over: [(entry("a"), index([0], dimension: 8))], limits: loose)
        XCTAssertTrue(found.isEmpty)
    }

    func test_空の問いでは引かない() {
        XCTAssertTrue(SemanticFinder.rank([], over: [(entry("a"), index([0]))], limits: loose).isEmpty)
    }

    // MARK: - 集める

    /// 索引の無い書籍を数えること。**「無かった」と「まだ見ていない」は違う。**
    func test_索引の無い書籍を数える() {
        let made = SemanticFinder.targets([entry("a"), entry("b"), entry("c")]) { _ in nil }
        XCTAssertTrue(made.ready.isEmpty)
        XCTAssertEqual(made.missing, 3)
    }

    /// いま読んでいる本は出さない。
    func test_除いた書籍は集めない() {
        let mine = entry("mine")
        let made = SemanticFinder.targets([mine, entry("other")], excluding: mine.id) { _ in nil }
        // どちらも索引は無いが、除いた 1 冊は数にも入らない
        XCTAssertEqual(made.missing, 1)
    }
}

/// 一覧の札。
extension SemanticFinderTests {
    /// **同じ頁の段落どうしで札が重ならないこと。**
    ///
    /// PDF は章も頁も位置も同じになり、違うのは目印だけである。
    /// 重なると一覧が取り違え、原書から読んだ本文の配りも当たらない。
    func test_同じ頁の段落でも札が重ならない() {
        let book = entry("a")
        func passage(_ anchor: String) -> RelatedPassage {
            RelatedPassage(book: book,
                           unit: SemanticUnit(locator: Locator(page: 7, progression: 0.5, text: anchor),
                                              heading: "第 3 章", section: 0),
                           score: 0.8)
        }
        let ids = Set([passage("最初の段落の頭である").id, passage("次の段落の頭である").id])
        XCTAssertEqual(ids.count, 2, "同じ頁の段落で札が重なっている")
    }
}
