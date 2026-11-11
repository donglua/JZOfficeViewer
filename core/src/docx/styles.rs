use super::format::{self, Font, ParagraphFormat};
use crate::model::{Document, LineSpacingRule};
use crate::xml::Node;
use crate::{Error, Package, Result};
use std::collections::{HashMap, HashSet};

const MAX_STYLES: usize = 1024;
const MAX_STYLE_DEPTH: usize = 64;

#[derive(Default)]
pub(super) struct Styles {
    entries: HashMap<String, Node>,
    font: Font,
    paragraph: ParagraphFormat,
    default_paragraph: String,
    pub default_character: String,
    pub theme_fonts: super::theme::ThemeFonts,
    pub line_pitch: f32,
}

impl Styles {
    pub fn load(package: &mut Package, main: &str, document: &mut Document) -> Result<Self> {
        let part = package.related_by_type(main, "styles")?.unwrap_or_else(|| {
            main.rsplit_once('/').map_or_else(
                || "styles.xml".to_owned(),
                |(dir, _)| format!("{dir}/styles.xml"),
            )
        });
        let mut result = Self::default();
        let theme_part = package.related_by_type(main, "theme")?;
        let theme_root = if let Some(path) = theme_part {
            package.optional_xml(&path)?
        } else {
            None
        };
        result.theme_fonts = super::theme::ThemeFonts::parse(theme_root.as_ref());
        let Some(root) = package.optional_xml(&part)? else {
            return Ok(result);
        };
        super::inspect(&root, document);
        if let Some(defaults) = root.child("docDefaults") {
            format::font(
                &mut result.font,
                defaults.child("rPrDefault").and_then(|n| n.child("rPr")),
                Some(&result.theme_fonts),
            )?;
            result.paragraph.apply(
                defaults.child("pPrDefault").and_then(|n| n.child("pPr")),
                result.font.run.size,
            );
        }
        let mut count = 0;
        for node in root.children {
            if node.name != "style" {
                continue;
            }
            count += 1;
            if count > MAX_STYLES {
                return Err(Error::Limit("DOCX exceeds 1024 styles"));
            }
            let id = node.attr("styleId");
            if id.len() > 256
                || node
                    .child("basedOn")
                    .is_some_and(|n| n.attr("val").len() > 256)
            {
                return Err(Error::Limit("DOCX style identifier exceeds 256 bytes"));
            }
            if id.is_empty() {
                continue;
            }
            if !node.attr("default").is_empty() && format::enabled(node.attr("default")) {
                match node.attr("type") {
                    "paragraph" => result.default_paragraph = id.to_owned(),
                    "character" => result.default_character = id.to_owned(),
                    _ => (),
                }
            }
            result.entries.insert(id.to_owned(), node);
        }
        Ok(result)
    }

    pub fn chain<'a>(&'a self, mut id: &'a str, document: &mut Document) -> Vec<&'a Node> {
        let mut chain = Vec::new();
        let mut seen = HashSet::new();
        while !id.is_empty() {
            if chain.len() >= MAX_STYLE_DEPTH || !seen.insert(id) {
                document.warn("Cyclic or excessive style inheritance was stopped.");
                break;
            }
            let Some(style) = self.entries.get(id) else {
                document.warn("Missing styles use inherited or default formatting.");
                break;
            };
            chain.push(style);
            id = style.child("basedOn").map_or("", |node| node.attr("val"));
        }
        chain
    }

    pub fn paragraph(
        &self,
        node: &Node,
        numbering: &mut super::numbering::Numbering,
        document: &mut Document,
    ) -> Result<(ParagraphFormat, Font)> {
        let mut format = self.paragraph.clone();
        let mut font = self.font.clone();
        let properties = node.child("pPr");
        let id = properties
            .and_then(|n| n.child("pStyle"))
            .map_or(self.default_paragraph.as_str(), |n| n.attr("val"));
        format.style_id = id.to_owned();
        let chain = self.chain(id, document);
        let outline = properties.and_then(|n| n.child("outlineLvl")).or_else(|| {
            chain
                .iter()
                .find_map(|style| style.child("pPr").and_then(|p| p.child("outlineLvl")))
        });
        let level = match outline {
            Some(outline) => outline
                .attr("val")
                .parse::<u8>()
                .ok()
                .filter(|n| *n < 9)
                .map(|n| n + 1),
            None => heading(id).or_else(|| {
                chain.iter().find_map(|style| {
                    heading(style.attr("styleId"))
                        .or_else(|| style.child("name").and_then(|n| heading(n.attr("val"))))
                })
            }),
        };
        if let Some(level) = level {
            font.run.size = match level {
                1 => 24.0,
                2 => 20.0,
                3 => 16.0,
                4 => 14.0,
                5 => 13.0,
                _ => 12.0,
            };
            font.run.bold = true;
            format.paragraph.before = 12.0;
        }
        for style in chain.iter().rev() {
            format::font(&mut font, style.child("rPr"), Some(&self.theme_fonts))?;
            format.apply(style.child("pPr"), font.run.size);
        }
        format.apply(properties, font.run.size);
        if !format.number.is_empty() && format.number != "0" {
            format.paragraph.bullet = numbering.bullet(&format.number, format.level);
            if !format.has_indent {
                format.paragraph.indent = 18.0 * (f32::from(format.level) + 1.0);
            }
        }
        if format.snap_to_grid
            && self.line_pitch > 0.0
            && format.paragraph.line_spacing_rule == LineSpacingRule::Auto
            && (format.paragraph.line_spacing - 1.0).abs() < 0.01
        {
            let font_size = if font.run.size > 0.0 && font.run.size.is_finite() {
                font.run.size
            } else {
                12.0
            };
            let natural = font_size * 1.2;
            if natural < self.line_pitch {
                format.paragraph.line_spacing = (self.line_pitch / natural).clamp(1.0, 1.8);
            }
        }
        Ok((format, font))
    }
}

fn heading(name: &str) -> Option<u8> {
    if name.len() > 256 {
        return None;
    }
    let normalized = name.replace(' ', "").to_ascii_lowercase();
    normalized
        .strip_prefix("heading")?
        .parse::<u8>()
        .ok()
        .filter(|level| (1..=9).contains(level))
}
