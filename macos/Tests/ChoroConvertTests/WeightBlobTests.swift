import XCTest
@testable import ChoroConvert

/// `weight.bin` の書き手。
///
/// **読み手を検査側に別に持つ。** 書き手が自分の書いたものを自分で読むと、
/// 形式が間違っていても往復するだけで通ってしまう。ここでは
/// coremltools の形式の記述（頭 64B ＋ 目録 64B ＋ 中身、目録は 64B 境界）から
/// 独立に読み直す。
///
/// 最終的な審判は kohagi の出力との**バイト一致**だが、それはモデルが要る。
/// こちらはモデル無しで、形式の側から固める。
final class WeightBlobTests: XCTestCase {
    private struct Record {
        var metaOffset: Int
        var type: UInt32
        var size: UInt64
        var dataOffset: UInt64
    }

    /// 形式の記述から独立に読む。
    private func parse(_ data: Data) throws -> (count: UInt32, records: [Record]) {
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> UInt32 {
            (0 ..< 4).reduce(UInt32(0)) { $0 | UInt32(bytes[at + $1]) << UInt32($1 * 8) }
        }
        func u64(_ at: Int) -> UInt64 {
            (0 ..< 8).reduce(UInt64(0)) { $0 | UInt64(bytes[at + $1]) << UInt64($1 * 8) }
        }
        let count = u32(0)
        XCTAssertEqual(u32(4), 2, "版が 2 ではない")

        var records: [Record] = []
        var at = 64
        for _ in 0 ..< count {
            at = (at + 63) / 64 * 64
            XCTAssertEqual(u32(at), 0xDEAD_BEEF, "\(at) の見張りが違う")
            let record = Record(metaOffset: at, type: u32(at + 4),
                                size: u64(at + 8), dataOffset: u64(at + 16))
            records.append(record)
            at = Int(record.dataOffset + record.size)
        }
        return (count, records)
    }

    func test_空でも頭だけは書く() throws {
        let blob = WeightBlob()
        let data = blob.finish()
        XCTAssertEqual(data.count, 64, "頭は 64 バイト")
        let read = try parse(data)
        XCTAssertEqual(read.count, 0)
    }

    func test_fp16を足して読み直せる() throws {
        var blob = WeightBlob()
        let offset = blob.append(fp16: [1, 2, 3, 4])
        let data = blob.finish()
        let read = try parse(data)

        XCTAssertEqual(read.count, 1)
        let record = try XCTUnwrap(read.records.first)
        XCTAssertEqual(UInt64(record.metaOffset), offset, "返す位置は目録の位置")
        XCTAssertEqual(record.type, 1, "fp16 は 1")
        XCTAssertEqual(record.size, 8, "4 個 × 2 バイト")
        XCTAssertEqual(record.dataOffset, offset + 64, "中身は目録の直後")
    }

    /// **どの目録も 64 バイトの境目から始まること。**
    /// ここがずれると、中身の並びも揃わず、Core ML が読めない。
    func test_目録は64バイトの境目に置く() throws {
        var blob = WeightBlob()
        // 中途半端な長さを重ねて、詰め物が要る形にする
        for count in [3, 5, 7, 1, 9] {
            _ = blob.append(fp16: (0 ..< count).map { Float($0) })
        }
        let read = try parse(blob.finish())
        XCTAssertEqual(read.count, 5)
        for record in read.records {
            XCTAssertEqual(record.metaOffset % 64, 0, "目録が境目にない：\(record.metaOffset)")
            XCTAssertEqual(record.dataOffset % 64, 0, "中身が境目にない：\(record.dataOffset)")
        }
    }

    func test_型ごとの番号() throws {
        var blob = WeightBlob()
        _ = blob.append(fp16: [1])
        _ = blob.append(fp32: [1])
        _ = blob.append(int8: [1])
        let read = try parse(blob.finish())
        XCTAssertEqual(read.records.map(\.type), [1, 2, 4], "fp16=1・fp32=2・int8=4")
        XCTAssertEqual(read.records.map(\.size), [2, 4, 1])
    }

    /// fp16 の中身が下位バイトから並ぶこと。
    func test_fp16は下位バイトから並ぶ() throws {
        var blob = WeightBlob()
        let offset = blob.append(fp16: [1])
        let data = [UInt8](blob.finish())
        let at = Int(offset) + 64
        // 1.0 の fp16 は 0x3c00
        XCTAssertEqual(data[at], 0x00)
        XCTAssertEqual(data[at + 1], 0x3c)
    }

    /// fp32 の中身も下位バイトから。
    func test_fp32は下位バイトから並ぶ() throws {
        var blob = WeightBlob()
        let offset = blob.append(fp32: [1])
        let data = [UInt8](blob.finish())
        let at = Int(offset) + 64
        // 1.0 の fp32 は 0x3f800000
        XCTAssertEqual(Array(data[at ..< at + 4]), [0x00, 0x00, 0x80, 0x3f])
    }

    /// 個数が頭に書かれること。**足すたびに書き直す**形なので、最後の値が残る。
    func test_個数を頭に書く() throws {
        var blob = WeightBlob()
        for _ in 0 ..< 7 { _ = blob.append(fp16: [1, 2]) }
        let read = try parse(blob.finish())
        XCTAssertEqual(read.count, 7)
        XCTAssertEqual(blob.count, 7)
    }

    /// 位置は重ならないこと。**重なると、別の const が同じ中身を指す。**
    func test_位置は重ならない() {
        var blob = WeightBlob()
        var offsets: [UInt64] = []
        for count in 1 ... 20 { offsets.append(blob.append(fp16: Array(repeating: 1, count: count))) }
        XCTAssertEqual(Set(offsets).count, offsets.count)
        XCTAssertEqual(offsets, offsets.sorted(), "後から足したものが前に来ている")
    }

    /// 端の値が fp16 で潰れること自体は正しい。**潰れ方を知っておく。**
    func test_fp16の丸め方() throws {
        var blob = WeightBlob()
        let offset = blob.append(fp16: [65504, 70000, 0.00001])
        let data = [UInt8](blob.finish())
        let at = Int(offset) + 64
        func read(_ index: Int) -> UInt16 {
            UInt16(data[at + index * 2]) | UInt16(data[at + index * 2 + 1]) << 8
        }
        XCTAssertEqual(read(0), 0x7bff, "fp16 の最大は 65504")
        XCTAssertEqual(read(1), 0x7c00, "超えると無限大になる")
        XCTAssertNotEqual(read(2), 0, "小さすぎる値は非正規化数として残る")
    }
}
