use super::colors::Theme;
use super::flag;
use super::geometry::points;
use crate::model::{
    contains_east_asian, infer_font_weight, Document, LineSpacingRule, Paragraph, Run, VertAlign,
};
use crate::xml::{number, Node};

pub(super) struct TextStyle<'a> {
    pub doc: &'a mut Document,
    pub theme: &'a Theme,
}

impl TextStyle<'_> {
    pub fn run(&mut self, run: &mut Run, properties: Option<&Node>) {
        let Some(properties) = properties else { return };
        if !properties.attr("sz").is_empty() {
            run.size = (number(properties.attr("sz"), run.size * 100.0) / 100.0).clamp(1.0, 400.0);
        }
        run.bold = flag(properties.attr("b"), run.bold);
        run.italic = flag(properties.attr("i"), run.italic);
        match properties.attr("u") {
            "" => (),
            "none" | "0" | "false" => run.underline = false,
            "sng" => run.underline = true,
            _ => {
                run.underline = true;
                self.doc
                    .warn("PPTX underline styles use single underlines.");
            }
        }
        run.color = self.theme.text_fill(properties, run.color, self.doc);
        let latin = properties
            .child("latin")
            .map(|f| f.attr("typeface"))
            .filter(|s| !s.is_empty());
        let ea = properties
            .child("ea")
            .map(|f| f.attr("typeface"))
            .filter(|s| !s.is_empty());
        if contains_east_asian(&run.text) {
            if let Some(face) = ea.or(latin) {
                run.font_face = face.to_owned();
            }
        } else if let Some(face) = latin {
            run.font_face = face.to_owned();
        }
        run.weight = infer_font_weight(&run.font_face);
        if ["latin", "ea", "cs", "sym"]
            .iter()
            .any(|n| properties.child(n).is_some())
        {
            self.doc
                .warn("PPTX font faces use viewer system font fallbacks.");
        }
        match properties.attr("strike") {
            "sngStrike" | "dblStrike" => run.strike = true,
            "noStrike" => run.strike = false,
            _ => (),
        }
        let baseline = number(properties.attr("baseline"), 0.0);
        if baseline > 0.0 {
            run.vert_align = VertAlign::Superscript;
        } else if baseline < 0.0 {
            run.vert_align = VertAlign::Subscript;
        }
        if !properties.attr("spc").is_empty() {
            run.spacing = (number(properties.attr("spc"), 0.0) / 100.0).clamp(-100.0, 400.0);
        }
        if let Some(hl) = properties.child("highlight") {
            run.background = self.theme.color(hl, run.background, self.doc);
        }
        if properties.child("hlinkClick").is_some() || properties.child("hlinkMouseOver").is_some()
        {
            self.doc.warn("PPTX text hyperlinks are not interactive.");
        }
    }

    pub fn paragraph(&mut self, paragraph: &mut Paragraph, properties: &Node) {
        match properties.attr("algn") {
            "" => (),
            "l" => paragraph.alignment = 0,
            "ctr" => paragraph.alignment = 1,
            "r" => paragraph.alignment = 2,
            "just" | "justLow" | "dist" | "thaiDist" => paragraph.alignment = 3,
            _ => {
                paragraph.alignment = 0;
                self.doc
                    .warn("PPTX justified paragraphs use left alignment.");
            }
        }
        if let Some(indent) = points(properties.attr("marL")) {
            paragraph.indent = indent.max(0.0);
        }
        if let Some(indent) = points(properties.attr("marR")) {
            paragraph.right_indent = indent.max(0.0);
        }
        if let Some(indent) = points(properties.attr("indent")) {
            paragraph.first_line_indent = indent;
        }
        if let Some(spacing) = properties.child("lnSpc") {
            if let Some(value) = spacing
                .child("spcPct")
                .and_then(|n| percentage(n.attr("val")))
            {
                paragraph.line_spacing_rule = LineSpacingRule::Auto;
                paragraph.line_spacing = value.clamp(0.1, 10.0);
            } else if let Some(value) = spacing
                .child("spcPts")
                .and_then(|n| n.attr("val").parse::<f32>().ok())
                .filter(|v| v.is_finite() && *v >= 0.0)
            {
                paragraph.line_spacing_rule = LineSpacingRule::Exact;
                paragraph.line_spacing = (value / 100.0).min(10_000.0);
            }
        }
        let font_size = properties
            .child("defRPr")
            .map(|rpr| number(rpr.attr("sz"), 1800.0) / 100.0)
            .unwrap_or(18.0);
        paragraph.before = self.spacing(properties.child("spcBef"), paragraph.before, font_size);
        paragraph.after = self.spacing(properties.child("spcAft"), paragraph.after, font_size);
        if properties.child("tabLst").is_some() || flag(properties.attr("rtl"), false) {
            self.doc.warn("PPTX tabs and RTL layout are simplified.");
        }
    }

    fn spacing(&mut self, node: Option<&Node>, fallback: f32, font_size: f32) -> f32 {
        let Some(node) = node else { return fallback };
        if let Some(points) = node.child("spcPts") {
            return (number(points.attr("val"), fallback * 100.0) / 100.0).clamp(0.0, 10_000.0);
        }
        if let Some(ratio) = node.child("spcPct").and_then(|n| percentage(n.attr("val"))) {
            return (ratio * font_size).clamp(0.0, 10_000.0);
        }
        if node.child("spcPct").is_some() {
            self.doc
                .warn("PPTX percentage paragraph spacing is not supported.");
        }
        fallback
    }
}

pub(super) fn apply_autofit(paragraphs: &mut [Paragraph], body: &Node, chain: &[&Node]) {
    let choice = std::iter::once(body)
        .chain(chain.iter().rev().filter_map(|shape| shape.child("txBody")))
        .filter_map(|body| body.child("bodyPr"))
        .find_map(|properties| {
            properties.children.iter().find(|child| {
                matches!(
                    child.name.as_str(),
                    "normAutofit" | "noAutofit" | "spAutoFit"
                )
            })
        });
    // A nearer choice replaces the entire inherited autofit configuration.
    let Some(settings) = choice.filter(|node| node.name == "normAutofit") else {
        return;
    };
    let scale = percentage(settings.attr("fontScale"))
        .filter(|v| (0.01..=1.0).contains(v))
        .unwrap_or(1.0);
    let reduction = percentage(settings.attr("lnSpcReduction"))
        .filter(|v| *v <= 1.0)
        .unwrap_or(0.0);
    for paragraph in paragraphs {
        for run in &mut paragraph.runs {
            run.size = (run.size * scale).max(1.0);
        }
        match paragraph.line_spacing_rule {
            LineSpacingRule::Auto => {
                paragraph.line_spacing = (paragraph.line_spacing - reduction).max(0.1);
            }
            LineSpacingRule::Exact | LineSpacingRule::AtLeast => (),
        }
    }
}

fn percentage(value: &str) -> Option<f32> {
    let value = value.trim();
    let ratio = match value.strip_suffix('%') {
        Some(percent) => percent.trim().parse::<f32>().ok()? / 100.0,
        None => value.parse::<f32>().ok()? / 100_000.0,
    };
    (ratio.is_finite() && ratio >= 0.0).then_some(ratio)
}
