use crate::{Error, Result};
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub(crate) struct Node {
    pub name: String,
    pub attrs: HashMap<String, String>,
    pub children: Vec<Node>,
    pub text: String,
}

impl Node {
    pub fn attr(&self, name: &str) -> &str {
        self.attrs.get(name).map_or("", String::as_str)
    }
    pub fn child(&self, name: &str) -> Option<&Self> {
        self.children.iter().find(|n| n.name == name)
    }
    pub fn named<'a>(&'a self, name: &'a str) -> impl Iterator<Item = &'a Self> {
        self.children.iter().filter(move |n| n.name == name)
    }
    pub fn descendant(&self, name: &str) -> Option<&Self> {
        if self.name == name {
            return Some(self);
        }
        self.children.iter().find_map(|n| n.descendant(name))
    }
}

pub(crate) fn parse(bytes: Vec<u8>) -> Result<Node> {
    let text = if bytes.starts_with(&[0xff, 0xfe]) || bytes.starts_with(&[0xfe, 0xff]) {
        if bytes.len() % 2 != 0 {
            return Err(Error::Invalid("Truncated UTF-16 XML"));
        }
        let little = bytes.starts_with(&[0xff, 0xfe]);
        let units: Vec<u16> = bytes[2..]
            .chunks_exact(2)
            .map(|v| {
                if little {
                    u16::from_le_bytes([v[0], v[1]])
                } else {
                    u16::from_be_bytes([v[0], v[1]])
                }
            })
            .collect();
        String::from_utf16(&units).map_err(|_| Error::Invalid("Invalid UTF-16 XML"))?
    } else {
        String::from_utf8(bytes).map_err(|_| Error::Invalid("Invalid UTF-8 XML"))?
    };
    let options = roxmltree::ParsingOptions {
        allow_dtd: false,
        nodes_limit: 60_000,
    };
    let doc = roxmltree::Document::parse_with_options(&text, options)?;
    owned(doc.root_element(), 0)
}

fn owned(node: roxmltree::Node<'_, '_>, depth: usize) -> Result<Node> {
    if depth >= 64 {
        return Err(Error::Limit("XML nesting exceeds 64 levels"));
    }
    let mut attrs = HashMap::new();
    for attr in node.attributes() {
        attrs.insert(attr.name().to_owned(), attr.value().to_owned());
        if attr
            .namespace()
            .is_some_and(|ns| ns.ends_with("/relationships"))
        {
            attrs.insert(format!("r:{}", attr.name()), attr.value().to_owned());
        }
    }
    let mut children = Vec::new();
    let mut text = String::new();
    for child in node.children() {
        if child.is_element() {
            children.push(owned(child, depth + 1)?);
        } else if child.is_text() {
            text.push_str(child.text().unwrap_or_default());
        }
    }
    Ok(Node {
        name: node.tag_name().name().to_owned(),
        attrs,
        children,
        text,
    })
}

pub(crate) fn number(value: &str, fallback: f32) -> f32 {
    value
        .parse::<f32>()
        .ok()
        .filter(|n| n.is_finite())
        .unwrap_or(fallback)
}

pub(crate) fn color(value: &str, fallback: u32) -> u32 {
    if value.len() == 6 {
        u32::from_str_radix(value, 16)
            .map(|v| 0xff000000 | v)
            .unwrap_or(fallback)
    } else {
        fallback
    }
}
