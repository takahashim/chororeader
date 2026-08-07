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
    /// 見つかった冊数。走査が終わった時点で決まる。
    @Published private(set) var total = 0
    /// 触り終わった冊数。既に並んでいたものも数える。
    @Published private(set) var done = 0
    /// 新しく加わった冊数。
    @Published private(set) var added = 0
    /// いま触っている書籍の名前。
    @Published private(set) var current = ""
    /// 終わったときの言葉。しばらく出しておく。
    @Published var summary: String?

    private var cancelled = false

    func cancel() { cancelled = true }

    func run(_ folder: URL, into store: LibraryStore) {
        guard !running else { return }
        Task { await work(folder, into: store) }
    }

    private func work(_ folder: URL, into store: LibraryStore) async {
        running = true
        cancelled = false
        done = 0
        added = 0
        summary = nil
        current = "探しています…"

        // 走査そのものはファイルの中身を読まない。数が多くても速い。
        let found = BookFinder.books(in: folder)
        total = found.count

        for url in found {
            if cancelled { break }
            current = url.lastPathComponent
            if store.register(url) { added += 1 }
            done += 1
            // 主スレッドを握り続けない。ここで描き直しが入る。
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
        let already = done - added
        if added == 0 {
            return "「\(name)」の \(total) 冊は、すべて書棚にありました"
        }
        return already == 0
            ? "「\(name)」から \(added) 冊を加えました"
            : "「\(name)」から \(added) 冊を加えました（\(already) 冊は既にありました）"
    }
}
