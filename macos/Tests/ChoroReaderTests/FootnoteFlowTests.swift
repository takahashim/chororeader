import WebKit
import XCTest
@testable import ChoroReader

/// 注入スクリプトから移動の判断までを、実際の WebView を動かして確かめる。
/// 画面操作では窓の重なりや活性化に左右されるため、ここで経路そのものを押さえる。
@MainActor
final class FootnoteFlowTests: XCTestCase {
    private func fixtureURL() throws -> URL {
        let url = TestPaths.fixture("footnotes.epub")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "conformance/choroconf generate でフィクスチャを作ってください")
        return url
    }

    /// 条件が満たされるまで run loop を回す。WebView の読み込みを待つため。
    @discardableResult
    private func wait(timeout: TimeInterval = 10, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func makeController() throws -> WebNavigatorController {
        let document = try BookDocument(url: fixtureURL())
        let controller = WebNavigatorController(document: document, settings: ReaderSettings.shared, start: nil)
        XCTAssertTrue(wait { !controller.isLoading }, "章を読み込めませんでした")
        // 注入スクリプトが動き出すまで待つ
        XCTAssertTrue(wait { self.evaluateBool(controller, "window.__choroReady === true") },
                      "注入スクリプトが動いていません")
        return controller
    }

    private func evaluateBool(_ controller: WebNavigatorController, _ script: String) -> Bool {
        var result = false
        var done = false
        controller.webView.evaluateJavaScript(script) { value, _ in
            result = (value as? Bool) ?? false
            done = true
        }
        _ = wait(timeout: 2) { done }
        return result
    }

    func testClickingFootnoteShowsPreviewAndKeepsPosition() throws {
        let controller = try makeController()
        let before = controller.locator

        controller.webView.evaluateJavaScript("document.getElementById('ref1').click(); true")

        XCTAssertTrue(wait(timeout: 5) { controller.preview != nil },
                      "脚注をクリックしてもポップオーバーが立ち上がらない")
        let preview = try XCTUnwrap(controller.preview)
        XCTAssertTrue(preview.isFootnote, "脚注として扱われていない")
        XCTAssertEqual(preview.target.fragment, "fn1")
        // 吹き出しの位置はリンクの矩形から決まる。原点のままだと画面の隅に出てしまう。
        XCTAssertGreaterThan(preview.anchor.width, 0)
        XCTAssertGreaterThan(preview.anchor.origin.y, 0)
        // 本文の位置を失わないことが、この機能の目的そのもの。
        XCTAssertEqual(controller.locator.href, before.href)
        XCTAssertNil(controller.locator.fragment, "脚注へ移動してしまっている")
    }

    func testClickingSectionLinkNavigatesInsteadOfPreviewing() throws {
        let controller = try makeController()

        controller.webView.evaluateJavaScript("""
        document.querySelector('a[href="#sec2"]').click(); true
        """)

        XCTAssertTrue(wait(timeout: 5) { controller.locator.fragment == "sec2" },
                      "節へのリンクで移動していない")
        XCTAssertNil(controller.preview, "節へのリンクでポップオーバーを出してしまっている")
    }

    func testPreviewResourceIsServedFromTheArchive() throws {
        let controller = try makeController()
        controller.webView.evaluateJavaScript("document.getElementById('ref1').click(); true")
        XCTAssertTrue(wait(timeout: 5) { controller.preview != nil })

        // 抜粋は本文と同じスキームハンドラ経由で配信される。中の相対参照が解けることの前提。
        let path = try XCTUnwrap(controller.preview?.resourcePath)
        XCTAssertEqual(path, "OEBPS/text/\(PreviewProvider.syntheticName)")

        let text = pollString(controller.previewView, "document.body ? document.body.textContent : ''",
                              until: { $0.contains("脚注") })
        if text.isEmpty {
            let state = pollString(controller.previewView, "document.readyState", until: { !$0.isEmpty })
            let location = pollString(controller.previewView, "String(document.location)", until: { !$0.isEmpty })
            XCTFail("抜粋が空です（readyState=\(state), location=\(location)）")
            return
        }
        XCTAssertTrue(text.contains("これは脚注の中身です"), "抜粋が表示されていない: \(text)")
        XCTAssertFalse(text.contains("本文の途中に脚注がある"), "本文まで写してしまっている")
    }

    private func pollString(_ webView: WKWebView, _ script: String,
                            until satisfied: (String) -> Bool, timeout: TimeInterval = 6) -> String {
        var latest = ""
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var done = false
            webView.evaluateJavaScript(script) { value, _ in
                latest = (value as? String) ?? ""
                done = true
            }
            _ = wait(timeout: 2) { done }
            if satisfied(latest) { return latest }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        return latest
    }
}
