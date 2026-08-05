using System.Text.Json;
using System.Text.Json.Nodes;
using TZReader.Core;

namespace TZReader.Probe;

/// <summary>
/// 実装間の振る舞いを突き合わせるための CLI。
/// 出力の形は conformance/CONTRACT.md で定義し、macOS 版と同じ値を返す。
/// UI にもライブラリ保存にも触れない純粋な経路にしておく。
/// </summary>
public static class Program
{
    private const int SchemaVersion = 1;

    public static int Main(string[] rawArguments)
    {
        CssCompat.RegisterEncodings();

        // macOS 版は「TZReader probe <command>」で起動する。こちらも同じ形を受け付ける。
        var arguments = rawArguments.AsSpan();
        if (arguments.Length > 0 && arguments[0] == "probe")
        {
            arguments = arguments[1..];
        }

        if (arguments.Length == 0)
        {
            return Fail("usage: tzprobe probe <version|parse|report|resolve|css|search|detect> ...");
        }

        var command = arguments[0];
        var rest = arguments[1..].ToArray();

        try
        {
            return command switch
            {
                "version" => Emit(new JsonObject
                {
                    ["schema"] = SchemaVersion,
                    ["implementation"] = "csharp",
                }),
                "parse" => Parse(rest),
                "report" => Report(rest),
                "resolve" => Resolve(rest),
                "css" => Css(),
                "search" => Search(rest),
                "detect" => Detect(rest),
                "pdfspike" => PdfSpike.Run(rest),
                _ => Fail($"unknown command: {command}"),
            };
        }
        catch (DocumentException e)
        {
            return EmitError(e.Kind);
        }
    }

    // MARK: コマンド

    private static int Parse(string[] args)
    {
        if (args.Length < 1)
        {
            return Fail("usage: probe parse <epub>");
        }
        using var archive = new EpubArchive(args[0]);
        var publication = EpubParser.Parse(archive);

        return Emit(new JsonObject
        {
            ["schema"] = SchemaVersion,
            ["command"] = "parse",
            ["format"] = publication.Layout == PublicationLayout.Fixed ? "fixedEPUB" : "reflowableEPUB",
            ["title"] = Norm(publication.Title),
            ["authors"] = Array(publication.Authors.Select(a => (JsonNode?)Norm(a))),
            ["language"] = NormOrNull(publication.Language),
            ["identifier"] = NormOrNull(publication.Identifier),
            ["layout"] = publication.Layout == PublicationLayout.Fixed ? "fixed" : "reflowable",
            ["direction"] = publication.Direction == ReadingDirection.Rtl ? "rtl" : "ltr",
            ["coverHref"] = NormOrNull(publication.CoverHref),
            ["readingOrder"] = Array(publication.ReadingOrder.Select(link => (JsonNode?)new JsonObject
            {
                ["href"] = Norm(link.Href),
                ["mediaType"] = Norm(link.MediaType),
            })),
            ["tableOfContents"] = Array(publication.TableOfContents.Select(TocNode)),
        });
    }

    private static int Report(string[] args)
    {
        if (args.Length < 1)
        {
            return Fail("usage: probe report <epub>");
        }
        using var archive = new EpubArchive(args[0]);
        var publication = EpubParser.Parse(archive);
        var report = BookReport.Make(archive, publication);

        return Emit(new JsonObject
        {
            ["schema"] = SchemaVersion,
            ["command"] = "report",
            ["report"] = new JsonObject
            {
                ["format"] = report.Format,
                ["layout"] = report.Layout,
                ["direction"] = report.Direction,
                ["spineCount"] = report.SpineCount,
                ["tocEntryCount"] = report.TocEntryCount,
                ["tocMaxDepth"] = report.TocMaxDepth,
                ["hasCover"] = report.HasCover,
                ["missingResources"] = Array(report.MissingResources.Select(p => (JsonNode?)Norm(p))),
                ["missingTOCTargets"] = Array(report.MissingTocTargets.Select(p => (JsonNode?)Norm(p))),
                ["missingSpineItems"] = Array(report.MissingSpineItems.Select(p => (JsonNode?)Norm(p))),
                ["cssFileCount"] = report.CssFileCount,
                ["nonUTF8CSSCount"] = report.NonUtf8CssCount,
                ["legacyCSSFileCount"] = report.LegacyCssFileCount,
                ["cssChanges"] = Array(report.CssChanges.Select(ChangeNode)),
                ["xhtmlCount"] = report.XhtmlCount,
                ["malformedXHTMLCount"] = report.MalformedXhtmlCount,
                ["imageCount"] = report.ImageCount,
                ["fontCount"] = report.FontCount,
                ["storedEntryCount"] = report.StoredEntryCount,
                ["deflatedEntryCount"] = report.DeflatedEntryCount,
                ["hasEncryptionMetadata"] = report.HasEncryptionMetadata,
            },
        });
    }

    private static int Resolve(string[] args)
    {
        if (args.Length < 2)
        {
            return Fail("usage: probe resolve <base> <href>");
        }
        return Emit(new JsonObject
        {
            ["schema"] = SchemaVersion,
            ["command"] = "resolve",
            ["base"] = args[0],
            ["href"] = args[1],
            ["result"] = Norm(Paths.Resolve(args[0], args[1])),
        });
    }

    private static int Css()
    {
        using var input = Console.OpenStandardInput();
        using var buffer = new MemoryStream();
        input.CopyTo(buffer);

        var result = CssCompat.Rewrite(CssCompat.DecodeText(buffer.ToArray()));
        var changes = result.Changes
            .OrderBy(c => c.From, StringComparer.Ordinal)
            .ThenBy(c => c.To, StringComparer.Ordinal);

        return Emit(new JsonObject
        {
            ["schema"] = SchemaVersion,
            ["command"] = "css",
            ["output"] = NormalizeNewlines(result.Css),
            ["changes"] = Array(changes.Select(ChangeNode)),
        });
    }

    private static int Search(string[] args)
    {
        if (args.Length < 2)
        {
            return Fail("usage: probe search <epub> <query>");
        }
        using var archive = new EpubArchive(args[0]);
        var publication = EpubParser.Parse(archive);
        var outcome = DocumentSearch.SearchEpub(archive, publication, args[1]);

        return Emit(new JsonObject
        {
            ["schema"] = SchemaVersion,
            ["command"] = "search",
            ["query"] = Norm(args[1]),
            ["truncated"] = outcome.Truncated,
            ["results"] = Array(outcome.Results.Select(r => (JsonNode?)new JsonObject
            {
                ["href"] = Norm(r.Locator.Href ?? string.Empty),
                // 丸め方の差で落ちないよう、小数第 3 位へ揃える。
                ["progression"] = Math.Round(r.Locator.Progression, 3, MidpointRounding.ToEven),
                ["match"] = Norm(r.Match),
                ["isCode"] = r.IsCode,
            })),
        });
    }

    private static int Detect(string[] args)
    {
        if (args.Length < 1)
        {
            return Fail("usage: probe detect <file>");
        }

        var format = DocumentFormats.Detect(args[0]);
        if (format is null)
        {
            return Emit(DetectResult(null, "unsupportedFormat"));
        }

        switch (format)
        {
            case DocumentFormat.Pdf:
                // 描画には触れず、開けるかどうかだけを見る。
                return Emit(File.Exists(args[0]) && PdfProbe.CanOpen(args[0])
                    ? DetectResult("pdf", null)
                    : DetectResult(null, "cannotOpenPDF"));

            case DocumentFormat.Markdown:
                return Emit(DetectResult("markdown", null));

            default:
                try
                {
                    using var archive = new EpubArchive(args[0]);
                    var publication = EpubParser.Parse(archive);
                    return Emit(DetectResult(
                        publication.Layout == PublicationLayout.Fixed ? "fixedEPUB" : "reflowableEPUB", null));
                }
                catch (DocumentException e)
                {
                    return Emit(DetectResult(null, e.Kind));
                }
                catch (Exception)
                {
                    return Emit(DetectResult(null, "cannotParseOPF"));
                }
        }
    }

    // MARK: 出力

    private static JsonObject DetectResult(string? format, string? errorKind) => new()
    {
        ["schema"] = SchemaVersion,
        ["command"] = "detect",
        ["format"] = format is null ? null : JsonValue.Create(format),
        ["error"] = errorKind is null ? null : new JsonObject { ["kind"] = errorKind },
    };

    private static JsonNode? TocNode(TocEntry entry) => new JsonObject
    {
        ["title"] = Norm(entry.Title),
        ["href"] = NormOrNull(entry.Href),
        ["fragment"] = NormOrNull(entry.Fragment),
        ["children"] = Array(entry.Children.Select(TocNode)),
    };

    private static JsonNode? ChangeNode(CssCompat.Change change) => new JsonObject
    {
        ["from"] = change.From,
        ["to"] = change.To,
        ["count"] = change.Count,
    };

    private static JsonArray Array(IEnumerable<JsonNode?> nodes)
    {
        var array = new JsonArray();
        foreach (var node in nodes)
        {
            array.Add(node);
        }
        return array;
    }

    /// <summary>macOS は分解形（NFD）を返すことがあり Windows は合成形。比較のため NFC へ揃える。</summary>
    private static string Norm(string value) => Paths.Normalize(value);

    private static JsonNode? NormOrNull(string? value) => value is null ? null : JsonValue.Create(Norm(value));

    private static string NormalizeNewlines(string value) =>
        value.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n');

    private static int Emit(JsonNode node)
    {
        var options = new JsonSerializerOptions
        {
            WriteIndented = true,
            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        };
        StripNulls(node);
        Console.Out.Write(node.ToJsonString(options));
        Console.Out.Write('\n');
        return 0;
    }

    /// <summary>
    /// 値が無いキーは出力しない。macOS 版の JSONEncoder が nil のプロパティを省くため、
    /// 「キーが無い」と「キーがあって null」を揃えないと比較で差になる。
    /// </summary>
    private static void StripNulls(JsonNode node)
    {
        switch (node)
        {
            case JsonObject obj:
                foreach (var key in obj.Where(pair => pair.Value is null).Select(pair => pair.Key).ToList())
                {
                    obj.Remove(key);
                }
                foreach (var pair in obj)
                {
                    if (pair.Value is not null)
                    {
                        StripNulls(pair.Value);
                    }
                }
                break;

            case JsonArray array:
                foreach (var element in array)
                {
                    if (element is not null)
                    {
                        StripNulls(element);
                    }
                }
                break;
        }
    }

    private static int EmitError(string kind) => Emit(new JsonObject
    {
        ["schema"] = SchemaVersion,
        ["command"] = "error",
        ["error"] = new JsonObject { ["kind"] = kind },
    });

    private static int Fail(string message)
    {
        Console.Error.WriteLine(message);
        return 2;
    }
}
