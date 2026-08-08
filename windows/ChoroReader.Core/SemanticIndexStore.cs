using System.Security.Cryptography;
using System.Text;

namespace ChoroReader.Core;

/// <summary>索引づくりの進み具合。何分もかかるので、見せられるようにする。</summary>
public readonly record struct SemanticProgress(int Done, int Total);

/// <summary>
/// 意味の索引の置き場所と、作り直しの判断。
///
/// <para>
/// 二字組索引（<see cref="SearchIndexStore"/>）と同じ場所・同じ考え方である
/// （spec-local-ai.md 4.3）。書籍そのものから何度でも作り直せるので、消えても困らない。
/// </para>
/// <para>
/// <b>失効の鍵にモデルの名前が足してある。</b>ファイルの大きさと更新日時だけだと、
/// モデルを入れ替えたときに古いベクトルをそのまま使い続け、
/// 見た目は何も変わらないまま順位だけが狂う。
/// </para>
/// <para>
/// <b>鍵は 1 枚の頭で見る。</b>中身をほどく前に落とせるので、
/// モデルを入れ替えた直後に置き場所を無駄に読まずに済む。
/// 以前は大きさと更新日時を頭で、モデルの名前を中身の側で持っていた。
/// 鍵が 2 層に散っていると、片方だけ見て通す事故になる。
/// </para>
/// </summary>
public sealed class SemanticIndexStore
{
    /// <summary>
    /// 索引ファイルの頭の版。
    ///
    /// <para>
    /// 版 6：引くものと当たってから要るものを分けた。文字列は表で 1 度だけ書き、
    /// ベクトルは fp16 のまま持つ。モデルの入れ替え検査は頭だけで済む。
    /// 版を上げないと、古いものを新しい読み方で解いて崩れる。
    /// </para>
    /// </summary>
    private const byte Version = 6;

    private static ReadOnlySpan<byte> Magic => "CHVB"u8;

    /// <summary>頭を読むのに要る量。ここだけ読めば失効を判じられる。</summary>
    private const int HeadBytes = 512;

    /// <summary>
    /// 抱え込む上限（バイト）。ベクトルは fp16 のまま持つので、置いてある形とほぼ同じ量で数える。
    /// fp32 に広げて持っていた頃の倍の冊数を、同じ上限で抱えられる。
    /// </summary>
    private const long MemoryLimit = 64L * 1024 * 1024;

    private readonly string _directory;
    private readonly Lock _gate = new();
    private readonly Dictionary<string, Held> _memory = new(StringComparer.Ordinal);
    private long _held;

    private sealed record Held(SemanticIndex Index, ulong Size, ulong Modified, long Cost);

    public SemanticIndexStore(string directory)
    {
        _directory = directory;
        Directory.CreateDirectory(_directory);
    }

    /// <summary>既定の置き場所。書籍そのものの隣には置かない（元ファイルを汚さない）。</summary>
    public static SemanticIndexStore Default() => new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "ChoroReader",
        "semantic"));

    // MARK: 取り出し

    /// <summary>
    /// 置いてあるものだけを返す。無くても作らない。
    ///
    /// <para>
    /// 作るのは何分もかかる仕事なので、引く側の都合で始めない（spec-local-ai.md 4.4）。
    /// </para>
    /// </summary>
    public SemanticIndex? Cached(string bookPath, string model)
    {
        var key = Paths.Normalize(bookPath);
        if (Stamp(bookPath) is not { } stamp)
        {
            return null;
        }
        var (size, modified) = stamp;

        lock (_gate)
        {
            if (_memory.TryGetValue(key, out var found)
                && found.Size == size && found.Modified == modified && found.Index.Model == model)
            {
                return found.Index;
            }
        }

        // mmap は使わない。試したら冷えた読み込みが倍に伸びた（198 → 435 ms／500 冊）。
        // どうせベクトルは自前の並びへ写し取るので、頁例外を 1 冊 40 回払うより
        // 順に 1 回で読む方が安い。
        byte[] data;
        try
        {
            data = File.ReadAllBytes(Where(bookPath));
        }
        catch (Exception)
        {
            return null;
        }

        if (Head.Of(data) is not { } head
            || head.Size != size || head.Modified != modified || head.Model != model
            || SemanticIndex.Decode(data, head.Cursor, model) is not { } index)
        {
            return null;
        }

        Remember(key, index, size, modified);
        return index;
    }

    public bool Has(string bookPath, string model) => Cached(bookPath, model) is not null;

    /// <summary>
    /// 置いてあるものが、どのモデルで作られたか。無ければ null。
    ///
    /// <para>
    /// <b>頭だけ読む。</b>版が上がったときに何冊作り直すのかを数えるのに使うので、
    /// 蔵書ぶん呼ばれる。中身（数十 MB）まで読むわけにいかない。
    /// </para>
    /// </summary>
    public string? RecordedModel(string bookPath)
    {
        try
        {
            using var file = File.OpenRead(Where(bookPath));
            var head = new byte[HeadBytes];
            var read = file.ReadAtLeast(head, head.Length, throwOnEndOfStream: false);
            return Head.Of(head.AsSpan(0, read).ToArray())?.Model;
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>
    /// 置いてあるが、いまのモデルとは版が違うもの。
    ///
    /// <para>
    /// 「まだ作っていない」のと「作ったが版が変わった」のは、人にとって違う。
    /// 前者は待てば済むが、後者は<b>全量が作り直しになる</b>（spec-local-ai.md 4.4）。
    /// </para>
    /// </summary>
    public bool IsStale(string bookPath, string model) =>
        RecordedModel(bookPath) is { } recorded && recorded != model;

    /// <summary>置いてあるものの大きさ。無ければ null。</summary>
    public long? SizeOnDisk(string bookPath)
    {
        var file = new FileInfo(Where(bookPath));
        return file.Exists ? file.Length : null;
    }

    /// <summary>ほどいたものを全部忘れる。<b>冷えた状態から測るために要る。</b></summary>
    public void ForgetMemory()
    {
        lock (_gate)
        {
            _memory.Clear();
            _held = 0;
        }
    }

    public void Discard(string bookPath)
    {
        try
        {
            File.Delete(Where(bookPath));
        }
        catch (Exception)
        {
            // 消せなくても、頭の鍵が合わなくなるので読み直されない。
        }
        lock (_gate)
        {
            if (_memory.Remove(Paths.Normalize(bookPath), out var gone))
            {
                _held -= gone.Cost;
            }
        }
    }

    // MARK: 作る

    /// <summary>
    /// 書籍 1 冊ぶんを作って置く。
    ///
    /// <para>
    /// <b>画面のスレッドから呼んではいけない。</b>書籍を丸ごと読み、段落ごとに推論を回すので、
    /// 1 冊で数十秒かかることがある。
    /// </para>
    /// <para>
    /// <paramref name="cancel"/> で降りたら<b>書きかけは置かない</b>。
    /// 半端なものを置くと、次に開いたときに「作ってある」ことになる。
    /// </para>
    /// </summary>
    public SemanticIndex? Build(
        string bookPath, IReadOnlyList<SemanticPiece> pieces, IEmbedder embedder, string model,
        Action<SemanticProgress>? progress = null, CancellationToken cancel = default)
    {
        if (pieces.Count == 0)
        {
            return null;
        }

        var units = new List<SemanticUnit>(pieces.Count);
        var vectors = new float[pieces.Count * embedder.Dimension];
        var truncated = 0;

        for (var at = 0; at < pieces.Count; at++)
        {
            if (cancel.IsCancellationRequested)
            {
                return null;
            }
            var piece = pieces[at];
            // 見出しを頭に付ける。節の途中だけを見ても何の話か分かるようにする。
            var body = piece.Unit.Heading.Length == 0
                ? piece.Text
                : piece.Unit.Heading + "。" + piece.Text;

            var made = embedder.Embed(body, EmbeddingKind.Document);
            if (made.Vector.Length != embedder.Dimension)
            {
                throw new DocumentException("embedderMismatch",
                    $"埋め込みの長さが違う: {made.Vector.Length} ≠ {embedder.Dimension}");
            }
            if (made.Truncated)
            {
                truncated++;
            }
            units.Add(piece.Unit);
            made.Vector.CopyTo(vectors.AsSpan(at * embedder.Dimension));
            progress?.Invoke(new SemanticProgress(at + 1, pieces.Count));
        }

        var index = new SemanticIndex(model, embedder.Dimension, units, vectors, truncated);
        Store(bookPath, index);
        return index;
    }

    /// <summary>作らずに置く。索引づくりを通さずに置きたいとき（規模の測定など）に使う。</summary>
    public void Store(string bookPath, SemanticIndex index)
    {
        if (Stamp(bookPath) is not { } stamp)
        {
            return;
        }
        var (size, modified) = stamp;

        var out_ = new List<byte>();
        out_.AddRange(new Head(size, modified, index.Model).Encode());
        out_.AddRange(index.Encode());

        // **いったん隣へ書いてから置き換える。** 書いている最中に落ちると、
        // 半端なものが残って「作ってある」ことになる。
        var where = Where(bookPath);
        var temporary = where + ".new";
        try
        {
            File.WriteAllBytes(temporary, [.. out_]);
            File.Move(temporary, where, overwrite: true);
        }
        catch (Exception)
        {
            try
            {
                File.Delete(temporary);
            }
            catch (Exception)
            {
                // 消せなくてもよい。頭の鍵が合わないので読まれない。
            }
            return;
        }

        Remember(Paths.Normalize(bookPath), index, size, modified);
    }

    // MARK: 置き場所

    private string Where(string bookPath)
    {
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(Paths.Normalize(bookPath)));
        return Path.Combine(_directory, Convert.ToHexStringLower(digest) + ".vec");
    }

    private static (ulong Size, ulong Modified)? Stamp(string bookPath)
    {
        var file = new FileInfo(bookPath);
        if (!file.Exists)
        {
            return null;
        }
        return ((ulong)file.Length,
                (ulong)Math.Max(0, new DateTimeOffset(file.LastWriteTimeUtc).ToUnixTimeSeconds()));
    }

    /// <summary>
    /// ほどいたものを抱える。上限を越えたら<b>一度捨てて入れ直す</b>。
    ///
    /// <para>
    /// 二字組索引と同じ作法である。どれを捨てるかを選ぶ仕掛けは持たない。
    /// 索引は書籍から作り直せるので、取りこぼしても読み直すだけで済む。
    /// </para>
    /// </summary>
    private void Remember(string key, SemanticIndex index, ulong size, ulong modified)
    {
        var cost = (long)index.Count * index.Dimension * 2;
        lock (_gate)
        {
            if (_memory.Remove(key, out var gone))
            {
                _held -= gone.Cost;
            }
            if (_held + cost > MemoryLimit)
            {
                _memory.Clear();
                _held = 0;
            }
            _memory[key] = new Held(index, size, modified, cost);
            _held += cost;
        }
    }

    /// <summary>
    /// 索引ファイルの頭。<b>失効の鍵をここに全部置く。</b>
    /// </summary>
    private readonly record struct Head(ulong Size, ulong Modified, string Model)
    {
        /// <summary>中身の始まる位置。</summary>
        public int Cursor { get; private init; }

        public static Head? Of(byte[] data)
        {
            if (data.Length < 5 || !data.AsSpan(0, 4).SequenceEqual(Magic) || data[4] != Version)
            {
                return null;
            }
            var reader = new Varint.Cursor(data, 5);
            if (reader.Get() is not { } size || reader.Get() is not { } modified
                || reader.Take() is not { } model)
            {
                return null;
            }
            return new Head(size, modified, Encoding.UTF8.GetString(model)) { Cursor = reader.At };
        }

        public byte[] Encode()
        {
            var out_ = new List<byte>();
            out_.AddRange(Magic);
            out_.Add(Version);
            Varint.Put(out_, Size);
            Varint.Put(out_, Modified);
            Varint.PutBytes(out_, Encoding.UTF8.GetBytes(Model));
            return [.. out_];
        }
    }
}
