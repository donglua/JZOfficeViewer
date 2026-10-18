pub use crate::spreadsheet::{Cell, CellRange, CellStyle, Sheet};
use serde::Serialize;

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
}

impl Document {
    pub fn new(kind: Kind) -> Self {
        Self {
            schema_version: 9,
            kind,
            width: 595.0,
            pages: Vec::new(),
            blocks: Vec::new(),
            warnings: Vec::new(),
            sheets: Vec::new(),
            cell_styles: Vec::new(),
        }
    }

    pub fn warn(&mut self, message: &str) {
        if self.warnings.len() < 100 && !self.warnings.iter().any(|s| s == message) {
            self.warnings.push(message.to_owned());
        }
    }
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
    pub color: u32,
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
            color: 0xff202124,
        }
    }
}
