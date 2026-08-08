using ChoroReader.Core;

namespace ChoroReader.Semantic;

/// <summary>
/// 意味で引いた 1 件。
///
/// <para>
/// <b>「当たり」ではない。</b>正確な検索と違って、当たった語が無いので囲めないし、
/// 件数にも意味が無い（spec-local-ai.md 5.2）。<see cref="Score"/> は近さで、
/// 人が「どれくらい近いのか」を測れるように添える。
/// </para>
/// </summary>
/// <param name="BookPath">どの書籍か。</param>
/// <param name="Title">書名。</param>
/// <param name="Heading">その段落を含む節の見出し。</param>
/// <param name="Target">飛び先。表題は見出しから埋めてある。</param>
/// <param name="Score">近さ。ベクトルは正規化してあるので内積そのもの。</param>
/// <param name="Text">原書から切り出した本文断片。索引には控えていない。</param>
public sealed record SemanticHit(string BookPath, string Title, string Heading,
                                 Locator Target, float Score, string Text);

/// <summary>
/// 蔵書を横断して、意味で引く。
///
/// <para>
/// <b>1 冊ずつ読んで、1 冊ずつ捨てる</b>（spec-local-ai.md 4.3）。
/// 先に全冊ぶんを集めてから並べてはいけない。ほどいた索引に上限を付けてあっても、
/// 集めた配列が握っていれば追い出されない。
/// </para>
/// <para>
/// <b>順位は節で決め、着地は段落でする</b>（5.1）。そこは
/// <see cref="SemanticIndex.Nearest"/> が引き受けるので、ここは冊をまたいで
/// 上位だけを残す仕事をする。
/// </para>
/// <para>
/// 本文は索引に無いので、<b>勝った書籍でだけ原書から切り出す</b>。
/// 全部の候補で切り出すと、負ける書籍まで開くことになる。
/// </para>
/// </summary>
public sealed class SemanticSearch(SemanticIndexStore store, string model)
{
    /// <summary>1 冊から拾う上限。多く採っても、冊をまたいだ上位には残らない。</summary>
    public const int PerBookLimit = 8;

    /// <summary>並べる上限。</summary>
    public const int Limit = 20;

    /// <summary>途中の 1 件。本文はまだ切り出していない。</summary>
    private readonly record struct Candidate(string BookPath, string Title, int Unit, float Score);

    /// <summary>
    /// 引く。
    ///
    /// <para>
    /// <b>画面のスレッドから呼んではいけない。</b>索引をほどき、原書を開く。
    /// </para>
    /// </summary>
    /// <param name="query">問いのベクトル。<c>検索クエリ: </c> を付けて埋め込んだもの。</param>
    /// <param name="books">蔵書（経路と書名）。</param>
    public IReadOnlyList<SemanticHit> Run(
        float[] query, IReadOnlyList<(string Path, string Title)> books,
        int limit = Limit, CancellationToken cancel = default)
    {
        var found = new List<Candidate>();
        // 勝った書籍でだけ本文を切り出せるよう、単位そのものは冊ごとに控えておく。
        var units = new Dictionary<string, IReadOnlyList<SemanticUnit>>(StringComparer.Ordinal);

        foreach (var (path, title) in books)
        {
            cancel.ThrowIfCancellationRequested();
            if (store.Cached(path, model) is not { } index || index.Dimension != query.Length)
            {
                continue;
            }

            var near = index.Nearest(query, PerBookLimit);
            if (near.Count == 0)
            {
                continue;
            }
            // **ここで単位まで解いておく。** 索引そのものは 1 冊ずつ捨てられるように、
            // 先の処理へ持ち越さない。
            var resolved = near.Select(one => index.Unit(one.Unit)).ToList();
            units[path] = resolved;
            for (var at = 0; at < near.Count; at++)
            {
                found.Add(new Candidate(path, title, at, near[at].Score));
            }
        }

        // 冊をまたいで上位だけ残す。同点は書名と番号で決める（呼ぶたびに変えない）。
        var winners = found
            .OrderByDescending(one => one.Score)
            .ThenBy(one => one.BookPath, StringComparer.Ordinal)
            .ThenBy(one => one.Unit)
            .Take(limit)
            .ToList();

        // 本文は勝った書籍でだけ切り出す。書籍は 1 度ずつしか開かない。
        var made = new List<SemanticHit>(winners.Count);
        foreach (var byBook in winners.GroupBy(one => one.BookPath, StringComparer.Ordinal))
        {
            cancel.ThrowIfCancellationRequested();
            var wanted = byBook.ToList();
            var picked = wanted.Select(one => units[one.BookPath][one.Unit]).ToList();
            var texts = PassageText.Read(picked, byBook.Key);

            for (var at = 0; at < wanted.Count; at++)
            {
                var unit = picked[at];
                made.Add(new SemanticHit(
                    BookPath: wanted[at].BookPath,
                    Title: wanted[at].Title,
                    Heading: unit.Heading,
                    Target: unit.Target,
                    Score: wanted[at].Score,
                    Text: texts.TryGetValue(at, out var text) ? text : string.Empty));
            }
        }

        // まとめ直したので、並びを付け直す。
        return [.. made.OrderByDescending(one => one.Score)
                       .ThenBy(one => one.BookPath, StringComparer.Ordinal)];
    }
}
