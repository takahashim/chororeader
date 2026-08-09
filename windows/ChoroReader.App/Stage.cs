using System.Windows;
using ChoroReader.Core;

namespace ChoroReader.App;

/// <summary>
/// 行き先。目次の 1 行、ページの 1 枚、当たりの 1 件、しおりの 1 つを同じ形で表す。
///
/// <para>
/// 押したら飛ぶ、という点でどれも同じものなので、面ごとに型を分けない。
/// 分けると、面が増えるたびに飛ぶ道が増える。
/// </para>
/// </summary>
/// <param name="Label">一覧に出す文字。</param>
/// <param name="Href">EPUB の章。PDF では空。</param>
/// <param name="Fragment">章の中の飛び先。</param>
/// <param name="Page">PDF のページ。EPUB では 0。</param>
/// <param name="Progression">章の中のどこか。しおりから戻るときに使う。</param>
/// <param name="Query">当たりのとき、囲む語。</param>
/// <param name="Nth">当たりのとき、章の中で何番目の当たりか。</param>
/// <param name="Depth">目次の階層。字下げに使う。</param>
/// <param name="Detail">2 行目に出すもの。当たりの本文など。無ければ 1 行で出る。</param>
internal sealed record Place(
    string Label,
    string? Href = null,
    string? Fragment = null,
    int Page = 0,
    double Progression = 0,
    string? Query = null,
    int Nth = 0,
    int Depth = 0,
    string? Detail = null)
{
    /// <summary>
    /// 字下げ。<b>空白文字では揃わない。</b>字形の幅が一定でないためである。
    /// </summary>
    public Thickness Indent => new(Depth * 14, 0, 0, 0);

    public override string ToString() => Label;
}

/// <summary>いま出しているところ。道具帯と下辺に出す。</summary>
/// <param name="Title">道具帯に出す章名またはページ。</param>
/// <param name="Position">下辺の右に出す進み具合。</param>
internal sealed record Whereabouts(string Title, string Position);

/// <summary>
/// 舞台。読書の窓の中身。
///
/// <para>
/// <b>窓は形式で分けない。</b>道具帯・サイドバー・下辺は形式に依らず同じ場所にあり、
/// 差し替わるのはここだけである（windows/README.md「画面の組み立て」）。
/// 形式ごとに窓を分けると、目次・検索・しおり・表示設定・位置の表示を形式の数だけ作ることになり、
/// どれか 1 つに機能を足したときに他が置いていかれる。
/// </para>
/// </summary>
internal interface IStage : IDisposable
{
    /// <summary>舞台に置く部品。</summary>
    FrameworkElement View { get; }

    /// <summary>書名。窓の題に出す。</summary>
    string BookTitle { get; }

    /// <summary>目次。空なら「目次がありません」と出す。</summary>
    IReadOnlyList<Place> Toc { get; }

    /// <summary>ページの一覧。持たない形式では空にして、タブそのものを出さない。</summary>
    IReadOnlyList<Place> Pages { get; }

    /// <summary>引けない理由。引けるなら <c>null</c>。</summary>
    string? CannotSearch { get; }

    /// <summary>表示設定が効くか。文字を組み直せるのはリフローだけ。</summary>
    bool Reflowable { get; }

    /// <summary>いま出しているところ。</summary>
    Whereabouts Where { get; }

    /// <summary>いま読んでいるところ。覚え書きに残す形。</summary>
    Position Position { get; }

    /// <summary>
    /// 章の中のどこかが、まだ分かっていない。
    ///
    /// <para>
    /// 本文の位置は間引かれた便りで届くので、章を開いた直後は分からない。
    /// <b>その状態で丸ごと書くと、章の中の位置を 0 で潰す。</b>
    /// 窓はこれを見て、章だけを控えるか丸ごと控えるかを決める
    /// （<see cref="ReadingStore.RememberChapter"/>）。
    /// </para>
    /// <para>
    /// 紙面には間引きが無く、ページは移った瞬間に確かなので、常に false になる。
    /// </para>
    /// </summary>
    bool PositionPending { get; }

    /// <summary>位置が動いたときに窓へ知らせる。窓は道具帯と下辺を書き直す。</summary>
    event Action? Moved;

    /// <summary>出せる状態にして、最初のところを出す。</summary>
    Task StartAsync();

    /// <summary>覚えていたところから始める。<see cref="StartAsync"/> より前に呼ぶ。</summary>
    void ResumeFrom(Position position);

    /// <summary>前後へ動かす。動いたら true。</summary>
    Task<bool> MoveAsync(int delta);

    /// <summary>指したところへ飛ぶ。</summary>
    Task GoAsync(Place place);

    /// <summary>引く。結果は飛び先つきの一覧。</summary>
    Task<(IReadOnlyList<Place> Hits, bool Truncated)> FindAsync(string query);

    /// <summary>表示設定を当てる。効かない形式では何もしない。</summary>
    Task ApplyStyleAsync(ReaderStyle style);
}
