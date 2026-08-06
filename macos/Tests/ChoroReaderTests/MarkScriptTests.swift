import WebKit
import XCTest
@testable import ChoroReader

/// 検索結果から飛んだ先で当たりを囲む注入スクリプト。
///
/// この部分は WebView の中でしか動かず、Swift 側の単体テストでは触れない。
/// 実物の WKWebView に本番と同じ順で注入して、囲めたかどうかを本文から読み取る。
@MainActor
final class MarkScriptTests: XCTestCase {
    /// 章に見立てた XHTML。同じ語を 2 度出し、何番目を選んだのかを見分けられるようにする。
    private let chapter = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title></head>
    <body>
      <p>まえ サンプル うしろ</p>
      <p>ふたつめ サンプル です</p>
      <p>ＡＢＣ と Abc</p>
      <pre>コード<span class="choro-code-actions"><button class="choro-code-button">サンプル</button></span></pre>
    </body></html>
    """

    private func loadedView() throws -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        // 本番と同じ順で入れる。choroMake は先に入るスタイル側で定義される。
        controller.addUserScript(WKUserScript(source: ReaderScripts.styleScript(css: ReaderScripts.chromeCSS),
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: ReaderScripts.mainScript,
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController = controller

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 600), configuration: config)
        webView.loadHTMLString(chapter, baseURL: nil)

        let ready = waitUntil(timeout: 8) {
            self.evaluate(webView, "!!(document.body && window.choroMark)") as? Bool == true
        }
        XCTAssertTrue(ready, "章と注入スクリプトが入っていない")
        return webView
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func evaluate(_ webView: WKWebView, _ script: String) -> Any? {
        var result: Any?
        var done = false
        webView.evaluateJavaScript(script) { value, _ in
            result = value
            done = true
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !done {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.03))
        }
        return result
    }

    /// 囲んだ語と、それを含む段落の書き出し。何番目を選んだのかはこれで見分ける。
    private func marked(_ webView: WKWebView) -> (text: String, paragraph: String, count: Int) {
        let text = evaluate(webView, "(document.querySelector('mark.choro-found') || {}).textContent || ''") as? String
        let paragraph = evaluate(webView, """
            ((document.querySelector('mark.choro-found') || {}).parentNode || {}).textContent || ''
            """) as? String
        let count = evaluate(webView, "document.querySelectorAll('mark.choro-found').length") as? Int
        return (text ?? "", paragraph ?? "", count ?? 0)
    }

    func test当たりを囲む() throws {
        let webView = try loadedView()
        XCTAssertEqual(evaluate(webView, "window.choroMark('サンプル', 0, false)") as? Bool, true)

        let found = marked(webView)
        XCTAssertEqual(found.text, "サンプル")
        XCTAssertEqual(found.count, 1, "囲むのは選んだ 1 つだけ")
        XCTAssertTrue(found.paragraph.hasPrefix("まえ"), "1 つめではなく \(found.paragraph) を囲んだ")
    }

    func test章の中の何番目かで選び分ける() throws {
        let webView = try loadedView()
        XCTAssertEqual(evaluate(webView, "window.choroMark('サンプル', 1, false)") as? Bool, true)

        let found = marked(webView)
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found.paragraph.hasPrefix("ふたつめ"), "2 つめではなく \(found.paragraph) を囲んだ")
    }

    /// こちらが足したもの（コードのコピーボタン）は本文ではない。
    /// 数に入れると、抽出（HTMLText）と当たりの順番がずれる。
    func test足したボタンの文字は数えない() throws {
        let webView = try loadedView()
        XCTAssertEqual(evaluate(webView, "window.choroMark('サンプル', 2, false)") as? Bool, false,
                       "コピーボタンの文字を 3 つめとして数えている")
    }

    /// 畳み方は DocumentSearch.options と同じ規則。全角と半角、大文字と小文字を区別しない。
    func test全角と半角や大文字小文字を区別しない() throws {
        let webView = try loadedView()
        XCTAssertEqual(evaluate(webView, "window.choroMark('abc', 0, false)") as? Bool, true)
        XCTAssertEqual(marked(webView).text, "ＡＢＣ", "全角の側を先に囲むはず")

        XCTAssertEqual(evaluate(webView, "window.choroMark('ＡＢＣ', 1, false)") as? Bool, true)
        XCTAssertEqual(marked(webView).text, "Abc")
    }

    func test引き直すと前の囲みは消える() throws {
        let webView = try loadedView()
        XCTAssertEqual(evaluate(webView, "window.choroMark('サンプル', 0, false)") as? Bool, true)
        XCTAssertEqual(marked(webView).count, 1)

        evaluate(webView, "window.choroClearMarks()")
        XCTAssertEqual(marked(webView).count, 0)

        // 囲みを外したあとの本文は、元の並びに戻っていなければならない。
        // 切った文字節が残ると、次に数えたときの居場所がずれる。
        XCTAssertEqual(evaluate(webView, "window.choroMark('サンプル', 1, false)") as? Bool, true)
        XCTAssertTrue(marked(webView).paragraph.hasPrefix("ふたつめ"))
    }

    func test見つからない語では何も囲まない() throws {
        let webView = try loadedView()
        XCTAssertEqual(evaluate(webView, "window.choroMark('出てこない語', 0, false)") as? Bool, false)
        XCTAssertEqual(marked(webView).count, 0)
    }

    // MARK: - ナビゲータを通した道

    /// 検索結果へ飛ぶと、その章の当たりが囲まれる。
    /// スクリプト単体ではなく、書籍を開いて動かすところまでを通しで確かめる。
    func test検索結果へ飛ぶと当たりが囲まれる() throws {
        let url = TestPaths.fixture("epub3-basic.epub")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "conformance/choroconf generate でフィクスチャを作ってください")

        let document = try BookDocument(url: url)
        let resources = try XCTUnwrap(document.resources)
        let publication = try XCTUnwrap(document.publication)
        let query = "e"
        let outcome = DocumentSearch.scanEPUB(resources: resources, publication: publication, query: query)
        let hit = try XCTUnwrap(outcome.results.last, "「\(query)」が 1 件も見つからない")

        let controller = WebNavigatorController(document: document, settings: ReaderSettings.shared, start: nil)
        XCTAssertTrue(waitUntil(timeout: 10) { !controller.isLoading })

        controller.mark = SearchMark(query: query, nth: hit.nth, target: hit.locator)
        controller.reveal(hit.locator)
        XCTAssertTrue(waitUntil(timeout: 10) { !controller.isLoading })

        let marked = waitUntil(timeout: 6) {
            self.evaluate(controller.webView,
                          "document.querySelectorAll('mark.choro-found').length") as? Int == 1
        }
        XCTAssertTrue(marked, "飛んだ先で当たりが囲まれていない")

        // 検索をやめたら消える。読み続けるあいだ残り続けては邪魔になる。
        controller.mark = nil
        XCTAssertTrue(waitUntil(timeout: 6) {
            self.evaluate(controller.webView,
                          "document.querySelectorAll('mark.choro-found').length") as? Int == 0
        }, "検索をやめても囲みが残っている")
    }

    /// 紙面は文字を持たない絵なので、当たりの矩形を上から塗る。
    /// PDFKit の選択とは別に持つ。あちらは人が文字を選び直すと消える。
    func test紙面の当たりを塗る() throws {
        let url = TestPaths.repositoryRoot.appendingPathComponent("samples/sample.pdf")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "samples/build.rb でサンプルを作ってください")

        let document = try BookDocument(url: url)
        let controller = PDFNavigatorController(document: document, settings: ReaderSettings.shared, start: nil)
        let page = try XCTUnwrap(document.pdfDocument?.page(at: 1))

        controller.mark = SearchMark(query: "sample", nth: 0,
                                     target: Locator(page: 1, progression: 0))
        let painted = try XCTUnwrap(controller.pdfView.highlightedSelections, "塗られていない")
        XCTAssertFalse(painted.isEmpty)
        XCTAssertTrue(painted.allSatisfy { $0.pages.first == page }, "当たりのないページまで塗っている")

        controller.mark = nil
        XCTAssertNil(controller.pdfView.highlightedSelections, "検索をやめても塗りが残っている")
    }
}
