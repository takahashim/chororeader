using System.IO.Compression;

namespace ChoroReader.Core;

/// <summary>本文とその周辺リソースの供給元。EPUB は ZIP、Markdown は隣接フォルダ。</summary>
public interface IResourceProvider
{
    bool Contains(string path);
    byte[] Read(string path);
}

public static class ResourceProviders
{
    /// <summary>
    /// 文字として読む。取り出せなければ null。
    ///
    /// 書庫から取り出したバイト列は、必ず同じ規則で文字に直す必要がある
    /// （BOM、UTF-8 でない CSS）。呼ぶ側で書くと、いつか書き忘れる。
    /// </summary>
    public static string? ReadText(this IResourceProvider resources, string path)
    {
        try
        {
            return CssCompat.DecodeText(resources.Read(path));
        }
        catch (Exception)
        {
            return null;
        }
    }
}

/// <summary>
/// EPUB の中身を、展開せずに要求時だけ取り出す。
/// .NET には ZipArchive があるので、macOS 版のような自前の ZIP リーダーは要らない。
/// </summary>
public sealed class EpubArchive : IResourceProvider, IDisposable
{
    private readonly ZipArchive _archive;
    private readonly Dictionary<string, ZipArchiveEntry> _entries = new(StringComparer.Ordinal);
    private readonly Dictionary<string, ZipArchiveEntry> _lowercased = new(StringComparer.Ordinal);
    private readonly Lock _gate = new();

    public IReadOnlyCollection<string> Names => _entries.Keys;

    public EpubArchive(string path)
    {
        try
        {
            _archive = ZipFile.OpenRead(path);
        }
        catch (Exception e)
        {
            throw DocumentException.BrokenArchive(e.Message);
        }

        foreach (var entry in _archive.Entries)
        {
            // ディレクトリ項目は持たない。名前は常に "/" 区切りで扱う。
            if (entry.FullName.EndsWith('/'))
            {
                continue;
            }
            var name = Paths.Normalize(entry.FullName.Replace('\\', '/'));
            _entries[name] = entry;
            _lowercased.TryAdd(name.ToLowerInvariant(), entry);
        }

        if (_entries.Count == 0)
        {
            throw DocumentException.BrokenArchive("項目が 1 つもない");
        }
    }

    public bool Contains(string path) => Find(path) is not null;

    public byte[] Read(string path)
    {
        var entry = Find(path) ?? throw new FileNotFoundException(path);
        // ZipArchive は同時アクセスに耐えないため、取り出しは直列化する。
        lock (_gate)
        {
            using var stream = entry.Open();
            using var buffer = new MemoryStream();
            stream.CopyTo(buffer);
            return buffer.ToArray();
        }
    }

    public long CompressedLength(string path) => Find(path)?.CompressedLength ?? 0;

    /// <summary>無圧縮で格納されているか。mimetype は無圧縮という決まりがある。</summary>
    public bool IsStored(string path)
    {
        var entry = Find(path);
        return entry is not null && entry.CompressedLength == entry.Length;
    }

    private ZipArchiveEntry? Find(string path)
    {
        var normalized = Paths.Normalize(path);
        if (_entries.TryGetValue(normalized, out var entry))
        {
            return entry;
        }
        var decoded = Paths.Normalize(Paths.PercentDecode(normalized));
        if (_entries.TryGetValue(decoded, out entry))
        {
            return entry;
        }
        // 大文字小文字だけが違う参照を持つ EPUB が実在するため、最後に緩く照合する。
        return _lowercased.TryGetValue(decoded.ToLowerInvariant(), out entry) ? entry : null;
    }

    public void Dispose() => _archive.Dispose();
}

/// <summary>1 つのフォルダの下だけを供給する。Markdown の相対パス画像を解決するために使う。</summary>
public sealed class FolderResourceProvider : IResourceProvider
{
    private readonly string _root;
    private readonly Dictionary<string, byte[]> _synthetic = new(StringComparer.Ordinal);

    public FolderResourceProvider(string root) => _root = Path.GetFullPath(root);

    public void ProvideSynthetic(string path, byte[] data) => _synthetic[path] = data;

    public bool Contains(string path) =>
        _synthetic.ContainsKey(path) || (Resolve(path) is { } full && File.Exists(full));

    public byte[] Read(string path)
    {
        if (_synthetic.TryGetValue(path, out var made))
        {
            return made;
        }
        var full = Resolve(path) ?? throw new UnauthorizedAccessException(path);
        return File.ReadAllBytes(full);
    }

    /// <summary>フォルダの外を指す参照は供給しない。</summary>
    private string? Resolve(string path)
    {
        var normalized = Paths.Resolve(string.Empty, path);
        if (normalized.Length == 0)
        {
            return null;
        }
        var full = Path.GetFullPath(Path.Combine(_root, normalized.Replace('/', Path.DirectorySeparatorChar)));
        var prefix = _root.EndsWith(Path.DirectorySeparatorChar) ? _root : _root + Path.DirectorySeparatorChar;
        return full == _root || full.StartsWith(prefix, StringComparison.Ordinal) ? full : null;
    }
}
