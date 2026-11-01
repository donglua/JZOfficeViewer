use super::{Parser, MAX_COORDINATE};
use crate::model::{Element, ElementType};
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
            images.push(Element {
                kind: ElementType::IMAGE,
                image: Some(target.clone()),
                width: if width > 0.0 {
                    width.clamp(1.0, MAX_COORDINATE)
                } else {
                    144.0
                },
                height: if height > 0.0 {
                    height.clamp(1.0, MAX_COORDINATE)
                } else {
                    144.0
                },
                padding: 0.0,
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
