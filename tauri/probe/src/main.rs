//! 実装間の振る舞いを突き合わせるための CLI。
//! 出力の形は conformance/CONTRACT.md で定義し、macOS 版・C# 版と同じ値を返す。
//! UI にもライブラリ保存にも触れない純粋な経路にしておく。

use std::io::Read;

use serde_json::{json, Map, Value};

use chororeader_core::archive::{EpubArchive, ResourceProvider};
use chororeader_core::fixed_layout;
use chororeader_core::publication::{detect_format, DocumentError, DocumentFormat, TocEntry};
use chororeader_core::style::{ReaderStyle, Theme};
use chororeader_core::{css_compat, epub_parser, html_text, mark, paths, pdf, preview, report, search};

const SCHEMA_VERSION: i64 = 2;

fn main() {
    let raw: Vec<String> = std::env::args().skip(1).collect();
    // macOS 版は「ChoroReader probe <command>」で起動する。こちらも同じ形を受け付ける。
    let arguments: &[String] = match raw.first().map(String::as_str) {
        Some("probe") => &raw[1..],
        _ => &raw,
    };

    let Some(command) = arguments.first() else {
        fail("usage: choroprobe probe <version|parse|report|style|text|preview|fixed|resolve|css|search|mark|detect> ...");
    };
    let rest = &arguments[1..];

    let outcome = match command.as_str() {
        "version" => Ok(json!({ "schema": SCHEMA_VERSION, "implementation": "rust" })),
        "parse" => parse(rest),
        "report" => report_command(rest),
        "style" => Ok(style()),
        "text" => text(rest),
        "preview" => preview_command(rest),
        "fixed" => fixed(rest),
        "resolve" => resolve(rest),
        "css" => Ok(css()),
        "search" => search_command(rest),
        "mark" => mark_command(rest),
        "detect" => detect(rest),
        other => fail(&format!("unknown command: {other}")),
    };

    match outcome {
        Ok(value) => emit(value),
        Err(error) => emit(json!({
            "schema": SCHEMA_VERSION,
            "command": "error",
            "error": { "kind": error.kind },
        })),
    }
}

// MARK: コマンド

fn parse(args: &[String]) -> Result<Value, DocumentError> {
    let path = arg(args, 0, "usage: probe parse <epub>");
    let archive = EpubArchive::open(path)?;
    let publication = epub_parser::parse(&archive)?;

    Ok(json!({
        "schema": SCHEMA_VERSION,
        "command": "parse",
        "format": publication.format_name(),
        "title": norm(&publication.title),
        "authors": publication.authors.iter().map(|a| norm(a)).collect::<Vec<_>>(),
        "language": norm_or_null(publication.language.as_deref()),
        "identifier": norm_or_null(publication.identifier.as_deref()),
        "layout": publication.layout_name(),
        "direction": publication.direction_name(),
        "coverHref": norm_or_null(publication.cover_href.as_deref()),
        "readingOrder": publication.reading_order.iter().map(|link| json!({
            "href": norm(&link.href),
            "mediaType": norm(&link.media_type),
        })).collect::<Vec<_>>(),
        "tableOfContents": publication.table_of_contents.iter().map(toc_node).collect::<Vec<_>>(),
    }))
}

fn report_command(args: &[String]) -> Result<Value, DocumentError> {
    let path = arg(args, 0, "usage: probe report <epub>");
    let archive = EpubArchive::open(path)?;
    let publication = epub_parser::parse(&archive)?;
    let report = report::make(&archive, &publication);

    Ok(json!({
        "schema": SCHEMA_VERSION,
        "command": "report",
        "report": {
            "format": report.format,
            "layout": report.layout,
            "direction": report.direction,
            "spineCount": report.spine_count,
            "tocEntryCount": report.toc_entry_count,
            "tocMaxDepth": report.toc_max_depth,
            "hasCover": report.has_cover,
            "missingResources": report.missing_resources.iter().map(|p| norm(p)).collect::<Vec<_>>(),
            "missingTOCTargets": report.missing_toc_targets.iter().map(|p| norm(p)).collect::<Vec<_>>(),
            "missingSpineItems": report.missing_spine_items.iter().map(|p| norm(p)).collect::<Vec<_>>(),
            "cssFileCount": report.css_file_count,
            "nonUTF8CSSCount": report.non_utf8_css_count,
            "legacyCSSFileCount": report.legacy_css_file_count,
            "cssChanges": report.css_changes.iter().map(change_node).collect::<Vec<_>>(),
            "xhtmlCount": report.xhtml_count,
            "malformedXHTMLCount": report.malformed_xhtml_count,
            "imageCount": report.image_count,
            "fontCount": report.font_count,
            "storedEntryCount": report.stored_entry_count,
            "deflatedEntryCount": report.deflated_entry_count,
            "hasEncryptionMetadata": report.has_encryption_metadata,
        },
    }))
}

/// 表示設定から作る CSS。設定は標準入力から JSON で受け取る。
fn style() -> Value {
    let style = parse_style(&read_standard_input());
    json!({
        "schema": SCHEMA_VERSION,
        "command": "style",
        "css": normalize_newlines(&style.css()),
        "needsForegroundMarking": style.needs_foreground_marking(),
    })
}

fn parse_style(input: &[u8]) -> ReaderStyle {
    let fallback = ReaderStyle::default();
    if input.is_empty() {
        return fallback;
    }
    let Ok(Value::Object(node)) = serde_json::from_slice::<Value>(input) else {
        return fallback;
    };

    ReaderStyle {
        font_size_percent: node
            .get("fontSizePercent")
            .and_then(Value::as_f64)
            .unwrap_or(fallback.font_size_percent),
        line_height: node
            .get("lineHeight")
            .and_then(Value::as_f64)
            .unwrap_or(fallback.line_height),
        max_width_em: node
            .get("maxWidthEm")
            .and_then(Value::as_f64)
            .unwrap_or(fallback.max_width_em),
        theme: Theme::parse(node.get("theme").and_then(Value::as_str)),
        body_font: node
            .get("bodyFont")
            .and_then(Value::as_str)
            .unwrap_or(&fallback.body_font)
            .to_string(),
        code_font: node
            .get("codeFont")
            .and_then(Value::as_str)
            .unwrap_or(&fallback.code_font)
            .to_string(),
        code_wrap: node
            .get("codeWrap")
            .and_then(Value::as_bool)
            .unwrap_or(fallback.code_wrap),
        publisher_style: node
            .get("publisherStyle")
            .and_then(Value::as_bool)
            .unwrap_or(fallback.publisher_style),
    }
}

/// 章から取り出した本文。検索も診断も抜粋もこの結果に乗っているため、ここを揃える。
fn text(args: &[String]) -> Result<Value, DocumentError> {
    let path = arg(args, 0, "usage: probe text <epub> <href>");
    let href = arg(args, 1, "usage: probe text <epub> <href>");
    let archive = EpubArchive::open(path)?;
    let data = archive
        .read(href)
        .ok_or_else(|| DocumentError::broken_archive(format!("{href} を読めない")))?;
    let extracted = html_text::extract(&css_compat::decode_text(&data));

    Ok(json!({
        "schema": SCHEMA_VERSION,
        "command": "text",
        "href": norm(href),
        "text": norm(&extracted.text),
        "codeRanges": extracted.code_ranges.iter()
            .map(|(start, end)| json!([start, end]))
            .collect::<Vec<_>>(),
    }))
}

/// リンク先の抜粋。整形の細部ではなく、どこを切り出したかを揃える。
fn preview_command(args: &[String]) -> Result<Value, DocumentError> {
    let path = arg(args, 0, "usage: probe preview <epub> <href> [fragment]");
    let href = arg(args, 1, "usage: probe preview <epub> <href> [fragment]");
    let fragment = args.get(2).map(String::as_str).filter(|f| !f.is_empty());
    let archive = EpubArchive::open(path)?;
    let built = preview::make(&archive, href, fragment, "");

    Ok(json!({
        "schema": SCHEMA_VERSION,
        "command": "preview",
        "path": built.as_ref().map(|p| Value::String(norm(&p.path))).unwrap_or(Value::Null),
        "isFootnote": built.as_ref().map(|p| p.is_footnote).unwrap_or(false),
        // 抜粋に混ざる自前の CSS は比較の対象にしない。
        "text": built.as_ref()
            .map(|p| Value::String(norm(html_text::extract(&p.html).text.trim())))
            .unwrap_or(Value::Null),
    }))
}

/// 固定レイアウトの組み立て。ページの種別と、見開きの組み方を揃える。
fn fixed(args: &[String]) -> Result<Value, DocumentError> {
    let path = arg(args, 0, "usage: probe fixed <epub> [ページ番号]");
    let archive = EpubArchive::open(path)?;
    let publication = epub_parser::parse(&archive)?;
    let page: usize = args.get(1).and_then(|a| a.parse().ok()).unwrap_or(0);
    let spreads = fixed_layout::spreads(publication.reading_order.len());

    let pages: Vec<Value> = publication
        .reading_order
        .iter()
        .enumerate()
        .map(|(index, link)| {
            let content = fixed_layout::content(&link.href, &archive);
            json!({
                "index": index,
                "kind": content.kind,
                "href": norm(&content.href),
                // 寸法は元の章から読む。画像 1 枚のページでも、名乗っているのは章のほうである。
                "viewport": fixed_layout::viewport(&link.href, &archive)
                    .map(|(width, height)| json!({ "width": width, "height": height }))
                    .unwrap_or(Value::Null),
            })
        })
        .collect();

    let spread_for_page = spreads
        .iter()
        .find(|s| s.contains(&page))
        .cloned()
        .unwrap_or_else(|| vec![page]);

    Ok(json!({
        "schema": SCHEMA_VERSION,
        "command": "fixed",
        "direction": publication.direction_name(),
        "pages": pages,
        "spreads": spreads,
        "spreadForPage": spread_for_page,
    }))
}

fn resolve(args: &[String]) -> Result<Value, DocumentError> {
    let base = arg(args, 0, "usage: probe resolve <base> <href>");
    let href = arg(args, 1, "usage: probe resolve <base> <href>");
    Ok(json!({
        "schema": SCHEMA_VERSION,
        "command": "resolve",
        "base": base,
        "href": href,
        "result": norm(&paths::resolve(base, href)),
    }))
}

fn css() -> Value {
    let input = read_standard_input();
    let result = css_compat::rewrite(&css_compat::decode_text(&input));
    let mut changes = result.changes;
    changes.sort_by(|a, b| a.from.cmp(&b.from).then(a.to.cmp(&b.to)));

    json!({
        "schema": SCHEMA_VERSION,
        "command": "css",
        "output": normalize_newlines(&result.css),
        "changes": changes.iter().map(change_node).collect::<Vec<_>>(),
    })
}

fn search_command(args: &[String]) -> Result<Value, DocumentError> {
    let path = arg(args, 0, "usage: probe search <epub> <query>");
    let query = arg(args, 1, "usage: probe search <epub> <query>");
    let archive = EpubArchive::open(path)?;
    let publication = epub_parser::parse(&archive)?;
    let outcome = search::search_epub(&archive, &publication, query);

    Ok(json!({
        "schema": SCHEMA_VERSION,
        "command": "search",
        "query": norm(query),
        "truncated": outcome.truncated,
        "results": outcome.results.iter().map(|r| json!({
            "href": norm(r.locator.href.as_deref().unwrap_or("")),
            // 丸め方の差で落ちないよう、小数第 3 位へ揃える。
            "progression": round_half_up(r.locator.progression, 3),
            "match": norm(&r.matched),
            "isCode": r.is_code,
            // 章の中で何番目の当たりか。飛んだ先で押した当たりを選び直すのに使うので、
            // 実装どうしで食い違うと、開き直した窓が別の語を強調することになる。
            "nth": r.nth,
        })).collect::<Vec<_>>(),
    }))
}

/// 検索結果から飛んだ先で、どの語をどこで囲むか。
///
/// 囲んだ HTML を丸ごと比べると、実装ごとの細部で偽の差分が出る。
/// 囲んだ語と、その直前にある本文で示す。置いた場所が同じかどうかはこれで分かる。
fn mark_command(args: &[String]) -> Result<Value, DocumentError> {
    let usage = "usage: probe mark <epub> <href> <query> [nth]";
    let path = arg(args, 0, usage);
    let href = arg(args, 1, usage);
    let query = arg(args, 2, usage);
    let nth: usize = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(0);

    let archive = EpubArchive::open(path)?;
    let data = archive
        .read(href)
        .ok_or_else(|| DocumentError::broken_archive(format!("{href} を読めない")))?;
    // 配るときと同じ順で通す。印は書き換えたあとの本文へ入る。
    let html = css_compat::rewrite_xhtml(&css_compat::decode_text(&data)).css;

    let mut out = Map::new();
    out.insert("schema".into(), json!(SCHEMA_VERSION));
    out.insert("command".into(), json!("mark"));
    out.insert("href".into(), json!(norm(href)));
    out.insert("query".into(), json!(norm(query)));
    out.insert("nth".into(), json!(nth));
    match mark::locate(&html, query, nth) {
        Some(placement) => {
            out.insert("found".into(), json!(true));
            out.insert("marked".into(), json!(norm(&placement.marked)));
            out.insert("before".into(), json!(norm(&placement.before)));
        }
        None => {
            out.insert("found".into(), json!(false));
        }
    }
    Ok(Value::Object(out))
}

fn detect(args: &[String]) -> Result<Value, DocumentError> {
    let path = arg(args, 0, "usage: probe detect <file>");

    let Some(format) = detect_format(path) else {
        return Ok(detect_result(None, Some("unsupportedFormat")));
    };

    match format {
        // 描画には触れず、開けるかどうかだけを見る。
        DocumentFormat::Pdf => Ok(if pdf::can_open(path) {
            detect_result(Some("pdf"), None)
        } else {
            detect_result(None, Some("cannotOpenPDF"))
        }),
        DocumentFormat::Markdown => Ok(detect_result(Some("markdown"), None)),
        DocumentFormat::ReflowableEpub => {
            match EpubArchive::open(path).and_then(|archive| {
                let publication = epub_parser::parse(&archive)?;
                Ok(publication.format_name())
            }) {
                Ok(name) => Ok(detect_result(Some(name), None)),
                Err(error) => Ok(detect_result(None, Some(error.kind))),
            }
        }
    }
}

// MARK: 出力

fn detect_result(format: Option<&str>, error_kind: Option<&str>) -> Value {
    json!({
        "schema": SCHEMA_VERSION,
        "command": "detect",
        "format": format.map(|f| Value::String(f.to_string())).unwrap_or(Value::Null),
        "error": error_kind
            .map(|k| json!({ "kind": k }))
            .unwrap_or(Value::Null),
    })
}

fn toc_node(entry: &TocEntry) -> Value {
    json!({
        "title": norm(&entry.title),
        "href": norm_or_null(entry.href.as_deref()),
        "fragment": norm_or_null(entry.fragment.as_deref()),
        "children": entry.children.iter().map(toc_node).collect::<Vec<_>>(),
    })
}

fn change_node(change: &css_compat::Change) -> Value {
    json!({ "from": change.from, "to": change.to, "count": change.count })
}

/// macOS は分解形（NFD）を返すことがあり Windows は合成形。比較のため NFC へ揃える。
fn norm(value: &str) -> String {
    paths::normalize(value)
}

fn norm_or_null(value: Option<&str>) -> Value {
    value
        .map(|v| Value::String(norm(v)))
        .unwrap_or(Value::Null)
}

fn normalize_newlines(value: &str) -> String {
    value.replace("\r\n", "\n").replace('\r', "\n")
}

/// 小数第 3 位へ丸める。ちょうど半分のときは 0 から遠い側へ寄せる（四捨五入）。
///
/// 以前は C# の MidpointRounding.ToEven に合わせていたが、C# 版は畳んだ。
/// 境目に当たる値が出るまで、Swift 版との違いは隠れていた。
fn round_half_up(value: f64, digits: u32) -> f64 {
    let factor = 10f64.powi(digits as i32);
    (value * factor).round() / factor
}

fn read_standard_input() -> Vec<u8> {
    let mut buffer = Vec::new();
    let _ = std::io::stdin().read_to_end(&mut buffer);
    buffer
}

fn emit(mut value: Value) {
    strip_nulls(&mut value);
    println!("{}", serde_json::to_string_pretty(&value).expect("JSON"));
}

/// 値が無いキーは出力しない。macOS 版の JSONEncoder が nil のプロパティを省くため、
/// 「キーが無い」と「キーがあって null」を揃えないと比較で差になる。
fn strip_nulls(value: &mut Value) {
    match value {
        Value::Object(map) => {
            let empty: Vec<String> = map
                .iter()
                .filter(|(_, v)| v.is_null())
                .map(|(k, _)| k.clone())
                .collect();
            for key in empty {
                map.remove(&key);
            }
            for (_, child) in map.iter_mut() {
                strip_nulls(child);
            }
        }
        Value::Array(items) => {
            for item in items {
                strip_nulls(item);
            }
        }
        _ => {}
    }
}

fn arg<'a>(args: &'a [String], index: usize, usage: &str) -> &'a str {
    match args.get(index) {
        Some(value) => value,
        None => fail(usage),
    }
}

fn fail(message: &str) -> ! {
    eprintln!("{message}");
    std::process::exit(2);
}

// serde_json::Map は既定で並べ替えた木を使うため、キー順は自然に揃う。
#[allow(dead_code)]
fn sorted_keys_are_default(_: &Map<String, Value>) {}
