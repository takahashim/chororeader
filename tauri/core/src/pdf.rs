//! PDF について答えられる事実を返す。
//!
//! 実体は MuPDF だが、その型はこの層より外へ出さない。
//! 描画ライブラリを差し替えても、ここより外に影響が出ないようにするため。

use std::sync::mpsc::{channel, Sender};
use std::sync::Mutex;

use crate::publication::TocEntry;

pub struct PdfDocument {
    inner: mupdf::Document,
}

impl PdfDocument {
    pub fn open(path: &str) -> Option<Self> {
        let inner = mupdf::Document::open(path).ok()?;
        // 開けても中身が無いものは開けなかったものとして扱う。
        if inner.page_count().ok()? <= 0 {
            return None;
        }
        Some(Self { inner })
    }

    pub fn page_count(&self) -> i32 {
        self.inner.page_count().unwrap_or(0)
    }

    /// テキスト層があるか。無い書籍は検索できないことを画面に出す。
    ///
    /// 同人誌には、入稿のためにフォントをアウトライン化した PDF が混ざる。
    /// 見た目は鮮明でも文字を 1 つも持たないため、検索が黙って 0 件になる。
    pub fn has_text_layer(&self) -> bool {
        let count = self.page_count();
        // 先頭は表紙のことが多い。数ページ見て判断する。
        (0..count.min(5)).any(|index| !self.text_of_page(index).trim().is_empty())
    }

    pub fn text_of_page(&self, index: i32) -> String {
        self.inner
            .load_page(index)
            .and_then(|page| page.text(Default::default()))
            .unwrap_or_default()
    }

    pub fn page_size(&self, index: i32) -> (f32, f32) {
        self.inner
            .load_page(index)
            .and_then(|page| page.bounds())
            .map(|r| (r.width(), r.height()))
            .unwrap_or((0.0, 0.0))
    }

    pub fn outline(&self) -> Vec<TocEntry> {
        fn convert(items: &[mupdf::Outline]) -> Vec<TocEntry> {
            items
                .iter()
                .map(|item| TocEntry {
                    title: item.title.clone(),
                    // PDF の飛び先はページ番号。href の形に合わせて文字列で持つ。
                    href: item.dest.map(|d| d.loc.page_number.to_string()),
                    fragment: None,
                    children: convert(&item.down),
                })
                .collect()
        }
        self.inner.outlines().map(|o| convert(&o)).unwrap_or_default()
    }

    /// ページを描いて PNG で返す。
    pub fn render_page(&self, index: i32, zoom: f32) -> Option<Vec<u8>> {
        let page = self.inner.load_page(index).ok()?;
        let matrix = mupdf::Matrix::new_scale(zoom, zoom);
        let pixmap = page
            .to_pixmap(&matrix, &mupdf::Colorspace::device_rgb(), false, true)
            .ok()?;
        let mut png = Vec::new();
        pixmap.write_to(&mut png, mupdf::ImageFormat::PNG).ok()?;
        Some(png)
    }

    pub fn search(&self, needle: &str, limit: usize) -> Vec<(i32, String)> {
        let mut hits = Vec::new();
        for index in 0..self.page_count() {
            if hits.len() >= limit {
                break;
            }
            let Ok(page) = self.inner.load_page(index) else {
                continue;
            };
            let Ok(quads) = page.search(needle, 4) else {
                continue;
            };
            if quads.is_empty() {
                continue;
            }
            // 前後の文脈は本文から切り出す。座標は画面側で使わないので運ばない。
            let text = page.text(Default::default()).unwrap_or_default();
            let excerpt = excerpt_around(&text, needle);
            hits.push((index, excerpt));
        }
        hits
    }
}

fn excerpt_around(text: &str, needle: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let needle_chars: Vec<char> = needle.chars().collect();
    let position = (0..chars.len().saturating_sub(needle_chars.len().saturating_sub(1)))
        .find(|&i| chars[i..].starts_with(&needle_chars))
        .unwrap_or(0);
    let start = position.saturating_sub(30);
    let end = (position + needle_chars.len() + 40).min(chars.len());
    chars[start..end]
        .iter()
        .collect::<String>()
        .replace('\n', " ")
        .trim()
        .to_string()
}

/// PDF として開けるか。描画には踏み込まない。
pub fn can_open(path: &str) -> bool {
    PdfDocument::open(path).is_some()
}

// MARK: 別スレッドに閉じ込めて使う

enum Job {
    Render {
        page: i32,
        zoom: f32,
        reply: Sender<Option<Vec<u8>>>,
    },
    Text {
        page: i32,
        reply: Sender<String>,
    },
    Size {
        page: i32,
        reply: Sender<(f32, f32)>,
    },
    Search {
        needle: String,
        limit: usize,
        reply: Sender<Vec<(i32, String)>>,
    },
}

/// MuPDF の型はスレッドを跨げないため、開いたスレッドに閉じ込めてチャネル越しに使う。
/// ページ数と目次のように何度も要るものは、開いたときに写しておく。
pub struct PdfWorker {
    jobs: Mutex<Sender<Job>>,
    pub page_count: i32,
    pub outline: Vec<TocEntry>,
    pub has_text_layer: bool,
}

impl PdfWorker {
    pub fn open(path: &str) -> Option<Self> {
        let (jobs, receiver) = channel::<Job>();
        let (ready, ready_receiver) = channel::<Option<(i32, Vec<TocEntry>, bool)>>();
        let path = path.to_string();

        std::thread::spawn(move || {
            let Some(document) = PdfDocument::open(&path) else {
                let _ = ready.send(None);
                return;
            };
            let _ = ready.send(Some((
                document.page_count(),
                document.outline(),
                document.has_text_layer(),
            )));

            while let Ok(job) = receiver.recv() {
                match job {
                    Job::Render { page, zoom, reply } => {
                        let _ = reply.send(document.render_page(page, zoom));
                    }
                    Job::Text { page, reply } => {
                        let _ = reply.send(document.text_of_page(page));
                    }
                    Job::Size { page, reply } => {
                        let _ = reply.send(document.page_size(page));
                    }
                    Job::Search {
                        needle,
                        limit,
                        reply,
                    } => {
                        let _ = reply.send(document.search(&needle, limit));
                    }
                }
            }
        });

        let (page_count, outline, has_text_layer) = ready_receiver.recv().ok()??;
        Some(Self {
            jobs: Mutex::new(jobs),
            page_count,
            outline,
            has_text_layer,
        })
    }

    fn ask<T>(&self, build: impl FnOnce(Sender<T>) -> Job) -> Option<T> {
        let (reply, answer) = channel::<T>();
        self.jobs.lock().ok()?.send(build(reply)).ok()?;
        answer.recv().ok()
    }

    pub fn render_page(&self, page: i32, zoom: f32) -> Option<Vec<u8>> {
        self.ask(|reply| Job::Render { page, zoom, reply })?
    }

    pub fn text_of_page(&self, page: i32) -> String {
        self.ask(|reply| Job::Text { page, reply }).unwrap_or_default()
    }

    pub fn page_size(&self, page: i32) -> (f32, f32) {
        self.ask(|reply| Job::Size { page, reply })
            .unwrap_or((0.0, 0.0))
    }

    pub fn search(&self, needle: &str, limit: usize) -> Vec<(i32, String)> {
        self.ask(|reply| Job::Search {
            needle: needle.to_string(),
            limit,
            reply,
        })
        .unwrap_or_default()
    }
}
