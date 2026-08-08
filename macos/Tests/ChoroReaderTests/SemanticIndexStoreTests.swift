import XCTest
@testable import ChoroReader

/// 索引を作って、置いて、読み直して、引く。
///
/// **決定的な偽物で回す。** 実物を使うと、モデルの無い機械で飛んでしまい、
/// 配管（切り出し・失効・往復）が守られない（spec-local-ai.md 第 8 章の 1）。
/// 実物との一致は `CoreMLEmbedderTests` が別に見ている。
@MainActor
final class SemanticIndexStoreTests: XCTestCase {
    /// 検査ごとに使い捨ての書籍を作る。中身は架空のもの。
    ///
    /// 置き場所の鍵は書籍の道筋なので、同じファイルを使い回すと
    /// 前の検査が置いたものを掴む。毎回別の道筋にする。
    private func book(_ sections: [(String, String)]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("choro-semantic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("book.epub")

        var body = ""
        for (heading, text) in sections {
            body += "<h2>\(heading)</h2><p>\(text)</p>"
        }
        try write(epub: body, to: url)
        return url
    }

    /// 最小の EPUB をその場で組む。
    ///
    /// 共有の検証用資産（conformance/fixtures）は凍らせてあるので足さない。
    /// ここで要るのは「意味で引けること」を見るための、それなりの長さの本文である。
    private func write(epub body: String, to url: URL) throws {
        let staging = url.deletingLastPathComponent().appendingPathComponent("staging", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("META-INF"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("OEBPS"),
                                                withIntermediateDirectories: true)
        func put(_ text: String, _ path: String) throws {
            try Data(text.utf8).write(to: staging.appendingPathComponent(path))
        }
        try put("application/epub+zip", "mimetype")
        try put("""
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """, "META-INF/container.xml")
        try put("""
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="id">urn:uuid:kakuu</dc:identifier>
            <dc:title>架空の技術書</dc:title>
            <dc:language>ja</dc:language>
          </metadata>
          <manifest><item id="t" href="text.xhtml" media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="t"/></spine>
        </package>
        """, "OEBPS/content.opf")
        try put("""
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>架空</title></head>
        <body>\(body)</body></html>
        """, "OEBPS/text.xhtml")

        try? FileManager.default.removeItem(at: url)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = staging
        zip.arguments = ["-q", "-X", url.path, "mimetype", "META-INF/container.xml",
                         "OEBPS/content.opf", "OEBPS/text.xhtml"]
        try zip.run()
        zip.waitUntilExit()
        try FileManager.default.removeItem(at: staging)
    }

    private func embedder() -> some Embedding { FakeEmbedder(dimension: 8, maximumTokens: 400) }

    /// 作ったものが置かれ、読み直せ、意味で引けること。
    func test_作って置いて引ける() throws {
        let embedder = embedder()
        let url = try book([
            ("非同期処理", String(repeating: "待っている間に他の仕事を進める書き方について述べる。", count: 12)),
            ("文字列の扱い", String(repeating: "文字の並びから一部を取り出す方法について述べる。", count: 12)),
            ("バックアップ", String(repeating: "写しを取っておき、失われたときに戻す備えについて述べる。", count: 12)),
        ])
        defer { SemanticIndexStore.discard(for: url) }

        let source = try XCTUnwrap(SearchIndexStore.open(url))
        var seen: [SemanticIndexStore.Progress] = []
        let made = try XCTUnwrap(SemanticIndexStore.build(for: url, source: source,
                                                          embedder: embedder,
                                                          progress: { seen.append($0) }))
        XCTAssertEqual(made.count, 3)
        XCTAssertEqual(made.dimension, embedder.dimension)
        XCTAssertEqual(made.truncated, 0)
        XCTAssertEqual(seen.map(\.done), [1, 2, 3], "進み具合が順に出ていない")
        XCTAssertEqual(seen.last?.total, 3)

        // 置いたものを読み直せる
        let back = try XCTUnwrap(SemanticIndexStore.cached(for: url))
        XCTAssertEqual(back.count, made.count)
        XCTAssertEqual(back.units.map(\.heading), ["非同期処理", "文字列の扱い", "バックアップ"])

        // 引ける。**どれが当たるかは偽物では見ない**（それは評価セットの仕事）。
        // ここで見るのは、節ごとに 1 件返り、飛び先が揃っていること。
        let query = try embedder.embed("架空の問い", as: .query).vector
        let found = back.nearest(to: query, limit: 5)
        XCTAssertEqual(found.count, 3, "節の数だけ返っていない")
        for hit in found {
            XCTAssertNotNil(back.units[hit.unit].locator.href, "飛び先に章が無い")
            XCTAssertNotNil(back.units[hit.unit].locator.text, "寄せるための目印が無い")
        }
    }

    /// **モデルが変われば使わない。** ここが崩れると、古いベクトルを新しい問いと
    /// 突き合わせることになり、見た目は何も変わらないまま順位だけが狂う。
    func test_モデルが違えば使わない() throws {
        let embedder = embedder()
        let url = try book([("架空の節", String(repeating: "架空の技術書の一節である。", count: 20))])
        defer { SemanticIndexStore.discard(for: url) }

        let source = try XCTUnwrap(SearchIndexStore.open(url))
        _ = try SemanticIndexStore.build(for: url, source: source, embedder: embedder,
                                         model: "架空のモデル-v1")

        XCTAssertNotNil(SemanticIndexStore.cached(for: url, model: "架空のモデル-v1"))
        XCTAssertNil(SemanticIndexStore.cached(for: url, model: "架空のモデル-v2"),
                     "モデルが違うのに使ってしまった")
    }

    /// 書籍が入れ替われば使わない。二字組索引と同じ判断。
    func test_書籍が変われば使わない() throws {
        let embedder = embedder()
        let url = try book([("架空の節", String(repeating: "架空の技術書の一節である。", count: 20))])
        defer { SemanticIndexStore.discard(for: url) }

        let source = try XCTUnwrap(SearchIndexStore.open(url))
        _ = try SemanticIndexStore.build(for: url, source: source, embedder: embedder)
        XCTAssertNotNil(SemanticIndexStore.cached(for: url))

        try write(epub: "<h2>別の節</h2><p>\(String(repeating: "別の中身である。", count: 60))</p>", to: url)
        XCTAssertNil(SemanticIndexStore.cached(for: url), "書籍が変わったのに使ってしまった")
    }

    /// 途中でやめられること。**書きかけを置かない。**
    func test_途中でやめれば何も置かない() throws {
        let embedder = embedder()
        let url = try book((0 ..< 6).map {
            ("第 \($0) 節", String(repeating: "架空の技術書の一節である。", count: 20))
        })
        defer { SemanticIndexStore.discard(for: url) }

        let source = try XCTUnwrap(SearchIndexStore.open(url))
        var done = 0
        let made = try SemanticIndexStore.build(for: url, source: source, embedder: embedder,
                                                progress: { done = $0.done },
                                                shouldStop: { done >= 2 })
        XCTAssertNil(made)
        XCTAssertNil(SemanticIndexStore.cached(for: url), "やめたのに書きかけが置かれている")
    }
}

/// 置いてあるものの版を見分けるところ。
///
/// **「まだ作っていない」と「作ったが版が変わった」は人にとって違う。**
/// 前者は待てば済むが、後者は全量が作り直しになる（spec-local-ai.md 第 4.4 節）。
/// 黙って作り直さないために、数えて言えるようにしてある。
extension SemanticIndexStoreTests {
    func test_版が変わったことを見分ける() throws {
        let url = try book([("架空の節", String(repeating: "架空の技術書の一節である。", count: 40))])
        defer { SemanticIndexStore.discard(for: url) }

        let source = try XCTUnwrap(SearchIndexStore.open(url))
        _ = try SemanticIndexStore.build(for: url, source: source, embedder: embedder(),
                                         model: "架空のモデル-v1")

        XCTAssertEqual(SemanticIndexStore.recordedModel(for: url), "架空のモデル-v1")
        XCTAssertFalse(SemanticIndexStore.isStale(for: url, model: "架空のモデル-v1"))
        XCTAssertTrue(SemanticIndexStore.isStale(for: url, model: "架空のモデル-v2"),
                      "版が変わったのに気付いていない")
    }

    /// 捨てたら「版違い」ではなく「無い」に戻ること。
    func test_捨てれば版違いではなくなる() throws {
        let url = try book([("架空の節", String(repeating: "架空の技術書の一節である。", count: 40))])
        let source = try XCTUnwrap(SearchIndexStore.open(url))
        _ = try SemanticIndexStore.build(for: url, source: source, embedder: embedder(),
                                         model: "架空のモデル-v1")
        SemanticIndexStore.discard(for: url)
        XCTAssertNil(SemanticIndexStore.recordedModel(for: url))
        XCTAssertFalse(SemanticIndexStore.isStale(for: url, model: "架空のモデル-v2"))
    }
}
