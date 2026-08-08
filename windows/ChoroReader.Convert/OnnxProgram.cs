using System.Text;

namespace ChoroReader.Convert;

/// <summary>値の型。仕様の <c>TensorProto.DataType</c> から写した。</summary>
public enum OnnxType
{
    Float = 1,
    Int64 = 7,
    Float16 = 10,
}

/// <summary>大きさ。動く軸は名前で置く。</summary>
public readonly record struct Extent(int Fixed, string? Name)
{
    public static Extent Of(int size) => new(size, null);

    /// <summary>長さが決まらない軸。同じ名前は同じ長さを指す。</summary>
    public static Extent Named(string label) => new(0, label);
}

/// <summary>演算に添える値。</summary>
public abstract record Attr(string Name)
{
    public sealed record Int(string Name, long Value) : Attr(Name);
    public sealed record Ints(string Name, IReadOnlyList<long> Values) : Attr(Name);
    public sealed record Float(string Name, float Value) : Attr(Name);
    public sealed record Text(string Name, string Value) : Attr(Name);
}

/// <summary>演算 1 つ。</summary>
public sealed record Op(string Type, IReadOnlyList<string> Inputs, IReadOnlyList<string> Outputs,
                        IReadOnlyList<Attr> Attributes);

/// <summary>重み。名前で参照される定数。</summary>
public sealed record Initializer(string Name, IReadOnlyList<int> Dims, OnnxType Type, byte[] Raw);

/// <summary>出入口 1 つ。</summary>
public sealed record Port(string Name, OnnxType Type, IReadOnlyList<Extent> Shape);

/// <summary>
/// ONNX のモデルを組み立てる。
///
/// <para>
/// <b>番号は仕様から写す。</b><c>onnx/onnx.proto3</c>（github.com/onnx/onnx）を見て写した。
/// 写し間違えれば ONNX Runtime が読めずにその場で落ちる。
/// </para>
/// <para>
/// Core ML より易しいところが 2 つある。長さが動くのでバケットが要らない。
/// 重みをモデルの中に置けるので、別のファイルを持たなくてよい。
/// </para>
/// </summary>
public sealed class OnnxProgram(string name, int opset = 17)
{
    private static class Model
    {
        public const int IrVersion = 1, ProducerName = 2, ProducerVersion = 3, Graph = 7, OpsetImport = 8;
    }

    private static class OperatorSet
    {
        public const int Domain = 1, Version = 2;
    }

    private static class GraphFields
    {
        public const int Node = 1, Name = 2, Initializer = 5, Input = 11, Output = 12;
    }

    private static class NodeFields
    {
        public const int Input = 1, Output = 2, Name = 3, OpType = 4, Attribute = 5;
    }

    private static class AttributeFields
    {
        public const int Name = 1, F = 2, I = 3, S = 4, Floats = 7, Ints = 8, Type = 20;
    }

    private static class TensorFields
    {
        public const int Dims = 1, DataType = 2, Name = 8, RawData = 9;
    }

    private static class ValueInfoFields
    {
        public const int Name = 1, Type = 2;
    }

    private static class TypeFields
    {
        public const int TensorType = 1;
    }

    private static class TensorTypeFields
    {
        public const int ElemType = 1, Shape = 2;
    }

    private static class ShapeFields
    {
        public const int Dim = 1;
    }

    private static class DimensionFields
    {
        public const int Value = 1, Param = 2;
    }

    /// <summary>属性の型。仕様の <c>AttributeProto.AttributeType</c> から写した。</summary>
    private enum AttributeType
    {
        Float = 1, Int = 2, String = 3, Floats = 6, Ints = 7,
    }

    public string Name { get; } = name;
    public int Opset { get; } = opset;
    public List<Port> Inputs { get; } = [];
    public List<Port> Outputs { get; } = [];
    public List<Initializer> Initializers { get; } = [];
    public List<Op> Ops { get; } = [];

    /// <summary>
    /// 読める形にする。
    ///
    /// <para>
    /// <b>IR の版は 8 に置く。</b>新しい版を名乗ると、少し古い ONNX Runtime が読まない。
    /// opset 17 に要るのは 8 までなので、名乗る理由が無い。
    /// </para>
    /// </summary>
    public byte[] Encode()
    {
        var model = new Protowire();
        model.Field(Model.IrVersion, 8ul);
        model.Field(Model.ProducerName, "choro-convert");
        model.Field(Model.ProducerVersion, "1");
        model.Field(Model.OpsetImport, Protowire.Message(set =>
        {
            // 既定の演算集合は domain を空文字で書く。省くと版が付かない。
            set.Field(OperatorSet.Domain, "");
            set.Field(OperatorSet.Version, Opset);
        }));
        model.Field(Model.Graph, Graph());
        return model.Bytes;
    }

    private Protowire Graph() => Protowire.Message(graph =>
    {
        graph.Field(GraphFields.Name, Name);
        foreach (var op in Ops)
        {
            graph.Field(GraphFields.Node, Node(op));
        }
        foreach (var weight in Initializers)
        {
            graph.Field(GraphFields.Initializer, Tensor(weight));
        }
        foreach (var port in Inputs)
        {
            graph.Field(GraphFields.Input, ValueInfo(port));
        }
        foreach (var port in Outputs)
        {
            graph.Field(GraphFields.Output, ValueInfo(port));
        }
    });

    private Protowire Node(Op op) => Protowire.Message(node =>
    {
        // **入と出は宣言した順に並べる。** ONNX は位置で意味が決まる。
        foreach (var input in op.Inputs)
        {
            node.Field(NodeFields.Input, input);
        }
        foreach (var output in op.Outputs)
        {
            node.Field(NodeFields.Output, output);
        }
        node.Field(NodeFields.Name, op.Outputs.Count > 0 ? op.Outputs[0] : op.Type);
        node.Field(NodeFields.OpType, op.Type);
        foreach (var attribute in op.Attributes)
        {
            node.Field(NodeFields.Attribute, Attribute(attribute));
        }
    });

    private static Protowire Attribute(Attr attribute) => Protowire.Message(made =>
    {
        made.Field(AttributeFields.Name, attribute.Name);
        switch (attribute)
        {
            case Attr.Int(_, var value):
                made.Field(AttributeFields.Type, (int)AttributeType.Int);
                made.Field(AttributeFields.I, (ulong)value);
                break;

            case Attr.Ints(_, var values):
                made.Field(AttributeFields.Type, (int)AttributeType.Ints);
                // packed で書く。ONNX は packed も繰り返しも受ける。
                var packed = new List<byte>();
                foreach (var one in values)
                {
                    Protowire.Put(packed, (ulong)one);
                }
                made.Field(AttributeFields.Ints, [.. packed]);
                break;

            case Attr.Float(_, var value):
                made.Field(AttributeFields.Type, (int)AttributeType.Float);
                made.Field(AttributeFields.F, value);
                break;

            case Attr.Text(_, var value):
                made.Field(AttributeFields.Type, (int)AttributeType.String);
                made.Field(AttributeFields.S, Encoding.UTF8.GetBytes(value));
                break;
        }
    });

    private static Protowire Tensor(Initializer weight) => Protowire.Message(made =>
    {
        foreach (var size in weight.Dims)
        {
            made.Field(TensorFields.Dims, size);
        }
        made.Field(TensorFields.DataType, (int)weight.Type);
        made.Field(TensorFields.Name, weight.Name);
        made.Field(TensorFields.RawData, weight.Raw);
    });

    private static Protowire ValueInfo(Port port) => Protowire.Message(made =>
    {
        made.Field(ValueInfoFields.Name, port.Name);
        made.Field(ValueInfoFields.Type, Protowire.Message(type =>
            type.Field(TypeFields.TensorType, Protowire.Message(tensor =>
            {
                tensor.Field(TensorTypeFields.ElemType, (int)port.Type);
                tensor.Field(TensorTypeFields.Shape, Protowire.Message(shape =>
                {
                    foreach (var extent in port.Shape)
                    {
                        shape.Field(ShapeFields.Dim, Protowire.Message(dim =>
                        {
                            if (extent.Name is { } label)
                            {
                                dim.Field(DimensionFields.Param, label);
                            }
                            else
                            {
                                dim.Field(DimensionFields.Value, extent.Fixed);
                            }
                        }));
                    }
                }));
            }))));
    });
}
