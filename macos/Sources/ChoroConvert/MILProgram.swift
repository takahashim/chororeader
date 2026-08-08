import Foundation

struct MILProgram {
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

    enum Payload {
        case floats([Float])
        case ints([Int32])
        case bools([Bool])
        case strings([String])
        case blob(offset: UInt64)
        case halves([Float])
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

    @discardableResult
    mutating func split(_ kind: String, outs: [Value],
                        inputs: [(String, Value)]) -> [Value] {
        for out in outs { names.insert(out.name) }
        operations.append(Self.operation(type: kind, inputs: inputs.map { ($0.0, [$0.1.name]) },
                                         outputs: outs,
                                         attributes: [("name", Self.stringValue(outs[0].name))]))
        return outs
    }

    func program(functionName: String, inputs: [Value], outputs: [Value]) -> Protowire {
        let block = Protowire.message { block in
            for value in outputs { block.field(2, string: value.name) }
            for operation in operations { block.field(3, message: operation) }
        }

        let function = Protowire.message { function in
            for value in inputs { function.field(1, message: Self.namedValueType(value)) }
            function.field(2, string: Self.opset)
            function.field(3, message: Self.mapEntry(key: Self.opset, value: block))
        }

        return Protowire.message { program in
            program.field(1, varint: 1)
            program.field(2, message: Self.mapEntry(key: functionName, value: function))
        }
    }

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

    static let opset = "CoreML8"

    private static func operation(type: String,
                                  inputs: [(String, [String])],
                                  outputs: [Value],
                                  attributes: [(String, Protowire)]) -> Protowire {
        Protowire.message { operation in
            operation.field(1, string: type)
            for input in inputs {
                let argument = Protowire.message { argument in
                    for name in input.1 {
                        argument.field(1, message: Protowire.message { binding in
                            binding.field(1, string: name)
                        })
                    }
                }
                operation.field(2, message: mapEntry(key: input.0, value: argument))
            }
            for value in outputs { operation.field(3, message: namedValueType(value)) }
            for attribute in attributes {
                operation.field(5, message: mapEntry(key: attribute.0, value: attribute.1))
            }
        }
    }

    private static func namedValueType(_ value: Value) -> Protowire {
        Protowire.message { named in
            named.field(1, string: value.name)
            named.field(2, message: valueType(value.type))
        }
    }

    private static func valueType(_ type: TensorType) -> Protowire {
        Protowire.message { wrapper in
            wrapper.field(1, message: Protowire.message { tensor in
                tensor.field(1, varint: type.dataType.rawValue)
                tensor.field(2, varint: UInt64(type.shape.count))
                for size in type.shape {
                    tensor.field(3, message: Protowire.message { dimension in
                        dimension.field(1, message: Protowire.message { constant in
                            constant.field(1, varint: UInt64(size))
                        })
                    })
                }
            })
        }
    }

    private static func value(_ type: TensorType, _ payload: Payload) -> Protowire {
        Protowire.message { value in
            value.field(2, message: valueType(type))
            switch payload {
            case let .blob(offset):
                value.field(5, message: Protowire.message { blob in
                    blob.field(1, string: "@model_path/weights/weight.bin")
                    blob.field(2, varint: offset)
                })
            default:
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
                tensor.field(1, message: Protowire.message { $0.packed(1, floats: values) })
            case let .halves(values):
                // **fp16 の即値は生のバイト列で置く。** floats に入れると
                // 「中身の数と型の数が違う」と言われて読めない（実際に踏んだ）。
                // TensorValue.bytes = 7 → RepeatedBytes.values = 1
                var raw = [UInt8]()
                raw.reserveCapacity(values.count * 2)
                for value in values {
                    let bits = Float16(value).bitPattern
                    raw.append(UInt8(bits & 0xff))
                    raw.append(UInt8(bits >> 8))
                }
                tensor.field(7, message: Protowire.message { $0.field(1, bytes: raw) })
            case let .ints(values):
                tensor.field(2, message: Protowire.message {
                    $0.packed(1, varints: values.map { UInt64(bitPattern: Int64($0)) })
                })
            case let .bools(values):
                tensor.field(3, message: Protowire.message {
                    $0.packed(1, varints: values.map { $0 ? 1 : 0 })
                })
            case let .strings(values):
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

    private static func mapEntry(key: String, value: Protowire) -> Protowire {
        Protowire.message { entry in
            entry.field(1, string: key)
            entry.field(2, message: value)
        }
    }
}
