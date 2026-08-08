import Foundation

/// 全文検索の索引。
///
/// 日本語には単語の切れ目が無いので、二字組（バイグラム）を鍵にした転置索引を持つ。
///
/// この索引は**候補を絞るだけ**で、当たりを決めない。
/// 二字組が同じ単位に出ていても、続けて出ているとは限らないためである。
/// 絞った単位を `DocumentSearch` の走査にかけ直して初めて当たりが決まる。
/// そうすることで、結果は索引が無いときと一字も変わらない。
///
/// 当たりの位置を索引に持たせないぶん、容量が小さい。
/// 日本語 50 万字（400 ページ相当）で 300 KB 前後に収まる。
struct SearchIndex {
    /// 単位の終わりを表す番人。
    ///
    /// 1 文字だけの問い合わせは「その字で始まる二字組」をまとめて引くが、
    /// 単位の最後の 1 文字は次の字を持たないので、そのままでは引けない。
    /// 二字目を 0 にした組を足しておくと、範囲を引くだけで漏れなく当たる。
    private static let sentinel: UInt32 = 0

    private(set) var unitCount: Int
    private var keys: [UInt64]
    private var offsets: [UInt32]
    private var units: [UInt32]

    var isEmpty: Bool { keys.isEmpty }

    // MARK: - 組み立て

    static func build(_ unitTexts: [String]) -> SearchIndex {
        var pairs: [(key: UInt64, unit: UInt32)] = []

        for (number, text) in unitTexts.enumerated() {
            let number = UInt32(number)
            let scalars = SearchFold.scalars(text)
            guard !scalars.isEmpty else { continue }
            for i in 0 ..< (scalars.count - 1) {
                pairs.append((key(scalars[i], scalars[i + 1]), number))
            }
            pairs.append((key(scalars[scalars.count - 1], sentinel), number))
        }

        pairs.sort { $0.key == $1.key ? $0.unit < $1.unit : $0.key < $1.key }

        var index = SearchIndex(unitCount: unitTexts.count, keys: [], offsets: [0], units: [])
        for pair in pairs {
            if index.keys.last == pair.key {
                if index.units.last == pair.unit { continue }
            } else {
                index.keys.append(pair.key)
                index.offsets.append(UInt32(index.units.count))
            }
            index.units.append(pair.unit)
            index.offsets[index.offsets.count - 1] = UInt32(index.units.count)
        }
        return index
    }

    // MARK: - 引き

    /// 問い合わせが当たりうる単位の番号。昇順。
    ///
    /// `nil` は「索引では絞れないので全部を見よ」を意味する。
    func candidates(_ query: String) -> [Int]? {
        let scalars = SearchFold.scalars(query)
        if scalars.isEmpty { return nil }
        if scalars.count == 1 { return byFirstScalar(scalars[0]) }

        var found: [UInt32]?
        for i in 0 ..< (scalars.count - 1) {
            let posting = self.posting(Self.key(scalars[i], scalars[i + 1]))
            found = found.map { Self.intersect($0, posting) } ?? Array(posting)
            if found?.isEmpty == true { break }
        }
        return found?.map(Int.init)
    }

    private func posting(_ wanted: UInt64) -> ArraySlice<UInt32> {
        var low = 0
        var high = keys.count
        while low < high {
            let middle = (low + high) / 2
            if keys[middle] < wanted { low = middle + 1 } else { high = middle }
        }
        guard low < keys.count, keys[low] == wanted else { return [] }
        return units[Int(offsets[low]) ..< Int(offsets[low + 1])]
    }

    private func byFirstScalar(_ scalar: UInt32) -> [Int] {
        let from = UInt64(scalar) << 21
        let to = from + (1 << 21)
        var seen = [Bool](repeating: false, count: unitCount)
        var found: [Int] = []
        for at in lowerBound(from) ..< lowerBound(to) {
            for unit in units[Int(offsets[at]) ..< Int(offsets[at + 1])] where !seen[Int(unit)] {
                seen[Int(unit)] = true
                found.append(Int(unit))
            }
        }
        return found.sorted()
    }

    private func lowerBound(_ wanted: UInt64) -> Int {
        var low = 0
        var high = keys.count
        while low < high {
            let middle = (low + high) / 2
            if keys[middle] < wanted { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private static func intersect(_ left: [UInt32], _ right: ArraySlice<UInt32>) -> [UInt32] {
        var found: [UInt32] = []
        var a = left.startIndex
        var b = right.startIndex
        while a < left.endIndex, b < right.endIndex {
            if left[a] < right[b] {
                a += 1
            } else if left[a] > right[b] {
                b += 1
            } else {
                found.append(left[a])
                a += 1
                b += 1
            }
        }
        return found
    }

    private static func key(_ first: UInt32, _ second: UInt32) -> UInt64 {
        (UInt64(first) << 21) | UInt64(second)
    }

    // MARK: - 書き出しと読み込み
    //
    // 鍵も単位番号も昇順に並んでいるので、差分を可変長で書けば大半が 1 バイトで済む。
    // 形式は Tauri 版と同じにしてある。ファイルを共有はしないが、決めを 2 度書かないため。

    private static let magic: [UInt8] = Array("CHIX".utf8)
    private static let version: UInt8 = 1

    func encoded() -> Data {
        var out = Data(Self.magic)
        out.append(Self.version)
        put(&out, UInt64(unitCount))
        put(&out, UInt64(keys.count))

        var previousKey: UInt64 = 0
        for at in keys.indices {
            put(&out, keys[at] - previousKey)
            previousKey = keys[at]
            put(&out, UInt64(offsets[at + 1] - offsets[at]))
        }

        for at in keys.indices {
            var previousUnit: UInt32 = 0
            for unit in units[Int(offsets[at]) ..< Int(offsets[at + 1])] {
                put(&out, UInt64(unit - previousUnit))
                previousUnit = unit
            }
        }
        return out
    }

    init?(decoding data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count > Self.magic.count,
              Array(bytes[0 ..< Self.magic.count]) == Self.magic,
              bytes[Self.magic.count] == Self.version else { return nil }

        var cursor = Self.magic.count + 1
        func get() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while cursor < bytes.count {
                let byte = bytes[cursor]
                cursor += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
                if shift >= 64 { return nil }
            }
            return nil
        }

        guard let count = get(), let keyCount = get(), count <= UInt64(UInt32.max) else { return nil }
        unitCount = Int(count)

        keys = []
        keys.reserveCapacity(Int(keyCount))
        var lengths: [UInt32] = []
        lengths.reserveCapacity(Int(keyCount))
        var previousKey: UInt64 = 0
        for _ in 0 ..< keyCount {
            guard let delta = get(), let length = get() else { return nil }
            previousKey += delta
            keys.append(previousKey)
            lengths.append(UInt32(truncatingIfNeeded: length))
        }

        offsets = [0]
        offsets.reserveCapacity(Int(keyCount) + 1)
        units = []
        for length in lengths {
            var previousUnit: UInt32 = 0
            for _ in 0 ..< length {
                guard let delta = get() else { return nil }
                previousUnit += UInt32(truncatingIfNeeded: delta)
                guard previousUnit < UInt32(unitCount) else { return nil }
                units.append(previousUnit)
            }
            offsets.append(UInt32(units.count))
        }
    }

    private init(unitCount: Int, keys: [UInt64], offsets: [UInt32], units: [UInt32]) {
        self.unitCount = unitCount
        self.keys = keys
        self.offsets = offsets
        self.units = units
    }

    private func put(_ out: inout Data, _ value: UInt64) {
        var value = value
        while true {
            let byte = UInt8(value & 0x7f)
            value >>= 7
            if value == 0 {
                out.append(byte)
                return
            }
            out.append(byte | 0x80)
        }
    }
}

/// 索引に載せる形。走査側と同じ規則で畳む。
///
/// 走査は `String.range(of:options:)` に任せているので、畳み方もその `options` に合わせる。
/// ここが走査より厳しくなると、索引が本当の当たりを落としてしまう。
enum SearchFold {
    /// 合成の違いを消してから 1 文字ずつ数に落とす。
    ///
    /// 正規化しておけば、「か」＋濁点と「が」が同じ数になる。
    /// 結合文字が後ろに付く文字は先頭の符号位置だけを見るが、
    /// それで一致する組が増える方向にしか動かないので、当たりを落とすことはない。
    static func scalars(_ text: String) -> [UInt32] {
        text.folding(options: DocumentSearch.options, locale: nil)
            .precomposedStringWithCanonicalMapping
            .compactMap { $0.unicodeScalars.first?.value }
    }
}
