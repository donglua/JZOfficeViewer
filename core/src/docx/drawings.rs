use super::{Parser, MAX_COORDINATE};
use crate::model::{Element, ElementType, ImageCrop, WrapMode};
use crate::xml::{self, Node};
use crate::{Error, Result};

const EMU_PER_POINT: f32 = 12700.0;

#[derive(Clone, Copy)]
pub(super) struct AnchorLayout {
    pub x: f32,
    pub y: f32,
    pub wrap_mode: WrapMode,
    pub horizontal_align: u8,
    pub behind_doc: bool,
    pub dist_top: f32,
    pub dist_bottom: f32,
    pub dist_left: f32,
    pub dist_right: f32,
}

impl Default for AnchorLayout {
    fn default() -> Self {
        Self {
            x: 0.0,
            y: 0.0,
            wrap_mode: WrapMode::Inline,
            horizontal_align: 0,
            behind_doc: false,
            dist_top: 0.0,
            dist_bottom: 0.0,
            dist_left: 0.0,
            dist_right: 0.0,
        }
    }
}

impl AnchorLayout {
    pub(super) fn apply(self, element: &mut Element) {
        element.x = self.x;
        element.y = self.y;
        element.wrap_mode = self.wrap_mode;
        element.horizontal_align = self.horizontal_align;
        element.behind_doc = self.behind_doc;
        element.dist_top = self.dist_top;
        element.dist_bottom = self.dist_bottom;
        element.dist_left = self.dist_left;
        element.dist_right = self.dist_right;
    }
}

impl Parser<'_> {
    pub(super) fn drawings(&mut self, node: &Node) -> Result<Vec<Element>> {
        let mut images = Vec::new();
        let mut found = false;
        for container in &node.children {
            if !matches!(container.name.as_str(), "inline" | "anchor") {
                continue;
            }
            found = true;
            let Some(blip) = container.descendant("blip") else {
                self.document
                    .warn("Non-image drawings, charts and diagrams are omitted.");
                continue;
            };
            let id = if blip.attr("r:embed").is_empty() {
                blip.attr("embed")
            } else {
                blip.attr("r:embed")
            };
            let Some(target) = self.relationships.get(id).filter(|_| !id.is_empty()) else {
                self.document.warn("External, linked or unresolved images are omitted; no network requests are made.");
                continue;
            };
            if !self.package.has(target) {
                self.document.warn("Missing image parts are omitted.");
                continue;
            }
            let extent = container.child("extent");
            let width = extent.map_or(0.0, |n| xml::number(n.attr("cx"), 0.0) / EMU_PER_POINT);
            let height = extent.map_or(0.0, |n| xml::number(n.attr("cy"), 0.0) / EMU_PER_POINT);
            if width <= 0.0 || height <= 0.0 {
                self.document
                    .warn("Images with missing or invalid extents use a fallback size.");
            }
            if width > MAX_COORDINATE || height > MAX_COORDINATE {
                self.document
                    .warn("Oversized image extents are limited to 1200 points.");
            }
            if images.len() >= self.block_limit.count {
                return Err(Error::Limit(self.block_limit.message));
            }
            let width = if width > 0.0 {
                width.clamp(1.0, MAX_COORDINATE)
            } else {
                144.0
            };
            let height = if height > 0.0 {
                height.clamp(1.0, MAX_COORDINATE)
            } else {
                144.0
            };
            let layout = self.anchor_layout(container, width, height);
            let image_bounds = container.descendant("srcRect").and_then(|crop| {
                let Some(crop) = crop_values(crop) else {
                    self.document
                        .warn("Images with invalid crop bounds use the full image.");
                    return None;
                };
                // Mirror the PPTX crop projection: scale the image so only the
                // cropped region lands inside the element's destination rect.
                let width = width / (1.0 - crop.left - crop.right);
                let height = height / (1.0 - crop.top - crop.bottom);
                Some([
                    -crop.left * width,
                    -crop.top * height,
                    (1.0 - crop.left) * width,
                    (1.0 - crop.top) * height,
                ])
            });
            let mut element = Element {
                kind: ElementType::IMAGE,
                image: Some(target.clone()),
                width,
                height,
                padding: 0.0,
                image_bounds,
                ..Element::default()
            };
            layout.apply(&mut element);
            images.push(element);
            if layout.wrap_mode == WrapMode::Inline {
                self.document.warn("Inline images use separate flow blocks; surrounding layout and spacing are approximate.");
            }
        }
        if !found {
            self.document.warn("Unsupported drawings are omitted.");
        }
        Ok(images)
    }

    fn anchor_layout(&self, container: &Node, width: f32, height: f32) -> AnchorLayout {
        if container.name != "anchor" {
            return AnchorLayout::default();
        }
        let (wrap_mode, wrap_node) = parse_wrap_mode(container);
        let behind_doc = flag_attr(container.attr("behindDoc"));
        let dist_top = anchor_distance(container, wrap_node, "distT");
        let dist_bottom = anchor_distance(container, wrap_node, "distB");
        let dist_left = anchor_distance(container, wrap_node, "distL");
        let dist_right = anchor_distance(container, wrap_node, "distR");

        let content_left = self.effective_margin(self.document.margin_left);
        let content_width = self.flow_width();

        let (x, horizontal_align) = parse_position_h(
            container,
            width,
            content_left,
            content_width,
            self.document.width,
        );
        let y = parse_position_v(
            container,
            height,
            self.document.margin_top,
            self.document.margin_bottom,
            self.page_height,
        );

        AnchorLayout {
            x,
            y,
            wrap_mode,
            horizontal_align,
            behind_doc,
            dist_top,
            dist_bottom,
            dist_left,
            dist_right,
        }
    }
}

fn flag_attr(raw: &str) -> bool {
    raw == "1" || raw.eq_ignore_ascii_case("true")
}

fn anchor_distance(container: &Node, wrap_node: Option<&Node>, attr: &str) -> f32 {
    let raw = container
        .get_attr(attr)
        .or_else(|| wrap_node.and_then(|n| n.get_attr(attr)));
    let Some(raw) = raw.map(str::trim).filter(|s| !s.is_empty()) else {
        return 0.0;
    };
    (xml::number(raw, 0.0) / EMU_PER_POINT).clamp(0.0, MAX_COORDINATE)
}

fn parse_wrap_mode(container: &Node) -> (WrapMode, Option<&Node>) {
    if let Some(node) = container.child("wrapNone") {
        (WrapMode::None, Some(node))
    } else if let Some(node) = container.child("wrapTopAndBottom") {
        (WrapMode::TopAndBottom, Some(node))
    } else if let Some(node) = container.child("wrapTight") {
        (WrapMode::Tight, Some(node))
    } else if let Some(node) = container.child("wrapThrough") {
        (WrapMode::Through, Some(node))
    } else if let Some(node) = container.child("wrapSquare") {
        (WrapMode::Square, Some(node))
    } else {
        (WrapMode::Square, None)
    }
}

fn parse_position_h(
    container: &Node,
    width: f32,
    content_left: f32,
    content_width: f32,
    page_width: f32,
) -> (f32, u8) {
    let content_right = content_left + content_width;
    let max_x = (page_width - width).max(0.0);
    if let Some(pos_h) = container.child("positionH") {
        if let Some(align_node) = pos_h.child("align") {
            let align = align_node.text.trim().to_ascii_lowercase();
            return match align.as_str() {
                "left" | "inside" => (content_left.clamp(0.0, max_x), 1),
                "center" => (
                    (content_left + ((content_width - width) * 0.5).max(0.0)).clamp(0.0, max_x),
                    2,
                ),
                "right" | "outside" => (
                    (content_right - width).max(content_left).clamp(0.0, max_x),
                    3,
                ),
                _ => (content_left.clamp(0.0, max_x), 0),
            };
        }
        if let Some(offset_node) = pos_h.child("posOffset") {
            let offset_pt = xml::number(offset_node.text.trim(), 0.0) / EMU_PER_POINT;
            let base_x = match pos_h.attr("relativeFrom") {
                "page" | "leftMargin" => 0.0,
                "rightMargin" => content_right,
                _ => content_left,
            };
            return ((base_x + offset_pt).clamp(0.0, max_x), 0);
        }
    } else if flag_attr(container.attr("simplePos")) {
        if let Some(simple) = container.child("simplePos") {
            let x = (xml::number(simple.attr("x"), 0.0) / EMU_PER_POINT).clamp(0.0, max_x);
            return (x, 0);
        }
    }
    (content_left.clamp(0.0, max_x), 0)
}

fn parse_position_v(
    container: &Node,
    height: f32,
    margin_top: f32,
    margin_bottom: f32,
    page_height: f32,
) -> f32 {
    if let Some(pos_v) = container.child("positionV") {
        let relative = pos_v.attr("relativeFrom");
        if let Some(offset_node) = pos_v.child("posOffset") {
            let offset_pt = xml::number(offset_node.text.trim(), 0.0) / EMU_PER_POINT;
            let raw_y = match relative {
                "margin" | "topMargin" => margin_top + offset_pt,
                _ => offset_pt,
            };
            return raw_y.clamp(0.0, MAX_COORDINATE);
        }
        if let Some(align_node) = pos_v.child("align") {
            let align = align_node.text.trim().to_ascii_lowercase();
            let area_top = if matches!(relative, "margin" | "topMargin") {
                margin_top
            } else {
                0.0
            };
            let area_height = if matches!(relative, "page") {
                page_height
            } else if matches!(relative, "margin" | "topMargin") {
                (page_height - margin_top - margin_bottom).max(height)
            } else {
                return 0.0;
            };
            return match align.as_str() {
                "center" => {
                    (area_top + ((area_height - height) * 0.5).max(0.0)).clamp(0.0, MAX_COORDINATE)
                }
                "bottom" | "outside" => {
                    (area_top + (area_height - height).max(0.0)).clamp(0.0, MAX_COORDINATE)
                }
                _ => area_top.clamp(0.0, MAX_COORDINATE),
            };
        }
    } else if flag_attr(container.attr("simplePos")) {
        if let Some(simple) = container.child("simplePos") {
            return (xml::number(simple.attr("y"), 0.0) / EMU_PER_POINT).clamp(0.0, MAX_COORDINATE);
        }
    }
    0.0
}

const MIN_SOURCE_FRACTION: f32 = 0.001;

fn crop_values(node: &Node) -> Option<ImageCrop> {
    let crop = ImageCrop {
        left: crop_percent(node, "l")?,
        top: crop_percent(node, "t")?,
        right: crop_percent(node, "r")?,
        bottom: crop_percent(node, "b")?,
    };
    let source_width = 1.0 - crop.left - crop.right;
    let source_height = 1.0 - crop.top - crop.bottom;
    if source_width > MIN_SOURCE_FRACTION && source_height > MIN_SOURCE_FRACTION {
        Some(crop)
    } else {
        None
    }
}

fn crop_percent(node: &Node, attr: &str) -> Option<f32> {
    let Some(raw) = node.get_attr(attr) else {
        return Some(0.0);
    };
    let value = parse_crop_percent(raw)?;
    if (0.0..=1.0).contains(&value) {
        Some(value)
    } else {
        None
    }
}

fn parse_crop_percent(value: &str) -> Option<f32> {
    let value = value.trim();
    if value.is_empty() {
        return None;
    }
    let parsed = if let Some(percent) = value.strip_suffix('%') {
        percent.trim().parse::<f32>().ok()? / 100.0
    } else {
        value.parse::<f32>().ok()? / 100_000.0
    };
    if parsed.is_finite() {
        Some(parsed)
    } else {
        None
    }
}
