import Foundation

/// ONNX のモデルを組み立てる。
///
/// Core ML の `.mlmodel` と同じく protobuf なので、書き手（`Protowire`）はそのまま使える。
/// 変わるのは番号と綴りだけである。
///
/// **番号は仕様から写す。** `onnx/onnx.proto3`（github.com/onnx/onnx）を見て写した。
/// MIL のときと同じ作法で、写し間違えれば ONNX Runtime が読めずにその場で落ちる。
///
/// **Core ML より易しいところが 2 つある。**
///
/// - 長さが動く。バケット（固定長を何本も束ねる）が要らない
/// - 重みはモデルの中に置ける。別の `weight.bin` を持たなくてよい
///
/// 逆に難しいのは、演算の綴りが Core ML と違うことだけである。
public struct ONNXProgram {
    /// protobuf の番号。仕様から写したもの。
    private enum Model {
        static let irVersion = 1, producerName = 2, producerVersion = 3
        static let graph = 7, opsetImport = 8
    }

    private enum OperatorSet {
        static let domain = 1, version = 2
    }

    private enum Graph {
        static let node = 1, name = 2, initializer = 5, input = 11, output = 12
    }

    private enum Node {
        static let input = 1, output = 2, name = 3, opType = 4, attribute = 5
    }

    private enum Attribute {
        static let name = 1, f = 2, i = 3, s = 4, t = 5, floats = 7, ints = 8, type = 20
    }

    private enum Tensor {
        static let dims = 1, dataType = 2, name = 8, rawData = 9
    }

    private enum ValueInfo {
        static let name = 1, type = 2
    }

    private enum TypeProto {
        static let tensorType = 1
    }

    private enum TensorTypeProto {
        static let elemType = 1, shape = 2
    }

    private enum Shape {
        static let dim = 1
    }

    private enum Dimension {
        static let value = 1, param = 2
    }

    /// 値の型。仕様の `TensorProto.DataType` から写した。
    public enum DataType: Int {
        case float = 1
        case int64 = 7
        case float16 = 10
    }

    /// 属性の型。仕様の `AttributeProto.AttributeType` から写した。
    private enum AttributeType: Int {
        case float = 1, int = 2, string = 3, tensor = 4
        case floats = 6, ints = 7
    }

    /// 大きさ。動く軸は名前で置く。
    public enum Extent {
        case fixed(Int)
        /// 長さが決まらない軸。同じ名前は同じ長さを指す。
        case named(String)
    }

    /// 演算 1 つ。
    public struct Op {
        public var type: String
        public var inputs: [String]
        public var outputs: [String]
        public var attributes: [Attr]

        public init(_ type: String, inputs: [String], outputs: [String], attributes: [Attr] = []) {
            self.type = type
            self.inputs = inputs
            self.outputs = outputs
            self.attributes = attributes
        }
    }

    /// 演算に添える値。
    public enum Attr {
        case int(String, Int)
        case ints(String, [Int])
        case float(String, Float)
        case floats(String, [Float])
        case string(String, String)
    }

    /// 重み。名前で参照される定数。
    public struct Initializer {
        public var name: String
        public var dims: [Int]
        public var type: DataType
        /// そのまま並べたバイト列（little endian）。
        public var raw: [UInt8]

        public init(name: String, dims: [Int], type: DataType, raw: [UInt8]) {
            self.name = name
            self.dims = dims
            self.type = type
            self.raw = raw
        }
    }

    /// 出入口 1 つ。
    public struct Port {
        public var name: String
        public var type: DataType
        public var shape: [Extent]

        public init(name: String, type: DataType, shape: [Extent]) {
            self.name = name
            self.type = type
            self.shape = shape
        }
    }

    public var name: String
    public var opset: Int
    public var inputs: [Port] = []
    public var outputs: [Port] = []
    public var initializers: [Initializer] = []
    public var ops: [Op] = []

    /// - Parameter opset: 既定は 17。ModernBERT が要る演算はすべてこの版に入っている。
    public init(name: String, opset: Int = 17) {
        self.name = name
        self.opset = opset
    }

    // MARK: - 組み立て

    /// 読める形にする。
    ///
    /// **IR の版は 8 に置く。** 新しい版を名乗ると、少し古い ONNX Runtime が読まない。
    /// opset 17 に要るのは 8 までなので、名乗る理由が無い。
    public func encoded() -> Data {
        var model = Protowire()
        model.field(Model.irVersion, varint: 8)
        model.field(Model.producerName, string: "choro-convert")
        model.field(Model.producerVersion, string: "1")
        model.field(Model.opsetImport, message: Protowire.message { set in
            // 既定の演算集合は domain を空文字で書く。省くと版が付かない。
            set.field(OperatorSet.domain, string: "")
            set.field(OperatorSet.version, varint: opset)
        })
        model.field(Model.graph, message: graph())
        return model.data
    }

    private func graph() -> Protowire {
        Protowire.message { graph in
            graph.field(Graph.name, string: name)
            for op in ops {
                graph.field(Graph.node, message: node(op))
            }
            for weight in initializers {
                graph.field(Graph.initializer, message: tensor(weight))
            }
            for port in inputs {
                graph.field(Graph.input, message: valueInfo(port))
            }
            for port in outputs {
                graph.field(Graph.output, message: valueInfo(port))
            }
        }
    }

    private func node(_ op: Op) -> Protowire {
        Protowire.message { node in
            // **入と出は宣言した順に並べる。** ONNX は位置で意味が決まる。
            for input in op.inputs {
                node.field(Node.input, string: input)
            }
            for output in op.outputs {
                node.field(Node.output, string: output)
            }
            node.field(Node.name, string: op.outputs.first ?? op.type)
            node.field(Node.opType, string: op.type)
            for attribute in op.attributes {
                node.field(Node.attribute, message: attr(attribute))
            }
        }
    }

    private func attr(_ attribute: Attr) -> Protowire {
        Protowire.message { out in
            switch attribute {
            case let .int(name, value):
                out.field(Attribute.name, string: name)
                out.field(Attribute.type, varint: AttributeType.int.rawValue)
                out.field(Attribute.i, varint: UInt64(bitPattern: Int64(value)))
            case let .ints(name, values):
                out.field(Attribute.name, string: name)
                out.field(Attribute.type, varint: AttributeType.ints.rawValue)
                // packed で書く。ONNX は packed も繰り返しも受ける。
                var packed = [UInt8]()
                for value in values {
                    Protowire.appendVarint(UInt64(bitPattern: Int64(value)), to: &packed)
                }
                out.field(Attribute.ints, bytes: packed)
            case let .float(name, value):
                out.field(Attribute.name, string: name)
                out.field(Attribute.type, varint: AttributeType.float.rawValue)
                out.field(Attribute.f, float: value)
            case let .floats(name, values):
                out.field(Attribute.name, string: name)
                out.field(Attribute.type, varint: AttributeType.floats.rawValue)
                var packed = [UInt8]()
                for value in values {
                    withUnsafeBytes(of: value.bitPattern.littleEndian) { packed.append(contentsOf: $0) }
                }
                out.field(Attribute.floats, bytes: packed)
            case let .string(name, value):
                out.field(Attribute.name, string: name)
                out.field(Attribute.type, varint: AttributeType.string.rawValue)
                out.field(Attribute.s, bytes: Array(value.utf8))
            }
        }
    }

    private func tensor(_ weight: Initializer) -> Protowire {
        Protowire.message { out in
            for size in weight.dims {
                out.field(Tensor.dims, varint: size)
            }
            out.field(Tensor.dataType, varint: weight.type.rawValue)
            out.field(Tensor.name, string: weight.name)
            out.field(Tensor.rawData, bytes: weight.raw)
        }
    }

    private func valueInfo(_ port: Port) -> Protowire {
        Protowire.message { out in
            out.field(ValueInfo.name, string: port.name)
            out.field(ValueInfo.type, message: Protowire.message { type in
                type.field(TypeProto.tensorType, message: Protowire.message { tensor in
                    tensor.field(TensorTypeProto.elemType, varint: port.type.rawValue)
                    tensor.field(TensorTypeProto.shape, message: Protowire.message { shape in
                        for extent in port.shape {
                            shape.field(Shape.dim, message: Protowire.message { dim in
                                switch extent {
                                case let .fixed(size):
                                    dim.field(Dimension.value, varint: size)
                                case let .named(label):
                                    dim.field(Dimension.param, string: label)
                                }
                            })
                        }
                    })
                })
            })
        }
    }
}
