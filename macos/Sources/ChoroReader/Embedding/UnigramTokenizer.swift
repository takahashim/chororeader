import Foundation

/// Unigram（SentencePiece）方式のトークナイザ。
///
/// Ruri v3 の `tokenizer.json` をそのまま読む。30m / 130m / 310m で同じファイルなので、
/// モデルの大きさを替えてもここは替わらない。
///
/// 段は 4 つ。
///   1. 特殊トークン（added_tokens）で切り分ける。中身は素通し
///   2. Metaspace：空白を ▁ に置き換える（prepend_scheme=never なので頭には足さない）
///   3. Viterbi：語彙の並びで最も点の高い分け方を選ぶ
///   4. 語彙に無い文字は byte fallback で <0xXX> に落とす
///
/// **食い違っても例外は出ず、黙って違うベクトルになる。** 参照実装（kohagi、
/// Rust の tokenizers crate）とトークン ID が一致することを検査で固める以外に、
/// 守る手立てが無い。実際に次の 3 つで黙って間違えた（spikes/findings-swift-tokenizer.md）。
///
/// - **String は正準等価で比べる。** 語彙を String の鍵にすると「が」（1 符号位置）と
///   「か」＋濁点（2 符号位置）が同じ鍵になり、片方が消える。この語彙には 15 組ある。
///   空白の置き換えも同じで、空白＋結合文字は 1 つの Character になるため当たらない。
///   → **すべてバイト列で扱う**
/// - **点の足し込みは Double で行う。** 語彙の点は f32 だが参照は f64 で積む。
///   同じ点の分け方が並ぶと（目次の点線のような連なり）丸めで順位が入れ替わる
/// - **同点は開始位置の小さい方（長い語彙）を採る。** バイト位置を昇順に進め、
///   等号を含まない比較で更新すれば参照と同じになる
struct UnigramTokenizer {
    /// 語彙。UTF-8 のバイト列から引く。
    private let scores: [[UInt8]: (id: Int, score: Double)]
    private let unkId: Int
    private let byteFallback: Bool
    /// 0…255 → `<0xXX>` の id。無ければ -1。
    private let byteToken: [Int]
    /// 特殊トークン。長い順に見る。
    private let added: [(content: [UInt8], id: Int)]
    private let bos: Int
    private let eos: Int
    private let minScore: Double
    /// 語彙に載る最長のバイト数。Viterbi の探索幅を切る。
    private let maxPieceBytes: Int

    /// 語彙に無い 1 文字に与える点。tokenizers の K_UNK_PENALTY と同じ。
    private static let unkPenalty: Double = 10.0

    enum Failure: Error, LocalizedError {
        case cannotRead(String)

        var errorDescription: String? {
            switch self {
            case let .cannotRead(why): return "トークナイザを読めません：\(why)"
            }
        }
    }

    init(contentsOf url: URL) throws {
        guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let model = json["model"] as? [String: Any],
              let vocab = model["vocab"] as? [[Any]], !vocab.isEmpty
        else { throw Failure.cannotRead("model.vocab がありません") }

        var table: [[UInt8]: (Int, Double)] = [:]
        table.reserveCapacity(vocab.count)
        var longest = 0
        var lowest = Double.greatestFiniteMagnitude
        for (id, entry) in vocab.enumerated() {
            guard entry.count >= 2, let piece = entry[0] as? String,
                  let score = (entry[1] as? NSNumber)?.doubleValue
            else { throw Failure.cannotRead("語彙 \(id) の形が違います") }
            let bytes = Array(piece.utf8)
            table[bytes] = (id, score)
            longest = max(longest, bytes.count)
            lowest = min(lowest, score)
        }
        scores = table
        maxPieceBytes = longest
        minScore = lowest
        unkId = (model["unk_id"] as? Int) ?? 0
        byteFallback = (model["byte_fallback"] as? Bool) ?? false
        byteToken = (0 ... 255).map { table[Array(String(format: "<0x%02X>", $0).utf8)]?.0 ?? -1 }

        // 短いものが先に当たると取りこぼす。長い順に見る。
        added = ((json["added_tokens"] as? [[String: Any]]) ?? [])
            .compactMap { entry in
                guard let content = entry["content"] as? String, let id = entry["id"] as? Int
                else { return nil }
                return (Array(content.utf8), id)
            }
            .sorted { $0.0.count > $1.0.count }

        // post_processor は TemplateProcessing で <s> … </s> を足すだけ。
        let post = (json["post_processor"] as? [String: Any]) ?? [:]
        let special = (post["special_tokens"] as? [String: Any]) ?? [:]
        func specialId(_ name: String) -> Int {
            guard let entry = special[name] as? [String: Any],
                  let ids = entry["ids"] as? [Int], let first = ids.first else { return -1 }
            return first
        }
        bos = specialId("<s>")
        eos = specialId("</s>")
    }

    /// 文字列をトークン ID の並びにする。`special` が真なら `<s>` … `</s>` で挟む。
    func encode(_ text: String, addSpecialTokens special: Bool = true) -> [Int] {
        var out: [Int] = []
        if special, bos >= 0 { out.append(bos) }
        for piece in splitOnAdded(Array(text.utf8)) {
            switch piece {
            case let .plain(bytes): out.append(contentsOf: viterbi(metaspace(bytes)))
            case let .special(id): out.append(id)
            }
        }
        if special, eos >= 0 { out.append(eos) }
        return out
    }

    /// 問いと本文の**組**を 1 本の並びにする。reranker（cross-encoder）が食う形。
    ///
    /// 詰め方は推測せず、`tokenizer.json` の post_processor から写した。
    /// `pair` は `<s> A </s> <s> B </s>` である（特殊トークン 4 つ）。
    ///
    /// **上限を越えたら長い側から 1 つずつ削る**（tokenizers の longest_first。
    /// truncation を指定しないときの既定で、参照実装もこれで詰めている）。
    /// 本文だけを削る形にすると、問いが長い組で参照実装と食い違う。
    func encodePair(_ first: String, _ second: String, limit: Int) -> [Int] {
        var a = encode(first, addSpecialTokens: false)
        var b = encode(second, addSpecialTokens: false)
        var over = a.count + b.count + 4 - limit
        while over > 0, !(a.isEmpty && b.isEmpty) {
            if a.count > b.count { a.removeLast() } else { b.removeLast() }
            over -= 1
        }
        var out: [Int] = []
        out.reserveCapacity(a.count + b.count + 4)
        if bos >= 0 { out.append(bos) }
        out.append(contentsOf: a)
        if eos >= 0 { out.append(eos) }
        if bos >= 0 { out.append(bos) }
        out.append(contentsOf: b)
        if eos >= 0 { out.append(eos) }
        return out
    }

    // MARK: - 段 1：特殊トークンで切り分ける

    private enum Piece {
        case plain([UInt8])
        case special(Int)
    }

    private func splitOnAdded(_ bytes: [UInt8]) -> [Piece] {
        guard !added.isEmpty else { return bytes.isEmpty ? [] : [.plain(bytes)] }
        var out: [Piece] = []
        var at = 0
        var plainFrom = 0
        while at < bytes.count {
            var hit: (length: Int, id: Int)?
            for (content, id) in added where at + content.count <= bytes.count {
                if Array(bytes[at ..< at + content.count]) == content {
                    hit = (content.count, id)
                    break
                }
            }
            if let hit {
                if at > plainFrom { out.append(.plain(Array(bytes[plainFrom ..< at]))) }
                out.append(.special(hit.id))
                at += hit.length
                plainFrom = at
            } else {
                at += 1
            }
        }
        if plainFrom < bytes.count { out.append(.plain(Array(bytes[plainFrom...]))) }
        return out
    }

    // MARK: - 段 2：Metaspace

    /// 空白を ▁ に置き換える。prepend_scheme が never なので頭には足さない。
    private func metaspace(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        let mark = Array("\u{2581}".utf8)   // E2 96 81
        for byte in bytes {
            if byte == 0x20 { out.append(contentsOf: mark) } else { out.append(byte) }
        }
        return out
    }

    // MARK: - 段 3：Viterbi

    /// 最も点の高い分け方を選ぶ。バイト位置で進み、文字の頭だけを節点にする。
    private func viterbi(_ bytes: [UInt8]) -> [Int] {
        guard !bytes.isEmpty else { return [] }
        let count = bytes.count

        // 継続バイト（10xxxxxx）は節点にしない。
        var isBoundary = [Bool](repeating: false, count: count + 1)
        isBoundary[count] = true
        for i in 0 ..< count where bytes[i] & 0xC0 != 0x80 { isBoundary[i] = true }

        var best = [Double](repeating: -.greatestFiniteMagnitude, count: count + 1)
        var from = [Int](repeating: -1, count: count + 1)
        /// その節点へ入った語彙 id。-1 は語彙に無かった 1 文字。
        var arrived = [Int](repeating: -1, count: count + 1)
        best[0] = 0

        let unkScore = minScore - Self.unkPenalty

        for i in 0 ..< count where isBoundary[i] && best[i] > -.greatestFiniteMagnitude {
            var matchedWholeChar = false
            let limit = min(count, i + maxPieceBytes)
            let width = charLength(bytes, i)
            var j = i + 1
            while j <= limit {
                if isBoundary[j], let (id, score) = scores[Array(bytes[i ..< j])] {
                    let value = best[i] + score
                    if value > best[j] { best[j] = value; from[j] = i; arrived[j] = id }
                    if j - i == width { matchedWholeChar = true }
                }
                j += 1
            }
            // その位置の 1 文字が語彙に無ければ、罰つきで進める（あとで byte fallback にする）
            if !matchedWholeChar, i + width <= count {
                let j = i + width
                let value = best[i] + unkScore
                if value > best[j] { best[j] = value; from[j] = i; arrived[j] = -1 }
            }
        }

        var ids: [Int] = []
        var at = count
        while at > 0 {
            let previous = from[at]
            if previous < 0 { break }   // 進めなかった。起きないはずだが、途中まで返す
            if arrived[at] >= 0 {
                ids.append(arrived[at])
            } else if byteFallback {
                // 語彙に無い 1 文字は、UTF-8 のバイトごとに落とす
                for byte in bytes[previous ..< at].reversed() {
                    let id = byteToken[Int(byte)]
                    ids.append(id >= 0 ? id : unkId)
                }
            } else {
                ids.append(unkId)
            }
            at = previous
        }
        return ids.reversed()
    }

    /// そのバイト位置から始まる 1 文字のバイト数。
    private func charLength(_ bytes: [UInt8], _ i: Int) -> Int {
        let byte = bytes[i]
        if byte < 0x80 { return 1 }
        if byte & 0xE0 == 0xC0 { return 2 }
        if byte & 0xF0 == 0xE0 { return 3 }
        if byte & 0xF8 == 0xF0 { return 4 }
        return 1
    }
}
