//! 読書位置としおりを残す。
//!
//! 書籍そのものには触れない。設定ディレクトリの JSON 1 枚に、書籍のパスを鍵にして書く。
//! 読書中にネットワークを使わないという不変条件があるので、同期は持たない。

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use tauri::Manager;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Position {
    /// EPUB は章の href、PDF は空。
    #[serde(default)]
    pub href: String,
    /// 章やページの中でどこまで読んだか。0 から 1。
    #[serde(default)]
    pub progression: f64,
    /// PDF のページ番号。
    #[serde(default)]
    pub page: i32,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Bookmark {
    pub href: String,
    pub progression: f64,
    pub page: i32,
    pub label: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BookState {
    #[serde(default)]
    pub position: Position,
    #[serde(default)]
    pub bookmarks: Vec<Bookmark>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct Stored {
    #[serde(default)]
    books: BTreeMap<String, BookState>,
    /// 最近開いた書籍。新しいものが先。
    #[serde(default)]
    recent: Vec<String>,
    #[serde(default)]
    settings: serde_json::Value,
}

pub struct Store {
    path: PathBuf,
    data: Mutex<Stored>,
}

impl Store {
    pub fn load(app: &tauri::AppHandle) -> Self {
        let directory = app
            .path()
            .app_config_dir()
            .unwrap_or_else(|_| PathBuf::from("."));
        let _ = std::fs::create_dir_all(&directory);
        let path = directory.join("state.json");
        let data = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        Self {
            path,
            data: Mutex::new(data),
        }
    }

    fn write(&self, data: &Stored) {
        if let Ok(text) = serde_json::to_string_pretty(data) {
            let _ = std::fs::write(&self.path, text);
        }
    }

    pub fn state_of(&self, book_path: &str) -> BookState {
        self.data
            .lock()
            .unwrap()
            .books
            .get(book_path)
            .cloned()
            .unwrap_or_default()
    }

    pub fn remember(&self, book_path: &str, position: Position) {
        let mut data = self.data.lock().unwrap();
        data.books.entry(book_path.to_string()).or_default().position = position;
        data.recent.retain(|p| p != book_path);
        data.recent.insert(0, book_path.to_string());
        data.recent.truncate(30);
        self.write(&data);
    }

    /// 同じ位置にしおりがあれば外し、無ければ付ける。
    pub fn toggle_bookmark(&self, book_path: &str, bookmark: Bookmark) -> Vec<Bookmark> {
        let mut data = self.data.lock().unwrap();
        let state = data.books.entry(book_path.to_string()).or_default();
        let same = |b: &Bookmark| {
            b.href == bookmark.href
                && b.page == bookmark.page
                && (b.progression - bookmark.progression).abs() < 0.02
        };
        if state.bookmarks.iter().any(same) {
            state.bookmarks.retain(|b| !same(b));
        } else {
            state.bookmarks.push(bookmark);
            state
                .bookmarks
                .sort_by(|a, b| {
                    a.href
                        .cmp(&b.href)
                        .then(a.page.cmp(&b.page))
                        .then(a.progression.total_cmp(&b.progression))
                });
        }
        let bookmarks = state.bookmarks.clone();
        self.write(&data);
        bookmarks
    }

    pub fn recent(&self) -> Vec<String> {
        self.data.lock().unwrap().recent.clone()
    }

    pub fn settings(&self) -> serde_json::Value {
        self.data.lock().unwrap().settings.clone()
    }

    pub fn save_settings(&self, settings: serde_json::Value) {
        let mut data = self.data.lock().unwrap();
        data.settings = settings;
        self.write(&data);
    }
}
