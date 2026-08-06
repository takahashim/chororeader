//! 読書位置としおりを残す。
//!
//! 書籍そのものには触れない。設定ディレクトリの JSON 1 枚に、書籍のパスを鍵にして書く。
//! 読書中にネットワークを使わないという不変条件があるので、同期は持たない。

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use tauri::Manager;

use tzreader_core::paths;

/// 書籍のパスを鍵にするときの形。
///
/// macOS は経路によって分解形（NFD）と合成形（NFC）のどちらも返す。
/// ファイルダイアログからは分解形、引数からは合成形で来ることがあり、
/// そのまま鍵にすると同じ本が二重に並ぶ。
fn key(path: &str) -> String {
    paths::normalize(path)
}

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
    /// 章の中の飛び先。あればここへ戻る。
    #[serde(default)]
    pub fragment: String,
    /// 前にいた場所の書き出し。文字サイズを変えても同じ段落へ戻れるようにするため。
    #[serde(default)]
    pub text: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Bookmark {
    pub href: String,
    pub progression: f64,
    pub page: i32,
    pub label: String,
    /// 付けたときの書き出し。読書位置と同じく、文字サイズを変えても戻れるようにする。
    #[serde(default)]
    pub text: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BookState {
    #[serde(default)]
    pub position: Position,
    #[serde(default)]
    pub bookmarks: Vec<Bookmark>,
    /// 書棚に並べるための覚え書き。開いたときに書き込む。
    /// これがあると、書棚を出すために書籍を開き直さずに済む。
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub authors: Vec<String>,
    #[serde(default)]
    pub format: String,
    /// 表紙の画像を置いたファイル名。covers/ の下にある。
    #[serde(default)]
    pub cover: String,
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
    covers: PathBuf,
    data: Mutex<Stored>,
}

impl Store {
    pub fn load(app: &tauri::AppHandle) -> Self {
        let directory = app
            .path()
            .app_config_dir()
            .unwrap_or_else(|_| PathBuf::from("."));
        let _ = std::fs::create_dir_all(&directory);
        let covers = directory.join("covers");
        let _ = std::fs::create_dir_all(&covers);
        let path = directory.join("state.json");
        let mut data: Stored = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        // 正規化の違いで分かれた項目をここで畳む。畳んだ結果はそのまま書き戻す。
        let merged = merge_by_key(&mut data);
        let store = Self {
            path,
            covers,
            data: Mutex::new(data),
        };
        if merged {
            store.write_now();
        }
        store
    }

    fn write_now(&self) {
        let data = self.data.lock().unwrap();
        self.write(&data);
    }

    pub fn cover_path(&self, name: &str) -> PathBuf {
        self.covers.join(name)
    }

    /// 書棚に出す覚え書きを残す。表紙は画像のまま置く。
    pub fn remember_meta(
        &self,
        book_path: &str,
        title: &str,
        authors: &[String],
        format: &str,
        cover: Option<(String, Vec<u8>)>,
    ) {
        let mut data = self.data.lock().unwrap();
        let state = data.books.entry(key(book_path)).or_default();
        state.title = title.to_string();
        state.authors = authors.to_vec();
        state.format = format.to_string();
        if let Some((name, bytes)) = cover {
            if std::fs::write(self.covers.join(&name), bytes).is_ok() {
                state.cover = name;
            }
        }
        let k = key(book_path);
        data.recent.retain(|p| *p != k);
        data.recent.insert(0, k);
        data.recent.truncate(60);
        self.write(&data);
    }

    /// 書棚。新しく開いたものが先。
    pub fn library(&self) -> Vec<(String, BookState)> {
        let data = self.data.lock().unwrap();
        data.recent
            .iter()
            .map(|path| (path.clone(), data.books.get(path).cloned().unwrap_or_default()))
            .collect()
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
            .get(&key(book_path))
            .cloned()
            .unwrap_or_default()
    }

    pub fn remember(&self, book_path: &str, position: Position) {
        let mut data = self.data.lock().unwrap();
        data.books.entry(key(book_path)).or_default().position = position;
        let k = key(book_path);
        data.recent.retain(|p| *p != k);
        data.recent.insert(0, k);
        data.recent.truncate(30);
        self.write(&data);
    }

    /// 同じ位置にしおりがあれば外し、無ければ付ける。
    pub fn toggle_bookmark(&self, book_path: &str, bookmark: Bookmark) -> Vec<Bookmark> {
        let mut data = self.data.lock().unwrap();
        let state = data.books.entry(key(book_path)).or_default();
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



    pub fn settings(&self) -> serde_json::Value {
        self.data.lock().unwrap().settings.clone()
    }

    pub fn save_settings(&self, settings: serde_json::Value) {
        let mut data = self.data.lock().unwrap();
        data.settings = settings;
        self.write(&data);
    }
}

/// 正規化の違いで分かれてしまった項目を 1 つにまとめる。
/// 覚え書きを持っているほうを残す。
fn merge_by_key(data: &mut Stored) -> bool {
    let before = (data.books.len(), data.recent.len());
    let mut books: BTreeMap<String, BookState> = BTreeMap::new();
    for (path, state) in std::mem::take(&mut data.books) {
        let k = key(&path);
        match books.get(&k) {
            Some(existing) if !existing.title.is_empty() => {}
            _ => {
                books.insert(k, state);
            }
        }
    }
    data.books = books;

    let mut recent = Vec::new();
    for path in std::mem::take(&mut data.recent) {
        let k = key(&path);
        if !recent.contains(&k) {
            recent.push(k);
        }
    }
    data.recent = recent;
    before != (data.books.len(), data.recent.len())
}
