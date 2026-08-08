using System.Text;
using System.Text.Json;

namespace ChoroReader.Core;

/// <summary>
/// Unigram（SentencePiece）方式のトークナイザ。
///
/// <para>
/// Ruri v3 の <c>tokenizer.json</c> をそのまま読む。30m / 130m / 310m で同じファイルなので、
/// モデルの大きさを替えてもここは替わらない。
/// </para>
/// <para>
/// 段は 4 つ。
/// <list type="number">
/// <item>特殊トークン（added_tokens）で切り分ける。中身は素通し</item>
/// <item>Metaspace：空白を ▁ に置き換える（prepend_scheme=never なので頭には足さない）</item>
/// <item>Viterbi：語彙の並びで最も点の高い分け方を選ぶ</item>
/// <item>語彙に無い文字は byte fallback で <c>&lt;0xXX&gt;</c> に落とす</item>
/// </list>
/// </para>
/// <para>
/// <b>既製品では揃わない。</b><c>Microsoft.ML.Tokenizers</c> を凍結済みの期待値に通したところ
/// 31/37 で、残ったうち 1 件が Viterbi の同点の採り方の違いだった（外からは直せない）。
/// 測った結果は spikes/findings-csharp-tokenizer.md にある。
/// </para>
/// <para>
/// <b>食い違っても例外は出ず、黙って違うベクトルになる。</b>参照実装（kohagi、
/// Rust の tokenizers crate）とトークン ID が一致することを検査で固める以外に、
/// 守る手立てが無い。Swift 実装は次の 3 つで黙って間違えた
/// （spikes/findings-swift-tokenizer.md）。移すにあたって同じ 3 つを踏まないようにしてある。
/// </para>
/// <list type="bullet">
/// <item>
/// <b>語彙は文字列でなくバイト列で引く。</b>Swift の String は正準等価で比べるため
/// 「が」（1 符号位置）と「か」＋濁点（2 符号位置）が同じ鍵になり、片方が消えた。
/// C# の string は序数で比べるのでそこは踏まないが、JSON から来た並びを
/// UTF-16 へ通して戻す往復そのものを避けたいので、バイト列のまま扱う
/// </item>
/// <item>
/// <b>点の足し込みは double で行う。</b>語彙の点は f32 だが参照は f64 で積む。
/// 同じ点の分け方が並ぶと（目次の点線のような連なり）丸めで順位が入れ替わる
/// </item>
/// <item>
/// <b>同点は開始位置の小さい方（長い語彙）を採る。</b>バイト位置を昇順に進め、
/// 等号を含まない比較で更新すれば参照と同じになる
/// </item>
/// </list>
/// </summary>
public sealed class UnigramTokenizer
{
    private readonly record struct Entry(int Id, double Score);

    /// <summary>語彙。UTF-8 のバイト列から引く。</summary>
    private readonly Dictionary<byte[], Entry> _vocab;

    /// <summary>
    /// 走査の途中でバイト列を切り出さずに引くための口。
    ///
    /// <para>
    /// Viterbi は 1 文字進むごとに語彙を何度も引く。そのたびに配列を作ると、
    /// 1 冊（580 段落）で数百万回の割り当てになる。
    /// </para>
    /// </summary>
    private readonly Dictionary<byte[], Entry>.AlternateLookup<ReadOnlySpan<byte>> _lookup;

    private readonly int _unkId;
    private readonly bool _byteFallback;

    /// <summary>0…255 → <c>&lt;0xXX&gt;</c> の id。無ければ -1。</summary>
    private readonly int[] _byteToken;

    /// <summary>特殊トークン。長い順に見る。</summary>
    private readonly (byte[] Content, int Id)[] _added;

    private readonly int _bos;
    private readonly int _eos;
    private readonly double _minScore;

    /// <summary>語彙に載る最長のバイト数。Viterbi の探索幅を切る。</summary>
    private readonly int _maxPieceBytes;

    /// <summary>語彙に無い 1 文字に与える点。tokenizers の K_UNK_PENALTY と同じ。</summary>
    private const double UnkPenalty = 10.0;

    /// <summary>Metaspace の印（U+2581）。</summary>
    private static ReadOnlySpan<byte> Mark => "▁"u8;

    public static UnigramTokenizer Load(string path) =>
        new(JsonDocument.Parse(File.ReadAllBytes(path)));

    public static UnigramTokenizer Parse(string json) =>
        new(JsonDocument.Parse(json));

    private UnigramTokenizer(JsonDocument document)
    {
        using var owned = document;
        var root = owned.RootElement;

        if (!root.TryGetProperty("model", out var model)
            || !model.TryGetProperty("vocab", out var vocab)
            || vocab.ValueKind != JsonValueKind.Array
            || vocab.GetArrayLength() == 0)
        {
            throw new DocumentException("cannotReadTokenizer", "model.vocab がありません");
        }

        _vocab = new Dictionary<byte[], Entry>(vocab.GetArrayLength(), new ByBytes());
        var longest = 0;
        var lowest = double.MaxValue;
        var id = 0;
        foreach (var entry in vocab.EnumerateArray())
        {
            if (entry.ValueKind != JsonValueKind.Array || entry.GetArrayLength() < 2)
            {
                throw new DocumentException("cannotReadTokenizer", $"語彙 {id} の形が違います");
            }
            var piece = entry[0].GetString()
                        ?? throw new DocumentException("cannotReadTokenizer", $"語彙 {id} の形が違います");
            var score = entry[1].GetDouble();

            var bytes = Encoding.UTF8.GetBytes(piece);
            _vocab[bytes] = new Entry(id, score);
            longest = Math.Max(longest, bytes.Length);
            lowest = Math.Min(lowest, score);
            id++;
        }
        _lookup = _vocab.GetAlternateLookup<ReadOnlySpan<byte>>();
        _maxPieceBytes = longest;
        _minScore = lowest;

        _unkId = model.TryGetProperty("unk_id", out var unk) && unk.ValueKind == JsonValueKind.Number
            ? unk.GetInt32()
            : 0;
        _byteFallback = model.TryGetProperty("byte_fallback", out var fallback)
                        && fallback.ValueKind == JsonValueKind.True;

        _byteToken = new int[256];
        for (var b = 0; b < 256; b++)
        {
            _byteToken[b] = _lookup.TryGetValue(Encoding.UTF8.GetBytes($"<0x{b:X2}>"), out var found)
                ? found.Id
                : -1;
        }

        // 短いものが先に当たると取りこぼす。長い順に見る。
        _added = root.TryGetProperty("added_tokens", out var addedTokens)
                 && addedTokens.ValueKind == JsonValueKind.Array
            ? [.. addedTokens.EnumerateArray()
                .Where(t => t.TryGetProperty("content", out _) && t.TryGetProperty("id", out _))
                .Select(t => (Content: Encoding.UTF8.GetBytes(t.GetProperty("content").GetString() ?? string.Empty),
                              Id: t.GetProperty("id").GetInt32()))
                .OrderByDescending(t => t.Content.Length)]
            : [];

        // post_processor は TemplateProcessing で <s> … </s> を足すだけ。
        _bos = SpecialId(root, "<s>");
        _eos = SpecialId(root, "</s>");
    }

    private static int SpecialId(JsonElement root, string name)
    {
        if (root.TryGetProperty("post_processor", out var post)
            && post.TryGetProperty("special_tokens", out var special)
            && special.TryGetProperty(name, out var one)
            && one.TryGetProperty("ids", out var ids)
            && ids.ValueKind == JsonValueKind.Array
            && ids.GetArrayLength() > 0)
        {
            return ids[0].GetInt32();
        }
        return -1;
    }

    /// <summary>
    /// 文字列をトークン ID の並びにする。
    /// <paramref name="addSpecialTokens"/> が真なら <c>&lt;s&gt;</c> … <c>&lt;/s&gt;</c> で挟む。
    /// </summary>
    public IReadOnlyList<int> Encode(string text, bool addSpecialTokens = true)
    {
        var out_ = new List<int>();
        if (addSpecialTokens && _bos >= 0)
        {
            out_.Add(_bos);
        }

        var bytes = Encoding.UTF8.GetBytes(text);
        foreach (var piece in SplitOnAdded(bytes))
        {
            if (piece.Id >= 0)
            {
                out_.Add(piece.Id);
            }
            else
            {
                Viterbi(Metaspace(bytes.AsSpan(piece.From, piece.To - piece.From)), out_);
            }
        }

        if (addSpecialTokens && _eos >= 0)
        {
            out_.Add(_eos);
        }
        return out_;
    }

    // MARK: 段 1：特殊トークンで切り分ける

    /// <summary>切り分けた一片。<see cref="Id"/> が 0 以上なら特殊トークン、負なら素の範囲。</summary>
    private readonly record struct Split(int From, int To, int Id);

    private List<Split> SplitOnAdded(byte[] bytes)
    {
        var out_ = new List<Split>();
        if (_added.Length == 0)
        {
            if (bytes.Length > 0)
            {
                out_.Add(new Split(0, bytes.Length, -1));
            }
            return out_;
        }

        var at = 0;
        var plainFrom = 0;
        while (at < bytes.Length)
        {
            var hit = -1;
            var length = 0;
            foreach (var (content, id) in _added)
            {
                if (at + content.Length <= bytes.Length
                    && bytes.AsSpan(at, content.Length).SequenceEqual(content))
                {
                    hit = id;
                    length = content.Length;
                    break;
                }
            }
            if (hit >= 0)
            {
                if (at > plainFrom)
                {
                    out_.Add(new Split(plainFrom, at, -1));
                }
                out_.Add(new Split(at, at + length, hit));
                at += length;
                plainFrom = at;
            }
            else
            {
                at++;
            }
        }
        if (plainFrom < bytes.Length)
        {
            out_.Add(new Split(plainFrom, bytes.Length, -1));
        }
        return out_;
    }

    // MARK: 段 2：Metaspace

    /// <summary>空白を ▁ に置き換える。prepend_scheme が never なので頭には足さない。</summary>
    private static byte[] Metaspace(ReadOnlySpan<byte> bytes)
    {
        var out_ = new List<byte>(bytes.Length);
        foreach (var b in bytes)
        {
            if (b == 0x20)
            {
                out_.AddRange(Mark);
            }
            else
            {
                out_.Add(b);
            }
        }
        return [.. out_];
    }

    // MARK: 段 3：Viterbi

    /// <summary>最も点の高い分け方を選ぶ。バイト位置で進み、文字の頭だけを節点にする。</summary>
    private void Viterbi(byte[] bytes, List<int> into)
    {
        var count = bytes.Length;
        if (count == 0)
        {
            return;
        }

        // 継続バイト（10xxxxxx）は節点にしない。
        var boundary = new bool[count + 1];
        boundary[count] = true;
        for (var i = 0; i < count; i++)
        {
            boundary[i] = (bytes[i] & 0xC0) != 0x80;
        }

        var best = new double[count + 1];
        var from = new int[count + 1];
        // その節点へ入った語彙 id。-1 は語彙に無かった 1 文字。
        var arrived = new int[count + 1];
        Array.Fill(best, -double.MaxValue);
        Array.Fill(from, -1);
        Array.Fill(arrived, -1);
        best[0] = 0;

        var unkScore = _minScore - UnkPenalty;

        for (var i = 0; i < count; i++)
        {
            if (!boundary[i] || best[i] <= -double.MaxValue)
            {
                continue;
            }

            var matchedWholeChar = false;
            var limit = Math.Min(count, i + _maxPieceBytes);
            var width = CharLength(bytes[i]);

            for (var j = i + 1; j <= limit; j++)
            {
                if (!boundary[j] || !_lookup.TryGetValue(bytes.AsSpan(i, j - i), out var found))
                {
                    continue;
                }
                var value = best[i] + found.Score;
                // **等号を含めない。** 同点なら開始位置の小さい方（長い語彙）が残る。
                if (value > best[j])
                {
                    best[j] = value;
                    from[j] = i;
                    arrived[j] = found.Id;
                }
                if (j - i == width)
                {
                    matchedWholeChar = true;
                }
            }

            // その位置の 1 文字が語彙に無ければ、罰つきで進める（あとで byte fallback にする）
            if (!matchedWholeChar && i + width <= count)
            {
                var j = i + width;
                var value = best[i] + unkScore;
                if (value > best[j])
                {
                    best[j] = value;
                    from[j] = i;
                    arrived[j] = -1;
                }
            }
        }

        // 後ろから辿る。組み立ては逆順になるので、最後にひっくり返す。
        var reversed = new List<int>();
        var at2 = count;
        while (at2 > 0)
        {
            var previous = from[at2];
            if (previous < 0)
            {
                break;  // 進めなかった。起きないはずだが、途中まで返す
            }
            if (arrived[at2] >= 0)
            {
                reversed.Add(arrived[at2]);
            }
            else if (_byteFallback)
            {
                // 語彙に無い 1 文字は、UTF-8 のバイトごとに落とす
                for (var b = at2 - 1; b >= previous; b--)
                {
                    var token = _byteToken[bytes[b]];
                    reversed.Add(token >= 0 ? token : _unkId);
                }
            }
            else
            {
                reversed.Add(_unkId);
            }
            at2 = previous;
        }

        for (var i = reversed.Count - 1; i >= 0; i--)
        {
            into.Add(reversed[i]);
        }
    }

    /// <summary>そのバイトから始まる 1 文字のバイト数。</summary>
    private static int CharLength(byte first) => first switch
    {
        < 0x80 => 1,
        _ when (first & 0xE0) == 0xC0 => 2,
        _ when (first & 0xF0) == 0xE0 => 3,
        _ when (first & 0xF8) == 0xF0 => 4,
        _ => 1,
    };

    /// <summary>
    /// バイト列を鍵にするための比べ方。
    ///
    /// <para>
    /// 切り出さずに引けるよう、<c>ReadOnlySpan&lt;byte&gt;</c> からも引ける口を持たせる。
    /// </para>
    /// </summary>
    private sealed class ByBytes
        : IEqualityComparer<byte[]>, IAlternateEqualityComparer<ReadOnlySpan<byte>, byte[]>
    {
        public bool Equals(byte[]? left, byte[]? right) =>
            left is null ? right is null : right is not null && left.AsSpan().SequenceEqual(right);

        public int GetHashCode(byte[] key) => GetHashCode(key.AsSpan());

        public bool Equals(ReadOnlySpan<byte> span, byte[] key) => span.SequenceEqual(key);

        public int GetHashCode(ReadOnlySpan<byte> span)
        {
            var hash = new HashCode();
            hash.AddBytes(span);
            return hash.ToHashCode();
        }

        public byte[] Create(ReadOnlySpan<byte> span) => span.ToArray();
    }
}
