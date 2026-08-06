//! 書籍を開いたときに何が起きたかを、決定的な値だけで要約する。
//! アプリの診断画面と、実装間の突き合わせの両方で使う。
//! 環境やタイミングに依存する値（時刻、所要時間、絶対パス）は入れない。

use std::collections::BTreeMap;
use std::sync::OnceLock;

use regex::{Regex, RegexBuilder};

use crate::archive::{EpubArchive, ResourceProvider};
use crate::css_compat::{self, Change};
use crate::paths;
use crate::publication::{Publication, TocEntry};
use crate::xml;

#[derive(Debug, Clone)]
pub struct BookReport {
    pub format: &'static str,
    pub layout: &'static str,
    pub direction: &'static str,
    pub spine_count: usize,
    pub toc_entry_count: usize,
    pub toc_max_depth: usize,
    pub has_cover: bool,

    pub missing_resources: Vec<String>,
    pub missing_toc_targets: Vec<String>,
    pub missing_spine_items: Vec<String>,

    pub css_file_count: usize,
    pub non_utf8_css_count: usize,
    pub legacy_css_file_count: usize,
    pub css_changes: Vec<Change>,

    pub xhtml_count: usize,
    pub malformed_xhtml_count: usize,

    pub image_count: usize,
    pub font_count: usize,
    pub stored_entry_count: usize,
    pub deflated_entry_count: usize,
    pub has_encryption_metadata: bool,
}

/// 書庫を 1 回だけ舐めて数えるもの。
///
/// ZIP からの取り出しは高いので、走査は 1 度で済ませる。
/// そのぶん数え上げが 1 か所に集まるため、器を分けて `make` から追い出す。
#[derive(Default)]
struct Tally {
    css_files: usize,
    non_utf8: usize,
    legacy_css: usize,
    changes: BTreeMap<String, Change>,
    xhtml: usize,
    malformed: usize,
    images: usize,
    fonts: usize,
    stored: usize,
    deflated: usize,
}

impl Tally {
    fn of(archive: &EpubArchive) -> Tally {
        let mut tally = Tally::default();
        let mut names: Vec<&String> = archive.names().iter().collect();
        names.sort();
        for name in names {
            tally.count(archive, name);
        }
        tally
    }

    fn count(&mut self, archive: &EpubArchive, name: &str) {
        if archive.is_stored(name) {
            self.stored += 1;
        } else {
            self.deflated += 1;
        }

        match extension(name).as_str() {
            "css" => self.count_css(archive, name),
            "xhtml" | "html" | "htm" => self.count_xhtml(archive, name),
            "png" | "jpg" | "jpeg" | "gif" | "svg" | "webp" => self.images += 1,
            "ttf" | "otf" | "woff" | "woff2" => self.fonts += 1,
            _ => {}
        }
    }

    fn count_css(&mut self, archive: &EpubArchive, name: &str) {
        self.css_files += 1;
        let Some(data) = archive.read(name) else {
            return;
        };
        if !css_compat::is_valid_utf8(&data) {
            self.non_utf8 += 1;
        }
        let text = css_compat::decode_text(&data);
        if !text.contains("-epub-") {
            return;
        }
        self.legacy_css += 1;
        for change in css_compat::rewrite(&text).changes {
            let key = format!("{}→{}", change.from, change.to);
            self.changes
                .entry(key)
                .and_modify(|existing| existing.count += change.count)
                .or_insert(change);
        }
    }

    fn count_xhtml(&mut self, archive: &EpubArchive, name: &str) {
        self.xhtml += 1;
        // 読めない章と、XML として壊れている章は、同じ「開けない」として数える。
        let broken = match archive.read_text(name) {
            Some(text) => !xml::is_well_formed(&css_compat::rewrite_xhtml(&text).css),
            None => true,
        };
        if broken {
            self.malformed += 1;
        }
    }

    /// 出力の並びは辞書順に揃える（conformance/CONTRACT.md）。
    fn sorted_changes(&self) -> Vec<Change> {
        let mut changes: Vec<Change> = self.changes.values().cloned().collect();
        changes.sort_by(|a, b| a.from.cmp(&b.from).then(a.to.cmp(&b.to)));
        changes
    }
}

pub fn make(archive: &EpubArchive, publication: &Publication) -> BookReport {
    let tally = Tally::of(archive);
    let css_changes = tally.sorted_changes();
    let mut missing_resources: Vec<String> = Vec::new();
    let mut missing_spine: Vec<String> = Vec::new();

    for link in &publication.reading_order {
        if !archive.contains(&link.href) {
            missing_spine.push(link.href.clone());
        }
    }

    let mut toc_targets: Vec<String> = Vec::new();
    let mut max_depth = 0usize;
    let mut entry_count = 0usize;

    fn walk(
        entries: &[TocEntry],
        depth: usize,
        archive: &EpubArchive,
        targets: &mut Vec<String>,
        max_depth: &mut usize,
        count: &mut usize,
    ) {
        if entries.is_empty() {
            return;
        }
        *max_depth = (*max_depth).max(depth);
        for entry in entries {
            *count += 1;
            if let Some(href) = &entry.href {
                if !archive.contains(href) {
                    targets.push(href.clone());
                }
            }
            walk(&entry.children, depth + 1, archive, targets, max_depth, count);
        }
    }
    walk(
        &publication.table_of_contents,
        1,
        archive,
        &mut toc_targets,
        &mut max_depth,
        &mut entry_count,
    );

    // 章から参照されている画像や CSS のうち、実体が無いものを拾う。
    for link in &publication.reading_order {
        let Some(source) = archive.read_text(&link.href) else {
            continue;
        };
        let base = paths::directory_of(&link.href);
        for reference in references(&source) {
            let resolved = paths::resolve(base, &reference);
            if !resolved.is_empty()
                && !archive.contains(&resolved)
                && !missing_resources.contains(&resolved)
            {
                missing_resources.push(resolved);
            }
        }
    }

    missing_resources.sort();
    missing_spine.sort();
    toc_targets.sort();
    toc_targets.dedup();

    BookReport {
        format: publication.format_name(),
        layout: publication.layout_name(),
        direction: publication.direction_name(),
        spine_count: publication.reading_order.len(),
        toc_entry_count: entry_count,
        toc_max_depth: max_depth,
        has_cover: publication.cover_href.is_some(),
        missing_resources,
        missing_toc_targets: toc_targets,
        missing_spine_items: missing_spine,
        css_file_count: tally.css_files,
        non_utf8_css_count: tally.non_utf8,
        legacy_css_file_count: tally.legacy_css,
        css_changes,
        xhtml_count: tally.xhtml,
        malformed_xhtml_count: tally.malformed,
        image_count: tally.images,
        font_count: tally.fonts,
        stored_entry_count: tally.stored,
        deflated_entry_count: tally.deflated,
        has_encryption_metadata: archive.contains("META-INF/encryption.xml"),
    }
}

/// 章が参照している src / href のうち、外部 URL と fragment 以外を返す。
fn references(html: &str) -> Vec<String> {
    static PATTERN: OnceLock<Regex> = OnceLock::new();
    let pattern = PATTERN.get_or_init(|| {
        RegexBuilder::new(r#"(?:src|href|xlink:href)\s*=\s*["']([^"']+)["']"#)
            .case_insensitive(true)
            .build()
            .expect("組み込みの正規表現")
    });

    let mut out = Vec::new();
    for capture in pattern.captures_iter(html) {
        let raw = capture[1].trim();
        if raw.is_empty() || raw.starts_with('#') || raw.starts_with("data:") {
            continue;
        }
        if raw.contains("://") || raw.starts_with("mailto:") {
            continue;
        }
        let path = paths::strip_fragment(raw).0;
        if !path.is_empty() {
            out.push(path.to_string());
        }
    }
    out
}

fn extension(name: &str) -> String {
    match name.rfind('.') {
        Some(index) => name[index + 1..].to_lowercase(),
        None => String::new(),
    }
}
