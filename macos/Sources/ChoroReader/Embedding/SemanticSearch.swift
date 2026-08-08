import Foundation

/// 書棚を意味で引く。
///
/// 文字が一致しない箇所を、意味の近さで引く（spec-local-ai.md 第 1.2 節の 2）。
///
/// **正確な検索の代わりではない。** 特徴的な語を 1 つでも覚えていれば、
/// 二字組索引を使う横断検索の方が速くて正確である。こちらが効くのは
/// 「概念しか覚えていない」場合に限られる（第 1.2 節）。だから
/// **同じ画面で混ぜず、引き方を選ばせる**（第 5.2 節）。
@MainActor
final class SemanticSearchModel: ObservableObject {
    @Published private(set) var found: [RelatedPassage] = []
    @Published private(set) var running = false
    @Published private(set) var query = ""
    /// 引けなかった理由。無ければ引けている。
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

    /// 問いを引く。
    ///
    /// 問いの埋め込みは推論を 1 回だけ回す。裏の筋でやるのは、
    /// **バケットを初めて開く回だけ数百 ms かかる**からである（findings-buckets.md）。
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
                // 持ち回っているものを使う。作り直すと 1 回 600 ms かかる。
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
