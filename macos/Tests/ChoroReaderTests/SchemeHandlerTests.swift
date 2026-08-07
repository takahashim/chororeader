import WebKit
import XCTest
@testable import ChoroReader

/// 配信時の MIME の決め方。
/// HTML5 として書かれた文書を XHTML として渡すと、名前空間が付かないために
/// <style> の中身が本文として表示されてしまう。
@MainActor
final class SchemeHandlerTests: XCTestCase {
    private final class Stub: ResourceProvider {
        var files: [String: String] = [:]
        func contains(_ path: String) -> Bool { files[path] != nil }
        func read(_ path: String) throws -> Data {
            guard let text = files[path] else { throw ZipArchive.Failure.entryNotFound(path) }
            return Data(text.utf8)
        }
    }

    private func mimeType(path: String, content: String) throws -> String {
        let stub = Stub()
        stub.files[path] = content
        let handler = ResourceSchemeHandler(resources: stub)

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: ResourceSchemeHandler.scheme)
        let webView = WKWebView(frame: .zero, configuration: config)
        let url = try XCTUnwrap(ResourceSchemeHandler.url(forHref: path))
        webView.load(URLRequest(url: url))

        // about:blank も readyState は complete になる。目的の文書が来たことを見てから種別を読む。
        let arrived = waitUntil(timeout: 8) {
            self.evaluate(webView, "String(document.location).indexOf('\(ResourceSchemeHandler.scheme)') === 0") as? Bool == true
        }
        XCTAssertTrue(arrived, "検証用の文書が読み込まれていない")
        return evaluate(webView, "document.contentType") as? String ?? ""
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

    func testGeneratedHTML5IsServedAsHTML() throws {
        // XML としても妥当な HTML5。XHTML として渡すと名前空間が付かず、<style> が本文として出てしまう。
        let html = """
        <!DOCTYPE html>
        <html lang="ja"><head><meta charset="utf-8"/><title>t</title>
        <style>body { color: red; }</style></head>
        <body><p>本文</p></body></html>
        """
        XCTAssertEqual(try mimeType(path: "OEBPS/generated.html", content: html), "text/html")
    }

    func testXHTMLChapterKeepsItsType() throws {
        let xhtml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title></head>
        <body><p>本文</p></body></html>
        """
        XCTAssertEqual(try mimeType(path: "OEBPS/ch01.xhtml", content: xhtml), "application/xhtml+xml")
    }

    func testMalformedXHTMLFallsBackToHTML() throws {
        // 閉じていないタグを含む章。XHTML として渡すと丸ごと表示できなくなる。
        let broken = """
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><meta charset="utf-8"><title>t</title></head>
        <body><p>閉じていない段落<br></body></html>
        """
        XCTAssertEqual(try mimeType(path: "OEBPS/broken.xhtml", content: broken), "text/html")
    }

    /// 覚える量に頭が打たれること。
    ///
    /// 章と CSS は文字なので 1 つは小さいが、際限は無い。読み進めれば章が積み上がり、
    /// 同じ章でも印の付き方ごとに別の 1 つになる。当たりを次々に押すとその分だけ増え、
    /// 窓が開いているあいだ捨てられない。
    func test_覚える量に頭が打たれる() {
        let handler = ResourceSchemeHandler(resources: Stub())
        let chunk = String(repeating: "あ", count: 200_000) // UTF-8 で 600 KB ほど

        for at in 0..<40 {
            handler.provideSynthetic(path: "OEBPS/text/ch\(at).xhtml", html: chunk)
        }

        XCTAssertGreaterThan(handler.cachedByteCount, 0, "何も覚えていない")
        XCTAssertLessThanOrEqual(handler.cachedByteCount, ResourceSchemeHandler.cacheLimit,
                                 "頭を越えて抱え込んでいる")
    }
}
