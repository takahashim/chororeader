import XCTest
@testable import ChoroReader

/// 意味の索引の書き出しと読み込み。
///
/// **ここが崩れても症状が出ない。** ベクトルが少しずれても順位が少し変わるだけで、
/// 例外も出なければ画面も壊れない。書いたものが読めることを形の側から固める。
final class SemanticIndexTests: XCTestCase {
    private func made(count: Int, dimension: Int = 8,
                      model: String = "ruri-v3-130m-coreml") -> SemanticIndex {
        var units: [SemanticUnit] = []
        var vectors: [Float] = []
        for at in 0 ..< count {
            units.append(SemanticUnit(
                locator: Locator(href: at % 2 == 0 ? "OEBPS/ch\(at).xhtml" : nil,
                                 page: at % 2 == 0 ? nil : at,
                                 progression: Double(at) / Double(max(1, count)),
                                 fragment: at % 3 == 0 ? "sec\(at)" : nil),
                heading: "第 \(at) 節　架空の見出し",
                excerpt: "これは架空の技術書の一節である。番号は \(at)。"))
            // 単位ごとに向きの違う単位ベクトルを作る
            var one = [Float](repeating: 0, count: dimension)
            one[at % dimension] = 1
            vectors.append(contentsOf: one)
        }
        return SemanticIndex(model: model, dimension: dimension,
                             units: units, vectors: vectors, truncated: 3)
    }

    func test_書いたものが読める() throws {
        let index = made(count: 12)
        let back = try XCTUnwrap(SemanticIndex(decoding: index.encoded(), model: index.model))

        XCTAssertEqual(back.model, index.model)
        XCTAssertEqual(back.dimension, index.dimension)
        XCTAssertEqual(back.truncated, index.truncated)
        XCTAssertEqual(back.units.count, index.units.count)
        for (a, b) in zip(back.units, index.units) {
            XCTAssertEqual(a.heading, b.heading)
            XCTAssertEqual(a.excerpt, b.excerpt)
            // 表題は見出しから埋め直される。持ち回らないことを見ておく。
            XCTAssertNil(a.locator.title)
            XCTAssertEqual(a.target.title, b.heading)
        }
        XCTAssertEqual(back.vectors.count, index.vectors.count)
        for (a, b) in zip(back.vectors, index.vectors) {
            // float16 で書くので、値そのものは丸まる
            XCTAssertEqual(a, b, accuracy: 1e-3)
        }
    }

    /// 位置表現が往復すること。ここが崩れると、当たっても飛べない。
    func test_飛び先が往復する() throws {
        let index = made(count: 6)
        let back = try XCTUnwrap(SemanticIndex(decoding: index.encoded(), model: index.model))
        for (a, b) in zip(back.units, index.units) {
            XCTAssertEqual(a.locator.href, b.locator.href)
            XCTAssertEqual(a.locator.page, b.locator.page)
            XCTAssertEqual(a.locator.fragment, b.locator.fragment)
            // 位置は 10 万分の 1 に丸めて書く
            XCTAssertEqual(a.locator.progression, b.locator.progression, accuracy: 1e-4)
        }
    }

    /// 壊れたものを掴まない。**途中で切れたファイルを黙って受け取ると、
    /// 単位とベクトルの数が食い違ったまま引くことになる。**
    func test_途中で切れたものは読まない() {
        let data = made(count: 10).encoded()
        for cut in [1, data.count / 3, data.count / 2, data.count - 1] {
            XCTAssertNil(SemanticIndex(decoding: data.prefix(cut), model: "m"),
                         "\(cut) バイトで切れたものを読んでしまった")
        }
    }

    func test_空でも書けて読める() throws {
        let empty = SemanticIndex(model: "m", dimension: 4, units: [], vectors: [], truncated: 0)
        let back = try XCTUnwrap(SemanticIndex(decoding: empty.encoded(), model: empty.model))
        XCTAssertEqual(back.count, 0)
        XCTAssertTrue(back.nearest(to: [1, 0, 0, 0], limit: 3).isEmpty)
    }

    /// 近い順に返すこと。
    func test_近い順に返す() {
        let index = made(count: 8, dimension: 8)
        var query = [Float](repeating: 0, count: 8)
        query[5] = 1
        let found = index.nearest(to: query, limit: 3)
        XCTAssertEqual(found.first?.unit, 5)
        XCTAssertEqual(found.first?.score ?? 0, 1, accuracy: 1e-5)
        // 点は降順
        XCTAssertEqual(found.map(\.score), found.map(\.score).sorted(by: >))
    }

    /// 次元の違う問いは受け付けない。**受け付けると、ずれた内積が黙って返る。**
    func test_次元が違えば引かない() {
        XCTAssertTrue(made(count: 4, dimension: 8).nearest(to: [1, 0, 0, 0], limit: 3).isEmpty)
    }
}
