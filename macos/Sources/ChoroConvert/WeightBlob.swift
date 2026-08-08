import Accelerate
import Foundation

struct WeightBlob {
    private static let align = 64
    private static let sentinel: UInt32 = 0xDEAD_BEEF
    private static let metaSize = 64
    private static let version: UInt32 = 2

    private enum DataType: UInt32 {
        case float16 = 1
        case float32 = 2
        case int8 = 4
    }

    private var bytes: [UInt8]
    private(set) var count: UInt32 = 0

    init() {
        bytes = [UInt8](repeating: 0, count: Self.align)
        Self.put(Self.version, into: &bytes, at: 4)
    }

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
