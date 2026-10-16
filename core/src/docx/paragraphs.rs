use super::{alternate, format, skipped, Parser, MAX_BLOCKS, MAX_TEXT};
use crate::model::{Element, Paragraph, Run};
use crate::xml::Node;
use crate::{Error, Result};

impl Parser<'_> {
    pub(super) fn paragraph(&mut self, node: &Node, in_cell: bool) -> Result<Vec<Element>> {
        let (paragraph, font) = self.styles.paragraph(node, &mut self.document)?;
        let mut flow = Flow {
            current: paragraph.clone(),
            template: paragraph,
            elements: Vec::new(),
            width: self.document.width - 64.0,
            in_cell,
            limit: if in_cell {
                1
            } else {
                MAX_BLOCKS.saturating_sub(self.document.blocks.len())
            },
            text_bytes: self.text_bytes,
        };
        self.inline(node, &font, &mut flow)?;
        if flow.elements.is_empty() && flow.current.runs.is_empty() {
            let mut mark = font;
            format::font(&mut mark, node.child("pPr").and_then(|n| n.child("rPr")))?;
            flow.text(mark.run("", &mut self.document))?;
        }
        if !flow.current.runs.is_empty() || flow.elements.is_empty() {
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
                        format::font(&mut font, style.child("rPr"))?;
                    }
                    format::font(&mut font, properties)?;
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
                    if flow.in_cell {
                        self.document.warn("Images inside table cells are omitted.");
                    } else {
                        for image in self.drawings(node)? {
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
            return Err(Error::Limit("DOCX exceeds 5000 flow blocks"));
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
