//! 轻量元数据速读：只读取判定格式与页数所需的部件，跳过正文内容构建。
//!
//! 文档列表、批量封面与冷启动首开通常只需要格式、页数/幻灯片数/Sheet 数、尺寸与告警。
//! 完整解析（样式链、几何预计算、文本与表格）对这些场景是纯开销，因此本模块沿 ZIP 中央
//! 目录直接读取 `_rels/.rels` 与主部件，只取 `sldIdLst` / `sldSz` / `sheets` 等少量节点。
//!
//! 输出是独立的紧凑协议，刻意不与渲染模型 `Document` 同形：元数据不含任何可绘制内容，
//! 复用渲染模型只会让平台层解码器去校验并不存在的行列与样式。平台层的元数据映射
//! （`OfficeMetadata` / `OfficeMetadataInfo` / macOS `OfficeMetadata`）按本协议读取。

use crate::model::Kind;
use crate::xml::Node;
use crate::{Error, Package, Result};
use serde::Serialize;

/// 单次元数据速读允许读取的最大部件数，超出视为异常包并拒绝
const MAX_METADATA_PARTS: usize = 8;
/// 单个元数据部件的解压上限，与主解析的 XML 部件上限一致
const METADATA_PART_LIMIT: u64 = 4 * 1024 * 1024;

/// 跨平台元数据 JSON 协议（字段采用 camelCase）
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Metadata {
    pub schema_version: u32,
    pub kind: Kind,
    /// 页数：DOCX 恒为 1（流式排版），PPTX 为幻灯片数，XLSX 为可见工作表数
    pub page_count: u32,
    /// 页面宽度（点）
    pub width: f32,
    /// 页面高度（点）；DOCX 与 XLSX 无固定页高，返回 0
    pub height: f32,
    /// 可见工作表名称，非 XLSX 时为空
    pub sheet_names: Vec<String>,
    /// 速读过程中可确定的告警，语义与完整解析保持一致
    pub warnings: Vec<String>,
}

/// 从文档包速读元数据，只访问判定格式与页数所需的部件
pub(crate) fn read(package: &mut Package) -> Result<Metadata> {
    let main_part = package
        .related_by_type("", "officeDocument")?
        .ok_or(Error::Invalid(
            "Only DOCX, PPTX and XLSX packages are supported",
        ))?;
    let mut budget = PartBudget::default();
    let root = budget.xml(package, &main_part)?;
    match root.name.as_str() {
        "document" => docx(&root),
        "presentation" => pptx(&root),
        "workbook" => xlsx(&root),
        _ => Err(Error::Invalid("Only DOCX, PPTX and XLSX are supported")),
    }
}

/// 部件读取计量：速读只应触碰少数部件，读取数超限说明遇到了异常结构
#[derive(Default)]
struct PartBudget {
    parts: usize,
}

impl PartBudget {
    fn xml(&mut self, package: &mut Package, part: &str) -> Result<Node> {
        if self.parts >= MAX_METADATA_PARTS {
            return Err(Error::Limit("Metadata scan exceeded its part budget"));
        }
        self.parts += 1;
        let bytes = package.read(part, METADATA_PART_LIMIT)?;
        crate::xml::parse(bytes)
    }
}

fn metadata(kind: Kind, width: f32, height: f32) -> Metadata {
    Metadata {
        schema_version: crate::model::schema_version(),
        kind,
        page_count: 1,
        width,
        height,
        sheet_names: Vec::new(),
        warnings: Vec::new(),
    }
}

/// DOCX：流式单页排版，宽度取自最后一个 sectPr 的 pgSz；页高依赖平台文本测量，返回 0
fn docx(root: &Node) -> Result<Metadata> {
    let body = root
        .child("body")
        .ok_or(Error::Invalid("Missing DOCX body"))?;
    let mut result = metadata(Kind::DOCX, 595.0, 0.0);
    if let Some(sect) = crate::docx::sections(body).last() {
        if let Some(size) = sect.child("pgSz") {
            result.width = (crate::xml::number(size.attr("w"), 11900.0) / 20.0)
                .clamp(300.0, crate::docx::MAX_COORDINATE);
        }
    }
    Ok(result)
}

/// PPTX：幻灯片数取自 sldIdLst，尺寸取自 sldSz，不读取任何幻灯片部件
fn pptx(root: &Node) -> Result<Metadata> {
    let (width, height) = match root.child("sldSz") {
        Some(size) => (
            crate::pptx::slide_dimension(size.attr("cx"))?,
            crate::pptx::slide_dimension(size.attr("cy"))?,
        ),
        None => (720.0, 540.0),
    };
    let ids = root
        .child("sldIdLst")
        .ok_or(Error::Invalid("PPTX has no slide list"))?;
    let count = ids.named("sldId").count();
    if count == 0 {
        return Err(Error::Invalid("PPTX has no slides"));
    }
    if count > crate::pptx::MAX_SLIDES {
        return Err(Error::Limit("PPTX exceeds 100 slides"));
    }
    let mut result = metadata(Kind::PPTX, width, height);
    result.page_count = u32::try_from(count).unwrap_or(u32::MAX);
    Ok(result)
}

/// XLSX：Sheet 名称与可见性取自 workbook.xml，不读取任何工作表部件
fn xlsx(root: &Node) -> Result<Metadata> {
    let sheets = root
        .child("sheets")
        .ok_or(Error::Invalid("Missing XLSX sheets"))?;
    if sheets.named("sheet").count() > crate::xlsx::MAX_SHEETS {
        return Err(Error::Limit("XLSX exceeds 32 sheets"));
    }
    let mut result = metadata(Kind::XLSX, 1.0, 0.0);
    let mut names = std::collections::HashSet::new();
    for sheet in sheets.named("sheet") {
        let name = sheet.attr("name");
        if name.is_empty() || !names.insert(name.to_owned()) {
            return Err(Error::Invalid("Missing or duplicate XLSX sheet name"));
        }
        match sheet.attr("state") {
            "hidden" | "veryHidden" => {
                if !result
                    .warnings
                    .iter()
                    .any(|warning| warning == "Hidden worksheets are not displayed")
                {
                    result
                        .warnings
                        .push("Hidden worksheets are not displayed".to_owned());
                }
                continue;
            }
            "" | "visible" => (),
            _ => return Err(Error::Invalid("Invalid worksheet visibility")),
        }
        result.sheet_names.push(name.to_owned());
    }
    if result.sheet_names.is_empty() {
        return Err(Error::Invalid(
            "Workbook has no visible supported worksheets",
        ));
    }
    result.page_count = u32::try_from(result.sheet_names.len()).unwrap_or(u32::MAX);
    Ok(result)
}
