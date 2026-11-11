use super::{appearance, boolean, colors::Colors, format, unsigned, MAX_STYLES};
use crate::model::{CellStyle, Document};
use crate::xml::Node;
use crate::{Error, Result};
use std::collections::HashMap;

#[derive(Clone)]
pub(super) struct Style {
    pub cell: CellStyle,
    pub format: Option<String>,
}

impl Default for Style {
    fn default() -> Self {
        Self {
            cell: CellStyle::default(),
            format: Some("General".to_owned()),
        }
    }
}

struct Tables {
    fonts: Vec<CellStyle>,
    fills: Vec<u32>,
    borders: Vec<[Option<u32>; 4]>,
    formats: HashMap<u32, String>,
}

pub(super) fn parse(
    root: Option<&Node>,
    theme: Option<&Node>,
    document: &mut Document,
) -> Result<Vec<Style>> {
    let Some(root) = root else {
        return Ok(vec![Style::default()]);
    };
    if root.name != "styleSheet" {
        return Err(Error::Invalid("Invalid XLSX styles part"));
    }
    for name in [
        "fonts",
        "fills",
        "borders",
        "numFmts",
        "cellXfs",
        "cellStyleXfs",
    ] {
        if root
            .child(name)
            .is_some_and(|node| node.children.len() > MAX_STYLES)
        {
            return Err(Error::Limit("XLSX style table exceeds 2048 entries"));
        }
    }
    let colors = Colors::new(
        theme,
        root.child("colors")
            .and_then(|colors| colors.child("indexedColors")),
    )?;
    let mut tables = Tables {
        fonts: Vec::new(),
        fills: Vec::new(),
        borders: Vec::new(),
        formats: HashMap::new(),
    };
    if let Some(nodes) = root.child("fonts") {
        for node in nodes.named("font") {
            tables
                .fonts
                .push(appearance::font(node, &colors, document)?);
        }
    }
    if let Some(nodes) = root.child("fills") {
        for node in nodes.named("fill") {
            tables
                .fills
                .push(appearance::fill(node, &colors, document)?);
        }
    }
    if let Some(nodes) = root.child("borders") {
        for node in nodes.named("border") {
            tables
                .borders
                .push(appearance::border(node, &colors, document)?);
        }
    }
    if let Some(nodes) = root.child("numFmts") {
        for node in nodes.named("numFmt") {
            let id = unsigned(node.attr("numFmtId"))?;
            if node.attr("formatCode").is_empty()
                || tables
                    .formats
                    .insert(id, node.attr("formatCode").to_owned())
                    .is_some()
            {
                return Err(Error::Invalid("Missing or duplicate XLSX number format"));
            }
        }
    }
    if tables.fonts.is_empty() {
        tables.fonts.push(CellStyle::default());
    }
    if tables.fills.is_empty() {
        tables.fills.push(0);
    }
    if tables.borders.is_empty() {
        tables.borders.push([None; 4]);
    }
    let mut bases = Vec::new();
    if let Some(nodes) = root.child("cellStyleXfs") {
        for node in nodes.named("xf") {
            bases.push(tables.xf(node, &Style::default(), document)?);
        }
    }
    if bases.is_empty() {
        bases.push(Style::default());
    }
    let mut result = Vec::new();
    if let Some(nodes) = root.child("cellXfs") {
        for node in nodes.named("xf") {
            let base = lookup(&bases, node.attr("xfId"))?;
            result.push(tables.xf(node, base, document)?);
        }
    }
    if result.is_empty() {
        result.push(Style::default());
    }
    Ok(result)
}

impl Tables {
    fn xf(&self, node: &Node, base: &Style, document: &mut Document) -> Result<Style> {
        let mut style = base.clone();
        let font = lookup(&self.fonts, node.attr("fontId"))?;
        let fill = *lookup(&self.fills, node.attr("fillId"))?;
        let borders = *lookup(&self.borders, node.attr("borderId"))?;
        if !node.attr("fontId").is_empty() && boolean(node.attr("applyFont"), true)? {
            style.cell.font_size = font.font_size;
            style.cell.bold = font.bold;
            style.cell.italic = font.italic;
            style.cell.underline = font.underline;
            style.cell.color = font.color;
            style.cell.font_face = font.font_face.clone();
            style.cell.strike = font.strike;
            style.cell.vert_align = font.vert_align;
        }
        if !node.attr("fillId").is_empty() && boolean(node.attr("applyFill"), true)? {
            style.cell.fill = fill;
        }
        if !node.attr("borderId").is_empty() && boolean(node.attr("applyBorder"), true)? {
            style.cell.borders = borders;
        }
        if !node.attr("numFmtId").is_empty() {
            let id = unsigned(node.attr("numFmtId"))?;
            if boolean(node.attr("applyNumberFormat"), true)? {
                style.format = self
                    .formats
                    .get(&id)
                    .cloned()
                    .or_else(|| format::builtin(id).map(str::to_owned));
            }
        }
        if let Some(alignment) = node.child("alignment") {
            if boolean(node.attr("applyAlignment"), true)? {
                appearance::alignment(&mut style.cell, alignment, document)?;
            }
        }
        Ok(style)
    }
}

fn lookup<'a, T>(items: &'a [T], value: &str) -> Result<&'a T> {
    let index = if value.is_empty() {
        0
    } else {
        unsigned(value)?
    };
    let index = usize::try_from(index)
        .map_err(|_| Error::Invalid("Invalid XLSX style component reference"))?;
    items
        .get(index)
        .ok_or(Error::Invalid("Invalid XLSX style component reference"))
}
