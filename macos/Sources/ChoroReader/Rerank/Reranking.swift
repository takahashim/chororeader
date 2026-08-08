import Foundation

/// 意味検索の候補を、本文を読み直して並べ直す。
///
/// **押されたときにだけ走る。** 勝手に並べ替えない理由は 2 つある。
///
/// 1. **悪くなる問いが実在する**（spikes/findings-reranker.md）。日本語 reranker は
///    クイズ形式の傾向を学んでいて、解答や演習の紙面を正解の説明と取り違える。
///    黙って並べ替えて戻せないのは筋が悪い
/// 2. 候補の数だけ推論が要る。索引と違い、**開くたびに払う値段**である
///
/// 元の順位を控えておき、行に添える。効いたかどうかを人が見て決められるようにする。
@MainActor
final class RerankModel: ObservableObject {
    /// 並べ直した結果。**まだなら nil**（素の並びを出す）。
    @Published private(set) var passages: [RelatedPassage]?
    @Published private(set) var running = false
    /// できない理由。無ければ押せる。
    @Published private(set) var reason: String?
    /// 札 → 元は何位だったか（0 始まり）。
    @Published private(set) var wasAt: [String: Int] = [:]
    /// 札 → 0〜1 に均した点。
    @Published private(set) var relevance: [String: Float] = [:]

    private var generation = 0

    /// 並べ直せる状態か。モデルが入っていなければ押させない。
    static var isAvailable: Bool {
        guard #available(macOS 15, *) else { return false }
        return RerankerModelStore.installed() != nil
    }

    func clear() {
        generation += 1
        passages = nil
        running = false
        reason = nil
        wasAt = [:]
        relevance = [:]
    }

    /// 素の並びへ戻す。**推論はやり直さない**（点は控えてある）。
    func reset() {
        generation += 1
        passages = nil
        running = false
    }

    /// 並べ直す。
    ///
    /// - Parameter texts: 札で引ける本文。**索引には本文が無い**ので、
    ///   原書から切り出したものを渡してもらう。読めていない候補は並べ直せない。
    func run(_ query: String, over candidates: [RelatedPassage], texts: [String: String]) {
        guard #available(macOS 15, *), Self.isAvailable else {
            reason = "並べ直しは macOS 15 以降で、モデルを入れてから使えます"
            return
        }
        // 本文の読めていない候補は、点を付けようがない。
        let ready = candidates.filter { !(texts[$0.id] ?? "").isEmpty }
        guard !ready.isEmpty else {
            reason = "本文をまだ読めていません"
            return
        }

        generation += 1
        let mine = generation
        running = true
        reason = nil
        let bodies = ready.map { texts[$0.id] ?? "" }

        Task.detached(priority: .userInitiated) { [weak self] in
            let made: [Float]?
            do {
                made = try RerankerHolder.shared.use {
                    try $0.scores(query: query, passages: bodies) {
                        // 問いが変わったら降りる。40 件を回し切ると次が待たされる。
                        MainActor.assumeIsolated { self?.generation != mine }
                    }
                } ?? nil
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.generation == mine else { return }
                    self.running = false
                    self.reason = error.localizedDescription
                }
                return
            }
            guard let scores = made else { return }
            await MainActor.run { [weak self] in
                guard let self, self.generation == mine else { return }
                self.apply(scores, to: ready, from: candidates)
            }
        }
    }

    @available(macOS 15, *)
    private func apply(_ scores: [Float], to ready: [RelatedPassage],
                       from candidates: [RelatedPassage]) {
        let made = Reranking.order(candidates, scored: ready, by: scores)
        wasAt = made.wasAt
        relevance = made.relevance
        passages = made.passages
        running = false
    }
}

/// 点を並びに直すところ。**推論を伴わないので、モデルが無くても確かめられる。**
enum Reranking {
    struct Ordered {
        var passages: [RelatedPassage] = []
        /// 札 → 元は何位だったか（0 始まり）。
        var wasAt: [String: Int] = [:]
        /// 札 → 0〜1 に均した点。
        var relevance: [String: Float] = [:]
    }

    /// 素の点を 0〜1 に均す。**見せるためだけのもの。**
    ///
    /// cross-encoder が返すのは素の logit で、-9 から +5 あたりまで散らばる。
    /// そのまま出しても近さには見えない。この型の reranker は 2 値の当たり外れで
    /// 学習されているので、sigmoid を通した値が「答えている度合い」に当たる。
    ///
    /// **順は変えない。** ここで向きを取り違えると、並びが裏返る。
    static func relevance(_ logit: Float) -> Float {
        1 / (1 + expf(-logit))
    }

    /// 点の高い順に並べ直す。
    ///
    /// **点の付かなかった候補は末尾へ回す。落とさない。** 本文をまだ読めていない
    /// 候補は点を付けようがないが、消してしまうと「並べ直したら減った」ことになる。
    /// 意味検索は件数を出さないので、減ったことに人は気付けない。
    static func order(_ candidates: [RelatedPassage], scored ready: [RelatedPassage],
                      by scores: [Float]) -> Ordered {
        var made = Ordered()
        for (at, passage) in candidates.enumerated() { made.wasAt[passage.id] = at }
        for (at, passage) in ready.enumerated() where at < scores.count {
            made.relevance[passage.id] = relevance(scores[at])
        }
        let scoredIds = Set(ready.map(\.id))
        let sorted = ready.indices.filter { $0 < scores.count }
            .sorted { scores[$0] > scores[$1] }.map { ready[$0] }
        made.passages = sorted + candidates.filter { !scoredIds.contains($0.id) }
        return made
    }
}
