import Foundation

/// container.xml から OPF を辿り、spine・目次・書誌情報を取り出す。
/// macOS には XMLDocument があるため、XPath で local-name() を使い名前空間の差異を吸収する。
enum EPUBParser {
    enum Failure: Error {
        case missingContainer
        case missingOPF(String)
        case emptySpine
    }

    static func parse(_ archive: ZipArchive) throws -> EPUBPublication {
        let containerData = try archive.read("META-INF/container.xml")
        guard let opfPath = rootfilePath(in: containerData) else { throw Failure.missingContainer }
        guard archive.contains(opfPath) else { throw Failure.missingOPF(opfPath) }

        let opfData = try archive.read(opfPath)
        let opf = try document(from: opfData)
        let opfDir = (opfPath as NSString).deletingLastPathComponent

        // manifest
        var manifest: [String: Link] = [:]   // id -> Link
        var coverID: String?
        for el in elements(opf, "//*[local-name()='manifest']/*[local-name()='item']") {
            guard let id = el.attribute(forName: "id")?.stringValue,
                  let rawHref = el.attribute(forName: "href")?.stringValue else { continue }
            let href = resolve(base: opfDir, href: stripFragment(rawHref).path)
            let props = Set((el.attribute(forName: "properties")?.stringValue ?? "")
                .split(separator: " ").map(String.init))
            manifest[id] = Link(href: href,
                                mediaType: el.attribute(forName: "media-type")?.stringValue ?? "",
                                id: id,
                                properties: props)
            if props.contains("cover-image") { coverID = id }
        }

        // spine
        var readingOrder: [Link] = []
        var spineProperties: [String] = []
        for el in elements(opf, "//*[local-name()='spine']/*[local-name()='itemref']") {
            guard let idref = el.attribute(forName: "idref")?.stringValue,
                  var link = manifest[idref] else { continue }
            if el.attribute(forName: "linear")?.stringValue == "no" { continue }
            let props = el.attribute(forName: "properties")?.stringValue ?? ""
            spineProperties.append(props)
            link.properties.formUnion(props.split(separator: " ").map(String.init))
            readingOrder.append(link)
        }
        guard !readingOrder.isEmpty else { throw Failure.emptySpine }

        // 書誌情報
        func metaValues(_ name: String) -> [String] {
            nodes(opf, "//*[local-name()='metadata']/*[local-name()='\(name)']")
                .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        let title = metaValues("title").first ?? ""
        let authors = metaValues("creator")
        let language = metaValues("language").first
        let identifier = metaValues("identifier").first

        // レイアウト種別
        let renditionLayout = nodes(opf, "//*[local-name()='meta'][@property='rendition:layout']")
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }.first
        var layout: PublicationLayout = renditionLayout == "pre-paginated" ? .fixed : .reflowable
        if layout == .reflowable,
           spineProperties.contains(where: { $0.contains("rendition:layout-pre-paginated") }) {
            layout = .fixed
        }

        // 綴じ方向
        let ppd = elements(opf, "//*[local-name()='spine']")
            .compactMap { $0.attribute(forName: "page-progression-direction")?.stringValue }
            .first
        let direction: ReadingDirection = (ppd == "rtl") ? .rtl : .ltr

        // 表紙
        if coverID == nil {
            coverID = elements(opf, "//*[local-name()='meta'][@name='cover']")
                .compactMap { $0.attribute(forName: "content")?.stringValue }.first
        }
        let coverHref = coverID.flatMap { manifest[$0]?.href }

        // 目次: EPUB3 の nav を優先し、なければ EPUB2 の NCX を読む
        var toc: [TOCEntry] = []
        if let navLink = manifest.values.first(where: { $0.properties.contains("nav") }),
           let navData = try? archive.read(navLink.href) {
            toc = parseNavDocument(navData, base: (navLink.href as NSString).deletingLastPathComponent)
        }
        if toc.isEmpty {
            let ncxID = elements(opf, "//*[local-name()='spine']")
                .compactMap { $0.attribute(forName: "toc")?.stringValue }.first
            let ncxLink = ncxID.flatMap { manifest[$0] }
                ?? manifest.values.first { $0.mediaType == "application/x-dtbncx+xml" }
            if let ncxLink, let ncxData = try? archive.read(ncxLink.href) {
                toc = parseNCX(ncxData, base: (ncxLink.href as NSString).deletingLastPathComponent)
            }
        }
        if toc.isEmpty {
            toc = readingOrder.map { link in
                TOCEntry(title: (link.href as NSString).lastPathComponent, href: link.href)
            }
        }

        return EPUBPublication(
            title: title.isEmpty ? "(無題)" : title,
            authors: authors,
            language: language,
            identifier: identifier,
            readingOrder: readingOrder,
            tableOfContents: toc,
            coverHref: coverHref,
            layout: layout,
            direction: direction
        )
    }

    // MARK: - 目次

    private static func parseNavDocument(_ data: Data, base: String) -> [TOCEntry] {
        guard let doc = try? document(from: data) else { return [] }
        // epub:type="toc" の nav を優先。無ければ最初の nav。
        let navs = elements(doc, "//*[local-name()='nav']")
        let tocNav = navs.first { el in
            let type = el.attribute(forName: "epub:type")?.stringValue
                ?? el.attribute(forName: "type")?.stringValue
            return type?.contains("toc") == true
        } ?? navs.first
        guard let root = tocNav, let list = elements(root, ".//*[local-name()='ol']").first else { return [] }
        return parseNavList(list, base: base)
    }

    private static func parseNavList(_ list: XMLElement, base: String) -> [TOCEntry] {
        var out: [TOCEntry] = []
        for node in list.children ?? [] {
            guard let li = node as? XMLElement, li.name?.hasSuffix("li") == true else { continue }
            let anchor = elements(li, "./*[local-name()='a']|./*[local-name()='span']").first
            let title = (anchor?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var href: String?
            var fragment: String?
            if let raw = anchor?.attribute(forName: "href")?.stringValue {
                let parts = stripFragment(raw)
                if !parts.path.isEmpty { href = resolve(base: base, href: parts.path) }
                fragment = parts.fragment
            }
            let sublist = elements(li, "./*[local-name()='ol']").first
            let children = sublist.map { parseNavList($0, base: base) } ?? []
            if !title.isEmpty || href != nil || !children.isEmpty {
                out.append(TOCEntry(title: title.isEmpty ? "(無題)" : title,
                                    href: href, fragment: fragment, children: children))
            }
        }
        return out
    }

    private static func parseNCX(_ data: Data, base: String) -> [TOCEntry] {
        guard let doc = try? document(from: data),
              let navMap = elements(doc, "//*[local-name()='navMap']").first
        else { return [] }
        return parseNavPoints(in: navMap, base: base)
    }

    private static func parseNavPoints(in parent: XMLElement, base: String) -> [TOCEntry] {
        var out: [TOCEntry] = []
        for np in elements(parent, "./*[local-name()='navPoint']") {
            let title = (nodes(np, "./*[local-name()='navLabel']/*[local-name()='text']").first?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var href: String?
            var fragment: String?
            if let src = elements(np, "./*[local-name()='content']").first?
                .attribute(forName: "src")?.stringValue {
                let parts = stripFragment(src)
                if !parts.path.isEmpty { href = resolve(base: base, href: parts.path) }
                fragment = parts.fragment
            }
            let children = parseNavPoints(in: np, base: base)
            out.append(TOCEntry(title: title.isEmpty ? "(無題)" : title,
                                href: href, fragment: fragment, children: children))
        }
        return out
    }

    // MARK: - 補助

    private static func nodes(_ node: XMLNode, _ xpath: String) -> [XMLNode] {
        (try? node.nodes(forXPath: xpath)) ?? []
    }

    private static func elements(_ node: XMLNode, _ xpath: String) -> [XMLElement] {
        nodes(node, xpath).compactMap { $0 as? XMLElement }
    }

    private static func rootfilePath(in data: Data) -> String? {
        guard let doc = try? document(from: data) else { return nil }
        let value = elements(doc, "//*[local-name()='rootfile']").first?
            .attribute(forName: "full-path")?.stringValue
        return value?.removingPercentEncoding ?? value
    }

    private static func document(from data: Data) throws -> XMLDocument {
        if let doc = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]) { return doc }
        // 崩れた XHTML を含む書籍があるため、整形して再試行する。
        return try XMLDocument(data: data, options: [.documentTidyXML, .nodeLoadExternalEntitiesNever])
    }

    static func stripFragment(_ href: String) -> (path: String, fragment: String?) {
        guard let hash = href.firstIndex(of: "#") else { return (href, nil) }
        let path = String(href[href.startIndex ..< hash])
        let frag = String(href[href.index(after: hash)...])
        return (path, frag.isEmpty ? nil : frag)
    }

    /// EPUB 内の相対参照を、アーカイブ先頭からのパスへ正規化する。
    static func resolve(base: String, href: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        if decoded.hasPrefix("/") { return String(decoded.dropFirst()) }
        var comps = base.isEmpty ? [] : base.split(separator: "/").map(String.init)
        for part in decoded.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            if part.isEmpty || part == "." { continue }
            if part == ".." { if !comps.isEmpty { comps.removeLast() }; continue }
            comps.append(part)
        }
        return comps.joined(separator: "/")
    }
}
