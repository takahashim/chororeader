using System.Text.Json;

namespace ChoroReader.Convert;

/// <summary>変換できないことを伝える。理由は全部まとめて言う。</summary>
public sealed class ConvertException(string message) : Exception(message);

/// <summary>
/// <c>model.safetensors</c> を読む。
///
/// <code>
/// | 見出しの長さ 8B（little endian） | 見出し（JSON） | 中身 |
/// </code>
///
/// <para>
/// 見出しは名前ごとに <c>{"dtype": …, "shape": […], "data_offsets": [始, 終]}</c> を持ち、
/// 位置は<b>中身の先頭からの相対</b>である（見出しの長さと 8 を足した先が実体）。
/// </para>
/// <para>
/// <b>読むのは変換のときだけ</b>なので、速さより読み違えないことを優先する。
/// </para>
/// </summary>
public sealed class Safetensors : IDisposable
{
    /// <summary>1 つの重み。</summary>
    private sealed record Tensor(string Name, int[] Shape, string DataType, long Start, long End)
    {
        public int Count => Shape.Aggregate(1, (a, b) => a * b);
    }

    private readonly FileStream _file;
    private readonly long _body;
    private readonly Dictionary<string, Tensor> _tensors = new(StringComparer.Ordinal);

    public Safetensors(string path)
    {
        _file = File.OpenRead(path);
        if (_file.Length <= 8)
        {
            throw new ConvertException("重みを読めません：短すぎます");
        }

        var head = new byte[8];
        _file.ReadExactly(head);
        var length = BitConverter.ToInt64(head);
        if (length <= 0 || 8 + length > _file.Length)
        {
            throw new ConvertException("重みを読めません：見出しの長さが合いません");
        }
        _body = 8 + length;

        var json = new byte[length];
        _file.ReadExactly(json);

        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(json);
        }
        catch (JsonException)
        {
            throw new ConvertException("重みを読めません：見出しが JSON ではありません");
        }
        using (document)
        {
            foreach (var entry in document.RootElement.EnumerateObject())
            {
                // `__metadata__` は重みではない。
                if (entry.Name == "__metadata__" || entry.Value.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }
                if (!entry.Value.TryGetProperty("dtype", out var dtype)
                    || !entry.Value.TryGetProperty("shape", out var shape)
                    || !entry.Value.TryGetProperty("data_offsets", out var offsets)
                    || offsets.GetArrayLength() != 2)
                {
                    continue;
                }
                _tensors[entry.Name] = new Tensor(
                    entry.Name,
                    [.. shape.EnumerateArray().Select(one => one.GetInt32())],
                    dtype.GetString() ?? "",
                    offsets[0].GetInt64(),
                    offsets[1].GetInt64());
            }
        }

        if (_tensors.Count == 0)
        {
            throw new ConvertException("重みを読めません：重みが 1 つもありません");
        }
    }

    public IReadOnlyList<string> Names => [.. _tensors.Keys.Order(StringComparer.Ordinal)];

    public int[]? Shape(string name) => _tensors.TryGetValue(name, out var found) ? found.Shape : null;

    /// <summary>
    /// float へ広げて返す。<b>形は返さない</b>ので、呼ぶ側が知っている前提である。
    ///
    /// <para>
    /// bf16・fp16・fp32 を扱う。ModernBERT の checkpoint はこのいずれかで配られる。
    /// </para>
    /// </summary>
    public float[] Read(string name)
    {
        if (!_tensors.TryGetValue(name, out var tensor))
        {
            throw new ConvertException($"重みを読めません：{name} がありません");
        }
        var from = _body + tensor.Start;
        var to = _body + tensor.End;
        if (to > _file.Length || from > to)
        {
            throw new ConvertException($"重みを読めません：{name} の位置が範囲の外です");
        }

        var raw = new byte[to - from];
        _file.Seek(from, SeekOrigin.Begin);
        _file.ReadExactly(raw);

        var made = new float[tensor.Count];
        switch (tensor.DataType)
        {
            case "F32":
                Expect(raw.Length, tensor.Count * 4, name);
                Buffer.BlockCopy(raw, 0, made, 0, raw.Length);
                return made;

            case "F16":
                Expect(raw.Length, tensor.Count * 2, name);
                for (var at = 0; at < made.Length; at++)
                {
                    made[at] = (float)BitConverter.UInt16BitsToHalf(BitConverter.ToUInt16(raw, at * 2));
                }
                return made;

            case "BF16":
                // bf16 は fp32 の上位 16 ビットそのものである。下位を 0 で埋めれば戻る。
                Expect(raw.Length, tensor.Count * 2, name);
                for (var at = 0; at < made.Length; at++)
                {
                    made[at] = BitConverter.UInt32BitsToSingle(
                        (uint)BitConverter.ToUInt16(raw, at * 2) << 16);
                }
                return made;

            default:
                throw new ConvertException($"重みを読めません：{name} の型 {tensor.DataType} は扱いません");
        }
    }

    private static void Expect(int got, int wanted, string name)
    {
        if (got != wanted)
        {
            throw new ConvertException($"重みを読めません：{name} の大きさが形と合いません");
        }
    }

    public void Dispose() => _file.Dispose();
}
