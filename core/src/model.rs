pub use crate::spreadsheet::{Cell, CellRange, CellStyle, Sheet};
use serde::Serialize;

/// 当前跨语言模型版本，需与 Android `DocumentDecoder` 及鸿蒙 `NativeCore` / `OfficeModel` 的校验值同步
pub const fn schema_version() -> u32 {
    9
}

#[derive(Debug, Clone, Serialize)]
pub enum Kind {
    DOCX,
    PPTX,
    XLSX,
}

#[derive(Debug, Clone, Serialize, Default)]
pub enum ElementType {
    #[default]
    TEXT,
    IMAGE,
    RECT,
    ELLIPSE,
    LINE,
    TABLE,
    PATH,
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "op", content = "points", rename_all = "SCREAMING_SNAKE_CASE")]
pub enum PathCommand {
    Move([f32; 2]),
    Line([f32; 2]),
    Quad([f32; 4]),
    Cubic([f32; 6]),
    Close,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Path {
    pub fill: bool,
    pub stroke: bool,
    pub commands: Vec<PathCommand>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GradientFill {
    pub colors: Vec<u32>,
    pub positions: Vec<f32>,
    pub points: [f32; 4],
    #[serde(skip_serializing_if = "Option::is_none")]
    pub transform: Option<[f32; 6]>,
    #[serde(skip_serializing)]
    pub angle: f32,
    #[serde(skip_serializing)]
    pub scaled: bool,
    #[serde(skip_serializing)]
    pub in_slide_space: bool,
}

#[derive(Debug, Clone, Copy, Serialize, Default, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum VertAlign {
    #[default]
    Baseline,
    Superscript,
    Subscript,
}

impl VertAlign {
    #[must_use]
    pub const fn is_baseline(&self) -> bool {
        matches!(self, Self::Baseline)
    }
}

pub fn is_false(v: &bool) -> bool {
    !*v
}

pub fn is_zero_f32(v: &f32) -> bool {
    *v == 0.0
}

pub fn is_zero_u16(v: &u16) -> bool {
    *v == 0
}

pub fn is_zero_u32(v: &u32) -> bool {
    *v == 0
}

pub fn contains_east_asian(text: &str) -> bool {
    text.chars().any(|c| {
        matches!(
            c,
            '\u{2E80}'..='\u{9FFF}'
                | '\u{AC00}'..='\u{D7AF}'
                | '\u{F900}'..='\u{FAFF}'
                | '\u{FE30}'..='\u{FE4F}'
                | '\u{FF00}'..='\u{FFEF}'
        )
    })
}

pub fn infer_font_weight(font_face: &str) -> u16 {
    let lower = font_face.to_ascii_lowercase();
    let normalized = lower.replace([' ', '-', '_'], "");
    if normalized.contains("thin") || normalized.contains("hairline") {
        100
    } else if normalized.contains("extralight") || normalized.contains("ultralight") {
        200
    } else if normalized.contains("demilight") || normalized.contains("light") {
        300
    } else if normalized.contains("medium") {
        500
    } else if normalized.contains("semibold") || normalized.contains("demibold") {
        600
    } else if normalized.contains("extrabold")
        || normalized.contains("ultrabold")
        || normalized.contains("heavy")
    {
        800
    } else if normalized.contains("black") {
        900
    } else {
        0
    }
}

#[derive(Debug, Clone, Copy, Serialize, Default, PartialEq)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum VerticalAlignment {
    #[default]
    Top,
    Center,
    Bottom,
}

#[derive(Debug, Clone, Copy, Serialize, Default, PartialEq)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum LineSpacingRule {
    #[default]
    Auto,
    Exact,
    AtLeast,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq)]
pub struct ImageCrop {
    pub left: f32,
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Document {
    pub schema_version: u32,
    pub kind: Kind,
    pub width: f32,
    pub pages: Vec<Page>,
    pub blocks: Vec<Element>,
    pub warnings: Vec<String>,
    pub sheets: Vec<Sheet>,
    pub cell_styles: Vec<CellStyle>,
    /// DOCX 页眉内容块（来自 headerReference 关联的 header*.xml），为空时不序列化
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub header_blocks: Vec<Element>,
    /// DOCX 页脚内容块（来自 footerReference 关联的 footer*.xml），为空时不序列化
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub footer_blocks: Vec<Element>,
    /// 页眉距页面顶部的距离（点），来自 sectPr/pgMar@header
    #[serde(skip_serializing_if = "is_zero_f32")]
    pub header_distance: f32,
    /// 页脚距页面底部的距离（点），来自 sectPr/pgMar@footer
    #[serde(skip_serializing_if = "is_zero_f32")]
    pub footer_distance: f32,
    /// 页边距（点），来自 sectPr/pgMar
    #[serde(skip_serializing_if = "is_zero_f32")]
    pub margin_top: f32,
    #[serde(skip_serializing_if = "is_zero_f32")]
    pub margin_bottom: f32,
    #[serde(skip_serializing_if = "is_zero_f32")]
    pub margin_left: f32,
    #[serde(skip_serializing_if = "is_zero_f32")]
    pub margin_right: f32,
}

impl Document {
    pub fn new(kind: Kind) -> Self {
        Self {
            schema_version: schema_version(),
            kind,
            width: 595.0,
            pages: Vec::new(),
            blocks: Vec::new(),
            warnings: Vec::new(),
            sheets: Vec::new(),
            cell_styles: Vec::new(),
            header_blocks: Vec::new(),
            footer_blocks: Vec::new(),
            header_distance: 0.0,
            footer_distance: 0.0,
            margin_top: 0.0,
            margin_bottom: 0.0,
            margin_left: 0.0,
            margin_right: 0.0,
        }
    }

    pub fn warn(&mut self, message: &str) {
        if self.warnings.len() < 100 && !self.warnings.iter().any(|s| s == message) {
            self.warnings.push(message.to_owned());
        }
    }

    /// 在当前文档模型中执行大小写不敏感的全文检索
    #[must_use]
    pub fn search(&self, query: &str) -> Vec<SearchMatch> {
        crate::search::search_document(self, query)
    }
}

/// 全文检索单条命中结果（跨平台 JSON 协议，字段采用 camelCase）
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchMatch {
    /// 页或工作表索引（0-based：DOCX 固定为 0，PPTX 为幻灯片序号，XLSX 为工作表序号）
    pub page_index: u32,
    /// 元素索引（0-based：DOCX 为 headerBlocks + blocks + footerBlocks 合并流序号，PPTX 为 page.elements 序号，XLSX 为 sheet.cells 序号）
    pub element_index: u32,
    /// 段落索引（0-based：普通文本块在 element.paragraphs 中的序号，表格单元格在 rows[row][column] 中的序号，XLSX 固定为 0）
    pub paragraph_index: u32,
    /// 表格或电子表格中的行号（0-based，仅 TABLE 元素与 XLSX 单元格存在）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub row: Option<u32>,
    /// 表格或电子表格中的列号（0-based，仅 TABLE 元素与 XLSX 单元格存在）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub column: Option<u32>,
    /// 命中文本在渲染段落（含 bullet 前缀）或单元格文本中的起始 UTF-16 码元偏移（0-based，包含）
    pub start_char: u32,
    /// 命中文本在渲染段落（含 bullet 前缀）或单元格文本中的结束 UTF-16 码元偏移（0-based，不包含）
    pub end_char: u32,
    /// 命中位置前后的上下文摘要文本
    pub snippet: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct Page {
    pub width: f32,
    pub height: f32,
    pub background: u32,
    pub elements: Vec<Element>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Element {
    #[serde(rename = "type")]
    pub kind: ElementType,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    #[serde(skip_serializing)]
    pub rotation: f32,
    /// PPTX local-to-slide drawing matrix, including position, rotation and flips.
    pub transform: [f32; 6],
    #[serde(skip_serializing)]
    pub flip_h: bool,
    #[serde(skip_serializing)]
    pub flip_v: bool,
    pub padding: f32,
    pub fill: u32,
    pub stroke: u32,
    pub stroke_width: f32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image: Option<String>,
    #[serde(skip_serializing)]
    pub image_crop: Option<ImageCrop>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_bounds: Option<[f32; 4]>,
    pub vertical_alignment: VerticalAlignment,
    pub text_wrap: bool,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub paragraphs: Vec<Paragraph>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub rows: Vec<Vec<Vec<Paragraph>>>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub column_widths: Vec<f32>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub merges: Vec<CellRange>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub cell_fills: Vec<Vec<u32>>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub paths: Vec<Path>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fill_gradient: Option<GradientFill>,
}

impl Default for Element {
    fn default() -> Self {
        Self {
            kind: ElementType::TEXT,
            x: 0.0,
            y: 0.0,
            width: 0.0,
            height: 0.0,
            rotation: 0.0,
            transform: [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
            flip_h: false,
            flip_v: false,
            padding: 4.0,
            fill: 0,
            stroke: 0,
            stroke_width: 1.0,
            image: None,
            image_crop: None,
            image_bounds: None,
            vertical_alignment: VerticalAlignment::Top,
            text_wrap: true,
            paragraphs: Vec::new(),
            rows: Vec::new(),
            column_widths: Vec::new(),
            merges: Vec::new(),
            cell_fills: Vec::new(),
            paths: Vec::new(),
            fill_gradient: None,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Paragraph {
    pub runs: Vec<Run>,
    pub alignment: u8,
    pub before: f32,
    pub after: f32,
    pub indent: f32,
    pub right_indent: f32,
    pub first_line_indent: f32,
    pub line_spacing_rule: LineSpacingRule,
    pub line_spacing: f32,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub bullet: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_width: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_height: Option<f32>,
    #[serde(skip_serializing_if = "is_zero_u32")]
    pub background: u32,
    #[serde(skip_serializing_if = "is_zero_u32")]
    pub border_top: u32,
    #[serde(skip_serializing_if = "is_zero_u32")]
    pub border_bottom: u32,
    #[serde(skip_serializing_if = "is_zero_u32")]
    pub border_left: u32,
    #[serde(skip_serializing_if = "is_zero_u32")]
    pub border_right: u32,
    #[serde(skip_serializing_if = "is_zero_f32")]
    pub border_width: f32,
}

impl Default for Paragraph {
    fn default() -> Self {
        Self {
            runs: Vec::new(),
            alignment: 0,
            before: 0.0,
            after: 6.0,
            indent: 0.0,
            right_indent: 0.0,
            first_line_indent: 0.0,
            line_spacing_rule: LineSpacingRule::Auto,
            line_spacing: 1.0,
            bullet: String::new(),
            image: None,
            image_width: None,
            image_height: None,
            background: 0,
            border_top: 0,
            border_bottom: 0,
            border_left: 0,
            border_right: 0,
            border_width: 0.0,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Run {
    pub text: String,
    #[serde(rename = "fontFace", skip_serializing_if = "String::is_empty")]
    pub font_face: String,
    pub size: f32,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    #[serde(skip_serializing_if = "is_false")]
    pub strike: bool,
    #[serde(rename = "vertAlign", skip_serializing_if = "VertAlign::is_baseline")]
    pub vert_align: VertAlign,
    #[serde(skip_serializing_if = "is_zero_f32")]
    pub spacing: f32,
    #[serde(skip_serializing_if = "is_zero_u16")]
    pub weight: u16,
    pub color: u32,
    #[serde(skip_serializing_if = "is_zero_u32")]
    pub background: u32,
}

impl Default for Run {
    fn default() -> Self {
        Self {
            text: String::new(),
            font_face: String::new(),
            size: 12.0,
            bold: false,
            italic: false,
            underline: false,
            strike: false,
            vert_align: VertAlign::Baseline,
            spacing: 0.0,
            weight: 0,
            color: 0xff202124,
            background: 0,
        }
    }
}
