//! DOCX 页眉页脚解析：从 sectPr 的 headerReference/footerReference 关联的部件中提取内容块。
//! header/footer XML 根元素为 w:hdr / w:ftr，内部结构（w:p、w:tbl）与正文一致，复用 body 解析逻辑。

use super::Parser;
use crate::xml::{self, Node};
use crate::{Error, Result};

/// 页眉/页脚类型
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum SectionKind {
    Header,
    Footer,
}

/// 从 sectPr 中解析 headerReference / footerReference，返回 (类型, 关系 ID, 引用类型) 列表
pub(super) fn references(sect: &Node) -> Vec<(SectionKind, String, String)> {
    let mut result = Vec::new();
    for child in &sect.children {
        match child.name.as_str() {
            "headerReference" => {
                result.push((
                    SectionKind::Header,
                    child.attr("r:id").to_owned(),
                    child.attr("type").to_owned(),
                ));
            }
            "footerReference" => {
                result.push((
                    SectionKind::Footer,
                    child.attr("r:id").to_owned(),
                    child.attr("type").to_owned(),
                ));
            }
            _ => {}
        }
    }
    result
}

/// 按文档顺序收集 body 下所有节属性（段落级 w:p/w:pPr/w:sectPr 与 body 末尾的 w:sectPr）。
/// 多节文档的页眉页脚引用按节继承，需要完整的节序列才能解析。
pub(super) fn properties(body: &Node) -> Vec<&Node> {
    let mut sections = Vec::new();
    collect(body, &mut sections);
    sections
}

fn collect<'a>(node: &'a Node, sections: &mut Vec<&'a Node>) {
    for child in &node.children {
        if child.name == "sectPr" {
            sections.push(child);
        } else {
            collect(child, sections);
        }
    }
}

/// 页边距与页眉页脚距离（单位：点）
pub(super) struct PageMargins {
    pub header: f32,
    pub footer: f32,
    pub top: f32,
    pub bottom: f32,
    pub left: f32,
    pub right: f32,
}

/// 解析 sectPr/pgMar 页边距与页眉页脚距离（单位：点，twips / 20），并限制在合理范围内
pub(super) fn page_margins(sect: &Node, page_width: f32) -> PageMargins {
    let pg_mar = sect.child("pgMar");
    let attr = |name: &str, fallback: f32| -> f32 {
        pg_mar
            .map(|n| xml::number(n.attr(name), fallback * 20.0) / 20.0)
            .unwrap_or(fallback)
    };
    let max_horizontal = ((page_width - 120.0) / 2.0).max(36.0);
    PageMargins {
        header: attr("header", 36.0).clamp(0.0, 288.0), // 默认 720 twips = 36pt
        footer: attr("footer", 36.0).clamp(0.0, 288.0), // 默认 720 twips = 36pt
        top: attr("top", 72.0).clamp(0.0, 288.0),       // 默认 1440 twips = 72pt
        bottom: attr("bottom", 72.0).clamp(0.0, 288.0),
        left: attr("left", 72.0).clamp(0.0, max_horizontal),
        right: attr("right", 72.0).clamp(0.0, max_horizontal),
    }
}

/// 解析 sectPr/docGrid linePitch（单位：点，twips / 20）
pub(super) fn line_pitch(sect: &Node) -> f32 {
    sect.child("docGrid")
        .map(|grid| xml::number(grid.attr("linePitch"), 0.0) / 20.0)
        .unwrap_or(0.0)
}

impl Parser<'_> {
    /// 解析 header/footer 部件，返回内容块列表。复用 body 解析逻辑，但输出到临时 blocks。
    pub(super) fn section_blocks(&mut self, part: &str) -> Result<Vec<crate::model::Element>> {
        let root = self.package.xml(part)?;
        let root_name = root.name.as_str();
        if root_name != "hdr" && root_name != "ftr" {
            return Err(Error::Invalid("Invalid header/footer root element"));
        }
        // 页眉页脚同样可能出现公式、浮动图形等不支持元素，需要一并记录告警
        super::inspect(&root, &mut self.document);
        // 页眉页脚部件拥有独立的 word/_rels/header1.xml.rels，其中的图片等资源关系与正文不同源，
        // 解析期间必须临时切换到该部件的关系表，否则 r:embed 会错误命中正文关系。
        let relationships = self.package.relationships(part)?;
        let saved_relationships = std::mem::replace(&mut self.relationships, relationships);
        // 页眉页脚使用更小的块数量上限，保证 core 不会输出平台层解码会拒绝的模型
        let saved_limit = std::mem::replace(&mut self.block_limit, super::SECTION_LIMIT);
        let saved_style_id = self.last_style_id.take();
        let saved_contextual = std::mem::replace(&mut self.last_contextual, false);
        // 临时交换 blocks，让 body() 把解析结果写入临时 Vec；text_bytes 在 body() 内正常累计
        let saved = std::mem::take(&mut self.document.blocks);
        let result = self.body(&root);
        let blocks = std::mem::replace(&mut self.document.blocks, saved);
        self.last_style_id = saved_style_id;
        self.last_contextual = saved_contextual;
        self.block_limit = saved_limit;
        self.relationships = saved_relationships;
        result?;
        Ok(blocks)
    }
}
