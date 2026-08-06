import XCTest
@testable import ChoroReader

final class CSSCompatTests: XCTestCase {
    func testRewritesPrefixedProperties() {
        let result = CSSCompat.rewrite(css: """
        body { -epub-writing-mode: vertical-rl; -epub-hyphens: auto; }
        .num { -epub-text-combine: horizontal; }
        """)
        XCTAssertTrue(result.css.contains("writing-mode: vertical-rl"))
        XCTAssertTrue(result.css.contains("hyphens: auto"))
        XCTAssertTrue(result.css.contains("text-combine-upright: all"))
        XCTAssertFalse(result.css.contains("-epub-"), "変換漏れ: \(result.css)")
        XCTAssertFalse(result.changes.isEmpty, "変更ログが残っていない")
    }

    func testLeavesCommentsAndStringsAlone() {
        let source = """
        /* -epub-writing-mode はここでは変えない */
        .a { content: "-epub-writing-mode: horizontal-tb"; }
        .b { -epub-writing-mode: vertical-rl; }
        """
        let result = CSSCompat.rewrite(css: source)
        XCTAssertTrue(result.css.contains("/* -epub-writing-mode はここでは変えない */"),
                      "コメント内を書き換えてしまっている")
        XCTAssertTrue(result.css.contains("\"-epub-writing-mode: horizontal-tb\""),
                      "文字列リテラル内を書き換えてしまっている")
        XCTAssertTrue(result.css.contains(".b { writing-mode: vertical-rl; }"))
    }

    func testDoesNotTouchWebkitPrefix() {
        let result = CSSCompat.rewrite(css: ".a { -webkit-writing-mode: vertical-rl; }")
        XCTAssertTrue(result.css.contains("-webkit-writing-mode"))
        XCTAssertTrue(result.changes.isEmpty)
    }

    func testRewritesStyleBlocksInXHTML() {
        let html = """
        <html><head><style>.v { -epub-writing-mode: vertical-rl; }</style></head>
        <body><p>-epub-writing-mode という文字列は本文なので変えない</p></body></html>
        """
        let result = CSSCompat.rewriteXHTML(html)
        XCTAssertTrue(result.css.contains(".v { writing-mode: vertical-rl; }"))
        XCTAssertTrue(result.css.contains("<p>-epub-writing-mode という文字列は本文なので変えない</p>"),
                      "本文を書き換えてしまっている")
    }

    func testDecodesNonUTF8() {
        let sjis = "p { color: red } /* 日本語 */".data(using: .shiftJIS)!
        let decoded = CSSCompat.decodeText(sjis)
        XCTAssertTrue(decoded.contains("日本語"), "Shift_JIS を復号できていない")
    }
}

final class HTMLTextTests: XCTestCase {
    func testExtractsTextAndMarksCode() {
        let html = """
        <html><body>
        <p>本文です</p>
        <pre><code>let x = 1</code></pre>
        <p>続きの本文</p>
        </body></html>
        """
        let extracted = HTMLText.extract(html)
        XCTAssertTrue(extracted.text.contains("本文です"))
        XCTAssertTrue(extracted.text.contains("let x = 1"))

        guard let codeOffset = extracted.text.range(of: "let x = 1")
            .map({ extracted.text.distance(from: extracted.text.startIndex, to: $0.lowerBound) }) else {
            return XCTFail("コードを抽出できていない")
        }
        XCTAssertTrue(extracted.isCode(at: codeOffset), "コードブロックとして印が付いていない")

        guard let proseOffset = extracted.text.range(of: "本文です")
            .map({ extracted.text.distance(from: extracted.text.startIndex, to: $0.lowerBound) }) else {
            return XCTFail("本文を抽出できていない")
        }
        XCTAssertFalse(extracted.isCode(at: proseOffset), "本文をコードと誤判定している")
    }

    func testDropsScriptAndStyle() {
        let html = "<style>.a{color:red}</style><script>alert('x')</script><p>本文</p>"
        let extracted = HTMLText.extract(html)
        XCTAssertFalse(extracted.text.contains("color:red"))
        XCTAssertFalse(extracted.text.contains("alert"))
        XCTAssertTrue(extracted.text.contains("本文"))
    }

    func testDecodesEntities() {
        let extracted = HTMLText.extract("<p>a &lt; b &amp;&amp; c &#x3042; &#12356;</p>")
        XCTAssertTrue(extracted.text.contains("a < b && c"))
        XCTAssertTrue(extracted.text.contains("あ"))
        XCTAssertTrue(extracted.text.contains("い"))
    }
}

final class SearchTests: XCTestCase {
    func testFindsTermsInRealBook() throws {
        let archive = try Fixtures.archive(Fixtures.gihyo)
        let publication = try EPUBParser.parse(archive)

        let expectation = expectation(description: "検索完了")
        var outcome: DocumentSearch.Outcome?
        DocumentSearch.searchEPUB(resources: archive, publication: publication, query: "モナド") {
            outcome = $0
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 30)

        let results = try XCTUnwrap(outcome?.results)
        XCTAssertFalse(results.isEmpty, "「モナド」が 1 件も見つからない")
        for result in results.prefix(5) {
            XCTAssertTrue(result.match.contains("モナド"))
            XCTAssertNotNil(result.locator.href)
            XCTAssertTrue((0 ... 1).contains(result.locator.progression))
        }
        XCTAssertTrue(results.contains { $0.isCode }, "コード内の一致が 1 件も検出されていない")
    }

    func testWidthInsensitiveMatching() throws {
        let archive = try Fixtures.archive(Fixtures.review)
        let publication = try EPUBParser.parse(archive)

        let expectation = expectation(description: "検索完了")
        var outcome: DocumentSearch.Outcome?
        // 全角で入力しても半角の Re:VIEW に当たること。日本語入力では全角のまま検索しがちなため。
        DocumentSearch.searchEPUB(resources: archive, publication: publication, query: "Ｒｅ：ＶＩＥＷ") {
            outcome = $0
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 30)
        XCTAssertFalse(outcome?.results.isEmpty ?? true, "全角入力が半角に一致していない")
    }
}
