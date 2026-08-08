using ChoroReader.Core;

namespace ChoroReader.Tests;

/// <summary>
/// 索引で絞った検索が、絞らない検索と一字も変わらないこと。
///
/// <para>
/// spec.md 10.4 の「索引は候補を絞るだけで、当たりを決めない」を機械で押さえる。
/// ここが崩れると、検索結果が索引の有無で変わり、conformance の
/// 「検索のヒット位置、件数、順序」を索引の導入で動かしてしまう。
/// </para>
/// <para>
/// Rust 版の tests/index_narrows_only.rs、macOS 版の SearchIndexTests と対になる検査である。
/// どれか 1 つの実装にしか無いと、残りが黙って崩れる。
/// </para>
/// </summary>
public class SearchIndexTests
{
    /// <summary>当たるもの、当たらないもの、1 文字、全角と半角の混ざったものを並べる。</summary>
    private static readonly string[] Queries =
    [
        "本文", "章", "の", "語", "hello", "ファイル名", "第 1 章", "出てこない語", "a", "",
    ];

    private static readonly string[] Books =
    [
        "epub3-basic.epub", "epub2-ncx.epub", "footnotes.epub", "legacy-css.epub",
        "encoded-paths.epub", "rtl.epub", "nonlinear-spine.epub", "repeated-spine.epub",
        "counting.epub",
    ];

    [Fact]
    public void 索引ありと索引なしで当たりが変わらない()
    {
        // 索引が一度も絞らなければ、この検査は何も確かめていないことになる。
        var narrowedAtLeastOnce = false;

        // 1 冊でも欠けたら落とす。飛ばすと、覆う範囲が減ったことに気づけない。
        var missing = Books.Where(name => !File.Exists(TestPaths.Fixture(name))).ToList();
        Assert.True(missing.Count == 0,
                    $"フィクスチャがありません（{string.Join("、", missing)}）。" +
                    "conformance で bundle exec ruby choroconf generate を先に走らせてください");

        foreach (var name in Books)
        {
            var path = TestPaths.Fixture(name);
            using var archive = new EpubArchive(path);
            var publication = EpubParser.Parse(archive);
            var units = SearchUnits.OfEpub(archive, publication);
            var index = SearchIndex.Build(units);

            foreach (var query in Queries.Concat(QueriesFrom(units)))
            {
                var candidates = index.Candidates(query);
                if (candidates is not null && candidates.Count < index.UnitCount)
                {
                    narrowedAtLeastOnce = true;
                }

                var full = DocumentSearch.SearchEpub(archive, publication, query);
                var narrow = DocumentSearch.SearchEpubWithin(
                    archive, publication, query, candidates, DocumentSearch.ResultLimit);

                Assert.Equal(Digest(full), Digest(narrow));
                Assert.Equal(full.Truncated, narrow.Truncated);
            }
        }

        Assert.True(narrowedAtLeastOnce, "索引が一度も候補を絞っていない");
    }

    /// <summary>
    /// 本文そのものから問い合わせを作る。書き並べた語だけでは、当てる場所が偏る。
    ///
    /// <para>
    /// 特に単位の末尾は落としやすい。二字組は文字の対で作るため、最後の 1 文字は
    /// 対の相手がおらず、番人（SENTINEL）と組ませる作りに頼っている。
    /// 末尾に当たる問い合わせを入れておかないと、そこが壊れても検査が黙って通る。
    /// </para>
    /// </summary>
    private static IEnumerable<string> QueriesFrom(IReadOnlyList<string> units)
    {
        foreach (var unit in units)
        {
            var chars = DocumentSearch.Runes(unit);
            if (chars.Count < 3)
            {
                continue;
            }
            string Take(int from, int length) =>
                string.Concat(chars.Skip(from).Take(Math.Min(length, chars.Count - from)));

            yield return Take(0, 2);                 // 頭
            yield return Take(chars.Count / 2, 3);   // 中ほど
            yield return Take(chars.Count - 2, 2);   // 末尾
            yield return Take(chars.Count - 1, 1);   // 末尾の 1 文字
        }
    }

    /// <summary>当たりは作るたびに同じ器とは限らないので、中身だけを比べる。</summary>
    private static List<string> Digest(SearchOutcome outcome) =>
        outcome.Results
            .Select(r => string.Join('|',
                r.Locator.Href ?? string.Empty,
                r.Locator.Progression.ToString("F3"),
                r.Match,
                r.IsCode,
                r.Nth))
            .ToList();

    /// <summary>
    /// 単位の最後の 1 文字には、二字組の相手がいない。
    /// 二字目を 0 にした組（番人）を足しておかないと、その字を 1 文字で引いたときに単位を落とす。
    ///
    /// <para>
    /// 上の「索引ありと索引なしで当たりが変わらない」だけでは、ここは踏めなかった。
    /// フィクスチャの単位はどれも空白か句点で終わり、その字は本文の途中にも出るため、
    /// 番人を外しても他の二字組が拾ってしまう。狙って踏む書籍をここで作る。
    /// </para>
    /// </summary>
    [Fact]
    public void 末尾にしか出ない字を一文字で引ける()
    {
        // 「え」は 0 番の末尾にしか出ない。「け」は 1 番の末尾にしか出ない。
        var index = SearchIndex.Build(["あいうえ", "かきくけ"]);

        var first = index.Candidates("え");
        Assert.NotNull(first);
        Assert.Contains(0, first);
        Assert.DoesNotContain(1, first);

        var second = index.Candidates("け");
        Assert.NotNull(second);
        Assert.Contains(1, second);
        Assert.DoesNotContain(0, second);
    }

    [Fact]
    public void 書き出して読み直しても同じ候補を返す()
    {
        var units = new[] { "これは最初の章である。", "二つめの章には別の語が出る。", string.Empty };
        var index = SearchIndex.Build(units);
        var restored = SearchIndex.Decode(index.Encode());

        Assert.NotNull(restored);
        Assert.Equal(index.UnitCount, restored.UnitCount);
        foreach (var query in new[] { "章", "最初", "別の語", "出てこない", "る", "" })
        {
            Assert.Equal(index.Candidates(query), restored.Candidates(query));
        }
    }

    [Fact]
    public void 壊れた並びを読ませても落ちない()
    {
        Assert.Null(SearchIndex.Decode([]));
        Assert.Null(SearchIndex.Decode("ちがう"u8.ToArray()));

        var sound = SearchIndex.Build(["本文がある章"]).Encode();

        // 版が違う。
        var wrongVersion = (byte[])sound.Clone();
        wrongVersion[4] = 99;
        Assert.Null(SearchIndex.Decode(wrongVersion));

        // 途中で切れている。どこで切れても落ちないこと。
        for (var cut = 5; cut < sound.Length; cut++)
        {
            SearchIndex.Decode(sound[..cut]);
        }
    }

    [Fact]
    public void 空の書籍でも扱える()
    {
        var index = SearchIndex.Build([]);
        Assert.True(index.IsEmpty);
        Assert.Equal(0, index.UnitCount);
        Assert.Null(index.Candidates(""));

        var restored = SearchIndex.Decode(index.Encode());
        Assert.NotNull(restored);
        Assert.True(restored.IsEmpty);
    }

    /// <summary>
    /// 索引の畳み方は、走査の畳み方より厳しくてはいけない。
    /// 厳しいと、本当の当たりを索引の段で落としてしまう。
    /// </summary>
    [Fact]
    public void 全角と半角や大文字小文字をまたいで絞れる()
    {
        var index = SearchIndex.Build(["ＡＢＣ の話", "無関係な章"]);

        var candidates = index.Candidates("abc");
        Assert.NotNull(candidates);
        Assert.Contains(0, candidates);
        Assert.DoesNotContain(1, candidates);
    }
}
