import Foundation

/// protobuf の符号化。**書く一方で、読む側は作らない。**
///
/// Core ML の `.mlmodel` は protobuf である。変換器はそれを組み立てるだけなので、
/// 必要なのは符号化の 3 つの形しかない。依存を足さずに済む量である
/// （本体はここまで依存ゼロで来ている）。
///
/// | 種別 | 使い道 |
/// |---|---|
/// | varint | field の見出し、整数、真偽、列挙 |
/// | length-delimited | 文字列、bytes、入れ子のメッセージ、packed の配列 |
/// | 32 ビット固定長 | float |
///
/// **番号を写し間違えても黙って通らない。** Core ML が読めずにその場で落ちる。
/// 番号は kohagi の `proto/MIL.proto`・`proto/CoreMLModelSubset.proto` から写す。
struct Protowire {
    private(set) var bytes: [UInt8] = []

    init() {}

    var data: Data { Data(bytes) }
    var isEmpty: Bool { bytes.isEmpty }

    // MARK: - field を書く

    /// 整数・真偽・列挙。
    mutating func field(_ number: Int, varint value: UInt64) {
        key(number, wire: 0)
        Self.appendVarint(value, to: &bytes)
    }

    mutating func field(_ number: Int, varint value: Int) {
        field(number, varint: UInt64(value))
    }

    mutating func field(_ number: Int, bool value: Bool) {
        field(number, varint: value ? 1 : 0)
    }

    /// 文字列。**空でも書く**かどうかは呼ぶ側が決める
    /// （protobuf は既定値を省いてよいが、Core ML には省くと困る場所がある）。
    mutating func field(_ number: Int, string value: String) {
        field(number, bytes: Array(value.utf8))
    }

    /// bytes・入れ子のメッセージ・packed の配列。
    mutating func field(_ number: Int, bytes value: [UInt8]) {
        key(number, wire: 2)
        Self.appendVarint(UInt64(value.count), to: &bytes)
        bytes.append(contentsOf: value)
    }

    mutating func field(_ number: Int, bytes value: Data) {
        field(number, bytes: [UInt8](value))
    }

    /// 入れ子のメッセージ。**空のメッセージも書ける**
    /// （「そこに在る」ことに意味がある場合がある）。
    mutating func field(_ number: Int, message: Protowire) {
        field(number, bytes: message.bytes)
    }

    /// float。
    mutating func field(_ number: Int, float value: Float) {
        key(number, wire: 5)
        let raw = value.bitPattern
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8((raw >> UInt32(shift)) & 0xff))
        }
    }

    // MARK: - packed の配列

    /// packed varint（proto3 の既定）。
    mutating func packed(_ number: Int, varints values: [UInt64]) {
        guard !values.isEmpty else { return }
        var payload: [UInt8] = []
        for value in values { Self.appendVarint(value, to: &payload) }
        field(number, bytes: payload)
    }

    /// packed float。
    mutating func packed(_ number: Int, floats values: [Float]) {
        guard !values.isEmpty else { return }
        var payload = [UInt8]()
        payload.reserveCapacity(values.count * 4)
        for value in values {
            let raw = value.bitPattern
            for shift in stride(from: 0, to: 32, by: 8) {
                payload.append(UInt8((raw >> UInt32(shift)) & 0xff))
            }
        }
        field(number, bytes: payload)
    }

    // MARK: - 内側

    /// field の見出し。番号と種別を 1 つの varint に詰める。
    private mutating func key(_ number: Int, wire: UInt64) {
        Self.appendVarint(UInt64(number) << 3 | wire, to: &bytes)
    }

    static func appendVarint(_ value: UInt64, to out: inout [UInt8]) {
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

    /// 入れ子を組み立てる糖衣。
    static func message(_ build: (inout Protowire) -> Void) -> Protowire {
        var made = Protowire()
        build(&made)
        return made
    }
}
