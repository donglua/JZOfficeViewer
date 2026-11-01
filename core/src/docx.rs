mod drawings;
mod format;
mod paragraphs;
mod section;
mod styles;
mod tables;

use crate::model::{Document, Element, Kind};
use crate::xml::{self, Node};
use crate::{Error, Package, Result};
use std::collections::HashMap;
use styles::Styles;

const MAX_BLOCKS: usize = 5000;
/// 单个页眉/页脚部件的块数量上限，必须与 Android DocumentDecoder 的校验保持一致，
/// 否则 core 解析成功但平台层解码会直接抛异常。
const MAX_SECTION_BLOCKS: usize = 500;
const MAX_CELLS: usize = 5000;
const MAX_COLUMNS: usize = 32;
const MAX_ROWS: usize = 500;
const MAX_COORDINATE: f32 = 1200.0;
pub(super) const MAX_TEXT: usize = 8 * 1024 * 1024;

/// 当前解析目标的块数量上限及其超限提示
#[derive(Clone, Copy)]
struct BlockLimit {
    count: usize,
    message: &'static str,
}

const FLOW_LIMIT: BlockLimit = BlockLimit {
    count: MAX_BLOCKS,
    message: "DOCX exceeds 5000 flow blocks",
};
const SECTION_LIMIT: BlockLimit = BlockLimit {
    count: MAX_SECTION_BLOCKS,
    message: "DOCX header/footer exceeds 500 blocks",
};

pub(crate) fn parse(package: &mut Package, main_part: &str) -> Result<Document> {
    let root = package.xml(main_part)?;
    if root.name != "document" {
        return Err(Error::Invalid("Invalid DOCX document root"));
    }
    let body = root
        .child("body")
        .ok_or(Error::Invalid("Missing DOCX body"))?;
    let mut document = Document::new(Kind::DOCX);
    let sect = body.child("sectPr").or_else(|| body.descendant("sectPr"));
    if let Some(sect) = sect {
        if let Some(size) = sect.child("pgSz") {
            document.width =
                (xml::number(size.attr("w"), 11900.0) / 20.0).clamp(300.0, MAX_COORDINATE);
        }
        let (header_dist, footer_dist, m_top, m_bottom, m_left, m_right, _gutter) =
            section::page_margins(sect);
        document.header_distance = header_dist;
        document.footer_distance = footer_dist;
        document.margin_top = m_top;
        document.margin_bottom = m_bottom;
        document.margin_left = m_left;
        document.margin_right = m_right;
    } else if let Some(size) = body.descendant("sectPr").and_then(|s| s.child("pgSz")) {
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
        block_limit: FLOW_LIMIT,
    };
    parser.body(body)?;
    // 解析页眉页脚（在正文之后，避免影响正文的 blocks 计数）
    if let Some(sect) = sect {
        parser.parse_sections(sect)?;
    }
    Ok(parser.document)
}

struct Parser<'a> {
    package: &'a mut Package,
    document: Document,
    relationships: HashMap<String, String>,
    styles: Styles,
    cells: usize,
    text_bytes: usize,
    block_limit: BlockLimit,
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
        if self.document.blocks.len() >= self.block_limit.count {
            return Err(Error::Limit(self.block_limit.message));
        }
        self.document.blocks.push(element);
        Ok(())
    }

    /// 解析 sectPr 中的页眉页脚引用，把内容块写入 document.header_blocks / footer_blocks
    fn parse_sections(&mut self, sect: &Node) -> Result<()> {
        let refs = section::references(sect);
        let mut header_part: Option<String> = None;
        let mut footer_part: Option<String> = None;
        for (kind, rel_id, ref_type) in &refs {
            let Some(target) = self.relationships.get(rel_id) else {
                continue;
            };
            // 优先选择 default 类型；没有 default 时取第一个
            match kind {
                section::SectionKind::Header => {
                    if header_part.is_none() || ref_type == "default" {
                        header_part = Some(target.clone());
                    }
                }
                section::SectionKind::Footer => {
                    if footer_part.is_none() || ref_type == "default" {
                        footer_part = Some(target.clone());
                    }
                }
            }
        }
        if let Some(part) = header_part {
            if self.package.has(&part) {
                let blocks = self.section_blocks(&part)?;
                if !blocks.is_empty() {
                    self.document.header_blocks = blocks;
                }
            }
        }
        if let Some(part) = footer_part {
            if self.package.has(&part) {
                let blocks = self.section_blocks(&part)?;
                if !blocks.is_empty() {
                    self.document.footer_blocks = blocks;
                }
            }
        }
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
        "headerReference" | "footerReference" => None, // 已支持页眉页脚
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
