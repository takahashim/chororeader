using System.Text;
using System.Xml;

namespace ChoroReader.Core;

/// <summary>配信する 1 つ。本文の応答には <see cref="ContentSecurityPolicy"/> を添える。</summary>
public sealed record DeliveredResource(byte[] Body, string ContentType, string? ContentSecurityPolicy);

/// <summary>
/// 本文とその周辺リソースを WebView へ供給する。供給範囲は <see cref="IResourceProvider"/> が決める。
/// CSS の互換変換と当たりの印は、ここで配信の瞬間に行う。元ファイルは書き換えない。
///
/// <para>
/// <b>WebView2 に依らない。</b>「要求された経路 → 応答」だけを受け持つので、
/// Windows を用意しなくても macOS で組んで検査できる。
/// WebView2 との配線（<c>WebResourceRequested</c>）は UI 側の薄い層が引き受ける。
/// </para>
/// <para>
/// 独自スキームは Windows では登録できなかったので、名前解決に成功しないホストへの要求を
/// 横取りする形にしている（spikes/findings-windows.md のスパイク 3）。
/// </para>
/// </summary>
public sealed class ResourceDelivery
{
    /// <summary>
    /// 本文の配信元。
    ///
    /// <para>
    /// <c>.invalid</c> は RFC 2606 で予約されていて、名前解決に成功することがない。
    /// 横取りに漏れがあっても外へ出ていかない。<c>https</c> なので secure context にもなる。
    /// </para>
    /// <para>
    /// <b>経路を組み立てるのも、CSP の許し先も、ここから取る。</b>
    /// Tauri 版は許し先を別に書いていて、Windows でだけ何にも当たらず、
    /// 書籍の CSS が効かず図版が抜けた本文が出た（spikes/findings-tauri.md）。
    /// </para>
    /// </summary>
    public const string Origin = "https://choro.invalid";

    /// <summary>
    /// 本文に付ける CSP。資源の取り寄せ先を配信元だけに限り、外への通信を塞ぐ。
    ///
    /// <para>
    /// <b>書籍の script を止めるのはここである。</b><c>script-src 'none'</c> がその役を負う。
    /// エンジンの段（<c>IsScriptEnabled = false</c>）では止めない。
    /// あれは「その文書に紐づく script を走らせない」という意味で、
    /// 注入したスクリプトが張ったリスナまで発火しなくなり、読書の仕掛けが止まる。
    /// <c>AddScriptToExecuteOnDocumentCreated</c> の注入は CSP の外にあり、そのまま走る。
    /// 書籍の script が止まり、注入もリスナも便りも生きていることは、
    /// WebView2 のスパイクが毎回確かめる（spikes/findings-windows.md）。
    /// </para>
    /// <para>
    /// <c>style-src</c> にだけ <c>'unsafe-inline'</c> が要る。
    /// 書籍は <c>style</c> 属性と <c>&lt;style&gt;</c> を普通に使い、
    /// 表示設定もそこへ当てるためである。
    /// </para>
    /// </summary>
    public const string ContentSecurityPolicy =
        "default-src 'none'; script-src 'none'; style-src 'unsafe-inline' " + Origin + "; " +
        "img-src " + Origin + " data:; media-src " + Origin + "; font-src " + Origin + "; " +
        "connect-src 'none'; base-uri 'none'; form-action 'none'";

    /// <summary>
    /// 覚えておける総量。
    ///
    /// 章と CSS は文字なので 1 つは小さいが、際限は無い。読み進めれば章が積み上がり、
    /// 同じ章でも印の付き方ごとに別の 1 つになる。窓が開いているあいだ捨てないので、頭を打っておく。
    /// </summary>
    public const int CacheLimit = 8 * 1024 * 1024;

    /// <summary>覚えるのは文字のものだけ。画像を溜め込むとメモリを圧迫する。</summary>
    private static readonly string[] Cacheable = ["css", "xhtml", "html", "htm"];

    private readonly IResourceProvider _resources;
    private readonly Lock _gate = new();

    /// <summary>入れた順。頭を打つときに、古いものから捨てるために持つ。</summary>
    private readonly Dictionary<string, DeliveredResource> _cache = new(StringComparer.Ordinal);
    private readonly List<string> _order = [];
    private int _cacheBytes;

    private readonly List<string> _changeLog = [];
    private (string Query, int Nth)? _mark;

    public ResourceDelivery(IResourceProvider resources) => _resources = resources;

    /// <summary>いま覚えている総量。頭が効いているかを検査が見る。</summary>
    public int CachedByteCount
    {
        get { lock (_gate) { return _cacheBytes; } }
    }

    /// <summary>CSS を書き換えた内訳。表示崩れの切り分けに使う。</summary>
    public IReadOnlyList<string> CssChangeLog
    {
        get { lock (_gate) { return [.. _changeLog]; } }
    }

    /// <summary>
    /// 本文へ入れる当たりの印。検索から飛ぶ前に置く。
    ///
    /// <para>
    /// 印は配信の瞬間に入れる。WebView の中で入れると、文字節を切って包む手術を
    /// JavaScript で書くことになり、抽出と数え方がずれる余地が残る。
    /// </para>
    /// </summary>
    public (string Query, int Nth)? SearchMark
    {
        get { lock (_gate) { return _mark; } }
        set { lock (_gate) { _mark = value; } }
    }

    // MARK: 経路

    /// <summary>章の経路から、WebView へ渡す URL を作る。</summary>
    public static string UrlOf(string href, string? fragment = null)
    {
        var path = string.Join('/', href.Split('/').Select(Uri.EscapeDataString));
        var url = $"{Origin}/{path}";
        return string.IsNullOrEmpty(fragment) ? url : $"{url}#{Uri.EscapeDataString(fragment)}";
    }

    /// <summary>URL から章の経路へ戻す。配信元が違えば null。</summary>
    public static string? HrefOf(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri))
        {
            return null;
        }
        if (!string.Equals(uri.GetLeftPart(UriPartial.Authority), Origin, StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }
        var path = uri.GetComponents(UriComponents.Path, UriFormat.UriEscaped);
        return Paths.PercentDecode(path);
    }

    // MARK: 配信

    /// <summary>
    /// 要求に応える。供給できなければ null（呼ぶ側が 404 にする）。
    ///
    /// <para>
    /// <paramref name="url"/> は要求された URL そのもの。配信元が違うものは受け取らない。
    /// 相対参照はここで正規化するので、<b>アーカイブの外を指す参照は取り出せずに弾かれる</b>。
    /// </para>
    /// </summary>
    public DeliveredResource? Deliver(string url)
    {
        if (HrefOf(url) is not { } raw)
        {
            return null;
        }
        return DeliverHref(raw);
    }

    /// <summary>経路を直に渡す形。URL を組み立てずに検査したいときに使う。</summary>
    public DeliveredResource? DeliverHref(string rawHref)
    {
        // 相対参照の正規化。アーカイブ外を指す参照は取り出せないので、ここで弾かれる。
        var href = Paths.Resolve(string.Empty, rawHref);
        if (href.Length == 0)
        {
            return null;
        }

        // 印の付き外れは配信時に決まるので、覚えておく鍵にも入れる。
        var wanted = SearchMark;
        var key = CacheKey(href, wanted);

        lock (_gate)
        {
            if (_cache.TryGetValue(key, out var found))
            {
                return found;
            }
        }

        byte[] raw;
        try
        {
            raw = _resources.Read(href);
        }
        catch (Exception)
        {
            return null; // 供給の範囲に無い。呼ぶ側が 404 にする。
        }

        var extension = ExtensionOf(href);
        var made = extension switch
        {
            "css" => Css(raw, href),
            "xhtml" or "html" or "htm" => Xhtml(raw, href, wanted),
            _ => new DeliveredResource(raw, MimeType(extension), null),
        };

        Store(key, extension, made);
        return made;
    }

    /// <summary>
    /// 抜粋を、書籍内リソースと同じ経路で配れるようにする。
    /// 対象と同じ階層へ置くことで、抜粋に含まれる相対参照がそのまま解決される。
    /// </summary>
    public void ProvideSynthetic(string path, string html)
    {
        var href = Paths.Resolve(string.Empty, path);
        // 書籍から切り出した断片は名前空間が欠けていることがある。寛容な HTML パーサへ渡す。
        var made = new DeliveredResource(Encoding.UTF8.GetBytes(html), "text/html; charset=utf-8",
                                         ContentSecurityPolicy);
        lock (_gate)
        {
            Remember(CacheKey(href, null), made);
        }
    }

    // MARK: 種類ごとの扱い

    private DeliveredResource Css(byte[] raw, string href)
    {
        var result = CssCompat.Rewrite(CssCompat.DecodeText(raw));
        Record(result.Changes, href);
        return new DeliveredResource(Encoding.UTF8.GetBytes(result.Css), "text/css; charset=utf-8", null);
    }

    private DeliveredResource Xhtml(byte[] raw, string href, (string Query, int Nth)? wanted)
    {
        var text = CssCompat.DecodeText(raw);
        var result = CssCompat.RewriteXhtml(text);
        var body = result.Css;
        if (wanted is { } mark)
        {
            body = Mark.Insert(body, mark.Query, mark.Nth) ?? body;
        }
        Record(result.Changes, href);

        var bytes = Encoding.UTF8.GetBytes(body);

        // XHTML として渡すのは、そう名乗っている文書だけにする。
        // HTML5 でも XML として妥当なことはあり、その場合に XHTML として解釈させると
        // 名前空間が付かず、<style> の中身が本文として表示されてしまう。
        var declaresXhtml = text.StartsWith("<?xml", StringComparison.Ordinal)
                            || text.Contains("xmlns=\"http://www.w3.org/1999/xhtml\"", StringComparison.Ordinal);
        var asXml = (ExtensionOf(href) == "xhtml" || declaresXhtml) && ParsesAsXml(bytes);

        return new DeliveredResource(
            bytes,
            asXml ? "application/xhtml+xml; charset=utf-8" : "text/html; charset=utf-8",
            ContentSecurityPolicy);
    }

    // MARK: 覚えておく

    /// <summary>覚えておく鍵。同じ章でも、印の有無で中身が変わる。</summary>
    private static string CacheKey(string href, (string Query, int Nth)? mark) =>
        mark is { } found ? $"{href}\0{found.Query}\0{found.Nth}" : href;

    private void Store(string key, string extension, DeliveredResource made)
    {
        if (!Cacheable.Contains(extension))
        {
            return;
        }
        lock (_gate)
        {
            Remember(key, made);
        }
    }

    /// <summary>覚える。総量が頭を越えたら、古いものから捨てる。呼ぶ側が鍵を持っていること。</summary>
    private void Remember(string key, DeliveredResource made)
    {
        if (_cache.TryGetValue(key, out var old))
        {
            _cacheBytes -= old.Body.Length;
            _order.Remove(key);
        }
        _cache[key] = made;
        _order.Add(key);
        _cacheBytes += made.Body.Length;

        while (_cacheBytes > CacheLimit && _order.Count > 0)
        {
            var oldest = _order[0];
            _order.RemoveAt(0);
            if (_cache.Remove(oldest, out var dropped))
            {
                _cacheBytes -= dropped.Body.Length;
            }
        }
    }

    private void Record(IReadOnlyList<CssCompat.Change> changes, string href)
    {
        if (changes.Count == 0)
        {
            return;
        }
        lock (_gate)
        {
            foreach (var change in changes)
            {
                _changeLog.Add($"{href}: {change.From}→{change.To} ({change.Count})");
            }
        }
    }

    // MARK: 補助

    private static string ExtensionOf(string href)
    {
        var name = href[(href.LastIndexOf('/') + 1)..];
        var dot = name.LastIndexOf('.');
        return dot < 0 ? string.Empty : name[(dot + 1)..].ToLowerInvariant();
    }

    private static bool ParsesAsXml(byte[] data)
    {
        try
        {
            using var stream = new MemoryStream(data);
            using var reader = XmlReader.Create(
                stream, new XmlReaderSettings { DtdProcessing = DtdProcessing.Ignore, XmlResolver = null });
            while (reader.Read())
            {
            }
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    public static string MimeType(string extension) => extension switch
    {
        "xhtml" or "html" or "htm" => "application/xhtml+xml",
        "css" => "text/css",
        "js" => "text/javascript",
        "png" => "image/png",
        "jpg" or "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "svg" => "image/svg+xml",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        "mp3" => "audio/mpeg",
        "mp4" or "m4v" => "video/mp4",
        "xml" or "ncx" or "opf" => "application/xml",
        _ => "application/octet-stream",
    };
}
