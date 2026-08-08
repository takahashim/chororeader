import Accelerate
import Foundation

/// `model.safetensors` を読む。
///
/// ```text
/// | 見出しの長さ 8B（little endian） | 見出し（JSON） | 中身 |
/// ```
///
/// 見出しは名前ごとに `{"dtype": …, "shape": […], "data_offsets": [始, 終]}` を持ち、
/// 位置は**中身の先頭からの相対**である（見出しの長さと 8 を足した先が実体）。
///
/// **読むのは変換のときだけ**なので、速さより読み違えないことを優先する。
/// 中身は 1 度だけ mmap で開き、要る重みだけを Float へ広げる。
public struct Safetensors {
    /// 1 つの重み。
    struct Tensor {
        var name: String
        /// 元の形（`[出力, 入力]` など）。
        var shape: [Int]
        var dataType: String
        var start: Int
        var end: Int

        var count: Int { shape.reduce(1, *) }
    }

    private let data: Data
    private let body: Int
    private(set) var tensors: [String: Tensor] = [:]

    public enum Failure: Error, LocalizedError {
        case cannotRead(String)

        public var errorDescription: String? {
            switch self {
            case let .cannotRead(why): return "重みを読めません：\(why)"
            }
        }
    }

    public init(contentsOf url: URL) throws {
        // 数 GB になり得るので写さない。要る重みだけを後で広げる。
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > 8 else { throw Failure.cannotRead("短すぎます") }

        var length: UInt64 = 0
        for byte in 0 ..< 8 {
            length |= UInt64(data[data.startIndex + byte]) << UInt64(byte * 8)
        }
        guard length > 0, 8 + Int(length) <= data.count else {
            throw Failure.cannotRead("見出しの長さが合いません")
        }
        body = 8 + Int(length)

        let headerBytes = data.subdata(in: (data.startIndex + 8) ..< (data.startIndex + body))
        guard let json = try? JSONSerialization.jsonObject(with: headerBytes) as? [String: Any] else {
            throw Failure.cannotRead("見出しが JSON ではありません")
        }

        for (name, value) in json {
            // `__metadata__` は重みではない。
            guard name != "__metadata__", let entry = value as? [String: Any],
                  let dataType = entry["dtype"] as? String,
                  let shape = entry["shape"] as? [Int],
                  let offsets = entry["data_offsets"] as? [Int], offsets.count == 2
            else { continue }
            tensors[name] = Tensor(name: name, shape: shape, dataType: dataType,
                                   start: offsets[0], end: offsets[1])
        }
        guard !tensors.isEmpty else { throw Failure.cannotRead("重みが 1 つもありません") }
    }

    var names: [String] { tensors.keys.sorted() }

    func shape(of name: String) -> [Int]? { tensors[name]?.shape }

    /// Float へ広げて返す。**形は返さない**ので、呼ぶ側が知っている前提である。
    ///
    /// bf16・fp16・fp32 を扱う。ModernBERT の checkpoint はこのいずれかで配られる。
    func read(_ name: String) throws -> [Float] {
        guard let tensor = tensors[name] else {
            throw Failure.cannotRead("\(name) がありません")
        }
        let from = data.startIndex + body + tensor.start
        let to = data.startIndex + body + tensor.end
        guard to <= data.endIndex, from <= to else {
            throw Failure.cannotRead("\(name) の位置が範囲の外です")
        }
        let raw = data.subdata(in: from ..< to)

        switch tensor.dataType {
        case "F32":
            guard raw.count == tensor.count * 4 else {
                throw Failure.cannotRead("\(name) の大きさが形と合いません")
            }
            var out = [Float](repeating: 0, count: tensor.count)
            _ = out.withUnsafeMutableBytes { raw.copyBytes(to: $0) }
            return out

        case "F16":
            guard raw.count == tensor.count * 2 else {
                throw Failure.cannotRead("\(name) の大きさが形と合いません")
            }
            var half = [UInt16](repeating: 0, count: tensor.count)
            _ = half.withUnsafeMutableBytes { raw.copyBytes(to: $0) }
            var out = [Float](repeating: 0, count: tensor.count)
            half.withUnsafeMutableBufferPointer { input in
                out.withUnsafeMutableBufferPointer { output in
                    var source = vImage_Buffer(data: input.baseAddress, height: 1,
                                               width: vImagePixelCount(input.count),
                                               rowBytes: input.count * 2)
                    var target = vImage_Buffer(data: output.baseAddress, height: 1,
                                               width: vImagePixelCount(output.count),
                                               rowBytes: output.count * 4)
                    _ = vImageConvert_Planar16FtoPlanarF(&source, &target, 0)
                }
            }
            return out

        case "BF16":
            // bf16 は fp32 の上位 16 ビットそのものである。下位を 0 で埋めれば戻る。
            guard raw.count == tensor.count * 2 else {
                throw Failure.cannotRead("\(name) の大きさが形と合いません")
            }
            var out = [Float](repeating: 0, count: tensor.count)
            raw.withUnsafeBytes { source in
                for at in 0 ..< tensor.count {
                    let low = UInt32(source[at * 2])
                    let high = UInt32(source[at * 2 + 1])
                    out[at] = Float(bitPattern: (high << 24) | (low << 16))
                }
            }
            return out

        default:
            throw Failure.cannotRead("\(name) の型 \(tensor.dataType) は扱いません")
        }
    }
}
