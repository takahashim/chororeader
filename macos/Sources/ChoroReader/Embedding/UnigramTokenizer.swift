import Foundation

struct UnigramTokenizer {
    /// 語彙。UTF-8 のバイト列から引く。
    private let scores: [[UInt8]: (id: Int, score: Double)]
    private let unkId: Int
    private let byteFallback: Bool
    private let byteToken: [Int]
    private let added: [(content: [UInt8], id: Int)]
    private let bos: Int
    private let eos: Int
    private let minScore: Double
    /// 語彙に載る最長のバイト数。Viterbi の探索幅を切る。
    private let maxPieceBytes: Int

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

        added = ((json["added_tokens"] as? [[String: Any]]) ?? [])
            .compactMap { entry in
                guard let content = entry["content"] as? String, let id = entry["id"] as? Int
                else { return nil }
                return (Array(content.utf8), id)
            }
            .sorted { $0.0.count > $1.0.count }

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

    private func viterbi(_ bytes: [UInt8]) -> [Int] {
        guard !bytes.isEmpty else { return [] }
        let count = bytes.count

        var isBoundary = [Bool](repeating: false, count: count + 1)
        isBoundary[count] = true
        for i in 0 ..< count where bytes[i] & 0xC0 != 0x80 { isBoundary[i] = true }

        var best = [Double](repeating: -.greatestFiniteMagnitude, count: count + 1)
        var from = [Int](repeating: -1, count: count + 1)
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
