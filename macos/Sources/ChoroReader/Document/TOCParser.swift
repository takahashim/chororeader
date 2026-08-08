import Foundation

/// 目次（EPUB3 の nav と EPUB2 の NCX）を SAX で読む。
///
/// XMLDocument は要素間の空白だけのテキストノードを捨てるため、
/// `<strong>見出し</strong> <span>副題</span>` のような目次で語が繋がってしまう。
/// `.nodePreserveWhitespace` を付けても戻らないので、空白をそのまま受け取れる SAX を使う。
enum TOCParser {
    static func parseNavDocument(_ data: Data, base: String) -> [TOCEntry] {
        let delegate = NavDelegate(base: base)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.result()
    }

    static func parseNCX(_ data: Data, base: String) -> [TOCEntry] {
        let delegate = NCXDelegate(base: base)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.roots
    }

    /// 接頭辞つきで届く要素名から局所名を取り出す。
    fileprivate static func localName(_ name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }

    fileprivate static func target(base: String, rawHref: String?) -> (href: String?, fragment: String?) {
        guard let rawHref else { return (nil, nil) }
        let parts = EPUBParser.stripFragment(rawHref)
        let href = parts.path.isEmpty ? nil : EPUBParser.resolve(base: base, href: parts.path)
        return (href, parts.fragment)
    }
}

private struct Frame {
    var title = ""
    var href: String?
    var fragment: String?
    var children: [TOCEntry] = []
}

private final class NavDelegate: NSObject, XMLParserDelegate {
    private let base: String
    private var collected: [(isTOC: Bool, entries: [TOCEntry])] = []

    private var navDepth = 0
    private var currentIsTOC = false
    private var listStack: [[TOCEntry]] = []
    private var itemStack: [Frame] = []
    private var roots: [TOCEntry] = []
    private var capturingText = false

    init(base: String) {
        self.base = base
    }

    func result() -> [TOCEntry] {
        collected.first { $0.isTOC }?.entries ?? collected.first?.entries ?? []
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        switch TOCParser.localName(name) {
        case "nav":
            navDepth += 1
            if navDepth == 1 {
                let type = attributes["epub:type"] ?? attributes["type"] ?? ""
                currentIsTOC = type.contains("toc")
                listStack = []
                itemStack = []
                roots = []
            }

        case "ol" where navDepth > 0:
            listStack.append([])

        case "li" where navDepth > 0:
            itemStack.append(Frame())

        case "a", "span":
            guard navDepth > 0, !itemStack.isEmpty else { return }
            if itemStack[itemStack.count - 1].href == nil {
                let target = TOCParser.target(base: base, rawHref: attributes["href"])
                itemStack[itemStack.count - 1].href = target.href
                itemStack[itemStack.count - 1].fragment = target.fragment
            }
            capturingText = true

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capturingText, !itemStack.isEmpty else { return }
        itemStack[itemStack.count - 1].title += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch TOCParser.localName(name) {
        case "a", "span":
            capturingText = false

        case "li" where navDepth > 0:
            guard !itemStack.isEmpty else { return }
            let frame = itemStack.removeLast()
            let title = frame.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty || frame.href != nil || !frame.children.isEmpty else { return }
            let entry = TOCEntry(title: title.isEmpty ? "(無題)" : title,
                                 href: frame.href, fragment: frame.fragment, children: frame.children)
            if listStack.isEmpty {
                roots.append(entry)
            } else {
                listStack[listStack.count - 1].append(entry)
            }

        case "ol" where navDepth > 0:
            guard !listStack.isEmpty else { return }
            let finished = listStack.removeLast()
            if itemStack.isEmpty {
                if roots.isEmpty { roots = finished } else { roots.append(contentsOf: finished) }
            } else {
                itemStack[itemStack.count - 1].children.append(contentsOf: finished)
            }

        case "nav":
            navDepth -= 1
            if navDepth == 0 {
                collected.append((currentIsTOC, roots))
                roots = []
            }

        default:
            break
        }
    }
}

private final class NCXDelegate: NSObject, XMLParserDelegate {
    private let base: String
    private var itemStack: [Frame] = []
    private(set) var roots: [TOCEntry] = []
    private var inNavMap = false
    private var capturingText = false
    private var inNavLabel = false

    init(base: String) {
        self.base = base
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        switch TOCParser.localName(name) {
        case "navMap":
            inNavMap = true
        case "navPoint" where inNavMap:
            itemStack.append(Frame())
        case "navLabel":
            inNavLabel = true
        case "text" where inNavLabel:
            capturingText = true
        case "content" where inNavMap:
            guard !itemStack.isEmpty, itemStack[itemStack.count - 1].href == nil else { return }
            let target = TOCParser.target(base: base, rawHref: attributes["src"])
            itemStack[itemStack.count - 1].href = target.href
            itemStack[itemStack.count - 1].fragment = target.fragment
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capturingText, !itemStack.isEmpty else { return }
        itemStack[itemStack.count - 1].title += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch TOCParser.localName(name) {
        case "text":
            capturingText = false
        case "navLabel":
            inNavLabel = false
        case "navPoint" where inNavMap:
            guard !itemStack.isEmpty else { return }
            let frame = itemStack.removeLast()
            let title = frame.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = TOCEntry(title: title.isEmpty ? "(無題)" : title,
                                 href: frame.href, fragment: frame.fragment, children: frame.children)
            if itemStack.isEmpty {
                roots.append(entry)
            } else {
                itemStack[itemStack.count - 1].children.append(entry)
            }
        case "navMap":
            inNavMap = false
        default:
            break
        }
    }
}
