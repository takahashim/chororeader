import Foundation

/// 可変長の整数と、長さ付きの文字列。
///
/// 索引の書き出しはどれもこの形で、二字組索引・意味の索引の**3 か所に同じものが散っていた**。
/// 形式を触るたびに 3 か所直すことになるので、1 つに寄せる。
enum Varint {
    static func append(_ value: UInt64, to out: inout Data) {
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

    static func append(_ text: String, to out: inout Data) {
        let bytes = Array(text.utf8)
        append(UInt64(bytes.count), to: &out)
        out.append(contentsOf: bytes)
    }

    /// 写さずに読む。**`Data` 全体を `[UInt8]` へ写してはいけない。**
    ///
    /// Reader は作るときにファイル全体を写す。頭の数十バイトを読むために
    /// 300 KB の sidecar を丸ごと写し、それを頭の検査と本体で 2 回やっていた。
    /// mmap で開いたファイルなら、写した時点で全ページが実 RAM に乗ってしまう。
    ///
    /// `withUnsafeBytes` の中でだけ生きる。外へ持ち出してはいけない。
    struct RawReader {
        let buffer: UnsafeRawBufferPointer
        var cursor: Int

        var remaining: Int { buffer.count - cursor }

        mutating func number() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while cursor < buffer.count {
                let byte = buffer[cursor]
                cursor += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
                if shift >= 64 { return nil }
            }
            return nil
        }
    }

    /// 読み取りの位置を持って進む。**足りなければ nil を返す**。
    ///
    /// 途中で切れたものを黙って受け取ると、単位とベクトルの数が食い違ったまま引くことになる。
    struct Reader {
        private let bytes: [UInt8]
        private(set) var cursor: Int

        init(_ data: Data, from: Int = 0) {
            bytes = [UInt8](data)
            cursor = from
        }

        var remaining: Int { bytes.count - cursor }

        mutating func number() -> UInt64? {
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

        mutating func text() -> String? {
            guard let length = number(), cursor + Int(length) <= bytes.count else { return nil }
            let made = String(decoding: bytes[cursor ..< cursor + Int(length)], as: UTF8.self)
            cursor += Int(length)
            return made
        }
    }
}
