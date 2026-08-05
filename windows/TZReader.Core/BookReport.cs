using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace TZReader.Core;

/// <summary>
/// 書籍を開いたときに何が起きたかを、決定的な値だけで要約する。
/// アプリの診断画面と、実装間の突き合わせの両方で使う。
/// 環境やタイミングに依存する値（時刻、所要時間、絶対パス）は入れない。
/// </summary>
public sealed record BookReport
{
    public required string Format { get; init; }
    public required string Layout { get; init; }
    public required string Direction { get; init; }
    public required int SpineCount { get; init; }
    public required int TocEntryCount { get; init; }
    public required int TocMaxDepth { get; init; }
    public required bool HasCover { get; init; }

    public required IReadOnlyList<string> MissingResources { get; init; }
    public required IReadOnlyList<string> MissingTocTargets { get; init; }
    public required IReadOnlyList<string> MissingSpineItems { get; init; }

    public required int CssFileCount { get; init; }
    public required int NonUtf8CssCount { get; init; }
    public required int LegacyCssFileCount { get; init; }
    public required IReadOnlyList<CssCompat.Change> CssChanges { get; init; }

    public required int XhtmlCount { get; init; }
    public required int MalformedXhtmlCount { get; init; }

    public required int ImageCount { get; init; }
    public required int FontCount { get; init; }
    public required int StoredEntryCount { get; init; }
    public required int DeflatedEntryCount { get; init; }
    public required bool HasEncryptionMetadata { get; init; }

    public bool IsHealthy =>
        MissingResources.Count == 0 && MissingTocTargets.Count == 0
        && MissingSpineItems.Count == 0 && MalformedXhtmlCount == 0;

    public static BookReport Make(EpubArchive archive, EpubPublication publication)
    {
        var missingResources = new List<string>();
        var missingSpine = new List<string>();
        var cssFiles = 0;
        var nonUtf8 = 0;
        var legacyCss = 0;
        var changeTotals = new Dictionary<string, CssCompat.Change>(StringComparer.Ordinal);
        var xhtml = 0;
        var malformed = 0;
        var images = 0;
        var fonts = 0;
        var stored = 0;
        var deflated = 0;

        foreach (var name in archive.Names.OrderBy(n => n, StringComparer.Ordinal))
        {
            if (archive.IsStored(name))
            {
                stored++;
            }
            else
            {
                deflated++;
            }

            switch (Extension(name))
            {
                case "css":
                    cssFiles++;
                    byte[] cssData;
                    try
                    {
                        cssData = archive.Read(name);
                    }
                    catch (Exception)
                    {
                        continue;
                    }
                    if (!IsValidUtf8(cssData))
                    {
                        nonUtf8++;
                    }
                    var cssText = CssCompat.DecodeText(cssData);
                    if (!cssText.Contains("-epub-", StringComparison.Ordinal))
                    {
                        continue;
                    }
                    legacyCss++;
                    foreach (var change in CssCompat.Rewrite(cssText).Changes)
                    {
                        var key = change.From + "→" + change.To;
                        changeTotals[key] = changeTotals.TryGetValue(key, out var existing)
                            ? existing with { Count = existing.Count + change.Count }
                            : change;
                    }
                    break;

                case "xhtml":
                case "html":
                case "htm":
                    xhtml++;
                    try
                    {
                        var text = CssCompat.DecodeText(archive.Read(name));
                        var normalized = CssCompat.RewriteXhtml(text).Css;
                        if (!ParsesAsXml(normalized))
                        {
                            malformed++;
                        }
                    }
                    catch (Exception)
                    {
                        malformed++;
                    }
                    break;

                case "png" or "jpg" or "jpeg" or "gif" or "svg" or "webp":
                    images++;
                    break;

                case "ttf" or "otf" or "woff" or "woff2":
                    fonts++;
                    break;
            }
        }

        foreach (var link in publication.ReadingOrder.Where(l => !archive.Contains(l.Href)))
        {
            missingSpine.Add(link.Href);
        }

        var tocTargets = new List<string>();
        var maxDepth = 0;
        var entryCount = 0;

        void Walk(IReadOnlyList<TocEntry> entries, int depth)
        {
            if (entries.Count == 0)
            {
                return;
            }
            maxDepth = Math.Max(maxDepth, depth);
            foreach (var entry in entries)
            {
                entryCount++;
                if (entry.Href is not null && !archive.Contains(entry.Href))
                {
                    tocTargets.Add(entry.Href);
                }
                Walk(entry.Children, depth + 1);
            }
        }
        Walk(publication.TableOfContents, 1);

        // 章から参照されている画像や CSS のうち、実体が無いものを拾う。
        foreach (var link in publication.ReadingOrder)
        {
            byte[] data;
            try
            {
                data = archive.Read(link.Href);
            }
            catch (Exception)
            {
                continue;
            }
            var basePath = EpubParser.DirectoryOf(link.Href);
            foreach (var reference in References(CssCompat.DecodeText(data)))
            {
                var resolved = Paths.Resolve(basePath, reference);
                if (resolved.Length > 0 && !archive.Contains(resolved) && !missingResources.Contains(resolved))
                {
                    missingResources.Add(resolved);
                }
            }
        }

        return new BookReport
        {
            Format = publication.Layout == PublicationLayout.Fixed ? "fixedEPUB" : "reflowableEPUB",
            Layout = publication.Layout == PublicationLayout.Fixed ? "fixed" : "reflowable",
            Direction = publication.Direction == ReadingDirection.Rtl ? "rtl" : "ltr",
            SpineCount = publication.ReadingOrder.Count,
            TocEntryCount = entryCount,
            TocMaxDepth = maxDepth,
            HasCover = publication.CoverHref is not null,
            MissingResources = missingResources.Order(StringComparer.Ordinal).ToList(),
            MissingTocTargets = tocTargets.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToList(),
            MissingSpineItems = missingSpine.Order(StringComparer.Ordinal).ToList(),
            CssFileCount = cssFiles,
            NonUtf8CssCount = nonUtf8,
            LegacyCssFileCount = legacyCss,
            CssChanges = changeTotals.Values
                .OrderBy(c => c.From, StringComparer.Ordinal)
                .ThenBy(c => c.To, StringComparer.Ordinal)
                .ToList(),
            XhtmlCount = xhtml,
            MalformedXhtmlCount = malformed,
            ImageCount = images,
            FontCount = fonts,
            StoredEntryCount = stored,
            DeflatedEntryCount = deflated,
            HasEncryptionMetadata = archive.Contains("META-INF/encryption.xml"),
        };
    }

    /// <summary>章が参照している src / href のうち、外部 URL と fragment 以外を返す。</summary>
    private static IEnumerable<string> References(string html)
    {
        foreach (Match match in Regex.Matches(
            html, @"(?:src|href|xlink:href)\s*=\s*[""']([^""']+)[""']", RegexOptions.IgnoreCase))
        {
            var raw = match.Groups[1].Value.Trim();
            if (raw.Length == 0 || raw.StartsWith('#') || raw.StartsWith("data:", StringComparison.Ordinal))
            {
                continue;
            }
            if (raw.Contains("://", StringComparison.Ordinal) || raw.StartsWith("mailto:", StringComparison.Ordinal))
            {
                continue;
            }
            var path = Paths.StripFragment(raw).Path;
            if (path.Length > 0)
            {
                yield return path;
            }
        }
    }

    private static string Extension(string name)
    {
        var index = name.LastIndexOf('.');
        return index < 0 ? string.Empty : name[(index + 1)..].ToLowerInvariant();
    }

    private static bool IsValidUtf8(byte[] data)
    {
        try
        {
            new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(data);
            return true;
        }
        catch (DecoderFallbackException)
        {
            return false;
        }
    }

    internal static bool ParsesAsXml(string text)
    {
        try
        {
            using var reader = System.Xml.XmlReader.Create(
                new StringReader(text),
                new System.Xml.XmlReaderSettings
                {
                    DtdProcessing = System.Xml.DtdProcessing.Ignore,
                    XmlResolver = null,
                });
            XDocument.Load(reader);
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }
}
