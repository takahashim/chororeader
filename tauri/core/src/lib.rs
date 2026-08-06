//! chororeader の UI に依らない中身。
//!
//! 画面に触れないことを保っておくと、突き合わせ用の probe から同じ経路を呼べる。
//! 出力の形と値は conformance/CONTRACT.md で定義し、macOS 版・C# 版と揃える。

pub mod archive;
pub mod css_compat;
pub mod epub_parser;
pub mod html_text;
pub mod mark;
pub mod index;
pub mod paths;
pub mod pdf;
pub mod preview;
pub mod publication;
pub mod report;
pub mod search;
pub mod style;
pub mod xml;

pub use archive::{EpubArchive, ResourceProvider};
pub use publication::{DocumentError, DocumentFormat, Publication, Result};
