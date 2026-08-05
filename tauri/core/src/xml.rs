//! XML を読むための最小限の木。
//!
//! 名前空間の宣言は書籍ごとにまちまちなので、要素も属性も局所名で照合する。
//! 抜粋を切り出すために、要素ごとに元の文字列の範囲を覚えておく。
//! 木から書き戻すのではなく元の断片をそのまま使うほうが、
//! 空白や実体参照の書き方を変えずに済む。

use quick_xml::events::Event;
use quick_xml::Reader;

#[derive(Debug, Clone)]
pub enum Child {
    Element(usize),
    Text(String),
}

#[derive(Debug, Clone)]
pub struct Element {
    pub name: String,
    pub attributes: Vec<(String, String)>,
    pub children: Vec<Child>,
    pub parent: Option<usize>,
    /// 元の文字列における、開始タグから終了タグまでのバイト範囲。
    pub span: (usize, usize),
}

#[derive(Debug, Clone)]
pub struct Document {
    elements: Vec<Element>,
    root: Option<usize>,
}

impl Element {
    /// 局所名で属性を引く。接頭辞の有無は問わない。
    pub fn attr(&self, local_name: &str) -> Option<&str> {
        self.attributes
            .iter()
            .find(|(key, _)| local_of(key) == local_name)
            .map(|(_, value)| value.as_str())
    }
}

impl Document {
    pub fn root(&self) -> Option<&Element> {
        self.root.map(|index| &self.elements[index])
    }

    pub fn get(&self, index: usize) -> &Element {
        &self.elements[index]
    }

    /// 文書順のすべての要素。
    pub fn all(&self) -> impl Iterator<Item = (usize, &Element)> {
        self.elements.iter().enumerate()
    }

    pub fn descendants<'a>(
        &'a self,
        index: usize,
        local_name: &'a str,
    ) -> impl Iterator<Item = usize> + 'a {
        // 木は文書順に積んであるので、範囲で絞れば子孫だけが残る。
        let span = self.elements[index].span;
        self.elements
            .iter()
            .enumerate()
            .filter(move |(i, e)| {
                *i != index && e.span.0 >= span.0 && e.span.1 <= span.1 && e.name == local_name
            })
            .map(|(i, _)| i)
    }

    /// 直接の子要素だけ。
    pub fn child_elements(&self, index: usize) -> impl Iterator<Item = usize> + '_ {
        self.elements[index].children.iter().filter_map(|c| match c {
            Child::Element(i) => Some(*i),
            Child::Text(_) => None,
        })
    }

    pub fn first_child_named(&self, index: usize, local_name: &str) -> Option<usize> {
        self.child_elements(index)
            .find(|i| self.elements[*i].name == local_name)
    }

    pub fn first_descendant_named(&self, local_name: &str) -> Option<usize> {
        self.elements
            .iter()
            .position(|e| e.name == local_name)
    }

    /// その要素より後ろにある兄弟要素。
    pub fn following_siblings(&self, index: usize) -> Vec<usize> {
        let Some(parent) = self.elements[index].parent else {
            return Vec::new();
        };
        let siblings: Vec<usize> = self.child_elements(parent).collect();
        match siblings.iter().position(|i| *i == index) {
            Some(position) => siblings[position + 1..].to_vec(),
            None => Vec::new(),
        }
    }

    /// 要素とその子孫のテキストをつないだもの。C# の XElement.Value に当たる。
    pub fn value(&self, index: usize) -> String {
        let mut out = String::new();
        self.collect_text(index, &mut out);
        out
    }

    fn collect_text(&self, index: usize, out: &mut String) {
        for child in &self.elements[index].children {
            match child {
                Child::Text(text) => out.push_str(text),
                Child::Element(i) => self.collect_text(*i, out),
            }
        }
    }
}

fn local_of(name: &str) -> &str {
    match name.rfind(':') {
        Some(index) => &name[index + 1..],
        None => name,
    }
}

/// XML として読む。整形式でなければ `None`。
///
/// 外部実体は読み込まない。書籍が外部を参照しても取りに行かせない。
pub fn parse(source: &str) -> Option<Document> {
    let mut reader = Reader::from_str(source);
    reader.config_mut().check_end_names = true;
    reader.config_mut().trim_text(false);

    let mut elements: Vec<Element> = Vec::new();
    let mut stack: Vec<usize> = Vec::new();
    let mut root: Option<usize> = None;

    loop {
        let start = reader.buffer_position() as usize;
        let event = reader.read_event().ok()?;
        let end = reader.buffer_position() as usize;

        match event {
            Event::Eof => break,

            Event::Start(ref tag) | Event::Empty(ref tag) => {
                let empty = matches!(event, Event::Empty(_));
                let name = String::from_utf8_lossy(tag.name().as_ref()).into_owned();
                let mut attributes = Vec::new();
                for attribute in tag.attributes() {
                    let attribute = attribute.ok()?;
                    let key = String::from_utf8_lossy(attribute.key.as_ref()).into_owned();
                    let value = attribute.unescape_value().ok()?.into_owned();
                    attributes.push((key, value));
                }

                let index = elements.len();
                elements.push(Element {
                    name: local_of(&name).to_string(),
                    attributes,
                    children: Vec::new(),
                    parent: stack.last().copied(),
                    span: (start, end),
                });

                if let Some(&parent) = stack.last() {
                    elements[parent].children.push(Child::Element(index));
                } else if root.is_none() {
                    root = Some(index);
                } else {
                    // 根が 2 つある文書は整形式でない。
                    return None;
                }

                if !empty {
                    stack.push(index);
                }
            }

            Event::End(_) => {
                let index = stack.pop()?;
                elements[index].span.1 = end;
            }

            Event::Text(ref text) => {
                // 宣言されていない実体は解けない。C# の XmlReader も同じ扱いで失敗する。
                let decoded = text.unescape().ok()?.into_owned();
                if let Some(&parent) = stack.last() {
                    elements[parent].children.push(Child::Text(decoded));
                }
            }

            Event::CData(ref data) => {
                let decoded = String::from_utf8_lossy(data.as_ref()).into_owned();
                if let Some(&parent) = stack.last() {
                    elements[parent].children.push(Child::Text(decoded));
                }
            }

            _ => {}
        }
    }

    // 閉じられていない要素が残っていれば整形式でない。
    if !stack.is_empty() || root.is_none() {
        return None;
    }

    Some(Document { elements, root })
}

/// 整形式かどうかだけを見る。
pub fn is_well_formed(source: &str) -> bool {
    parse(source).is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 閉じていない要素を弾く() {
        assert!(!is_well_formed("<a><b></a>"));
        assert!(!is_well_formed("<html><body><p>text</body></html>"));
        assert!(is_well_formed("<a><b/></a>"));
    }

    #[test]
    fn 局所名で属性を引く() {
        let document = parse(r#"<a epub:type="footnote" xmlns:epub="urn:x"/>"#).unwrap();
        assert_eq!(document.root().unwrap().attr("type"), Some("footnote"));
    }

    #[test]
    fn 範囲は元の断片を指す() {
        let source = "<root><p id=\"x\">中身</p></root>";
        let document = parse(source).unwrap();
        let target = document
            .all()
            .find(|(_, e)| e.attr("id") == Some("x"))
            .unwrap()
            .0;
        let (start, end) = document.get(target).span;
        assert_eq!(&source[start..end], "<p id=\"x\">中身</p>");
    }
}
