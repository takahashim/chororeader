//! 検索結果から飛んだ先で、当たった語を囲む。
//!
//! 印は配信時に本文へ入れる。画面側で入れると、文字節を切って包む手術を JS で書くことになり、
//! 抽出（html_text）と数え方がずれる余地が残る。ここで入れれば、
//! 当たりを選ぶのは検索と同じコード（search::nth_match）になる。
//!
//! **抽出そのものには触らない。** あちらは実装間で突き合わせている中心なので、
//! 本文と元の HTML を後から突き合わせて位置を求める。突き合わせがずれても、
//! 動くのは印の位置だけで、検索の当たりは動かない。

use crate::html_text;
use crate::search;

/// 印に付ける名前。画面側の CSS はこれを見て色を当てる。
pub const CLASS: &str = "choro-found";

/// 印を入れた場所。実装間で突き合わせるために、囲んだ語とその直前の文脈で表す。
///
/// 位置を数で言うと、実装ごとの数え方（バイトか、符号位置か、書記素か）の違いが
/// そのまま差になる。文字列で示せば、置いた場所が同じかどうかだけを比べられる。
#[derive(Debug, Clone)]
pub struct Placement {
    /// 囲んだ語。
    pub marked: String,
    /// 囲んだところの直前にある本文（元の HTML から、最大 20 文字）。
    pub before: String,
}

/// 印を置く場所。囲めなければ `None`。
pub fn locate(html: &str, query: &str, nth: usize) -> Option<Placement> {
    let (start, end) = span(html, query, nth)?;
    let before: String = html[..start].chars().rev().take(20).collect::<Vec<_>>()
        .into_iter().rev().collect();
    Some(Placement {
        marked: html[start..end].to_string(),
        before,
    })
}

/// 本文の nth 番目の当たりを `<mark>` で囲んだ HTML。囲めなければ `None`。
pub fn insert(html: &str, query: &str, nth: usize) -> Option<String> {
    let (start, end) = span(html, query, nth)?;

    let mut out = String::with_capacity(html.len() + 40);
    out.push_str(&html[..start]);
    out.push_str(&format!("<mark class=\"{CLASS}\">"));
    out.push_str(&html[start..end]);
    out.push_str("</mark>");
    out.push_str(&html[end..]);
    Some(out)
}

/// 囲む範囲（元の HTML のバイト位置）。
fn span(html: &str, query: &str, nth: usize) -> Option<(usize, usize)> {
    let extracted = html_text::extract(html);
    let (from, to) = search::nth_match(&extracted.text, query, nth)?;

    let origins = align(html, &extracted.text);
    let start = *origins.get(from)?;
    // 終わりは、当たりの最後の文字の後ろ。
    let last = *origins.get(to.saturating_sub(1))?;
    let end = last + source_width(&html[last..]);
    // 節をまたぐ当たりは、始まりの地の文で切る。タグを囲むと入れ子が壊れる。
    let end = end.min(run_end(html, start));
    (end > start).then_some((start, end))
}

/// その文字が属する地の文の終わり。次のタグの手前で止める。
fn run_end(html: &str, at: usize) -> usize {
    match html[at..].find('<') {
        Some(offset) => at + offset,
        None => html.len(),
    }
}

/// 本文の 1 文字が、元の HTML で占める長さ。実体参照は書かれたぶんを数える。
fn source_width(rest: &str) -> usize {
    let Some(c) = rest.chars().next() else {
        return 0;
    };
    if c == '&' {
        if let Some(length) = entity_length(rest) {
            return length;
        }
    }
    c.len_utf8()
}

/// 抽出した本文の 1 文字ごとに、元の HTML でその文字が始まるバイト位置を求める。
///
/// 抽出は削って詰めるだけなので、元を頭から舐めながら同じ文字を拾えば揃う。
/// 揃わない文字（タグの位置に足した空白など）は、いま見ている位置を指しておく。
/// 完全に一致しなくてよい。ずれるのは印の位置だけで、当たりそのものは動かない。
fn align(html: &str, text: &str) -> Vec<usize> {
    let wanted: Vec<char> = text.chars().collect();
    let mut origins = Vec::with_capacity(wanted.len());
    let mut at = 0usize;

    // 本文に混ぜないところ（script / style / コメント）は、抽出も消している。飛ばす。
    let ignored = html_text::ignored_ranges(html);
    let mut cursor = 0usize;
    let mut inside_tag = false;

    while at < wanted.len() && cursor < html.len() {
        if let Some((_, end)) = ignored.iter().find(|(from, to)| cursor >= *from && cursor < *to) {
            cursor = *end;
            inside_tag = false;
            continue;
        }
        let c = html[cursor..].chars().next().expect("境界は文字の頭");
        let width = c.len_utf8();

        if c == '<' {
            inside_tag = true;
            cursor += width;
            continue;
        }
        if c == '>' {
            inside_tag = false;
            cursor += width;
            // タグの位置には空白が 1 つ入る。本文側がそれを待っていれば、ここを指す。
            if wanted[at] == ' ' {
                origins.push(cursor);
                at += 1;
            }
            continue;
        }
        if inside_tag {
            cursor += width;
            continue;
        }

        // 実体参照は解かれて 1 文字になる。始まりの位置を指しておく。
        if c == '&' {
            if let Some(length) = entity_length(&html[cursor..]) {
                origins.push(cursor);
                at += 1;
                cursor += length;
                continue;
            }
        }

        if c == wanted[at] {
            origins.push(cursor);
            at += 1;
            cursor += width;
            continue;
        }

        // 改行や連なった空白は 1 つに詰められる。本文側が空白を待っていれば、そこで揃える。
        if wanted[at] == ' ' && c.is_whitespace() {
            origins.push(cursor);
            at += 1;
            cursor += width;
            continue;
        }
        cursor += width;
    }

    // 揃えきれなかった残りは、末尾を指しておく。
    while origins.len() < wanted.len() {
        origins.push(html.len());
    }
    origins
}

/// `&...;` の長さ。実体参照でなければ `None`。
fn entity_length(rest: &str) -> Option<usize> {
    let end = rest.char_indices().take(12).find(|(_, c)| *c == ';')?.0;
    let inside = &rest[1..end];
    if inside.is_empty() || inside.contains('<') || inside.contains(' ') {
        return None;
    }
    Some(end + 1)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn marked(html: &str, query: &str, nth: usize) -> String {
        insert(html, query, nth).unwrap_or_else(|| panic!("囲めなかった: {query} の {nth} 番目"))
    }

    #[test]
    fn 当たりを囲む() {
        let out = marked("<p>これはサンプルです</p>", "サンプル", 0);
        assert!(out.contains(r#"<mark class="choro-found">サンプル</mark>"#), "{out}");
    }

    #[test]
    fn 何番目かで選び分ける() {
        let html = "<p>まえ サンプル</p><p>あと サンプル</p>";
        assert!(marked(html, "サンプル", 1).contains(r#"あと <mark class="choro-found">サンプル</mark>"#));
    }

    #[test]
    fn 検索が数えた通し番号と同じものを選ぶ() {
        // 抽出した本文で数えた nth と、ここで囲む当たりが一致していること。
        let html = "<p>型と型と型</p>";
        let text = html_text::extract(html).text;
        for nth in 0..3 {
            let (from, _) = search::nth_match(&text, "型", nth).expect("当たり");
            let before = text.chars().take(from).filter(|c| *c == '型').count();
            assert_eq!(before, nth, "{nth} 番目の前に型が {before} 個");
            assert!(insert(html, "型", nth).is_some());
        }
    }

    #[test]
    fn 全角と半角を区別しない() {
        let out = marked("<p>ＡＢＣ</p>", "abc", 0);
        assert!(out.contains(r#"<mark class="choro-found">ＡＢＣ</mark>"#), "{out}");
    }

    #[test]
    fn 節をまたぐ語はそもそも当たりにならない() {
        // 抽出はタグの位置に空白を 1 つ残すので、「本<b>文</b>」の本文は「本 文」になる。
        // 検索が当てない以上、囲む対象にもならない。入れ子を壊す心配はここで消えている。
        let html = "<p>本<b>文</b></p>";
        assert!(html_text::extract(html).text.contains("本 文"));
        assert!(insert(html, "本文", 0).is_none());
    }

    #[test]
    fn 実体参照を挟んでも位置がずれない() {
        let out = marked("<p>a&amp;b の話</p>", "の話", 0);
        assert!(out.contains(r#"<mark class="choro-found">の話</mark>"#), "{out}");
    }

    #[test]
    fn スクリプトの中は数えない() {
        // 抽出が本文に混ぜないものは、当たりにもならない。
        let html = "<script>var 型 = 1;</script><p>型</p>";
        let out = marked(html, "型", 0);
        assert!(out.contains(r#"<p><mark class="choro-found">型</mark></p>"#), "{out}");
    }

    #[test]
    fn 見つからない語では何も返さない() {
        assert!(insert("<p>本文</p>", "出てこない語", 0).is_none());
        assert!(insert("<p>本文</p>", "本文", 5).is_none());
        assert!(insert("<p>本文</p>", "", 0).is_none());
    }

    #[test]
    fn 囲んでも本文の字は増えない() {
        // 印はタグなので、抽出はその位置に空白を残す。字そのものは変わらない。
        let html = "<p>これはサンプルです</p>";
        let out = marked(html, "サンプル", 0);
        let squeeze = |s: &str| s.replace(' ', "");
        assert_eq!(squeeze(&html_text::extract(html).text), squeeze(&html_text::extract(&out).text));
    }
}
