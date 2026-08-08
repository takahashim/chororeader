//! 固定レイアウトの組み立てのうち、画面に依らない部分。
//! ページの種別の見分けと、見開きの組み方を扱う。
//!
//! 見開きの組み方は実装間で揃える（conformance/CONTRACT.md）。

use std::sync::OnceLock;

use regex::{Regex, RegexBuilder};

use crate::archive::ResourceProvider;
use crate::html_text;
use crate::paths;

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

    let Some(source) = resources.read_text(href) else {
        return document;
    };
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

/// ページの寸法。固定レイアウトの各ページは meta viewport で大きさを名乗る。
///
/// 拡大の枠を先に決めるために要る。大きさを与えないと画像がすべて同じ位置に積まれ、
/// 遅延読み込みが効かなくなる。
pub fn viewport(href: &str, resources: &dyn ResourceProvider) -> Option<(f64, f64)> {
    static VIEWPORT: OnceLock<Regex> = OnceLock::new();
    let pattern = VIEWPORT.get_or_init(|| {
        RegexBuilder::new(r#"(?i)<meta\b[^>]*\bname\s*=\s*["']viewport["'][^>]*\bcontent\s*=\s*["']([^"']+)["']"#)
            .case_insensitive(true)
            .build()
            .expect("組み込みの正規表現")
    });

    let source = resources.read_text(href)?;
    let content = pattern.captures(&source)?[1].to_string();

    let mut width = None;
    let mut height = None;
    for part in content.split(',') {
        let (key, value) = part.split_once('=')?;
        match key.trim() {
            "width" => width = value.trim().parse::<f64>().ok(),
            "height" => height = value.trim().parse::<f64>().ok(),
            _ => {}
        }
    }
    match (width, height) {
        (Some(w), Some(h)) if w > 0.0 && h > 0.0 => Some((w, h)),
        _ => None,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn viewportから寸法を読む() {
        struct One(String);
        impl ResourceProvider for One {
            fn contains(&self, _: &str) -> bool { true }
            fn read(&self, _: &str) -> Option<Vec<u8>> { Some(self.0.clone().into_bytes()) }
        }
        let page = One(r#"<html><head><meta name="viewport" content="width=1200, height=1697"/></head><body/></html>"#.to_string());
        assert_eq!(viewport("p.xhtml", &page), Some((1200.0, 1697.0)));

        let none = One("<html><head/><body/></html>".to_string());
        assert_eq!(viewport("p.xhtml", &none), None);
    }

    /// 書き損じた並びは、半端に読めたぶんも使わない。
    ///
    /// `width` だけ拾うと、書き損じた書籍で妙な寸法を掴んだまま画面を組むことになる。
    /// 名乗っていないのと同じ扱いにして、寸法を与えない側へ倒す。
    #[test]
    fn 書き損じた並びは全体を捨てる() {
        struct One(String);
        impl ResourceProvider for One {
            fn contains(&self, _: &str) -> bool { true }
            fn read(&self, _: &str) -> Option<Vec<u8>> { Some(self.0.clone().into_bytes()) }
        }
        let page = |content: &str| {
            One(format!(
                r#"<html><head><meta name="viewport" content="{content}"/></head><body/></html>"#
            ))
        };

        // height に `=` が無い。
        assert_eq!(viewport("p.xhtml", &page("width=1200, height")), None);
        // 片方しか名乗っていない。
        assert_eq!(viewport("p.xhtml", &page("width=1200")), None);
        // 数として読めない。
        assert_eq!(viewport("p.xhtml", &page("width=そこそこ, height=1700")), None);
        // 0 や負の寸法は枠にならない。
        assert_eq!(viewport("p.xhtml", &page("width=0, height=1700")), None);
        assert_eq!(viewport("p.xhtml", &page("width=1200, height=-1")), None);
        // 知らない鍵が混ざっていても、幅と高さが揃っていれば読む。
        assert_eq!(
            viewport("p.xhtml", &page("width=1200, height=1700, initial-scale=1")),
            Some((1200.0, 1700.0))
        );
    }

    #[test]
    fn 見開きは表紙を単独にする() {
        assert_eq!(spreads(5), vec![vec![0], vec![1, 2], vec![3, 4]]);
        assert_eq!(spreads(4), vec![vec![0], vec![1, 2], vec![3]]);
    }
}
