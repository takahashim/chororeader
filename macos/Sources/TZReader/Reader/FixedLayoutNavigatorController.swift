import AppKit
import Combine
import WebKit

/// 固定レイアウト EPUB（ページが画像や固定配置の書籍）の表示。
///
/// ページを合成した 1 枚の文書として WebView へ渡す。
/// 画像の復号と拡大は WebKit に任せられるため、自前で描画するより実装が小さく、
/// 本文用のスキームハンドラとテーマ設定をそのまま使い回せる。
@MainActor
final class FixedLayoutNavigatorController: NSObject, ObservableObject, WKNavigationDelegate,
                                            WKScriptMessageHandler {
    /// ページの中身。画像 1 枚で構成されるページと、そうでないページを区別する。
    enum PageContent {
        case image(href: String)
        case document(href: String)
    }

    let document: BookDocument
    let settings: ReaderSettings
    let schemeHandler: ResourceSchemeHandler
    private(set) var webView: WKWebView!

    @Published private(set) var locator: Locator
    @Published private(set) var pageLabel: String = ""

    var onNavigated: ((Locator) -> Void)?
    var onOpenInNewWindow: ((Locator) -> Void)?
    var onStatus: ((String?) -> Void)?

    private(set) var pages: [PageContent] = []
    private var spreads: [[Int]] = []
    private var settingsObserver: AnyCancellable?
    private var syntheticCounter = 0

    var pageCount: Int { pages.count }
    var currentPage: Int { locator.page ?? 0 }
    private var isRTL: Bool { document.publication?.direction == .rtl }

    init(document: BookDocument, settings: ReaderSettings, start: Locator?) {
        self.document = document
        self.settings = settings
        guard let resources = document.resources, let publication = document.publication else {
            fatalError("FixedLayoutNavigatorController は本文リソースを必要とする")
        }
        schemeHandler = ResourceSchemeHandler(resources: resources)

        // 開始位置はページ番号で受けるが、目次や別ウィンドウからは href で来ることもある。
        let requested = start?.page ?? start?.href.flatMap { publication.index(ofHref: $0) } ?? 0
        let lastIndex = max(publication.readingOrder.count - 1, 0)
        let index = min(max(requested, 0), lastIndex)
        locator = Locator(href: publication.readingOrder[safe: index]?.href,
                          page: index,
                          progression: lastIndex > 0 ? Double(index) / Double(lastIndex) : 0)
        super.init()

        pages = publication.readingOrder.map { link in
            Self.pageContent(for: link.href, resources: resources)
        }
        spreads = Self.spreads(pageCount: pages.count, rtl: isRTL)

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: ResourceSchemeHandler.scheme)
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let controller = WKUserContentController()
        controller.add(self, name: "tzr")
        // 左右キーは「次の単位へ」。並べ方によらず意味を変えない。
        controller.addUserScript(WKUserScript(source: Self.keyScript,
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController = controller

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        // ピンチと ⌘+ / ⌘- による拡大は WebKit の機能をそのまま使う。
        webView.allowsMagnification = true

        settingsObserver = settings.objectWillChange
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.render() }

        render()
    }

    // MARK: - 移動

    func go(toPage index: Int, pushHistory: Bool = true) {
        let clamped = max(0, min(index, max(pages.count - 1, 0)))
        guard clamped != currentPage || pageLabel.isEmpty else { return }
        if pushHistory { onNavigated?(locator) }
        locator.page = clamped
        locator.href = document.publication?.readingOrder[safe: clamped]?.href
        locator.progression = pages.count > 1 ? Double(clamped) / Double(pages.count - 1) : 0
        render()
    }

    func reveal(_ target: Locator) {
        if let page = target.page {
            go(toPage: page)
        } else if let href = target.href,
                  let index = document.publication?.index(ofHref: href) {
            go(toPage: index)
        }
    }

    /// 左右キーは「次の単位へ」。並べ方によらず意味を変えない。
    func moveHorizontally(toRight: Bool) {
        let forward = toRight != isRTL
        step(forward: forward)
    }

    func goNextPage() { step(forward: true) }
    func goPrevPage() { step(forward: false) }

    private func step(forward: Bool) {
        switch settings.pageLayout {
        case .spread:
            guard let current = spreads.firstIndex(where: { $0.contains(currentPage) }) else { return }
            let next = forward ? current + 1 : current - 1
            guard let target = spreads[safe: next]?.first else { return }
            go(toPage: target)
        case .singlePage, .continuousScroll:
            go(toPage: currentPage + (forward ? 1 : -1))
        }
    }

    func zoomIn() { webView.magnification = min(webView.magnification * 1.25, 8) }
    func zoomOut() { webView.magnification = max(webView.magnification / 1.25, 0.2) }
    func zoomToFit() { webView.magnification = 1 }

    // MARK: - 描画

    private func render() {
        guard !pages.isEmpty else { return }
        let indices: [Int]
        switch settings.pageLayout {
        case .continuousScroll:
            indices = Array(pages.indices)
        case .singlePage:
            indices = [currentPage]
        case .spread:
            indices = spreads.first { $0.contains(currentPage) } ?? [currentPage]
        }

        // 合成文書はアーカイブ直下に置く。ページの参照は先頭からの絶対パスで書くため、階層に依存しない。
        syntheticCounter += 1
        let path = "__tzr_fixed_\(syntheticCounter).xhtml"
        schemeHandler.provideSynthetic(path: path, html: html(for: indices))
        if let url = ResourceSchemeHandler.url(forHref: path) {
            webView.load(URLRequest(url: url))
        }
        updateLabel()
    }

    private func updateLabel() {
        guard !pages.isEmpty else { return }
        if settings.pageLayout == .spread, let spread = spreads.first(where: { $0.contains(currentPage) }),
           spread.count == 2 {
            let left = isRTL ? spread[1] : spread[0]
            let right = isRTL ? spread[0] : spread[1]
            pageLabel = "\(left + 1)–\(right + 1) / \(pages.count)"
        } else {
            pageLabel = "\(currentPage + 1) / \(pages.count)"
        }
        locator.title = "\(currentPage + 1) ページ"
    }

    private func html(for indices: [Int]) -> String {
        let background = settings.theme.background
        let continuous = settings.pageLayout == .continuousScroll
        let spreadMode = settings.pageLayout == .spread && indices.count > 1

        let items = indices.map { index -> String in
            let element: String
            switch pages[safe: index] {
            case let .image(href):
                let url = ResourceSchemeHandler.url(forHref: href)?.absoluteString ?? ""
                // 連続表示では見えているページだけ復号させる。
                element = "<img class=\"tzr-page\" src=\"\(url)\"\(continuous ? " loading=\"lazy\"" : "") alt=\"\"/>"
            case let .document(href):
                let url = ResourceSchemeHandler.url(forHref: href)?.absoluteString ?? ""
                element = "<iframe class=\"tzr-page tzr-page-frame\" src=\"\(url)\"></iframe>"
            case nil:
                element = ""
            }
            return "<div class=\"tzr-slot\" id=\"tzr-page-\(index)\">\(element)</div>"
        }

        // 見開きは綴じ方向に従って左右を入れ替える。
        let ordered = spreadMode && isRTL ? items.reversed().joined() : items.joined()

        let fit: String
        switch settings.pageFit {
        case .whole:
            fit = "max-width: 100%; max-height: 100vh; width: auto; height: auto;"
        case .width:
            fit = "width: 100%; height: auto;"
        case .actual:
            fit = "width: auto; height: auto;"
        }

        return """
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><meta charset="utf-8"/><style>
        html, body { margin: 0; padding: 0; background: \(background); }
        body {
            display: flex;
            flex-direction: \(continuous ? "column" : "row");
            align-items: center;
            justify-content: center;
            gap: \(continuous ? "12px" : "0");
            min-height: 100vh;
        }
        .tzr-slot { display: flex; align-items: center; justify-content: center; }
        .tzr-page { display: block; \(fit) }
        .tzr-page-frame { border: 0; width: 100vw; height: 100vh; }
        </style></head>
        <body>\(ordered)</body></html>
        """
    }

    // MARK: - ページの中身を見分ける

    /// ページが画像 1 枚で構成されているなら、その画像を直接表示する。
    /// 文字が固定座標で置かれているページは、元の XHTML をそのまま埋め込む。
    static func pageContent(for href: String, resources: ResourceProvider) -> PageContent {
        guard let data = try? resources.read(href) else { return .document(href: href) }
        let source = CSSCompat.decodeText(data)
        guard let reference = primaryImageReference(in: source) else { return .document(href: href) }
        let base = (href as NSString).deletingLastPathComponent
        let resolved = EPUBParser.resolve(base: base, href: reference)
        guard resources.contains(resolved) else { return .document(href: href) }

        // 画像以外に本文が載っているページは、画像だけを出すと内容が落ちる。
        let text = HTMLText.stripTags(source).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count < 40 else { return .document(href: href) }
        return .image(href: resolved)
    }

    private static func primaryImageReference(in html: String) -> String? {
        let patterns = [
            #"(?i)<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#,
            #"(?i)<image\b[^>]*\bxlink:href\s*=\s*["']([^"']+)["']"#,
            #"(?i)<image\b[^>]*\bhref\s*=\s*["']([^"']+)["']"#,
        ]
        var found: [String] = []
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let range = Range(match.range(at: 1), in: html) else { continue }
                found.append(String(html[range]))
            }
        }
        // 画像が複数あるページは、単純な 1 枚もののページではない。
        return found.count == 1 ? found.first : nil
    }

    /// 見開きの組み方。表紙は単独で見せ、以降を 2 枚ずつまとめる。
    static func spreads(pageCount: Int, rtl: Bool) -> [[Int]] {
        guard pageCount > 0 else { return [] }
        var result: [[Int]] = [[0]]
        var index = 1
        while index < pageCount {
            if index + 1 < pageCount {
                result.append([index, index + 1])
                index += 2
            } else {
                result.append([index])
                index += 1
            }
        }
        return result
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.allow) }
        if action.navigationType == .linkActivated,
           let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            decisionHandler(.cancel)
            onStatus?(url.absoluteString)
            NSWorkspace.shared.open(url)
            return
        }
        decisionHandler(url.scheme == ResourceSchemeHandler.scheme || url.scheme == "about" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard settings.pageLayout == .continuousScroll else { return }
        webView.evaluateJavaScript("""
        (function () {
          var el = document.getElementById('tzr-page-\(currentPage)');
          if (el) { el.scrollIntoView(true); }
          return true;
        })();
        """)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["kind"] as? String == "arrow" else { return }
        moveHorizontally(toRight: body["side"] as? String == "right")
    }

    private static let keyScript = """
    (function () {
      document.addEventListener('keydown', function (e) {
        if (e.metaKey || e.ctrlKey || e.altKey) return;
        if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') return;
        e.preventDefault();
        try {
          window.webkit.messageHandlers.tzr.postMessage({
            kind: 'arrow', side: e.key === 'ArrowRight' ? 'right' : 'left'
          });
        } catch (err) {}
      });
    })();
    """
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
