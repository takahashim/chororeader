import AppKit
import Combine
import WebKit

/// リフロー型 EPUB のナビゲータ。WKWebView を所有し、SwiftUI View の再生成では作り直さない。
@MainActor
final class WebNavigatorController: NSObject, ObservableObject, WKNavigationDelegate,
                                    WKScriptMessageHandler, WKUIDelegate {
    let document: BookDocument
    let settings: ReaderSettings
    let schemeHandler: ResourceSchemeHandler
    private(set) var webView: WKWebView!

    @Published private(set) var locator: Locator
    @Published private(set) var isLoading = false
    @Published private(set) var chapterTitle: String = ""

    /// ⌘クリックなど、別ウィンドウで開く要求。
    var onOpenInNewWindow: ((Locator) -> Void)?
    /// 履歴へ積むべき移動が起きたことの通知。
    var onNavigated: ((Locator) -> Void)?
    var onStatus: ((String?) -> Void)?

    /// リンク先を移動せずに見せるための要求。ビュー側でポップオーバーとして出す。
    @Published var preview: PreviewRequest?

    /// いま強調している当たり。章を読み込むたびに当て直し、検索をやめると消える。
    var mark: SearchMark? {
        didSet {
            // 押した直後の 1 回だけ、囲んだところまで送る。
            // あとで通りかかったときは、配られた印がそのまま残る。
            markApproach = mark != nil && mark != oldValue
            // 印は配信の瞬間に入る。次に章を配ってもらうときのために、先に置いておく。
            schemeHandler.mark = mark.map { ($0.query, $0.nth) }
            // 外すだけなら配り直さなくてよい。配り直すと画面がちらつく。
            if mark == nil {
                webView.evaluateJavaScript("window.choroClearMarks && window.choroClearMarks()")
            }
        }
    }
    private var markApproach = false

    private var pendingRestore: Locator?
    private var settingsObserver: AnyCancellable?
    private var previewWebView: WKWebView?
    /// クリックされたリンクの位置。移動の判断より先に注入スクリプトから届く。
    private var lastLinkRect: CGRect?

    private var readingOrder: [Link] { document.publication?.readingOrder ?? [] }

    init(document: BookDocument, settings: ReaderSettings, start: Locator?) {
        self.document = document
        self.settings = settings
        guard let resources = document.resources else {
            fatalError("WebNavigatorController は本文リソースを必要とする")
        }
        schemeHandler = ResourceSchemeHandler(resources: resources)
        let first = document.publication?.readingOrder.first?.href
        locator = start ?? Locator(href: first, progression: 0)
        super.init()

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: ResourceSchemeHandler.scheme)
        // 書籍由来の JavaScript は動かさない。注入スクリプトだけが動く。
        config.defaultWebpagePreferences.allowsContentJavaScript = false

        let controller = WKUserContentController()
        // 受け手は強く持たれる。輪にしないため弱い中継を挟む（WeakScriptMessageHandler）。
        controller.add(WeakScriptMessageHandler(self), name: "choro")
        config.userContentController = controller

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")

        installUserScripts()
        applyTheme()

        settingsObserver = settings.objectWillChange
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.applyStyleToLivePage() }

        load(locator: locator, pushHistory: false)
    }

    // MARK: - 移動

    func load(locator target: Locator, pushHistory: Bool = true) {
        guard let href = target.href, let url = ResourceSchemeHandler.url(forHref: href, fragment: target.fragment) else { return }
        if pushHistory { onNavigated?(locator) }
        pendingRestore = target
        locator = target
        chapterTitle = title(forHref: href)
        isLoading = true
        webView.load(URLRequest(url: url))
    }

    func reveal(_ target: Locator) {
        // 当たりへ飛ぶときは読み直す。印は配信の瞬間に入るので、そのままでは付かない。
        if markApproach, mark?.target.href == target.href {
            load(locator: target)
            return
        }
        // 同じ章の中なら読み直さずに動く。
        if target.href == locator.href, !isLoading {
            onNavigated?(locator)
            locator.progression = target.progression
            locator.fragment = target.fragment
            locator.text = target.text
            restore(target)
        } else {
            load(locator: target)
        }
    }

    var currentIndex: Int? {
        guard let href = locator.href else { return nil }
        return readingOrder.firstIndex { $0.href == href }
    }
    var canGoNextChapter: Bool { (currentIndex ?? readingOrder.count) < readingOrder.count - 1 }
    var canGoPrevChapter: Bool { (currentIndex ?? 0) > 0 }

    func goNextChapter() {
        guard let i = currentIndex, i + 1 < readingOrder.count else { return }
        load(locator: Locator(href: readingOrder[i + 1].href, progression: 0))
    }

    func goPrevChapter() {
        guard let i = currentIndex, i > 0 else { return }
        load(locator: Locator(href: readingOrder[i - 1].href, progression: 0))
    }

    func copySelection() {
        selectedText { text in
            guard let text, !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// いま選んでいる本文。**取り出しに一往復かかる**ので、返し手で受ける。
    func selectedText(_ hand: @escaping (String?) -> Void) {
        webView.evaluateJavaScript("window.choroSelectedText()") { value, _ in
            hand(value as? String)
        }
    }

    // MARK: - スタイル

    private func installUserScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        let css = settings.userCSS() + "\n" + ReaderScripts.chromeCSS
        controller.addUserScript(WKUserScript(source: ReaderScripts.styleScript(css: css),
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: ReaderScripts.mainScript,
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    private func applyStyleToLivePage() {
        installUserScripts()
        applyTheme()
        let css = settings.userCSS() + "\n" + ReaderScripts.chromeCSS
        webView.evaluateJavaScript("window.choroSetStyle && window.choroSetStyle(\(ReaderScripts.quote(css)))")
        applyForegroundMarking()
    }

    /// 文字色を当てる要素を選び直す。テーマを変えたときと、章を読み込んだときに呼ぶ。
    private func applyForegroundMarking() {
        let enabled = settings.needsForegroundMarking
        webView.evaluateJavaScript("window.choroApplyForeground && window.choroApplyForeground(\(enabled))")
    }

    private func applyTheme() {
        let color = NSColor(hexString: settings.theme.background) ?? .textBackgroundColor
        webView.underPageBackgroundColor = color
        webView.appearance = settings.theme.appearance
    }

    // MARK: - 復元

    private func restore(_ target: Locator) {
        if let fragment = target.fragment, !fragment.isEmpty {
            webView.evaluateJavaScript("window.choroScrollToFragment(\(ReaderScripts.quote(fragment)))") { [weak self] ok, _ in
                if (ok as? Bool) != true { self?.restoreByTextOrProgression(target) }
            }
        } else {
            restoreByTextOrProgression(target)
        }
    }

    private func restoreByTextOrProgression(_ target: Locator) {
        if let text = target.text, !text.isEmpty {
            webView.evaluateJavaScript("window.choroScrollToText(\(ReaderScripts.quote(text)))") { [weak self] ok, _ in
                if (ok as? Bool) != true {
                    self?.webView.evaluateJavaScript("window.choroScrollToProgression(\(target.progression))")
                }
            }
        } else if target.progression > 0 {
            webView.evaluateJavaScript("window.choroScrollToProgression(\(target.progression))")
        }
    }

    /// 目次に対応する項目がない章（表紙など）では、ファイル名を出さずに空にする。
    private func title(forHref href: String) -> String {
        document.publication?.title(forHref: href) ?? ""
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else {
            decisionHandler(.allow)
            return
        }

        if action.navigationType == .linkActivated {
            let wantsNewWindow = action.modifierFlags.contains(.command)

            if url.scheme == ResourceSchemeHandler.scheme, let href = ResourceSchemeHandler.href(from: url) {
                let target = Locator(href: href, progression: 0,
                                     fragment: url.fragment?.removingPercentEncoding,
                                     title: title(forHref: href))
                decisionHandler(.cancel)
                if wantsNewWindow {
                    onOpenInNewWindow?(target)
                } else if showFootnotePreview(for: target) {
                    // 脚注は移動せずにその場で見せる。本文の位置を失わせない。
                } else if href == locator.href {
                    onNavigated?(locator)
                    locator.fragment = target.fragment
                    restore(target)
                } else {
                    load(locator: target)
                }
                return
            }

            // 外部 URL は OS のブラウザへ渡す。WebView からは外部へ出さない。
            if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                decisionHandler(.cancel)
                onStatus?(url.absoluteString)
                NSWorkspace.shared.open(url)
                return
            }
        }

        // 書籍内リソース以外の読み込みは許可しない。
        if url.scheme == ResourceSchemeHandler.scheme || url.scheme == "about" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        applyForegroundMarking()
        showChapterEndAffordance()
        if let target = pendingRestore {
            pendingRestore = nil
            // 当たりへ飛んだときは、囲まれたところへ送るのが位置の復元より正確なので、そちらに譲る。
            if !(markApproach && marksHere) { restore(target) }
        }
        approachMark()
    }

    // MARK: - 当たりの強調

    /// この章に当たりがあるか。ほかの章では、目当ての語が出ていても囲まない。
    private var marksHere: Bool {
        guard let mark else { return false }
        return mark.target.href == locator.href
    }

    /// 配られた本文に入っている印まで送る。押した直後の 1 回だけ。
    private func approachMark() {
        guard markApproach, marksHere else { return }
        markApproach = false
        webView.evaluateJavaScript("window.choroApproachMark && window.choroApproachMark()")
    }

    /// 章末に次の章への行き先を出す。最後の章では何も出さない。
    private func showChapterEndAffordance() {
        guard let index = currentIndex, index + 1 < readingOrder.count else {
            webView.evaluateJavaScript("window.choroSetChapterEnd && window.choroSetChapterEnd(null)")
            return
        }
        let next = readingOrder[index + 1].href
        let title = document.publication?.title(forHref: next)
        let label = title.map { "次の章へ　\($0)" } ?? "次の章へ"
        webView.evaluateJavaScript("window.choroSetChapterEnd && window.choroSetChapterEnd(\(ReaderScripts.quote(label)))")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }

    // MARK: - 注入スクリプトからの通知

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "position":
            locator.progression = (body["progression"] as? Double) ?? locator.progression
            locator.text = body["text"] as? String
            locator.title = chapterTitle

        case "nextChapter":
            if canGoNextChapter { goNextChapter() }

        case "prevChapter":
            if canGoPrevChapter { goPrevChapter() }

        case "arrow":
            // 右開きの書籍では、右が前へ戻る向きになる。
            let rtl = document.publication?.direction == .rtl
            let forward = (body["side"] as? String == "right") != rtl
            if forward { goNextChapter() } else { goPrevChapter() }

        case "copyCode":
            if let text = body["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                onStatus?("コードをコピーしました")
            }

        case "preview":
            showPreview(body)

        case "previewCancel":
            preview = nil

        case "linkRect":
            lastLinkRect = rect(from: body["rect"])

        default:
            break
        }
    }

    // MARK: - プレビュー

    /// 本文と同じ設定を当てた小さな WebView。ポップオーバーのたびに作り直さず使い回す。
    var previewView: WKWebView {
        if let previewWebView { return previewWebView }
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: ResourceSchemeHandler.scheme)
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = NSColor(hexString: settings.theme.background) ?? .textBackgroundColor
        previewWebView = view
        return view
    }

    private func showPreview(_ body: [String: Any]) {
        guard let rawHref = body["href"] as? String, let frame = rect(from: body["rect"]) else { return }
        let parts = EPUBParser.stripFragment(rawHref)
        guard let target = resolveTarget(path: parts.path, fragment: parts.fragment) else { return }
        present(target: target, anchor: frame, forceFootnote: body["noteref"] as? Bool ?? false)
    }

    /// 脚注リンクなら、その場に吹き出しを出して移動を止める。戻り値はポップオーバーを出したかどうか。
    private func showFootnotePreview(for target: Locator) -> Bool {
        guard target.fragment != nil, let anchor = lastLinkRect else { return false }
        return present(target: target, anchor: anchor, forceFootnote: false, footnoteOnly: true)
    }

    private func resolveTarget(path: String, fragment: String?) -> Locator? {
        guard let resources = document.resources, let currentHref = locator.href else { return nil }
        let base = (currentHref as NSString).deletingLastPathComponent
        let href = path.isEmpty ? currentHref : EPUBParser.resolve(base: base, href: path)
        guard resources.contains(href) else { return nil }
        return Locator(href: href, progression: 0, fragment: fragment,
                       title: document.publication?.title(forHref: href))
    }

    @discardableResult
    private func present(target: Locator, anchor: CGRect,
                         forceFootnote: Bool, footnoteOnly: Bool = false) -> Bool {
        guard let resources = document.resources, let href = target.href else { return false }
        let css = settings.userCSS() + "\n" + ReaderScripts.chromeCSS
        guard let built = PreviewProvider.make(resources: resources, href: href,
                                               fragment: target.fragment, css: css) else { return false }
        let isFootnote = built.isFootnote || forceFootnote
        if footnoteOnly, !isFootnote { return false }

        schemeHandler.provideSynthetic(path: built.path, html: built.html)

        // 同じリンクを指したまま出し直すと点滅するため、変化したときだけ差し替える。
        if let existing = preview, existing.target == target, existing.anchor == anchor { return true }
        preview = PreviewRequest(target: target, anchor: anchor,
                                 isFootnote: isFootnote, resourcePath: built.path)
        if let url = ResourceSchemeHandler.url(forHref: built.path) {
            previewView.load(URLRequest(url: url))
        }
        return true
    }

    private func rect(from value: Any?) -> CGRect? {
        guard let dict = value as? [String: Any] else { return nil }
        return CGRect(x: (dict["x"] as? Double) ?? 0, y: (dict["y"] as? Double) ?? 0,
                      width: max((dict["w"] as? Double) ?? 1, 1),
                      height: max((dict["h"] as? Double) ?? 1, 1))
    }

    func dismissPreview() {
        preview = nil
    }
}

struct PreviewRequest: Identifiable, Equatable {
    let id = UUID()
    var target: Locator
    var anchor: CGRect
    var isFootnote: Bool
    var resourcePath: String

    static func == (lhs: PreviewRequest, rhs: PreviewRequest) -> Bool {
        lhs.target == rhs.target && lhs.anchor == rhs.anchor
    }
}

extension NSColor {
    convenience init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        s = ""
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }
}
