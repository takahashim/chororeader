using System.Text.Json;

namespace ChoroReader.Convert;

public enum Activation
{
    Gelu,
    Silu,
}

/// <summary>
/// <c>config.json</c> から、グラフを組むのに要る値を読む。
///
/// <para>
/// <b>組み上げるグラフは決め打ちである。</b>射影に bias は付けず、rope は head の
/// 幅いっぱいに掛け、全域注意の層は <c>層 % n == 0</c> で選ぶ。config がそれと違うことを
/// 言っていても変換は通り、<b>それらしい数まで出る</b>。だから読むときに拒む。
/// </para>
/// <para>
/// 拒む理由は全部まとめて言う。使えない checkpoint を見ている人が欲しいのは
/// 一覧であって、最初の 1 つではない。
/// </para>
/// </summary>
public sealed class EncoderConfig
{
    public int Hidden { get; }
    public int Heads { get; }
    public int Layers { get; }
    public int Intermediate { get; }
    public int Vocab { get; }
    public float Eps { get; }

    /// <summary>局所注意の窓の幅。</summary>
    public int LocalAttention { get; }

    /// <summary>この間隔ごとの層が全域を見る。ほかは窓の中だけを見る。</summary>
    public int GlobalEvery { get; }

    public float LocalRopeTheta { get; }
    public float GlobalRopeTheta { get; }

    /// <summary>
    /// checkpoint が学習された最も長い位置。
    /// <b>これを超える長さは、後ろに学習された rope が無い。</b>動きはするが間違った数を出す。
    /// </summary>
    public int MaxPositions { get; }

    /// <summary>中間層の門の活性。</summary>
    public Activation Activation { get; }

    /// <summary>分類頭を持つか（reranker）。</summary>
    public bool IsClassifier { get; }

    /// <summary>重みの名前に付く前置き。分類頭のある checkpoint は <c>model.</c> が付く。</summary>
    public string Prefix { get; }

    public int HeadDim => Hidden / Heads;

    /// <summary>この層は全域を見るか。</summary>
    public bool IsGlobal(int layer) => GlobalEvery != 0 && layer % GlobalEvery == 0;

    public EncoderConfig(string json)
    {
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(json);
        }
        catch (JsonException)
        {
            throw new ConvertException("config.json を読めません：JSON として読めません");
        }

        using (document)
        {
            var root = document.RootElement;

            double? Number(string key) =>
                root.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.Number
                    ? value.GetDouble()
                    : null;

            int Integer(string key) => (int)(Number(key)
                ?? throw new ConvertException($"config.json を読めません：{key} がありません"));

            Hidden = Integer("hidden_size");
            Heads = Integer("num_attention_heads");
            Layers = Integer("num_hidden_layers");
            Intermediate = Integer("intermediate_size");
            Vocab = Integer("vocab_size");
            // ruri は norm_eps、ほかは layer_norm_eps を持つ。どちらも受ける。
            Eps = (float)(Number("norm_eps") ?? Number("layer_norm_eps") ?? 1e-5);
            LocalAttention = (int)(Number("local_attention") ?? 128);
            GlobalEvery = (int)(Number("global_attn_every_n_layers") ?? 3);

            // **theta の置き場所が 2 通りある。** 新しい config は `rope_parameters` の側に持ち、
            // 平らな鍵は null になる。そこだけを見ていると既定値で変換が通り、
            // 静かに違うベクトルが出る（macOS 版が踏んだ。cosine 0.14）。
            root.TryGetProperty("rope_parameters", out var ropeParameters);
            float Theta(string kind, string flat, double fallback)
            {
                if (ropeParameters.ValueKind == JsonValueKind.Object
                    && ropeParameters.TryGetProperty(kind, out var one)
                    && one.TryGetProperty("rope_theta", out var value)
                    && value.ValueKind == JsonValueKind.Number)
                {
                    return (float)value.GetDouble();
                }
                return (float)(Number(flat) ?? Number("rope_theta") ?? fallback);
            }
            LocalRopeTheta = Theta("sliding_attention", "local_rope_theta", 10000);
            GlobalRopeTheta = Theta("full_attention", "global_rope_theta", 160000);
            MaxPositions = (int)(Number("max_position_embeddings") ?? 8192);

            var name = Text(root, "hidden_activation") ?? "gelu";
            Activation = Parse(name, "hidden_activation");

            var architectures = root.TryGetProperty("architectures", out var list)
                                && list.ValueKind == JsonValueKind.Array
                ? list.EnumerateArray().Select(one => one.GetString() ?? "").ToList()
                : [];
            IsClassifier = architectures.Any(one => one.Contains("SequenceClassification"));
            // 分類頭のある checkpoint は胴体の重みに `model.` が付く。
            Prefix = IsClassifier ? "model." : "";

            var reasons = Assumptions(root, GlobalEvery, Hidden, Heads);
            if (reasons.Count > 0)
            {
                throw new ConvertException("この checkpoint は変換できません：\n"
                    + string.Join("\n", reasons.Select(one => $"  ・{one}")));
            }
        }
    }

    private static string? Text(JsonElement root, string key) =>
        root.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static Activation Parse(string name, string key) =>
        name.Replace("_", "") switch
        {
            "gelu" => Activation.Gelu,
            "silu" => Activation.Silu,
            _ => throw new ConvertException($"config.json を読めません：{key} が {name} は扱いません"),
        };

    /// <summary>
    /// <b>決め打ちのグラフが守れない言い分</b>を集める。
    ///
    /// <para>
    /// どれも値にはならない。読んで無視すると、通って、それらしい数が出て、
    /// 順位だけが静かに狂う。
    /// </para>
    /// </summary>
    private static List<string> Assumptions(JsonElement root, int globalEvery, int hidden, int heads)
    {
        var made = new List<string>();

        // 組み上げる linear はどれも bias を持たず、正規化は gamma だけを持つ。
        foreach (var (key, what) in new[]
                 {
                     ("attention_bias", "注意の射影"),
                     ("mlp_bias", "中間層の射影"),
                     ("norm_bias", "正規化"),
                 })
        {
            if (root.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.True)
            {
                made.Add($"{key} が true だが、組み上げるグラフは{what}に bias を持たせない");
            }
        }

        // 組み上げる rope は伸縮しない。既定でない rope_type は参照実装だけが効かせる。
        if (root.TryGetProperty("rope_parameters", out var rope) && rope.ValueKind == JsonValueKind.Object)
        {
            foreach (var kind in new[] { "full_attention", "sliding_attention" })
            {
                if (rope.TryGetProperty(kind, out var one)
                    && Text(one, "rope_type") is { } type && type != "default")
                {
                    made.Add($"rope_parameters.{kind}.rope_type が {type} だが、組み上げる rope は伸縮しない");
                }
            }
        }

        // layer_types があるなら、そちらが正しい。間隔で選ぶこちらの規則が違うことになる。
        if (root.TryGetProperty("layer_types", out var types) && types.ValueKind == JsonValueKind.Array)
        {
            var disagree = types.EnumerateArray()
                .Select((one, at) => (At: at, Global: one.GetString() == "full_attention"))
                .Where(one => one.Global != (globalEvery != 0 && one.At % globalEvery == 0))
                .Select(one => one.At)
                .ToList();
            if (disagree.Count > 0)
            {
                made.Add($"layer_types の層 [{string.Join(", ", disagree)}] が "
                    + $"global_attn_every_n_layers {globalEvery} と食い違う。"
                    + "組み上げるグラフは間隔の方に従う");
            }
        }

        // head の幅で割り切れないと、rope の掛け方が変わる。
        if (heads == 0 || hidden % heads != 0)
        {
            made.Add($"hidden_size {hidden} が num_attention_heads {heads} で割り切れない");
        }
        else if (hidden / heads % 2 != 0)
        {
            made.Add($"head の幅 {hidden / heads} が偶数でない。rope は 2 つ組で回す");
        }

        return made;
    }

    /// <summary>
    /// 焼く長さが使えるかを見る。
    /// <b>学習された位置を超える長さは、動いて、間違った数を出す。</b>
    /// </summary>
    public void Check(int maximumSequence)
    {
        var reasons = new List<string>();
        if (maximumSequence <= 0)
        {
            reasons.Add($"最大の長さ {maximumSequence} が正でない");
        }
        if (maximumSequence > MaxPositions)
        {
            reasons.Add($"最大の長さ {maximumSequence} が、学習された位置 {MaxPositions} を超える");
        }
        if (reasons.Count > 0)
        {
            throw new ConvertException("この checkpoint は変換できません：\n"
                + string.Join("\n", reasons.Select(one => $"  ・{one}")));
        }
    }
}
