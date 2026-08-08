using System.Globalization;

namespace ChoroReader.Core;

public enum ReaderTheme
{
    Light,
    Sepia,
    Dark,
}

public static class ReaderThemes
{
    public static string Background(this ReaderTheme theme) => theme switch
    {
        ReaderTheme.Light => "#ffffff",
        ReaderTheme.Sepia => "#f6efe2",
        _ => "#1c1c1e",
    };

    public static string Foreground(this ReaderTheme theme) => theme switch
    {
        ReaderTheme.Light => "#1a1a1a",
        ReaderTheme.Sepia => "#3a3226",
        _ => "#d6d6d6",
    };

    public static string Link(this ReaderTheme theme) => theme switch
    {
        ReaderTheme.Light => "#0b5cad",
        ReaderTheme.Sepia => "#8a5a1a",
        _ => "#79b1ff",
    };

    public static string CodeBackground(this ReaderTheme theme) => theme switch
    {
        ReaderTheme.Light => "#f4f4f6",
        ReaderTheme.Sepia => "#ece3d2",
        _ => "#2b2b2e",
    };

    public static ReaderTheme Parse(string? value) => value?.ToLowerInvariant() switch
    {
        "sepia" => ReaderTheme.Sepia,
        "dark" => ReaderTheme.Dark,
        _ => ReaderTheme.Light,
    };
}

/// <summary>
/// 表示設定の値そのもの。生成する CSS は入力から一意に決まるため、実装間で揃える対象になる。
/// </summary>
public sealed record ReaderStyle
{
    public double FontSizePercent { get; init; } = 100;
    public double LineHeight { get; init; } = 1.8;
    public double MaxWidthEm { get; init; } = 42;
    public ReaderTheme Theme { get; init; } = ReaderTheme.Light;
    public string BodyFont { get; init; } = string.Empty;
    public string CodeFont { get; init; } = "SF Mono";
    public bool CodeWrap { get; init; }
    public bool PublisherStyle { get; init; }

    /// <summary>暗いテーマでは、背景色を持たない要素にだけ文字色を当てる。その印付けが要るかどうか。</summary>
    public bool NeedsForegroundMarking => !PublisherStyle && Theme == ReaderTheme.Dark;

    /// <summary>本文へ被せるスタイル。出版社 CSS を壊さない範囲に絞る。</summary>
    public string Css()
    {
        var background = Theme.Background();
        var foreground = Theme.Foreground();
        var widthRule = MaxWidthEm > 0
            ? $"max-width: {(int)MaxWidthEm}em !important;"
            : string.Empty;
        var bodyFontRule = BodyFont.Length == 0
            ? string.Empty
            : $"font-family: \"{BodyFont}\", serif !important;";

        // 出版社スタイル優先のときは、色と幅だけを最小限に整える。
        if (PublisherStyle)
        {
            return $$"""
            html { background-color: {{background}} !important; }
            body { {{widthRule}} margin-left: auto !important; margin-right: auto !important; }
            img, svg, video { max-width: 100% !important; height: auto !important; }
            pre { overflow-x: auto; }
            """;
        }

        // 文字色の上書きは暗いテーマだけに限る。
        // 明るいテーマとセピアでは、出版社の配色は明るい紙を前提に組まれていてそのまま読める。
        // 一律に上書きすると、見出しの黒帯のように背景色を持つ要素から文字色を奪ってしまう。
        var colorRules = Theme == ReaderTheme.Dark
            ? $$"""
            body { color: {{foreground}} !important; }
            /* 背景色を持たない要素だけに当てる。印は choroApplyForeground が付ける。 */
            .choro-fg { color: {{foreground}} !important; }
            a.choro-fg, .choro-fg a:not([class]) { color: {{Theme.Link()}} !important; }
            """
            : $$"""body { color: {{foreground}}; }""";

        var lineHeight = LineHeight.ToString("F2", CultureInfo.InvariantCulture);

        return $$"""
        html {
            font-size: {{(int)FontSizePercent}}% !important;
            background-color: {{background}} !important;
            -webkit-text-size-adjust: none;
        }
        body {
            line-height: {{lineHeight}} !important;
            {{widthRule}}
            margin: 0 auto !important;
            padding: 2em 1.6em 6em !important;
            background-color: {{background}} !important;
            {{bodyFontRule}}
        }
        {{colorRules}}
        img, svg, video { max-width: 100% !important; height: auto !important; }
        table { max-width: 100% !important; display: block; overflow-x: auto; }
        /* コードは等幅で読めることを最優先にし、内側の色付けには触れない */
        pre, code, kbd, samp {
            font-family: "{{CodeFont}}", ui-monospace, Menlo, monospace !important;
            background-color: {{Theme.CodeBackground()}} !important;
        }
        pre {
            padding: 0.8em 1em !important;
            border-radius: 6px;
            overflow-x: auto !important;
            white-space: {{(CodeWrap ? "pre-wrap" : "pre")}} !important;
            word-break: {{(CodeWrap ? "break-all" : "normal")}} !important;
        }
        """;
    }
}
