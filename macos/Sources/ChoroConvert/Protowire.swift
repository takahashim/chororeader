import Foundation

struct Protowire {
    private(set) var bytes: [UInt8] = []

    init() {}

    var data: Data { Data(bytes) }
    var isEmpty: Bool { bytes.isEmpty }

    // MARK: - field を書く

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

    mutating func field(_ number: Int, string value: String) {
        field(number, bytes: Array(value.utf8))
    }

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

    mutating func field(_ number: Int, float value: Float) {
        key(number, wire: 5)
        let raw = value.bitPattern
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8((raw >> UInt32(shift)) & 0xff))
        }
    }

    // MARK: - packed の配列

    mutating func packed(_ number: Int, varints values: [UInt64]) {
        guard !values.isEmpty else { return }
        var payload: [UInt8] = []
        for value in values { Self.appendVarint(value, to: &payload) }
        field(number, bytes: payload)
    }

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

    static func message(_ build: (inout Protowire) -> Void) -> Protowire {
        var made = Protowire()
        build(&made)
        return made
    }
}
