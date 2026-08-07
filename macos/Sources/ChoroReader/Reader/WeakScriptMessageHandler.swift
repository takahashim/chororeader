import WebKit

/// 画面からの知らせを、弱い参照で受け渡す中継。
///
/// `WKUserContentController.add(_:name:)` は受け手を**強く**持つ。
/// ナビゲータを直に渡すと
///
///   ナビゲータ → WKWebView → configuration → userContentController → ナビゲータ
///
/// で輪になり、ウィンドウを閉じても解放されない。deinit そのものが呼ばれないので、
/// そこで外す形では切れない。間に弱い参照を 1 枚挟んで断つ。
///
/// 1 つ残るたびに WebKit のプロセスと描画の資源が居座るため、
/// 多数の書籍を開いて閉じる使い方で効いてくる。
@MainActor
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    nonisolated func userContentController(_ controller: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            target?.userContentController(controller, didReceive: message)
        }
    }
}
