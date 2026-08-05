import AppKit
import WebKit

// allowsContentJavaScript = false の下で、次の 2 点を確認する。
//  A: アプリ注入の WKUserScript とメッセージハンドラが動くか（スクロール通知の実装方式を決める）
//  B: 書籍由来の <script> が実行されないか（セキュリティ方針の検証）

let html = """
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>original-title</title></head>
<body style="height:3000px">
<p id="p">content</p>
<script type="text/javascript">
//<![CDATA[
  document.title = "CONTENT-JS-RAN";
  document.getElementById('p').textContent = "CONTENT-JS-RAN";
//]]>
</script>
</body></html>
"""

final class Handler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let data = html.data(using: .utf8)!
        let resp = URLResponse(url: task.request.url!, mimeType: "application/xhtml+xml",
                               expectedContentLength: data.count, textEncodingName: "utf-8")
        task.didReceive(resp); task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class Delegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    var web: WKWebView!
    var window: NSWindow!
    var gotUserScriptMessage = false

    func applicationDidFinishLaunching(_ n: Notification) {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(Handler(), forURLScheme: "tzr")
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false

        let ucc = WKUserContentController()
        ucc.add(self, name: "tzr")
        ucc.addUserScript(WKUserScript(source: """
            window.webkit.messageHandlers.tzr.postMessage({kind: 'userScript', title: document.title});
            window.addEventListener('scroll', function() {
              window.webkit.messageHandlers.tzr.postMessage({kind: 'scroll', y: window.scrollY});
            });
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        cfg.userContentController = ucc

        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: cfg)
        web.navigationDelegate = self
        window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 600, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web
        window.makeKeyAndOrderFront(nil)
        web.load(URLRequest(url: URL(string: "tzr://book/probe.xhtml")!))
    }

    func userContentController(_ c: WKUserContentController, didReceive msg: WKScriptMessage) {
        if let body = msg.body as? [String: Any] {
            if body["kind"] as? String == "userScript" {
                gotUserScriptMessage = true
                print("A: user script + message handler = WORKS (title seen: \(body["title"] ?? "?"))")
            } else {
                print("A: scroll message = \(body)")
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish nav: WKNavigation!) {
        webView.evaluateJavaScript("document.getElementById('p').textContent") { r, _ in
            let text = (r as? String) ?? "?"
            print("B: content <script> ran = \(text == "CONTENT-JS-RAN" ? "YES (方針に反する)" : "NO (期待どおり)") [p = \(text)]")
            // スクロール通知の実地確認
            webView.evaluateJavaScript("window.scrollTo(0, 500); 'ok'") { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    print("A(結論): \(self.gotUserScriptMessage ? "注入スクリプト方式が使える" : "注入スクリプトは動かない → evaluateJavaScript ポーリングに切り替え")")
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let d = Delegate()
app.delegate = d
app.run()
