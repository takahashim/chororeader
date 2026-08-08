import Foundation

/// 形式共通の読書位置。EPUB は href + 章内 progression、PDF はページ番号を主に使う。
struct Locator: Codable, Hashable {
    var href: String?
    var page: Int?
    var progression: Double
    var fragment: String?
    var title: String?
    /// 復元の最後の手がかり。章の内容が変わっても近い位置へ戻せるようにする。
    var text: String?

    init(href: String? = nil, page: Int? = nil, progression: Double = 0,
         fragment: String? = nil, title: String? = nil, text: String? = nil) {
        self.href = href
        self.page = page
        self.progression = progression
        self.fragment = fragment
        self.title = title
        self.text = text
    }
}

struct Link: Hashable {
    var href: String
    var mediaType: String
    var id: String?
    var properties: Set<String> = []
}

struct TOCEntry: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var href: String?
    var fragment: String?
    var page: Int?
    var children: [TOCEntry] = []

    var hasChildren: Bool { !children.isEmpty }
}

enum PublicationLayout: String, Codable {
    case reflowable
    case fixed
}

enum ReadingDirection: String, Codable {
    case ltr
    case rtl
}

struct EPUBPublication {
    var title: String
    var authors: [String]
    var language: String?
    var identifier: String?
    /// 書誌の素。**プローブの出力には載せない**（`Bibliography` の説明を見よ）。
    var publisher: String?
    var published: String?
    var subtitle: String?
    /// `dc:identifier` は複数ある。ISBN は最初とは限らない。
    var identifiers: [String] = []
    var readingOrder: [Link]
    var tableOfContents: [TOCEntry]
    var coverHref: String?
    var layout: PublicationLayout
    var direction: ReadingDirection

    func index(ofHref href: String) -> Int? {
        readingOrder.firstIndex { $0.href == href }
    }

    func title(forHref href: String) -> String? {
        func search(_ entries: [TOCEntry]) -> String? {
            for e in entries {
                if e.href == href { return e.title }
                if let found = search(e.children) { return found }
            }
            return nil
        }
        return search(tableOfContents)
    }
}

enum DocumentFormat: String, Codable {
    case reflowableEPUB
    case fixedEPUB
    case pdf
    case markdown

    var isEPUB: Bool { self == .reflowableEPUB || self == .fixedEPUB }

    static func detect(url: URL) -> DocumentFormat? {
        switch url.pathExtension.lowercased() {
        case "epub": return .reflowableEPUB  // 固定レイアウトかは OPF を読んで確定する
        case "pdf": return .pdf
        case "md", "markdown": return .markdown
        default: return nil
        }
    }
}
