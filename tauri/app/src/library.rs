//! 開いている書籍を持つ層。
//!
//! 同じ書籍を複数のウィンドウで開いても、解析結果と ZIP は 1 つで済ませる。
//! 比較しながら読むことが目的の道具なので、同じ本が何度も開かれる前提で作る。

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use serde::Serialize;

use tzreader_core::archive::EpubArchive;
use tzreader_core::epub_parser;
use tzreader_core::paths;
use tzreader_core::pdf::PdfWorker;
use tzreader_core::preview::fixed_layout;
use tzreader_core::publication::{detect_format, DocumentFormat, Publication, TocEntry};

pub enum Content {
    Epub {
        archive: EpubArchive,
        publication: Publication,
    },
    Pdf {
        worker: PdfWorker,
        title: String,
    },
}

pub struct Book {
    pub id: String,
    pub path: String,
    pub content: Content,
}

/// 開いている書籍の集まり。
#[derive(Default)]
pub struct Library {
    books: Mutex<HashMap<String, Arc<Mutex<Book>>>>,
    /// 同じパスを二度開かないための索引。
    by_path: Mutex<HashMap<String, String>>,
    next_id: Mutex<usize>,
}

impl Library {
    pub fn open(&self, path: &str) -> Result<Arc<Mutex<Book>>, String> {
        // 鍵にする前に形を揃える。macOS は経路によって分解形と合成形のどちらも返す。
        let path = &paths::normalize(path);
        if let Some(id) = self.by_path.lock().unwrap().get(path) {
            if let Some(book) = self.books.lock().unwrap().get(id) {
                return Ok(book.clone());
            }
        }

        let content = match detect_format(path) {
            Some(DocumentFormat::Pdf) => {
                let worker = PdfWorker::open(path).ok_or("PDF として開けない")?;
                let title = paths::last_component(path)
                    .rsplit_once('.')
                    .map(|(stem, _)| stem.to_string())
                    .unwrap_or_else(|| path.to_string());
                Content::Pdf { worker, title }
            }
            Some(DocumentFormat::ReflowableEpub) => {
                let archive = EpubArchive::open(path).map_err(|e| e.detail)?;
                let publication = epub_parser::parse(&archive).map_err(|e| e.detail)?;
                Content::Epub {
                    archive,
                    publication,
                }
            }
            _ => return Err("対応していない形式".to_string()),
        };

        let id = {
            let mut next = self.next_id.lock().unwrap();
            *next += 1;
            format!("b{next}")
        };
        let book = Arc::new(Mutex::new(Book {
            id: id.clone(),
            path: path.to_string(),
            content,
        }));
        self.books.lock().unwrap().insert(id.clone(), book.clone());
        self.by_path
            .lock()
            .unwrap()
            .insert(path.to_string(), id);
        Ok(book)
    }

    pub fn get(&self, id: &str) -> Option<Arc<Mutex<Book>>> {
        self.books.lock().unwrap().get(id).cloned()
    }
}

// MARK: 画面へ渡す形

#[derive(Serialize)]
pub struct TocNode {
    pub title: String,
    pub href: Option<String>,
    pub fragment: Option<String>,
    pub children: Vec<TocNode>,
}

#[derive(Serialize)]
pub struct FixedPage {
    /// image なら 1 枚の絵、document なら元の XHTML をそのまま埋める。
    pub kind: String,
    pub href: String,
}

#[derive(Serialize)]
pub struct Chapter {
    pub href: String,
    pub title: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BookInfo {
    pub id: String,
    pub path: String,
    pub format: String,
    pub title: String,
    pub authors: Vec<String>,
    pub direction: String,
    pub layout: String,
    pub toc: Vec<TocNode>,
    pub chapters: Vec<Chapter>,
    pub page_count: i32,
    /// PDF にテキスト層があるか。無い書籍では検索できないことを画面に出す。
    pub has_text_layer: bool,
    /// 固定レイアウトのページ。リフロー型では空。
    pub pages: Vec<FixedPage>,
    /// ページの寸法。拡大の枠を先に決めるために要る。
    pub page_size: Option<(f64, f64)>,
}

pub fn describe(book: &Book) -> BookInfo {
    match &book.content {
        Content::Epub {
            publication,
            archive,
        } => {
            // 固定レイアウトのときだけ、ページの種別と寸法を先に決めておく。
            let (pages, page_size) = if publication.is_fixed() {
                let pages: Vec<FixedPage> = publication
                    .reading_order
                    .iter()
                    .map(|link| {
                        let content = fixed_layout::content(&link.href, archive);
                        FixedPage {
                            kind: content.kind.to_string(),
                            href: content.href,
                        }
                    })
                    .collect();
                let size = publication
                    .reading_order
                    .iter()
                    .find_map(|link| fixed_layout::viewport(&link.href, archive));
                (pages, size)
            } else {
                (Vec::new(), None)
            };

            BookInfo {
                id: book.id.clone(),
                path: book.path.clone(),
                format: publication.format_name().to_string(),
                title: publication.title.clone(),
                authors: publication.authors.clone(),
                direction: publication.direction_name().to_string(),
                layout: publication.layout_name().to_string(),
                toc: publication.table_of_contents.iter().map(node).collect(),
                chapters: publication
                    .reading_order
                    .iter()
                    .map(|link| Chapter {
                        href: link.href.clone(),
                        title: publication
                            .title_for_href(&link.href)
                            .unwrap_or_else(|| paths::last_component(&link.href))
                            .to_string(),
                    })
                    .collect(),
                page_count: 0,
                has_text_layer: true,
                pages,
                page_size,
            }
        }
        Content::Pdf { worker, title } => BookInfo {
            id: book.id.clone(),
            path: book.path.clone(),
            format: "pdf".to_string(),
            title: title.clone(),
            authors: Vec::new(),
            direction: "ltr".to_string(),
            layout: "fixed".to_string(),
            toc: worker.outline.iter().map(node).collect(),
            chapters: Vec::new(),
            page_count: worker.page_count,
            has_text_layer: worker.has_text_layer,
            pages: Vec::new(),
            page_size: None,
        },
    }
}

fn node(entry: &TocEntry) -> TocNode {
    TocNode {
        title: entry.title.clone(),
        href: entry.href.clone(),
        fragment: entry.fragment.clone(),
        children: entry.children.iter().map(node).collect(),
    }
}
