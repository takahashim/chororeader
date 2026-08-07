import Accelerate
import Foundation

/// 書籍ひとつぶんの意味の索引。
///
/// 節ごとに 1 本のベクトルを持つ（spec-local-ai.md 第 4.1 節）。
/// ベクトルは正規化してあるので、近さは内積そのものである。
///
/// **モデルの名前を一緒に持つ。** ベクトルはモデルが変われば意味を失うが、
/// 見た目には何も変わらないので、持っていないと黙って違うものを比べることになる。
struct SemanticIndex {
    /// 作ったときのモデル。違えば使わない。
    let model: String
    let dimension: Int
    let units: [SemanticUnit]
    /// `units.count * dimension` を平らに並べたもの。単位ごとに正規化済み。
    /// 平らに持つのは、総当たりの内積を 1 回の行列積で済ませるためである。
    let vectors: [Float]
    /// いちばん長いバケットに収まらず、頭から切り詰めた単位の数。
    ///
    /// **切り詰めたものを割り直すことはしない**（spec-local-ai.md 第 4.1 節）。
    /// 割ると、片の多い節ほど「たまたま高く出る」機会が増え、
    /// そこは巻末（索引・解答・問題集）に偏る。数だけ残して、後から測り直せるようにする。
    let truncated: Int

    var count: Int { units.count }

    init(model: String, dimension: Int, units: [SemanticUnit], vectors: [Float], truncated: Int) {
        self.model = model
        self.dimension = dimension
        self.units = units
        self.vectors = vectors
        self.truncated = truncated
    }

    /// 近い順に単位の番号と点を返す。
    ///
    /// 総当たりで足りる。節単位なら 1,000 冊でも 10 万件程度で、
    /// 実測 0.35 ms である（第 4.3 節）。ANN は持たない。
    func nearest(to vector: [Float], limit: Int) -> [(unit: Int, score: Float)] {
        guard vector.count == dimension, count > 0 else { return [] }
        var scores = [Float](repeating: 0, count: count)
        // (count × dimension) と (dimension × 1) の積。行ごとの内積を一息で取る。
        vDSP_mmul(vectors, 1, vector, 1, &scores, 1,
                  vDSP_Length(count), 1, vDSP_Length(dimension))
        return scores.enumerated()
            .sorted { $0.element > $1.element }
            .prefix(limit)
            .map { (unit: $0.offset, score: $0.element) }
    }

    /// ある単位のベクトル。関連箇所は「いま読んでいる単位」を問いにする。
    func vector(at unit: Int) -> [Float]? {
        guard unit >= 0, unit < count else { return nil }
        return Array(vectors[unit * dimension ..< (unit + 1) * dimension])
    }
}

// MARK: - 書き出しと読み込み

extension SemanticIndex {
    /// ベクトルは float16 で書く。半分になり、内積の順位は変わらない。
    ///
    /// 512 次元で 1 単位 1 KB。蔵書 60 冊・6,000 単位で 6 MB である。
    func encoded() -> Data {
        var out = Data()
        append(&out, model)
        appendNumber(&out, UInt64(dimension))
        appendNumber(&out, UInt64(truncated))
        appendNumber(&out, UInt64(units.count))
        for unit in units {
            append(&out, unit.locator.href ?? "")
            appendNumber(&out, UInt64(unit.locator.page.map { $0 + 1 } ?? 0))
            // 位置は 10 万分の 1 まで。1,000 ページの本で 0.01 ページぶんの粗さで足りる。
            appendNumber(&out, UInt64((unit.locator.progression * 100_000).rounded()))
            append(&out, unit.locator.fragment ?? "")
            // 本文の目印。これが無いと、着くのは章（ページ）の頭までになる。
            append(&out, unit.locator.text ?? "")
            append(&out, unit.heading)
            append(&out, unit.excerpt)
        }
        var halves = [UInt16](repeating: 0, count: vectors.count)
        var source = vectors
        source.withUnsafeMutableBufferPointer { input in
            halves.withUnsafeMutableBufferPointer { output in
                var from = vImage_Buffer(data: input.baseAddress, height: 1,
                                         width: vImagePixelCount(input.count), rowBytes: input.count * 4)
                var to = vImage_Buffer(data: output.baseAddress, height: 1,
                                       width: vImagePixelCount(output.count), rowBytes: output.count * 2)
                _ = vImageConvert_PlanarFtoPlanar16F(&from, &to, 0)
            }
        }
        halves.withUnsafeBufferPointer { out.append(Data(buffer: $0)) }
        return out
    }

    init?(decoding data: Data) {
        var cursor = 0
        let bytes = [UInt8](data)
        func number() -> UInt64? {
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
        func string() -> String? {
            guard let length = number(), cursor + Int(length) <= bytes.count else { return nil }
            let made = String(decoding: bytes[cursor ..< cursor + Int(length)], as: UTF8.self)
            cursor += Int(length)
            return made
        }

        guard let model = string(), let dimension = number(), let truncated = number(),
              let total = number(), dimension > 0, dimension < 65536 else { return nil }

        var units: [SemanticUnit] = []
        units.reserveCapacity(Int(total))
        for _ in 0 ..< Int(total) {
            guard let href = string(), let page = number(), let progression = number(),
                  let fragment = string(), let anchor = string(),
                  let heading = string(), let excerpt = string()
            else { return nil }
            let locator = Locator(href: href.isEmpty ? nil : href,
                                  page: page == 0 ? nil : Int(page) - 1,
                                  progression: Double(progression) / 100_000,
                                  fragment: fragment.isEmpty ? nil : fragment,
                                  text: anchor.isEmpty ? nil : anchor)
            units.append(SemanticUnit(locator: locator, heading: heading, excerpt: excerpt))
        }

        let wanted = Int(total) * Int(dimension)
        guard bytes.count - cursor == wanted * 2 else { return nil }
        var halves = [UInt16](repeating: 0, count: wanted)
        _ = halves.withUnsafeMutableBytes { data.copyBytes(to: $0, from: cursor ..< bytes.count) }
        var vectors = [Float](repeating: 0, count: wanted)
        halves.withUnsafeMutableBufferPointer { input in
            vectors.withUnsafeMutableBufferPointer { output in
                var from = vImage_Buffer(data: input.baseAddress, height: 1,
                                         width: vImagePixelCount(input.count), rowBytes: input.count * 2)
                var to = vImage_Buffer(data: output.baseAddress, height: 1,
                                       width: vImagePixelCount(output.count), rowBytes: output.count * 4)
                _ = vImageConvert_Planar16FtoPlanarF(&from, &to, 0)
            }
        }
        self.init(model: model, dimension: Int(dimension), units: units,
                  vectors: vectors, truncated: Int(truncated))
    }

    private func append(_ out: inout Data, _ value: String) {
        let bytes = Array(value.utf8)
        appendNumber(&out, UInt64(bytes.count))
        out.append(contentsOf: bytes)
    }

    private func appendNumber(_ out: inout Data, _ value: UInt64) {
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
