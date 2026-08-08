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
                heading: "第 \(at) 節　架空の見出し", section: at))
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
            // 表題は見出しから埋め直される。持ち回らないことを見ておく。
            XCTAssertNil(a.locator.title)
            XCTAssertEqual(a.target.title, b.heading)
        }
        // ベクトルは fp16 で書くので、値そのものは丸まる
        for at in 0 ..< back.count {
            let a = try XCTUnwrap(back.vector(at: at))
            let b = try XCTUnwrap(index.vector(at: at))
            for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: 1e-3) }
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

/// 順位の付け方。
///
/// **節で順位を決め、段落へ着地する。**
/// 段落だけで順位を付けると話題の芯を失う。400 字の段落は「学習」に触れていれば
/// 「過学習を防ぐ方法」に高く出るが、本当に読みたい「正則化」の節には届かない。
/// 実測で意味検索が 8/15 まで落ちた（節で順位を付ければ 11/15）。
///
/// **崩れても症状は出ない。** 結果は返るし、それらしくも見える。
extension SemanticIndexTests {
    /// 節ごとに 1 件だけ返すこと。1 つの節が一覧を埋め尽くさない。
    func test_節ごとに1件返す() {
        // 節 0 に 3 段落、節 1 に 1 段落。すべて同じ向き。
        let index = madeSections([0, 0, 0, 1], dimension: 4, axis: 0)
        let found = index.nearest(to: [1, 0, 0, 0], limit: 10)
        XCTAssertEqual(found.count, 2, "節ではなく段落の数だけ返っている")
    }

    /// **節の中でいちばん近い段落を返すこと。** ここが節の頭を返すようだと、
    /// 段落単位にした意味が無くなる。
    func test_節の中でいちばん近い段落へ着地する() {
        var units: [SemanticUnit] = []
        var vectors: [Float] = []
        // 同じ節の 3 段落。2 番目だけが問いと同じ向き。
        for (at, axis) in [1, 0, 2].enumerated() {
            units.append(SemanticUnit(locator: Locator(page: at, progression: 0),
                                      heading: "節", section: 0))
            var one = [Float](repeating: 0, count: 4)
            one[axis] = 1
            vectors.append(contentsOf: one)
        }
        let index = SemanticIndex(model: "m", dimension: 4, units: units,
                                  vectors: vectors, truncated: 0)
        let found = index.nearest(to: [1, 0, 0, 0], limit: 3)
        XCTAssertEqual(found.first?.unit, 1, "節の中でいちばん近い段落を選んでいない")
    }

    /// 節の点は、その節の段落の平均であること。
    /// **最大にすると、段落の多い節ほど得をする**（節単位のスパイクで測った悪さ）。
    func test_節の点は平均で決まる() {
        var units: [SemanticUnit] = []
        var vectors: [Float] = []
        // 節 0：当たり 1 つ＋外れ 3 つ。節 1：やや近いものが 1 つだけ。
        let plan: [(section: Int, value: [Float])] = [
            (0, [1, 0]), (0, [0, 1]), (0, [0, 1]), (0, [0, 1]),
            (1, [0.8, 0.6]),
        ]
        for (at, one) in plan.enumerated() {
            units.append(SemanticUnit(locator: Locator(page: at, progression: 0),
                                      heading: "節 \(one.section)", section: one.section))
            vectors.append(contentsOf: one.value)
        }
        let index = SemanticIndex(model: "m", dimension: 2, units: units,
                                  vectors: vectors, truncated: 0)
        let found = index.nearest(to: [1, 0], limit: 2)
        // 最大で決めるなら節 0（1.0）が勝つ。平均なら節 1（0.8 対 0.25）が勝つ。
        XCTAssertEqual(index.units[found[0].unit].section, 1,
                       "節の点を最大で決めている（段落の多い節が有利になる）")
    }

    private func madeSections(_ sections: [Int], dimension: Int, axis: Int) -> SemanticIndex {
        var units: [SemanticUnit] = []
        var vectors: [Float] = []
        for (at, section) in sections.enumerated() {
            units.append(SemanticUnit(locator: Locator(page: at, progression: 0),
                                      heading: "節 \(section)", section: section))
            var one = [Float](repeating: 0, count: dimension)
            one[axis] = 1
            vectors.append(contentsOf: one)
        }
        return SemanticIndex(model: "m", dimension: dimension, units: units,
                             vectors: vectors, truncated: 0)
    }
}
