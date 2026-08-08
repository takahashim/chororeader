using System.Text;

namespace ChoroReader.Core;

/// <summary>
/// 全文検索の索引の置き場所と、作り直しの判断。
///
/// <para>
/// 索引は書籍そのものから何度でも作り直せるので、消えても困らない。
/// そのため覚え書きと同じ場所へ置きっぱなしにし、<b>元ファイルが変わったら捨てる</b>。
/// </para>
/// <para>
/// ほどいたものは持ち続ける。書棚の横断検索は引くたびに全冊の索引に触るので、
/// 毎回ほどき直すと読み込みのほうが絞り込みより高く付く。
/// </para>
/// </summary>
public sealed class SearchIndexStore
{
    /// <summary>覆いの版。読めない版のファイルは捨てて作り直す。</summary>
    private const byte Version = 1;

    private static ReadOnlySpan<byte> Magic => "CHIB"u8;

    /// <summary>抱え込む上限。蔵書が増えても際限なく持たない。溢れたら一度捨てて入れ直す。</summary>
    private const int MemoryLimit = 200;

    private readonly string _directory;
    private readonly Lock _gate = new();
    private readonly Dictionary<string, Entry> _memory = new(StringComparer.Ordinal);

    private sealed record Entry(SearchIndex Index, long Size, long Modified);

    public SearchIndexStore(string directory)
    {
        _directory = directory;
        Directory.CreateDirectory(_directory);
    }

    /// <summary>既定の置き場所。書籍そのものの隣には置かない（元ファイルを汚さない）。</summary>
    public static SearchIndexStore Default() => new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "ChoroReader",
        "indexes"));

    /// <summary>作らずに、既にあるものだけを返す。</summary>
    public SearchIndex? Cached(string bookPath)
    {
        var path = Paths.Normalize(bookPath);
        if (Stamp(path) is not { } stamp)
        {
            return null;
        }
        var (size, modified) = stamp;

        lock (_gate)
        {
            if (_memory.TryGetValue(path, out var found)
                && found.Size == size && found.Modified == modified)
            {
                return found.Index;
            }
        }

        byte[] bytes;
        try
        {
            bytes = File.ReadAllBytes(Location(path));
        }
        catch (Exception)
        {
            return null;
        }

        if (Unwrap(bytes) is not { } stored)
        {
            return null;
        }
        var (storedPath, storedSize, storedModified, payload) = stored;
        // 名前の重なりで別の本の索引を掴まないよう、道そのものも見る。
        if (storedPath != path || storedSize != size || storedModified != modified)
        {
            return null;
        }

        var index = SearchIndex.Decode(payload);
        if (index is not null)
        {
            Remember(path, index, size, modified);
        }
        return index;
    }

    /// <summary>
    /// 索引を返す。無ければその場で作って置く。
    /// <paramref name="units"/> は要るときにしか呼ばない。書籍を丸ごと読むので時間がかかる。
    /// </summary>
    public SearchIndex? Ensure(string bookPath, Func<IReadOnlyList<string>> units)
    {
        if (Cached(bookPath) is { } found)
        {
            return found;
        }

        var path = Paths.Normalize(bookPath);
        if (Stamp(path) is not { } stamp)
        {
            return null;
        }
        var (size, modified) = stamp;

        var index = SearchIndex.Build(units());

        var output = new List<byte>();
        output.AddRange(Magic);
        output.Add(Version);
        Varint.PutBytes(output, Encoding.UTF8.GetBytes(path));
        Varint.Put(output, (ulong)size);
        Varint.Put(output, (ulong)modified);
        output.AddRange(index.Encode());
        try
        {
            File.WriteAllBytes(Location(path), [.. output]);
        }
        catch (Exception)
        {
            // 置けなくても索引そのものは使える。次に開いたときに作り直す。
        }

        Remember(path, index, size, modified);
        return index;
    }

    /// <summary>引かれる前に、置いてある索引をほどいておく。</summary>
    public void Warm(IEnumerable<string> bookPaths)
    {
        foreach (var path in bookPaths)
        {
            _ = Cached(path);
        }
    }

    public void Discard(string bookPath)
    {
        var path = Paths.Normalize(bookPath);
        lock (_gate)
        {
            _memory.Remove(path);
        }
        try
        {
            File.Delete(Location(path));
        }
        catch (Exception)
        {
            // 無ければそれでよい。
        }
    }

    private void Remember(string path, SearchIndex index, long size, long modified)
    {
        lock (_gate)
        {
            if (_memory.Count >= MemoryLimit)
            {
                _memory.Clear();
            }
            _memory[path] = new Entry(index, size, modified);
        }
    }

    private string Location(string path) => Path.Combine(_directory, $"{Digest(path)}.idx");

    /// <summary>元ファイルの印。大きさと更新日時が変わったら、索引は当てにしない。</summary>
    private static (long Size, long Modified)? Stamp(string path)
    {
        try
        {
            var info = new FileInfo(path);
            return info.Exists
                ? (info.Length, info.LastWriteTimeUtc.ToUnixTimeSeconds())
                : null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>道を短い名前へ畳む。64 bit を 2 つ並べ、重なりは道そのものの照合で弾く。</summary>
    private static string Digest(string path)
    {
        var output = new StringBuilder();
        foreach (var seed in new ulong[] { 0xcbf2_9ce4_8422_2325, 0x9e37_79b9_7f4a_7c15 })
        {
            var hash = seed;
            unchecked
            {
                foreach (var b in Encoding.UTF8.GetBytes(path))
                {
                    hash ^= b;
                    hash *= 0x100_0000_01b3;
                }
            }
            output.Append(hash.ToString("x16"));
        }
        return output.ToString();
    }

    private static (string Path, long Size, long Modified, byte[] Payload)? Unwrap(byte[] bytes)
    {
        var head = Magic.Length + 1;
        if (bytes.Length < head || !bytes.AsSpan(0, Magic.Length).SequenceEqual(Magic)
            || bytes[Magic.Length] != Version)
        {
            return null;
        }

        var cursor = new Varint.Cursor(bytes, head);
        if (cursor.Take() is not { } path
            || cursor.Get() is not { } size
            || cursor.Get() is not { } modified
            || cursor.Rest() is not { } payload)
        {
            return null;
        }

        try
        {
            return (new UTF8Encoding(false, true).GetString(path), (long)size, (long)modified, payload);
        }
        catch (Exception)
        {
            return null;
        }
    }
}

file static class TimeExtensions
{
    internal static long ToUnixTimeSeconds(this DateTime value) =>
        new DateTimeOffset(DateTime.SpecifyKind(value, DateTimeKind.Utc)).ToUnixTimeSeconds();
}
