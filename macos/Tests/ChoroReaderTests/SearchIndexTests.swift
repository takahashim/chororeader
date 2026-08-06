import XCTest
@testable import ChoroReader

/// 索引は候補を絞るだけで当たりを決めない。
/// そのため守るべき性質は 1 つで、**本当の当たりを落とさない**ことに尽きる。
/// 余計な候補が出るのは、走査し直す段で消えるので害がない。
final class SearchIndexTests: XCTestCase {
    private let sample = ["型システムの話", "配列と連結リスト", "型推論と単一化"]

    func test二字以上は含む単位だけに絞る() {
        let index = SearchIndex.build(sample)
        XCTAssertEqual(index.candidates("配列"), [1])
        XCTAssertEqual(index.candidates("型推論"), [2])
    }

    func test一字は含む単位をすべて挙げる() {
        XCTAssertEqual(SearchIndex.build(sample).candidates("型"), [0, 2])
    }

    func test単位の最後の一文字も引ける() {
        XCTAssertEqual(SearchIndex.build(["あいう"]).candidates("う"), [0])
    }

    func test無い語は候補が空になる() {
        XCTAssertEqual(SearchIndex.build(sample).candidates("継続モナド"), [])
    }

    func test空の問い合わせは絞れない() {
        XCTAssertNil(SearchIndex.build(sample).candidates(""))
    }

    func test続いていなくても候補には残る() {
        // 「型」と「論」は在るが「型論」とは続かない。索引は絞るだけなので候補には出す。
        XCTAssertEqual(SearchIndex.build(["型と推論"]).candidates("と推"), [0])
    }

    func test全角と半角と大小を区別しない() {
        let index = SearchIndex.build(["ＡＰＩ の設計"])
        XCTAssertEqual(index.candidates("api"), [0])
    }

    func test濁点の合成の違いを区別しない() {
        let index = SearchIndex.build(["か\u{3099}っこいい"])
        XCTAssertEqual(index.candidates("がっこ"), [0])
    }

    func test書き出して読み戻せる() {
        let index = SearchIndex.build(sample)
        let back = SearchIndex(decoding: index.encoded())
        XCTAssertNotNil(back)
        XCTAssertEqual(back?.unitCount, index.unitCount)
        XCTAssertEqual(back?.candidates("型推論"), [2])
        XCTAssertEqual(back?.candidates("型"), [0, 2])
    }

    func test壊れた入力は読まない() {
        XCTAssertNil(SearchIndex(decoding: Data()))
        XCTAssertNil(SearchIndex(decoding: Data("XXXX\u{1}".utf8)))
        var bytes = SearchIndex.build(sample).encoded()
        bytes[4] = 99
        XCTAssertNil(SearchIndex(decoding: bytes))
    }

    /// 索引で絞った結果が、走査だけの結果と食い違わないことを確かめる。
    /// 索引を入れる目的は速さであって、当たりを変えることではない。
    func test絞り込みが当たりを落とさない() {
        let units = [
            "第 1 章 型システム。static な型付けと dynamic な型付けを比べる。",
            "第 2 章 メモリ。配列は連続した領域を占める。ＡＰＩ の設計にも響く。",
            "第 3 章 並行。スレッドとタスクは違う。async/await の話をする。",
            "",
        ]
        let index = SearchIndex.build(units)
        let queries = ["型", "配列", "ＡＰＩ", "api", "async", "スレッド", "無い語",
                       "領域を占める", "a", "。", "静的"]

        for query in queries {
            let 走査 = units.indices.filter {
                units[$0].range(of: query, options: DocumentSearch.options) != nil
            }
            let 候補 = index.candidates(query) ?? Array(units.indices)
            for hit in 走査 {
                XCTAssertTrue(候補.contains(hit), "「\(query)」の当たり（単位 \(hit)）を索引が落とした")
            }
        }
    }
}

/// 索引を挟んでも当たりが変わらないことを、書籍そのもので確かめる。
/// 単体の作り物では取りこぼす、現実の綴りや記法の癖まで見るため。
final class SearchIndexOverBooksTests: XCTestCase {
    private let queries = ["a", "the", "章", "テスト", "code", "の", "EPUB", "見つからない語"]

    func testフィクスチャで索引ありと索引なしが一致する() throws {
        let names = ["epub3-basic.epub", "epub2-ncx.epub", "footnotes.epub",
                     "legacy-css.epub", "encoded-paths.epub", "rtl.epub"]
        for name in names {
            try compare(TestPaths.fixture(name), label: name)
        }
    }

    func test実在の技術書で索引ありと索引なしが一致する() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Fixtures.gihyo),
                          "検証用の実書籍がありません。macos/Tests/local-books.json を用意すると実行されます。")
        try compare(URL(fileURLWithPath: Fixtures.gihyo), label: "gihyo")
    }

    private func compare(_ url: URL, label: String) throws {
        guard let source = SearchIndexStore.open(url),
              case let .epub(resources, publication) = source else {
            return XCTFail("\(label) を開けない")
        }
        let index = SearchIndex.build(SearchIndexStore.unitTexts(of: source))

        for query in queries {
            let full = DocumentSearch.scanEPUB(resources: resources, publication: publication, query: query)
            let narrowed = DocumentSearch.scanEPUB(resources: resources, publication: publication,
                                                   query: query, only: index.candidates(query))
            XCTAssertEqual(digest(full.results), digest(narrowed.results),
                           "\(label) の「\(query)」で索引ありと索引なしが食い違った")
        }
    }

    /// SearchResult は生成のたびに別の id を持つので、中身だけを比べる。
    private func digest(_ results: [SearchResult]) -> [String] {
        results.map { "\($0.locator.href ?? "")|\($0.locator.progression)|\($0.match)" }
    }
}
