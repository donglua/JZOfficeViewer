mod drawings;
mod format;
pub(super) mod numbering;
mod paragraphs;
mod section;
mod styles;
mod tables;
pub(super) mod theme;

use crate::model::{Document, Element, Kind};
use crate::xml::{self, Node};
use crate::{Error, Package, Result};
use numbering::Numbering;
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
/// Word 默认页边距（点），用于未声明 sectPr/pgMar 的文档
const DEFAULT_MARGIN: f32 = 72.0;
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
    let sections = section::properties(body);
    if let Some(&sect) = sections.last() {
        if let Some(size) = sections.iter().rev().find_map(|s| s.child("pgSz")) {
            document.width =
                (xml::number(size.attr("w"), 11900.0) / 20.0).clamp(300.0, MAX_COORDINATE);
        }
        let margins_sect = sections
            .iter()
            .rev()
            .find(|s| s.child("pgMar").is_some())
            .copied()
            .unwrap_or(sect);
        let margins = section::page_margins(margins_sect, document.width);
        document.header_distance = margins.header;
        document.footer_distance = margins.footer;
        document.margin_top = margins.top;
        document.margin_bottom = margins.bottom;
        document.margin_left = margins.left;
        document.margin_right = margins.right;
    }
    inspect(body, &mut document);
    let relationships = package.relationships(main_part)?;
    let mut styles = Styles::load(package, main_part, &mut document)?;
    let line_pitch = sections
        .iter()
        .rev()
        .map(|s| section::line_pitch(s))
        .find(|&p| p > 0.0)
        .unwrap_or(0.0);
    styles.line_pitch = line_pitch;
    let numbering_part = package.related_by_type(main_part, "numbering")?;
    let numbering_root = if let Some(path) = numbering_part {
        package.optional_xml(&path)?
    } else {
        None
    };
    let numbering = Numbering::parse(numbering_root.as_ref());
    let mut parser = Parser {
        package,
        document,
        relationships,
        styles,
        numbering,
        cells: 0,
        text_bytes: 0,
        block_limit: FLOW_LIMIT,
        last_style_id: None,
        last_contextual: false,
    };
    parser.body(body)?;
    // 解析页眉页脚（在正文之后，避免影响正文的 blocks 计数）。
    // 多节文档中页眉页脚引用按节继承，使用按文档顺序收集的全部 sectPr。
    if !sections.is_empty() {
        parser.parse_sections(&sections)?;
    }
    Ok(parser.document)
}

struct Parser<'a> {
    package: &'a mut Package,
    document: Document,
    relationships: HashMap<String, String>,
    styles: Styles,
    pub(super) numbering: Numbering,
    cells: usize,
    text_bytes: usize,
    block_limit: BlockLimit,
    pub(super) last_style_id: Option<String>,
    pub(super) last_contextual: bool,
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
                    self.last_style_id = None;
                    self.last_contextual = false;
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

    /// 流式正文的可用宽度：扣除左右页边距。未从 sectPr 读到边距时按 Word 默认 72pt 回退，
    /// 与 Android OfficeRenderer 计算 contentWidth 的方式保持一致。
    fn flow_width(&self) -> f32 {
        let margin = |value: f32| {
            if value > 0.0 {
                value
            } else {
                DEFAULT_MARGIN
            }
        };
        (self.document.width
            - margin(self.document.margin_left)
            - margin(self.document.margin_right))
        .max(1.0)
    }

    /// 解析各节的页眉页脚引用，把内容块写入 document.header_blocks / footer_blocks。
    /// 多节文档中，后一节未重复声明引用时按 OOXML 规则继承前一节的页眉页脚，
    /// 因此从最后一节向前查找最近一个声明了该类型引用的节。
    fn parse_sections(&mut self, sections: &[&Node]) -> Result<()> {
        if let Some(part) = self.section_part(sections, section::SectionKind::Header) {
            if self.package.has(&part) {
                let blocks = self.section_blocks(&part)?;
                if !blocks.is_empty() {
                    self.document.header_blocks = blocks;
                }
            }
        }
        if let Some(part) = self.section_part(sections, section::SectionKind::Footer) {
            if self.package.has(&part) {
                let blocks = self.section_blocks(&part)?;
                if !blocks.is_empty() {
                    self.document.footer_blocks = blocks;
                }
            }
        }
        Ok(())
    }

    /// 取指定类型页眉/页脚对应部件路径：从最后一节向前，第一个声明了该类型且关系可解析的节生效
    fn section_part(&self, sections: &[&Node], kind: section::SectionKind) -> Option<String> {
        for sect in sections.iter().rev() {
            let mut chosen: Option<(String, String)> = None;
            for (reference_kind, rel_id, ref_type) in section::references(sect) {
                if reference_kind != kind {
                    continue;
                }
                // 优先选择 default 类型；没有 default 时取第一个
                if chosen
                    .as_ref()
                    .is_none_or(|(_, chosen_type)| chosen_type != "default")
                {
                    chosen = Some((rel_id, ref_type));
                }
            }
            if let Some((rel_id, _)) = chosen {
                if let Some(target) = self.relationships.get(&rel_id) {
                    return Some(target.clone());
                }
            }
        }
        None
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
        "vertAlign" | "strike" | "dstrike" | "vanish" => {
            Some("Some advanced run formatting is not reproduced.")
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
