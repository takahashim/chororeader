import Accelerate
import Foundation

/// `weights/weight.bin` を書く。MIL の const が中身を指す先である。
///
/// 形式は coremltools の `MILBlob/Blob/StorageFormat.hpp` 由来
/// （BSD-3-Clause。告知は `LICENSE-COREMLTOOLS-BSD` に運ぶ）。
///
/// ```text
/// | 頭 64B | 目録 64B | 中身 | 詰め物 | 目録 64B | 中身 | …
/// ```
///
/// **どの目録も 64 バイトの境目から始まる**ので、その直後に来る中身も揃う。
/// MIL の const が指すのは中身ではなく**目録の位置**で、
/// `write` の類が返すのはその位置である。
///
/// 形式が正しいことは kohagi 側で確かめてある（公開済みの `weight.bin` を
/// 読み書きして往復させ、形式がこの通りであることを立てた）。
/// こちらは**その kohagi の出力とバイト単位で突き合わせる**（第 7 節の審判 1）。
struct WeightBlob {
    private static let align = 64
    private static let sentinel: UInt32 = 0xDEAD_BEEF
    private static let metaSize = 64
    private static let version: UInt32 = 2

    /// coremltools の `MILBlob/Blob/BlobDataType.hpp`。
    private enum DataType: UInt32 {
        case float16 = 1
        case float32 = 2
        case int8 = 4
    }

    private var bytes: [UInt8]
    private(set) var count: UInt32 = 0

    init() {
        // 頭は中身を足すたびに書き直す（個数を持つため）。
        // **版は最初から書いておく。** 足す前に書き出すことは実際には無いが、
        // 版が 0 のまま出ると、版を見る読み手に弾かれる形になる。
        // 中身のあるものでは append が上書きするので、kohagi との一致には影響しない。
        bytes = [UInt8](repeating: 0, count: Self.align)
        Self.put(Self.version, into: &bytes, at: 4)
    }

    /// fp16 として足し、**目録の位置**を返す。
    ///
    /// 変換された encoder が持つのはこの形である。
    mutating func append(fp16 values: [Float]) -> UInt64 {
        guard !values.isEmpty else { return append(.float16, []) }
        var half = [UInt16](repeating: 0, count: values.count)
        var source = values
        source.withUnsafeMutableBufferPointer { input in
            half.withUnsafeMutableBufferPointer { output in
                var from = vImage_Buffer(data: input.baseAddress, height: 1,
                                         width: vImagePixelCount(input.count),
                                         rowBytes: input.count * 4)
                var to = vImage_Buffer(data: output.baseAddress, height: 1,
                                       width: vImagePixelCount(output.count),
                                       rowBytes: output.count * 2)
                _ = vImageConvert_PlanarFtoPlanar16F(&from, &to, 0)
            }
        }
        var raw = [UInt8]()
        raw.reserveCapacity(half.count * 2)
        for value in half {
            raw.append(UInt8(value & 0xff))
            raw.append(UInt8(value >> 8))
        }
        return append(.float16, raw)
    }

    mutating func append(fp32 values: [Float]) -> UInt64 {
        var raw = [UInt8]()
        raw.reserveCapacity(values.count * 4)
        for value in values {
            let pattern = value.bitPattern
            for shift in stride(from: 0, to: 32, by: 8) {
                raw.append(UInt8((pattern >> UInt32(shift)) & 0xff))
            }
        }
        return append(.float32, raw)
    }

    mutating func append(int8 values: [Int8]) -> UInt64 {
        append(.int8, values.map { UInt8(bitPattern: $0) })
    }

    /// 書き終えた中身。`weights/weight.bin` へそのまま置く。
    func finish() -> Data { Data(bytes) }

    // MARK: - 内側

    private mutating func append(_ type: DataType, _ data: [UInt8]) -> UInt64 {
        while bytes.count % Self.align != 0 { bytes.append(0) }
        let metaOffset = bytes.count
        let dataOffset = metaOffset + Self.metaSize

        var meta = [UInt8](repeating: 0, count: Self.metaSize)
        Self.put(UInt32(Self.sentinel), into: &meta, at: 0)
        Self.put(type.rawValue, into: &meta, at: 4)
        Self.put(UInt64(data.count), into: &meta, at: 8)
        Self.put(UInt64(dataOffset), into: &meta, at: 16)
        // 24 番地以降の詰め物のビット数は 0 のまま。1 バイト未満の型でしか使わない。
        bytes.append(contentsOf: meta)
        bytes.append(contentsOf: data)

        count += 1
        Self.put(count, into: &bytes, at: 0)
        Self.put(Self.version, into: &bytes, at: 4)
        return UInt64(metaOffset)
    }

    private static func put(_ value: UInt32, into out: inout [UInt8], at offset: Int) {
        for byte in 0 ..< 4 { out[offset + byte] = UInt8((value >> UInt32(byte * 8)) & 0xff) }
    }

    private static func put(_ value: UInt64, into out: inout [UInt8], at offset: Int) {
        for byte in 0 ..< 8 { out[offset + byte] = UInt8((value >> UInt64(byte * 8)) & 0xff) }
    }
}
