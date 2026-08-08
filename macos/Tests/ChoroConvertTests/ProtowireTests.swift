import XCTest
@testable import ChoroConvert

/// protobuf の符号化。
///
/// **ここが 1 バイトずれると、Core ML が読めずにその場で落ちる。**
/// 黙って壊れる形ではないが、落ちたときに原因が分かるよう、
/// 既知の値との突き合わせで固めておく。
///
/// 期待値は protobuf の仕様そのものから採った（`protoc` の出力ではない）。
/// varint は 7 ビットずつ下位から、続きがあれば最上位に 1 を立てる。
/// field の見出しは `番号 << 3 | 種別`。
final class ProtowireTests: XCTestCase {
    private func hex(_ made: Protowire) -> String {
        made.bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - varint

    func test_varintの刻み() {
        var one = Protowire()
        one.field(1, varint: 0)
        XCTAssertEqual(hex(one), "0800", "番号 1・種別 0 の見出しは 0x08")

        var small = Protowire()
        small.field(1, varint: 127)
        XCTAssertEqual(hex(small), "087f", "127 は 1 バイトに収まる")

        var edge = Protowire()
        edge.field(1, varint: 128)
        XCTAssertEqual(hex(edge), "088001", "128 から 2 バイト。下位 7 ビットが先")

        var big = Protowire()
        big.field(1, varint: 300)
        XCTAssertEqual(hex(big), "08ac02")
    }

    func test_最大の値も書ける() {
        var made = Protowire()
        made.field(1, varint: UInt64.max)
        // 64 ビットは 7 ビット × 10 で収まる
        XCTAssertEqual(made.bytes.count, 1 + 10)
        XCTAssertEqual(hex(made), "08ffffffffffffffffff01")
    }

    /// 番号が 16 を超えると見出しが 2 バイトになる。**境目を踏む。**
    func test_番号が大きいと見出しも伸びる() {
        var small = Protowire()
        small.field(15, varint: 1)
        XCTAssertEqual(hex(small), "7801", "15 << 3 = 120 = 0x78")

        var large = Protowire()
        large.field(16, varint: 1)
        XCTAssertEqual(hex(large), "800101", "16 << 3 = 128。ここから 2 バイト")
    }

    func test_真偽は0と1() {
        var made = Protowire()
        made.field(2, bool: true)
        made.field(3, bool: false)
        XCTAssertEqual(hex(made), "10011800")
    }

    // MARK: - length-delimited

    func test_文字列は長さを前に置く() {
        var made = Protowire()
        made.field(1, string: "abc")
        XCTAssertEqual(hex(made), "0a03616263", "見出し 0x0a・長さ 3・abc")
    }

    /// **日本語はバイト数で数える。** 文字数で数えると長さが合わず、
    /// 後ろの field がずれて読めなくなる。
    func test_日本語はバイト数で数える() {
        var made = Protowire()
        made.field(1, string: "架空")
        XCTAssertEqual(made.bytes[1], 6, "3 バイト × 2 文字")
        XCTAssertEqual(hex(made), "0a06" + "e69eb6" + "e7a9ba")
    }

    func test_空の文字列も書ける() {
        var made = Protowire()
        made.field(1, string: "")
        XCTAssertEqual(hex(made), "0a00", "長さ 0 として在ることを示す")
    }

    func test_入れ子は中身をそのまま包む() {
        let inner = Protowire.message { $0.field(1, varint: 150) }
        var outer = Protowire()
        outer.field(2, message: inner)
        XCTAssertEqual(hex(inner), "089601")
        XCTAssertEqual(hex(outer), "1203089601", "見出し 0x12・長さ 3・中身")
    }

    /// 空の入れ子も書けること。**在ることに意味がある場所がある。**
    func test_空の入れ子も書ける() {
        var made = Protowire()
        made.field(1, message: Protowire())
        XCTAssertEqual(hex(made), "0a00")
    }

    // MARK: - 固定長

    func test_floatは32ビット下位から() {
        var made = Protowire()
        made.field(1, float: 1)
        // 1.0 の IEEE754 は 0x3f800000。protobuf は下位のバイトから並べる
        XCTAssertEqual(hex(made), "0d0000803f", "見出し 0x0d（種別 5）")
    }

    func test_floatの負の値() {
        var made = Protowire()
        made.field(1, float: -2)
        XCTAssertEqual(hex(made), "0d000000c0")
    }

    // MARK: - packed

    func test_packedは1つの塊にまとめる() {
        var made = Protowire()
        made.packed(1, varints: [1, 300, 2])
        XCTAssertEqual(hex(made), "0a04" + "01" + "ac02" + "02")
    }

    func test_packedのfloat() {
        var made = Protowire()
        made.packed(1, floats: [1, -2])
        XCTAssertEqual(hex(made), "0a08" + "0000803f" + "000000c0")
    }

    /// **空の packed は書かない。** 長さ 0 の塊を置くと、
    /// 読み手によっては「空の要素が 1 つ」と解される。
    func test_空のpackedは書かない() {
        var made = Protowire()
        made.packed(1, varints: [])
        made.packed(2, floats: [])
        XCTAssertTrue(made.isEmpty)
    }

    // MARK: - 並び

    /// 書いた順に並ぶこと。**protobuf は順不同を許すが、
    /// 実物の束と見比べるときに順が違うと突き合わせにくい。**
    func test_書いた順に並ぶ() {
        var made = Protowire()
        made.field(3, varint: 1)
        made.field(1, varint: 2)
        XCTAssertEqual(hex(made), "18010802")
    }
}
