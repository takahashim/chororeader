import XCTest
@testable import ChoroReader

/// 本文へ印を入れる部分。文字列から文字列を作るだけなので、画面を起こさずに確かめられる。
/// 同じ観点を Rust 版は core/src/mark.rs で持っている。
final class SearchMarkInserterTests: XCTestCase {
    private func marked(_ html: String, _ query: String, _ nth: Int = 0) throws -> String {
        try XCTUnwrap(SearchMarkInserter.insert(into: html, query: query, nth: nth),
                      "囲めなかった: 「\(query)」の \(nth) 番目")
    }

    func test当たりを囲む() throws {
        let out = try marked("<p>これはサンプルです</p>", "サンプル")
        XCTAssertTrue(out.contains(#"<mark class="choro-found">サンプル</mark>"#), out)
    }

    func test何番目かで選び分ける() throws {
        let html = "<p>まえ サンプル</p><p>あと サンプル</p>"
        let out = try marked(html, "サンプル", 1)
        XCTAssertTrue(out.contains(#"あと <mark class="choro-found">サンプル</mark>"#), out)
    }

    /// 走査が数えた通し番号と、ここで囲む当たりが同じものを指していること。
    func test検索が数えた通し番号と同じものを選ぶ() throws {
        let html = "<p>型と型と型</p>"
        let text = HTMLText.extract(html).text
        for nth in 0 ..< 3 {
            let (from, _) = try XCTUnwrap(SearchMarkInserter.nthMatch(in: text, query: "型", nth: nth))
            let before = text.prefix(from).filter { $0 == "型" }.count
            XCTAssertEqual(before, nth, "\(nth) 番目の前に型が \(before) 個")
            XCTAssertNotNil(SearchMarkInserter.insert(into: html, query: "型", nth: nth))
        }
    }

    /// 探し方は DocumentSearch.options と同じ。全角と半角、大文字と小文字を区別しない。
    func test全角と半角を区別しない() throws {
        let out = try marked("<p>ＡＢＣ</p>", "abc")
        XCTAssertTrue(out.contains(#"<mark class="choro-found">ＡＢＣ</mark>"#), out)
    }

    func test節をまたぐ語はそもそも当たりにならない() {
        // 抽出はタグの位置に空白を 1 つ残すので、「本<b>文</b>」の本文は「本 文」になる。
        // 検索が当てない以上、囲む対象にもならない。入れ子を壊す心配はここで消えている。
        let html = "<p>本<b>文</b></p>"
        XCTAssertTrue(HTMLText.extract(html).text.contains("本 文"))
        XCTAssertNil(SearchMarkInserter.insert(into: html, query: "本文", nth: 0))
    }

    func test実体参照を挟んでも位置がずれない() throws {
        let out = try marked("<p>a&amp;b の話</p>", "の話")
        XCTAssertTrue(out.contains(#"<mark class="choro-found">の話</mark>"#), out)
    }

    func testスクリプトの中は数えない() throws {
        // 抽出が本文に混ぜないものは、当たりにもならない。
        let out = try marked("<script>var 型 = 1;</script><p>型</p>", "型")
        XCTAssertTrue(out.contains(#"<p><mark class="choro-found">型</mark></p>"#), out)
    }

    func test見つからない語では何も返さない() {
        XCTAssertNil(SearchMarkInserter.insert(into: "<p>本文</p>", query: "出てこない語", nth: 0))
        XCTAssertNil(SearchMarkInserter.insert(into: "<p>本文</p>", query: "本文", nth: 5))
        XCTAssertNil(SearchMarkInserter.insert(into: "<p>本文</p>", query: "", nth: 0))
    }

    func test囲んでも本文の字は増えない() throws {
        // 印はタグなので、抽出はその位置に空白を残す。字そのものは変わらない。
        let html = "<p>これはサンプルです</p>"
        let out = try marked(html, "サンプル")
        let squeeze = { (s: String) in s.replacingOccurrences(of: " ", with: "") }
        XCTAssertEqual(squeeze(HTMLText.extract(html).text), squeeze(HTMLText.extract(out).text))
    }
}
