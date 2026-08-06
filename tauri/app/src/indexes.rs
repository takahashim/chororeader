//! 全文検索の索引の置き場所と、作り直しの判断。
//!
//! 索引は書籍そのものから何度でも作り直せるので、消えても困らない。
//! そのため覚え書きと同じ場所へ置きっぱなしにし、元ファイルが変わったら捨てる。
//!
//! ほどいたものは持ち続ける。書棚の横断検索は引くたびに全冊の索引に触るので、
//! 毎回ほどき直すと蔵書 78 冊で 1.4 秒かかり、絞り込みより読み込みの方が高く付く。

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use chororeader_core::archive::{EpubArchive, ResourceProvider};
use chororeader_core::index::Index;
use chororeader_core::paths;
use chororeader_core::pdf::PdfWorker;
use chororeader_core::publication::{detect_format, DocumentFormat, Publication};
use chororeader_core::{epub_parser, html_text};
use tauri::Manager;

/// 索引と走査に要るものだけを開いた形。
///
/// 開いている書籍を使い回さず、その都度開き直す。
/// EPUB の読み出しは中央ディレクトリだけなので安く、PDF は別のスレッドに閉じ込めた
/// 実体にしておかないと、描画中の書籍を背後から触ることになるためである。
pub enum Source {
    Epub {
        archive: EpubArchive,
        publication: Publication,
    },
    Pdf {
        worker: PdfWorker,
    },
}

pub fn open_source(path: &str) -> Option<Source> {
    match detect_format(path) {
        Some(DocumentFormat::Pdf) => PdfWorker::open(path).map(|worker| Source::Pdf { worker }),
        Some(DocumentFormat::ReflowableEpub) => {
            let archive = EpubArchive::open(path).ok()?;
            let publication = epub_parser::parse(&archive).ok()?;
            Some(Source::Epub {
                archive,
                publication,
            })
        }
        _ => None,
    }
}

/// 索引に載せる本文を単位ごとに切り出す。EPUB は読み順の 1 項目、PDF は 1 ページ。
pub fn unit_texts(source: &Source) -> Vec<String> {
    match source {
        Source::Epub {
            archive,
            publication,
        } => publication
            .reading_order
            .iter()
            .map(|link| {
                archive
                    .read(&link.href)
                    .map(|data| {
                        html_text::extract(&chororeader_core::css_compat::decode_text(&data)).text
                    })
                    .unwrap_or_default()
            })
            .collect(),
        Source::Pdf { worker } => worker.page_texts(),
    }
}

struct Cached {
    index: Arc<Index>,
    size: u64,
    modified: u64,
}

pub struct Indexes {
    directory: PathBuf,
    memory: Mutex<HashMap<String, Cached>>,
}

impl Indexes {
    pub fn load(app: &tauri::AppHandle) -> Self {
        let directory = app
            .path()
            .app_config_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join("index");
        let _ = std::fs::create_dir_all(&directory);
        Indexes {
            directory,
            memory: Mutex::new(HashMap::new()),
        }
    }

    /// 作らずに、既にあるものだけを返す。
    pub fn cached(&self, path: &str) -> Option<Arc<Index>> {
        let path = paths::normalize(path);
        let (size, modified) = stamp(&path)?;

        if let Some(found) = self.memory.lock().ok()?.get(&path) {
            if found.size == size && found.modified == modified {
                return Some(found.index.clone());
            }
        }

        let bytes = std::fs::read(self.location(&path)).ok()?;
        let (stored_path, stored_size, stored_modified, payload) = unwrap(&bytes)?;
        // 名前の重なりで別の本の索引を掴まないよう、道そのものも見る。
        if stored_path != path || stored_size != size || stored_modified != modified {
            return None;
        }

        let index = Arc::new(Index::decode(payload)?);
        self.remember(path, index.clone(), size, modified);
        Some(index)
    }

    /// 索引を返す。無ければその場で作って置く。書籍を丸ごと読むので時間がかかる。
    pub fn ensure(&self, path: &str, source: &Source) -> Option<Arc<Index>> {
        if let Some(found) = self.cached(path) {
            return Some(found);
        }
        let path = paths::normalize(path);
        let (size, modified) = stamp(&path)?;

        let index = Arc::new(Index::build(&unit_texts(source)));
        let mut out = Vec::new();
        out.extend_from_slice(b"CHIB");
        out.push(1);
        put_bytes(&mut out, path.as_bytes());
        put(&mut out, size);
        put(&mut out, modified);
        out.extend_from_slice(&index.encode());
        let _ = std::fs::write(self.location(&path), &out);

        self.remember(path, index.clone(), size, modified);
        Some(index)
    }

    /// 引かれる前に、置いてある索引をほどいておく。
    pub fn warm(&self, paths: &[String]) {
        for path in paths {
            let _ = self.cached(path);
        }
    }

    fn remember(&self, path: String, index: Arc<Index>, size: u64, modified: u64) {
        let Ok(mut memory) = self.memory.lock() else {
            return;
        };
        // 蔵書が増えても際限なく抱えない。溢れたら一度捨てて入れ直す。
        if memory.len() >= 200 {
            memory.clear();
        }
        memory.insert(
            path,
            Cached {
                index,
                size,
                modified,
            },
        );
    }

    fn location(&self, path: &str) -> PathBuf {
        self.directory.join(format!("{}.idx", digest(path)))
    }
}

fn stamp(path: &str) -> Option<(u64, u64)> {
    let meta = std::fs::metadata(Path::new(path)).ok()?;
    let modified = meta
        .modified()
        .ok()?
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_secs();
    Some((meta.len(), modified))
}

/// 道を短い名前へ畳む。64 bit を 2 つ並べ、重なりは道そのものの照合で弾く。
fn digest(path: &str) -> String {
    let mut out = String::new();
    for seed in [0xcbf2_9ce4_8422_2325u64, 0x9e37_79b9_7f4a_7c15u64] {
        let mut hash = seed;
        for byte in path.as_bytes() {
            hash ^= *byte as u64;
            hash = hash.wrapping_mul(0x100_0000_01b3);
        }
        out.push_str(&format!("{hash:016x}"));
    }
    out
}

fn unwrap(bytes: &[u8]) -> Option<(String, u64, u64, &[u8])> {
    if bytes.len() < 5 || &bytes[..4] != b"CHIB" || bytes[4] != 1 {
        return None;
    }
    let mut at = 5;
    let length = get(bytes, &mut at)? as usize;
    let path = String::from_utf8(bytes.get(at..at + length)?.to_vec()).ok()?;
    at += length;
    let size = get(bytes, &mut at)?;
    let modified = get(bytes, &mut at)?;
    Some((path, size, modified, bytes.get(at..)?))
}

fn put(out: &mut Vec<u8>, mut value: u64) {
    loop {
        let byte = (value & 0x7f) as u8;
        value >>= 7;
        if value == 0 {
            out.push(byte);
            return;
        }
        out.push(byte | 0x80);
    }
}

fn put_bytes(out: &mut Vec<u8>, bytes: &[u8]) {
    put(out, bytes.len() as u64);
    out.extend_from_slice(bytes);
}

fn get(bytes: &[u8], at: &mut usize) -> Option<u64> {
    let mut value = 0u64;
    let mut shift = 0;
    loop {
        let byte = *bytes.get(*at)?;
        *at += 1;
        value |= ((byte & 0x7f) as u64) << shift;
        if byte & 0x80 == 0 {
            return Some(value);
        }
        shift += 7;
        if shift >= 64 {
            return None;
        }
    }
}
