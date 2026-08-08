using ChoroReader.Core;

namespace ChoroReader.App;

/// <summary>
/// 開いている 1 冊ぶんの紙面。ページの位置と、いま強調している当たりを持つ。
///
/// <para>
/// EPUB の <see cref="BookSession"/> と対になる。あちらは読み順、こちらはページ。
/// </para>
/// </summary>
internal sealed class PdfSession : IDisposable
{
    internal PdfInspector Document { get; }

    /// <summary>いま出しているページ。</summary>
    internal int Page { get; private set; }

    /// <summary>倍率。1.0 が原寸。</summary>
    internal double Zoom { get; private set; } = 1.0;

    /// <summary>いま強調している当たり。ページを移ると引き直す。</summary>
    internal IReadOnlyList<PageHit> Hits { get; private set; } = [];

    private PdfSession(PdfInspector document) => Document = document;

    internal static PdfSession Open(string path) => new(PdfInspector.Open(path));

    internal int Count => Document.PageCount;

    /// <summary>ページを送る。端に着いていたら false。</summary>
    internal bool Move(int delta)
    {
        var next = Page + delta;
        if (next < 0 || next >= Count)
        {
            return false;
        }
        Page = next;
        return true;
    }

    internal void MoveTo(int page) => Page = Math.Clamp(page, 0, Math.Max(0, Count - 1));

    /// <summary>倍率を変える。際限なく拡げない。</summary>
    internal void ZoomBy(double factor) => Zoom = Math.Clamp(Zoom * factor, 0.25, 8.0);

    internal void ZoomTo(double zoom) => Zoom = Math.Clamp(zoom, 0.25, 8.0);

    /// <summary>
    /// 紙面を引く。索引で候補を絞ってから走査する。
    /// 索引は候補を減らすだけで当たりは決めないので、絞っても結果は変わらない。
    /// </summary>
    internal void Find(string query, SearchIndex? index)
    {
        Hits = query.Length == 0
            ? []
            : Document.SearchWithin(query, DocumentSearch.ResultLimit, index?.Candidates(query));
    }

    /// <summary>いま出しているページに乗る当たりの矩形。</summary>
    internal IReadOnlyList<PageRect> RectsOnPage =>
        Hits.FirstOrDefault(hit => hit.Page == Page)?.Rects ?? [];

    public void Dispose() => Document.Dispose();
}
