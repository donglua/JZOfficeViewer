use super::flag;
use super::transform::Transform;
use crate::model::{Document, Element, ElementType, VerticalAlignment};
use crate::xml::{number, Node};

const MAX_POINT: f32 = 100_000.0;

pub(super) fn points(value: &str) -> Option<f32> {
    value
        .parse::<f32>()
        .ok()
        .map(|v| v / 12700.0)
        .filter(|v| v.is_finite() && v.abs() <= MAX_POINT)
}

#[derive(Clone, Copy)]
pub(super) struct Bounds {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    rotation: f32,
    flip_h: bool,
    flip_v: bool,
}

impl Bounds {
    pub fn parse(chain: &[&Node]) -> Option<Self> {
        let (mut offset, mut extent, mut rotation) = (None, None, 0.0);
        let (mut flip_h, mut flip_v) = (false, false);
        for shape in chain {
            let transform = match shape.name.as_str() {
                "graphicFrame" => shape.child("xfrm"),
                _ => shape.child("spPr").and_then(|p| p.child("xfrm")),
            };
            let Some(transform) = transform else { continue };
            if let Some(off) = transform.child("off") {
                offset = Some((points(off.attr("x"))?, points(off.attr("y"))?));
            }
            if let Some(ext) = transform.child("ext") {
                extent = Some((points(ext.attr("cx"))?, points(ext.attr("cy"))?));
            }
            rotation = (number(transform.attr("rot"), 0.0) / 60000.0) % 360.0;
            flip_h = flag(transform.attr("flipH"), false);
            flip_v = flag(transform.attr("flipV"), false);
        }
        let (x, y) = offset?;
        let (width, height) = extent?;
        if width < 0.0
            || height < 0.0
            || (x + width).abs() > MAX_POINT
            || (y + height).abs() > MAX_POINT
        {
            return None;
        }
        Some(Self {
            x,
            y,
            width,
            height,
            rotation,
            flip_h,
            flip_v,
        })
    }

    pub fn element(self, kind: ElementType) -> Element {
        Element {
            kind,
            x: self.x,
            y: self.y,
            width: self.width,
            height: self.height,
            rotation: self.rotation,
            flip_h: self.flip_h,
            flip_v: self.flip_v,
            ..Element::default()
        }
    }

    pub fn in_slide_units(self, transform: Transform) -> Option<(Self, Transform)> {
        if transform.0 == Transform::IDENTITY.0 {
            return Some((self, transform));
        }
        let [a, b, c, d, tx, ty] = transform.0;
        let (sin, cos) = self.rotation.to_radians().sin_cos();
        let (a, b, c, d) = (
            a * cos + c * sin,
            b * cos + d * sin,
            c * cos - a * sin,
            d * cos - b * sin,
        );
        let (sx, sy) = (a.hypot(b), c.hypot(d));
        if sx <= 0.0 || sy <= 0.0 {
            return None;
        }
        let [ga, gb, gc, gd, _, _] = transform.0;
        let (cx, cy) = (self.x + self.width / 2.0, self.y + self.height / 2.0);
        let x = ga * cx + gc * cy + tx - (a * self.width + c * self.height) / 2.0;
        let y = gb * cx + gd * cy + ty - (b * self.width + d * self.height) / 2.0;
        let (width, height) = (self.width * sx, self.height * sy);
        if [x, y, width, height]
            .iter()
            .any(|v| !v.is_finite() || v.abs() > MAX_POINT)
        {
            return None;
        }
        // Group coordinates scale geometry; fonts, margins and line widths are already points.
        let bounds = Self {
            x: 0.0,
            y: 0.0,
            width,
            height,
            rotation: 0.0,
            ..self
        };
        Some((bounds, Transform([a / sx, b / sx, c / sy, d / sy, x, y])))
    }

    pub fn text_element(self, chain: &[&Node], doc: &mut Document) -> Option<Element> {
        let (mut left, mut right, mut top, mut bottom) = (7.2, 7.2, 3.6, 3.6);
        let mut vertical_alignment = VerticalAlignment::Top;
        let mut text_wrap = true;
        for shape in chain {
            let Some(body) = shape.child("txBody").and_then(|b| b.child("bodyPr")) else {
                continue;
            };
            left = points(body.attr("lIns")).map_or(left, |v| v.max(0.0));
            right = points(body.attr("rIns")).map_or(right, |v| v.max(0.0));
            top = points(body.attr("tIns")).map_or(top, |v| v.max(0.0));
            bottom = points(body.attr("bIns")).map_or(bottom, |v| v.max(0.0));
            if let Some(anchor) = body.get_attr("anchor") {
                vertical_alignment = match anchor {
                    "ctr" => VerticalAlignment::Center,
                    "b" => VerticalAlignment::Bottom,
                    "t" => VerticalAlignment::Top,
                    _ => {
                        doc.warn("PPTX unknown vertical text alignment uses top alignment.");
                        VerticalAlignment::Top
                    }
                };
            }
            if !matches!(body.attr("vert"), "" | "horz") || number(body.attr("rot"), 0.0) != 0.0 {
                doc.warn("PPTX vertical text and independent text rotation are not supported.");
            }
            match body.attr("wrap") {
                "none" => text_wrap = false,
                "square" => text_wrap = true,
                _ => (),
            }
            if !matches!(body.attr("numCol"), "" | "1") {
                doc.warn("PPTX text uses one column.");
            }
            if ["spAutoFit", "prstTxWarp"]
                .iter()
                .any(|name| body.child(name).is_some())
            {
                doc.warn("PPTX shape-to-text autofit and WordArt are not supported.");
            }
        }
        left = left.min(self.width);
        right = right.min(self.width - left);
        top = top.min(self.height);
        bottom = bottom.min(self.height - top);
        let width = self.width - left - right;
        let height = self.height - top - bottom;
        if width <= 0.0 || height <= 0.0 {
            return None;
        }
        let (sin, cos) = self.rotation.to_radians().sin_cos();
        let (dx, dy) = ((left - right) / 2.0, (top - bottom) / 2.0);
        let x = self.x + (self.width - width) / 2.0 + dx * cos - dy * sin;
        let y = self.y + (self.height - height) / 2.0 + dx * sin + dy * cos;
        if [x, y, x + width, y + height]
            .iter()
            .any(|v| !v.is_finite() || v.abs() > MAX_POINT)
        {
            return None;
        }
        Some(Element {
            x,
            y,
            width,
            height,
            padding: 0.0,
            vertical_alignment,
            text_wrap,
            flip_h: false,
            flip_v: false,
            ..self.element(ElementType::TEXT)
        })
    }
}
