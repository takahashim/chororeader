using ChoroReader.Core;

namespace ChoroReader.Tests;

/// <summary>
/// 索引の置き場所と、作り直しの判断。
///
/// <para>
/// 索引は書籍から何度でも作り直せるので、消えても困らない。
/// 困るのは<b>古い索引を新しい書籍のものとして掴む</b>ことで、
/// そうなると検索が黙って取りこぼす。ここで見るのは主にそれである。
/// </para>
/// </summary>
public class SearchIndexStoreTests : IDisposable
{
    private readonly string _directory =
        Path.Combine(Path.GetTempPath(), $"choro-index-{Guid.NewGuid():N}");

    public void Dispose()
    {
        try
        {
            Directory.Delete(_directory, recursive: true);
        }
        catch (Exception)
        {
            // 消せなくても検査の結果には関わらない。
        }
        GC.SuppressFinalize(this);
    }

    private string WriteBook(string content)
    {
        Directory.CreateDirectory(_directory);
        var path = Path.Combine(_directory, $"{Guid.NewGuid():N}.txt");
        File.WriteAllText(path, content);
        return path;
    }

    [Fact]
    public void 一度作った索引は次から読み直して使う()
    {
        var book = WriteBook("なかみ");
        var store = new SearchIndexStore(_directory);

        var built = 0;
        var first = store.Ensure(book, () => { built++; return ["最初の章", "次の章"]; });
        Assert.NotNull(first);
        Assert.Equal(1, built);

        // 覚えているぶんを返す。作り直さない。
        var second = store.Ensure(book, () => { built++; return ["最初の章", "次の章"]; });
        Assert.NotNull(second);
        Assert.Equal(1, built);

        // 別の店から読み直しても、ファイルから戻せる。
        var reopened = new SearchIndexStore(_directory);
        var third = reopened.Cached(book);
        Assert.NotNull(third);
        Assert.Equal(first.UnitCount, third.UnitCount);
        Assert.Equal(first.Candidates("章"), third.Candidates("章"));
    }

    [Fact]
    public void 元ファイルが変わったら捨てる()
    {
        var book = WriteBook("なかみ");
        var store = new SearchIndexStore(_directory);
        Assert.NotNull(store.Ensure(book, () => ["最初の章"]));

        // 大きさと更新日時のどちらかが変われば、索引は当てにしない。
        File.WriteAllText(book, "なかみが変わった");
        File.SetLastWriteTimeUtc(book, DateTime.UtcNow.AddSeconds(30));

        Assert.Null(new SearchIndexStore(_directory).Cached(book));

        // 作り直すと、新しい中身のものになる。
        var built = 0;
        var again = store.Ensure(book, () => { built++; return ["別の章", "もう 1 つ"]; });
        Assert.NotNull(again);
        Assert.Equal(1, built);
        Assert.Equal(2, again.UnitCount);
    }

    [Fact]
    public void 無い書籍では何も返さない()
    {
        var store = new SearchIndexStore(_directory);
        var missing = Path.Combine(_directory, "ない本.epub");

        Assert.Null(store.Cached(missing));
        Assert.Null(store.Ensure(missing, () => throw new InvalidOperationException("呼ばれてはいけない")));
    }

    [Fact]
    public void 壊れたファイルは読まずに作り直す()
    {
        var book = WriteBook("なかみ");
        var store = new SearchIndexStore(_directory);
        Assert.NotNull(store.Ensure(book, () => ["章"]));

        // 置いてある索引を壊す。
        foreach (var file in Directory.GetFiles(_directory, "*.idx"))
        {
            File.WriteAllBytes(file, [0x00, 0x01, 0x02, 0x03, 0x04, 0x05]);
        }

        Assert.Null(new SearchIndexStore(_directory).Cached(book));
    }

    [Fact]
    public void 捨てたら次に作り直す()
    {
        var book = WriteBook("なかみ");
        var store = new SearchIndexStore(_directory);
        Assert.NotNull(store.Ensure(book, () => ["章"]));

        store.Discard(book);
        Assert.Null(store.Cached(book));

        var built = 0;
        Assert.NotNull(store.Ensure(book, () => { built++; return ["章"]; }));
        Assert.Equal(1, built);
    }
}
