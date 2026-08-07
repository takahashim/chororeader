import Foundation

/// 覚えたフォルダと書棚の差分。**見せてから当てる。**
///
/// 黙って当てると、消えた書籍の読書位置としおりが無言で失われる。
/// 何が増えて何が無くなったかを先に見せ、外すかどうかは人が決める。
struct SyncPlan: Equatable {
    /// 新しく見つかった書籍。
    var added: [URL] = []
    /// 場所が変わった書籍。しおり（bookmark）が追えたもの。
    var moved: [Moved] = []
    /// 覚えたフォルダの下にあったのに、もう見つからない書籍。
    var missing: [LibraryEntry] = []

    struct Moved: Equatable {
        var entry: LibraryEntry
        var to: URL
    }

    var isEmpty: Bool { added.isEmpty && moved.isEmpty && missing.isEmpty }

    var summary: String {
        var parts: [String] = []
        if !added.isEmpty { parts.append("増えた \(added.count) 冊") }
        if !moved.isEmpty { parts.append("移動した \(moved.count) 冊") }
        if !missing.isEmpty { parts.append("見つからない \(missing.count) 冊") }
        return parts.isEmpty ? "変わりありません" : parts.joined(separator: "／")
    }
}

/// 覚えたフォルダを見に行って、書棚との差分を作る。
@MainActor
enum FolderSync {
    /// 差分を作る。書棚には触らない。
    ///
    /// **覚えたフォルダの下にある書籍だけを見る。** ほかから開いた書籍を
    /// 「見つからない」と言い出すと、外す提案が的外れになる。
    static func plan(folders: [URL], store: LibraryStore) -> SyncPlan {
        var plan = SyncPlan()

        // いま書棚にある書籍を、実際の置き場所で引けるようにする。
        // 場所が変わった書籍を二重に加えないため、id ではなく置き場所で見る。
        var here: [String: LibraryEntry] = [:]
        for entry in store.entries {
            guard let url = store.resolveURL(for: entry) else { continue }
            here[url.standardizedFileURL.path] = entry
        }

        for folder in folders {
            for url in BookFinder.books(in: folder) {
                if here[url.standardizedFileURL.path] == nil {
                    plan.added.append(url)
                }
            }
        }

        for entry in store.entries where isUnder(entry.path, folders) {
            guard let url = store.resolveURL(for: entry) else {
                plan.missing.append(entry)
                continue
            }
            let now = url.standardizedFileURL.path
            if now != URL(fileURLWithPath: entry.path).standardizedFileURL.path {
                plan.moved.append(SyncPlan.Moved(entry: entry, to: url))
            }
        }

        return plan
    }

    /// 差分を当てる。`removeMissing` が偽なら、見つからない書籍はそのまま残す。
    ///
    /// 外すと読書位置としおりも消える。既定では外さない。
    @discardableResult
    static func apply(_ plan: SyncPlan, to store: LibraryStore, removeMissing: Bool) -> Int {
        var added = 0
        for url in plan.added where store.register(url) { added += 1 }
        for moved in plan.moved { store.relocate(moved.entry.id, to: moved.to) }
        if removeMissing {
            for entry in plan.missing { store.remove(entry.id) }
        }
        return added
    }

    /// その道筋が、覚えたフォルダのどれかの下にあるか。
    static func isUnder(_ path: String, _ folders: [URL]) -> Bool {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        return folders.contains { folder in
            let base = folder.standardizedFileURL.path
            return target == base || target.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
    }
}
