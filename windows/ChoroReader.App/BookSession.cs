using ChoroReader.Core;

namespace ChoroReader.App;

/// <summary>
/// 開いている 1 冊ぶんの持ち物。書庫・書誌・配信と、いま読んでいるところ。
///
/// <para>
/// 窓が閉じたら捨てる。同じ書籍を複数の窓で開くときは、いまは窓ごとに持つ。
/// 書籍単位の共有層（spec.md 4.3）は、しおりと読書位置を入れる段で作る。
/// </para>
/// </summary>
internal sealed class BookSession : IDisposable
{
    private readonly EpubArchive _archive;

    internal EpubPublication Publication { get; }

    internal ResourceDelivery Delivery { get; }

    /// <summary>いま開いている読み順の位置。</summary>
    internal int Index { get; private set; }

    private BookSession(EpubArchive archive, EpubPublication publication)
    {
        _archive = archive;
        Publication = publication;
        Delivery = new ResourceDelivery(archive);
    }

    internal static BookSession Open(string path)
    {
        var archive = new EpubArchive(path);
        try
        {
            return new BookSession(archive, EpubParser.Parse(archive));
        }
        catch (Exception)
        {
            archive.Dispose();
            throw;
        }
    }

    internal int Count => Publication.ReadingOrder.Count;

    internal string HrefAt(int index) => Publication.ReadingOrder[Math.Clamp(index, 0, Count - 1)].Href;

    internal string TitleAt(int index)
    {
        var href = HrefAt(index);
        return Publication.TitleForHref(href) ?? Paths.LastComponent(href);
    }

    /// <summary>読み順を動かす。端に着いていたら false（呼ぶ側が知らせを出す）。</summary>
    internal bool Move(int delta)
    {
        var next = Index + delta;
        if (next < 0 || next >= Count)
        {
            return false;
        }
        Index = next;
        return true;
    }

    internal void MoveTo(int index) => Index = Math.Clamp(index, 0, Count - 1);

    public void Dispose() => _archive.Dispose();
}
