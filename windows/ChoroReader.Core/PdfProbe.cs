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

    public IReadOnlyList<(int Page, string Text)> Search(string needle, int limit) =>
        _backend.Search(needle, limit);

    public byte[] RenderPage(int index, double zoom) => _backend.RenderPage(index, zoom);

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
    IReadOnlyList<(int Page, string Text)> Search(string needle, int limit);
    byte[] RenderPage(int index, double zoom);
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
