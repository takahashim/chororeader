import XCTest
@testable import ChoroConvert

/// ONNX の組み立て。
///
/// **番号を写し間違えても、この検査だけでは気付けない。**
/// 組んだ bytes を自分で読み返しているだけだからである。
/// 本当の答え合わせは ONNX Runtime に読ませることで、
/// 出した見本（`/tmp/choro-onnx-sample.onnx`）を C# 側の検査が読む
/// （`windows/ChoroReader.Tests/OnnxProgramTests.cs`）。MIL で coremltools を治具にしたのと同じ形である。
final class ONNXProgramTests: XCTestCase {
    /// 検査側の読み手。**書き手の裏返しではなく、protobuf の仕様から組む。**
    private struct Reader {
        var bytes: [UInt8]
        var at = 0

        mutating func varint() -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while at < bytes.count {
                let byte = bytes[at]
                at += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { break }
                shift += 7
            }
            return value
        }

        mutating func key() -> (number: Int, wire: Int) {
            let raw = varint()
            return (Int(raw >> 3), Int(raw & 7))
        }

        mutating func bytesField() -> [UInt8] {
            let length = Int(varint())
            let slice = Array(bytes[at ..< at + length])
            at += length
            return slice
        }

        /// その番号の field を全部集める。
        static func collect(_ bytes: [UInt8], number: Int) -> [[UInt8]] {
            var reader = Reader(bytes: bytes)
            var made: [[UInt8]] = []
            while reader.at < bytes.count {
                let (found, wire) = reader.key()
                switch wire {
                case 0:
                    let value = reader.varint()
                    if found == number {
                        var packed = [UInt8]()
                        var rest = value
                        repeat {
                            packed.append(UInt8(rest & 0xff))
                            rest >>= 8
                        } while rest > 0
                        made.append(packed)
                    }
                case 2:
                    let value = reader.bytesField()
                    if found == number { made.append(value) }
                case 5:
                    if found == number { made.append(Array(bytes[reader.at ..< reader.at + 4])) }
                    reader.at += 4
                default:
                    XCTFail("知らない wire 形式 \(wire)")
                    return made
                }
            }
            return made
        }

        static func number(_ bytes: [UInt8], number: Int) -> UInt64? {
            var reader = Reader(bytes: bytes)
            while reader.at < bytes.count {
                let (found, wire) = reader.key()
                switch wire {
                case 0:
                    let value = reader.varint()
                    if found == number { return value }
                case 2:
                    _ = reader.bytesField()
                case 5:
                    reader.at += 4
                default:
                    return nil
                }
            }
            return nil
        }

        static func text(_ bytes: [UInt8], number: Int) -> String? {
            collect(bytes, number: number).first.map { String(decoding: $0, as: UTF8.self) }
        }
    }

    /// 足し算 1 つだけのモデル。組み立ての骨を通す。
    private func sample() -> ONNXProgram {
        var program = ONNXProgram(name: "sample")
        program.inputs = [.init(name: "x", type: .float, shape: [.named("batch"), .fixed(2)])]
        program.outputs = [.init(name: "y", type: .float, shape: [.named("batch"), .fixed(2)])]
        program.initializers = [
            .init(name: "bias", dims: [2], type: .float,
                  raw: [Float(1.5), Float(2.5)].flatMap { value in
                      withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) }
                  }),
        ]
        program.ops = [.init("Add", inputs: ["x", "bias"], outputs: ["y"])]
        return program
    }

    func test_モデルの頭を組む() throws {
        let bytes = [UInt8](sample().encoded())

        XCTAssertEqual(Reader.number(bytes, number: 1), 8, "IR の版")
        XCTAssertEqual(Reader.text(bytes, number: 2), "choro-convert")

        let opset = try XCTUnwrap(Reader.collect(bytes, number: 8).first)
        XCTAssertEqual(Reader.text(opset, number: 1), "", "既定の domain は空文字")
        XCTAssertEqual(Reader.number(opset, number: 2), 17)
    }

    func test_グラフに演算と重みと出入口が入る() throws {
        let bytes = [UInt8](sample().encoded())
        let graph = try XCTUnwrap(Reader.collect(bytes, number: 7).first)

        XCTAssertEqual(Reader.text(graph, number: 2), "sample")

        let node = try XCTUnwrap(Reader.collect(graph, number: 1).first)
        XCTAssertEqual(Reader.collect(node, number: 1).map { String(decoding: $0, as: UTF8.self) },
                       ["x", "bias"], "入は宣言した順に並ぶ")
        XCTAssertEqual(Reader.text(node, number: 2), "y")
        XCTAssertEqual(Reader.text(node, number: 4), "Add")

        let weight = try XCTUnwrap(Reader.collect(graph, number: 5).first)
        XCTAssertEqual(Reader.number(weight, number: 2), 1, "float")
        XCTAssertEqual(Reader.text(weight, number: 8), "bias")
        XCTAssertEqual(Reader.collect(weight, number: 9).first?.count, 8, "float 2 つぶん")

        XCTAssertEqual(Reader.collect(graph, number: 11).count, 1, "入口")
        XCTAssertEqual(Reader.collect(graph, number: 12).count, 1, "出口")
    }

    /// 動く軸は名前で置く。バケットが要らないのはこれのためである。
    func test_動く軸は名前で置く() throws {
        let bytes = [UInt8](sample().encoded())
        let graph = try XCTUnwrap(Reader.collect(bytes, number: 7).first)
        let port = try XCTUnwrap(Reader.collect(graph, number: 11).first)
        let type = try XCTUnwrap(Reader.collect(port, number: 2).first)
        let tensor = try XCTUnwrap(Reader.collect(type, number: 1).first)
        XCTAssertEqual(Reader.number(tensor, number: 1), 1, "float")

        let shape = try XCTUnwrap(Reader.collect(tensor, number: 2).first)
        let dims = Reader.collect(shape, number: 1)
        XCTAssertEqual(dims.count, 2)
        XCTAssertEqual(Reader.text(dims[0], number: 2), "batch", "1 つ目は名前で置く")
        XCTAssertEqual(Reader.number(dims[1], number: 1), 2, "2 つ目は決まった長さ")
    }

    /// 見本を書き出す。**答え合わせは ONNX Runtime に読ませて行う。**
    ///
    /// 環境変数を置いたときだけ書く。普段の検査で /tmp を汚さない。
    func test_見本を書き出す() throws {
        guard let where_ = ProcessInfo.processInfo.environment["CHORO_ONNX_SAMPLE"] else {
            throw XCTSkip("CHORO_ONNX_SAMPLE が無いので書き出さない")
        }
        try sample().encoded().write(to: URL(fileURLWithPath: where_))
    }
}
