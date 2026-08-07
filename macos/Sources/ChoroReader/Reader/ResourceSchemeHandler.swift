import Foundation
import WebKit

/// 本文とその周辺リソースを WebView へ供給する。供給範囲は ResourceProvider が決める。
/// CSS の互換変換はここで、配信の瞬間に行う。元ファイルは書き換えない。
final class ResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "chororeader"

    private let resources: ResourceProvider
    private let lock = NSLock()
    private var contentCache: [String: (data: Data, mime: String)] = [:]
    /// 入れた順。頭を打つときに、古いものから捨てるために持つ。
    private var cacheOrder: [String] = []
    private var cacheBytes = 0
    private var changeLog: [String] = []
    private var markRequest: (query: String, nth: Int)?

    init(resources: ResourceProvider) {
        self.resources = resources
    }

    /// いま覚えている総量。頭が効いているかを検査が見る。
    var cachedByteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return cacheBytes
    }

    var cssChangeLog: [String] {
        lock.lock(); defer { lock.unlock() }
        return changeLog
    }

    /// 本文へ入れる当たりの印。検索から飛ぶ前にナビゲータが置く。
    ///
    /// 印は配信の瞬間に入れる。WebView の中で入れると、文字節を切って包む手術を
    /// JavaScript で書くことになり、抽出と数え方がずれる余地が残る。
    var mark: (query: String, nth: Int)? {
        get { lock.lock(); defer { lock.unlock() }; return markRequest }
        set { lock.lock(); defer { lock.unlock() }; markRequest = newValue }
    }

    static func url(forHref href: String, fragment: String? = nil) -> URL? {
        let encoded = href.split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        var s = "\(scheme)://book/\(encoded)"
        if let fragment, !fragment.isEmpty {
            s += "#" + (fragment.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? fragment)
        }
        return URL(string: s)
    }

    static func href(from url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        let path = url.path
        guard path.hasPrefix("/") else { return nil }
        return String(path.dropFirst()).removingPercentEncoding ?? String(path.dropFirst())
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let rawHref = Self.href(from: url) else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        // 相対参照の正規化。アーカイブ外を指す参照は取り出せないので、ここで弾かれる。
        let href = EPUBParser.resolve(base: "", href: rawHref)

        // 印の付き外れは配信時に決まるので、覚えておく鍵にも入れる。
        let wanted = mark
        let key = cacheKey(href, mark: wanted)

        if let cached = cached(key) {
            respond(task, url: url, data: cached.data, mime: cached.mime)
            return
        }

        guard let raw = try? resources.read(href) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let ext = (href as NSString).pathExtension.lowercased()
        var data = raw
        var mime = Self.mimeType(forExtension: ext)

        switch ext {
        case "css":
            let result = CSSCompat.rewrite(css: CSSCompat.decodeText(raw))
            data = Data(result.css.utf8)
            record(result.changes, path: href)
        case "xhtml", "html", "htm":
            let text = CSSCompat.decodeText(raw)
            let result = CSSCompat.rewriteXHTML(text)
            var body = result.css
            if let wanted {
                body = SearchMarkInserter.insert(into: body, query: wanted.query, nth: wanted.nth) ?? body
            }
            data = Data(body.utf8)
            record(result.changes, path: href)
            // XHTML として渡すのは、そう名乗っている文書だけにする。
            // HTML5 でも XML として妥当なことはあり、その場合に XHTML として解釈させると
            // 名前空間が付かず、<style> の中身が本文として表示されてしまう。
            let declaresXHTML = text.hasPrefix("<?xml")
                || text.contains("xmlns=\"http://www.w3.org/1999/xhtml\"")
            mime = (ext == "xhtml" || declaresXHTML) && Self.parsesAsXML(data)
                ? "application/xhtml+xml" : "text/html"
        default:
            break
        }

        store(key, data: data, mime: mime)
        respond(task, url: url, data: data, mime: mime)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    // MARK: - 補助

    private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, mime: String) {
        let isText = mime.hasPrefix("text/") || mime.contains("xml") || mime.contains("javascript")
        let response = URLResponse(url: url, mimeType: mime,
                                   expectedContentLength: data.count,
                                   textEncodingName: isText ? "utf-8" : nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    /// プレビュー用に組み立てた抜粋を、書籍内リソースと同じ経路で配信できるようにする。
    /// 対象と同じ階層へ置くことで、抜粋に含まれる相対参照がそのまま解決される。
    func provideSynthetic(path: String, html: String) {
        lock.lock(); defer { lock.unlock() }
        // 書籍から切り出した断片は名前空間が欠けていることがある。寛容な HTML パーサへ渡す。
        remember(path, data: Data(html.utf8), mime: "text/html")
    }

    /// 覚えておく鍵。同じ章でも、印の有無で中身が変わる。
    private func cacheKey(_ href: String, mark: (query: String, nth: Int)?) -> String {
        guard let mark else { return href }
        return "\(href)\u{0}\(mark.query)\u{0}\(mark.nth)"
    }

    private func cached(_ href: String) -> (data: Data, mime: String)? {
        lock.lock(); defer { lock.unlock() }
        return contentCache[href]
    }

    /// 覚えておける総量。
    ///
    /// 章と CSS は文字なので 1 つは小さいが、際限は無い。読み進めれば章が積み上がり、
    /// 同じ章でも印の付き方ごとに別の 1 つになる（cacheKey）。当たりを次々に押していくと
    /// その分だけ増える。窓が開いているあいだ捨てないので、頭を打っておく。
    static let cacheLimit = 8 * 1024 * 1024

    private func store(_ href: String, data: Data, mime: String) {
        // 章と CSS だけを保持する。画像を溜め込むとメモリを圧迫するため対象外にする。
        let ext = (href as NSString).pathExtension.lowercased()
        guard ["css", "xhtml", "html", "htm"].contains(ext) else { return }
        lock.lock(); defer { lock.unlock() }
        remember(href, data: data, mime: mime)
    }

    /// 覚える。総量が頭を越えたら、古いものから捨てる。
    /// 呼ぶ側が lock を持っていること。
    private func remember(_ key: String, data: Data, mime: String) {
        if let old = contentCache[key] {
            cacheBytes -= old.data.count
            cacheOrder.removeAll { $0 == key }
        }
        contentCache[key] = (data, mime)
        cacheOrder.append(key)
        cacheBytes += data.count

        while cacheBytes > Self.cacheLimit, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            if let dropped = contentCache.removeValue(forKey: oldest) {
                cacheBytes -= dropped.data.count
            }
        }
    }

    private func record(_ changes: [CSSCompat.Change], path: String) {
        guard !changes.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        changeLog.append(contentsOf: changes.map { "\(path): \($0.logLine)" })
    }

    private static func parsesAsXML(_ data: Data) -> Bool {
        (try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])) != nil
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext {
        case "xhtml", "html", "htm": return "application/xhtml+xml"
        case "css": return "text/css"
        case "js": return "text/javascript"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "mp3": return "audio/mpeg"
        case "mp4", "m4v": return "video/mp4"
        case "xml", "ncx", "opf": return "application/xml"
        default: return "application/octet-stream"
        }
    }
}
