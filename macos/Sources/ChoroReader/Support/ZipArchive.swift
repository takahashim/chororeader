import Compression
import Foundation

/// EPUB を展開せずに読むための最小 ZIP リーダー。
/// 章は要求された時点で個別に取り出す。全展開しないため、開いてから最初の表示までが短い。
final class ZipArchive {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    enum Failure: Error {
        case notAZip
        case truncated
        case unsupportedCompression(UInt16)
        case inflateFailed(String)
        case entryNotFound(String)
    }

    private let data: Data
    private(set) var entries: [String: Entry] = [:]
    private(set) var names: [String] = []

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        try readCentralDirectory()
    }

    // MARK: - 読み出し

    func contains(_ path: String) -> Bool { entry(for: path) != nil }

    func read(_ path: String) throws -> Data {
        guard let e = entry(for: path) else { throw Failure.entryNotFound(path) }
        return try read(e)
    }

    func read(_ e: Entry) throws -> Data {
        // ローカルヘッダは中央ディレクトリと名前長・拡張長が異なりうるので、必ず読み直す。
        let o = e.localHeaderOffset
        guard o + 30 <= data.count, u32(o) == 0x0403_4b50 else { throw Failure.truncated }
        let nameLen = Int(u16(o + 26))
        let extraLen = Int(u16(o + 28))
        let start = o + 30 + nameLen + extraLen
        guard start + e.compressedSize <= data.count else { throw Failure.truncated }
        let raw = data.subdata(in: (data.startIndex + start) ..< (data.startIndex + start + e.compressedSize))

        switch e.method {
        case 0: return raw
        case 8: return try inflate(raw, expected: e.uncompressedSize)
        default: throw Failure.unsupportedCompression(e.method)
        }
    }

    private func entry(for path: String) -> Entry? {
        if let e = entries[path] { return e }
        if let decoded = path.removingPercentEncoding, let e = entries[decoded] { return e }
        // 大文字小文字だけが違う参照を持つ EPUB が実在するため、最後に緩く照合する。
        let lower = path.lowercased()
        if let key = entries.keys.first(where: { $0.lowercased() == lower }) { return entries[key] }
        return nil
    }

    private func inflate(_ src: Data, expected: Int) throws -> Data {
        guard expected > 0 else { return Data() }
        var dst = Data(count: expected)
        let written: Int = dst.withUnsafeMutableBytes { dstBuf in
            src.withUnsafeBytes { srcBuf in
                guard let d = dstBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let s = srcBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                // ZIP の deflate はヘッダなしの生ストリーム。COMPRESSION_ZLIB がこれに対応する。
                return compression_decode_buffer(d, expected, s, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expected else {
            throw Failure.inflateFailed("expected \(expected) bytes, got \(written)")
        }
        return dst
    }

    // MARK: - 中央ディレクトリ

    private func readCentralDirectory() throws {
        guard data.count > 22 else { throw Failure.notAZip }

        var eocd = -1
        let lowest = max(0, data.count - 66_000)
        var i = data.count - 22
        while i >= lowest {
            if u32(i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw Failure.notAZip }

        var count = Int(u16(eocd + 10))
        var cdOffset = Int(u32(eocd + 16))

        // ZIP64（4GB 超、または 65535 項目超）
        if count == 0xFFFF || cdOffset == 0xFFFF_FFFF {
            let locator = eocd - 20
            guard locator >= 0, u32(locator) == 0x0706_4b50 else { throw Failure.truncated }
            let z64 = Int(u64(locator + 8))
            guard z64 >= 0, z64 + 56 <= data.count, u32(z64) == 0x0606_4b50 else { throw Failure.truncated }
            count = Int(u64(z64 + 32))
            cdOffset = Int(u64(z64 + 48))
        }

        var p = cdOffset
        entries.reserveCapacity(count)
        names.reserveCapacity(count)
        for _ in 0 ..< count {
            guard p + 46 <= data.count, u32(p) == 0x0201_4b50 else { break }
            let method = u16(p + 10)
            var compressed = Int(u32(p + 20))
            var uncompressed = Int(u32(p + 24))
            let nameLen = Int(u16(p + 28))
            let extraLen = Int(u16(p + 30))
            let commentLen = Int(u16(p + 32))
            var localOffset = Int(u32(p + 42))

            guard p + 46 + nameLen <= data.count else { break }
            let nameData = data.subdata(in: (data.startIndex + p + 46) ..< (data.startIndex + p + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)

            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                readZip64Extra(at: p + 46 + nameLen, length: extraLen,
                               uncompressed: &uncompressed, compressed: &compressed, offset: &localOffset)
            }

            if !name.hasSuffix("/") {
                let e = Entry(name: name, method: method, compressedSize: compressed,
                              uncompressedSize: uncompressed, localHeaderOffset: localOffset)
                entries[name] = e
                names.append(name)
            }
            p += 46 + nameLen + extraLen + commentLen
        }

        guard !entries.isEmpty else { throw Failure.notAZip }
    }

    private func readZip64Extra(at start: Int, length: Int,
                                uncompressed: inout Int, compressed: inout Int, offset: inout Int) {
        var q = start
        let end = min(start + length, data.count)
        while q + 4 <= end {
            let id = u16(q)
            let size = Int(u16(q + 2))
            guard q + 4 + size <= end else { return }
            if id == 0x0001 {
                var f = q + 4
                if uncompressed == 0xFFFF_FFFF, f + 8 <= end { uncompressed = Int(u64(f)); f += 8 }
                if compressed == 0xFFFF_FFFF, f + 8 <= end { compressed = Int(u64(f)); f += 8 }
                if offset == 0xFFFF_FFFF, f + 8 <= end { offset = Int(u64(f)) }
                return
            }
            q += 4 + size
        }
    }

    // MARK: - リトルエンディアン読み出し

    private func byte(_ o: Int) -> UInt8 {
        let i = data.startIndex + o
        return i < data.endIndex ? data[i] : 0
    }
    private func u16(_ o: Int) -> UInt16 {
        UInt16(byte(o)) | (UInt16(byte(o + 1)) << 8)
    }
    private func u32(_ o: Int) -> UInt32 {
        var v: UInt32 = 0
        for k in 0 ..< 4 { v |= UInt32(byte(o + k)) << (8 * UInt32(k)) }
        return v
    }
    private func u64(_ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0 ..< 8 { v |= UInt64(byte(o + k)) << (8 * UInt64(k)) }
        return v
    }
}
