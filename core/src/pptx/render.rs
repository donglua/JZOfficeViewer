use super::colors::Theme;
use super::geometry::Bounds;
use super::inheritance;
use super::parts::Part;
use super::styles::Styles;
use super::text::Text;
use super::transform::{self, Transform};
use super::{flag, relation_id, Budget};
use crate::model::{Document, Element, ElementType, GradientFill, ImageCrop, Page, Paragraph};
use crate::xml::Node;
use crate::{Package, Result};

pub(super) struct Render<'a> {
    pub doc: &'a mut Document,
    pub theme: &'a Theme,
    pub pkg: &'a mut Package,
    pub budget: &'a mut Budget,
    pub defaults: Option<&'a Node>,
    pub layout: Option<&'a Node>,
    pub master: Option<&'a Node>,
    pub background_gradient: Option<GradientFill>,
}

#[derive(Clone, Copy)]
struct ShapeTree<'a> {
    part: &'a Part,
    inherited: bool,
    transform: Transform,
}

impl Render<'_> {
    pub fn background(&mut self, page: &mut Page, sources: [&Part; 3]) -> Result<()> {
        for part in sources {
            let Some(bg) = part.root.child("cSld").and_then(|n| n.child("bg")) else {
                continue;
            };
            if let Some(properties) = bg.child("bgPr") {
                let picture = properties
                    .child("blipFill")
                    .and_then(|n| n.child("blip"))
                    .and_then(|n| part.rels.get(relation_id(n, "embed")))
                    .filter(|p| self.pkg.has(p));
                if let Some(path) = picture {
                    let background = Element {
                        kind: ElementType::IMAGE,
                        width: page.width,
                        height: page.height,
                        image: Some(path.clone()),
                        ..Element::default()
                    };
                    self.emit(page, background, Transform::IDENTITY)?;
                } else if let Some(gradient) = self.theme.gradient(properties, self.doc) {
                    self.background_gradient = Some(gradient.clone());
                    let background = Element {
                        kind: ElementType::RECT,
                        width: page.width,
                        height: page.height,
                        fill_gradient: Some(gradient),
                        ..Element::default()
                    };
                    self.emit(page, background, Transform::IDENTITY)?;
                } else {
                    page.background = self.theme.fill(properties, page.background, self.doc);
                }
            } else if let Some(reference) = bg.child("bgRef") {
                page.background = self
                    .theme
                    .fill_reference(reference, page.background, self.doc);
            }
            return Ok(());
        }
        Ok(())
    }

    pub fn tree(&mut self, part: &Part, inherited: bool, page: &mut Page) -> Result<()> {
        super::unsupported::warn(&part.root, self.doc);
        let Some(tree) = inheritance::tree(&part.root) else {
            return Ok(());
        };
        self.shapes(
            tree,
            ShapeTree {
                part,
                inherited,
                transform: Transform::IDENTITY,
            },
            page,
        )
    }

    fn shapes(&mut self, tree: &Node, scope: ShapeTree<'_>, page: &mut Page) -> Result<()> {
        for shape in &tree.children {
            if scope.inherited && inheritance::placeholder(shape).is_some() {
                continue;
            }
            let hidden = shape
                .children
                .iter()
                .find(|n| n.name.starts_with("nv"))
                .and_then(|n| n.child("cNvPr"))
                .is_some_and(|n| flag(n.attr("hidden"), false));
            if hidden {
                continue;
            }
            match shape.name.as_str() {
                "nvGrpSpPr" | "grpSpPr" | "extLst" => continue,
                "grpSp" => {
                    self.budget.object()?;
                    if let Some(transform) = scope.transform.group(shape) {
                        if transform::flipped(shape) {
                            self.doc.warn("PPTX group flips are not supported.");
                        }
                        self.shapes(shape, ShapeTree { transform, ..scope }, page)?;
                    } else {
                        self.doc
                            .warn("PPTX groups with invalid or excessive transforms were omitted.");
                    }
                    continue;
                }
                "sp" | "cxnSp" | "pic" | "graphicFrame" => (),
                _ => {
                    self.doc.warn("Unsupported PPTX shape content was omitted.");
                    continue;
                }
            }
            let chain = if scope.inherited {
                vec![shape]
            } else {
                inheritance::chain(shape, self.layout, self.master)
            };
            let Some(bounds) = Bounds::parse(&chain) else {
                self.doc
                    .warn("PPTX shapes with missing or invalid absolute bounds were omitted.");
                continue;
            };
            let Some((bounds, transform)) = bounds.in_slide_units(scope.transform) else {
                self.doc
                    .warn("PPTX elements with excessive transformed bounds were omitted.");
                continue;
            };
            match shape.name.as_str() {
                "pic" => {
                    if let Some(element) = self.picture(scope.part, shape, bounds) {
                        self.emit(page, element, transform)?;
                    }
                }
                "graphicFrame" => {
                    for element in self.graphic(scope.part, shape, bounds)? {
                        self.emit(page, element, transform)?;
                    }
                }
                _ => {
                    let mut element = bounds.element(ElementType::RECT);
                    let supported = Styles {
                        doc: self.doc,
                        theme: self.theme,
                    }
                    .drawing(&chain, &mut element);
                    if chain
                        .iter()
                        .rev()
                        .find_map(|node| node.get_attr("useBgFill"))
                        .is_some_and(|value| flag(value, false))
                    {
                        element.fill = page.background;
                        element.fill_gradient = self.background_gradient.clone().map(|mut fill| {
                            fill.in_slide_space = true;
                            fill
                        });
                    }
                    if supported
                        && (element.fill != 0
                            || element.fill_gradient.is_some()
                            || element.stroke != 0
                            || shape.child("txBody").is_none())
                    {
                        self.emit(page, element, transform)?;
                    }
                    if let Some(body) = shape.child("txBody") {
                        if let Some(mut text) = bounds.text_element(&chain, self.doc) {
                            text.paragraphs = self.paragraphs(body, &chain)?;
                            if !text.paragraphs.is_empty() {
                                self.emit(page, text, transform)?;
                            }
                        } else {
                            self.doc
                                .warn("PPTX text with empty or excessive bounds was omitted.");
                        }
                    }
                }
            }
        }
        Ok(())
    }

    fn picture(&mut self, part: &Part, shape: &Node, bounds: Bounds) -> Option<Element> {
        let fill = shape.child("blipFill");
        let blip = fill.and_then(|n| n.child("blip"));
        let path = blip.and_then(|n| part.rels.get(relation_id(n, "embed")));
        let Some(path) = path.filter(|p| self.pkg.has(p)) else {
            self.doc
                .warn("PPTX linked or missing pictures were omitted.");
            return None;
        };
        let image_crop = fill
            .and_then(|n| n.child("srcRect"))
            .and_then(|crop| parse_image_crop(crop, self.doc));
        if fill.is_some_and(|n| n.child("tile").is_some())
            || blip.is_some_and(|n| !n.children.is_empty())
        {
            self.doc
                .warn("PPTX picture tiling and effects are not supported.");
        }
        if let Some(properties) = shape.child("spPr") {
            if properties.child("custGeom").is_some()
                || properties
                    .child("prstGeom")
                    .is_some_and(|n| n.attr("prst") != "rect")
            {
                self.doc.warn("PPTX picture masks use rectangular bounds.");
            }
        }
        let mut element = bounds.element(ElementType::IMAGE);
        element.image = Some(path.clone());
        element.image_crop = image_crop;
        Some(element)
    }

    pub fn paragraphs(&mut self, body: &Node, chain: &[&Node]) -> Result<Vec<Paragraph>> {
        Text {
            doc: self.doc,
            theme: self.theme,
            budget: self.budget,
            defaults: self.defaults,
            master: self.master,
            chain,
        }
        .read(body)
    }

    fn emit(&mut self, page: &mut Page, mut element: Element, transform: Transform) -> Result<()> {
        self.budget.object()?;
        self.budget.path_commands += element
            .paths
            .iter()
            .map(|path| path.commands.len())
            .sum::<usize>();
        if self.budget.path_commands > 100_000 {
            return Err(crate::Error::Limit(
                "PPTX exceeds 100000 custom path commands",
            ));
        }
        element.transform = transform.0;
        if !transform.accepts(&element) || !super::drawing::prepare(&mut element, page, self.doc) {
            self.doc
                .warn("PPTX elements with excessive transformed bounds were omitted.");
            return Ok(());
        }
        page.elements.push(element);
        Ok(())
    }
}

const MIN_SOURCE_FRACTION: f32 = 0.001;

fn parse_image_crop(crop: &Node, doc: &mut Document) -> Option<ImageCrop> {
    let Some(image_crop) = crop_values(crop) else {
        doc.warn("PPTX pictures with invalid crop bounds use the full image.");
        return None;
    };
    let source_width = 1.0 - image_crop.left - image_crop.right;
    let source_height = 1.0 - image_crop.top - image_crop.bottom;
    if source_width > MIN_SOURCE_FRACTION && source_height > MIN_SOURCE_FRACTION {
        Some(image_crop)
    } else {
        doc.warn("PPTX pictures with invalid crop bounds use the full image.");
        None
    }
}

fn crop_values(crop: &Node) -> Option<ImageCrop> {
    Some(ImageCrop {
        left: crop_percent(crop, "l")?,
        top: crop_percent(crop, "t")?,
        right: crop_percent(crop, "r")?,
        bottom: crop_percent(crop, "b")?,
    })
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
    parsed.is_finite().then_some(parsed)
}
