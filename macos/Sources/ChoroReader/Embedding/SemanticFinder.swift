import Foundation

/// 近さで並べる。**関連箇所と意味検索で同じ規則を通す。**
///
/// 以前は同じ手順（蔵書を舐める → 書籍ごとに上位 N → 下限で切る → 点で並べる）が
/// 2 か所にあり、下限だけが食い違っていた。片方を調整してもう片方を忘れる事故が起きる。
enum SemanticFinder {
    /// 何件まで、どこまで遠いものを出すか。
    ///
    /// **用途で違ってよいが、違う理由は 1 か所に書く。**
    struct Limits {
        /// 1 冊から出す上限。1 冊が結果を埋め尽くさないようにする。
        var perBook: Int
        /// これより遠いものは出さない。
        ///
        /// 意味の近さには「当たり」が無いので、下を切らないと
        /// **蔵書のどこかしらが必ず並ぶ**。関係の無いものが常に出ると、
        /// 出ていること自体が信用されなくなる。
        var leastScore: Float
        /// 全体の上限。
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

    /// 蔵書を引く。
    ///
    /// **1 冊ずつ読んで、1 冊ずつ捨てる。** 先に全冊ぶんを集めてから並べると、
    /// 蔵書 500 冊（29 万段落）で 500 MB を抱えることになる（実測）。
    /// ほどいた索引に上限を付けてあっても、集めた配列が握っていれば追い出されない。
    ///
    /// 蔵書と道筋の解き方を**渡してもらう**。ここが `LibraryStore.shared` を
    /// 直に見ていると差し替えられず、検査が書けない。
    static func search(_ query: [Float], over entries: [LibraryEntry],
                       excluding current: BookID? = nil,
                       limits: Limits,
                       resolve: (LibraryEntry) -> URL?) -> Found {
        var made = Found()
        guard !query.isEmpty else { return made }
        for entry in entries where entry.id != current {
            guard let url = resolve(entry), let index = SemanticIndexStore.cached(for: url) else {
                made.missing += 1
                continue
            }
            made.passages.append(contentsOf: rank(query, over: [(entry, index)], limits: limits))
        }
        made.passages = Array(made.passages.sorted { $0.score > $1.score }.prefix(limits.total))
        return made
    }

    /// 近い順に並べる。
    ///
    /// **次元は問いの側で決まる。** 以前は「手本の索引」を渡させていたが、
    /// 自分の索引がまだ無いときに次元 0 の偽物を渡すことになり、
    /// どの書籍とも一致せず黙って空が返っていた。
    static func rank(_ query: [Float], over targets: [(entry: LibraryEntry, index: SemanticIndex)],
                     limits: Limits) -> [RelatedPassage] {
        guard !query.isEmpty else { return [] }
        var found: [RelatedPassage] = []
        for target in targets where target.index.dimension == query.count {
            for hit in target.index.nearest(to: query, limit: limits.perBook)
            where hit.score >= limits.leastScore {
                found.append(RelatedPassage(book: target.entry,
                                            unit: target.index.units[hit.unit],
                                            score: hit.score))
            }
        }
        return Array(found.sorted { $0.score > $1.score }.prefix(limits.total))
    }
}
