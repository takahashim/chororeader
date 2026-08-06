import WebKit
import XCTest
@testable import ChoroReader

/// 出版社が背景色を敷いた要素（見出しの帯など）から、文字色を奪わないことを守る。
/// 奪うと黒帯に暗い文字が残り、見出しが読めなくなる。
@MainActor
final class ThemeColorTests: XCTestCase {
    private let settings = ReaderSettings.shared

    override func tearDown() {
        settings.theme = .light
        super.tearDown()
    }

    func testLightThemeDoesNotForceTextColor() {
        settings.theme = .light
        let css = settings.userCSS()
        XCTAssertFalse(css.contains("color: \(ReaderTheme.light.foreground) !important"),
                       "明るいテーマで文字色を強制している")
        XCTAssertTrue(css.contains("background-color: \(ReaderTheme.light.background) !important"),
                      "背景色は当てておく必要がある")
    }

    func testSepiaThemeDoesNotForceTextColor() {
        settings.theme = .sepia
        XCTAssertFalse(settings.userCSS().contains("!important;\n        }\n        p,"),
                       "セピアで一律の文字色指定が残っている")
        XCTAssertFalse(settings.needsForegroundMarking)
    }

    func testDarkThemeForcesColorOnlyThroughMarkedClass() {
        settings.theme = .dark
        let css = settings.userCSS()
        XCTAssertTrue(css.contains(".choro-fg"), "暗いテーマで印付けを使っていない")
        XCTAssertTrue(settings.needsForegroundMarking)
        // 見出しなどを名指しで塗ると、背景色を持つ要素も巻き込んでしまう。
        XCTAssertFalse(css.contains("h1, h2, h3"), "要素名を名指しで塗っている")
    }

    /// 実際のページで、背景色を持つ見出しが印付けから除かれることを確かめる。
    func testElementsWithBackgroundAreExcluded() throws {
        let html = """
        <!DOCTYPE html><html><head><style>
        .band { background: #000; color: #fff; }
        </style></head><body>
        <div class="band" id="band"><h1 id="title">見出し</h1><p id="sub">副題</p></div>
        <p id="plain">本文</p>
        <pre id="code"><span id="kw" style="color:#07a">let</span> x</pre>
        </body></html>
        """

        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.loadHTMLString(html, baseURL: nil)
        // about:blank の時点でも readyState は complete になる。目的の文書が来たことで判定する。
        XCTAssertTrue(waitUntil {
            (self.evaluate(webView, "!!document.getElementById('band')") as? Bool) == true
        }, "検証用の文書が読み込まれていない")

        _ = evaluate(webView, ReaderScripts.mainScript)
        let marked = evaluate(webView, "window.choroApplyForeground(true)") as? Int
        XCTAssertNotNil(marked, "印付けの関数が動いていない")
        // body の子は 3 つ。背景を持つ帯は除かれ、本文とコードの 2 つだけが塗られる。
        XCTAssertEqual(marked, 2)

        func hasClass(_ id: String) -> Bool {
            (evaluate(webView, "document.getElementById('\(id)').classList.contains('choro-fg')") as? Bool) ?? false
        }

        XCTAssertFalse(hasClass("band"), "背景色を持つ要素を塗ろうとしている")
        XCTAssertFalse(hasClass("title"), "背景色の中の見出しを塗ろうとしている")
        XCTAssertFalse(hasClass("sub"), "背景色の中の副題を塗ろうとしている")
        XCTAssertTrue(hasClass("plain"), "背景色のない本文が塗られていない")
        // コードは枠だけ塗り、内側の色付けには触れない。
        XCTAssertTrue(hasClass("code"))
        XCTAssertFalse(hasClass("kw"), "コード内の色付けを塗り潰している")
    }

    // MARK: - 補助

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
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
        _ = waitUntil(timeout: 3) { done }
        return result
    }

    private func string(_ webView: WKWebView, _ script: String) -> String {
        evaluate(webView, script) as? String ?? ""
    }
}
