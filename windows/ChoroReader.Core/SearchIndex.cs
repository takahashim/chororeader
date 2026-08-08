using System.Text;

namespace ChoroReader.Core;

/// <summary>
/// 全文検索の索引。
///
/// <para>
/// 日本語には単語の切れ目が無いので、二字組（バイグラム）を鍵にした転置索引を持つ。
/// </para>
/// <para>
/// この索引は<b>候補を絞るだけ</b>で、当たりを決めない。
/// 二字組が同じ単位に出ていても、続けて出ているとは限らないためである。
/// 絞った単位を <see cref="DocumentSearch"/> の走査にかけ直して初めて当たりが決まる。
/// そうすることで、結果は索引が無いときと一字も変わらない
/// （conformance/CONTRACT.md の「検索のヒット位置、件数、順序」を索引の導入で動かさないため）。
/// </para>
/// <para>
/// 当たりの位置を索引に持たせないぶん、容量が小さい。
/// 索引の形式は実装ごとに閉じたもので、契約には載せない（spec.md 10.4）。
/// 揃えるべきは索引の中身ではなく検索結果である。
/// </para>
/// </summary>
public sealed class SearchIndex
{
    /// <summary>索引の形式の版。読めない版のファイルは捨てて作り直す。</summary>
    private const byte Version = 1;

    private static ReadOnlySpan<byte> Magic => "CHIX"u8;

    /// <summary>
    /// 単位の終わりを表す番人。
    ///
    /// 1 文字だけの問い合わせは「その字で始まる二字組」をまとめて引くが、
    /// 単位の最後の 1 文字は次の字を持たないので、そのままでは引けない。
    /// 二字目を 0 にした組を足しておくと、範囲を引くだけで漏れなく当たる。
    /// </summary>
    private const uint Sentinel = 0;

    private readonly uint _unitCount;

    /// <summary>昇順に並べた鍵。</summary>
    private readonly ulong[] _keys;

    /// <summary><c>_keys[i]</c> の単位番号は <c>_units[_offsets[i].._offsets[i + 1]]</c>。</summary>
    private readonly int[] _offsets;

    private readonly uint[] _units;

    private SearchIndex(uint unitCount, ulong[] keys, int[] offsets, uint[] units)
    {
        _unitCount = unitCount;
        _keys = keys;
        _offsets = offsets;
        _units = units;
    }

    public int UnitCount => (int)_unitCount;

    public bool IsEmpty => _keys.Length == 0;

    /// <summary>2 文字を 1 つの数にする。Unicode の符号位置は 21 bit に収まる。</summary>
    private static ulong KeyOf(Rune first, uint second) => ((ulong)first.Value << 21) | second;

    public static SearchIndex Build(IReadOnlyList<string> units)
    {
        var pairs = new List<(ulong Key, uint Unit)>();

        for (var number = 0; number < units.Count; number++)
        {
            var chars = Fold.Text(units[number]);
            for (var i = 0; i + 1 < chars.Count; i++)
            {
                pairs.Add((KeyOf(chars[i], (uint)chars[i + 1].Value), (uint)number));
            }
            if (chars.Count > 0)
            {
                pairs.Add((KeyOf(chars[^1], Sentinel), (uint)number));
            }
        }

        pairs.Sort();

        var keys = new List<ulong>();
        var offsets = new List<int> { 0 };
        var postings = new List<uint>();
        (ulong Key, uint Unit)? previous = null;

        foreach (var pair in pairs)
        {
            if (previous == pair)
            {
                continue;
            }
            previous = pair;

            if (keys.Count == 0 || keys[^1] != pair.Key)
            {
                keys.Add(pair.Key);
                offsets.Add(postings.Count);
            }
            postings.Add(pair.Unit);
            offsets[^1] = postings.Count;
        }

        return new SearchIndex((uint)units.Count, [.. keys], [.. offsets], [.. postings]);
    }

    /// <summary>
    /// 問い合わせが当たりうる単位の番号。
    ///
    /// <para>null は「索引では絞れないので全部を見よ」を意味する。</para>
    /// </summary>
    public IReadOnlySet<int>? Candidates(string query)
    {
        var chars = Fold.Text(query);
        if (chars.Count == 0)
        {
            return null;
        }
        if (chars.Count == 1)
        {
            return ToSet(ByFirstChar(chars[0]));
        }

        uint[]? found = null;
        for (var i = 0; i + 1 < chars.Count; i++)
        {
            var posting = Posting(KeyOf(chars[i], (uint)chars[i + 1].Value));
            found = found is null ? posting : Intersect(found, posting);
            if (found.Length == 0)
            {
                break;
            }
        }
        return found is null ? null : ToSet(found);
    }

    private static IReadOnlySet<int> ToSet(uint[] units)
    {
        var set = new HashSet<int>(units.Length);
        foreach (var unit in units)
        {
            set.Add((int)unit);
        }
        return set;
    }

    private uint[] Posting(ulong key)
    {
        var at = Array.BinarySearch(_keys, key);
        return at < 0 ? [] : _units[_offsets[at].._offsets[at + 1]];
    }

    /// <summary>その字で始まる二字組をすべて合併する。</summary>
    private uint[] ByFirstChar(Rune c)
    {
        var from = (ulong)c.Value << 21;
        var to = from + (1UL << 21);
        var start = LowerBound(from);
        var end = LowerBound(to);

        var seen = new bool[_unitCount];
        var found = new List<uint>();
        for (var at = start; at < end; at++)
        {
            for (var i = _offsets[at]; i < _offsets[at + 1]; i++)
            {
                var unit = _units[i];
                if (!seen[unit])
                {
                    seen[unit] = true;
                    found.Add(unit);
                }
            }
        }
        found.Sort();
        return [.. found];
    }

    /// <summary><paramref name="value"/> 以上が最初に現れる位置。</summary>
    private int LowerBound(ulong value)
    {
        var low = 0;
        var high = _keys.Length;
        while (low < high)
        {
            var middle = low + ((high - low) / 2);
            if (_keys[middle] < value)
            {
                low = middle + 1;
            }
            else
            {
                high = middle;
            }
        }
        return low;
    }

    private static uint[] Intersect(uint[] left, uint[] right)
    {
        var found = new List<uint>();
        int a = 0, b = 0;
        while (a < left.Length && b < right.Length)
        {
            if (left[a] < right[b])
            {
                a++;
            }
            else if (left[a] > right[b])
            {
                b++;
            }
            else
            {
                found.Add(left[a]);
                a++;
                b++;
            }
        }
        return [.. found];
    }

    // MARK: 書き出しと読み込み
    //
    // 鍵も単位番号も昇順に並んでいるので、差分を可変長で書けば大半が 1 バイトで済む。

    public byte[] Encode()
    {
        var output = new List<byte>();
        output.AddRange(Magic);
        output.Add(Version);
        Varint.Put(output, _unitCount);
        Varint.Put(output, (ulong)_keys.Length);

        var previous = 0ul;
        for (var at = 0; at < _keys.Length; at++)
        {
            Varint.Put(output, _keys[at] - previous);
            previous = _keys[at];
            Varint.Put(output, (ulong)(_offsets[at + 1] - _offsets[at]));
        }

        for (var at = 0; at < _keys.Length; at++)
        {
            var last = 0u;
            for (var i = _offsets[at]; i < _offsets[at + 1]; i++)
            {
                Varint.Put(output, _units[i] - last);
                last = _units[i];
            }
        }
        return [.. output];
    }

    /// <summary>読めなければ null。壊れたファイルは捨てて作り直す。</summary>
    public static SearchIndex? Decode(byte[] bytes)
    {
        var head = Magic.Length + 1;
        if (bytes.Length < head || !bytes.AsSpan(0, Magic.Length).SequenceEqual(Magic)
            || bytes[Magic.Length] != Version)
        {
            return null;
        }

        var cursor = new Varint.Cursor(bytes, head);
        if (cursor.Get() is not { } rawUnitCount || rawUnitCount > uint.MaxValue
            || cursor.Get() is not { } rawKeyCount || rawKeyCount > int.MaxValue)
        {
            return null;
        }
        var unitCount = (uint)rawUnitCount;
        var keyCount = (int)rawKeyCount;

        var keys = new ulong[keyCount];
        var lengths = new int[keyCount];
        var previous = 0ul;
        for (var i = 0; i < keyCount; i++)
        {
            if (cursor.Get() is not { } step || cursor.Get() is not { } length || length > int.MaxValue)
            {
                return null;
            }
            previous += step;
            keys[i] = previous;
            lengths[i] = (int)length;
        }

        var offsets = new int[keyCount + 1];
        var units = new List<uint>();
        for (var i = 0; i < keyCount; i++)
        {
            var last = 0u;
            for (var n = 0; n < lengths[i]; n++)
            {
                if (cursor.Get() is not { } step || step > uint.MaxValue)
                {
                    return null;
                }
                last += (uint)step;
                if (last >= unitCount)
                {
                    return null;
                }
                units.Add(last);
            }
            offsets[i + 1] = units.Count;
        }

        return new SearchIndex(unitCount, keys, offsets, [.. units]);
    }
}
