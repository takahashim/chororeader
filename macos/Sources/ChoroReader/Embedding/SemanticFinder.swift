import Foundation

enum SemanticFinder {
    struct Limits {
        /// 1 冊から出す上限。1 冊が結果を埋め尽くさないようにする。
        var perBook: Int
        /// これより遠いものは出さない。
        ///
        /// 意味の近さには「当たり」が無いので、下を切らないと
        /// **蔵書のどこかしらが必ず並ぶ**。関係の無いものが常に出ると、
        /// 出ていること自体が信用されなくなる。
        var leastScore: Float
        var total: Int

        /// 関連箇所。**本文どうしの比較**なので両側とも `検索文書: ` で埋め込む。
        /// 同じ向きの接頭辞どうしは点が高めに出るので、下限も高く採る。
        static let related = Limits(perBook: 2, leastScore: 0.6, total: 12)

        /// 意味検索。**問いと本文の比較**で接頭辞が違うぶん、点は低めに出る。
        /// 同じ下限にすると、当たっているものまで落ちる。
        static let search = Limits(perBook: 3, leastScore: 0.5, total: 40)
    }

    /// 引いた結果と、索引の載っていなかった数。
    ///
    /// **載っていない数を返すのは、隠さないためである。** 「蔵書に無い」のか
    /// 「まだ見ていない」のかで、人が次にすることが変わる。
    struct Found {
        var passages: [RelatedPassage] = []
        var missing = 0
    }

    static func search(_ query: [Float], over entries: [LibraryEntry],
                       excluding current: BookID? = nil,
                       limits: Limits,
                       resolve: (LibraryEntry) -> URL?) -> Found {
        var made = Found()
        guard !query.isEmpty else { return made }
        var scored: [(entry: LibraryEntry, index: SemanticIndex, unit: Int, score: Float)] = []
        for entry in entries where entry.id != current {
            guard let url = resolve(entry), let index = SemanticIndexStore.cached(for: url) else {
                made.missing += 1
                continue
            }
            guard index.dimension == query.count else { continue }
            for hit in index.nearest(to: query, limit: limits.perBook)
            where hit.score >= limits.leastScore {
                scored.append((entry, index, hit.unit, hit.score))
            }
        }
        made.passages = scored.sorted { $0.score > $1.score }.prefix(limits.total)
            .map { RelatedPassage(book: $0.entry, unit: $0.index.unit(at: $0.unit), score: $0.score) }
        return made
    }

    static func rank(_ query: [Float], over targets: [(entry: LibraryEntry, index: SemanticIndex)],
                     limits: Limits) -> [RelatedPassage] {
        guard !query.isEmpty else { return [] }
        var found: [RelatedPassage] = []
        for target in targets where target.index.dimension == query.count {
            for hit in target.index.nearest(to: query, limit: limits.perBook)
            where hit.score >= limits.leastScore {
                found.append(RelatedPassage(book: target.entry,
                                            unit: target.index.unit(at: hit.unit),
                                            score: hit.score))
            }
        }
        return Array(found.sorted { $0.score > $1.score }.prefix(limits.total))
    }
}
