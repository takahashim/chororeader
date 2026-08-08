namespace ChoroReader.Core;

/// <summary>1 冊ぶんの当たり。</summary>
/// <param name="Truncated">
/// 上限で打ち切ったか。打ち切ったときは、その本を開いて全件を見る道を出す。
/// </param>
public sealed record BookHits(
    string Path,
    string Title,
    IReadOnlyList<LibraryHit> Hits,
    bool Truncated);

/// <summary>
/// 蔵書を横断して引いたときの、1 件の当たり。
///
/// <para>
/// EPUB と PDF で当たりの形が違うので、画面が要るものだけを揃えて持つ。
/// EPUB は章の経路と章内の通し番号、PDF はページ番号で、飛び先が決まる。
/// </para>
/// </summary>
public sealed record LibraryHit(string Where, string Excerpt, string? Href, int? Page, int Nth);

/// <summary>
/// 書棚にある書籍を横断して引く（spec.md 10.4）。
///
/// <para>
/// 1 冊ずつ索引で候補を絞り、残った章（PDF ならページ）だけを走査し直す。
/// <b>索引は候補を減らすだけ</b>なので、当たりは 1 冊ずつ開いて引いたときと変わらない。
/// </para>
/// <para>
/// 索引がまだ無い書籍はその場で作る。1 冊目は書籍を丸ごと読むぶん遅いが、
/// 2 度目からは索引だけで済む。<b>1 冊ずつ返す</b>ので、待たされている間も手は止まらない。
/// </para>
/// <para>
/// 画面に依らない。書棚の窓はここを呼んで、返ってきたものを並べるだけにする。
/// </para>
/// </summary>
public sealed class LibrarySearch(SearchIndexStore store)
{
    /// <summary>1 冊から拾う上限。1 冊が結果を埋め尽くさないようにする。</summary>
    public const int PerBookLimit = 20;

    private readonly SearchIndexStore _store = store;

    /// <summary>
    /// 蔵書を順に引く。当たった本から順に返す。
    ///
    /// <para>
    /// <paramref name="cancel"/> で降りられる。降りるのは 1 冊の切れ目なので、
    /// 大きな本を読んでいる最中は少し待つ。
    /// </para>
    /// </summary>
    public IEnumerable<BookHits> Search(
        IEnumerable<string> bookPaths, string query, CancellationToken cancel = default)
    {
        query = query.Trim();
        if (query.Length == 0)
        {
            yield break;
        }

        foreach (var path in bookPaths)
        {
            cancel.ThrowIfCancellationRequested();
            // 見つからない本は引きようがない。
            if (!File.Exists(path))
            {
                continue;
            }
            if (Of(path, query) is { } found)
            {
                yield return found;
            }
        }
    }

    /// <summary>1 冊を引く。当たらなければ null。</summary>
    public BookHits? Of(string path, string query)
    {
        var format = DocumentFormats.Detect(path);
        return format switch
        {
            DocumentFormat.Pdf => OfPdf(path, query),
            DocumentFormat.ReflowableEpub => OfEpub(path, query),
            _ => null,
        };
    }

    private BookHits? OfEpub(string path, string query)
    {
        EpubArchive archive;
        EpubPublication publication;
        try
        {
            archive = new EpubArchive(path);
            publication = EpubParser.Parse(archive);
        }
        catch (Exception)
        {
            return null; // 開けない本は飛ばす。書棚の検索は 1 冊で止めない。
        }

        using (archive)
        {
            // 索引があるうちは書籍を丸ごと読まない。当たらない本には触らずに済む。
            var index = _store.Ensure(path, () => SearchUnits.OfEpub(archive, publication));
            var candidates = index?.Candidates(query);
            if (candidates is { Count: 0 })
            {
                return null;
            }

            var outcome = DocumentSearch.SearchEpubWithin(
                archive, publication, query, candidates, PerBookLimit);
            if (outcome.Results.Count == 0)
            {
                return null;
            }

            var hits = outcome.Results
                .Select(r => new LibraryHit(r.ChapterTitle, Excerpt(r), r.Locator.Href, null, r.Nth))
                .ToList();
            return new BookHits(path, TitleOf(publication.Title, path), hits, outcome.Truncated);
        }
    }

    private BookHits? OfPdf(string path, string query)
    {
        PdfInspector document;
        try
        {
            document = PdfInspector.Open(path);
        }
        catch (Exception)
        {
            return null;
        }

        using (document)
        {
            var index = _store.Ensure(path, document.PageTexts);
            var candidates = index?.Candidates(query);
            if (candidates is { Count: 0 })
            {
                return null;
            }

            var found = document.SearchWithin(query, PerBookLimit, candidates);
            if (found.Count == 0)
            {
                return null;
            }

            var hits = found
                .Select(h => new LibraryHit($"{h.Page + 1} ページ", h.Excerpt, null, h.Page, 0))
                .ToList();
            // 上限ちょうどで返ってきたら、まだ先があるとみなす。
            return new BookHits(path, TitleOf(string.Empty, path), hits, found.Count >= PerBookLimit);
        }
    }

    /// <summary>当たりの前後。書籍名の一覧に並べるので、1 行に均す。</summary>
    private static string Excerpt(SearchResult result) =>
        $"{result.Before}{result.Match}{result.After}".Replace('\n', ' ').Trim();

    /// <summary>名乗っていなければファイル名で出す。空欄を出しても読む人の役に立たない。</summary>
    private static string TitleOf(string title, string path) =>
        title.Length > 0 && title != "(無題)" ? title : Path.GetFileNameWithoutExtension(path);
}
