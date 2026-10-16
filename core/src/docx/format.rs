use super::MAX_COORDINATE;
use crate::model::{Document, LineSpacingRule, Paragraph, Run};
use crate::xml::{self, Node};
use crate::{Error, Result};

#[derive(Clone, Default)]
pub(super) struct Font {
    pub run: Run,
    pub hidden: bool,
    families: [FontFamily; 4],
}

#[derive(Clone, Default)]
enum FontFamily {
    #[default]
    Default,
    Explicit(String),
    Theme,
}

impl Font {
    pub fn run(&self, text: &str, document: &mut Document) -> Run {
        let mut run = Run {
            text: text.to_owned(),
            ..self.run.clone()
        };
        let mut face = None;
        for family in &self.families {
            match family {
                FontFamily::Default => (),
                FontFamily::Theme => {
                    document.warn("Theme fonts use the viewer's default font.");
                    return run;
                }
                FontFamily::Explicit(value) => {
                    if face.is_some_and(|previous| previous != value) {
                        document.warn("Mixed-script font families use the viewer's default font.");
                        return run;
                    }
                    face = Some(value);
                }
            }
        }
        if let Some(face) = face {
            run.font_face.clone_from(face);
            document.warn(
                "Font families use available device fonts; missing fonts may be substituted.",
            );
        }
        run
    }
}

pub(super) fn enabled(value: &str) -> bool {
    !["0", "false", "off", "none"]
        .iter()
        .any(|off| value.eq_ignore_ascii_case(off))
}

pub(super) fn points(value: &str, fallback: f32) -> f32 {
    value
        .parse::<f32>()
        .ok()
        .filter(|n| n.is_finite())
        .map_or(fallback, |n| (n / 20.0).clamp(0.0, MAX_COORDINATE))
}

pub(super) fn font(font: &mut Font, properties: Option<&Node>) -> Result<()> {
    let Some(properties) = properties else {
        return Ok(());
    };
    let run = &mut font.run;
    for node in &properties.children {
        let value = node.attr("val");
        match node.name.as_str() {
            "rFonts" => {
                // Theme wins in this node; either choice replaces that script's inherited value.
                for ((name, theme), family) in [
                    ("ascii", "asciiTheme"),
                    ("hAnsi", "hAnsiTheme"),
                    ("eastAsia", "eastAsiaTheme"),
                    ("cs", "cstheme"),
                ]
                .into_iter()
                .zip(&mut font.families)
                {
                    if !node.attr(theme).trim().is_empty() {
                        *family = FontFamily::Theme;
                    } else if !node.attr(name).trim().is_empty() {
                        let face = node.attr(name).trim();
                        if face.len() > 256 {
                            return Err(Error::Limit("DOCX font family name exceeds 256 bytes"));
                        }
                        *family = FontFamily::Explicit(face.to_owned());
                    }
                }
            }
            "b" => run.bold = enabled(value),
            "i" => run.italic = enabled(value),
            "u" => run.underline = enabled(value),
            "sz" => run.size = (xml::number(value, run.size * 2.0) / 2.0).clamp(1.0, 400.0),
            "color" => {
                run.color = if value.eq_ignore_ascii_case("auto") {
                    0xff202124
                } else {
                    xml::color(value, run.color)
                }
            }
            "vanish" => font.hidden = enabled(value),
            "webHidden" => font.hidden = enabled(value),
            _ => (),
        }
    }
    Ok(())
}

#[derive(Clone)]
pub(super) struct ParagraphFormat {
    pub paragraph: Paragraph,
    pub number: String,
    pub level: u8,
    pub has_indent: bool,
    line_spacing_units: f32,
}

impl Default for ParagraphFormat {
    fn default() -> Self {
        Self {
            paragraph: Paragraph::default(),
            number: String::new(),
            level: 0,
            has_indent: false,
            line_spacing_units: 240.0,
        }
    }
}

impl ParagraphFormat {
    fn apply_line_spacing(&mut self) {
        match self.paragraph.line_spacing_rule {
            LineSpacingRule::Auto => {
                self.paragraph.line_spacing = (self.line_spacing_units / 240.0).clamp(0.1, 10.0);
            }
            LineSpacingRule::Exact => {
                self.paragraph.line_spacing = (self.line_spacing_units / 20.0).clamp(0.1, 400.0);
            }
            LineSpacingRule::AtLeast => {
                self.paragraph.line_spacing = (self.line_spacing_units / 20.0).clamp(0.1, 400.0);
            }
        }
    }

    pub fn apply(&mut self, properties: Option<&Node>) {
        let Some(properties) = properties else {
            return;
        };
        for node in &properties.children {
            match node.name.as_str() {
                "jc" => {
                    self.paragraph.alignment = match node.attr("val") {
                        "center" => 1,
                        "right" | "end" => 2,
                        _ => 0,
                    }
                }
                "spacing" => {
                    self.paragraph.before = points(node.attr("before"), self.paragraph.before);
                    self.paragraph.after = points(node.attr("after"), self.paragraph.after);
                    let mut update_line_spacing = false;
                    if !node.attr("line").is_empty() {
                        self.line_spacing_units =
                            xml::number(node.attr("line"), self.line_spacing_units);
                        update_line_spacing = true;
                    }
                    if !node.attr("lineRule").is_empty() {
                        self.paragraph.line_spacing_rule = match node.attr("lineRule") {
                            "exact" => LineSpacingRule::Exact,
                            "atLeast" => LineSpacingRule::AtLeast,
                            _ => LineSpacingRule::Auto,
                        };
                        update_line_spacing = true;
                    }
                    if update_line_spacing {
                        self.apply_line_spacing();
                    }
                }
                "ind" => {
                    let left = if node.attr("start").is_empty() {
                        node.attr("left")
                    } else {
                        node.attr("start")
                    };
                    if !left.is_empty() {
                        self.paragraph.indent = points(left, self.paragraph.indent);
                        self.has_indent = true;
                    }
                    let right = if node.attr("end").is_empty() {
                        node.attr("right")
                    } else {
                        node.attr("end")
                    };
                    if !right.is_empty() {
                        self.paragraph.right_indent = points(right, self.paragraph.right_indent);
                    }
                    if !node.attr("hanging").is_empty() {
                        self.paragraph.first_line_indent =
                            -points(node.attr("hanging"), -self.paragraph.first_line_indent);
                    } else if !node.attr("firstLine").is_empty() {
                        self.paragraph.first_line_indent =
                            points(node.attr("firstLine"), self.paragraph.first_line_indent);
                    }
                }
                "numPr" => {
                    if let Some(number) = node.child("numId") {
                        self.number = number.attr("val").to_owned();
                    }
                    if let Some(level) = node.child("ilvl") {
                        self.level = level.attr("val").parse::<u8>().map_or(0, |n| n.min(8));
                    }
                }
                _ => (),
            }
        }
    }
}
