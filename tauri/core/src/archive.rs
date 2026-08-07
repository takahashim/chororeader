//! 本文とその周辺リソースの供給元。EPUB は展開せず、要求時だけ取り出す。

use std::cell::RefCell;
use std::collections::HashMap;
use std::fs::File;
use std::io::Read;

use crate::paths;
use crate::publication::{DocumentError, Result};

/// 供給元の抽象。抜粋も固定レイアウトも、ZIP かどうかを知らずに済ませる。
pub trait ResourceProvider {
    fn contains(&self, path: &str) -> bool;
    fn read(&self, path: &str) -> Option<Vec<u8>>;

    /// 文字として読む。
    ///
    /// 書庫から取り出したバイト列は、必ず同じ規則で文字に直す必要がある
    /// （BOM、UTF-8 でない CSS）。呼ぶ側で書くと、いつか書き忘れる。
    fn read_text(&self, path: &str) -> Option<String> {
        Some(crate::css_compat::decode_text(&self.read(path)?))
    }
}

struct Entry {
    index: usize,
    compressed: u64,
    uncompressed: u64,
}

/// EPUB の中身を、展開せずに要求時だけ取り出す。
pub struct EpubArchive {
    zip: RefCell<zip::ZipArchive<File>>,
    entries: HashMap<String, Entry>,
    /// 大文字小文字だけが違う参照を持つ EPUB が実在するため、緩い照合用の索引も持つ。
    lowercased: HashMap<String, String>,
    names: Vec<String>,
}

impl EpubArchive {
    pub fn open(path: &str) -> Result<Self> {
        let file = File::open(path).map_err(|e| DocumentError::broken_archive(e.to_string()))?;
        let mut zip =
            zip::ZipArchive::new(file).map_err(|e| DocumentError::broken_archive(e.to_string()))?;

        let mut entries = HashMap::new();
        let mut lowercased: HashMap<String, String> = HashMap::new();
        let mut names = Vec::new();

        for index in 0..zip.len() {
            let file = zip
                .by_index(index)
                .map_err(|e| DocumentError::broken_archive(e.to_string()))?;
            // 項目名は常に UTF-8 として読む。
            // zip クレートは UTF-8 のフラグが立っていない項目を CP437 として解くが、
            // それを書き出す道具（rubyzip など）は珍しくなく、日本語のファイル名が化ける。
            // 他の実装はいずれも UTF-8 で読んでいるため、そちらへ揃える。
            let raw = String::from_utf8_lossy(file.name_raw()).into_owned();
            // ディレクトリ項目は持たない。名前は常に "/" 区切りで扱う。
            if raw.ends_with('/') {
                continue;
            }
            let name = paths::normalize(&raw.replace('\\', "/"));
            lowercased
                .entry(name.to_lowercase())
                .or_insert_with(|| name.clone());
            entries.insert(
                name.clone(),
                Entry {
                    index,
                    compressed: file.compressed_size(),
                    uncompressed: file.size(),
                },
            );
            names.push(name);
        }

        if entries.is_empty() {
            return Err(DocumentError::broken_archive("項目が 1 つもない"));
        }

        Ok(Self {
            zip: RefCell::new(zip),
            entries,
            lowercased,
            names,
        })
    }

    /// 収録されている項目の名前。順序は書庫の並びのまま。
    pub fn names(&self) -> &[String] {
        &self.names
    }

    /// 無圧縮で格納されているか。mimetype は無圧縮という決まりがある。
    pub fn is_stored(&self, path: &str) -> bool {
        match self.find(path) {
            Some(entry) => entry.compressed == entry.uncompressed,
            None => false,
        }
    }

    fn find(&self, path: &str) -> Option<&Entry> {
        let normalized = paths::normalize(path);
        if let Some(entry) = self.entries.get(&normalized) {
            return Some(entry);
        }
        let decoded = paths::normalize(&paths::percent_decode(&normalized));
        if let Some(entry) = self.entries.get(&decoded) {
            return Some(entry);
        }
        let key = self.lowercased.get(&decoded.to_lowercase())?;
        self.entries.get(key)
    }
}

impl ResourceProvider for EpubArchive {
    fn contains(&self, path: &str) -> bool {
        self.find(path).is_some()
    }

    fn read(&self, path: &str) -> Option<Vec<u8>> {
        let index = self.find(path)?.index;
        let mut zip = self.zip.borrow_mut();
        let mut file = zip.by_index(index).ok()?;
        let mut buffer = Vec::with_capacity(file.size() as usize);
        file.read_to_end(&mut buffer).ok()?;
        Some(buffer)
    }
}
