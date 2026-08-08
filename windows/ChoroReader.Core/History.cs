namespace ChoroReader.Core;

/// <summary>
/// 行った先の履歴。戻る／進む。
///
/// <para>
/// 目次や検索から飛んだあと、元いた場所へ帰れないと読書が続かない。
/// macOS 版・Tauri 版はどちらも道具帯に戻る／進むを持っている。
/// </para>
/// <para>
/// 画面に依らないので、ここに置いて macOS でも検査できるようにする。
/// </para>
/// </summary>
public sealed class History<T>
{
    private readonly List<T> _places = [];

    /// <summary>いまいるところ。まだどこにも行っていなければ -1。</summary>
    private int _at = -1;

    /// <summary>覚えておく数の上限。長い本を読み回っても際限なく増やさない。</summary>
    private readonly int _limit;

    public History(int limit = 100) => _limit = Math.Max(1, limit);

    public bool CanGoBack => _at > 0;

    public bool CanGoForward => _at >= 0 && _at < _places.Count - 1;

    /// <summary>いまいるところ。まだどこにも行っていなければ既定値。</summary>
    public T? Current => _at >= 0 ? _places[_at] : default;

    public int Count => _places.Count;

    /// <summary>
    /// 行った先を積む。
    ///
    /// <para>
    /// <b>戻っている途中で新しいところへ行ったら、先は捨てる。</b>
    /// 残しておくと、戻る／進むを往復したときに通らなかった道が現れる。
    /// </para>
    /// <para>
    /// <b>同じところを続けて積まない。</b>章の中で位置が動くたびに積むと、
    /// 戻るを押しても同じ章に留まり続けることになる。
    /// </para>
    /// </summary>
    public void Visit(T place)
    {
        if (_at >= 0 && EqualityComparer<T>.Default.Equals(_places[_at], place))
        {
            return;
        }

        if (_at < _places.Count - 1)
        {
            _places.RemoveRange(_at + 1, _places.Count - _at - 1);
        }

        _places.Add(place);
        if (_places.Count > _limit)
        {
            _places.RemoveAt(0);
        }
        _at = _places.Count - 1;
    }

    /// <summary>
    /// 1 つ戻る。戻れなければ既定値を返す。
    ///
    /// <para>
    /// 戻った先は<b>積み直さない</b>。積むと履歴が伸び続けて、進むが消える。
    /// </para>
    /// </summary>
    public T? GoBack()
    {
        if (!CanGoBack)
        {
            return default;
        }
        _at--;
        return _places[_at];
    }

    public T? GoForward()
    {
        if (!CanGoForward)
        {
            return default;
        }
        _at++;
        return _places[_at];
    }
}
