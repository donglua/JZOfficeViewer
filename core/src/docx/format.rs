use super::MAX_COORDINATE;
use crate::model::{
    contains_east_asian, infer_font_weight, Document, LineSpacingRule, Paragraph, Run, VertAlign,
};
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
        for family in &self.families {
            if matches!(family, FontFamily::Theme) {
                document.warn("Theme fonts use the viewer's default font.");
                return run;
            }
        }
        let mut explicit = Vec::new();
        for family in &self.families {
            if let FontFamily::Explicit(value) = family {
                explicit.push(value.as_str());
            }
        }
        if explicit.is_empty() {
            return run;
        }

        let all_identical = explicit.iter().all(|f| *f == explicit[0]);
        let face = if all_identical {
            Some(explicit[0])
        } else {
            let has_cjk = contains_east_asian(text);
            let has_latin = text.chars().any(|c| c.is_ascii_alphabetic());
            if has_cjk && !has_latin {
                if let FontFamily::Explicit(ref ea) = self.families[2] {
                    Some(ea.as_str())
                } else {
                    None
                }
            } else if has_latin && !has_cjk {
                if let FontFamily::Explicit(ref ascii) = self.families[0] {
                    Some(ascii.as_str())
                } else if let FontFamily::Explicit(ref h_ansi) = self.families[1] {
                    Some(h_ansi.as_str())
                } else {
                    None
                }
            } else {
                None
            }
        };

        if let Some(face) = face {
            run.font_face = face.to_owned();
            run.weight = infer_font_weight(face);
            document.warn(
                "Font families use available device fonts; missing fonts may be substituted.",
            );
        } else {
            document.warn("Mixed-script font families use the viewer's default font.");
            return run;
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

pub(super) fn char_points(value: &str, font_size: f32, fallback: f32) -> f32 {
    let em = if font_size > 0.0 && font_size.is_finite() {
        font_size
    } else {
        12.0
    };
    value
        .parse::<f32>()
        .ok()
        .filter(|n| n.is_finite())
        .map_or(fallback, |n| (n / 100.0 * em).clamp(0.0, MAX_COORDINATE))
}

pub(super) fn font(
    font: &mut Font,
    properties: Option<&Node>,
    theme_fonts: Option<&super::theme::ThemeFonts>,
) -> Result<()> {
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
                        let theme_key = node.attr(theme).trim();
                        if let Some(resolved) = theme_fonts.and_then(|tf| tf.get(theme_key)) {
                            if resolved.len() > 256 {
                                return Err(Error::Limit(
                                    "DOCX font family name exceeds 256 bytes",
                                ));
                            }
                            *family = FontFamily::Explicit(resolved.to_owned());
                        } else {
                            *family = FontFamily::Theme;
                        }
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
            "strike" | "dstrike" => run.strike = enabled(value),
            "vertAlign" => {
                run.vert_align = match value {
                    "superscript" => VertAlign::Superscript,
                    "subscript" => VertAlign::Subscript,
                    _ => VertAlign::Baseline,
                };
            }
            "spacing" => run.spacing = (xml::number(value, 0.0) / 20.0).clamp(-100.0, 400.0),
            "sz" => run.size = (xml::number(value, run.size * 2.0) / 2.0).clamp(1.0, 400.0),
            "color" => {
                run.color = if value.eq_ignore_ascii_case("auto") {
                    0xff202124
                } else {
                    xml::color(value, run.color)
                }
            }
            "highlight" => {
                let mapped = match value {
                    "yellow" => 0xFFFFFF00,
                    "green" => 0xFF00FF00,
                    "cyan" => 0xFF00FFFF,
                    "magenta" => 0xFFFF00FF,
                    "blue" => 0xFF0000FF,
                    "red" => 0xFFFF0000,
                    "darkBlue" | "darkblue" => 0xFF000080,
                    "darkCyan" | "darkcyan" => 0xFF008080,
                    "darkGreen" | "darkgreen" => 0xFF008000,
                    "darkMagenta" | "darkmagenta" => 0xFF800080,
                    "darkRed" | "darkred" => 0xFF800000,
                    "darkYellow" | "darkyellow" => 0xFF808000,
                    "darkGray" | "darkgray" => 0xFF808080,
                    "lightGray" | "lightgray" => 0xFFC0C0C0,
                    "black" => 0xFF000000,
                    "white" => 0xFFFFFFFF,
                    "none" => 0,
                    _ => xml::color(value, 0),
                };
                run.background = mapped;
            }
            "shd" => {
                let fill = node.attr("fill");
                if !fill.is_empty()
                    && !fill.eq_ignore_ascii_case("auto")
                    && !fill.eq_ignore_ascii_case("none")
                {
                    run.background = xml::color(fill, run.background);
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
    pub contextual_spacing: bool,
    pub snap_to_grid: bool,
    pub style_id: String,
    line_spacing_units: f32,
}

impl Default for ParagraphFormat {
    fn default() -> Self {
        Self {
            paragraph: Paragraph::default(),
            number: String::new(),
            level: 0,
            has_indent: false,
            contextual_spacing: false,
            snap_to_grid: true,
            style_id: String::new(),
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

    pub fn apply(&mut self, properties: Option<&Node>, font_size: f32) {
        let Some(properties) = properties else {
            return;
        };
        for node in &properties.children {
            match node.name.as_str() {
                "jc" => {
                    self.paragraph.alignment = match node.attr("val") {
                        "center" => 1,
                        "right" | "end" => 2,
                        "both" | "distribute" => 3,
                        _ => 0,
                    }
                }
                "spacing" => {
                    let em = if font_size > 0.0 && font_size.is_finite() {
                        font_size
                    } else {
                        12.0
                    };
                    if !node.attr("beforeLines").is_empty() {
                        let lines = xml::number(node.attr("beforeLines"), 0.0);
                        self.paragraph.before =
                            (lines / 100.0 * em * 1.2).clamp(0.0, MAX_COORDINATE);
                    } else if !node.attr("before").is_empty() {
                        self.paragraph.before = points(node.attr("before"), self.paragraph.before);
                    } else if matches!(node.attr("beforeAutospacing"), "1" | "true" | "on")
                        || (!node.attr("beforeAutospacing").is_empty()
                            && enabled(node.attr("beforeAutospacing")))
                    {
                        self.paragraph.before = 5.0;
                    }

                    if !node.attr("afterLines").is_empty() {
                        let lines = xml::number(node.attr("afterLines"), 0.0);
                        self.paragraph.after =
                            (lines / 100.0 * em * 1.2).clamp(0.0, MAX_COORDINATE);
                    } else if !node.attr("after").is_empty() {
                        self.paragraph.after = points(node.attr("after"), self.paragraph.after);
                    } else if matches!(node.attr("afterAutospacing"), "1" | "true" | "on")
                        || (!node.attr("afterAutospacing").is_empty()
                            && enabled(node.attr("afterAutospacing")))
                    {
                        self.paragraph.after = 5.0;
                    }
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
                "contextualSpacing" => {
                    let val = node.attr("val");
                    self.contextual_spacing = if val.is_empty() { true } else { enabled(val) };
                }
                "snapToGrid" => {
                    let val = node.attr("val");
                    self.snap_to_grid = if val.is_empty() { true } else { enabled(val) };
                }
                "pStyle" => {
                    if !node.attr("val").is_empty() {
                        self.style_id = node.attr("val").to_owned();
                    }
                }
                "ind" => {
                    let left_chars = if node.attr("startChars").is_empty() {
                        node.attr("leftChars")
                    } else {
                        node.attr("startChars")
                    };
                    if !left_chars.is_empty() {
                        self.paragraph.indent =
                            char_points(left_chars, font_size, self.paragraph.indent);
                        self.has_indent = true;
                    } else {
                        let left = if node.attr("start").is_empty() {
                            node.attr("left")
                        } else {
                            node.attr("start")
                        };
                        if !left.is_empty() {
                            self.paragraph.indent = points(left, self.paragraph.indent);
                            self.has_indent = true;
                        }
                    }
                    let right_chars = if node.attr("endChars").is_empty() {
                        node.attr("rightChars")
                    } else {
                        node.attr("endChars")
                    };
                    if !right_chars.is_empty() {
                        self.paragraph.right_indent =
                            char_points(right_chars, font_size, self.paragraph.right_indent);
                    } else {
                        let right = if node.attr("end").is_empty() {
                            node.attr("right")
                        } else {
                            node.attr("end")
                        };
                        if !right.is_empty() {
                            self.paragraph.right_indent =
                                points(right, self.paragraph.right_indent);
                        }
                    }
                    if !node.attr("hangingChars").is_empty() {
                        self.paragraph.first_line_indent = -char_points(
                            node.attr("hangingChars"),
                            font_size,
                            -self.paragraph.first_line_indent,
                        );
                    } else if !node.attr("hanging").is_empty() {
                        self.paragraph.first_line_indent =
                            -points(node.attr("hanging"), -self.paragraph.first_line_indent);
                    } else if !node.attr("firstLineChars").is_empty() {
                        self.paragraph.first_line_indent = char_points(
                            node.attr("firstLineChars"),
                            font_size,
                            self.paragraph.first_line_indent,
                        );
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
                "shd" => {
                    let fill = node.attr("fill");
                    if !fill.is_empty()
                        && !fill.eq_ignore_ascii_case("auto")
                        && !fill.eq_ignore_ascii_case("none")
                    {
                        self.paragraph.background = xml::color(fill, self.paragraph.background);
                    }
                }
                "pBdr" => {
                    for child in &node.children {
                        let val = child.attr("val");
                        if val == "none" || val == "nil" {
                            continue;
                        }
                        let color = if child.attr("color").is_empty()
                            || child.attr("color").eq_ignore_ascii_case("auto")
                        {
                            0xFF000000
                        } else {
                            xml::color(child.attr("color"), 0xFF000000)
                        };
                        let sz = xml::number(child.attr("sz"), 4.0) / 8.0;
                        match child.name.as_str() {
                            "top" => self.paragraph.border_top = color,
                            "bottom" => self.paragraph.border_bottom = color,
                            "left" => self.paragraph.border_left = color,
                            "right" => self.paragraph.border_right = color,
                            _ => {}
                        }
                        self.paragraph.border_width = sz.max(self.paragraph.border_width);
                    }
                }
                _ => (),
            }
        }
    }
}
