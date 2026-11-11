use super::colors::Theme;
use super::inheritance::{level_defaults, text_style};
use super::numbering;
use super::text_style::{apply_autofit, TextStyle};
use super::Budget;
use crate::model::{Document, Paragraph, Run};
use crate::xml::Node;
use crate::{Error, Result};

pub(super) struct Text<'a> {
    pub doc: &'a mut Document,
    pub theme: &'a Theme,
    pub budget: &'a mut Budget,
    pub defaults: Option<&'a Node>,
    pub master: Option<&'a Node>,
    pub chain: &'a [&'a Node],
}

impl Text<'_> {
    pub fn read(&mut self, body: &Node) -> Result<Vec<Paragraph>> {
        let mut output = Vec::new();
        let mut numbering = [0_u32; 9];
        for paragraph in body.named("p") {
            let direct = paragraph.child("pPr");
            let level = direct.map_or(0, paragraph_level);
            let mut defaults = Vec::new();
            level_defaults(self.defaults, level, &mut defaults);
            level_defaults(
                self.master
                    .and_then(|n| n.child("txStyles"))
                    .and_then(|n| n.child(text_style(self.chain))),
                level,
                &mut defaults,
            );
            for shape in self.chain {
                if let Some(reference) = shape.child("style").and_then(|n| n.child("fontRef")) {
                    defaults.push(reference);
                }
                if let Some(shape_body) = shape.child("txBody") {
                    level_defaults(shape_body.child("lstStyle"), level, &mut defaults);
                    if !std::ptr::eq(shape_body, body) {
                        if let Some(properties) = shape_body
                            .named("p")
                            .filter_map(|p| p.child("pPr"))
                            .find(|p| paragraph_level(p) == level)
                        {
                            defaults.push(properties);
                        }
                    }
                }
            }
            if self.chain.is_empty() {
                level_defaults(body.child("lstStyle"), level, &mut defaults);
            }
            if let Some(direct) = direct {
                defaults.push(direct);
            }
            let mut base = Run {
                size: 18.0,
                color: self.theme.text_color(),
                ..Run::default()
            };
            let mut result = Paragraph {
                after: 0.0,
                ..Paragraph::default()
            };
            let mut bullet = None;
            let mut styles = TextStyle {
                doc: self.doc,
                theme: self.theme,
            };
            for properties in defaults {
                if properties.name == "fontRef" {
                    base.color = styles.theme.color(properties, base.color, styles.doc);
                    continue;
                }
                styles.paragraph(&mut result, properties);
                styles.run(&mut base, properties.child("defRPr"));
                for property in &properties.children {
                    if matches!(
                        property.name.as_str(),
                        "buNone" | "buChar" | "buAutoNum" | "buBlip"
                    ) {
                        bullet = Some(property);
                    }
                }
            }
            if let Some(bullet) = bullet {
                match bullet.name.as_str() {
                    "buChar" => result.bullet = format!("{} ", bullet.attr("char")),
                    "buAutoNum" => {
                        let counter = numbering
                            .get_mut(level)
                            .ok_or(Error::Invalid("Invalid PPTX list level"))?;
                        if *counter == 0 {
                            *counter = bullet
                                .attr("startAt")
                                .parse::<u32>()
                                .unwrap_or(1)
                                .clamp(1, 32767);
                        }
                        result.bullet = numbering::format(*counter, bullet.attr("type"))
                            .unwrap_or_else(|| {
                                styles.doc.warn("PPTX numbered lists use decimal numbers.");
                                format!("{counter}. ")
                            });
                        *counter += 1;
                    }
                    "buBlip" => styles.doc.warn("PPTX picture bullets are omitted."),
                    _ => (),
                }
            }
            for counter in numbering.iter_mut().skip(level + 1) {
                *counter = 0;
            }
            self.budget.text(result.bullet.len())?;
            for item in &paragraph.children {
                if !matches!(item.name.as_str(), "r" | "fld" | "br") {
                    continue;
                }
                let mut run = base.clone();
                if item.name == "br" {
                    run.text.push('\n');
                } else {
                    for segment in item.named("t") {
                        run.text.push_str(&segment.text);
                    }
                    if item.name == "fld" {
                        styles.doc.warn("PPTX fields use saved text values.");
                    }
                }
                styles.run(&mut run, item.child("rPr"));
                self.budget.text(run.text.len())?;
                result.runs.push(run);
            }
            if result.runs.is_empty() {
                styles.run(&mut base, paragraph.child("endParaRPr"));
                result.runs.push(base);
            }
            output.push(result);
        }
        apply_autofit(&mut output, body, self.chain);
        Ok(output)
    }
}

fn paragraph_level(node: &Node) -> usize {
    node.attr("lvl").parse::<usize>().unwrap_or(0).min(8)
}
