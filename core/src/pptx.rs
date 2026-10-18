mod chart;
mod chart_data;
mod colors;
mod drawing;
mod geometry;
mod gradient;
mod inheritance;
mod numbering;
mod parts;
mod path;
mod preset_geometry;
mod render;
mod round_rect;
mod styles;
mod table;
mod text;
mod text_fill;
mod text_style;
mod transform;
mod unsupported;

use crate::model::{Document, Kind, Page};
use crate::xml::Node;
use crate::{Error, Package, Result};
use colors::Theme;
use parts::{Cache, Part};
use render::Render;

#[derive(Default)]
struct Budget {
    objects: usize,
    text_bytes: usize,
    path_commands: usize,
}

impl Budget {
    fn object(&mut self) -> Result<()> {
        if self.objects >= 5000 {
            return Err(Error::Limit("PPTX exceeds 5000 elements and table cells"));
        }
        self.objects += 1;
        Ok(())
    }

    fn text(&mut self, bytes: usize) -> Result<()> {
        self.text_bytes = self.text_bytes.saturating_add(bytes);
        if self.text_bytes > 8 * 1024 * 1024 {
            return Err(Error::Limit("PPTX rendered text exceeds 8 MiB"));
        }
        Ok(())
    }
}

pub(crate) fn parse(pkg: &mut Package, main_part: &str) -> Result<Document> {
    let presentation = Part::read(pkg, main_part)?;
    if presentation.root.name != "presentation" {
        return Err(Error::Invalid("Invalid PPTX presentation part"));
    }
    let mut doc = Document::new(Kind::PPTX);
    let (width, height) = match presentation.root.child("sldSz") {
        Some(size) => (
            slide_dimension(size.attr("cx"))?,
            slide_dimension(size.attr("cy"))?,
        ),
        None => {
            doc.warn("Missing PPTX slide size; using 720 x 540 points.");
            (720.0, 540.0)
        }
    };
    doc.width = width;
    let ids = presentation
        .root
        .child("sldIdLst")
        .ok_or(Error::Invalid("PPTX has no slide list"))?;
    let count = ids.named("sldId").count();
    if count == 0 {
        return Err(Error::Invalid("PPTX has no slides"));
    }
    if count > 100 {
        return Err(Error::Limit("PPTX exceeds 100 slides"));
    }
    let mut cache = Cache::default();
    let default_theme = cache.related(pkg, Some(&presentation), "theme")?;
    let mut budget = Budget::default();
    for id in ids.named("sldId") {
        let path = presentation
            .rels
            .get(relation_id(id, "id"))
            .ok_or(Error::Invalid("Missing PPTX slide relationship"))?;
        let slide = Part::read(pkg, path)?;
        if slide.root.name != "sld" {
            return Err(Error::Invalid("Invalid PPTX slide part"));
        }
        let layout = cache.related(pkg, Some(&slide), "slideLayout")?;
        let master = cache.related(pkg, layout.as_deref(), "slideMaster")?;
        let theme_part = cache
            .related(pkg, master.as_deref(), "theme")?
            .or_else(|| default_theme.clone());
        let mut theme = Theme::new(theme_part, &mut doc);
        let layout_root = layout.as_deref().map(|p| &p.root);
        let master_root = master.as_deref().map(|p| &p.root);
        theme.set_mapping(&slide.root, layout_root, master_root);
        for part in [Some(&slide), layout.as_deref()].into_iter().flatten() {
            if pkg.related_by_type(&part.path, "themeOverride")?.is_some() {
                doc.warn("PPTX theme overrides are not supported.");
            }
        }
        let mut page = Page {
            width,
            height,
            background: 0xffffffff,
            elements: Vec::new(),
        };
        let mut renderer = Render {
            doc: &mut doc,
            theme: &theme,
            pkg,
            budget: &mut budget,
            defaults: presentation.root.child("defaultTextStyle"),
            layout: layout_root,
            master: master_root,
            background_gradient: None,
        };
        renderer.background(
            &mut page,
            [
                &slide,
                layout.as_deref().unwrap_or(&slide),
                master.as_deref().unwrap_or(&slide),
            ],
        )?;
        if flag(slide.root.attr("showMasterSp"), true) {
            if layout_root.is_none_or(|n| flag(n.attr("showMasterSp"), true)) {
                if let Some(part) = master.as_deref() {
                    renderer.tree(part, true, &mut page)?;
                }
            }
            if let Some(part) = layout.as_deref() {
                renderer.tree(part, true, &mut page)?;
            }
        }
        renderer.tree(&slide, false, &mut page)?;
        doc.pages.push(page);
    }
    Ok(doc)
}

fn slide_dimension(value: &str) -> Result<f32> {
    geometry::points(value)
        .filter(|v| *v > 0.0 && *v <= 14400.0)
        .ok_or(Error::Invalid("Invalid PPTX slide dimensions"))
}

fn relation_id<'a>(node: &'a Node, name: &str) -> &'a str {
    node.get_attr(&format!("r:{name}"))
        .unwrap_or_else(|| node.attr(name))
}

fn flag(value: &str, default: bool) -> bool {
    match value {
        "1" | "true" | "on" => true,
        "0" | "false" | "off" => false,
        _ => default,
    }
}
