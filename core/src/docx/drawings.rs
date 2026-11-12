use super::{Parser, MAX_COORDINATE};
use crate::model::{Element, ElementType, ImageCrop};
use crate::xml::{self, Node};
use crate::{Error, Result};

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
            let width = extent.map_or(0.0, |n| xml::number(n.attr("cx"), 0.0) / 12700.0);
            let height = extent.map_or(0.0, |n| xml::number(n.attr("cy"), 0.0) / 12700.0);
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
            images.push(Element {
                kind: ElementType::IMAGE,
                image: Some(target.clone()),
                width,
                height,
                padding: 0.0,
                image_bounds,
                ..Element::default()
            });
            self.document.warn("Inline images use separate flow blocks; surrounding layout and spacing are approximate.");
        }
        if !found {
            self.document.warn("Unsupported drawings are omitted.");
        }
        Ok(images)
    }
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
