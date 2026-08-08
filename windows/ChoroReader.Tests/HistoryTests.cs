using ChoroReader.Core;

namespace ChoroReader.Tests;

/// <summary>
/// 戻る／進む。
///
/// <para>
/// 目次や検索から飛んだあと元へ帰る道なので、<b>通らなかった道が現れないこと</b>が要になる。
/// </para>
/// </summary>
public class HistoryTests
{
    private static History<string> Walked(params string[] places)
    {
        var history = new History<string>();
        foreach (var place in places)
        {
            history.Visit(place);
        }
        return history;
    }

    [Fact]
    public void 何も無いところからは戻れない()
    {
        var history = new History<string>();
        Assert.False(history.CanGoBack);
        Assert.False(history.CanGoForward);
        Assert.Null(history.GoBack());

        // 1 か所しか行っていなければ、まだ戻り先は無い。
        history.Visit("ch01");
        Assert.False(history.CanGoBack);
        Assert.Equal("ch01", history.Current);
    }

    [Fact]
    public void 戻って進むと元の場所へ返る()
    {
        var history = Walked("ch01", "ch02", "ch03");

        Assert.Equal("ch02", history.GoBack());
        Assert.Equal("ch01", history.GoBack());
        Assert.False(history.CanGoBack);

        Assert.Equal("ch02", history.GoForward());
        Assert.Equal("ch03", history.GoForward());
        Assert.False(history.CanGoForward);
    }

    /// <summary>
    /// 戻っている途中で新しいところへ行ったら、先は捨てる。
    /// 残すと、戻る／進むを往復したときに<b>通らなかった道</b>が現れる。
    /// </summary>
    [Fact]
    public void 戻ってから別の場所へ行くと先は消える()
    {
        var history = Walked("ch01", "ch02", "ch03");
        history.GoBack();
        Assert.True(history.CanGoForward);

        history.Visit("ch09");

        Assert.False(history.CanGoForward);
        Assert.Equal("ch09", history.Current);

        // 捨てたのは ch03 だけ。ch09 へは ch02 から行ったので、戻り先はそこ。
        Assert.Equal("ch02", history.GoBack());
        Assert.Equal("ch01", history.GoBack());
        Assert.False(history.CanGoBack);
    }

    /// <summary>
    /// 章の中で位置が動くたびに積むと、戻るを押しても同じ章に留まり続ける。
    /// </summary>
    [Fact]
    public void 同じ場所を続けて積まない()
    {
        var history = Walked("ch01", "ch01", "ch01", "ch02");

        Assert.Equal(2, history.Count);
        Assert.Equal("ch01", history.GoBack());
        Assert.False(history.CanGoBack);
    }

    /// <summary>離れていれば、同じ場所がもう一度出てくるのは正しい。</summary>
    [Fact]
    public void 離れた同じ場所は別に積む()
    {
        var history = Walked("ch01", "ch02", "ch01");

        Assert.Equal(3, history.Count);
        Assert.Equal("ch02", history.GoBack());
    }

    /// <summary>戻った先を積み直すと履歴が伸び続け、進むが消える。</summary>
    [Fact]
    public void 戻っても履歴は伸びない()
    {
        var history = Walked("ch01", "ch02", "ch03");
        history.GoBack();

        Assert.Equal(3, history.Count);
        Assert.True(history.CanGoForward);
    }

    [Fact]
    public void 上限を超えたら古い方から捨てる()
    {
        var history = new History<int>(limit: 3);
        for (var i = 0; i < 10; i++)
        {
            history.Visit(i);
        }

        Assert.Equal(3, history.Count);
        Assert.Equal(9, history.Current);
        Assert.Equal(8, history.GoBack());
        Assert.Equal(7, history.GoBack());
        Assert.False(history.CanGoBack);
    }
}
