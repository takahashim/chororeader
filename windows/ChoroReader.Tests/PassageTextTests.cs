using System.IO.Compression;
using ChoroReader.Core;

namespace ChoroReader.Tests;

/// <summary>
/// 当たった段落の本文を、原書から切り出す。
///
/// <para>
/// <b>切り出す場所は位置で決め、目印は答え合わせに使う。</b>
/// 目印だけで探すと、<b>繰り返しの多い本文</b>（箇条書き、定型の言い回し、
/// 同じ説明の続く節）で手前の同じ並びに当たる（spec-local-ai.md 4.2）。
/// </para>
/// <para>
/// 外しても例外は出ない。<b>それらしい本文が別の場所から出てくるだけ</b>なので、
/// 使ってみて気付くことができない。ここが唯一の防壁である。
/// </para>
/// </summary>
public class PassageTextTests : IDisposable
{
    private readonly string _root =
        Path.Combine(Path.GetTempPath(), $"choro-passage-{Guid.NewGuid():N}");

    public PassageTextTests() => Directory.CreateDirectory(_root);

    public void Dispose()
    {
        try
        {
            Directory.Delete(_root, recursive: true);
        }
        catch (Exception)
        {
            // 消せなくても検査の結果には関わらない。
        }
        GC.SuppressFinalize(this);
    }

    /// <summary>1 章だけの EPUB を置く。本文はそのまま指定したものになる。</summary>
    private string Book(string body)
    {
        var where = Path.Combine(_root, $"{Guid.NewGuid():N}.epub");
        File.Copy(Path.Combine(TestPaths.Samples, "sample-reflowable.epub"), where, overwrite: true);
        using (var zip = ZipFile.Open(where, ZipArchiveMode.Update))
        {
            for (var at = 1; at <= 3; at++)
            {
                var path = $"OEBPS/text/ch{at:00}.xhtml";
                zip.GetEntry(path)?.Delete();
                using var writer = new StreamWriter(zip.CreateEntry(path).Open());
                writer.Write($"""
                    <?xml version="1.0" encoding="UTF-8"?>
                    <html xmlns="http://www.w3.org/1999/xhtml"><body><p>{(at == 1 ? body : "")}</p></body></html>
                    """);
            }
        }
        return where;
    }

    private static SemanticUnit At(double progression, string? anchor) => new()
    {
        Locator = new Locator { Href = "OEBPS/text/ch01.xhtml", Progression = progression, Text = anchor },
        Heading = "節",
        Section = 0,
    };

    /// <summary>
    /// <b>繰り返しの本文で手前に寄らない。</b>
    ///
    /// <para>
    /// 同じ目印が 2 度出る本文を作り、位置で 2 つ目を指す。位置を見ずに目印だけで探すと、
    /// 1 つ目が当たって<b>前の段落の本文が出る</b>。
    /// </para>
    /// </summary>
    [Fact]
    public void 繰り返しの本文で位置の近い方を採る()
    {
        // 「あ」100 ＋ 目印 ＋「い」100 ＋ 目印 ＋「う」100。
        const string mark = "めじるし";
        var body = new string('あ', 100) + mark + new string('い', 100) + mark + new string('う', 100);
        var book = Book(body);

        // 2 つ目の目印は 204 文字目。全体は 208 文字。
        var second = 100 + mark.Length + 100;
        var units = new[] { At((double)second / body.Length, mark) };

        var made = PassageText.Read(units, book, limit: 60);

        Assert.True(made.TryGetValue(0, out var text), "切り出せていない");
        Assert.StartsWith(mark, text);
        // 2 つ目の目印の後ろは「う」である。1 つ目を採ると「い」が続く。
        Assert.Contains('う', text);
        Assert.DoesNotContain('い', text);
    }

    /// <summary>位置の先が目印と合っていれば、そこが答え。探し直さない。</summary>
    [Fact]
    public void 位置と目印が合えばそこを採る()
    {
        var body = new string('あ', 50) + "ここから" + new string('か', 50);
        var book = Book(body);

        var made = PassageText.Read([At(50.0 / body.Length, "ここから")], book, limit: 20);

        Assert.StartsWith("ここから", made[0]);
    }

    /// <summary>
    /// <b>位置がずれていたら、目印が引き戻す。</b>
    ///
    /// <para>
    /// 位置は索引を作ったときの本文の長さで測っている。読み直したときの本文と
    /// 空白の詰め方などで数文字ずれることがあるので、目印で寄せ直す。
    /// これが目印の役目であって、位置がぴたり合っている限り出番は無い。
    /// </para>
    /// </summary>
    [Fact]
    public void 位置がずれていたら目印で寄せ直す()
    {
        const string mark = "めじるし";
        var body = new string('あ', 100) + mark + new string('い', 100);
        var book = Book(body);

        // 本当は 100 文字目だが、8 文字ぶんずれた位置を渡す。
        var made = PassageText.Read([At(108.0 / body.Length, mark)], book, limit: 20);

        Assert.StartsWith(mark, made[0]);
    }

    /// <summary>目印が無ければ位置だけで決める。目印は答え合わせであって、必須ではない。</summary>
    [Fact]
    public void 目印が無ければ位置で決める()
    {
        var body = new string('あ', 100) + new string('か', 100);
        var book = Book(body);

        var made = PassageText.Read([At(0.5, null)], book, limit: 20);

        Assert.Equal(new string('か', 20) + "…", made[0]);
    }

    /// <summary>長い段落は切り、切ったことが分かるようにする。</summary>
    [Fact]
    public void 長ければ切って印を付ける()
    {
        var book = Book(new string('あ', 500));

        var made = PassageText.Read([At(0, null)], book, limit: 100);

        Assert.Equal(101, made[0].Length);
        Assert.EndsWith("…", made[0]);
    }

    /// <summary>
    /// <b>書籍は 1 度だけ開く。</b>同じ章を指す単位が並んでも、章の取り出しは 1 度で足りる。
    /// 返すのは<b>渡した並びの番号</b>で引ける形にする（単位そのものを鍵にすると重なる）。
    /// </summary>
    [Fact]
    public void 同じ章を指す単位を取りこぼさない()
    {
        var body = new string('あ', 100) + new string('か', 100) + new string('さ', 100);
        var book = Book(body);

        // まったく同じ内容の単位を 2 つ。鍵にすると重なって 1 つになる。
        var made = PassageText.Read([At(0, null), At(0, null), At(2.0 / 3, null)], book, limit: 10);

        Assert.Equal(3, made.Count);
        // 後ろが残っているので「…」が付く。段落の終わりでは止まらない。
        Assert.Equal(new string('あ', 10) + "…", made[0]);
        Assert.Equal(new string('あ', 10) + "…", made[1]);
        Assert.Equal(new string('さ', 10) + "…", made[2]);
    }

    [Fact]
    public void 読めない書籍では何も返さない()
    {
        var broken = Path.Combine(_root, "壊れた本.epub");
        File.WriteAllText(broken, "これは EPUB ではない");

        Assert.Empty(PassageText.Read([At(0, null)], broken));
        Assert.Empty(PassageText.Read([], Book("あ")));
    }
}
