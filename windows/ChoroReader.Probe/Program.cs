using System.Text.Json;
using System.Text.Json.Nodes;
using ChoroReader.Core;

namespace ChoroReader.Probe;

/// <summary>
/// 実装間の振る舞いを突き合わせるための CLI。
/// 出力の形は conformance/CONTRACT.md で定義し、macOS 版と同じ値を返す。
/// UI にもライブラリ保存にも触れない純粋な経路にしておく。
/// </summary>
public static class Program
{
    private const int SchemaVersion = 2;

    public static int Main(string[] rawArguments)
    {
        CssCompat.RegisterEncodings();

        // macOS 版は「ChoroReader probe <command>」で起動する。こちらも同じ形を受け付ける。
        var arguments = rawArguments.AsSpan();
        if (arguments.Length > 0 && arguments[0] == "probe")
        {
            arguments = arguments[1..];
        }

        if (arguments.Length == 0)
        {
            return Fail("usage: choroprobe probe "
                        + "<version|parse|report|style|text|preview|fixed|resolve|css|search|mark|detect> ...");
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
                "style" => Style(),
                "text" => Text(rest),
                "preview" => Preview(rest),
                "fixed" => Fixed(rest),
                "resolve" => Resolve(rest),
                "css" => Css(),
                "search" => Search(rest),
                "mark" => MarkCommand(rest),
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

    /// <summary>表示設定から作る CSS。設定は標準入力から JSON で受け取る。</summary>
    private static int Style()
    {
        var input = ReadStandardInput();
        var style = ParseStyle(input);

        return Emit(new JsonObject
        {
            ["schema"] = SchemaVersion,
            ["command"] = "style",
            ["css"] = NormalizeNewlines(style.Css()),
            ["needsForegroundMarking"] = style.NeedsForegroundMarking,
        });
    }

    private static ReaderStyle ParseStyle(byte[] input)
    {
        if (input.Length == 0)
        {
            return new ReaderStyle();
        }
        try
        {
            var node = JsonNode.Parse(input)?.AsObject();
            if (node is null)
            {
                return new ReaderStyle();
            }
            var fallback = new ReaderStyle();
            return new ReaderStyle
            {
                FontSizePercent = node["fontSizePercent"]?.GetValue<double>() ?? fallback.FontSizePercent,
                LineHeight = node["lineHeight"]?.GetValue<double>() ?? fallback.LineHeight,
                MaxWidthEm = node["maxWidthEm"]?.GetValue<double>() ?? fallback.MaxWidthEm,
                Theme = ReaderThemes.Parse(node["theme"]?.GetValue<string>()),
                BodyFont = node["bodyFont"]?.GetValue<string>() ?? fallback.BodyFont,
                CodeFont = node["codeFont"]?.GetValue<string>() ?? fallback.CodeFont,
                CodeWrap = node["codeWrap"]?.GetValue<bool>() ?? fallback.CodeWrap,
                PublisherStyle = node["publisherStyle"]?.GetValue<bool>() ?? fallback.PublisherStyle,
            };
        }
        catch (Exception)
        {
            return new ReaderStyle();
        }
    }

    /// <summary>章から取り出した本文。検索も診断も抜粋もこの結果に乗っているため、ここを揃える。</summary>
    private static int Text(string[] args)
    {
        if (args.Length < 2)
        {
            return Fail("usage: probe text <epub> <href>");
        }
        using var archive = new EpubArchive(args[0]);
        var source = archive.ReadText(args[1])
                     ?? throw DocumentException.BrokenArchive($"{args[1]} を読めない");
        var extracted = HtmlText.Extract(source);

        return Emit(new JsonObject
        {
            ["schema"] = SchemaVersion,
            ["command"] = "text",
            ["href"] = Norm(args[1]),
            ["text"] = Norm(extracted.Text),
            ["codeRanges"] = Array(extracted.CodeRanges.Select(r => (JsonNode?)new JsonArray(r.Start, r.End))),
        });
    }

    /// <summary>リンク先の抜粋。整形の細部ではなく、どこを切り出したかを揃える。</summary>
    private static int Preview(string[] args)
    {
        if (args.Length < 2)
        {
            return Fail("usage: probe preview <epub> <href> [fragment]");
        }
        using var archive = new EpubArchive(args[0]);
        var fragment = args.Length >= 3 && args[2].Length > 0 ? args[2] : null;
        var built = PreviewProvider.Make(archive, args[1], fragment, string.Empty);

        return Emit(new JsonObject
        {
            ["schema"] = SchemaVersion,
            ["command"] = "preview",
            ["path"] = built is null ? null : JsonValue.Create(Norm(built.Path)),
            ["isFootnote"] = built?.IsFootnote ?? false,
            // 抜粋に混ざる自前の CSS は比較の対象にしない。
            ["text"] = built is null ? null : JsonValue.Create(Norm(HtmlText.Extract(built.Html).Text.Trim())),
        });
    }

    /// <summary>固定レイアウトの組み立て。ページの種別と、見開きの組み方を揃える。</summary>
    private static int Fixed(string[] args)
    {
        if (args.Length < 1)
        {
            return Fail("usage: probe fixed <epub> [ページ番号]");
        }
        using var archive = new EpubArchive(args[0]);
        var publication = EpubParser.Parse(archive);
        var page = args.Length >= 2 && int.TryParse(args[1], out var parsed) ? parsed : 0;
        var rtl = publication.Direction == ReadingDirection.Rtl;
        var spreads = FixedLayoutPlan.Spreads(publication.ReadingOrder.Count);

        var pages = publication.ReadingOrder.Select((link, index) =>
        {
            var content = FixedLayoutPlan.Content(link.Href, archive);
            return (JsonNode?)new JsonObject
            {
                ["index"] = index,
                ["kind"] = content.Kind,
                ["href"] = Norm(content.Href),
            };
        });

        var spreadForPage = spreads.FirstOrDefault(s => s.Contains(page)) ?? [page];

        return Emit(new JsonObject
        {
            ["schema"] = SchemaVersion,
            ["command"] = "fixed",
            ["direction"] = rtl ? "rtl" : "ltr",
            ["pages"] = Array(pages),
            ["spreads"] = Array(spreads.Select(s => (JsonNode?)new JsonArray(s.Select(i => (JsonNode?)i).ToArray()))),
            ["spreadForPage"] = new JsonArray(spreadForPage.Select(i => (JsonNode?)i).ToArray()),
        });
    }

    private static byte[] ReadStandardInput()
    {
        using var input = Console.OpenStandardInput();
        using var buffer = new MemoryStream();
        input.CopyTo(buffer);
        return buffer.ToArray();
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
        var result = CssCompat.Rewrite(CssCompat.DecodeText(ReadStandardInput()));
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
                // ちょうど半分のときは 0 から遠い側へ寄せる（四捨五入）。
                ["progression"] = Math.Round(r.Locator.Progression, 3, MidpointRounding.AwayFromZero),
                ["match"] = Norm(r.Match),
                ["isCode"] = r.IsCode,
                // 章の中で何番目の当たりか。飛んだ先で押した当たりを選び直すのに使うので、
                // 実装どうしで食い違うと、開き直した窓が別の語を強調することになる。
                ["nth"] = r.Nth,
            })),
        });
    }

    /// <summary>
    /// 検索結果から飛んだ先で、どの語をどこで囲むか。
    ///
    /// 囲んだ HTML を丸ごと比べると、実装ごとの細部で偽の差分が出る。
    /// 囲んだ語と、その直前にある本文で示す。置いた場所が同じかどうかはこれで分かる。
    /// </summary>
    private static int MarkCommand(string[] args)
    {
        const string Usage = "usage: probe mark <epub> <href> <query> [nth]";
        if (args.Length < 3)
        {
            return Fail(Usage);
        }
        var nth = args.Length >= 4 && int.TryParse(args[3], out var parsed) ? parsed : 0;

        using var archive = new EpubArchive(args[0]);
        var source = archive.ReadText(args[1])
                     ?? throw DocumentException.BrokenArchive($"{args[1]} を読めない");
        // 配るときと同じ順で通す。印は書き換えたあとの本文へ入る。
        var html = CssCompat.RewriteXhtml(source).Css;

        var output = new JsonObject
        {
            ["schema"] = SchemaVersion,
            ["command"] = "mark",
            ["href"] = Norm(args[1]),
            ["query"] = Norm(args[2]),
            ["nth"] = nth,
        };
        if (Mark.Locate(html, args[2], nth) is { } placement)
        {
            output["found"] = true;
            output["marked"] = Norm(placement.Marked);
            output["before"] = Norm(placement.Before);
        }
        else
        {
            output["found"] = false;
        }
        return Emit(output);
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
