using ChoroReader.Core;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

namespace ChoroReader.Semantic;

/// <summary>
/// 本物の埋め込み器。ONNX Runtime で Ruri v3 を回す。
///
/// <para>
/// <b>アプリはモデルの出どころを知らない。</b>決まった場所を見るだけにしておく
/// （spec-local-ai.md 4.6）。配り方が決まったら、そこへ書く手順が足されるだけで使う側は変わらない。
/// </para>
/// <para>
/// <b>グラフに入っているのは pooling までである。</b>出口 <c>sentence_embedding</c> は
/// マスク付きの平均まで済んでいるが、元モデルは Transformer → Pooling の 2 段で
/// Normalize の段を持たない。<b>L2 で割るのはこちら</b>（<see cref="EmbeddingPipeline"/>）。
/// </para>
/// <para>
/// 接頭辞と切り詰めもこちらの仕事である。どれも黙って間違えられるので、
/// 判断は <see cref="EmbeddingPipeline"/> に置いてモデル無しでも検査できるようにしてある。
/// </para>
/// </summary>
public sealed class OnnxEmbedder : IEmbedder, IDisposable
{
    /// <summary>
    /// 収める長さの上限。
    ///
    /// <para>
    /// ONNX は長さが動くので 8192 まで通せるが、<b>macOS 版と揃える</b>。
    /// あちらは Core ML の固定長バケットの最大が 2048 で、そこで切っている。
    /// 揃えないと、長い段落だけ実装によって別のベクトルになる。
    /// 段落は 400 字（およそ 200 トークン）を狙っているので、まず届かない。
    /// </para>
    /// </summary>
    public const int MaximumTokens = 2048;

    private readonly InferenceSession _session;
    private readonly UnigramTokenizer _tokenizer;
    private readonly string _output;
    private readonly Lock _gate = new();
    private bool _disposed;

    public int Dimension { get; }

    private OnnxEmbedder(InferenceSession session, UnigramTokenizer tokenizer, int dimension, string output)
    {
        _session = session;
        _tokenizer = tokenizer;
        Dimension = dimension;
        _output = output;
    }

    /// <summary>
    /// 置いてあるモデルを開く。
    ///
    /// <para>
    /// 要るのは <c>model.onnx</c>（または <c>onnx/</c> の下）と <c>tokenizer.json</c> の 2 つだけ。
    /// </para>
    /// </summary>
    public static OnnxEmbedder Load(string directory)
    {
        var model = Find(directory)
            ?? throw new DocumentException("missingModel", $"モデルが見つかりません: {directory}");
        var vocabulary = Path.Combine(directory, "tokenizer.json");
        if (!File.Exists(vocabulary))
        {
            throw new DocumentException("missingModel", $"tokenizer.json がありません: {directory}");
        }

        var session = new InferenceSession(model);
        try
        {
            // **出口はグラフに聞く。** 名前を決め打ちすると、変換の仕方が変わったときに黙って外れる。
            var output = session.OutputMetadata.ContainsKey("sentence_embedding")
                ? "sentence_embedding"
                : throw new DocumentException("missingModel",
                    $"sentence_embedding を出さないグラフです（出口: {string.Join(",", session.OutputMetadata.Keys)}）");

            // 次元もグラフの申告から読む。モデルを差し替えても実装は変わらない。
            var shape = session.OutputMetadata[output].Dimensions;
            var dimension = shape.Length > 0 && shape[^1] > 0
                ? shape[^1]
                : throw new DocumentException("missingModel", "出口の次元が分かりません");

            return new OnnxEmbedder(session, UnigramTokenizer.Load(vocabulary), dimension, output);
        }
        catch (Exception)
        {
            session.Dispose();
            throw;
        }
    }

    private static string? Find(string directory)
    {
        string[] places =
        [
            Path.Combine(directory, "model.onnx"),
            Path.Combine(directory, "onnx", "model.onnx"),
            Path.Combine(directory, "onnx", "model_fp16.onnx"),
        ];
        return places.FirstOrDefault(File.Exists);
    }

    /// <summary>
    /// 1 本のベクトルにする。
    ///
    /// <para>
    /// <b>直列に回す。</b>索引づくり（裏）と問い（前）が同じものを叩くので閂を掛ける。
    /// この競合は検査でも捕まえにくい（窓が狭いだけで、無いわけではない）。
    /// </para>
    /// </summary>
    public Embedded Embed(string text, EmbeddingKind kind)
    {
        var ids = _tokenizer.Encode(EmbeddingPipeline.PrefixOf(kind) + text);
        var (kept, truncated) = EmbeddingPipeline.Truncate(ids, MaximumTokens);

        var tokens = new DenseTensor<long>([1, kept.Length]);
        var mask = new DenseTensor<long>([1, kept.Length]);
        for (var at = 0; at < kept.Length; at++)
        {
            tokens[0, at] = kept[at];
            // 1 本ずつ回すので詰め物は無い。すべて数に入れる。
            mask[0, at] = 1;
        }

        float[] made;
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            using var result = _session.Run(
            [
                NamedOnnxValue.CreateFromTensor("input_ids", tokens),
                NamedOnnxValue.CreateFromTensor("attention_mask", mask),
            ], [_output]);
            made = [.. result.First().AsEnumerable<float>()];
        }

        if (made.Length != Dimension)
        {
            throw new DocumentException("embedderMismatch",
                $"出てきた長さが違う: {made.Length} ≠ {Dimension}");
        }

        // グラフは正規化しない。ここで割る。
        EmbeddingPipeline.Normalize(made);
        return new Embedded(made, truncated);
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }
            _disposed = true;
            _session.Dispose();
        }
    }
}
