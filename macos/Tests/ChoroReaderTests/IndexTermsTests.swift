import XCTest
@testable import ChoroReader

/// 用語索引から語を採るところ。
///
/// **取りこぼしより、混ぜ物の方が悪い。** 頁番号や節見出しが語として並ぶと、
/// 蔵書横断の一覧が使い物にならない。
final class IndexTermsTests: XCTestCase {
    // MARK: - 1 項目から語を採る

    func test_末尾の頁番号を落とす() {
        XCTAssertEqual(IndexTerms.term(from: "配列 12, 45, 67"), "配列")
        XCTAssertEqual(IndexTerms.term(from: "型推論　101"), "型推論")
        XCTAssertEqual(IndexTerms.term(from: "例外 12-15"), "例外")
    }

    /// **点線には結合文字を使う本がある**（U+0336 の重ね打ち）。
    /// 見た目が同じでも普通の記号としては落とせない。
    func test_点線を落とす() {
        XCTAssertEqual(IndexTerms.term(from: "has-a関係 ････････････ 12"), "has-a関係")
        XCTAssertEqual(IndexTerms.term(from: "CAPTCHA \u{0336}\u{0336}\u{0336}\u{0336} 34"), "CAPTCHA")
        XCTAssertEqual(IndexTerms.term(from: "モジュール…………… 8"), "モジュール")
    }

    /// 参照はその語の説明ではない。
    func test_参照のところで切る() {
        XCTAssertEqual(IndexTerms.term(from: "動的型付け → 型"), "動的型付け")
        XCTAssertEqual(IndexTerms.term(from: "配列 参照 リスト"), "配列")
    }

    /// **見出しは語ではない。** あ行・A・記号がそのまま並ぶ。
    func test_見出しは語にしない() {
        for raw in ["あ行", "か行", "A", "z", "記号", "数字", "その他"] {
            XCTAssertNil(IndexTerms.term(from: raw), "「\(raw)」を語と見なしている")
        }
    }

    func test_語にならないものは返さない() {
        for raw in ["", "   ", "12, 34", "・・・・・", "—"] {
            XCTAssertNil(IndexTerms.term(from: raw), "「\(raw)」を語と見なしている")
        }
    }

    /// 英語の語や記号を含む語は残ること。**見出しの「A」とは区別する。**
    func test_短い語でも残る() {
        XCTAssertEqual(IndexTerms.term(from: "型 3"), "型")
        XCTAssertEqual(IndexTerms.term(from: "C++ 88"), "C++")
        XCTAssertEqual(IndexTerms.term(from: "ghc-mod 120"), "ghc-mod")
    }

    // MARK: - 索引の紙面（XHTML）から

    /// **語は外側の項目にあり、内側は頁番号のリンクである。**
    ///
    /// 内側まで数えると頁番号ばかり拾う（実物で 805 項目から 82 語しか出なかった）。
    func test_入れ子の頁番号を語にしない() {
        let html = """
        <html><body><ul>
          <li><span>配列</span><ul><li><a href="c1.xhtml#p12">12</a></li>
                                   <li><a href="c2.xhtml#p45">45</a></li></ul></li>
          <li><span>例外</span><ul><li><a href="c3.xhtml#p88">88</a></li></ul></li>
        </ul></body></html>
        """
        XCTAssertEqual(IndexTerms.fromHTML(html), ["配列", "例外"])
    }

    /// **リンクだけの項目は語ではない。** 節の見出しを指していることがある。
    func test_リンクだけの項目は語にしない() {
        let html = """
        <html><body><ul>
          <li><span>アクセシビリティ</span><ul>
            <li><a href="c1.xhtml">7-5 架空の節の見出しである</a></li></ul></li>
        </ul></body></html>
        """
        XCTAssertEqual(IndexTerms.fromHTML(html), ["アクセシビリティ"])
    }

    /// 頁番号が項目の中に地の文で並ぶ形も採れること。
    func test_項目の中に頁番号がある形() {
        let html = "<html><body><ul><li>関数 12, 34</li><li>再帰 56</li></ul></body></html>"
        XCTAssertEqual(IndexTerms.fromHTML(html), ["関数", "再帰"])
    }

    /// `<li>` を使わない索引は、行として読む。
    func test_一覧でない索引は行として読む() {
        let html = "<html><body><p>関数 12</p><p>再帰 56</p></body></html>"
        let made = IndexTerms.fromHTML(html)
        XCTAssertTrue(made.contains("関数"), "\(made)")
        XCTAssertTrue(made.contains("再帰"), "\(made)")
    }
}

/// 蔵書を横断して語で引くところ。
@MainActor
final class TermSearchTests: XCTestCase {
    private func entry(_ name: String) -> LibraryEntry {
        LibraryEntry(id: BookID(url: URL(fileURLWithPath: "/架空/\(name).epub")),
                     path: "/架空/\(name).epub", bookmarkData: nil,
                     title: name, authors: [], format: .reflowableEPUB,
                     lastOpenedAt: Date(timeIntervalSince1970: 0))
    }

    /// 大小・全角半角を無視して比べること。索引は表記が混ざる。
    func test_表記の違いを無視する() {
        XCTAssertEqual(TermSearch.normalize("JavaScript"), TermSearch.normalize("javascript"))
        XCTAssertEqual(TermSearch.normalize("ＪＳ"), TermSearch.normalize("JS"))
        XCTAssertEqual(TermSearch.normalize("型 推論"), TermSearch.normalize("型推論"))
    }

    /// **索引を持たない本と、まだ調べていない本を分けて数えること。**
    ///
    /// 混ぜると「扱っていない」のか「見ていない」のかが分からない。
    func test_持たない本と見ていない本を分ける() {
        let books = [entry("あ"), entry("い"), entry("う")]
        let terms: [String: [String]] = ["あ": ["配列"], "い": []]
        let made = TermSearch.run("配列", over: books) { terms[$0.title] }

        XCTAssertEqual(made.hits.count, 1)
        XCTAssertEqual(made.withoutIndex, 1, "索引を持たない本を数えていない")
        XCTAssertEqual(made.unread, 1, "まだ調べていない本を数えていない")
    }

    /// **問いそのものを載せている本が先。** 次は問いに近い（短い）語の順。
    func test_一致する語を持つ本を先に出す() {
        let books = [entry("あ"), entry("い"), entry("う")]
        let terms = ["あ": ["型推論"], "い": ["型"], "う": ["型クラス"]]
        let made = TermSearch.run("型", over: books) { terms[$0.title] }

        XCTAssertEqual(made.hits.map(\.book.title), ["い", "あ", "う"])
        XCTAssertTrue(made.hits[0].isExact)
        XCTAssertFalse(made.hits[1].isExact)
    }

    /// **1 冊からは 1 語だけ。** 「型」で引いて 1 冊が並びを埋めない。
    func test_1冊からは1語だけ出す() {
        let books = [entry("あ")]
        let terms = ["あ": ["型", "型推論", "型クラス", "静的型付け"]]
        let made = TermSearch.run("型", over: books) { terms[$0.title] }

        XCTAssertEqual(made.hits.count, 1)
        XCTAssertEqual(made.hits[0].term, "型", "いちばん近い語を選んでいない")
    }

    /// 当たらない本は出さないこと。
    func test_載っていなければ出さない() {
        let made = TermSearch.run("架空の語", over: [entry("あ")]) { _ in ["配列", "例外"] }
        XCTAssertTrue(made.hits.isEmpty)
        XCTAssertEqual(made.withoutIndex, 0)
    }

    /// 空の問いでは何も返さないこと。
    func test_空の問いでは何もしない() {
        let made = TermSearch.run("  ", over: [entry("あ")]) { _ in ["配列"] }
        XCTAssertTrue(made.hits.isEmpty)
    }
}
