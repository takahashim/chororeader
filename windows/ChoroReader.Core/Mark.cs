using System.Text;

namespace ChoroReader.Core;

/// <summary>
/// 検索結果から飛んだ先で、当たった語を囲む。
///
/// 印は配信時に本文へ入れる。画面側で入れると、文字節を切って包む手術を JS で書くことになり、
/// 抽出（HtmlText）と数え方がずれる余地が残る。ここで入れれば、
/// 当たりを選ぶのは検索と同じコード（DocumentSearch.NthMatch）になる。
///
/// 場所は抽出（HtmlText.Extract）が控えた位置をそのまま使う。
/// 抽出は削って詰めるだけなので、削りながら控えれば元の位置が分かる。
/// </summary>
public static class Mark
{
    /// <summary>印に付ける名前。画面側の CSS はこれを見て色を当てる。</summary>
    public const string ClassName = "choro-found";

    /// <summary>
    /// 印を入れた場所。実装間で突き合わせるために、囲んだ語とその直前の文脈で表す。
    ///
    /// 位置を数で言うと、実装ごとの数え方（バイトか、符号位置か、書記素か）の違いが
    /// そのまま差になる。文字列で示せば、置いた場所が同じかどうかだけを比べられる。
    /// </summary>
    /// <param name="Marked">囲んだ語。</param>
    /// <param name="Before">囲んだところの直前にある本文（元の HTML から、最大 20 文字）。</param>
    public sealed record Placement(string Marked, string Before);

    /// <summary>印を置く場所。囲めなければ null。</summary>
    public static Placement? Locate(string html, string query, int nth)
    {
        if (Span(html, query, nth) is not { } span)
        {
            return null;
        }
        var (start, end) = span;
        return new Placement(html[start..end], LastRunes(html[..start], 20));
    }

    /// <summary>本文の nth 番目の当たりを <c>&lt;mark&gt;</c> で囲んだ HTML。囲めなければ null。</summary>
    public static string? Insert(string html, string query, int nth)
    {
        if (Span(html, query, nth) is not { } span)
        {
            return null;
        }
        var (start, end) = span;
        return new StringBuilder(html.Length + 40)
            .Append(html, 0, start)
            .Append($"<mark class=\"{ClassName}\">")
            .Append(html, start, end - start)
            .Append("</mark>")
            .Append(html, end, html.Length - end)
            .ToString();
    }

    /// <summary>囲む範囲（元の HTML の位置）。</summary>
    private static (int Start, int End)? Span(string html, string query, int nth)
    {
        var extracted = HtmlText.Extract(html);
        if (DocumentSearch.NthMatch(extracted.Text, query, nth) is not { } match)
        {
            return null;
        }
        var (from, to) = match;

        var origins = extracted.Origins;
        if (from >= origins.Count)
        {
            return null;
        }
        var start = origins[from];
        // 終わりは、当たりの次の文字が始まるところ。最後まで当たっていれば HTML の末尾。
        var end = to < origins.Count ? origins[to] : html.Length;
        // 節をまたぐ当たりは、始まりの地の文で切る。タグを囲むと入れ子が壊れる。
        end = Math.Min(end, RunEnd(html, start));
        return end > start ? (start, end) : null;
    }

    /// <summary>その文字が属する地の文の終わり。次のタグの手前で止める。</summary>
    private static int RunEnd(string html, int at)
    {
        var index = html.IndexOf('<', at);
        return index < 0 ? html.Length : index;
    }

    /// <summary>末尾から <paramref name="count"/> 文字。文字は Unicode スカラーで数える。</summary>
    private static string LastRunes(string source, int count)
    {
        var runes = DocumentSearch.Runes(source);
        var text = new StringBuilder();
        for (var index = Math.Max(0, runes.Count - count); index < runes.Count; index++)
        {
            text.Append(runes[index].ToString());
        }
        return text.ToString();
    }
}
