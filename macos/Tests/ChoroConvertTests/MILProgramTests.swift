import XCTest
@testable import ChoroConvert

/// MIL プログラムの組み立て。
///
/// **番号を写し間違えても、ここでは落ちない。** 落ちるのは Core ML が読むときで、
/// そのとき出るのは「読めません」だけである。どの field がずれたのかは言ってくれない。
///
/// だから 2 段で見る。
///
/// 1. ここ：組み上げた bytes を、独立に組んだ読み手でほどく（下記）
/// 2. 実物：coremltools（Python）でほどいて構造を確かめる治具を 1 度だけ通す。
///    その結果はこの検査の期待値として写してある
///
/// 検査側の読み手は**書き手の裏返しではない**。protobuf の仕様
/// （見出し = 番号 << 3 | 種別、length-delimited は長さが前）から独立に組んである。
final class MILProgramTests: XCTestCase {
    // MARK: - 検査側の読み手

    /// ほどいた field。番号と中身だけを持つ。
    private struct Field {
        var number: Int
        var wire: Int
        var payload: [UInt8]
        var varint: UInt64
    }

    private func parse(_ bytes: [UInt8]) -> [Field] {
        var made: [Field] = []
        var at = 0
        func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while at < bytes.count {
                let byte = bytes[at]
                at += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while at < bytes.count {
            guard let key = varint() else { break }
            let number = Int(key >> 3)
            let wire = Int(key & 7)
            switch wire {
            case 0:
                guard let value = varint() else { return made }
                made.append(Field(number: number, wire: wire, payload: [], varint: value))
            case 2:
                guard let length = varint(), at + Int(length) <= bytes.count else { return made }
                made.append(Field(number: number, wire: wire,
                                  payload: Array(bytes[at ..< at + Int(length)]), varint: 0))
                at += Int(length)
            case 5:
                guard at + 4 <= bytes.count else { return made }
                made.append(Field(number: number, wire: wire,
                                  payload: Array(bytes[at ..< at + 4]), varint: 0))
                at += 4
            default:
                return made
            }
        }
        return made
    }

    private func first(_ fields: [Field], _ number: Int) -> Field? {
        fields.first { $0.number == number }
    }

    private func all(_ fields: [Field], _ number: Int) -> [Field] {
        fields.filter { $0.number == number }
    }

    private func text(_ field: Field?) -> String? {
        field.map { String(decoding: $0.payload, as: UTF8.self) }
    }

    // MARK: - 期待値の土台

    private func sample() -> (program: Protowire, x: MILProgram.Value, y: MILProgram.Value) {
        var mil = MILProgram()
        let x = MILProgram.Value(name: "x", type: .init(.fp16, [1, 4]))
        let weight = mil.constant("w", .init(.fp16, [4, 4]), .blob(offset: 128))
        let bias = mil.constant("b", .init(.fp16, [4]), .floats([0, 0, 0, 0]))
        let y = MILProgram.Value(name: "y", type: .init(.fp16, [1, 4]))
        mil.op("linear", out: y, inputs: [("x", x), ("weight", weight), ("bias", bias)])
        return (mil.program(functionName: "main", inputs: [x], outputs: [y]), x, y)
    }

    // MARK: - 慣例

    /// 実物の束から読み取った決まりごと。**schema からは分からない。**
    func test_版と関数とopset() throws {
        let program = parse(sample().program.bytes)

        // Program.version = 1、値は 1
        XCTAssertEqual(first(program, 1)?.varint, 1, "Program.version が 1 でない")

        // Program.functions = 2（map）。key=1・value=2 の入れ子
        let entry = parse(try XCTUnwrap(first(program, 2)).payload)
        XCTAssertEqual(text(first(entry, 1)), "main")

        let function = parse(try XCTUnwrap(first(entry, 2)).payload)
        // Function.opset = 2
        XCTAssertEqual(text(first(function, 2)), "CoreML8", "opset が CoreML8 でない")

        // Function.block_specializations = 3。**鍵も opset である**
        let specialization = parse(try XCTUnwrap(first(function, 3)).payload)
        XCTAssertEqual(text(first(specialization, 1)), "CoreML8",
                       "ブロックを収める鍵が opset と違う")
    }

    /// **関数は入力を宣言し、ブロックは出力だけを宣言する。**
    func test_入力は関数がブロックは出力だけ() throws {
        let program = parse(sample().program.bytes)
        let entry = parse(try XCTUnwrap(first(program, 2)).payload)
        let function = parse(try XCTUnwrap(first(entry, 2)).payload)

        // Function.inputs = 1
        let inputs = all(function, 1)
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(text(first(parse(inputs[0].payload), 1)), "x")

        let specialization = parse(try XCTUnwrap(first(function, 3)).payload)
        let block = parse(try XCTUnwrap(first(specialization, 2)).payload)
        // Block.inputs = 1 は空、Block.outputs = 2 に名前
        XCTAssertTrue(all(block, 1).isEmpty, "ブロックが入力を宣言している")
        XCTAssertEqual(all(block, 2).compactMap { text($0) }, ["y"])
    }

    /// どの演算も `name` 属性を持つこと。
    func test_どの演算もname属性を持つ() throws {
        let program = parse(sample().program.bytes)
        let entry = parse(try XCTUnwrap(first(program, 2)).payload)
        let function = parse(try XCTUnwrap(first(entry, 2)).payload)
        let specialization = parse(try XCTUnwrap(first(function, 3)).payload)
        let block = parse(try XCTUnwrap(first(specialization, 2)).payload)

        // Block.operations = 3
        let operations = all(block, 3)
        XCTAssertEqual(operations.count, 3, "const 2 つと linear 1 つ")
        for operation in operations {
            let fields = parse(operation.payload)
            // Operation.attributes = 5（map）。name があること
            let keys = all(fields, 5).compactMap { text(first(parse($0.payload), 1)) }
            XCTAssertTrue(keys.contains("name"), "name 属性が無い演算がある")
        }
    }

    /// 演算の型と、入力の結び付き。
    func test_演算の型と入力() throws {
        let program = parse(sample().program.bytes)
        let entry = parse(try XCTUnwrap(first(program, 2)).payload)
        let function = parse(try XCTUnwrap(first(entry, 2)).payload)
        let specialization = parse(try XCTUnwrap(first(function, 3)).payload)
        let block = parse(try XCTUnwrap(first(specialization, 2)).payload)
        let operations = all(block, 3).map { parse($0.payload) }

        XCTAssertEqual(operations.compactMap { text(first($0, 1)) }, ["const", "const", "linear"])

        // linear の入力：Operation.inputs = 2（map）。値は Argument で、
        // Argument.arguments = 1 → Binding.name = 1
        let linear = operations[2]
        var bound: [String: String] = [:]
        for input in all(linear, 2) {
            let pair = parse(input.payload)
            let key = try XCTUnwrap(text(first(pair, 1)))
            let argument = parse(try XCTUnwrap(first(pair, 2)).payload)
            let binding = parse(try XCTUnwrap(first(argument, 1)).payload)
            bound[key] = text(first(binding, 1))
        }
        XCTAssertEqual(bound, ["x": "x", "weight": "w", "bias": "b"])
    }

    /// `const` の中身。**大きいものは blob、小さいものは即値。**
    func test_constの中身は即値かblob() throws {
        let program = parse(sample().program.bytes)
        let entry = parse(try XCTUnwrap(first(program, 2)).payload)
        let function = parse(try XCTUnwrap(first(entry, 2)).payload)
        let specialization = parse(try XCTUnwrap(first(function, 3)).payload)
        let block = parse(try XCTUnwrap(first(specialization, 2)).payload)
        let operations = all(block, 3).map { parse($0.payload) }

        func attribute(_ fields: [Field], _ name: String) throws -> [Field] {
            for entry in all(fields, 5) {
                let pair = parse(entry.payload)
                if text(first(pair, 1)) == name {
                    return parse(try XCTUnwrap(first(pair, 2)).payload)
                }
            }
            XCTFail("\(name) 属性が無い")
            return []
        }

        // 1 つめは blob 参照：Value.blobFileValue = 5
        let blobValue = try attribute(operations[0], "val")
        let blob = parse(try XCTUnwrap(first(blobValue, 5)).payload)
        XCTAssertEqual(text(first(blob, 1)), "@model_path/weights/weight.bin")
        XCTAssertEqual(first(blob, 2)?.varint, 128, "**目録の位置**を指す")

        // 2 つめは即値：Value.immediateValue = 3 → ImmediateValue.tensor = 1
        //             → TensorValue.floats = 1 → RepeatedFloats.values = 1（packed）
        let immediateValue = try attribute(operations[1], "val")
        let immediate = parse(try XCTUnwrap(first(immediateValue, 3)).payload)
        let tensor = parse(try XCTUnwrap(first(immediate, 1)).payload)
        let floats = parse(try XCTUnwrap(first(tensor, 1)).payload)
        XCTAssertEqual(try XCTUnwrap(first(floats, 1)).payload.count, 16, "float 4 個ぶん")
    }

    /// 型は必ず書かれること。**形の推論をしない方針の受け皿。**
    func test_すべての値に型が付く() throws {
        let program = parse(sample().program.bytes)
        let entry = parse(try XCTUnwrap(first(program, 2)).payload)
        let function = parse(try XCTUnwrap(first(entry, 2)).payload)
        let specialization = parse(try XCTUnwrap(first(function, 3)).payload)
        let block = parse(try XCTUnwrap(first(specialization, 2)).payload)

        for operation in all(block, 3) {
            // Operation.outputs = 3 → NamedValueType.type = 2 → ValueType.tensorType = 1
            for output in all(parse(operation.payload), 3) {
                let named = parse(output.payload)
                let type = parse(try XCTUnwrap(first(named, 2)).payload)
                let tensor = parse(try XCTUnwrap(first(type, 1)).payload)
                XCTAssertEqual(first(tensor, 1)?.varint, 10, "fp16 は 10")
                let rank = try XCTUnwrap(first(tensor, 2)?.varint)
                XCTAssertEqual(all(tensor, 3).count, Int(rank), "rank と次元の数が食い違う")
            }
        }
    }

    // MARK: - 名前

    /// 名前がぶつからないこと。
    ///
    /// **ぶつかると、後から置いた方が前を隠す。** 数は返るが違うグラフになる。
    func test_名前は重ならない() {
        var mil = MILProgram()
        var made: [String] = []
        for _ in 0 ..< 200 { made.append(mil.fresh("t")) }
        XCTAssertEqual(Set(made).count, made.count)
    }

    func test_既に使った名前は避ける() {
        var mil = MILProgram()
        _ = mil.constant("t_1", .init(.fp16, [1]), .floats([0]))
        let next = mil.fresh("t")
        XCTAssertNotEqual(next, "t_1", "置いた名前とぶつかっている")
    }

    // MARK: - 束

    /// 複数の関数を 1 つのプログラムに収められること（multi-function）。
    func test_複数の関数を収める() throws {
        var first64 = MILProgram()
        let x64 = MILProgram.Value(name: "x", type: .init(.fp16, [1, 64]))
        first64.op("identity", out: MILProgram.Value(name: "y", type: .init(.fp16, [1, 64])),
                   inputs: [("x", x64)])

        var second = MILProgram()
        let x128 = MILProgram.Value(name: "x", type: .init(.fp16, [1, 128]))
        second.op("identity", out: MILProgram.Value(name: "y", type: .init(.fp16, [1, 128])),
                  inputs: [("x", x128)])

        let program = MILProgram.program(functions: [
            ("seq_64", first64.function(inputs: [x64],
                                        outputs: [.init(name: "y", type: .init(.fp16, [1, 64]))])),
            ("seq_128", second.function(inputs: [x128],
                                        outputs: [.init(name: "y", type: .init(.fp16, [1, 128]))])),
        ])

        let fields = parse(program.bytes)
        let names = all(fields, 2).compactMap { text(self.first(parse($0.payload), 1)) }
        XCTAssertEqual(names, ["seq_64", "seq_128"])
    }
}
