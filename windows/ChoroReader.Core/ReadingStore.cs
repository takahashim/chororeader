using System.Text.Json;
using System.Text.Json.Serialization;

namespace ChoroReader.Core;

/// <summary>
/// どこまで読んだか。
///
/// <para>
/// <see cref="Text"/> は前にいた場所の書き出しである。
/// 文字サイズや窓の幅を変えると割合はずれるので、文字を手掛かりに戻れるようにしておく。
/// </para>
/// </summary>
public sealed record Position
{
    /// <summary>EPUB は章の経路、PDF は空。</summary>
    public string Href { get; init; } = string.Empty;

    /// <summary>章やページの中でどこまで読んだか。0 から 1。</summary>
    public double Progression { get; init; }

    /// <summary>PDF のページ番号。</summary>
    public int Page { get; init; }

    /// <summary>章の中の飛び先。あればここへ戻る。</summary>
    public string Fragment { get; init; } = string.Empty;

    public string Text { get; init; } = string.Empty;
}

/// <summary>しおり。付けたときの書き出しを添える（<see cref="Position"/> と同じ理由）。</summary>
public sealed record Bookmark
{
    public string Href { get; init; } = string.Empty;
    public double Progression { get; init; }
    public int Page { get; init; }
    public string Label { get; init; } = string.Empty;
    public string Text { get; init; } = string.Empty;
}

/// <summary>1 冊ぶんの覚え書き。</summary>
public sealed record BookState
{
    public Position Position { get; init; } = new();
    public IReadOnlyList<Bookmark> Bookmarks { get; init; } = [];

    /// <summary>書棚に並べるときの題名。開かずに出せるよう控えておく。</summary>
    public string Title { get; init; } = string.Empty;
}

/// <summary>
/// 読書位置としおりと表示設定を残す。
///
/// <para>
/// <b>書籍そのものには触れない。</b>設定の置き場所へ JSON 1 枚を書き、
/// 書籍の経路を鍵にする。読書中にネットワークを使わない不変条件があるので、同期は持たない。
/// </para>
/// <para>
/// 画面に依らない。窓はここを呼ぶだけにするので、macOS でも検査できる。
/// </para>
/// </summary>
public sealed class ReadingStore
{
    private sealed record Snapshot
    {
        public Dictionary<string, BookState> Books { get; init; } = new(StringComparer.Ordinal);
        public ReaderStyle Settings { get; init; } = new();
    }

    private static readonly JsonSerializerOptions Format = new()
    {
        WriteIndented = true,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingDefault,
    };

    private readonly string _path;
    private readonly Lock _gate = new();
    private Snapshot _state = new();

    public ReadingStore(string path)
    {
        _path = path;
        Directory.CreateDirectory(Path.GetDirectoryName(path) ?? ".");
        Load();
    }

    /// <summary>既定の置き場所。書籍そのものの隣には置かない（元ファイルを汚さない）。</summary>
    public static ReadingStore Default() => new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "ChoroReader",
        "reading.json"));

    /// <summary>
    /// 書籍の経路を鍵にするときの形。
    ///
    /// <para>
    /// 経路によって分解形（NFD）と合成形（NFC）のどちらも来る。
    /// そのまま鍵にすると、同じ本が二重に並ぶ。
    /// </para>
    /// </summary>
    private static string KeyOf(string path) => Paths.Normalize(path);

    public BookState StateOf(string bookPath)
    {
        lock (_gate)
        {
            return _state.Books.TryGetValue(KeyOf(bookPath), out var found) ? found : new BookState();
        }
    }

    /// <summary>並んでいる蔵書。経路と覚え書きの組。</summary>
    public IReadOnlyList<(string Path, BookState State)> Library()
    {
        lock (_gate)
        {
            return _state.Books.Select(pair => (pair.Key, pair.Value)).ToList();
        }
    }

    public void Remember(string bookPath, Position position) =>
        Update(bookPath, state => state with { Position = position });

    public void RememberTitle(string bookPath, string title) =>
        Update(bookPath, state => state with { Title = title });

    /// <summary>しおりを付け外しする。同じ場所を指すものがあれば外す。</summary>
    public IReadOnlyList<Bookmark> ToggleBookmark(string bookPath, Bookmark bookmark)
    {
        IReadOnlyList<Bookmark> after = [];
        Update(bookPath, state =>
        {
            var same = state.Bookmarks.FirstOrDefault(
                b => b.Href == bookmark.Href && b.Page == bookmark.Page
                     && Math.Abs(b.Progression - bookmark.Progression) < 0.0005);
            after = same is null
                ? [.. state.Bookmarks, bookmark]
                : state.Bookmarks.Where(b => b != same).ToList();
            return state with { Bookmarks = after };
        });
        return after;
    }

    public void Forget(string bookPath)
    {
        lock (_gate)
        {
            _state.Books.Remove(KeyOf(bookPath));
            Save();
        }
    }

    public ReaderStyle Settings
    {
        get { lock (_gate) { return _state.Settings; } }
    }

    public void SaveSettings(ReaderStyle settings)
    {
        lock (_gate)
        {
            _state = _state with { Settings = settings };
            Save();
        }
    }

    private void Update(string bookPath, Func<BookState, BookState> change)
    {
        lock (_gate)
        {
            var key = KeyOf(bookPath);
            _state.Books.TryGetValue(key, out var before);
            _state.Books[key] = change(before ?? new BookState());
            Save();
        }
    }

    // MARK: 置き場所

    /// <summary>
    /// 読み込む。読めなければ空から始める。
    ///
    /// <para>
    /// 覚え書きは書籍から作り直せないが、<b>失われても読書は続けられる</b>。
    /// 壊れた JSON で起動できなくなるほうが困るので、黙って捨てる。
    /// </para>
    /// </summary>
    private void Load()
    {
        try
        {
            if (File.Exists(_path))
            {
                _state = JsonSerializer.Deserialize<Snapshot>(File.ReadAllText(_path), Format) ?? new Snapshot();
            }
        }
        catch (Exception)
        {
            _state = new Snapshot();
        }
    }

    /// <summary>
    /// 書き出す。呼ぶ側が鍵を持っていること。
    ///
    /// <para>
    /// <b>いったん隣へ書いてから置き換える。</b>書いている最中に落ちると、
    /// 半端な JSON が残って次の起動で全部失う。
    /// </para>
    /// </summary>
    private void Save()
    {
        var temporary = _path + ".new";
        try
        {
            File.WriteAllText(temporary, JsonSerializer.Serialize(_state, Format));
            File.Move(temporary, _path, overwrite: true);
        }
        catch (Exception)
        {
            // 置けなくても読書は続けられる。次の折に書き直す。
            try
            {
                File.Delete(temporary);
            }
            catch (Exception)
            {
                // 消せなくてもよい。
            }
        }
    }
}
