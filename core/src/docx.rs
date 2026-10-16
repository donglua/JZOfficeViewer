mod drawings;
mod format;
mod paragraphs;
mod styles;
mod tables;

use crate::model::{Document, Element, Kind};
use crate::xml::{self, Node};
use crate::{Error, Package, Result};
use std::collections::HashMap;
use styles::Styles;

const MAX_BLOCKS: usize = 5000;
const MAX_CELLS: usize = 5000;
const MAX_COLUMNS: usize = 32;
const MAX_ROWS: usize = 500;
const MAX_COORDINATE: f32 = 1200.0;
pub(super) const MAX_TEXT: usize = 8 * 1024 * 1024;

pub(crate) fn parse(package: &mut Package, main_part: &str) -> Result<Document> {
    let root = package.xml(main_part)?;
    if root.name != "document" {
        return Err(Error::Invalid("Invalid DOCX document root"));
    }
    let body = root
        .child("body")
        .ok_or(Error::Invalid("Missing DOCX body"))?;
    let mut document = Document::new(Kind::DOCX);
    if let Some(size) = body
        .child("sectPr")
        .or_else(|| body.descendant("sectPr"))
        .and_then(|section| section.child("pgSz"))
    {
        document.width = (xml::number(size.attr("w"), 11900.0) / 20.0).clamp(300.0, MAX_COORDINATE);
    }
    inspect(body, &mut document);
    let relationships = package.relationships(main_part)?;
    let styles = Styles::load(package, main_part, &mut document)?;
    let mut parser = Parser {
        package,
        document,
        relationships,
        styles,
        cells: 0,
        text_bytes: 0,
    };
    parser.body(body)?;
    Ok(parser.document)
}

struct Parser<'a> {
    package: &'a mut Package,
    document: Document,
    relationships: HashMap<String, String>,
    styles: Styles,
    cells: usize,
    text_bytes: usize,
}

impl Parser<'_> {
    fn body(&mut self, parent: &Node) -> Result<()> {
        for node in &parent.children {
            match node.name.as_str() {
                "p" => {
                    for block in self.paragraph(node, false)? {
                        self.push(block)?;
                    }
                }
                "tbl" => {
                    let table = self.table(node)?;
                    self.push(table)?;
                }
                "sdt" => {
                    if let Some(content) = node.child("sdtContent") {
                        self.body(content)?;
                    }
                }
                "AlternateContent" => {
                    if let Some(content) = alternate(node) {
                        self.body(content)?;
                    }
                }
                name if skipped(name) => (),
                _ => self.body(node)?,
            }
        }
        Ok(())
    }

    fn push(&mut self, element: Element) -> Result<()> {
        if self.document.blocks.len() >= MAX_BLOCKS {
            return Err(Error::Limit("DOCX exceeds 5000 flow blocks"));
        }
        self.document.blocks.push(element);
        Ok(())
    }
}

fn alternate(node: &Node) -> Option<&Node> {
    node.child("Choice").or_else(|| node.child("Fallback"))
}

fn skipped(name: &str) -> bool {
    matches!(
        name,
        "pPr"
            | "rPr"
            | "sectPr"
            | "tblPr"
            | "tblGrid"
            | "trPr"
            | "tcPr"
            | "sdtPr"
            | "sdtEndPr"
            | "customXmlPr"
            | "del"
            | "moveFrom"
            | "instrText"
            | "oMath"
            | "oMathPara"
            | "pict"
            | "object"
            | "txbxContent"
            | "altChunk"
            | "rt"
            | "rp"
    )
}

fn inspect(node: &Node, document: &mut Document) {
    let warning = match node.name.as_str() {
        "headerReference" | "footerReference" => Some("Headers and footers are omitted."),
        "footnoteReference" | "endnoteReference" => Some("Footnotes and endnotes are omitted."),
        "oMath" | "oMathPara" => Some("Mathematical equations are omitted."),
        "anchor" => Some("Floating drawings use document flow; anchors and wrapping are ignored."),
        "vMerge" | "hMerge" | "gridBefore" | "gridAfter" => {
            Some("Merged or irregular table cells use an unmerged rectangular approximation.")
        }
        "gridSpan" if xml::number(node.attr("val"), 1.0) > 1.0 => {
            Some("Merged or irregular table cells use an unmerged rectangular approximation.")
        }
        "pict" | "object" | "txbxContent" => {
            Some("Legacy drawings, embedded objects and text boxes are omitted.")
        }
        "altChunk" => Some("Embedded document content is omitted."),
        "ins" | "del" | "moveFrom" | "moveTo" => {
            Some("Tracked changes show inserted content and omit deleted content.")
        }
        "fldSimple" | "fldChar" => Some("Fields display saved results and are not recalculated."),
        "AlternateContent" => Some(
            "Alternate content uses one saved representation; unsupported features may be lost.",
        ),
        "cols" if xml::number(node.attr("num"), 1.0) > 1.0 => {
            Some("Multiple columns are rendered in a single continuous flow.")
        }
        "color" if !node.attr("themeColor").is_empty() => {
            Some("Theme colors use saved colors or inherited fallbacks.")
        }
        "vertAlign" | "strike" | "dstrike" | "highlight" | "vanish" => {
            Some("Some advanced run formatting is not reproduced.")
        }
        "jc" if matches!(node.attr("val"), "both" | "distribute") => {
            Some("Justified paragraphs are left aligned.")
        }
        "spacing"
            if ["beforeLines", "afterLines"]
                .iter()
                .any(|key| !node.attr(key).is_empty()) =>
        {
            Some("Line-count paragraph spacing uses the viewer's default spacing.")
        }
        "ind"
            if [
                "leftChars",
                "rightChars",
                "startChars",
                "endChars",
                "firstLineChars",
                "hangingChars",
            ]
            .iter()
            .any(|key| !node.attr(key).is_empty()) =>
        {
            Some("Character-unit paragraph indents use inherited point indents.")
        }
        "pageBreakBefore" if format::enabled(node.attr("val")) => {
            Some("Paragraph page breaks are ignored in continuous flow.")
        }
        "srcRect" | "effectLst" => Some("Image cropping and drawing effects are not reproduced."),
        "tblStyle" => Some("Table styles use the viewer's default cell appearance."),
        _ => None,
    };
    if let Some(message) = warning {
        document.warn(message);
    }
    for child in &node.children {
        inspect(child, document);
    }
}
