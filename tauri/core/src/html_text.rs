//! 章の HTML から本文とコードを取り出す。索引は作らず、要求されたときに走査する。
//! 抽出結果は検索の位置計算に使うため、他の実装と同じ文字列になる必要がある。

use std::sync::OnceLock;

use regex::{Regex, RegexBuilder};

#[derive(Debug, Clone)]
pub struct Extracted {
    pub text: String,
    /// 本文中でコードが占める範囲。単位は Unicode スカラー。
    pub code_ranges: Vec<(usize, usize)>,
    /// 本文の 1 文字ごとに、元の HTML でその文字が始まるバイト位置。
    ///
    /// 抽出は削って詰めるだけなので、削りながら控えておけば元へ戻せる。
    /// 別に辿り直すと規則が二重になり、片方だけ直したときに黙ってずれる。
    pub origins: Vec<usize>,
}

impl Extracted {
    pub fn is_code(&self, offset: usize) -> bool {
        self.code_ranges
            .iter()
            .any(|(start, end)| offset >= *start && offset < *end)
    }
}

/// 名前付き実体。C# 版の初期化順と同じ並びで適用する。
/// `&amp;` を先に解くかどうかで結果が変わりうるため、順序も揃える。
const ENTITIES: &[(&str, &str)] = &[
    ("&amp;", "&"),
    ("&lt;", "<"),
    ("&gt;", ">"),
    ("&quot;", "\""),
    ("&apos;", "'"),
    ("&nbsp;", " "),
    ("&mdash;", "—"),
    ("&ndash;", "–"),
    ("&hellip;", "…"),
];

/// 本文に混ぜないところ。extract はこれらを消してから走査する。
///
/// head は画面に出ない。題名（title）は本文として数えると、
/// 検索が「見えないところに当たった」と言い、飛んでも何も無いことになる。
fn head() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| regex(r"<head\b[^>]*>.*?</head>"))
}

fn script() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| regex(r"<script\b[^>]*>.*?</script>"))
}

fn style() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| regex(r"<style\b[^>]*>.*?</style>"))
}

fn comment() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| regex(r"<!--.*?-->"))
}

/// 本文に混ぜないところの範囲（バイト位置）。重なりは畳んでいない。
fn ignored_ranges(html: &str) -> Vec<(usize, usize)> {
    let mut ranges: Vec<(usize, usize)> = Vec::new();
    for re in [head(), script(), style(), comment()] {
        ranges.extend(re.find_iter(html).map(|m| (m.start(), m.end())));
    }
    ranges.sort_unstable();
    ranges
}

/// 本文に混ぜないところを抜いた並び。位置は元の HTML へ戻せる。
struct Body {
    text: String,
    /// (この並びでの始まり, 元の HTML での始まり)。残した断片ごとに 1 つ。
    pieces: Vec<(usize, usize)>,
}

impl Body {
    fn of(html: &str) -> Body {
        let mut text = String::with_capacity(html.len());
        let mut pieces = Vec::new();
        let mut at = 0usize;

        for (from, to) in ignored_ranges(html) {
            if from > at {
                pieces.push((text.len(), at));
                text.push_str(&html[at..from]);
            }
            // 入れ子や重なりがあるので、後ろへ戻さない。
            at = at.max(to);
        }
        if at < html.len() {
            pieces.push((text.len(), at));
            text.push_str(&html[at..]);
        }
        Body { text, pieces }
    }

    /// この並びでの位置を、元の HTML での位置に戻す。
    fn origin(&self, at: usize) -> usize {
        let next = self.pieces.partition_point(|(start, _)| *start <= at);
        match next.checked_sub(1) {
            Some(index) => {
                let (start, from) = self.pieces[index];
                from + (at - start)
            }
            None => 0,
        }
    }
}

fn regex(pattern: &str) -> Regex {
    RegexBuilder::new(pattern)
        .case_insensitive(true)
        .dot_matches_new_line(true)
        .build()
        .expect("組み込みの正規表現")
}

pub fn extract(html: &str) -> Extracted {
    static PRE: OnceLock<Regex> = OnceLock::new();
    let pre = PRE.get_or_init(|| regex(r"<pre\b[^>]*>(.*?)</pre>"));

    let body = Body::of(html);
    let source = body.text.as_str();

    let mut text = String::new();
    let mut origins = Vec::new(); // まだ body の中の位置。最後に元へ戻す。
    let mut length = 0usize; // 文字数。バイト数ではない。
    let mut code_ranges = Vec::new();
    let mut cursor = 0;

    for capture in pre.captures_iter(source) {
        let whole = capture.get(0).expect("全体");
        let (before, before_at) = strip_tags_from(&source[cursor..whole.start()], cursor);
        length += before.chars().count();
        text.push_str(&before);
        origins.extend(before_at);

        let start = length;
        let code = capture.get(1).expect("中身");
        let (inner, inner_at) = strip_tags_from(code.as_str(), code.start());
        length += inner.chars().count();
        text.push_str(&inner);
        origins.extend(inner_at);
        code_ranges.push((start, length));

        text.push('\n');
        origins.push(whole.end());
        length += 1;
        cursor = whole.end();
    }
    let (tail, tail_at) = strip_tags_from(&source[cursor..], cursor);
    text.push_str(&tail);
    origins.extend(tail_at);

    let origins = origins.into_iter().map(|at| body.origin(at)).collect();
    Extracted { text, code_ranges, origins }
}

/// タグを落として本文だけにする。タグの位置には空白を 1 つ残す。
pub fn strip_tags(source: &str) -> String {
    strip_tags_from(source, 0).0
}

/// タグを落とし、残した 1 文字ごとに元の位置も返す。`base` は `source` が始まるところ。
///
/// 位置を控えるのは落とすのと同じ走査の中でだけ行う。別に辿り直せば、
/// タグの扱い・実体参照・空白の詰め方を二か所に書くことになる。
fn strip_tags_from(source: &str, base: usize) -> (String, Vec<usize>) {
    let mut output = String::with_capacity(source.len());
    let mut origins = Vec::with_capacity(source.len());
    let mut inside_tag = false;
    let mut last_was_space = false;

    for (offset, c) in source.char_indices() {
        let at = base + offset;
        if c == '<' {
            inside_tag = true;
            continue;
        }
        if c == '>' {
            inside_tag = false;
            if !last_was_space {
                // タグの代わりに置く空白は、タグの終わりの次を指す。
                output.push(' ');
                origins.push(at + c.len_utf8());
                last_was_space = true;
            }
            continue;
        }
        if inside_tag {
            continue;
        }
        if c == '\n' || c == '\r' || c == '\t' {
            if !last_was_space {
                output.push(' ');
                origins.push(at);
                last_was_space = true;
            }
            continue;
        }
        output.push(c);
        origins.push(at);
        last_was_space = c == ' ';
    }

    decode_entities(&output, &origins)
}

/// 実体参照を解く。解けた字は、書かれていた並びの始まりを指す。
///
/// 名前付きは C# 版の初期化順（ENTITIES）で、全体を 1 つずつ均す。
/// `&amp;lt;` が `<` になるのはこの順序による。1 文字ずつ解くと結果が変わる。
fn decode_entities(source: &str, origins: &[usize]) -> (String, Vec<usize>) {
    if !source.contains('&') {
        return (source.to_string(), origins.to_vec());
    }

    let mut text = source.to_string();
    let mut at = origins.to_vec();
    for (from, to) in ENTITIES {
        if text.contains(from) {
            (text, at) = replaced(&text, &at, *from, |_| to.to_string());
        }
    }
    if !text.contains("&#") {
        return (text, at);
    }

    static NUMERIC: OnceLock<Regex> = OnceLock::new();
    let numeric = NUMERIC.get_or_init(|| Regex::new(r"&#(x?)([0-9A-Fa-f]+);").expect("数値実体"));
    replaced(&text, &at, numeric, |found| {
        let capture = numeric.captures(found).expect("見つけた並び");
        let radix = if capture[1].is_empty() { 10 } else { 16 };
        match u32::from_str_radix(&capture[2], radix)
            .ok()
            .and_then(char::from_u32)
        {
            Some(c) => c.to_string(),
            // 読めない並びは、書いてあるまま残す。
            None => found.to_string(),
        }
    })
}

/// 見つかった並びを置き換える。置いた字は、いずれも元の並びの始まりを指す。
fn replaced(
    text: &str,
    origins: &[usize],
    pattern: impl Pattern,
    into: impl Fn(&str) -> String,
) -> (String, Vec<usize>) {
    let mut output = String::with_capacity(text.len());
    let mut at = Vec::with_capacity(origins.len());
    let mut byte = 0usize;
    let mut index = 0usize; // 文字数。origins はこちらで引く。

    while let Some((from, to)) = pattern.find(text, byte) {
        let head = &text[byte..from];
        output.push_str(head);
        at.extend_from_slice(&origins[index..index + head.chars().count()]);
        index += head.chars().count();

        let found = &text[from..to];
        let origin = origins.get(index).copied().unwrap_or(0);
        let put = into(found);
        output.push_str(&put);
        at.extend(put.chars().map(|_| origin));
        index += found.chars().count();
        byte = to;
    }
    output.push_str(&text[byte..]);
    at.extend_from_slice(&origins[index..]);
    (output, at)
}

/// `replaced` が探すもの。文字列でも正規表現でも同じように辿れるようにする。
trait Pattern {
    /// `from` 以降の最初の一致（バイト位置）。
    fn find(&self, text: &str, from: usize) -> Option<(usize, usize)>;
}

impl Pattern for &str {
    fn find(&self, text: &str, from: usize) -> Option<(usize, usize)> {
        let offset = text[from..].find(*self)?;
        Some((from + offset, from + offset + self.len()))
    }
}

impl Pattern for &Regex {
    fn find(&self, text: &str, from: usize) -> Option<(usize, usize)> {
        let found = Regex::find_at(self, text, from)?;
        Some((found.start(), found.end()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn コードの範囲は文字数で数える() {
        let extracted = extract("<h1>第 1 章</h1><pre>puts</pre><p>後</p>");
        let chars: Vec<char> = extracted.text.chars().collect();
        let (start, end) = extracted.code_ranges[0];
        assert_eq!(chars[start..end].iter().collect::<String>(), "puts");
    }

    #[test]
    fn 本文の実体参照を解く() {
        assert_eq!(strip_tags("a&amp;b&#12354;"), "a&bあ");
    }

    /// 控えた位置が、本当にその文字の始まりを指しているか。
    fn 指し先が合う(html: &str) {
        let extracted = extract(html);
        assert_eq!(extracted.origins.len(), extracted.text.chars().count(), "{html}");
        for (index, c) in extracted.text.chars().enumerate() {
            let at = extracted.origins[index];
            assert!(at <= html.len(), "{html} の {index} 文字目が範囲の外");
            // 抽出が足した字（タグの代わりの空白、コードの後ろの改行）と、
            // 実体参照を解いた字は、元に同じ字があるとは限らない。
            if !c.is_whitespace() && c.is_ascii() {
                assert!(html[at..].starts_with(c), "{html} の {index} 文字目（{c}）が {at} を指す");
            }
        }
    }

    #[test]
    fn 控えた位置は元の文字を指す() {
        指し先が合う("<p>hello world</p>");
        指し先が合う("<head><title>題</title></head><body><p>hi</p></body>");
        指し先が合う("<p>a&amp;b</p><pre>code</pre><p>tail</p>");
        指し先が合う("<!-- 消える --><p>x</p><script>y</script><p>z</p>");
        指し先が合う("");
    }

    #[test]
    fn 実体参照を解いた字は書かれた並びの頭を指す() {
        let html = "<p>a&amp;b</p>";
        let extracted = extract(html);
        let index = extracted.text.chars().position(|c| c == '&').expect("解けた字");
        assert!(html[extracted.origins[index]..].starts_with("&amp;"));
    }

    #[test]
    fn scriptとstyleは本文に混ぜない() {
        let extracted = extract("<style>body{}</style><p>本文</p><script>x()</script>");
        assert!(!extracted.text.contains("body"));
        assert!(!extracted.text.contains("x()"));
        assert!(extracted.text.contains("本文"));
    }
}
