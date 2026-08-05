//! container.xml から OPF を辿り、spine・目次・書誌情報を取り出す。
//! 名前空間の宣言は書籍ごとにまちまちなので、要素は局所名で照合する。

use std::collections::{BTreeSet, HashMap};

use crate::archive::{EpubArchive, ResourceProvider};
use crate::css_compat;
use crate::paths;
use crate::publication::{
    Direction, DocumentError, Layout, Link, Publication, Result, TocEntry,
};
use crate::xml::{self, Document};

pub fn parse(archive: &EpubArchive) -> Result<Publication> {
    let opf_path = rootfile_path(archive).ok_or_else(DocumentError::missing_container)?;
    if !archive.contains(&opf_path) {
        return Err(DocumentError::missing_opf(&opf_path));
    }

    let opf_source = css_compat::decode_text(
        &archive
            .read(&opf_path)
            .ok_or_else(|| DocumentError::missing_opf(&opf_path))?,
    );
    let opf = xml::parse(&opf_source)
        .ok_or_else(|| DocumentError::cannot_parse_opf("OPF を XML として読めない"))?;
    let Some(root) = root_index(&opf) else {
        return Err(DocumentError::cannot_parse_opf("根の要素がない"));
    };

    let opf_directory = paths::directory_of(&opf_path).to_string();

    // manifest
    let mut manifest: HashMap<String, Link> = HashMap::new();
    let mut manifest_order: Vec<String> = Vec::new();
    let mut cover_id: Option<String> = None;
    for section in opf.child_elements(root).filter(|i| opf.get(*i).name == "manifest") {
        for item in opf.child_elements(section).filter(|i| opf.get(*i).name == "item") {
            let element = opf.get(item);
            let (Some(id), Some(raw_href)) = (element.attr("id"), element.attr("href")) else {
                continue;
            };
            let href = paths::resolve(&opf_directory, paths::strip_fragment(raw_href).0);
            let properties: BTreeSet<String> = element
                .attr("properties")
                .unwrap_or("")
                .split(' ')
                .filter(|p| !p.is_empty())
                .map(str::to_string)
                .collect();
            if properties.contains("cover-image") {
                cover_id = Some(id.to_string());
            }
            if !manifest.contains_key(id) {
                manifest_order.push(id.to_string());
            }
            manifest.insert(
                id.to_string(),
                Link {
                    href,
                    media_type: element.attr("media-type").unwrap_or("").to_string(),
                    id: Some(id.to_string()),
                    properties,
                },
            );
        }
    }

    // spine
    let spine = opf
        .child_elements(root)
        .find(|i| opf.get(*i).name == "spine");
    let mut reading_order: Vec<Link> = Vec::new();
    let mut spine_properties: Vec<String> = Vec::new();
    if let Some(spine) = spine {
        for itemref in opf
            .child_elements(spine)
            .filter(|i| opf.get(*i).name == "itemref")
        {
            let element = opf.get(itemref);
            let Some(idref) = element.attr("idref") else {
                continue;
            };
            let Some(link) = manifest.get(idref) else {
                continue;
            };
            // linear="no" は本文の流れに入れない補助ページ。読み順からは外す。
            if element.attr("linear") == Some("no") {
                continue;
            }
            let properties = element.attr("properties").unwrap_or("").to_string();
            let mut merged = link.properties.clone();
            for value in properties.split(' ').filter(|p| !p.is_empty()) {
                merged.insert(value.to_string());
            }
            spine_properties.push(properties);
            reading_order.push(Link {
                properties: merged,
                ..link.clone()
            });
        }
    }

    if reading_order.is_empty() {
        return Err(DocumentError::empty_spine());
    }

    // 書誌情報
    let metadata = opf
        .child_elements(root)
        .find(|i| opf.get(*i).name == "metadata");
    let meta_values = |name: &str| -> Vec<String> {
        let Some(metadata) = metadata else {
            return Vec::new();
        };
        opf.child_elements(metadata)
            .filter(|i| opf.get(*i).name == name)
            .map(|i| opf.value(i).trim().to_string())
            .filter(|v| !v.is_empty())
            .collect()
    };

    let titles = meta_values("title");
    let authors = meta_values("creator");
    let languages = meta_values("language");
    let identifiers = meta_values("identifier");

    // レイアウト種別
    let rendition_layout = opf
        .descendants(root, "meta")
        .find(|i| opf.get(*i).attr("property") == Some("rendition:layout"))
        .map(|i| opf.value(i).trim().to_string());
    let mut layout = if rendition_layout.as_deref() == Some("pre-paginated") {
        Layout::Fixed
    } else {
        Layout::Reflowable
    };
    if layout == Layout::Reflowable
        && spine_properties
            .iter()
            .any(|p| p.contains("rendition:layout-pre-paginated"))
    {
        layout = Layout::Fixed;
    }

    let direction = match spine.and_then(|i| opf.get(i).attr("page-progression-direction")) {
        Some("rtl") => Direction::Rtl,
        _ => Direction::Ltr,
    };

    // 表紙
    if cover_id.is_none() {
        cover_id = opf
            .descendants(root, "meta")
            .find(|i| opf.get(*i).attr("name") == Some("cover"))
            .and_then(|i| opf.get(i).attr("content").map(str::to_string));
    }
    let cover_href = cover_id
        .as_deref()
        .and_then(|id| manifest.get(id))
        .map(|link| link.href.clone());

    // 目次。EPUB3 の nav を優先し、無ければ EPUB2 の NCX を読む。
    let mut toc: Vec<TocEntry> = Vec::new();
    let nav_link = manifest_order
        .iter()
        .filter_map(|id| manifest.get(id))
        .find(|link| link.properties.contains("nav"));
    if let Some(nav_link) = nav_link {
        if let Some(data) = archive.read(&nav_link.href) {
            toc = parse_nav_document(
                &css_compat::decode_text(&data),
                paths::directory_of(&nav_link.href),
            );
        }
    }
    if toc.is_empty() {
        let ncx_id = spine.and_then(|i| opf.get(i).attr("toc"));
        let ncx_link = ncx_id
            .and_then(|id| manifest.get(id))
            .or_else(|| {
                manifest_order
                    .iter()
                    .filter_map(|id| manifest.get(id))
                    .find(|link| link.media_type == "application/x-dtbncx+xml")
            });
        if let Some(ncx_link) = ncx_link {
            if let Some(data) = archive.read(&ncx_link.href) {
                toc = parse_ncx(
                    &css_compat::decode_text(&data),
                    paths::directory_of(&ncx_link.href),
                );
            }
        }
    }
    if toc.is_empty() {
        toc = reading_order
            .iter()
            .map(|link| TocEntry {
                title: paths::last_component(&link.href).to_string(),
                href: Some(link.href.clone()),
                fragment: None,
                children: Vec::new(),
            })
            .collect();
    }

    Ok(Publication {
        title: titles.first().cloned().unwrap_or_else(|| "(無題)".to_string()),
        authors,
        language: languages.into_iter().next(),
        identifier: identifiers.into_iter().next(),
        reading_order,
        table_of_contents: toc,
        cover_href,
        layout,
        direction,
    })
}

// MARK: 目次

fn parse_nav_document(source: &str, base: &str) -> Vec<TocEntry> {
    let Some(document) = xml::parse(source) else {
        return Vec::new();
    };
    let Some(root) = root_index(&document) else {
        return Vec::new();
    };

    let navs: Vec<usize> = document.descendants(root, "nav").collect();
    let toc_nav = navs
        .iter()
        .copied()
        .find(|i| {
            document
                .get(*i)
                .attr("type")
                .map(|t| t.contains("toc"))
                .unwrap_or(false)
        })
        .or_else(|| navs.first().copied());

    let Some(toc_nav) = toc_nav else {
        return Vec::new();
    };
    let list = document.descendants(toc_nav, "ol").next();
    match list {
        Some(list) => parse_nav_list(&document, list, base),
        None => Vec::new(),
    }
}

fn parse_nav_list(document: &Document, list: usize, base: &str) -> Vec<TocEntry> {
    let mut entries = Vec::new();
    for item in document
        .child_elements(list)
        .filter(|i| document.get(*i).name == "li")
        .collect::<Vec<_>>()
    {
        let anchor = document
            .child_elements(item)
            .find(|i| matches!(document.get(*i).name.as_str(), "a" | "span"));
        let title = anchor
            .map(|i| document.value(i).trim().to_string())
            .unwrap_or_default();

        let mut href = None;
        let mut fragment = None;
        if let Some(raw) = anchor.and_then(|i| document.get(i).attr("href")) {
            let (path, frag) = paths::strip_fragment(raw);
            if !path.is_empty() {
                href = Some(paths::resolve(base, path));
            }
            fragment = frag.map(str::to_string);
        }

        let sublist = document
            .child_elements(item)
            .find(|i| document.get(*i).name == "ol");
        let children = sublist
            .map(|i| parse_nav_list(document, i, base))
            .unwrap_or_default();

        if !title.is_empty() || href.is_some() || !children.is_empty() {
            entries.push(TocEntry {
                title: if title.is_empty() {
                    "(無題)".to_string()
                } else {
                    title
                },
                href,
                fragment,
                children,
            });
        }
    }
    entries
}

fn parse_ncx(source: &str, base: &str) -> Vec<TocEntry> {
    let Some(document) = xml::parse(source) else {
        return Vec::new();
    };
    let Some(root) = root_index(&document) else {
        return Vec::new();
    };
    let nav_map = document.descendants(root, "navMap").next();
    match nav_map {
        Some(nav_map) => parse_nav_points(&document, nav_map, base),
        None => Vec::new(),
    }
}

fn parse_nav_points(document: &Document, parent: usize, base: &str) -> Vec<TocEntry> {
    let mut entries = Vec::new();
    for point in document
        .child_elements(parent)
        .filter(|i| document.get(*i).name == "navPoint")
        .collect::<Vec<_>>()
    {
        let title = document
            .first_child_named(point, "navLabel")
            .and_then(|label| document.first_child_named(label, "text"))
            .map(|i| document.value(i).trim().to_string())
            .unwrap_or_default();

        let mut href = None;
        let mut fragment = None;
        if let Some(src) = document
            .first_child_named(point, "content")
            .and_then(|i| document.get(i).attr("src"))
        {
            let (path, frag) = paths::strip_fragment(src);
            if !path.is_empty() {
                href = Some(paths::resolve(base, path));
            }
            fragment = frag.map(str::to_string);
        }

        entries.push(TocEntry {
            title: if title.is_empty() {
                "(無題)".to_string()
            } else {
                title
            },
            href,
            fragment,
            children: parse_nav_points(document, point, base),
        });
    }
    entries
}

// MARK: 補助

fn rootfile_path(archive: &EpubArchive) -> Option<String> {
    if !archive.contains("META-INF/container.xml") {
        return None;
    }
    let data = archive.read("META-INF/container.xml")?;
    let document = xml::parse(&css_compat::decode_text(&data))?;
    let root = root_index(&document)?;
    let rootfile = document.descendants(root, "rootfile").next()?;
    let value = document.get(rootfile).attr("full-path")?;
    Some(paths::percent_decode(value))
}

/// 根の要素の位置。木は文書順に積んであるため常に 0 番。
fn root_index(document: &Document) -> Option<usize> {
    document.root().map(|_| 0)
}
