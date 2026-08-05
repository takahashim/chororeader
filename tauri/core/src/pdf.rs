//! PDF について答えられる事実を返す。
//!
//! 実体は MuPDF だが、その型はこの層より外へ出さない。
//! 描画ライブラリを差し替えても、ここより外に影響が出ないようにするため。

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

    pub fn outline(&self) -> Vec<TocEntry> {
        fn convert(items: &[mupdf::Outline]) -> Vec<TocEntry> {
            items
                .iter()
                .map(|item| TocEntry {
                    title: item.title.clone(),
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
}

/// PDF として開けるか。描画には踏み込まない。
pub fn can_open(path: &str) -> bool {
    PdfDocument::open(path).is_some()
}
