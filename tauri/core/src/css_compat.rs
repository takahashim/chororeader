//! 古い EPUB の CSS を、配信時に解釈可能な形へ書き換える。
//! 元ファイルには触れず、意味を変える書き換えもしない。
//! 出力は他の実装と一致させる必要がある（conformance/CONTRACT.md）。

use std::sync::OnceLock;

use regex::{Regex, RegexBuilder};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Change {
    pub from: String,
    pub to: String,
    pub count: usize,
}

#[derive(Debug, Clone)]
pub struct Rewritten {
    pub css: String,
    pub changes: Vec<Change>,
}

/// プロパティ名だけを標準形へ移せるもの。
const PROPERTY_MAP: &[(&str, &str)] = &[
    ("-epub-writing-mode", "writing-mode"),
    ("-epub-text-orientation", "text-orientation"),
    ("-epub-ruby-position", "ruby-position"),
    ("-epub-text-emphasis", "text-emphasis"),
    ("-epub-text-emphasis-color", "text-emphasis-color"),
    ("-epub-text-emphasis-style", "text-emphasis-style"),
    ("-epub-text-emphasis-position", "text-emphasis-position"),
    ("-epub-hyphens", "hyphens"),
    ("-epub-line-break", "line-break"),
    ("-epub-word-break", "word-break"),
    ("-epub-text-align-last", "text-align-last"),
    ("-epub-caption-side", "caption-side"),
];

fn regex(pattern: &str) -> Regex {
    RegexBuilder::new(pattern)
        .case_insensitive(true)
        .dot_matches_new_line(true)
        .build()
        .expect("組み込みの正規表現")
}

pub fn rewrite(css: &str) -> Rewritten {
    let mut changes: Vec<Change> = Vec::new();
    let mut output = String::with_capacity(css.len());

    for segment in segments(css) {
        match segment {
            Segment::Verbatim(text) => output.push_str(text),
            Segment::Code(text) => {
                // 値の読み替えが要るものを先に処理する。
                let mut text = replace(
                    text,
                    r"-epub-text-combine-horizontal\s*:\s*[^;}]*",
                    "text-combine-upright: all",
                    "-epub-text-combine-horizontal",
                    &mut changes,
                );
                text = replace(
                    &text,
                    r"-epub-text-combine\s*:\s*horizontal",
                    "text-combine-upright: all",
                    "-epub-text-combine: horizontal",
                    &mut changes,
                );
                for (from, to) in PROPERTY_MAP {
                    // C# 版は先読み `(?=\s*:)` を使う。Rust の正規表現に先読みは無いので、
                    // 区切りまで取り込んで書き戻す。効果は同じで、
                    // -epub-text-emphasis が -epub-text-emphasis-color に食い込まない。
                    let pattern = format!(r"{}(\s*:)", regex::escape(from));
                    text = replace(&text, &pattern, &format!("{to}$1"), from, &mut changes);
                }
                output.push_str(&text);
            }
        }
    }

    Rewritten {
        css: output,
        changes,
    }
}

/// XHTML 内の style ブロックにも同じ変換をかける。要素構造には触れない。
pub fn rewrite_xhtml(html: &str) -> Rewritten {
    if !html.contains("-epub-") {
        return Rewritten {
            css: html.to_string(),
            changes: Vec::new(),
        };
    }

    static STYLE_BLOCK: OnceLock<Regex> = OnceLock::new();
    let pattern = STYLE_BLOCK.get_or_init(|| regex(r"(?s)(<style\b[^>]*>)(.*?)(</style>)"));

    let mut changes: Vec<Change> = Vec::new();
    let mut output = String::with_capacity(html.len());
    let mut cursor = 0;

    for capture in pattern.captures_iter(html) {
        let whole = capture.get(0).expect("全体");
        output.push_str(&html[cursor..whole.start()]);

        let inner = rewrite(&capture[2]);
        if inner.changes.is_empty() {
            output.push_str(whole.as_str());
        } else {
            changes.extend(inner.changes);
            output.push_str(&capture[1]);
            output.push_str(&inner.css);
            output.push_str(&capture[3]);
        }
        cursor = whole.end();
    }
    output.push_str(&html[cursor..]);

    Rewritten {
        css: output,
        changes,
    }
}

fn replace(
    text: &str,
    pattern: &str,
    replacement: &str,
    label: &str,
    changes: &mut Vec<Change>,
) -> String {
    if !text.contains("-epub-") {
        return text.to_string();
    }
    let pattern = regex(pattern);
    let count = pattern.find_iter(text).count();
    if count == 0 {
        return text.to_string();
    }
    changes.push(Change {
        from: label.to_string(),
        // 記録する行き先は、置換に使う後方参照を含まない見出しにする。
        to: replacement.replace("$1", ""),
        count,
    });
    pattern.replace_all(text, replacement).into_owned()
}

enum Segment<'a> {
    /// 書き換えの対象。
    Code(&'a str),
    /// コメントと文字列リテラル。中身には触れない。
    Verbatim(&'a str),
}

/// コメントと文字列リテラルを切り分ける。その内側を書き換えないための下ごしらえ。
fn segments(css: &str) -> Vec<Segment<'_>> {
    let bytes = css.as_bytes();
    let mut segments = Vec::new();
    let mut code_start = 0;
    let mut i = 0;

    while i < bytes.len() {
        let c = bytes[i];

        if c == b'/' && i + 1 < bytes.len() && bytes[i + 1] == b'*' {
            if i > code_start {
                segments.push(Segment::Code(&css[code_start..i]));
            }
            let mut j = i + 2;
            while j < bytes.len() {
                if bytes[j] == b'*' && j + 1 < bytes.len() && bytes[j + 1] == b'/' {
                    j += 2;
                    break;
                }
                j += 1;
            }
            let end = j.min(bytes.len());
            segments.push(Segment::Verbatim(&css[i..end]));
            i = end;
            code_start = i;
            continue;
        }

        if c == b'"' || c == b'\'' {
            if i > code_start {
                segments.push(Segment::Code(&css[code_start..i]));
            }
            let mut j = i + 1;
            while j < bytes.len() {
                if bytes[j] == b'\\' {
                    j = (j + 2).min(bytes.len());
                    continue;
                }
                if bytes[j] == c {
                    j += 1;
                    break;
                }
                j += 1;
            }
            let end = j.min(bytes.len());
            segments.push(Segment::Verbatim(&css[i..end]));
            i = end;
            code_start = i;
            continue;
        }

        // 多バイト文字の途中で切らないよう、文字単位で進める。
        i += utf8_width(c);
    }

    if bytes.len() > code_start {
        segments.push(Segment::Code(&css[code_start..]));
    }
    segments
}

fn utf8_width(first: u8) -> usize {
    match first {
        0x00..=0x7F => 1,
        0xC0..=0xDF => 2,
        0xE0..=0xEF => 3,
        _ => 4,
    }
}

/// UTF-8 以外で書かれたリソースも読めるようにする。
pub fn decode_text(data: &[u8]) -> String {
    // BOM 付きはそのまま任せる。
    if data.starts_with(&[0xEF, 0xBB, 0xBF]) {
        return String::from_utf8_lossy(&data[3..]).into_owned();
    }

    if let Ok(text) = std::str::from_utf8(data) {
        return text.to_string();
    }

    for encoding in [encoding_rs::SHIFT_JIS, encoding_rs::EUC_JP] {
        if let Some(text) = encoding.decode_without_bom_handling_and_without_replacement(data) {
            return text.into_owned();
        }
    }

    // ISO-8859-1 はどのバイト列でも解ける。C# 版の最後の候補と同じ振る舞いにする。
    data.iter().map(|&b| b as char).collect()
}

/// 厳密な UTF-8 かどうか。診断で「UTF-8 でない CSS」を数えるのに使う。
pub fn is_valid_utf8(data: &[u8]) -> bool {
    std::str::from_utf8(data).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn コメントと文字列の中は書き換えない() {
        let input = "/* -epub-writing-mode はコメント */\n.a { content: \"-epub-writing-mode: horizontal-tb\"; }\n.b { -epub-writing-mode: vertical-rl; }\n";
        let result = rewrite(input);
        assert!(result.css.contains("/* -epub-writing-mode はコメント */"));
        assert!(result.css.contains("\"-epub-writing-mode: horizontal-tb\""));
        assert!(result.css.contains(".b { writing-mode: vertical-rl; }"));
        assert_eq!(result.changes.len(), 1);
        assert_eq!(result.changes[0].count, 1);
    }

    #[test]
    fn 接頭辞の長い方に食い込まない() {
        let result = rewrite(".e { -epub-text-emphasis-color: red; }");
        assert!(result.css.contains("text-emphasis-color: red"));
        assert_eq!(result.changes.len(), 1);
        assert_eq!(result.changes[0].from, "-epub-text-emphasis-color");
    }

    #[test]
    fn ベンダー接頭辞の別系統は触らない() {
        let input = ".w { -webkit-writing-mode: vertical-rl; }\n";
        let result = rewrite(input);
        assert_eq!(result.css, input);
        assert!(result.changes.is_empty());
    }
}
