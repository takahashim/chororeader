import CryptoKit
import Foundation
import PDFKit

struct BookID: Hashable, Codable {
    var raw: String

    init(url: URL) {
        let key = url.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(key.utf8))
        raw = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}

struct Bookmark: Identifiable, Codable, Hashable {
    var id = UUID()
    var locator: Locator
    var name: String
    var createdAt: Date = Date()
}

/// 書籍ごとに 1 つ。複数ウィンドウで同じ書籍を開いても、この層は共有する。
@MainActor
final class BookDocument: ObservableObject {
    enum Source {
        case epub(archive: ZipArchive, publication: EPUBPublication)
        case pdf(PDFKit.PDFDocument)
    }

    let id: BookID
    let url: URL
    let format: DocumentFormat
    let source: Source
    let title: String
    let authors: [String]
    let tableOfContents: [TOCEntry]
    /// CSS 互換レイヤーが書き換えた内容。表示崩れの切り分けに使う。
    private(set) var cssChanges: [String] = []

    @Published var bookmarks: [Bookmark] = []

    var publication: EPUBPublication? {
        if case let .epub(_, pub) = source { return pub }
        return nil
    }
    var archive: ZipArchive? {
        if case let .epub(archive, _) = source { return archive }
        return nil
    }
    /// 本文と周辺リソースの供給元。
    var resources: ResourceProvider? { archive }
    var pdfDocument: PDFKit.PDFDocument? {
        if case let .pdf(doc) = source { return doc }
        return nil
    }

    init(url: URL) throws {
        self.url = url
        id = BookID(url: url)

        guard let detected = DocumentFormat.detect(url: url) else {
            throw OpenError.unsupportedFormat(url.lastPathComponent)
        }

        switch detected {
        case .pdf:
            guard let doc = PDFKit.PDFDocument(url: url) else { throw OpenError.cannotOpenPDF }
            source = .pdf(doc)
            format = .pdf
            let attrs = doc.documentAttributes
            let attrTitle = attrs?[PDFKit.PDFDocumentAttribute.titleAttribute] as? String
            title = (attrTitle?.isEmpty == false ? attrTitle! : url.deletingPathExtension().lastPathComponent)
            if let author = attrs?[PDFKit.PDFDocumentAttribute.authorAttribute] as? String, !author.isEmpty {
                authors = [author]
            } else {
                authors = []
            }
            tableOfContents = BookDocument.outline(of: doc)

        case .reflowableEPUB, .fixedEPUB:
            let archive: ZipArchive
            do {
                archive = try ZipArchive(url: url)
            } catch {
                throw OpenError.brokenArchive(String(describing: error))
            }
            let pub: EPUBPublication
            do {
                pub = try EPUBParser.parse(archive)
            } catch EPUBParser.Failure.emptySpine {
                throw OpenError.emptySpine
            } catch {
                throw OpenError.cannotParseOPF(String(describing: error))
            }
            source = .epub(archive: archive, publication: pub)
            format = pub.layout == .fixed ? .fixedEPUB : .reflowableEPUB
            title = pub.title.isEmpty ? url.deletingPathExtension().lastPathComponent : pub.title
            authors = pub.authors
            tableOfContents = pub.tableOfContents

        case .markdown:
            throw OpenError.unsupportedFormat("Markdown の表示は未対応です")
        }

        bookmarks = LibraryStore.shared.bookmarks(for: id)
    }

    /// 診断用のレポート。走査を伴うため、要求されたときに作って以後は使い回す。
    private var cachedReport: BookReport?

    func report() -> BookReport? {
        if let cachedReport { return cachedReport }
        guard let archive, let publication else { return nil }
        let made = BookReport.make(archive: archive, publication: publication)
        cachedReport = made
        return made
    }

    func noteCSSChanges(_ changes: [String], path: String) {
        guard !changes.isEmpty else { return }
        cssChanges.append(contentsOf: changes.map { "\(path): \($0)" })
    }

    // MARK: - しおり

    func addBookmark(_ locator: Locator, name: String) {
        bookmarks.append(Bookmark(locator: locator, name: name))
        bookmarks.sort { ($0.locator.page ?? 0, $0.locator.progression) < ($1.locator.page ?? 0, $1.locator.progression) }
        LibraryStore.shared.setBookmarks(bookmarks, for: id)
    }

    func removeBookmark(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        LibraryStore.shared.setBookmarks(bookmarks, for: id)
    }

    func renameBookmark(_ bookmark: Bookmark, to name: String) {
        guard let i = bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return }
        bookmarks[i].name = name
        LibraryStore.shared.setBookmarks(bookmarks, for: id)
    }

    // MARK: - PDF アウトライン

    private static func outline(of doc: PDFKit.PDFDocument) -> [TOCEntry] {
        guard let root = doc.outlineRoot else { return [] }
        func walk(_ node: PDFOutline) -> [TOCEntry] {
            var out: [TOCEntry] = []
            for i in 0 ..< node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                let page = child.destination?.page.flatMap { doc.index(for: $0) }
                out.append(TOCEntry(title: child.label ?? "(無題)",
                                    href: nil, fragment: nil, page: page,
                                    children: walk(child)))
            }
            return out
        }
        return walk(root)
    }

    enum OpenError: LocalizedError {
        case unsupportedFormat(String)
        case cannotOpenPDF
        case brokenArchive(String)
        case cannotParseOPF(String)
        case emptySpine

        var errorDescription: String? {
            switch self {
            case let .unsupportedFormat(name): return "対応していない形式です: \(name)"
            case .cannotOpenPDF: return "PDF を開けませんでした。破損しているか、暗号化されている可能性があります。"
            case .brokenArchive: return "EPUB の ZIP 構造を読み取れませんでした。"
            case .cannotParseOPF: return "EPUB の OPF を解析できませんでした。"
            case .emptySpine: return "EPUB の spine が空です。表示できるページがありません。"
            }
        }

        /// 別実装と突き合わせるための分類名。表示文言は変わっても、この値は変えない。
        var kind: String {
            switch self {
            case .unsupportedFormat: return "unsupportedFormat"
            case .cannotOpenPDF: return "cannotOpenPDF"
            case .brokenArchive: return "brokenArchive"
            case .cannotParseOPF: return "cannotParseOPF"
            case .emptySpine: return "emptySpine"
            }
        }

        var diagnosticDetail: String {
            switch self {
            case let .unsupportedFormat(s): return s
            case .cannotOpenPDF: return "PDFDocument(url:) が nil を返しました。"
            case let .brokenArchive(s): return s
            case let .cannotParseOPF(s): return s
            case .emptySpine: return "spine に linear な itemref がありません。"
            }
        }
    }
}

/// 開いている書籍を 1 つに保つ。ウィンドウが増えても再パースしない。
@MainActor
final class DocumentRegistry {
    static let shared = DocumentRegistry()

    private var documents: [BookID: BookDocument] = [:]
    private var refCounts: [BookID: Int] = [:]

    func open(url: URL) throws -> BookDocument {
        let id = BookID(url: url)
        if let existing = documents[id] { return existing }
        let doc = try BookDocument(url: url)
        documents[id] = doc
        LibraryStore.shared.record(doc)
        IndexBuilder.scheduleIfNeeded(for: url)
        // 意味の索引は入にしていなければ何もしない。入なら、開いた本を先に作る。
        SemanticIndexBuilder.shared.prioritize(url)
        return doc
    }

    func retain(_ doc: BookDocument) {
        refCounts[doc.id, default: 0] += 1
    }

    func release(_ doc: BookDocument) {
        let n = (refCounts[doc.id] ?? 1) - 1
        if n <= 0 {
            refCounts[doc.id] = nil
            documents[doc.id] = nil
        } else {
            refCounts[doc.id] = n
        }
        // 本を 1 冊も開いていないなら、埋め込み器も要らない。
        // 索引作りが走っている間は、あちらが使っているので降りない。
        if documents.isEmpty, #available(macOS 15, *) {
            EmbedderHolder.shared.release()
        }
    }
}
