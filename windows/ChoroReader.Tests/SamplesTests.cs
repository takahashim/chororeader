using ChoroReader.Core;

namespace ChoroReader.Tests;

/// <summary>
/// 同梱の見本書籍。
///
/// <para>
/// 書籍を 1 冊も持たないマシンでも読み方を確かめられるように埋め込んである。
/// <b>埋め込みは黙って外れる。</b>csproj の書き方を変えたときや、見本の名前を変えたときに、
/// 実行するまで気付けない。ここで縛っておく。
/// </para>
/// <para>
/// このテストは ChoroReader.App を参照しないので、資源そのものではなく
/// <b>元のファイル</b>を見る。埋め込みが外れていないことは、App の動作確認が見る。
/// </para>
/// </summary>
public class SamplesTests
{
    /// <summary>App が埋め込んでいるのと同じ 3 つ。名前を変えたら両方を直す。</summary>
    private static readonly string[] Names =
    [
        "sample-reflowable.epub",
        "sample-fixed.epub",
        "sample.pdf",
    ];

    private static string Where(string name) => Path.Combine(TestPaths.Samples, name);

    [Fact]
    public void 見本が揃っている()
    {
        Assert.All(Names, name => Assert.True(File.Exists(Where(name)), $"{name} がありません"));
    }

    /// <summary>
    /// 見本は 3 つとも形式が違う。読み方の違いを確かめるためのものなので、
    /// どれかが同じ形式になっていたら見本の役を果たさない。
    /// </summary>
    [Fact]
    public void 三つとも別の読み方になる()
    {
        using var reflowable = new EpubArchive(Where("sample-reflowable.epub"));
        Assert.Equal(PublicationLayout.Reflowable, EpubParser.Parse(reflowable).Layout);

        using var fixedLayout = new EpubArchive(Where("sample-fixed.epub"));
        Assert.Equal(PublicationLayout.Fixed, EpubParser.Parse(fixedLayout).Layout);

        Assert.Equal(DocumentFormat.Pdf, DocumentFormats.Detect(Where("sample.pdf")));
    }

    /// <summary>見本は読めること。開けるだけでなく、本文と紙面が取り出せること。</summary>
    [Fact]
    public void 見本は読める()
    {
        using var archive = new EpubArchive(Where("sample-reflowable.epub"));
        var publication = EpubParser.Parse(archive);
        Assert.NotEmpty(publication.ReadingOrder);
        Assert.NotEmpty(SearchUnits.OfEpub(archive, publication).Where(t => t.Trim().Length > 0));

        using var paper = PdfInspector.Open(Where("sample.pdf"));
        Assert.True(paper.PageCount > 0);
        Assert.True(paper.HasTextLayer, "見本の PDF に文字の層が無いと、検索を試せない");
    }

    /// <summary>実行ファイルへ埋め込むので、大きくなりすぎないこと。</summary>
    [Fact]
    public void 見本は小さい()
    {
        var total = Names.Sum(name => new FileInfo(Where(name)).Length);
        Assert.True(total < 512 * 1024, $"見本が {total / 1024} KB ある。埋め込むには大きい");
    }
}
