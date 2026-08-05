using System.Xml.Linq;

namespace TZReader.Core;

/// <summary>
/// container.xml から OPF を辿り、spine・目次・書誌情報を取り出す。
/// 名前空間の宣言は書籍ごとにまちまちなので、要素は局所名で照合する。
/// </summary>
public static class EpubParser
{
    public static EpubPublication Parse(EpubArchive archive)
    {
        var opfPath = RootfilePath(archive) ?? throw DocumentException.MissingContainer();
        if (!archive.Contains(opfPath))
        {
            throw DocumentException.MissingOpf(opfPath);
        }

        XDocument opf;
        try
        {
            opf = LoadXml(archive.Read(opfPath));
        }
        catch (Exception e)
        {
            throw DocumentException.CannotParseOpf(e.Message);
        }

        var opfDirectory = DirectoryOf(opfPath);

        // manifest
        var manifest = new Dictionary<string, Link>(StringComparer.Ordinal);
        string? coverId = null;
        foreach (var item in Elements(opf.Root, "manifest").SelectMany(m => Elements(m, "item")))
        {
            var id = Attribute(item, "id");
            var rawHref = Attribute(item, "href");
            if (id is null || rawHref is null)
            {
                continue;
            }
            var href = Paths.Resolve(opfDirectory, Paths.StripFragment(rawHref).Path);
            var properties = (Attribute(item, "properties") ?? string.Empty)
                .Split(' ', StringSplitOptions.RemoveEmptyEntries).ToHashSet(StringComparer.Ordinal);
            manifest[id] = new Link(href, Attribute(item, "media-type") ?? string.Empty, id, properties);
            if (properties.Contains("cover-image"))
            {
                coverId = id;
            }
        }

        // spine
        var readingOrder = new List<Link>();
        var spineProperties = new List<string>();
        var spine = Elements(opf.Root, "spine").FirstOrDefault();
        foreach (var itemref in spine is null ? [] : Elements(spine, "itemref"))
        {
            var idref = Attribute(itemref, "idref");
            if (idref is null || !manifest.TryGetValue(idref, out var link))
            {
                continue;
            }
            // linear="no" は本文の流れに入れない補助ページ。読み順からは外す。
            if (Attribute(itemref, "linear") == "no")
            {
                continue;
            }
            var properties = Attribute(itemref, "properties") ?? string.Empty;
            spineProperties.Add(properties);
            var merged = new HashSet<string>(link.Properties, StringComparer.Ordinal);
            foreach (var value in properties.Split(' ', StringSplitOptions.RemoveEmptyEntries))
            {
                merged.Add(value);
            }
            readingOrder.Add(link with { Properties = merged });
        }

        if (readingOrder.Count == 0)
        {
            throw DocumentException.EmptySpine();
        }

        // 書誌情報
        var metadata = Elements(opf.Root, "metadata").FirstOrDefault();
        List<string> MetaValues(string name) =>
            (metadata is null ? [] : Elements(metadata, name))
            .Select(e => e.Value.Trim())
            .Where(v => v.Length > 0)
            .ToList();

        var titles = MetaValues("title");
        var authors = MetaValues("creator");
        var languages = MetaValues("language");
        var identifiers = MetaValues("identifier");

        // レイアウト種別
        var renditionLayout = Descendants(opf.Root, "meta")
            .FirstOrDefault(e => Attribute(e, "property") == "rendition:layout")?.Value.Trim();
        var layout = renditionLayout == "pre-paginated" ? PublicationLayout.Fixed : PublicationLayout.Reflowable;
        if (layout == PublicationLayout.Reflowable
            && spineProperties.Any(p => p.Contains("rendition:layout-pre-paginated", StringComparison.Ordinal)))
        {
            layout = PublicationLayout.Fixed;
        }

        var direction = Attribute(spine, "page-progression-direction") == "rtl"
            ? ReadingDirection.Rtl : ReadingDirection.Ltr;

        // 表紙
        coverId ??= Descendants(opf.Root, "meta")
            .FirstOrDefault(e => Attribute(e, "name") == "cover") is { } coverMeta
            ? Attribute(coverMeta, "content") : null;
        var coverHref = coverId is not null && manifest.TryGetValue(coverId, out var coverLink)
            ? coverLink.Href : null;

        // 目次。EPUB3 の nav を優先し、無ければ EPUB2 の NCX を読む。
        var toc = new List<TocEntry>();
        var navLink = manifest.Values.FirstOrDefault(l => l.Properties.Contains("nav"));
        if (navLink is not null && archive.Contains(navLink.Href))
        {
            toc = ParseNavDocument(archive.Read(navLink.Href), DirectoryOf(navLink.Href));
        }
        if (toc.Count == 0)
        {
            var ncxId = Attribute(spine, "toc");
            var ncxLink = ncxId is not null && manifest.TryGetValue(ncxId, out var byId)
                ? byId
                : manifest.Values.FirstOrDefault(l => l.MediaType == "application/x-dtbncx+xml");
            if (ncxLink is not null && archive.Contains(ncxLink.Href))
            {
                toc = ParseNcx(archive.Read(ncxLink.Href), DirectoryOf(ncxLink.Href));
            }
        }
        if (toc.Count == 0)
        {
            toc = readingOrder
                .Select(link => new TocEntry(LastComponent(link.Href), link.Href, null, null, []))
                .ToList();
        }

        return new EpubPublication
        {
            Title = titles.Count > 0 ? titles[0] : "(無題)",
            Authors = authors,
            Language = languages.FirstOrDefault(),
            Identifier = identifiers.FirstOrDefault(),
            ReadingOrder = readingOrder,
            TableOfContents = toc,
            CoverHref = coverHref,
            Layout = layout,
            Direction = direction,
        };
    }

    // MARK: 目次

    private static List<TocEntry> ParseNavDocument(byte[] data, string basePath)
    {
        XDocument document;
        try
        {
            document = LoadXml(data);
        }
        catch (Exception)
        {
            return [];
        }

        var navs = Descendants(document.Root, "nav").ToList();
        var tocNav = navs.FirstOrDefault(nav =>
        {
            var type = Attribute(nav, "type", "http://www.idpf.org/2007/ops") ?? Attribute(nav, "type");
            return type?.Contains("toc", StringComparison.Ordinal) == true;
        }) ?? navs.FirstOrDefault();

        var list = tocNav is null ? null : Descendants(tocNav, "ol").FirstOrDefault();
        return list is null ? [] : ParseNavList(list, basePath);
    }

    private static List<TocEntry> ParseNavList(XElement list, string basePath)
    {
        var entries = new List<TocEntry>();
        foreach (var item in list.Elements().Where(e => LocalName(e) == "li"))
        {
            var anchor = item.Elements().FirstOrDefault(e => LocalName(e) is "a" or "span");
            var title = (anchor?.Value ?? string.Empty).Trim();

            string? href = null;
            string? fragment = null;
            var rawHref = anchor is null ? null : Attribute(anchor, "href");
            if (rawHref is not null)
            {
                var parts = Paths.StripFragment(rawHref);
                if (parts.Path.Length > 0)
                {
                    href = Paths.Resolve(basePath, parts.Path);
                }
                fragment = parts.Fragment;
            }

            var sublist = item.Elements().FirstOrDefault(e => LocalName(e) == "ol");
            var children = sublist is null ? [] : ParseNavList(sublist, basePath);

            if (title.Length > 0 || href is not null || children.Count > 0)
            {
                entries.Add(new TocEntry(title.Length == 0 ? "(無題)" : title, href, fragment, null, children));
            }
        }
        return entries;
    }

    private static List<TocEntry> ParseNcx(byte[] data, string basePath)
    {
        XDocument document;
        try
        {
            document = LoadXml(data);
        }
        catch (Exception)
        {
            return [];
        }

        var navMap = Descendants(document.Root, "navMap").FirstOrDefault();
        return navMap is null ? [] : ParseNavPoints(navMap, basePath);
    }

    private static List<TocEntry> ParseNavPoints(XElement parent, string basePath)
    {
        var entries = new List<TocEntry>();
        foreach (var point in parent.Elements().Where(e => LocalName(e) == "navPoint"))
        {
            var label = point.Elements().FirstOrDefault(e => LocalName(e) == "navLabel");
            var title = (label?.Elements().FirstOrDefault(e => LocalName(e) == "text")?.Value ?? string.Empty).Trim();

            string? href = null;
            string? fragment = null;
            var content = point.Elements().FirstOrDefault(e => LocalName(e) == "content");
            var src = content is null ? null : Attribute(content, "src");
            if (src is not null)
            {
                var parts = Paths.StripFragment(src);
                if (parts.Path.Length > 0)
                {
                    href = Paths.Resolve(basePath, parts.Path);
                }
                fragment = parts.Fragment;
            }

            entries.Add(new TocEntry(title.Length == 0 ? "(無題)" : title, href, fragment, null,
                                     ParseNavPoints(point, basePath)));
        }
        return entries;
    }

    // MARK: 補助

    private static string? RootfilePath(EpubArchive archive)
    {
        if (!archive.Contains("META-INF/container.xml"))
        {
            return null;
        }
        try
        {
            var document = LoadXml(archive.Read("META-INF/container.xml"));
            var rootfile = Descendants(document.Root, "rootfile").FirstOrDefault();
            var value = rootfile is null ? null : Attribute(rootfile, "full-path");
            return value is null ? null : Paths.PercentDecode(value);
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static XDocument LoadXml(byte[] data)
    {
        // 外部実体は読み込まない。書籍が外部を参照しても取りに行かせない。
        using var stream = new MemoryStream(data);
        var settings = new System.Xml.XmlReaderSettings
        {
            DtdProcessing = System.Xml.DtdProcessing.Ignore,
            XmlResolver = null,
        };
        using var reader = System.Xml.XmlReader.Create(stream, settings);
        return XDocument.Load(reader);
    }

    private static string LocalName(XElement element) => element.Name.LocalName;

    private static IEnumerable<XElement> Elements(XElement? parent, string localName) =>
        parent is null ? [] : parent.Elements().Where(e => LocalName(e) == localName);

    private static IEnumerable<XElement> Descendants(XElement? root, string localName) =>
        root is null ? [] : root.Descendants().Where(e => LocalName(e) == localName);

    private static string? Attribute(XElement? element, string name, string? ns = null)
    {
        if (element is null)
        {
            return null;
        }
        if (ns is not null)
        {
            return element.Attribute(XName.Get(name, ns))?.Value;
        }
        // 名前空間の有無にかかわらず、局所名で拾う。
        return element.Attributes().FirstOrDefault(a => a.Name.LocalName == name)?.Value;
    }

    internal static string DirectoryOf(string path)
    {
        var index = path.LastIndexOf('/');
        return index < 0 ? string.Empty : path[..index];
    }

    internal static string LastComponent(string path)
    {
        var index = path.LastIndexOf('/');
        return index < 0 ? path : path[(index + 1)..];
    }
}
