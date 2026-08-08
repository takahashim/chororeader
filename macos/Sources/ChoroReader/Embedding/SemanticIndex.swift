import Accelerate
import Foundation

final class SemanticIndex: @unchecked Sendable {
    /// 作ったときのモデル。**読み込みのときに包む側から渡される。**
    let model: String
    let dimension: Int
    /// いちばん長いバケットに収まらず、頭から切り詰めた単位の数。
    /// 数だけ残して、後から測り直せるようにする（第 4.1 節）。
    let truncated: Int
    let count: Int

    /// 単位ごとの節の番号。**順位は節で決める**（第 5.1 節）ので、先にほどいておく。
    private let sectionIds: [Int32]
    /// `count * dimension` を fp16 のまま平らに並べたもの。単位ごとに正規化済み。
    private let half: [UInt16]

    /// メタデータ。ほどくまで Data のまま持ち、ほどいたら units に移して捨てる。
    private let gate = NSLock()
    private var lazyUnits: [SemanticUnit]?
    private var metaBlob: Data?

    init(model: String, dimension: Int, units: [SemanticUnit], vectors: [Float], truncated: Int) {
        self.model = model
        self.dimension = dimension
        self.truncated = truncated
        count = units.count
        sectionIds = units.map { Int32($0.section) }
        half = Self.narrowed(vectors)
        lazyUnits = units
        metaBlob = nil
    }

    private init(model: String, dimension: Int, truncated: Int,
                 sectionIds: [Int32], half: [UInt16], metaBlob: Data) {
        self.model = model
        self.dimension = dimension
        self.truncated = truncated
        count = sectionIds.count
        self.sectionIds = sectionIds
        self.half = half
        lazyUnits = nil
        self.metaBlob = metaBlob
    }

    // MARK: - 引く

    func nearest(to vector: [Float], limit: Int) -> [(unit: Int, score: Float)] {
        guard vector.count == dimension, count > 0 else { return [] }

        var wide = [Float](repeating: 0, count: half.count)
        Self.widen(half, into: &wide)
        var scores = [Float](repeating: 0, count: count)
        vDSP_mmul(wide, 1, vector, 1, &scores, 1,
                  vDSP_Length(count), 1, vDSP_Length(dimension))

        var best: [Int32: (unit: Int, sum: Float, members: Int, top: Float)] = [:]
        for at in 0 ..< count {
            let section = sectionIds[at]
            let score = scores[at]
            if var already = best[section] {
                already.sum += score
                already.members += 1
                if score > already.top {
                    already.top = score
                    already.unit = at
                }
                best[section] = already
            } else {
                best[section] = (unit: at, sum: score, members: 1, top: score)
            }
        }

        return best.values
            .map { (unit: $0.unit, score: $0.sum / Float($0.members)) }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    func vector(at unit: Int) -> [Float]? {
        guard unit >= 0, unit < count else { return nil }
        var out = [Float](repeating: 0, count: dimension)
        half.withUnsafeBufferPointer { whole in
            Self.widen(UnsafeBufferPointer(rebasing: whole[unit * dimension ..< (unit + 1) * dimension]),
                       into: &out)
        }
        return out
    }

    // MARK: - メタデータ

    /// 1 単位ぶんの飛び先と見出し。**最初に触ったときに全部ほどく。**
    ///
    /// 勝った書籍でしか呼ばれない前提である（`SemanticFinder` は並べ終えてから呼ぶ）。
    func unit(at: Int) -> SemanticUnit { units[at] }

    var units: [SemanticUnit] {
        gate.lock()
        defer { gate.unlock() }
        if let lazyUnits { return lazyUnits }
        let made = decodedMeta()
        lazyUnits = made
        metaBlob = nil
        return made
    }

    // MARK: - 書き出し

    func encoded() -> Data {
        var out = Data()
        Varint.append(UInt64(dimension), to: &out)
        Varint.append(UInt64(truncated), to: &out)
        Varint.append(UInt64(count), to: &out)
        for section in sectionIds { Varint.append(UInt64(section), to: &out) }
        half.withUnsafeBufferPointer { out.append(Data(buffer: $0)) }

        let meta = Self.encodedMeta(units)
        Varint.append(UInt64(meta.count), to: &out)
        out.append(meta)
        return out
    }

    convenience init?(decoding data: Data, from: Int = 0, model: String) {
        guard let parsed = Self.parse(data, from: from) else { return nil }
        self.init(model: model, dimension: parsed.dimension, truncated: parsed.truncated,
                  sectionIds: parsed.sections, half: parsed.half,
                  metaBlob: data.subdata(in: parsed.metaOffset ..< data.count))
    }

    private static func parse(_ data: Data, from: Int)
        -> (dimension: Int, truncated: Int, sections: [Int32], half: [UInt16], metaOffset: Int)? {
        data.withUnsafeBytes { raw in
            var reader = Varint.RawReader(buffer: raw, cursor: from)
            guard let dimension = reader.number(), dimension > 0, dimension < 65536,
                  let truncated = reader.number(),
                  let total = reader.number(), total < 5_000_000 else { return nil }

            var sections = [Int32]()
            sections.reserveCapacity(Int(total))
            for _ in 0 ..< Int(total) {
                guard let section = reader.number(), section < 10_000_000 else { return nil }
                sections.append(Int32(section))
            }

            let vectorBytes = Int(total) * Int(dimension) * 2
            guard reader.cursor + vectorBytes <= raw.count else { return nil }
            var half = [UInt16](repeating: 0, count: Int(total) * Int(dimension))
            if vectorBytes > 0 {
                half.withUnsafeMutableBytes {
                    $0.copyMemory(from: UnsafeRawBufferPointer(
                        rebasing: raw[reader.cursor ..< reader.cursor + vectorBytes]))
                }
            }
            reader.cursor += vectorBytes

            guard let metaLength = reader.number(),
                  raw.count - reader.cursor == Int(metaLength) else { return nil }
            return (Int(dimension), Int(truncated), sections, half, reader.cursor)
        }
    }

    // MARK: - メタデータの形

    private static func encodedMeta(_ units: [SemanticUnit]) -> Data {
        var table: [String] = [""]
        var lookup: [String: Int] = ["": 0]
        func indexed(_ text: String?) -> Int {
            let key = text ?? ""
            if let already = lookup[key] { return already }
            table.append(key)
            lookup[key] = table.count - 1
            return table.count - 1
        }

        // 先に全部引いて、表を確定させてから書く。
        let rows = units.map { unit in
            (heading: indexed(unit.heading),
             href: indexed(unit.locator.href),
             fragment: indexed(unit.locator.fragment),
             page: UInt64(unit.locator.page.map { $0 + 1 } ?? 0),
             progression: UInt64((unit.locator.progression * 100_000).rounded()),
             anchor: unit.locator.text ?? "")
        }

        var out = Data()
        Varint.append(UInt64(table.count), to: &out)
        for text in table { Varint.append(text, to: &out) }
        for row in rows {
            Varint.append(UInt64(row.heading), to: &out)
            Varint.append(UInt64(row.href), to: &out)
            Varint.append(UInt64(row.fragment), to: &out)
            Varint.append(row.page, to: &out)
            Varint.append(row.progression, to: &out)
            Varint.append(row.anchor, to: &out)
        }
        return out
    }

    private func decodedMeta() -> [SemanticUnit] {
        guard let blob = metaBlob else { return [] }
        var reader = Varint.Reader(blob)

        guard let tableCount = reader.number(), tableCount < 1_000_000 else { return broken() }
        var table = [String]()
        table.reserveCapacity(Int(tableCount))
        for _ in 0 ..< Int(tableCount) {
            guard let text = reader.text() else { return broken() }
            table.append(text)
        }
        func look(_ at: UInt64) -> String? {
            guard at < table.count else { return nil }
            let text = table[Int(at)]
            return text.isEmpty ? nil : text
        }

        var made = [SemanticUnit]()
        made.reserveCapacity(count)
        for at in 0 ..< count {
            guard let heading = reader.number(), let href = reader.number(),
                  let fragment = reader.number(), let page = reader.number(),
                  let progression = reader.number(), let anchor = reader.text()
            else { return broken() }
            let locator = Locator(href: look(href),
                                  page: page == 0 ? nil : Int(page) - 1,
                                  progression: Double(progression) / 100_000,
                                  fragment: look(fragment),
                                  text: anchor.isEmpty ? nil : anchor)
            made.append(SemanticUnit(locator: locator, heading: look(heading) ?? "",
                                     section: Int(sectionIds[at])))
        }
        return made
    }

    /// メタデータが崩れていたときの逃げ道。
    ///
    /// 長さの検査は通ったのに中身が読めない、はまず起きないが、
    /// 起きたときに数を食い違わせると `unit(at:)` が落ちる。空の殻で数だけ揃える。
    private func broken() -> [SemanticUnit] {
        (0 ..< count).map {
            SemanticUnit(locator: Locator(), heading: "", section: Int(sectionIds[$0]))
        }
    }

    // MARK: - fp16

    private static func narrowed(_ vectors: [Float]) -> [UInt16] {
        guard !vectors.isEmpty else { return [] }
        var made = [UInt16](repeating: 0, count: vectors.count)
        vectors.withUnsafeBufferPointer { source in
            made.withUnsafeMutableBufferPointer { target in
                var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress),
                                         height: 1, width: vImagePixelCount(source.count),
                                         rowBytes: source.count * 4)
                var to = vImage_Buffer(data: target.baseAddress, height: 1,
                                       width: vImagePixelCount(target.count),
                                       rowBytes: target.count * 2)
                _ = vImageConvert_PlanarFtoPlanar16F(&from, &to, 0)
            }
        }
        return made
    }

    private static func widen(_ half: [UInt16], into out: inout [Float]) {
        half.withUnsafeBufferPointer { Self.widen($0, into: &out) }
    }

    private static func widen(_ half: UnsafeBufferPointer<UInt16>, into out: inout [Float]) {
        guard !half.isEmpty else { return }
        out.withUnsafeMutableBufferPointer { target in
            var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: half.baseAddress),
                                     height: 1, width: vImagePixelCount(half.count),
                                     rowBytes: half.count * 2)
            var to = vImage_Buffer(data: target.baseAddress, height: 1,
                                   width: vImagePixelCount(target.count),
                                   rowBytes: target.count * 4)
            _ = vImageConvert_Planar16FtoPlanarF(&from, &to, 0)
        }
    }
}
