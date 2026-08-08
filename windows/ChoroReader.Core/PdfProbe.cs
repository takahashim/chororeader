namespace ChoroReader.Core;

/// <summary>
/// PDF について、描画に踏み込まずに答えられる事実を返す。
/// 実体は MuPDF（MuPDFCore）だが、その型は外へ漏らさない。
/// 描画ライブラリを差し替えても、ここより外に影響が出ないようにするため。
/// </summary>
public static class PdfProbe
{
    static PdfProbe() => MuPdfBackend.Register();

    /// <summary>PDF として開けるか。</summary>
    public static bool CanOpen(string path)
    {
        try
        {
            using var document = PdfInspector.Open(path);
            return document.PageCount > 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
}

/// <summary>
/// 紙面の当たり。
///
/// <para>
/// <see cref="Rects"/> は描いた絵の左上を原点とする点の座標で、
/// 倍率を掛ければそのまま画素の位置になる。飛んだ先で当たりを囲むために使う。
/// </para>
/// </summary>
public sealed record PageHit(int Page, string Excerpt, IReadOnlyList<PageRect> Rects);

/// <summary>当たりを覆う長方形。ページの枠の左上を原点とする。</summary>
public readonly record struct PageRect(double X0, double Y0, double X1, double Y1);

/// <summary>
/// 描いた絵。
///
/// <para>
/// <b>寸法を絵と一緒に返す。</b>中身は素の画素の並び（RGB、1 画素 3 バイト）で、
/// それ自体は縦横を名乗らない。呼ぶ側が倍率から計算し直すと、
/// MuPDF の丸め方と食い違って絵がずれる。描いたものが知っている値をそのまま渡す。
/// </para>
/// </summary>
public sealed record RenderedPage(int Width, int Height, byte[] Pixels)
{
    /// <summary>1 行あたりのバイト数。画素は RGB の 3 バイト。</summary>
    public int Stride => Width * 3;
}

/// <summary>
/// PDF の意味情報と描画。描画結果の扱いは UI 側が決める。
///
/// <para>
/// 1 つの文書を複数のスレッドから使ってよい。描画は時間がかかるので、
/// 画面を止めないために背後のスレッドへ回すことになる。そのあいだに検索も走る。
/// 直列化は実装（<see cref="IPdfBackend"/>）が引き受ける。
/// </para>
/// </summary>
public sealed class PdfInspector : IDisposable
{
    private readonly IPdfBackend _backend;

    private PdfInspector(IPdfBackend backend) => _backend = backend;

    public static PdfInspector Open(string path)
    {
        MuPdfBackend.Register();
        return new PdfInspector(PdfBackend.Open(path));
    }

    public int PageCount => _backend.PageCount;

    /// <summary>テキスト層があるか。無い書籍は検索できないことを画面に出す。</summary>
    public bool HasTextLayer => _backend.HasTextLayer;

    public string TextOfPage(int index) => _backend.TextOfPage(index);

    /// <summary>索引に載せる本文。1 ページを 1 単位とする。</summary>
    public IReadOnlyList<string> PageTexts() =>
        Enumerable.Range(0, PageCount).Select(TextOfPage).ToList();

    public IReadOnlyList<TocEntry> Outline() => _backend.Outline();

    public IReadOnlyList<PageHit> Search(string needle, int limit) =>
        _backend.SearchWithin(needle, limit, null);

    /// <summary>
    /// <paramref name="only"/> に挙がったページだけを見る。null なら全部。
    ///
    /// <para>
    /// 索引（<see cref="SearchIndex.Candidates"/>）で絞った候補を渡すための入り口。
    /// 索引は候補を減らすだけで当たりは決めないので、絞っても絞らなくても同じ結果になる。
    /// </para>
    /// </summary>
    public IReadOnlyList<PageHit> SearchWithin(string needle, int limit, IReadOnlySet<int>? only) =>
        _backend.SearchWithin(needle, limit, only);

    /// <summary>ページを描く。倍率は 1.0 が原寸。</summary>
    public RenderedPage RenderPage(int index, double zoom) => _backend.RenderPage(index, zoom);

    public (double Width, double Height) PageSize(int index) => _backend.PageSize(index);

    public void Dispose() => _backend.Dispose();
}

/// <summary>
/// PDF の実体。
///
/// <para>
/// <b>実装は、複数のスレッドから同時に呼ばれても壊れないこと。</b>
/// 描画は背後のスレッドで走り、そのあいだに検索も走る。
/// PDF のライブラリはたいてい 1 つの文書を並行に読めないので、実装側で直列化する。
/// 返す列は、呼び出し側が反復するころには鍵が外れているため、遅延させないこと。
/// </para>
/// </summary>
internal interface IPdfBackend : IDisposable
{
    int PageCount { get; }
    bool HasTextLayer { get; }
    string TextOfPage(int index);
    IReadOnlyList<TocEntry> Outline();
    IReadOnlyList<PageHit> SearchWithin(string needle, int limit, IReadOnlySet<int>? only);
    RenderedPage RenderPage(int index, double zoom);
    (double Width, double Height) PageSize(int index);
}

/// <summary>
/// 実装の差し替え口。いまは MuPDF を使う。
/// MuPDFCore を参照していない環境（スパイク前）でもビルドできるよう、生成をここに閉じる。
/// </summary>
internal static class PdfBackend
{
    internal static Func<string, IPdfBackend>? Factory { get; set; }

    internal static IPdfBackend Open(string path) =>
        Factory is not null
            ? Factory(path)
            : throw new InvalidOperationException("PDF の実装が登録されていない");
}
