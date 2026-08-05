import Foundation

/// リンク先を移動せずに確かめるための、小さな抜粋を組み立てる。
/// 本文と同じスキームハンドラ経由で配信するので、抜粋の中の画像や CSS もそのまま解決される。
enum PreviewProvider {
    /// 抜粋に入れる本文の目安。脚注はこれよりずっと短く収まる。
    private static let budget = 1200

    static let syntheticName = "__tzr_preview__.xhtml"

    struct Preview {
        /// スキームハンドラへ差し込む合成リソースの位置。相対参照が解けるよう、対象と同じ階層に置く。
        var path: String
        var html: String
        var isFootnote: Bool
    }

    static func make(resources: ResourceProvider, href: String, fragment: String?, css: String) -> Preview? {
        guard let data = try? resources.read(href) else { return nil }
        let source = CSSCompat.rewriteXHTML(CSSCompat.decodeText(data)).css

        let extracted = extract(from: source, fragment: fragment)
        guard !extracted.body.isEmpty else { return nil }

        let directory = (href as NSString).deletingLastPathComponent
        let path = directory.isEmpty ? syntheticName : "\(directory)/\(syntheticName)"

        // 抜粋には epub:type のような接頭辞付き属性が混ざる。XHTML として解釈させると
        // 名前空間が宣言されていない断片で丸ごとパースに失敗するため、HTML として配信する。
        let html = """
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><meta charset="utf-8"/><style>
        \(css)
        html, body { margin: 0 !important; padding: 12px 14px !important; max-width: none !important; }
        body { font-size: 0.94em !important; }
        h1, h2, h3, h4, h5, h6 { margin-top: 0 !important; }
        a { pointer-events: none; }
        img, svg { max-width: 100% !important; height: auto !important; }
        </style></head>
        <body>\(extracted.body)</body>
        </html>
        """

        return Preview(path: path, html: html, isFootnote: extracted.isFootnote)
    }

    // MARK: - 抜粋の取り出し

    private struct Extracted {
        var body: String
        var isFootnote: Bool
    }

    private static func extract(from source: String, fragment: String?) -> Extracted {
        guard let document = parse(source) else {
            return Extracted(body: escapedPlainText(source), isFootnote: false)
        }

        guard let fragment, !fragment.isEmpty else {
            return Extracted(body: leadingContent(of: document), isFootnote: false)
        }

        guard let target = element(withID: fragment, in: document) else {
            return Extracted(body: leadingContent(of: document), isFootnote: false)
        }

        // 脚注は要素 1 つで完結する。前後を足すとかえって読みにくい。
        if isFootnoteElement(target) {
            return Extracted(body: target.xmlString, isFootnote: true)
        }

        var html = target.xmlString
        var length = target.stringValue?.count ?? 0
        var node = target.nextSibling
        while length < budget, let current = node {
            if let element = current as? XMLElement {
                html += element.xmlString
                length += element.stringValue?.count ?? 0
            }
            node = current.nextSibling
        }
        return Extracted(body: html, isFootnote: false)
    }

    private static func isFootnoteElement(_ element: XMLElement) -> Bool {
        let type = (element.attribute(forName: "epub:type")?.stringValue ?? "")
            + " " + (element.attribute(forName: "role")?.stringValue ?? "")
        if type.contains("footnote") || type.contains("note") || type.contains("doc-footnote") { return true }
        let name = element.localName ?? element.name ?? ""
        return name == "aside"
    }

    private static func element(withID id: String, in document: XMLDocument) -> XMLElement? {
        // id に引用符が入る書籍があるため、XPath へ直接埋め込まずに走査する。
        guard let all = try? document.nodes(forXPath: "//*[@id]") else { return nil }
        return all.compactMap { $0 as? XMLElement }
            .first { $0.attribute(forName: "id")?.stringValue == id }
    }

    private static func leadingContent(of document: XMLDocument) -> String {
        guard let body = (try? document.nodes(forXPath: "//*[local-name()='body']"))?
            .compactMap({ $0 as? XMLElement }).first else { return "" }
        var html = ""
        var length = 0
        for child in body.children ?? [] {
            guard let element = child as? XMLElement else { continue }
            html += element.xmlString
            length += element.stringValue?.count ?? 0
            if length >= budget { break }
        }
        return html
    }

    private static func parse(_ source: String) -> XMLDocument? {
        let data = Data(source.utf8)
        if let document = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]) {
            return document
        }
        return try? XMLDocument(data: data, options: [.documentTidyXML, .nodeLoadExternalEntitiesNever])
    }

    /// XML として読めない章のための最後の手段。整形は諦め、文字だけ見せる。
    private static func escapedPlainText(_ source: String) -> String {
        let text = HTMLText.stripTags(source).prefix(budget)
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<p>\(escaped)</p>"
    }
}
