using System.Text;
using ChoroReader.Core;

namespace ChoroReader.Tests;

/// <summary>
/// 本文のバイト列を文字にする。
///
/// <para>
/// <b>読み違えても例外は出ない。</b>別の符号化として解けてしまえば、文字化けした本文が
/// そのまま並ぶだけである。使ってみるまで気付けない。
/// </para>
/// <para>
/// Shift_JIS と EUC-JP は .NET では既定で使えず、<c>CodePagesEncodingProvider</c> を
/// 登録して初めて引ける。<b>登録を落とすと、UTF-8 でない書籍が黙って化ける。</b>
/// ここがその防壁である。
/// </para>
/// </summary>
public class TextDecodingTests
{
    public TextDecodingTests() => CssCompat.RegisterEncodings();

    [Fact]
    public void UTF8はそのまま読める()
    {
        Assert.Equal("日本語", CssCompat.DecodeText(Encoding.UTF8.GetBytes("日本語")));
    }

    /// <summary>
    /// Shift_JIS の「日本語」。UTF-8 としては解けない並びなので、そちらへ落ちる。
    /// <b>符号化の登録が無いと、ここで化ける。</b>
    /// </summary>
    [Fact]
    public void ShiftJISを読める()
    {
        byte[] sjis = [0x93, 0xFA, 0x96, 0x7B, 0x8C, 0xEA];

        Assert.Equal("日本語", CssCompat.DecodeText(sjis));
    }

    /// <summary>UTF-8 が先。両方で解ける並びは UTF-8 として読む。</summary>
    [Fact]
    public void UTF8を先に試す()
    {
        // 「あ」の UTF-8（E3 81 82）は Shift_JIS でも半角片仮名として解けてしまう。
        Assert.Equal("あ", CssCompat.DecodeText(Encoding.UTF8.GetBytes("あ")));
    }

    [Fact]
    public void 空でも落ちない() => Assert.Equal("", CssCompat.DecodeText([]));
}
