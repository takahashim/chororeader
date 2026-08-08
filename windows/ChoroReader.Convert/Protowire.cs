using System.Text;

namespace ChoroReader.Convert;

/// <summary>
/// protobuf の符号化。<b>書く一方で、読む側は作らない。</b>
///
/// <para>
/// ONNX のモデルは protobuf である。変換器はそれを組み立てるだけなので、
/// 必要なのは符号化の 3 つの形しかない。依存を足さずに済む量である。
/// </para>
/// <list type="table">
/// <item><term>varint</term><description>field の見出し、整数、真偽、列挙</description></item>
/// <item><term>length-delimited</term><description>文字列、bytes、入れ子、packed の配列</description></item>
/// <item><term>32 ビット固定長</term><description>float</description></item>
/// </list>
/// <para>
/// <b>番号を写し間違えても黙って通らない。</b>ONNX Runtime が読めずにその場で落ちる。
/// 番号は <c>onnx/onnx.proto3</c>（github.com/onnx/onnx）から写す。
/// </para>
/// </summary>
public sealed class Protowire
{
    private readonly List<byte> _bytes = [];

    public byte[] Bytes => [.. _bytes];

    public int Length => _bytes.Count;

    /// <summary>入れ子のメッセージを 1 つ組む。</summary>
    public static Protowire Message(Action<Protowire> build)
    {
        var made = new Protowire();
        build(made);
        return made;
    }

    // MARK: field を書く

    /// <summary>整数・真偽・列挙。</summary>
    public void Field(int number, ulong varint)
    {
        Key(number, wire: 0);
        Put(_bytes, varint);
    }

    public void Field(int number, int varint) => Field(number, (ulong)varint);

    /// <summary>文字列。</summary>
    public void Field(int number, string value) => Field(number, Encoding.UTF8.GetBytes(value));

    /// <summary>bytes・入れ子のメッセージ・packed の配列。</summary>
    public void Field(int number, byte[] value)
    {
        Key(number, wire: 2);
        Put(_bytes, (ulong)value.Length);
        _bytes.AddRange(value);
    }

    public void Field(int number, Protowire message) => Field(number, message.Bytes);

    /// <summary>float。<b>32 ビット固定長で書く</b>（varint ではない）。</summary>
    public void Field(int number, float value)
    {
        Key(number, wire: 5);
        _bytes.AddRange(BitConverter.GetBytes(value));
    }

    private void Key(int number, int wire) => Put(_bytes, (ulong)((number << 3) | wire));

    /// <summary>可変長整数。7 ビットずつ、続きがあれば最上位を立てる。</summary>
    public static void Put(List<byte> output, ulong value)
    {
        while (true)
        {
            var lower = (byte)(value & 0x7f);
            value >>= 7;
            if (value == 0)
            {
                output.Add(lower);
                return;
            }
            output.Add((byte)(lower | 0x80));
        }
    }
}
