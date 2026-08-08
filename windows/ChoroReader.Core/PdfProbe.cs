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

/// <summary>PDF の意味情報と描画。描画結果の扱いは UI 側が決める。</summary>
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

    public IReadOnlyList<TocEntry> Outline() => _backend.Outline();

    public IEnumerable<(int Page, string Text)> Search(string needle, int limit) =>
        _backend.Search(needle, limit);

    public byte[] RenderPage(int index, double zoom) => _backend.RenderPage(index, zoom);

    public (double Width, double Height) PageSize(int index) => _backend.PageSize(index);

    public void Dispose() => _backend.Dispose();
}

internal interface IPdfBackend : IDisposable
{
    int PageCount { get; }
    bool HasTextLayer { get; }
    string TextOfPage(int index);
    IReadOnlyList<TocEntry> Outline();
    IEnumerable<(int Page, string Text)> Search(string needle, int limit);
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
