import Foundation

/// 蔵書の用語索引を横断して引く。
///
/// **全文検索との違いは決定的である。** 全文検索は「その語が 1 度でも出た本」を
/// 返すが、こちらは**著者が索引に載せた本**、つまり扱うと認めた本だけを返す。
///
/// 索引を持つのは蔵書の半分ほどだった（EPUB 8 冊中 4 冊、PDF 9 冊中 5 冊）。
/// **持たない本を「無い」と混ぜない。** 出せていない冊数を返し、
/// 「扱っていない」のか「索引が無い」のかを人が分かるようにする。
enum TermSearch {
    struct Hit: Identifiable, Hashable {
        var book: LibraryEntry
        /// 索引に載っていた形。問いと同じとは限らない（部分一致で当たる）。
        var term: String
        /// 問いそのものだったか。**言い換えより先に出す。**
        var isExact: Bool

        var id: String { "\(book.path)#\(term)" }
    }

    struct Found {
        var hits: [Hit] = []
        /// 索引の語をまだ調べていない書籍の数。
        var unread = 0
        /// 索引を持たないと分かっている書籍の数。
        var withoutIndex = 0
    }

    /// 語で引く。
    ///
    /// **UI を持つスレッドから呼んでよい。** 置いてある語を読むだけで、
    /// 書籍は開かない。置いていない本は数えるだけで飛ばす。
    ///
    /// - Parameter terms: その書籍の索引語。**まだ調べていなければ nil、
    ///   索引を持たないなら空**を返す。この 2 つは意味が違う。
    ///   置き場所を直に見ないのは、検査を書けるようにするためである。
    static func run(_ query: String, over entries: [LibraryEntry],
                    terms lookup: (LibraryEntry) -> [String]?) -> Found {
        let wanted = normalize(query)
        var made = Found()
        guard !wanted.isEmpty else { return made }

        for entry in entries {
            guard let terms = lookup(entry) else {
                made.unread += 1
                continue
            }
            if terms.isEmpty {
                made.withoutIndex += 1
                continue
            }
            // 1 冊から出すのは**いちばん近い 1 語**だけ。
            // 「型」で引いて「型推論」「型クラス」…と 1 冊が並びを埋めない。
            var best: Hit?
            for term in terms {
                let flat = normalize(term)
                guard flat.contains(wanted) else { continue }
                let exact = flat == wanted
                if exact { best = Hit(book: entry, term: term, isExact: true); break }
                if best == nil || term.count < best!.term.count {
                    best = Hit(book: entry, term: term, isExact: false)
                }
            }
            if let best { made.hits.append(best) }
        }

        // 問いそのものを載せている本が先。次は短い語（＝問いに近い語）の順。
        made.hits.sort {
            if $0.isExact != $1.isExact { return $0.isExact }
            if $0.term.count != $1.term.count { return $0.term.count < $1.term.count }
            return $0.book.displayTitle < $1.book.displayTitle
        }
        return made
    }

    /// 置いてある語で引く。書棚から呼ぶのはこちら。
    static func run(_ query: String, over entries: [LibraryEntry],
                    resolve: (LibraryEntry) -> URL?) -> Found {
        run(query, over: entries) { entry in
            resolve(entry).flatMap { IndexTermsStore.cached(for: $0) }
        }
    }

    /// 比べるための形。**大小と全角半角を無視する。**
    /// 索引は「JavaScript」「javascript」「ＪＳ」が混ざる。
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
                                  locale: nil)
        return folded.filter { !$0.isWhitespace && $0 != "　" }
    }
}
