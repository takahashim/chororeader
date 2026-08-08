using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ChoroReader.Core;

namespace ChoroReader.App;

/// <summary>
/// 書棚に並べる表紙を、1 度だけ取り出して置いておく。
///
/// <para>
/// 書棚を開くたびに書籍を開き直すわけにはいかない。
/// EPUB は数十メガあり、PDF は数百ページある。一覧のために毎回それを触るのは重い。
/// 原寸で持つ必要もないので、縮小したものを LocalAppData の下へ書く。
/// </para>
/// <para>
/// 取り出しの筋は <see cref="Covers"/>（Core）にあり、macOS でも検査できる。
/// ここがやるのは<b>復号・縮小・書き出し</b>だけである。
/// </para>
/// </summary>
internal static class CoverCache
{
    /// <summary>書棚の升目に収める幅。画面の倍率を見込んで少し大きめに持つ。</summary>
    private const int Width = 320;

    private static string Directory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "ChoroReader", "covers");

    /// <summary>
    /// 置き場所の名前。
    ///
    /// <para>
    /// 経路をそのまま名前にはできない（区切りも長さも通らない）ので、要約を名前にする。
    /// 同じ書籍が同じ名前に落ちればよいだけなので、衝突しにくさ以上のものは要らない。
    /// </para>
    /// </summary>
    private static string NameOf(string bookPath)
    {
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(Paths.Normalize(bookPath)));
        return Convert.ToHexStringLower(digest)[..24] + ".png";
    }

    /// <summary>
    /// 表紙を出す。無ければ取り出して置いてから出す。
    ///
    /// <para>
    /// <b>取れない書籍はある。</b>表紙を持たない EPUB も、開けない PDF もある。
    /// そのときは <c>null</c> を返し、書棚は題名だけで並べる。
    /// </para>
    /// </summary>
    internal static BitmapSource? Of(string bookPath)
    {
        var where = Path.Combine(Directory, NameOf(bookPath));
        try
        {
            if (File.Exists(where))
            {
                return Read(where);
            }

            if (Draw(Covers.Of(bookPath)) is not { } drawn)
            {
                return null;
            }
            Write(drawn, where);
            return drawn;
        }
        catch (Exception)
        {
            // 表紙が出なくても書棚は並ぶ。
            return null;
        }
    }

    /// <summary>
    /// 置いてあるものを読む。
    ///
    /// <para>
    /// <b>読み終えたらファイルを離す。</b>掴んだままだと、表紙を取り直したいときに置き換えられない。
    /// <c>Freeze</c> するのは、背後のスレッドで読んだ絵を画面のスレッドで使うためである。
    /// </para>
    /// </summary>
    private static BitmapSource Read(string where)
    {
        var image = new BitmapImage();
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.UriSource = new Uri(where);
        image.EndInit();
        image.Freeze();
        return image;
    }

    private static void Write(BitmapSource image, string where)
    {
        System.IO.Directory.CreateDirectory(Path.GetDirectoryName(where)!);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(image));
        using var file = File.Create(where);
        encoder.Save(file);
    }

    /// <summary>取り出したものを、升目に収まる絵にする。</summary>
    private static BitmapSource? Draw(CoverSource? source) => source switch
    {
        EncodedCover encoded => Decode(encoded.Bytes),
        PixelCover pixels => Fit(FromPixels(pixels.Page)),
        _ => null,
    };

    /// <summary>
    /// 書籍に入っている画像を復号する。
    ///
    /// <para>
    /// <b>原寸まで復号しない。</b>表紙が全面写真だと数千画素あり、升目に置くには要らない。
    /// 幅を指定して復号すると、その大きさまでしか起こさない。
    /// </para>
    /// </summary>
    private static BitmapSource? Decode(byte[] bytes)
    {
        try
        {
            using var stream = new MemoryStream(bytes);
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.DecodePixelWidth = Width;
            image.StreamSource = stream;
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch (Exception)
        {
            // SVG の表紙など、復号できない形式はある。
            return null;
        }
    }

    private static BitmapSource FromPixels(RenderedPage drawn)
    {
        var image = BitmapSource.Create(
            drawn.Width, drawn.Height, 96, 96, PixelFormats.Rgb24, null, drawn.Pixels, drawn.Stride);
        image.Freeze();
        return image;
    }

    private static BitmapSource Fit(BitmapSource image)
    {
        if (image.PixelWidth <= Width)
        {
            return image;
        }
        var scale = (double)Width / image.PixelWidth;
        var scaled = new TransformedBitmap(image, new ScaleTransform(scale, scale));
        scaled.Freeze();
        return scaled;
    }
}
