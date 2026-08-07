import Foundation

struct LibraryEntry: Codable, Identifiable, Hashable {
    var id: BookID
    var path: String
    var bookmarkData: Data?
    var title: String
    var authors: [String]
    var format: DocumentFormat
    /// 書棚の並びの基準にする日時。
    ///
    /// 開いたときはその時刻。**まとめて取り込んだだけの書籍はファイルの更新日時**を入れる。
    /// 取り込んだ時刻にすると、何百冊が「いま開いた」ことになって書棚の先頭を埋め、
    /// 本当に最近読んだ本が押し出される。
    var lastOpenedAt: Date
    var lastLocator: Locator?
    var bookmarks: [Bookmark] = []
    /// 書棚に並べる表紙の置き場所。取れなかった書籍では nil。
    var coverName: String?

    var displayAuthors: String { authors.joined(separator: "、") }
    var fileExists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// 蔵書と読書位置の保存。元ファイルは複製せず、参照だけを持つ。
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var entries: [LibraryEntry] = []

    private let fileURL: URL
    private var saveWorkItem: DispatchWorkItem?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChoroReader", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("library.json")
        load()
    }

    // MARK: - 参照

    func entry(for id: BookID) -> LibraryEntry? {
        entries.first { $0.id == id }
    }

    func lastLocator(for id: BookID) -> Locator? {
        entry(for: id)?.lastLocator
    }

    func bookmarks(for id: BookID) -> [Bookmark] {
        entry(for: id)?.bookmarks ?? []
    }

    var recent: [LibraryEntry] {
        entries.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    /// Security-Scoped Bookmark を優先して復元する。移動されたファイルもこれで追える。
    func resolveURL(for entry: LibraryEntry) -> URL? {
        if let data = entry.bookmarkData {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data,
                                  options: [.withSecurityScope],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale) {
                return url
            }
        }
        let url = URL(fileURLWithPath: entry.path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - 更新

    func record(_ doc: BookDocument) {
        var entry = entries.first { $0.id == doc.id }
            ?? LibraryEntry(id: doc.id, path: doc.url.path, bookmarkData: nil,
                            title: doc.title, authors: doc.authors, format: doc.format,
                            lastOpenedAt: Date(), lastLocator: nil)
        entry.path = doc.url.path
        entry.title = doc.title
        entry.authors = doc.authors
        entry.format = doc.format
        entry.lastOpenedAt = Date()
        // 表紙は開いたときに 1 度だけ取り出す。書棚を開くたびに書籍を触らずに済む。
        if entry.coverName == nil { entry.coverName = CoverCache.store(from: doc) }
        if entry.bookmarkData == nil {
            entry.bookmarkData = try? doc.url.bookmarkData(options: [.withSecurityScope],
                                                           includingResourceValuesForKeys: nil,
                                                           relativeTo: nil)
        }
        upsert(entry)
    }

    /// 開かずに書棚へ加える。フォルダからまとめて取り込むときに使う。
    ///
    /// 既に並んでいる書籍は触らない。読書位置も並び順も、取り込みで動かさない。
    /// 加えたら true、既にあったか読めなければ false。
    @discardableResult
    func register(_ url: URL) -> Bool {
        if entries.contains(where: { $0.id == BookID(url: url) }) { return false }
        guard let document = try? BookDocument(url: url) else { return false }

        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        var entry = LibraryEntry(id: document.id, path: url.path, bookmarkData: nil,
                                 title: document.title, authors: document.authors,
                                 format: document.format,
                                 lastOpenedAt: modified ?? Date(), lastLocator: nil)
        entry.coverName = CoverCache.store(from: document)
        entry.bookmarkData = try? url.bookmarkData(options: [.withSecurityScope],
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil)
        upsert(entry)
        return true
    }

    func savePosition(_ locator: Locator, for id: BookID) {
        guard var entry = entries.first(where: { $0.id == id }) else { return }
        entry.lastLocator = locator
        upsert(entry)
    }

    func setBookmarks(_ bookmarks: [Bookmark], for id: BookID) {
        guard var entry = entries.first(where: { $0.id == id }) else { return }
        entry.bookmarks = bookmarks
        upsert(entry)
    }

    func remove(_ id: BookID) {
        if let name = entry(for: id)?.coverName { CoverCache.discard(name) }
        entries.removeAll { $0.id == id }
        scheduleSave()
    }

    private func upsert(_ entry: LibraryEntry) {
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
        scheduleSave()
    }

    // MARK: - 永続化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([LibraryEntry].self, from: data)) ?? []
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let snapshot = entries
        let url = fileURL
        let item = DispatchWorkItem {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
        saveWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: item)
    }
}
