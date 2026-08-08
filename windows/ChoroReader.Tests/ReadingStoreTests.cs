using ChoroReader.Core;

namespace ChoroReader.Tests;

/// <summary>
/// 読書位置としおりと表示設定の覚え書き。
///
/// <para>
/// 索引と違って<b>書籍から作り直せない</b>。消えたら読者の手が戻らないので、
/// 失う筋を潰しておく。ここで見るのは主にそれである。
/// </para>
/// </summary>
public class ReadingStoreTests : IDisposable
{
    private readonly string _directory =
        Path.Combine(Path.GetTempPath(), $"choro-reading-{Guid.NewGuid():N}");

    private string Where => Path.Combine(_directory, "reading.json");

    private ReadingStore Open() => new(Where);

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

    [Fact]
    public void 位置を覚えて読み直せる()
    {
        var store = Open();
        store.Remember("C:/本/ある本.epub",
                       new Position { Href = "OEBPS/text/ch02.xhtml", Progression = 0.42, Text = "第 2 章" });

        // 開き直しても残っていること。書き出しは同じ経路で読める。
        var again = Open().StateOf("C:/本/ある本.epub");
        Assert.Equal("OEBPS/text/ch02.xhtml", again.Position.Href);
        Assert.Equal(0.42, again.Position.Progression);
        Assert.Equal("第 2 章", again.Position.Text);
    }

    [Fact]
    public void 覚えのない本では空を返す()
    {
        var state = Open().StateOf("C:/本/開いたことのない本.epub");

        Assert.Equal(string.Empty, state.Position.Href);
        Assert.Equal(0, state.Position.Progression);
        Assert.Empty(state.Bookmarks);
    }

    /// <summary>
    /// 経路によって分解形（NFD）と合成形（NFC）のどちらも来る。
    /// そのまま鍵にすると、同じ本が二重に並ぶ。
    /// </summary>
    [Fact]
    public void 濁点の形が違っても同じ本として扱う()
    {
        // 「が」を 2 通りで書く。指す先は同じ本である。
        var composed = "C:/本/がっこう.epub";
        var decomposed = "C:/本/\u304B\u3099っこう.epub";
        Assert.NotEqual(composed, decomposed);

        var store = Open();
        store.Remember(composed, new Position { Href = "ch01.xhtml", Progression = 0.5 });

        Assert.Equal("ch01.xhtml", store.StateOf(decomposed).Position.Href);
        Assert.Single(store.Library());
    }

    [Fact]
    public void しおりを付けて外せる()
    {
        var store = Open();
        var mark = new Bookmark { Href = "ch01.xhtml", Progression = 0.25, Label = "ここ" };

        Assert.Single(store.ToggleBookmark("本.epub", mark));
        // 同じ場所をもう一度押したら外れる。
        Assert.Empty(store.ToggleBookmark("本.epub", mark));

        // 別の場所は別のしおりとして積む。
        store.ToggleBookmark("本.epub", mark);
        store.ToggleBookmark("本.epub", mark with { Progression = 0.75 });
        Assert.Equal(2, Open().StateOf("本.epub").Bookmarks.Count);
    }

    [Fact]
    public void 表示設定を覚えて読み直せる()
    {
        var store = Open();
        store.SaveSettings(new ReaderStyle { FontSizePercent = 120, Theme = ReaderTheme.Dark, CodeWrap = true });

        var again = Open().Settings;
        Assert.Equal(120, again.FontSizePercent);
        Assert.Equal(ReaderTheme.Dark, again.Theme);
        Assert.True(again.CodeWrap);
    }

    [Fact]
    public void 書棚から外せる()
    {
        var store = Open();
        store.Remember("消す本.epub", new Position { Href = "ch01.xhtml" });
        Assert.Single(store.Library());

        store.Forget("消す本.epub");
        Assert.Empty(store.Library());
        Assert.Empty(Open().StateOf("消す本.epub").Position.Href);
    }

    /// <summary>
    /// 壊れた JSON で起動できなくなるほうが困る。黙って捨てて、空から始める。
    /// </summary>
    [Fact]
    public void 壊れていたら空から始める()
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(Where, "{ これは JSON ではない");

        var store = Open();
        Assert.Empty(store.Library());

        // 書き直せること。壊れたまま固まらない。
        store.Remember("本.epub", new Position { Href = "ch01.xhtml" });
        Assert.Equal("ch01.xhtml", Open().StateOf("本.epub").Position.Href);
    }

    /// <summary>
    /// 書いている最中に落ちても、前の中身が残っていること。
    /// 半端な JSON を置くと、次の起動で覚え書きを全部失う。
    /// </summary>
    [Fact]
    public void 書き換えの途中で落ちても前の中身が残る()
    {
        var store = Open();
        store.Remember("本.epub", new Position { Href = "ch01.xhtml" });

        // 隣に半端なものが残っていても、本体は読める。
        File.WriteAllText(Where + ".new", "{ 途中で落ちた");
        Assert.Equal("ch01.xhtml", Open().StateOf("本.epub").Position.Href);
    }

    [Fact]
    public void 並行に書いても壊れない()
    {
        var store = Open();

        Parallel.For(0, 8, worker =>
        {
            for (var i = 0; i < 20; i++)
            {
                store.Remember($"本{worker}.epub", new Position { Href = $"ch{i:00}.xhtml", Progression = i / 20.0 });
            }
        });

        // 8 冊とも残り、読み直せること。
        Assert.Equal(8, store.Library().Count);
        Assert.Equal(8, Open().Library().Count);
    }
}
