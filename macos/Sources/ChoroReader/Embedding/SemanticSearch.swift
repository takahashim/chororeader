import Foundation

@MainActor
final class SemanticSearchModel: ObservableObject {
    @Published private(set) var found: [RelatedPassage] = []
    @Published private(set) var running = false
    @Published private(set) var query = ""
    @Published private(set) var reason: String?
    /// 索引の無い書籍の数。「まだ全部は見ていない」ことを隠さないために出す。
    @Published private(set) var missing = 0

    private var generation = 0

    func clear() {
        generation += 1
        found = []
        running = false
        query = ""
        reason = nil
        missing = 0
    }

    func run(_ text: String, over entries: [LibraryEntry], resolve: @escaping (LibraryEntry) -> URL?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            clear()
            return
        }
        generation += 1
        let mine = generation
        query = text
        guard #available(macOS 15, *), EmbeddingModelStore.installed() != nil else {
            found = []
            reason = "意味検索は macOS 15 以降で、モデルを入れてから使えます"
            return
        }

        running = true
        reason = nil
        Task.detached(priority: .userInitiated) {
            let vector: [Float]
            do {
                guard let made = try EmbedderHolder.shared.use({ try $0.embed(text, as: .query) })
                else { return }
                vector = made.vector
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.generation == mine else { return }
                    self.running = false
                    self.reason = error.localizedDescription
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self, self.generation == mine else { return }
                self.gather(vector, over: entries, resolve: resolve)
            }
        }
    }

    /// 並べる。**推論は済んでいるので、ここは読むだけである。**
    private func gather(_ vector: [Float], over entries: [LibraryEntry],
                        resolve: (LibraryEntry) -> URL?) {
        let made = SemanticFinder.search(vector, over: entries, limits: .search, resolve: resolve)
        found = made.passages
        missing = made.missing
        running = false
        reason = found.isEmpty
            ? (made.missing == entries.count ? "まだ 1 冊も読み込んでいません" : "近い箇所は見つかりませんでした")
            : nil
    }
}
