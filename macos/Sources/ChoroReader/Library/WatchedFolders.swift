import Foundation

/// 取り込んだフォルダを覚えておく。あとから同じところを見に行くため。
///
/// **見張りはしない。** 変化を追い続けるのは spec 第 2.3 節の対象外に近づく。
/// 覚えるのは場所だけで、見に行くのは人が「同期」を押したときに限る。
///
/// 蔵書とは別のファイルに置く。library.json は書籍の並びそのもので、
/// 形を変えると前の版で書いたものが読めなくなる。
@MainActor
final class WatchedFolders: ObservableObject {
    static let shared = WatchedFolders()

    struct Watched: Codable, Identifiable, Hashable {
        var path: String
        /// 移動されたフォルダも追えるようにする。蔵書の項目と同じ考え方。
        var bookmarkData: Data?
        var addedAt: Date
        var id: String { path }

        var name: String { URL(fileURLWithPath: path).lastPathComponent }
    }

    @Published private(set) var folders: [Watched] = []

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ChoroReader", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.fileURL = base.appendingPathComponent("folders.json")
        }
        load()
    }

    /// 覚える。同じところを二度覚えない。
    func remember(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !folders.contains(where: { $0.path == path }) else { return }
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope],
                                             includingResourceValuesForKeys: nil,
                                             relativeTo: nil)
        folders.append(Watched(path: path, bookmarkData: bookmark, addedAt: Date()))
        save()
    }

    func forget(_ path: String) {
        folders.removeAll { $0.path == path }
        save()
    }

    /// いまの場所。移動されていれば、しおり（bookmark）が追う。
    func resolve(_ watched: Watched) -> URL? {
        if let data = watched.bookmarkData {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url
            }
        }
        let url = URL(fileURLWithPath: watched.path)
        var isDirectory: ObjCBool = false
        let there = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return there && isDirectory.boolValue ? url : nil
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        folders = (try? decoder.decode([Watched].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(folders) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
