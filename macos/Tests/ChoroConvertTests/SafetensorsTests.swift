import XCTest
@testable import ChoroConvert

/// `model.safetensors` の読み手。
///
/// **読み違えても例外は出ない。** 位置を 1 つずらしても数は返り、
/// 変換は通り、ただ違うベクトルが出るだけである。だから
/// 「書いたものが読める」ではなく、**形式の記述どおりに組んだファイル**で確かめる。
final class SafetensorsTests: XCTestCase {
    /// 形式の記述から独立に組む（読み手の裏返しではない）。
    ///
    /// ```text
    /// | 見出しの長さ 8B | 見出し（JSON） | 中身 |
    /// ```
    private func write(_ entries: [(name: String, shape: [Int], dtype: String, bytes: [UInt8])]) throws -> URL {
        var header: [String: Any] = [:]
        var body: [UInt8] = []
        for entry in entries {
            header[entry.name] = ["dtype": entry.dtype, "shape": entry.shape,
                                  "data_offsets": [body.count, body.count + entry.bytes.count]]
            body.append(contentsOf: entry.bytes)
        }
        let json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        var out = [UInt8]()
        for shift in stride(from: 0, to: 64, by: 8) {
            out.append(UInt8((UInt64(json.count) >> UInt64(shift)) & 0xff))
        }
        out.append(contentsOf: [UInt8](json))
        out.append(contentsOf: body)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("choro-st-\(UUID().uuidString).safetensors")
        try Data(out).write(to: url)
        return url
    }

    private func fp32Bytes(_ values: [Float]) -> [UInt8] {
        var out: [UInt8] = []
        for value in values {
            for shift in stride(from: 0, to: 32, by: 8) {
                out.append(UInt8((value.bitPattern >> UInt32(shift)) & 0xff))
            }
        }
        return out
    }

    func test_fp32を読む() throws {
        let url = try write([(name: "a.weight", shape: [2, 2], dtype: "F32",
                              bytes: fp32Bytes([1, -2, 0.5, 1000]))])
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try Safetensors(contentsOf: url)
        XCTAssertEqual(file.names, ["a.weight"])
        XCTAssertEqual(file.shape(of: "a.weight"), [2, 2])
        XCTAssertEqual(try file.read("a.weight"), [1, -2, 0.5, 1000])
    }

    /// **2 つ目以降の位置がずれないこと。** ここがずれると、
    /// 別の層の重みを読んだまま変換が通ってしまう。
    func test_複数の重みが混ざらない() throws {
        let url = try write([
            (name: "first", shape: [3], dtype: "F32", bytes: fp32Bytes([1, 2, 3])),
            (name: "second", shape: [2], dtype: "F32", bytes: fp32Bytes([10, 20])),
            (name: "third", shape: [1], dtype: "F32", bytes: fp32Bytes([99])),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try Safetensors(contentsOf: url)
        XCTAssertEqual(try file.read("first"), [1, 2, 3])
        XCTAssertEqual(try file.read("second"), [10, 20])
        XCTAssertEqual(try file.read("third"), [99])
    }

    func test_fp16を読む() throws {
        // 1.0 = 0x3c00、-2.0 = 0xc000
        let url = try write([(name: "h", shape: [2], dtype: "F16", bytes: [0x00, 0x3c, 0x00, 0xc0])])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try Safetensors(contentsOf: url).read("h"), [1, -2])
    }

    /// bf16 は fp32 の上位 16 ビットそのもの。**下位を 0 で埋めれば戻る。**
    func test_bf16を読む() throws {
        // 1.0 の fp32 は 0x3f800000 → 上位は 0x3f80
        // -2.0 は 0xc0000000 → 上位は 0xc000
        let url = try write([(name: "b", shape: [2], dtype: "BF16", bytes: [0x80, 0x3f, 0x00, 0xc0])])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try Safetensors(contentsOf: url).read("b"), [1, -2])
    }

    /// 形と中身の大きさが食い違うものは受け取らない。
    /// **受け取ると、足りない分を 0 で埋めたまま変換が通る。**
    func test_大きさが合わなければ落とす() throws {
        let url = try write([(name: "a", shape: [4], dtype: "F32", bytes: fp32Bytes([1, 2]))])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try Safetensors(contentsOf: url).read("a"))
    }

    func test_知らない型は受け取らない() throws {
        let url = try write([(name: "a", shape: [1], dtype: "I64", bytes: [0, 0, 0, 0, 0, 0, 0, 0])])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try Safetensors(contentsOf: url).read("a"))
    }

    func test_無い名前は落とす() throws {
        let url = try write([(name: "a", shape: [1], dtype: "F32", bytes: fp32Bytes([1]))])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try Safetensors(contentsOf: url).read("b"))
    }

    /// `__metadata__` は重みではない。**混ぜると、使わなかった重みの数え方が狂う。**
    func test_metadataは重みに数えない() throws {
        var header: [String: Any] = [
            "__metadata__": ["format": "pt"],
            "a": ["dtype": "F32", "shape": [1], "data_offsets": [0, 4]],
        ]
        let json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        var out = [UInt8]()
        for shift in stride(from: 0, to: 64, by: 8) {
            out.append(UInt8((UInt64(json.count) >> UInt64(shift)) & 0xff))
        }
        out.append(contentsOf: [UInt8](json))
        out.append(contentsOf: fp32Bytes([7]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("choro-st-\(UUID().uuidString).safetensors")
        try Data(out).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        header = [:]

        let file = try Safetensors(contentsOf: url)
        XCTAssertEqual(file.names, ["a"], "__metadata__ を重みに数えている")
        XCTAssertEqual(try file.read("a"), [7])
    }

    func test_壊れたものは開かない() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("choro-st-\(UUID().uuidString).safetensors")
        try Data([1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try Safetensors(contentsOf: url))
    }
}
