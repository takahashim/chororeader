import Foundation

/// フォルダの中の書籍を、まとめて書棚へ加える。
///
/// 1 冊ごとに書籍を開いて題名と著者と表紙を取り出す。数百冊あると数秒では終わらないので、
/// 進み具合を見せ、途中でやめられるようにする。
///
/// **1 冊ごとに手を離す。** 書籍を開く処理は主スレッドのものなので、
/// 続けて回すと書棚が固まる。1 冊ごとに譲れば、進み具合も描き直せる。
@MainActor
final class FolderImport: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var total = 0
    @Published private(set) var done = 0
    @Published private(set) var added = 0
    @Published private(set) var already = 0
    @Published private(set) var failed = 0
    @Published private(set) var current = ""
    @Published var summary: String?

    private var cancelled = false

    func cancel() { cancelled = true }

    func run(_ folder: URL, into store: LibraryStore) {
        guard !running else { return }
        Task { await work(folder, into: store) }
    }

    /// 落とされたものを取り込む。**書籍は開かない。**
    ///
    /// フォルダが混じっていたら、その中も辿る。走査は中身を読まないので速い。
    func drop(_ urls: [URL], into store: LibraryStore) {
        guard !running else { return }
        Task { await work(dropped: urls, into: store) }
    }

    private func work(dropped urls: [URL], into store: LibraryStore) async {
        reset()
        current = "探しています…"

        var found: [URL] = []
        var folders = 0
        var others = 0
        for url in urls {
            var isFolder: ObjCBool = false
            let there = FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
            guard there else { continue }
            if isFolder.boolValue {
                folders += 1
                found.append(contentsOf: BookFinder.books(in: url))
            } else if BookFinder.extensions.contains(url.pathExtension.lowercased()) {
                found.append(url)
            } else {
                others += 1
            }
        }
        total = found.count

        for url in found {
            if cancelled { break }
            current = url.lastPathComponent
            take(url, into: store)
            await Task.yield()
        }

        running = false
        current = ""
        summary = report(dropped: urls.count, folders: folders, others: others)
    }

    /// 落として取り込んだときの言葉。
    ///
    /// **読めなかったものを黙らせない。** 落としたのに増えないと、
    /// 見落としたのか、既にあったのか、そもそも書籍でなかったのかが分からない。
    private func report(dropped: Int, folders: Int, others: Int) -> String {
        if cancelled { return "取り込みをやめました（\(added) 冊を加えました）" }
        if total == 0 {
            return folders > 0 ? "落とされたフォルダに EPUB と PDF は見つかりませんでした"
                               : "EPUB と PDF ではありませんでした"
        }
        if added == 0, failed == 0, others == 0 {
            return "\(total) 冊は、すべて書棚にありました"
        }
        return "\(added) 冊を加えました" + tail(others: others)
    }

    /// 加えられなかったものの内訳。**黙らせない。**
    private func tail(others: Int = 0) -> String {
        var notes: [String] = []
        if already > 0 { notes.append("\(already) 冊は既にありました") }
        if failed > 0 { notes.append("\(failed) 冊は読めませんでした") }
        if others > 0 { notes.append("\(others) 件は EPUB でも PDF でもありません") }
        return notes.isEmpty ? "" : "（" + notes.joined(separator: "、") + "）"
    }

    private func reset() {
        running = true
        cancelled = false
        done = 0
        added = 0
        already = 0
        failed = 0
        summary = nil
    }

    private func take(_ url: URL, into store: LibraryStore) {
        let known = store.entry(for: BookID(url: url)) != nil
        if store.register(url) {
            added += 1
        } else if known {
            already += 1
        } else {
            failed += 1
        }
        done += 1
    }

    private func work(_ folder: URL, into store: LibraryStore) async {
        reset()
        current = "探しています…"

        let found = BookFinder.books(in: folder)
        total = found.count

        for url in found {
            if cancelled { break }
            current = url.lastPathComponent
            take(url, into: store)
            await Task.yield()
        }

        running = false
        current = ""
        summary = report(folder: folder)
    }

    private func report(folder: URL) -> String {
        let name = folder.lastPathComponent
        if cancelled {
            return "「\(name)」の取り込みをやめました（\(added) 冊を加えました）"
        }
        if total == 0 {
            return "「\(name)」に EPUB と PDF は見つかりませんでした"
        }
        if added == 0, failed == 0 {
            return "「\(name)」の \(total) 冊は、すべて書棚にありました"
        }
        return "「\(name)」から \(added) 冊を加えました" + tail()
    }
}
