import Foundation

/// MIL のプログラムを組み立てる。
///
/// **小さく作ってある。** 1 つの関数の 1 つのブロックに、型の付いた値と演算を
/// 並べられれば足りる。慣例は実物の束（`takahashim/ruri-v3-130m-coreml`）から
/// 読み取ったもので、当て推量ではない（kohagi の `mil.rs` から移した）。
/// schema からは読み取れない決まりごとは次の 5 つ。
///
/// - `Program.version` は 1。モデル側の `specificationVersion` は 9（macOS 15 向け）
/// - opset は文字列 `"CoreML8"`。関数が唯一のブロックを収める鍵でもある
///   （`.mlmodelc` の中の文字で書かれた MIL は同じものを `ios18` と表す）
/// - 関数は入力を宣言し、**ブロックは出力だけ**を宣言する
/// - どの演算も `name` 属性に文字列テンソルを持つ。`const` は中身を `val` 属性に持ち、
///   即値か、`weights/weight.bin` の**目録の位置**への参照のどちらかである
/// - **形の推論はしない。** すべての値の型は作るところで書く。入力と食い違う演算は
///   呼ぶ側の誤りであり、Core ML が組み立てのときにそう言う（間違った数を出すのではなく）
///
/// field の番号は kohagi の `proto/MIL.proto`（coremltools からそのまま持ってきたもの）
/// から写した。写し間違えると Core ML が読めずにその場で落ちる。
struct MILProgram {
    /// `MIL.proto` の `DataType`。使うものだけ。
    enum DataType: UInt64 {
        case bool = 1
        case string = 2
        case fp16 = 10
        case fp32 = 11
        case int32 = 23
    }

    /// 値の型（テンソル）。**形の推論をしないので、これを必ず書く。**
    struct TensorType: Equatable {
        var dataType: DataType
        var shape: [Int]

        init(_ dataType: DataType, _ shape: [Int]) {
            self.dataType = dataType
            self.shape = shape
        }

        var count: Int { shape.reduce(1, *) }
    }

    /// ブロックの中の 1 つの値。名前と型を持つ。
    struct Value: Equatable {
        var name: String
        var type: TensorType
    }

    /// 演算の中身（`val` 属性）。即値か、blob への参照。
    enum Payload {
        case floats([Float])
        case ints([Int32])
        case bools([Bool])
        case strings([String])
        /// `weights/weight.bin` の目録の位置。
        case blob(offset: UInt64)
    }

    // MARK: - 組み立て

    private var operations: [Protowire] = []
    private var names = Set<String>()
    private var counter = 0

    init() {}

    /// 名前を 1 つ作る。同じ名前を 2 度使わない。
    ///
    /// **名前がぶつかると、後から置いた方が前を隠す。** 数は返るが違うグラフになる。
    mutating func fresh(_ hint: String) -> String {
        counter += 1
        var made = "\(hint)_\(counter)"
        while names.contains(made) {
            counter += 1
            made = "\(hint)_\(counter)"
        }
        names.insert(made)
        return made
    }

    /// 定数を置く。
    ///
    /// 中身が大きいものは blob（`weight.bin`）へ、小さいものは即値へ置く。
    /// どちらでも `const` の形は同じである。
    mutating func constant(_ name: String, _ type: TensorType, _ payload: Payload) -> Value {
        let out = Value(name: name, type: type)
        names.insert(name)
        operations.append(Self.operation(type: "const", inputs: [], outputs: [out],
                                         attributes: [("name", Self.stringValue(name)),
                                                      ("val", Self.value(type, payload))]))
        return out
    }

    /// 演算を置く。出力は 1 つ。
    ///
    /// 入力の名前（`x`・`y`・`axis` など）は MIL の演算ごとに決まっている。
    /// 間違えると Core ML が組み立てで落ちる。
    @discardableResult
    mutating func op(_ kind: String, out: Value, inputs: [(String, Value)]) -> Value {
        names.insert(out.name)
        operations.append(Self.operation(type: kind, inputs: inputs.map { ($0.0, [$0.1.name]) },
                                         outputs: [out],
                                         attributes: [("name", Self.stringValue(out.name))]))
        return out
    }

    /// 入力の 1 つが値の並びを取る演算（`concat` の `values` など）。
    @discardableResult
    mutating func op(_ kind: String, out: Value,
                     inputs: [(String, Value)], variadic: (String, [Value])) -> Value {
        names.insert(out.name)
        var bound = inputs.map { ($0.0, [$0.1.name]) }
        bound.append((variadic.0, variadic.1.map(\.name)))
        operations.append(Self.operation(type: kind, inputs: bound, outputs: [out],
                                         attributes: [("name", Self.stringValue(out.name))]))
        return out
    }

    /// 組み上げた `Program`。
    ///
    /// - Parameters:
    ///   - inputs: 関数の入力。**関数が宣言する**
    ///   - outputs: ブロックの出力。**ブロックが宣言する**
    func program(functionName: String, inputs: [Value], outputs: [Value]) -> Protowire {
        let block = Protowire.message { block in
            // Block.outputs = 2（文字列の並び）。入力はブロックでは宣言しない。
            for value in outputs { block.field(2, string: value.name) }
            // Block.operations = 3
            for operation in operations { block.field(3, message: operation) }
        }

        let function = Protowire.message { function in
            // Function.inputs = 1
            for value in inputs { function.field(1, message: Self.namedValueType(value)) }
            // Function.opset = 2
            function.field(2, string: Self.opset)
            // Function.block_specializations = 3（map<string, Block>）
            function.field(3, message: Self.mapEntry(key: Self.opset, value: block))
        }

        return Protowire.message { program in
            // Program.version = 1
            program.field(1, varint: 1)
            // Program.functions = 2（map<string, Function>）
            program.field(2, message: Self.mapEntry(key: functionName, value: function))
        }
    }

    /// 複数の関数を 1 つのプログラムに収める（multi-function の束）。
    static func program(functions: [(name: String, function: Protowire)]) -> Protowire {
        Protowire.message { program in
            program.field(1, varint: 1)
            for one in functions {
                program.field(2, message: mapEntry(key: one.name, value: one.function))
            }
        }
    }

    /// 1 つの関数だけを組む（束に入れるため）。
    func function(inputs: [Value], outputs: [Value]) -> Protowire {
        let block = Protowire.message { block in
            for value in outputs { block.field(2, string: value.name) }
            for operation in operations { block.field(3, message: operation) }
        }
        return Protowire.message { function in
            for value in inputs { function.field(1, message: Self.namedValueType(value)) }
            function.field(2, string: Self.opset)
            function.field(3, message: Self.mapEntry(key: Self.opset, value: block))
        }
    }

    // MARK: - 形

    /// 演算の opset。**関数が唯一のブロックを収める鍵でもある。**
    static let opset = "CoreML8"

    private static func operation(type: String,
                                  inputs: [(String, [String])],
                                  outputs: [Value],
                                  attributes: [(String, Protowire)]) -> Protowire {
        Protowire.message { operation in
            // Operation.type = 1
            operation.field(1, string: type)
            // Operation.inputs = 2（map<string, Argument>）
            for input in inputs {
                let argument = Protowire.message { argument in
                    // Argument.arguments = 1（Binding の並び）
                    for name in input.1 {
                        argument.field(1, message: Protowire.message { binding in
                            // Binding.name = 1
                            binding.field(1, string: name)
                        })
                    }
                }
                operation.field(2, message: mapEntry(key: input.0, value: argument))
            }
            // Operation.outputs = 3
            for value in outputs { operation.field(3, message: namedValueType(value)) }
            // Operation.attributes = 5（map<string, Value>）
            for attribute in attributes {
                operation.field(5, message: mapEntry(key: attribute.0, value: attribute.1))
            }
        }
    }

    private static func namedValueType(_ value: Value) -> Protowire {
        Protowire.message { named in
            // NamedValueType.name = 1、type = 2
            named.field(1, string: value.name)
            named.field(2, message: valueType(value.type))
        }
    }

    private static func valueType(_ type: TensorType) -> Protowire {
        Protowire.message { wrapper in
            // ValueType.tensorType = 1
            wrapper.field(1, message: Protowire.message { tensor in
                // TensorType.dataType = 1、rank = 2、dimensions = 3
                tensor.field(1, varint: type.dataType.rawValue)
                tensor.field(2, varint: UInt64(type.shape.count))
                for size in type.shape {
                    tensor.field(3, message: Protowire.message { dimension in
                        // Dimension.constant = 1 → ConstantDimension.size = 1
                        dimension.field(1, message: Protowire.message { constant in
                            constant.field(1, varint: UInt64(size))
                        })
                    })
                }
            })
        }
    }

    /// `Value`（中身を持つ側）。即値か blob への参照。
    private static func value(_ type: TensorType, _ payload: Payload) -> Protowire {
        Protowire.message { value in
            // Value.type = 2
            value.field(2, message: valueType(type))
            switch payload {
            case let .blob(offset):
                // Value.blobFileValue = 5
                value.field(5, message: Protowire.message { blob in
                    // BlobFileValue.fileName = 1、offset = 2
                    blob.field(1, string: "@model_path/weights/weight.bin")
                    blob.field(2, varint: offset)
                })
            default:
                // Value.immediateValue = 3 → ImmediateValue.tensor = 1
                value.field(3, message: Protowire.message { immediate in
                    immediate.field(1, message: tensorValue(payload))
                })
            }
        }
    }

    private static func tensorValue(_ payload: Payload) -> Protowire {
        Protowire.message { tensor in
            switch payload {
            case let .floats(values):
                // TensorValue.floats = 1 → RepeatedFloats.values = 1（packed）
                tensor.field(1, message: Protowire.message { $0.packed(1, floats: values) })
            case let .ints(values):
                // TensorValue.ints = 2 → RepeatedInts.values = 1（packed）
                tensor.field(2, message: Protowire.message {
                    $0.packed(1, varints: values.map { UInt64(bitPattern: Int64($0)) })
                })
            case let .bools(values):
                // TensorValue.bools = 3
                tensor.field(3, message: Protowire.message {
                    $0.packed(1, varints: values.map { $0 ? 1 : 0 })
                })
            case let .strings(values):
                // TensorValue.strings = 4 → RepeatedStrings.values = 1
                tensor.field(4, message: Protowire.message { repeated in
                    for value in values { repeated.field(1, string: value) }
                })
            case .blob:
                break   // ここへは来ない（value 側で分かれている）
            }
        }
    }

    private static func stringValue(_ text: String) -> Protowire {
        value(TensorType(.string, []), .strings([text]))
    }

    /// protobuf の map は「key=1、value=2 を持つ入れ子」の並びとして符号化される。
    private static func mapEntry(key: String, value: Protowire) -> Protowire {
        Protowire.message { entry in
            entry.field(1, string: key)
            entry.field(2, message: value)
        }
    }
}
