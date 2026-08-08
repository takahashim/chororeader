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

        func metaValues(_ name: String) -> [String] {
            nodes(opf, "//*[local-name()='metadata']/*[local-name()='\(name)']")
                .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        let title = metaValues("title").first ?? ""
        let authors = metaValues("creator")
        let language = metaValues("language").first
        let identifiers = metaValues("identifier")
        let identifier = identifiers.first
        let publisher = metaValues("publisher").first
        let published = metaValues("date").first

        let subtitle: String? = {
            let subtitleIds = Set(nodes(opf, "//*[local-name()='metadata']/*[local-name()='meta'][@property='title-type']")
                .filter { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) == "subtitle" }
                .compactMap { ($0 as? XMLElement)?.attribute(forName: "refines")?.stringValue }
                .map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 })
            guard !subtitleIds.isEmpty else { return nil }
            return nodes(opf, "//*[local-name()='metadata']/*[local-name()='title']")
                .compactMap { $0 as? XMLElement }
                .first { subtitleIds.contains($0.attribute(forName: "id")?.stringValue ?? "") }?
                .stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }()

        let renditionLayout = nodes(opf, "//*[local-name()='meta'][@property='rendition:layout']")
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }.first
        var layout: PublicationLayout = renditionLayout == "pre-paginated" ? .fixed : .reflowable
        if layout == .reflowable,
           spineProperties.contains(where: { $0.contains("rendition:layout-pre-paginated") }) {
            layout = .fixed
        }

        let ppd = elements(opf, "//*[local-name()='spine']")
            .compactMap { $0.attribute(forName: "page-progression-direction")?.stringValue }
            .first
        let direction: ReadingDirection = (ppd == "rtl") ? .rtl : .ltr

        if coverID == nil {
            coverID = elements(opf, "//*[local-name()='meta'][@name='cover']")
                .compactMap { $0.attribute(forName: "content")?.stringValue }.first
        }
        let coverHref = coverID.flatMap { manifest[$0]?.href }

        // 目次: EPUB3 の nav を優先し、なければ EPUB2 の NCX を読む
        var toc: [TOCEntry] = []
        if let navLink = manifest.values.first(where: { $0.properties.contains("nav") }),
           let navData = try? archive.read(navLink.href) {
            toc = TOCParser.parseNavDocument(navData, base: (navLink.href as NSString).deletingLastPathComponent)
        }
        if toc.isEmpty {
            let ncxID = elements(opf, "//*[local-name()='spine']")
                .compactMap { $0.attribute(forName: "toc")?.stringValue }.first
            let ncxLink = ncxID.flatMap { manifest[$0] }
                ?? manifest.values.first { $0.mediaType == "application/x-dtbncx+xml" }
            if let ncxLink, let ncxData = try? archive.read(ncxLink.href) {
                toc = TOCParser.parseNCX(ncxData, base: (ncxLink.href as NSString).deletingLastPathComponent)
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
            publisher: publisher,
            published: published,
            subtitle: subtitle,
            identifiers: identifiers,
            readingOrder: readingOrder,
            tableOfContents: toc,
            coverHref: coverHref,
            layout: layout,
            direction: direction
        )
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

    /// 空白だけのテキストノードを保つ。
    /// 目次に `<strong>見出し</strong> <span>副題</span>` のような並びがあると、
    /// 捨ててしまった場合に語が繋がってしまうため。
    private static let parseOptions: XMLNode.Options = [
        .nodeLoadExternalEntitiesNever,
        .nodePreserveWhitespace,
    ]

    private static func document(from data: Data) throws -> XMLDocument {
        if let doc = try? XMLDocument(data: data, options: parseOptions) { return doc }
        // 崩れた XHTML を含む書籍があるため、整形して再試行する。
        return try XMLDocument(data: data, options: parseOptions.union([.documentTidyXML]))
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
