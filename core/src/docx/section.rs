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

/// 解析 sectPr/pgMar 页边距与页眉页脚距离（单位：点，twips / 20）
pub(super) fn page_margins(sect: &Node) -> (f32, f32, f32, f32, f32, f32, f32) {
    let pg_mar = sect.child("pgMar");
    let attr = |name: &str, fallback: f32| -> f32 {
        pg_mar
            .map(|n| xml::number(n.attr(name), fallback * 20.0) / 20.0)
            .unwrap_or(fallback)
    };
    (
        attr("header", 36.0), // header_distance 默认 720 twips = 36pt
        attr("footer", 36.0), // footer_distance 默认 720 twips = 36pt
        attr("top", 72.0),    // margin_top 默认 1440 twips = 72pt
        attr("bottom", 72.0),
        attr("left", 72.0),
        attr("right", 72.0),
        0.0, // gutter 不使用
    )
}

impl Parser<'_> {
    /// 解析 header/footer 部件，返回内容块列表。复用 body 解析逻辑，但输出到临时 blocks。
    pub(super) fn section_blocks(&mut self, part: &str) -> Result<Vec<crate::model::Element>> {
        let root = self.package.xml(part)?;
        let root_name = root.name.as_str();
        if root_name != "hdr" && root_name != "ftr" {
            return Err(Error::Invalid("Invalid header/footer root element"));
        }
        // 页眉页脚部件拥有独立的 word/_rels/header1.xml.rels，其中的图片等资源关系与正文不同源，
        // 解析期间必须临时切换到该部件的关系表，否则 r:embed 会错误命中正文关系。
        let relationships = self.package.relationships(part)?;
        let saved_relationships = std::mem::replace(&mut self.relationships, relationships);
        // 页眉页脚使用更小的块数量上限，保证 core 不会输出平台层解码会拒绝的模型
        let saved_limit = std::mem::replace(&mut self.block_limit, super::SECTION_LIMIT);
        // 临时交换 blocks，让 body() 把解析结果写入临时 Vec；text_bytes 在 body() 内正常累计
        let saved = std::mem::take(&mut self.document.blocks);
        let result = self.body(&root);
        let blocks = std::mem::replace(&mut self.document.blocks, saved);
        self.block_limit = saved_limit;
        self.relationships = saved_relationships;
        result?;
        Ok(blocks)
    }
}
