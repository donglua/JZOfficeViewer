use super::{alternate, format, skipped, Parser, MAX_TEXT};
use crate::model::{Element, Paragraph, Run};
use crate::xml::Node;
use crate::{Error, Result};

impl Parser<'_> {
    pub(super) fn paragraph(&mut self, node: &Node, in_cell: bool) -> Result<Vec<Element>> {
        let (mut format, font) =
            self.styles
                .paragraph(node, &mut self.numbering, &mut self.document)?;
        if !in_cell {
            if self.last_contextual
                && format.contextual_spacing
                && !format.style_id.is_empty()
                && self.last_style_id.as_deref() == Some(&format.style_id)
            {
                if let Some(last_block) = self.document.blocks.last_mut() {
                    if let Some(prev_p) = last_block.paragraphs.last_mut() {
                        prev_p.after = 0.0;
                        format.paragraph.before = 0.0;
                    }
                }
            }
            self.last_style_id = Some(format.style_id.clone());
            self.last_contextual = format.contextual_spacing;
        }
        let paragraph = format.paragraph;
        let mut flow = Flow {
            current: paragraph.clone(),
            template: paragraph,
            elements: Vec::new(),
            width: self.flow_width(),
            in_cell,
            limit: if in_cell {
                100
            } else {
                self.block_limit
                    .count
                    .saturating_sub(self.document.blocks.len())
            },
            limit_message: self.block_limit.message,
            text_bytes: self.text_bytes,
        };
        self.inline(node, &font, &mut flow)?;
        if flow.elements.is_empty() && flow.current.runs.is_empty() {
            let mut mark = font;
            format::font(
                &mut mark,
                node.child("pPr").and_then(|n| n.child("rPr")),
                Some(&self.styles.theme_fonts),
            )?;
            if !mark.hidden {
                flow.text(mark.run("", &mut self.document))?;
            }
        }
        if !flow.current.runs.is_empty() {
            flow.flush()?;
        }
        self.text_bytes = flow.text_bytes;
        Ok(flow.elements)
    }

    fn inline(&mut self, parent: &Node, font: &format::Font, flow: &mut Flow) -> Result<()> {
        for node in &parent.children {
            match node.name.as_str() {
                "r" => {
                    let mut font = font.clone();
                    let properties = node.child("rPr");
                    let id = properties
                        .and_then(|n| n.child("rStyle"))
                        .map_or(self.styles.default_character.as_str(), |n| n.attr("val"));
                    for style in self.styles.chain(id, &mut self.document).iter().rev() {
                        format::font(
                            &mut font,
                            style.child("rPr"),
                            Some(&self.styles.theme_fonts),
                        )?;
                    }
                    format::font(&mut font, properties, Some(&self.styles.theme_fonts))?;
                    if font.hidden {
                        continue;
                    }
                    self.inline(node, &font, flow)?;
                }
                "t" => flow.text(font.run(&node.text, &mut self.document))?,
                "tab" | "ptab" => flow.text(font.run("\t", &mut self.document))?,
                "br" | "cr" => {
                    if matches!(node.attr("type"), "page" | "column") {
                        self.document
                            .warn("Page and column breaks are rendered as line breaks.");
                    }
                    flow.text(font.run("\n", &mut self.document))?;
                }
                "noBreakHyphen" => flow.text(font.run("\u{2011}", &mut self.document))?,
                "softHyphen" => flow.text(font.run("\u{ad}", &mut self.document))?,
                "drawing" => {
                    for image in self.drawings(node)? {
                        if flow.in_cell {
                            flow.cell_image(image)?;
                        } else {
                            flow.image(image)?;
                        }
                    }
                }
                "sdt" => {
                    if let Some(content) = node.child("sdtContent") {
                        self.inline(content, font, flow)?;
                    }
                }
                "AlternateContent" => {
                    if let Some(content) = alternate(node) {
                        self.inline(content, font, flow)?;
                    }
                }
                "sym" => self
                    .document
                    .warn("Symbol fonts are unsupported; symbols are omitted."),
                "pict" | "object" | "txbxContent" => {
                    if let Some(content) = node.descendant("txbxContent") {
                        if !flow.current.runs.is_empty() {
                            flow.current.after = 0.0;
                            flow.flush()?;
                        }
                        for paragraph in content.children.iter().filter(|n| n.name == "p") {
                            for block in self.paragraph(paragraph, flow.in_cell)? {
                                flow.push(block)?;
                            }
                        }
                    }
                }
                name if skipped(name) => (),
                _ => self.inline(node, font, flow)?,
            }
        }
        Ok(())
    }
}

struct Flow {
    template: Paragraph,
    current: Paragraph,
    elements: Vec<Element>,
    width: f32,
    in_cell: bool,
    limit: usize,
    limit_message: &'static str,
    text_bytes: usize,
}

impl Flow {
    fn text(&mut self, run: Run) -> Result<()> {
        self.text_bytes += run.text.len();
        if self.text_bytes > MAX_TEXT {
            return Err(Error::Limit("DOCX text exceeds 8 MiB"));
        }
        self.current.runs.push(run);
        Ok(())
    }

    fn image(&mut self, image: Element) -> Result<()> {
        if !self.current.runs.is_empty() || !self.current.bullet.is_empty() {
            self.current.after = 0.0;
            self.flush()?;
        }
        self.push(image)?;
        self.current = self.template.clone();
        self.current.before = 0.0;
        self.current.bullet.clear();
        Ok(())
    }

    fn cell_image(&mut self, image: Element) -> Result<()> {
        if !self.current.runs.is_empty() || !self.current.bullet.is_empty() {
            self.current.after = 0.0;
            self.flush()?;
        }
        let mut img_para = self.template.clone();
        img_para.image = image.image;
        img_para.image_width = Some(image.width);
        img_para.image_height = Some(image.height);
        self.push(Element {
            width: self.width,
            padding: 0.0,
            paragraphs: vec![img_para],
            ..Element::default()
        })?;
        self.current = self.template.clone();
        self.current.before = 0.0;
        self.current.bullet.clear();
        Ok(())
    }

    fn flush(&mut self) -> Result<()> {
        let paragraph = std::mem::replace(&mut self.current, self.template.clone());
        self.push(Element {
            width: self.width,
            padding: 0.0,
            paragraphs: vec![paragraph],
            ..Element::default()
        })
    }

    fn push(&mut self, element: Element) -> Result<()> {
        if self.elements.len() >= self.limit {
            return Err(Error::Limit(self.limit_message));
        }
        self.elements.push(element);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn docx_flow_rejects_exceeding_text_limit() {
        let mut flow = Flow {
            template: Paragraph::default(),
            current: Paragraph::default(),
            elements: Vec::new(),
            width: 500.0,
            in_cell: false,
            limit: 5000,
            limit_message: "DOCX exceeds 5000 flow blocks",
            text_bytes: 0,
        };
        let chunk = "a".repeat(1024 * 1024);
        let mut result = Ok(());
        for _ in 0..9 {
            result = flow.text(Run {
                text: chunk.clone(),
                ..Run::default()
            });
            if result.is_err() {
                break;
            }
        }
        assert!(matches!(
            result,
            Err(Error::Limit("DOCX text exceeds 8 MiB"))
        ));
    }
}
