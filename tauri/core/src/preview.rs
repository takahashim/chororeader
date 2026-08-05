//! リンク先を移動せずに確かめるための、小さな抜粋を組み立てる。
//! どこを切り出すかは実装間で揃える（conformance/CONTRACT.md）。

use std::sync::OnceLock;

use regex::{Regex, RegexBuilder};

use crate::archive::ResourceProvider;
use crate::css_compat;
use crate::html_text;
use crate::paths;
use crate::xml::{self, Document};

/// 抜粋に入れる本文の目安。脚注はこれよりずっと短く収まる。
const BUDGET: usize = 1200;

pub const SYNTHETIC_NAME: &str = "__tzr_preview__.xhtml";

#[derive(Debug, Clone)]
pub struct Preview {
    pub path: String,
    pub html: String,
    pub is_footnote: bool,
}

pub fn make(
    resources: &dyn ResourceProvider,
    href: &str,
    fragment: Option<&str>,
    css: &str,
) -> Option<Preview> {
    let data = resources.read(href)?;
    let source = css_compat::rewrite_xhtml(&css_compat::decode_text(&data)).css;
    let (body, is_footnote) = extract(&source, fragment);
    if body.is_empty() {
        return None;
    }

    let directory = paths::directory_of(href);
    let path = if directory.is_empty() {
        SYNTHETIC_NAME.to_string()
    } else {
        format!("{directory}/{SYNTHETIC_NAME}")
    };

    // 抜粋には epub:type のような接頭辞付き属性が混ざる。XHTML として解釈させると
    // 名前空間が宣言されていない断片で丸ごとパースに失敗するため、HTML として配信する。
    let html = format!(
        r#"<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><meta charset="utf-8"/><style>
{css}
html, body {{ margin: 0 !important; padding: 12px 14px !important; max-width: none !important; }}
body {{ font-size: 0.94em !important; }}
h1, h2, h3, h4, h5, h6 {{ margin-top: 0 !important; }}
a {{ pointer-events: none; }}
img, svg {{ max-width: 100% !important; height: auto !important; }}
</style></head>
<body>{body}</body>
</html>"#
    );

    Some(Preview {
        path,
        html,
        is_footnote,
    })
}

fn extract(source: &str, fragment: Option<&str>) -> (String, bool) {
    let Some(document) = xml::parse(source) else {
        return (escaped_plain_text(source), false);
    };

    let Some(fragment) = fragment.filter(|f| !f.is_empty()) else {
        return (leading_content(&document, source), false);
    };

    let Some(target) = document
        .all()
        .find(|(_, e)| e.attr("id") == Some(fragment))
        .map(|(index, _)| index)
    else {
        return (leading_content(&document, source), false);
    };

    // 脚注は要素 1 つで完結する。前後を足すとかえって読みにくい。
    if is_footnote_element(&document, target) {
        return (slice(source, &document, target), true);
    }

    let mut html = slice(source, &document, target);
    let mut length = document.value(target).chars().count();
    for sibling in document.following_siblings(target) {
        if length >= BUDGET {
            break;
        }
        html.push_str(&slice(source, &document, sibling));
        length += document.value(sibling).chars().count();
    }
    (html, false)
}

fn is_footnote_element(document: &Document, index: usize) -> bool {
    let element = document.get(index);
    let kind = format!(
        "{} {}",
        element.attr("type").unwrap_or(""),
        element.attr("role").unwrap_or("")
    );
    if kind.contains("footnote") || kind.contains("note") || kind.contains("doc-footnote") {
        return true;
    }
    element.name == "aside"
}

fn leading_content(document: &Document, source: &str) -> String {
    let Some(body) = document.first_descendant_named("body") else {
        return String::new();
    };
    let mut html = String::new();
    let mut length = 0usize;
    for child in document.child_elements(body).collect::<Vec<_>>() {
        html.push_str(&slice(source, document, child));
        length += document.value(child).chars().count();
        if length >= BUDGET {
            break;
        }
    }
    html
}

/// 木から書き戻すのではなく、元の断片をそのまま使う。
/// 空白や実体参照の書き方を変えずに済むため。
fn slice(source: &str, document: &Document, index: usize) -> String {
    let (start, end) = document.get(index).span;
    source[start..end].to_string()
}

/// XML として読めない章のための最後の手段。整形は諦め、文字だけ見せる。
fn escaped_plain_text(source: &str) -> String {
    let text = html_text::strip_tags(source);
    let text: String = text.chars().take(BUDGET).collect();
    let escaped = text
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;");
    format!("<p>{escaped}</p>")
}

/// 固定レイアウトの組み立てのうち、画面に依らない部分。
/// ページの種別の見分けと、見開きの組み方を扱う。
pub mod fixed_layout {
    use super::*;

    #[derive(Debug, Clone)]
    pub struct PageContent {
        pub kind: &'static str,
        pub href: String,
    }

    /// ページが画像 1 枚で構成されているなら、その画像を直接表示する。
    /// 文字が固定座標で置かれているページは、元の XHTML をそのまま埋め込む。
    pub fn content(href: &str, resources: &dyn ResourceProvider) -> PageContent {
        let document = PageContent {
            kind: "document",
            href: href.to_string(),
        };

        let Some(data) = resources.read(href) else {
            return document;
        };
        let source = css_compat::decode_text(&data);
        let Some(reference) = primary_image_reference(&source) else {
            return document;
        };

        let resolved = paths::resolve(paths::directory_of(href), &reference);
        if !resources.contains(&resolved) {
            return document;
        }

        // 画像以外に本文が載っているページは、画像だけを出すと内容が落ちる。
        let text = html_text::strip_tags(&source);
        if text.trim().chars().count() < 40 {
            PageContent {
                kind: "image",
                href: resolved,
            }
        } else {
            document
        }
    }

    fn image_patterns() -> &'static [Regex] {
        static PATTERNS: OnceLock<Vec<Regex>> = OnceLock::new();
        PATTERNS.get_or_init(|| {
            [
                r#"<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#,
                r#"<image\b[^>]*\bxlink:href\s*=\s*["']([^"']+)["']"#,
                r#"<image\b[^>]*\bhref\s*=\s*["']([^"']+)["']"#,
            ]
            .iter()
            .map(|p| {
                RegexBuilder::new(p)
                    .case_insensitive(true)
                    .build()
                    .expect("組み込みの正規表現")
            })
            .collect()
        })
    }

    fn primary_image_reference(html: &str) -> Option<String> {
        let mut found = Vec::new();
        for pattern in image_patterns() {
            for capture in pattern.captures_iter(html) {
                found.push(capture[1].to_string());
            }
        }
        // 画像が複数あるページは、単純な 1 枚もののページではない。
        if found.len() == 1 {
            found.pop()
        } else {
            None
        }
    }

    /// 見開きの組み方。表紙は単独で見せ、以降を 2 枚ずつまとめる。
    pub fn spreads(page_count: usize) -> Vec<Vec<usize>> {
        if page_count == 0 {
            return Vec::new();
        }
        let mut result = vec![vec![0]];
        let mut index = 1;
        while index < page_count {
            if index + 1 < page_count {
                result.push(vec![index, index + 1]);
                index += 2;
            } else {
                result.push(vec![index]);
                index += 1;
            }
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 脚注は要素ひとつで切る() {
        let source = r#"<html xmlns:epub="urn:x"><body><p>本文</p><aside id="fn1" epub:type="footnote"><p>脚注</p></aside></body></html>"#;
        let (body, is_footnote) = extract(source, Some("fn1"));
        assert!(is_footnote);
        assert_eq!(
            body,
            r#"<aside id="fn1" epub:type="footnote"><p>脚注</p></aside>"#
        );
    }

    #[test]
    fn 見つからないidは先頭から見せる() {
        let source = "<html><body><p>あたま</p></body></html>";
        let (body, is_footnote) = extract(source, Some("no-such-id"));
        assert!(!is_footnote);
        assert_eq!(body, "<p>あたま</p>");
    }

    #[test]
    fn 見開きは表紙を単独にする() {
        assert_eq!(
            fixed_layout::spreads(5),
            vec![vec![0], vec![1, 2], vec![3, 4]]
        );
        assert_eq!(fixed_layout::spreads(4), vec![vec![0], vec![1, 2], vec![3]]);
    }
}
