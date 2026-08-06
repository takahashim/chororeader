//! container.xml から OPF を辿り、spine・目次・書誌情報を取り出す。
//! 名前空間の宣言は書籍ごとにまちまちなので、要素は局所名で照合する。

use std::collections::{BTreeSet, HashMap};

use crate::archive::{EpubArchive, ResourceProvider};
use crate::paths;
use crate::publication::{
    Direction, DocumentError, Layout, Link, Publication, Result, TocEntry,
};
use crate::xml::{self, Document};

/// manifest に並ぶ資源。id で引くのと、書かれた順に辿るのと、両方が要る。
struct Manifest {
    by_id: HashMap<String, Link>,
    order: Vec<String>,
    /// 表紙として名指しされた項目の id。properties か、EPUB2 の meta から拾う。
    cover_id: Option<String>,
}

impl Manifest {
    fn get(&self, id: &str) -> Option<&Link> {
        self.by_id.get(id)
    }

    /// 書かれた順に辿って、条件に合う最初のもの。
    fn find(&self, matches: impl Fn(&Link) -> bool) -> Option<&Link> {
        self.order
            .iter()
            .filter_map(|id| self.by_id.get(id))
            .find(|link| matches(link))
    }
}

pub fn parse(archive: &EpubArchive) -> Result<Publication> {
    let opf_path = rootfile_path(archive).ok_or_else(DocumentError::missing_container)?;
    if !archive.contains(&opf_path) {
        return Err(DocumentError::missing_opf(&opf_path));
    }

    let opf_source = archive
        .read_text(&opf_path)
        .ok_or_else(|| DocumentError::missing_opf(&opf_path))?;
    let opf = xml::parse(&opf_source)
        .ok_or_else(|| DocumentError::cannot_parse_opf("OPF を XML として読めない"))?;
    let Some(root) = root_index(&opf) else {
        return Err(DocumentError::cannot_parse_opf("根の要素がない"));
    };

    let directory = paths::directory_of(&opf_path).to_string();
    let manifest = manifest(&opf, root, &directory);
    let spine = opf.child_elements(root).find(|i| opf.get(*i).name == "spine");
    let (reading_order, spine_properties) = reading_order(&opf, spine, &manifest);
    if reading_order.is_empty() {
        return Err(DocumentError::empty_spine());
    }

    let metadata = metadata(&opf, root);
    Ok(Publication {
        title: metadata.first("title").unwrap_or_else(|| "(無題)".to_string()),
        authors: metadata.all("creator"),
        language: metadata.first("language"),
        identifier: metadata.first("identifier"),
        table_of_contents: table_of_contents(archive, &opf, spine, &manifest, &reading_order),
        cover_href: cover_href(&opf, root, &manifest),
        layout: layout(&opf, root, &spine_properties),
        direction: direction(&opf, spine),
        reading_order,
    })
}

// MARK: OPF の各部

fn manifest(opf: &Document, root: usize, directory: &str) -> Manifest {
    let mut by_id: HashMap<String, Link> = HashMap::new();
    let mut order: Vec<String> = Vec::new();
    let mut cover_id = None;

    for section in opf.child_elements(root).filter(|i| opf.get(*i).name == "manifest") {
        for item in opf.child_elements(section).filter(|i| opf.get(*i).name == "item") {
            let element = opf.get(item);
            let (Some(id), Some(raw_href)) = (element.attr("id"), element.attr("href")) else {
                continue;
            };
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
            if !by_id.contains_key(id) {
                order.push(id.to_string());
            }
            by_id.insert(
                id.to_string(),
                Link {
                    href: paths::resolve(directory, paths::strip_fragment(raw_href).0),
                    media_type: element.attr("media-type").unwrap_or("").to_string(),
                    id: Some(id.to_string()),
                    properties,
                },
            );
        }
    }

    Manifest {
        by_id,
        order,
        cover_id,
    }
}

/// 読み順と、itemref に書かれた properties。properties はレイアウト種別の判定に要る。
fn reading_order(
    opf: &Document,
    spine: Option<usize>,
    manifest: &Manifest,
) -> (Vec<Link>, Vec<String>) {
    let mut order: Vec<Link> = Vec::new();
    let mut properties: Vec<String> = Vec::new();
    let Some(spine) = spine else {
        return (order, properties);
    };

    for itemref in opf.child_elements(spine).filter(|i| opf.get(*i).name == "itemref") {
        let element = opf.get(itemref);
        let Some(link) = element.attr("idref").and_then(|id| manifest.get(id)) else {
            continue;
        };
        // linear="no" は本文の流れに入れない補助ページ。読み順からは外す。
        if element.attr("linear") == Some("no") {
            continue;
        }
        let written = element.attr("properties").unwrap_or("").to_string();
        let mut merged = link.properties.clone();
        for value in written.split(' ').filter(|p| !p.is_empty()) {
            merged.insert(value.to_string());
        }
        properties.push(written);
        order.push(Link {
            properties: merged,
            ..link.clone()
        });
    }
    (order, properties)
}

/// 書誌情報。同じ名前の要素が複数あることがあるので、並びのまま持つ。
struct Metadata<'a> {
    opf: &'a Document,
    section: Option<usize>,
}

impl Metadata<'_> {
    fn all(&self, name: &str) -> Vec<String> {
        let Some(section) = self.section else {
            return Vec::new();
        };
        self.opf
            .child_elements(section)
            .filter(|i| self.opf.get(*i).name == name)
            .map(|i| self.opf.value(i).trim().to_string())
            .filter(|v| !v.is_empty())
            .collect()
    }

    fn first(&self, name: &str) -> Option<String> {
        self.all(name).into_iter().next()
    }
}

fn metadata<'a>(opf: &'a Document, root: usize) -> Metadata<'a> {
    Metadata {
        opf,
        section: opf.child_elements(root).find(|i| opf.get(*i).name == "metadata"),
    }
}

/// レイアウト種別。書籍全体の宣言が無くても、spine の項目が名乗ることがある。
fn layout(opf: &Document, root: usize, spine_properties: &[String]) -> Layout {
    let declared = opf
        .descendants(root, "meta")
        .find(|i| opf.get(*i).attr("property") == Some("rendition:layout"))
        .map(|i| opf.value(i).trim().to_string());
    if declared.as_deref() == Some("pre-paginated") {
        return Layout::Fixed;
    }
    if spine_properties
        .iter()
        .any(|p| p.contains("rendition:layout-pre-paginated"))
    {
        return Layout::Fixed;
    }
    Layout::Reflowable
}

fn direction(opf: &Document, spine: Option<usize>) -> Direction {
    match spine.and_then(|i| opf.get(i).attr("page-progression-direction")) {
        Some("rtl") => Direction::Rtl,
        _ => Direction::Ltr,
    }
}

/// 表紙。EPUB3 の properties を優先し、無ければ EPUB2 の meta name="cover" を見る。
fn cover_href(opf: &Document, root: usize, manifest: &Manifest) -> Option<String> {
    let id = manifest.cover_id.clone().or_else(|| {
        opf.descendants(root, "meta")
            .find(|i| opf.get(*i).attr("name") == Some("cover"))
            .and_then(|i| opf.get(i).attr("content").map(str::to_string))
    })?;
    manifest.get(&id).map(|link| link.href.clone())
}

/// 目次。EPUB3 の nav を優先し、無ければ EPUB2 の NCX、どちらも無ければ読み順で代える。
fn table_of_contents(
    archive: &EpubArchive,
    opf: &Document,
    spine: Option<usize>,
    manifest: &Manifest,
    reading_order: &[Link],
) -> Vec<TocEntry> {
    let nav = manifest.find(|link| link.properties.contains("nav"));
    if let Some(nav) = nav {
        if let Some(source) = archive.read_text(&nav.href) {
            let entries = parse_nav_document(&source, paths::directory_of(&nav.href));
            if !entries.is_empty() {
                return entries;
            }
        }
    }

    let ncx = spine
        .and_then(|i| opf.get(i).attr("toc"))
        .and_then(|id| manifest.get(id))
        .or_else(|| manifest.find(|link| link.media_type == "application/x-dtbncx+xml"));
    if let Some(ncx) = ncx {
        if let Some(source) = archive.read_text(&ncx.href) {
            let entries = parse_ncx(&source, paths::directory_of(&ncx.href));
            if !entries.is_empty() {
                return entries;
            }
        }
    }

    reading_order
        .iter()
        .map(|link| TocEntry {
            title: paths::last_component(&link.href).to_string(),
            href: Some(link.href.clone()),
            fragment: None,
            children: Vec::new(),
        })
        .collect()
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
    let document = xml::parse(&archive.read_text("META-INF/container.xml")?)?;
    let root = root_index(&document)?;
    let rootfile = document.descendants(root, "rootfile").next()?;
    let value = document.get(rootfile).attr("full-path")?;
    Some(paths::percent_decode(value))
}

/// 根の要素の位置。木は文書順に積んであるため常に 0 番。
fn root_index(document: &Document) -> Option<usize> {
    document.root().map(|_| 0)
}
