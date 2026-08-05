//! 書籍を表す値と、実装間で揃えるエラー分類。

use std::collections::BTreeSet;
use std::fmt;

/// 形式共通の読書位置。
#[derive(Debug, Clone, Default)]
pub struct Locator {
    pub href: Option<String>,
    pub progression: f64,
    pub title: Option<String>,
    pub text: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Link {
    pub href: String,
    pub media_type: String,
    pub id: Option<String>,
    pub properties: BTreeSet<String>,
}

#[derive(Debug, Clone)]
pub struct TocEntry {
    pub title: String,
    pub href: Option<String>,
    pub fragment: Option<String>,
    pub children: Vec<TocEntry>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Layout {
    Reflowable,
    Fixed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Ltr,
    Rtl,
}

#[derive(Debug, Clone)]
pub struct Publication {
    pub title: String,
    pub authors: Vec<String>,
    pub language: Option<String>,
    pub identifier: Option<String>,
    pub reading_order: Vec<Link>,
    pub table_of_contents: Vec<TocEntry>,
    pub cover_href: Option<String>,
    pub layout: Layout,
    pub direction: Direction,
}

impl Publication {
    pub fn is_fixed(&self) -> bool {
        self.layout == Layout::Fixed
    }

    pub fn format_name(&self) -> &'static str {
        if self.is_fixed() {
            "fixedEPUB"
        } else {
            "reflowableEPUB"
        }
    }

    pub fn layout_name(&self) -> &'static str {
        if self.is_fixed() {
            "fixed"
        } else {
            "reflowable"
        }
    }

    pub fn direction_name(&self) -> &'static str {
        if self.direction == Direction::Rtl {
            "rtl"
        } else {
            "ltr"
        }
    }

    /// 目次から、その章に付いた見出しを探す。
    pub fn title_for_href(&self, href: &str) -> Option<&str> {
        fn search<'a>(entries: &'a [TocEntry], href: &str) -> Option<&'a str> {
            for entry in entries {
                if entry.href.as_deref() == Some(href) {
                    return Some(&entry.title);
                }
                if let Some(found) = search(&entry.children, href) {
                    return Some(found);
                }
            }
            None
        }
        search(&self.table_of_contents, href)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DocumentFormat {
    ReflowableEpub,
    Pdf,
    Markdown,
}

/// 拡張子から表示種別のあたりを付ける。EPUB の固定レイアウト判定は OPF を読んでから。
pub fn detect_format(path: &str) -> Option<DocumentFormat> {
    let extension = path.rsplit_once('.')?.1.to_ascii_lowercase();
    match extension.as_str() {
        "epub" => Some(DocumentFormat::ReflowableEpub),
        "pdf" => Some(DocumentFormat::Pdf),
        "md" | "markdown" => Some(DocumentFormat::Markdown),
        _ => None,
    }
}

/// 実装間で揃える必要のあるエラー分類（conformance/CONTRACT.md）。
/// 表示文言ではなく `kind` を揃える。
#[derive(Debug, Clone)]
pub struct DocumentError {
    pub kind: &'static str,
    pub detail: String,
}

impl DocumentError {
    fn new(kind: &'static str, detail: impl Into<String>) -> Self {
        Self {
            kind,
            detail: detail.into(),
        }
    }

    pub fn broken_archive(detail: impl Into<String>) -> Self {
        Self::new("brokenArchive", detail)
    }

    pub fn missing_container() -> Self {
        Self::new(
            "missingContainer",
            "META-INF/container.xml から rootfile を取り出せない",
        )
    }

    pub fn missing_opf(path: &str) -> Self {
        Self::new("missingOPF", format!("OPF が見つからない: {path}"))
    }

    pub fn cannot_parse_opf(detail: impl Into<String>) -> Self {
        Self::new("cannotParseOPF", detail)
    }

    pub fn empty_spine() -> Self {
        Self::new("emptySpine", "spine に linear な項目がない")
    }

    pub fn cannot_open_pdf() -> Self {
        Self::new("cannotOpenPDF", "PDF として開けない")
    }
}

impl fmt::Display for DocumentError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.kind, self.detail)
    }
}

impl std::error::Error for DocumentError {}

pub type Result<T> = std::result::Result<T, DocumentError>;
