using System.Numerics.Tensors;
using System.Text;

namespace ChoroReader.Core;

/// <summary>
/// 書籍ひとつぶんの意味の索引。
///
/// <para>
/// 段落ごとに 1 本のベクトルを持つ（spec-local-ai.md 4.1）。
/// ベクトルは正規化してあるので、近さは内積そのものである。
/// </para>
/// <para>
/// <b>順位付けに要るものと、当たってから要るものを分けて持つ。</b>
/// </para>
/// <list type="bullet">
/// <item>節の番号とベクトルは、読んだときにほどく。引くたびに全部触るものだからである</item>
/// <item>飛び先・見出し・目印（メタデータ）は、<b>当たりが出るまでほどかない</b>。
/// 一緒にほどくと、500 冊を引くたびに 29 万個の文字列を組み立てることになる</item>
/// </list>
/// <para>
/// ベクトルは <b>fp16 のまま持つ</b>。fp32 に広げて持つと同じ中身で倍の場所を食い、
/// 記憶に抱えられる冊数が半分になる。引くときに 1 冊ぶんずつ fp32 へ広げる。
/// </para>
/// <para>
/// <b>どのモデルで作ったかは包む側（<see cref="SemanticIndexStore"/>）が持つ。</b>
/// ベクトルはモデルが変われば意味を失うので、失効の鍵に要る。
/// 中身にも書くと鍵が 2 層に散り、片方だけ見て通す事故になる。
/// </para>
/// </summary>
public sealed class SemanticIndex
{
    /// <summary>作ったときのモデル。<b>読み込みのときに包む側から渡される。</b></summary>
    public string Model { get; }

    public int Dimension { get; }

    /// <summary>
    /// いちばん長いバケットに収まらず、頭から切り詰めた単位の数。
    /// 数だけ残して、後から測り直せるようにする。
    /// </summary>
    public int Truncated { get; }

    public int Count { get; }

    /// <summary>単位ごとの節の番号。<b>順位は節で決める</b>ので、先にほどいておく。</summary>
    private readonly int[] _sections;

    /// <summary><c>Count * Dimension</c> を fp16 のまま平らに並べたもの。単位ごとに正規化済み。</summary>
    private readonly Half[] _half;

    /// <summary>メタデータ。ほどくまでバイト列のまま持ち、ほどいたら捨てる。</summary>
    private readonly Lock _gate = new();

    private IReadOnlyList<SemanticUnit>? _units;
    private byte[]? _meta;

    public SemanticIndex(string model, int dimension, IReadOnlyList<SemanticUnit> units,
                         ReadOnlySpan<float> vectors, int truncated)
    {
        Model = model;
        Dimension = dimension;
        Truncated = truncated;
        Count = units.Count;
        _sections = [.. units.Select(unit => unit.Section)];
        _half = new Half[vectors.Length];
        TensorPrimitives.ConvertToHalf(vectors, _half);
        _units = units;
        _meta = null;
    }

    private SemanticIndex(string model, int dimension, int truncated,
                          int[] sections, Half[] half, byte[] meta)
    {
        Model = model;
        Dimension = dimension;
        Truncated = truncated;
        Count = sections.Length;
        _sections = sections;
        _half = half;
        _units = null;
        _meta = meta;
    }

    // MARK: 引く

    /// <summary>
    /// 近い順に単位の番号と点を返す。
    ///
    /// <para>
    /// <b>順位は節で決め、着地は段落でする。</b>
    /// 段落だけで順位を付けると話題の芯を失う（実測 8/15 対 11/15、spec-local-ai.md 5.1）。
    /// 節の点は段落の平均で決める。最大にすると段落の多い節ほど得をする。
    /// </para>
    /// <para>
    /// 総当たりで足りる。ANN は持たない（4.3）。
    /// </para>
    /// <para>
    /// <b>同点の並びは番号の小さい順で決める。</b>辞書の並び順に任せると、
    /// 同じ索引を引いても呼ぶたびに順が入れ替わりうる。
    /// </para>
    /// </summary>
    public IReadOnlyList<(int Unit, float Score)> Nearest(ReadOnlySpan<float> vector, int limit)
    {
        if (vector.Length != Dimension || Count == 0)
        {
            return [];
        }

        // fp16 を 1 冊ぶんだけ広げる。持ち続けるのは fp16 の側。
        var wide = new float[_half.Length];
        TensorPrimitives.ConvertToSingle(_half, wide);

        var scores = new float[Count];
        for (var at = 0; at < Count; at++)
        {
            scores[at] = TensorPrimitives.Dot<float>(
                wide.AsSpan(at * Dimension, Dimension), vector);
        }

        // 節ごとにまとめる。代表は節の中でいちばん近い段落。
        var best = new Dictionary<int, (int Unit, float Sum, int Members, float Top)>();
        for (var at = 0; at < Count; at++)
        {
            var section = _sections[at];
            var score = scores[at];
            if (best.TryGetValue(section, out var already))
            {
                already.Sum += score;
                already.Members++;
                if (score > already.Top)
                {
                    already.Top = score;
                    already.Unit = at;
                }
                best[section] = already;
            }
            else
            {
                best[section] = (at, score, 1, score);
            }
        }

        return [.. best.Values
            .Select(one => (Unit: one.Unit, Score: one.Sum / one.Members))
            .OrderByDescending(one => one.Score)
            .ThenBy(one => one.Unit)
            .Take(limit)];
    }

    /// <summary>ある単位のベクトル。</summary>
    public float[]? Vector(int unit)
    {
        if (unit < 0 || unit >= Count)
        {
            return null;
        }
        var made = new float[Dimension];
        TensorPrimitives.ConvertToSingle(_half.AsSpan(unit * Dimension, Dimension), made);
        return made;
    }

    // MARK: メタデータ

    /// <summary>
    /// 1 単位ぶんの飛び先と見出し。<b>最初に触ったときに全部ほどく。</b>
    /// 勝った書籍でしか呼ばれない前提である。
    /// </summary>
    public SemanticUnit Unit(int at) => Units[at];

    public IReadOnlyList<SemanticUnit> Units
    {
        get
        {
            lock (_gate)
            {
                if (_units is { } already)
                {
                    return already;
                }
                var made = DecodeMeta();
                _units = made;
                _meta = null;
                return made;
            }
        }
    }

    // MARK: 書き出し

    /// <summary>
    /// 並びは「節の番号 → ベクトル → メタデータ」。
    ///
    /// <para>
    /// 引くのに要るものが前、当たってから要るものが後ろ。
    /// 読み込みは前だけをほどき、後ろは長さを確かめて置いておく。
    /// </para>
    /// </summary>
    public byte[] Encode()
    {
        var out_ = new List<byte>();
        Varint.Put(out_, (ulong)Dimension);
        Varint.Put(out_, (ulong)Truncated);
        Varint.Put(out_, (ulong)Count);
        foreach (var section in _sections)
        {
            Varint.Put(out_, (ulong)section);
        }

        var vectors = new byte[_half.Length * 2];
        for (var at = 0; at < _half.Length; at++)
        {
            BitConverter.TryWriteBytes(vectors.AsSpan(at * 2, 2), BitConverter.HalfToUInt16Bits(_half[at]));
        }
        out_.AddRange(vectors);

        var meta = EncodeMeta(Units);
        Varint.Put(out_, (ulong)meta.Length);
        out_.AddRange(meta);
        return [.. out_];
    }

    /// <summary>
    /// 読み直す。<b>モデルの名前は包む側から渡す</b>（中身には書いていない）。
    ///
    /// <para>
    /// ほどくのは節の番号とベクトルまで。メタデータは<b>長さだけ確かめて</b>置いておく。
    /// 途中で切れたものは長さが合わないので、ここで落ちる。
    /// </para>
    /// </summary>
    public static SemanticIndex? Decode(byte[] data, int from, string model)
    {
        var reader = new Varint.Cursor(data, from);

        if (reader.Get() is not { } dimension || dimension == 0 || dimension >= 65536
            || reader.Get() is not { } truncated
            || reader.Get() is not { } total || total >= 5_000_000)
        {
            return null;
        }

        var sections = new int[(int)total];
        for (var at = 0; at < sections.Length; at++)
        {
            if (reader.Get() is not { } section || section >= 10_000_000)
            {
                return null;
            }
            sections[at] = (int)section;
        }

        var vectorBytes = (int)total * (int)dimension * 2;
        if (reader.At + vectorBytes > data.Length)
        {
            return null;
        }
        var half = new Half[(int)total * (int)dimension];
        for (var at = 0; at < half.Length; at++)
        {
            half[at] = BitConverter.UInt16BitsToHalf(
                BitConverter.ToUInt16(data, reader.At + at * 2));
        }
        if (!reader.Skip(vectorBytes))
        {
            return null;
        }

        if (reader.Get() is not { } metaLength || data.Length - reader.At != (int)metaLength)
        {
            return null;
        }
        return new SemanticIndex(model, (int)dimension, (int)truncated,
                                 sections, half, data[reader.At..]);
    }

    // MARK: メタデータの形

    /// <summary>
    /// メタデータの文字列は<b>表で 1 度だけ</b>書く。
    /// 見出しと章の道筋は同じ節の段落ぶん（10 前後）重複するためである。
    /// 目印は段落ごとに違うのでそのまま書く。
    /// </summary>
    private static byte[] EncodeMeta(IReadOnlyList<SemanticUnit> units)
    {
        // 表の 0 番は空。「無い」を 0 で書けるようにする。
        var table = new List<string> { string.Empty };
        var lookup = new Dictionary<string, int>(StringComparer.Ordinal) { [string.Empty] = 0 };

        int Indexed(string? text)
        {
            var key = text ?? string.Empty;
            if (lookup.TryGetValue(key, out var already))
            {
                return already;
            }
            table.Add(key);
            lookup[key] = table.Count - 1;
            return table.Count - 1;
        }

        // 先に全部引いて、表を確定させてから書く。
        var rows = units.Select(unit => (
            Heading: Indexed(unit.Heading),
            Href: Indexed(unit.Locator.Href),
            Fragment: Indexed(unit.Locator.Fragment),
            Page: (ulong)(unit.Locator.Page is { } page ? page + 1 : 0),
            // 位置は 10 万分の 1 まで。1,000 ページの本で 0.01 ページぶんの粗さで足りる。
            // 丸めはちょうど半分のとき 0 から遠い側へ寄せる（実装間で揃える決まり）。
            Progression: (ulong)Math.Round(unit.Locator.Progression * 100_000, MidpointRounding.AwayFromZero),
            Anchor: unit.Locator.Text ?? string.Empty)).ToList();

        var out_ = new List<byte>();
        Varint.Put(out_, (ulong)table.Count);
        foreach (var text in table)
        {
            Varint.PutBytes(out_, Encoding.UTF8.GetBytes(text));
        }
        foreach (var row in rows)
        {
            Varint.Put(out_, (ulong)row.Heading);
            Varint.Put(out_, (ulong)row.Href);
            Varint.Put(out_, (ulong)row.Fragment);
            Varint.Put(out_, row.Page);
            Varint.Put(out_, row.Progression);
            Varint.PutBytes(out_, Encoding.UTF8.GetBytes(row.Anchor));
        }
        return [.. out_];
    }

    private IReadOnlyList<SemanticUnit> DecodeMeta()
    {
        if (_meta is not { } blob)
        {
            return [];
        }
        var reader = new Varint.Cursor(blob, 0);

        if (reader.Get() is not { } tableCount || tableCount >= 1_000_000)
        {
            return Broken();
        }
        var table = new List<string>((int)tableCount);
        for (var at = 0; at < (int)tableCount; at++)
        {
            if (reader.Take() is not { } text)
            {
                return Broken();
            }
            table.Add(Encoding.UTF8.GetString(text));
        }

        string? Look(ulong at)
        {
            if (at >= (ulong)table.Count)
            {
                return null;
            }
            return table[(int)at].Length == 0 ? null : table[(int)at];
        }

        var made = new List<SemanticUnit>(Count);
        for (var at = 0; at < Count; at++)
        {
            if (reader.Get() is not { } heading || reader.Get() is not { } href
                || reader.Get() is not { } fragment || reader.Get() is not { } page
                || reader.Get() is not { } progression || reader.Take() is not { } anchor)
            {
                return Broken();
            }
            made.Add(new SemanticUnit
            {
                Locator = new Locator
                {
                    Href = Look(href),
                    Page = page == 0 ? null : (int)page - 1,
                    Progression = progression / 100_000.0,
                    Fragment = Look(fragment),
                    Text = anchor.Length == 0 ? null : Encoding.UTF8.GetString(anchor),
                },
                Heading = Look(heading) ?? string.Empty,
                Section = _sections[at],
            });
        }
        return made;
    }

    /// <summary>
    /// メタデータが崩れていたときの逃げ道。
    ///
    /// <para>
    /// 長さの検査は通ったのに中身が読めない、はまず起きないが、
    /// 起きたときに数を食い違わせると <see cref="Unit"/> が落ちる。空の殻で数だけ揃える。
    /// </para>
    /// </summary>
    private IReadOnlyList<SemanticUnit> Broken() =>
        [.. _sections.Select(section => new SemanticUnit
        {
            Locator = new Locator(),
            Heading = string.Empty,
            Section = section,
        })];
}
