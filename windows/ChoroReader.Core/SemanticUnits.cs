using System.Text.RegularExpressions;

namespace ChoroReader.Core;

/// <summary>意味の索引が載せる単位。本文は控えない。</summary>
public sealed record SemanticUnit
{
    /// <summary>飛び先。表題は <see cref="Heading"/> のみ。</summary>
    public required Locator Locator { get; init; }

    /// <summary>この段落を含む節の見出し。</summary>
    public required string Heading { get; init; }

    /// <summary>
    /// この段落が属する節の番号（書籍の中で通し）。
    ///
    /// <para>
    /// <b>順位は節で決め、着地は段落でする</b>（spec-local-ai.md 5.1）。
    /// 段落だけで順位を付けると話題の芯を失い、巻末や一般論に流れる（実測 8/15 対 11/15）。
    /// </para>
    /// </summary>
    public required int Section { get; init; }

    /// <summary>移動に渡す飛び先。表題は見出しから埋める。</summary>
    public Locator Target => Locator with { Title = Heading.Length > 0 ? Heading : null };
}

/// <summary>切り出した段落と、埋め込みに渡す本文。</summary>
/// <remarks>
/// 本文を <see cref="SemanticUnit"/> に持たせないのは、索引に書かないものだからである
/// （spec-local-ai.md 4.2）。控えていた頃は本の 35% が原文のまま索引ファイルに入っていた。
/// </remarks>
public sealed record SemanticPiece(SemanticUnit Unit, string Text);

/// <summary>
/// 書籍を段落に区切る。
///
/// <para>
/// <b>節ではなく段落を単位とする</b>（spec-local-ai.md 4.1）。
/// 節を 1 本のベクトルにすると、3 つの話題に触れた節がそのどれでもない平均になる。
/// 着いた先も節の頭で、当たった場所そのものは分からない。
/// </para>
/// <para>
/// <b>文字は Unicode スカラーで数える。</b>Swift 版はここだけ書記素で数えているが、
/// 位置の数え方は spec.md でスカラーと決めてあり、C# 側の他の場所（検索・印）もそれで揃えてある。
/// 索引ファイルは実装ごとに作るので、揃っていて困るのは<b>同じ実装の中</b>だけである。
/// 混ぜると、この索引が出した位置を自分の検索や印が解けなくなる。
/// </para>
/// </summary>
public static class SemanticUnits
{
    /// <summary>
    /// 日本語で 400 字はおよそ 200 トークン、技術書の 1〜2 段落にあたる。
    /// 小さくするほど的は絞れるが、文脈が減り、索引も膨らむ。
    /// </summary>
    public const int TargetCharacters = 400;

    /// <summary>これ未満は独り立ちさせない。前の段落に足すか、捨てる。</summary>
    public const int DefaultLeastCharacters = 100;

    /// <summary>区切りが見つからなくても、ここを超えたら切る。</summary>
    private const int MostCharacters = 800;

    /// <summary>飛び先に載せる目印の長さ。<b>長すぎると綴じ方の違いで一致しない。</b></summary>
    private const int AnchorCharacters = 30;

    private static readonly Regex Headings =
        new(@"<h[1-3]\b([^>]*)>(.*?)</h[1-3]>", RegexOptions.IgnoreCase | RegexOptions.Singleline);

    private static readonly Regex Identifier =
        new("""\bid\s*=\s*["']([^"']+)["']""", RegexOptions.IgnoreCase);

    private static readonly Regex Spaces = new(@"\s+");

    // MARK: EPUB

    /// <summary>
    /// 読み順を段落に切る。
    ///
    /// <para>
    /// 読み順の 1 項目を <c>h1</c>〜<c>h3</c> で割り、その中を段落に詰める。
    /// 節の見出しは各段落に添える（どこの話かが分からないと見分けが付かない）。
    /// </para>
    /// </summary>
    public static IReadOnlyList<SemanticPiece> OfEpub(
        IResourceProvider resources, EpubPublication publication,
        int leastCharacters = DefaultLeastCharacters)
    {
        var made = new List<SemanticPiece>();
        var at = 0;   // 節の通し番号

        // **巻末の索引は載せない。** 語がひたすら並ぶ紙面は何にでも少しずつ似てしまい、
        // 意味検索の上位を埋める。二字組の検索は別の索引なので、語で引くことは今までどおりできる。
        var skip = BackIndex.Of(publication);

        for (var place = 0; place < publication.ReadingOrder.Count; place++)
        {
            if (skip?.Contains(place) == true)
            {
                continue;
            }
            if (resources.ReadText(publication.ReadingOrder[place].Href) is not { } html)
            {
                continue;
            }
            var href = publication.ReadingOrder[place].Href;

            // 章の中での位置は、取り出した本文の長さで測る。綴じ方に左右されないため。
            var sections = Placed(Split(html));
            var total = Math.Max(1, sections.Count > 0
                ? sections[^1].Offset + Count(sections[^1].Text)
                : 0);

            foreach (var section in sections)
            {
                foreach (var passage in Passages(section.Text, leastCharacters))
                {
                    made.Add(new SemanticPiece(
                        new SemanticUnit
                        {
                            Locator = new Locator
                            {
                                Href = href,
                                Progression = Math.Min(1, (double)(section.Offset + passage.Offset) / total),
                                // 節の頭の段落なら見出しの id へ、そうでなければ本文で探す
                                Fragment = passage.Offset == 0 ? section.Fragment : null,
                                Text = Anchor(passage.Text),
                            },
                            Heading = section.Heading,
                            Section = at,
                        },
                        passage.Text));
                }
                at++;
            }
        }
        return made;
    }

    private sealed record Section(string Heading, string? Fragment, string Html);

    /// <summary>本文を取り出し、章の頭からの位置を添えた節。</summary>
    private sealed record PlacedSection(string Heading, string? Fragment, string Text, int Offset);

    /// <summary>節を順に並べ、章の頭からの位置を付ける。</summary>
    private static List<PlacedSection> Placed(List<Section> sections)
    {
        var made = new List<PlacedSection>(sections.Count);
        var offset = 0;
        foreach (var section in sections)
        {
            var text = Tidy(HtmlText.Extract(section.Html).Text);
            made.Add(new PlacedSection(section.Heading, section.Fragment, text, offset));
            offset += Count(text);
        }
        return made;
    }

    /// <summary>
    /// 見出しの位置で HTML を割る。見出しが無ければ丸ごと 1 つ。
    ///
    /// <para>
    /// 段落に切るのはこの後だが、<b>見出しは先に拾っておく</b>。
    /// どの節の話かが分からないと、一覧で見分けが付かない。
    /// </para>
    /// </summary>
    private static List<Section> Split(string html)
    {
        var matches = Headings.Matches(html);
        if (matches.Count == 0)
        {
            return [new Section(string.Empty, null, html)];
        }

        var made = new List<Section>();
        // 最初の見出しより前にも本文があることがある（前書きなど）。捨てない。
        if (matches[0].Index > 0)
        {
            made.Add(new Section(string.Empty, null, html[..matches[0].Index]));
        }

        for (var at = 0; at < matches.Count; at++)
        {
            var match = matches[at];
            var to = at + 1 < matches.Count ? matches[at + 1].Index : html.Length;
            // **見出しの札そのものは本文に含めない。** 見出しは別に持っているので二重になるうえ、
            // 画面では見出しと段落が別の節点なので、跨いだ目印は本文から見つからない。
            var from = match.Index + match.Length;
            var body = from < to ? html[from..to] : string.Empty;
            var heading = Tidy(HtmlText.Extract(match.Groups[2].Value).Text);
            var id = Identifier.Match(match.Groups[1].Value);
            made.Add(new Section(heading, id.Success ? id.Groups[1].Value : null, body));
        }
        return made;
    }

    // MARK: PDF

    /// <summary>
    /// 紙面を段落に切る。
    ///
    /// <para>
    /// <b>ページごとに切る。</b>節の範囲でまとめると、着いた先が節の頭になってしまう。
    /// ページ単位なら飛び先のページが正確に決まり、目印で行まで寄せられる。
    /// </para>
    /// </summary>
    public static IReadOnlyList<SemanticPiece> OfPdf(
        PdfInspector paper, int leastCharacters = DefaultLeastCharacters)
    {
        var titles = BackIndex.PageTitles(paper);
        // **巻末の索引は載せない。** EPUB と同じ扱いである。
        var skip = BackIndex.Of(paper, titles);

        var made = new List<SemanticPiece>();
        // 節はアウトラインの区切り。見出しが変わるまでは同じ節とする。
        var at = 0;
        string? previous = null;

        for (var page = 0; page < paper.PageCount; page++)
        {
            if (skip?.Contains(page) == true)
            {
                continue;
            }
            if (previous != titles[page])
            {
                if (previous is not null)
                {
                    at++;
                }
                previous = titles[page];
            }

            var text = Tidy(paper.TextOfPage(page));
            if (text.Length == 0)
            {
                continue;
            }
            foreach (var passage in Passages(text, leastCharacters))
            {
                made.Add(new SemanticPiece(
                    new SemanticUnit
                    {
                        Locator = new Locator
                        {
                            Page = page,
                            Progression = (double)page / Math.Max(1, paper.PageCount),
                            Text = Anchor(passage.Text),
                        },
                        Heading = titles[page],
                        Section = at,
                    },
                    passage.Text));
            }
        }
        return made;
    }

    // MARK: 段落に切る

    /// <param name="Offset">元の本文の中での位置。章内の位置を測るのに使う。</param>
    private sealed record Passage(int Offset, string Text);

    /// <summary>
    /// 文の切れ目で詰めて、狙いの長さの段落にする。
    ///
    /// <para>
    /// <b>短い切れ端は前に足す。</b>見出しだけの行や 1 文だけの段落を独り立ちさせると、
    /// 文脈の無いベクトルが索引を埋める。
    /// </para>
    /// </summary>
    private static List<Passage> Passages(string text, int leastCharacters)
    {
        var made = new List<Passage>();
        if (Count(text) < leastCharacters)
        {
            return made;
        }

        var current = new System.Text.StringBuilder();
        var start = 0;
        var seen = 0;
        // **数え直さない。** 詰めるたびに全体を数えると、本文の長さの 2 乗で効く。
        var held = 0;

        foreach (var chunk in Chunks(text))
        {
            if (current.Length == 0)
            {
                start = seen;
            }
            current.Append(chunk.Text);
            seen += chunk.Count;
            held += chunk.Count;
            if (held >= TargetCharacters)
            {
                made.Add(new Passage(start, Tidy(current.ToString())));
                current.Clear();
                held = 0;
            }
        }

        if (current.Length > 0)
        {
            var last = Tidy(current.ToString());
            if (Count(last) >= leastCharacters)
            {
                made.Add(new Passage(start, last));
            }
            else if (made.Count > 0)
            {
                // 端数は前に足す。独り立ちさせない。
                var previous = made[^1];
                made[^1] = previous with { Text = Tidy(previous.Text + last) };
            }
        }
        return made;
    }

    /// <summary>切れ端と、その長さ（スカラー数）。長さは数え直さずに持ち回る。</summary>
    private readonly record struct Chunk(string Text, int Count);

    /// <summary>詰める前の切れ端。改行か句点で割り、長すぎるものは力尽くで切る。</summary>
    private static List<Chunk> Chunks(string text)
    {
        var made = new List<Chunk>();
        var current = new System.Text.StringBuilder();
        var length = 0;

        foreach (var rune in text.EnumerateRunes())
        {
            current.Append(rune.ToString());
            length++;
            var breaks = rune.Value is '\n' or '。' or '．' or '！' or '？';
            if (breaks || length >= MostCharacters)
            {
                made.Add(new Chunk(current.ToString(), length));
                current.Clear();
                length = 0;
            }
        }
        if (current.Length > 0)
        {
            made.Add(new Chunk(current.ToString(), length));
        }
        return made;
    }

    // MARK: 共通

    /// <summary>文字の数。<b>Unicode スカラーで数える</b>（UTF-16 の単位数ではない）。</summary>
    private static int Count(string text)
    {
        var at = 0;
        foreach (var _ in text.EnumerateRunes())
        {
            at++;
        }
        return at;
    }

    private static string Tidy(string text) => Spaces.Replace(text, " ").Trim();

    /// <summary>
    /// 飛び先に載せる目印。
    ///
    /// <para>
    /// 読み手はこれを本文の中から探して、そこへ寄せる。
    /// <b>長いほど外れやすい。</b>取り出した本文と画面上の本文は、
    /// 空白や組み方の都合で完全には一致しないためである。
    /// 見つからなければ章内の位置（EPUB）やページ（PDF）へ落ちる。
    /// </para>
    /// </summary>
    private static string? Anchor(string text)
    {
        var trimmed = Tidy(text);
        if (Count(trimmed) < 8)
        {
            return null;
        }

        // 30 スカラーで切る。**符号単位で切らない。**
        // 上位・下位の片割れだけを残すと、飛び先の目印が壊れた文字で始まる。
        var made = new System.Text.StringBuilder();
        var taken = 0;
        foreach (var rune in trimmed.EnumerateRunes())
        {
            if (taken == AnchorCharacters)
            {
                break;
            }
            made.Append(rune.ToString());
            taken++;
        }
        return made.ToString();
    }
}
