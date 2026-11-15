use super::{alternate, Parser, MAX_COORDINATE};
use crate::model::{Element, ElementType, ImageCrop, Paragraph, VerticalAlignment, WrapMode};
use crate::xml::{self, Node};
use crate::{Error, Result};

const EMU_PER_POINT: f32 = 12700.0;
const MAX_GROUP_DEPTH: usize = 16;

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
        let mut elements = Vec::new();
        let mut found = false;
        for child in &node.children {
            let container = if child.name == "AlternateContent" {
                let Some(chosen) = alternate(child) else {
                    continue;
                };
                if let Some(drawing) = chosen.child("drawing") {
                    for nested in &drawing.children {
                        if matches!(nested.name.as_str(), "inline" | "anchor") {
                            found = true;
                            self.parse_container(nested, &mut elements)?;
                        }
                    }
                    continue;
                }
                chosen
            } else {
                child
            };
            if !matches!(container.name.as_str(), "inline" | "anchor") {
                continue;
            }
            found = true;
            self.parse_container(container, &mut elements)?;
        }
        if !found {
            self.document.warn("Unsupported drawings are omitted.");
        }
        Ok(elements)
    }

    fn parse_container(&mut self, container: &Node, out: &mut Vec<Element>) -> Result<()> {
        let wgp = container.descendant("wgp");
        let wsp = if wgp.is_none() {
            container.descendant("wsp")
        } else {
            None
        };
        let pic_blip = if wgp.is_none() && wsp.is_none() {
            container.descendant("blip")
        } else {
            None
        };
        if wgp.is_none() && wsp.is_none() && pic_blip.is_none() {
            self.document
                .warn("Non-image drawings, charts and diagrams are omitted.");
            return Ok(());
        }

        let (width, height) = self.container_extent(container, wgp, wsp);
        let layout = self.anchor_layout(container, width, height);

        if let Some(group) = wgp {
            let mut group_elements = Vec::new();
            self.parse_wpg_children(group, [0.0, 0.0, width, height], 0, &mut group_elements)?;
            self.push_group_elements(group_elements, layout, height, out)?;
        } else if let Some(shape) = wsp {
            if let Some(mut element) = self.parse_wsp(shape, width, height)? {
                layout.apply(&mut element);
                self.push_drawing_element(element, out)?;
            }
        } else if let Some(blip) = pic_blip {
            let src_rect = container.descendant("srcRect");
            if let Some(mut element) = self.resolve_image_element(blip, src_rect, width, height) {
                layout.apply(&mut element);
                self.push_drawing_element(element, out)?;
                if layout.wrap_mode == WrapMode::Inline {
                    self.document.warn("Inline images use separate flow blocks; surrounding layout and spacing are approximate.");
                }
            }
        }
        Ok(())
    }

    fn push_drawing_element(&self, element: Element, out: &mut Vec<Element>) -> Result<()> {
        if out.len() >= self.block_limit.count {
            return Err(Error::Limit(self.block_limit.message));
        }
        out.push(element);
        Ok(())
    }

    fn push_group_elements(
        &self,
        mut items: Vec<Element>,
        layout: AnchorLayout,
        group_height: f32,
        out: &mut Vec<Element>,
    ) -> Result<()> {
        let count = items.len();
        if count == 0 {
            return Ok(());
        }
        if count == 1 {
            if let Some(mut item) = items.pop() {
                let is_full_width =
                    item.x.abs() < 0.5 && (item.width - self.flow_width()).abs() < 0.5;
                item.x += layout.x;
                item.y += layout.y;
                item.wrap_mode = layout.wrap_mode;
                item.horizontal_align = if is_full_width || item.x == layout.x {
                    layout.horizontal_align
                } else {
                    0
                };
                item.behind_doc = layout.behind_doc;
                item.dist_top = layout.dist_top;
                item.dist_bottom = layout.dist_bottom;
                item.dist_left = layout.dist_left;
                item.dist_right = layout.dist_right;
                self.push_drawing_element(item, out)?;
            }
            return Ok(());
        }

        let is_stacked_group =
            matches!(layout.wrap_mode, WrapMode::TopAndBottom | WrapMode::Inline);
        for (idx, mut item) in items.into_iter().enumerate() {
            let mapped_y = item.y;
            let mapped_h = item.height;
            item.x += layout.x;
            item.horizontal_align = 0;
            item.behind_doc = layout.behind_doc;
            if is_stacked_group {
                let is_last = idx + 1 == count;
                if is_last {
                    item.y = layout.y + mapped_y;
                    item.wrap_mode = WrapMode::TopAndBottom;
                    item.dist_top = layout.dist_top + mapped_y;
                    item.dist_bottom =
                        (group_height - mapped_y - mapped_h).max(0.0) + layout.dist_bottom;
                } else {
                    item.y = layout.y + layout.dist_top + mapped_y;
                    item.wrap_mode = WrapMode::None;
                }
            } else {
                item.y = layout.y + mapped_y;
                item.wrap_mode = layout.wrap_mode;
                item.dist_top = layout.dist_top;
                item.dist_bottom = layout.dist_bottom;
                item.dist_left = layout.dist_left;
                item.dist_right = layout.dist_right;
            }
            self.push_drawing_element(item, out)?;
        }
        Ok(())
    }

    fn container_extent(
        &mut self,
        container: &Node,
        wgp: Option<&Node>,
        wsp: Option<&Node>,
    ) -> (f32, f32) {
        let mut extent = container.child("extent");
        if extent.is_none() {
            extent = wgp
                .and_then(|g| g.child("grpSpPr"))
                .and_then(|p| p.child("xfrm"))
                .and_then(|x| x.child("ext"))
                .or_else(|| {
                    wsp.and_then(|s| s.child("spPr"))
                        .and_then(|p| p.child("xfrm"))
                        .and_then(|x| x.child("ext"))
                });
        }
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
        (width, height)
    }

    fn resolve_image_element(
        &mut self,
        blip: &Node,
        src_rect: Option<&Node>,
        width: f32,
        height: f32,
    ) -> Option<Element> {
        let id = if blip.attr("r:embed").is_empty() {
            blip.attr("embed")
        } else {
            blip.attr("r:embed")
        };
        let Some(target) = self.relationships.get(id).filter(|_| !id.is_empty()) else {
            self.document.warn(
                "External, linked or unresolved images are omitted; no network requests are made.",
            );
            return None;
        };
        if !self.package.has(target) {
            self.document.warn("Missing image parts are omitted.");
            return None;
        }
        let image_bounds = src_rect.and_then(|crop| {
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
        Some(Element {
            kind: ElementType::IMAGE,
            image: Some(target.clone()),
            width,
            height,
            padding: 0.0,
            image_bounds,
            ..Element::default()
        })
    }

    fn parse_wsp(&mut self, wsp: &Node, width: f32, height: f32) -> Result<Option<Element>> {
        let sp_pr = wsp.child("spPr");
        let blip_fill = sp_pr.and_then(|sp| sp.child("blipFill"));
        let mut has_image_fill = false;
        let mut supported = true;
        let mut element = if let Some(blip) = blip_fill.and_then(|bf| bf.child("blip")) {
            let src_rect = blip_fill.and_then(|bf| bf.child("srcRect"));
            if let Some(mut img_el) = self.resolve_image_element(blip, src_rect, width, height) {
                has_image_fill = true;
                // Preserve line stroke without letting Styles::drawing warn on blipFill.
                if let Some(ln) = sp_pr.and_then(|sp| sp.child("ln")) {
                    img_el.stroke = self.styles.theme.fill(ln, 0, &mut self.document);
                    let line_w = xml::number(ln.attr("w"), 12700.0) / EMU_PER_POINT;
                    img_el.stroke_width = line_w.clamp(0.0, 1000.0);
                }
                img_el
            } else {
                return Ok(None);
            }
        } else {
            let mut el = Element {
                width,
                height,
                padding: 4.0,
                ..Element::default()
            };
            supported = {
                let mut pptx_styles = crate::pptx::styles::Styles {
                    doc: &mut self.document,
                    theme: &self.styles.theme,
                };
                pptx_styles.drawing(&[wsp], &mut el)
            };
            el
        };

        if let Some(xfrm) = sp_pr.and_then(|sp| sp.child("xfrm")) {
            element.rotation = (xml::number(xfrm.attr("rot"), 0.0) / 60000.0) % 360.0;
            element.flip_h = flag_attr(xfrm.attr("flipH"));
            element.flip_v = flag_attr(xfrm.attr("flipV"));
        }
        crate::pptx::drawing::prepare_local(&mut element);

        self.apply_wsp_textbox(wsp, &mut element, has_image_fill)?;

        if !supported && !has_image_fill {
            if element.paragraphs.is_empty() {
                return Ok(None);
            }
            element.kind = ElementType::TEXT;
            element.fill = 0;
            element.fill_gradient = None;
            element.stroke = 0;
            element.paths.clear();
        }
        Ok(Some(element))
    }

    fn apply_wsp_textbox(
        &mut self,
        wsp: &Node,
        element: &mut Element,
        has_image_fill: bool,
    ) -> Result<()> {
        if let Some(body_pr) = wsp.child("bodyPr") {
            let left = body_inset(body_pr, "lIns", 7.2);
            let right = body_inset(body_pr, "rIns", 7.2);
            let top = body_inset(body_pr, "tIns", 3.6);
            let bottom = body_inset(body_pr, "bIns", 3.6);
            let avg_inset = (left + right + top + bottom) * 0.25;
            let max_pad = (element.width.min(element.height) * 0.45).max(0.0);
            if !has_image_fill {
                element.padding = avg_inset.clamp(0.0, max_pad);
            }
            if let Some(anchor) = body_pr.get_attr("anchor") {
                element.vertical_alignment = match anchor {
                    "ctr" => VerticalAlignment::Center,
                    "b" => VerticalAlignment::Bottom,
                    _ => VerticalAlignment::Top,
                };
            }
            if body_pr.attr("wrap") == "none" {
                element.text_wrap = false;
            }
        }

        let Some(content) = wsp.child("txbx").and_then(|t| t.child("txbxContent")) else {
            return Ok(());
        };
        let mut paragraphs: Vec<Paragraph> = Vec::new();
        for child in &content.children {
            if child.name == "p" {
                for mut block in self.paragraph(child, true)? {
                    paragraphs.append(&mut block.paragraphs);
                }
            }
        }
        if !paragraphs.is_empty() {
            if let Some(font_ref) = wsp.child("style").and_then(|s| s.child("fontRef")) {
                if element.fill != 0 && !font_ref.children.is_empty() {
                    let theme_text_color =
                        self.styles
                            .theme
                            .color(font_ref, 0xff20_2124, &mut self.document);
                    let any_explicit_color = content
                        .children
                        .iter()
                        .filter(|n| n.name == "p")
                        .any(|p| p.descendant("color").is_some());
                    if !any_explicit_color {
                        for para in &mut paragraphs {
                            for run in &mut para.runs {
                                if run.color == 0xff20_2124 {
                                    run.color = theme_text_color;
                                }
                            }
                        }
                    }
                }
            }
            element.paragraphs = paragraphs;
        }
        Ok(())
    }

    fn parse_wpg_children(
        &mut self,
        wgp: &Node,
        target_box: [f32; 4],
        depth: usize,
        out: &mut Vec<Element>,
    ) -> Result<()> {
        if depth > MAX_GROUP_DEPTH {
            return Ok(());
        }
        let [parent_x, parent_y, parent_w, parent_h] = target_box;
        if parent_w <= 0.0 || parent_h <= 0.0 {
            return Ok(());
        }
        let xfrm = wgp.child("grpSpPr").and_then(|p| p.child("xfrm"));
        let (ch_x, ch_y, ch_w, ch_h) = group_child_space(xfrm, parent_w, parent_h);
        if ch_w <= 0.0 || ch_h <= 0.0 {
            return Ok(());
        }
        let sx = parent_w / ch_w;
        let sy = parent_h / ch_h;

        for child in &wgp.children {
            if out.len() >= self.block_limit.count {
                return Err(Error::Limit(self.block_limit.message));
            }
            match child.name.as_str() {
                "wsp" => {
                    let Some([cx, cy, cw, ch]) =
                        xfrm_box(child.child("spPr").and_then(|p| p.child("xfrm")))
                    else {
                        continue;
                    };
                    let mapped_x = parent_x + (cx - ch_x) * sx;
                    let mapped_y = parent_y + (cy - ch_y) * sy;
                    let mapped_w = (cw * sx).clamp(1.0, MAX_COORDINATE);
                    let mapped_h = (ch * sy).clamp(1.0, MAX_COORDINATE);
                    if let Some(mut el) = self.parse_wsp(child, mapped_w, mapped_h)? {
                        el.x = mapped_x;
                        el.y = mapped_y;
                        out.push(el);
                    }
                }
                "pic" => {
                    let Some([cx, cy, cw, ch]) =
                        xfrm_box(child.child("spPr").and_then(|p| p.child("xfrm")))
                    else {
                        continue;
                    };
                    let mapped_x = parent_x + (cx - ch_x) * sx;
                    let mapped_y = parent_y + (cy - ch_y) * sy;
                    let mapped_w = (cw * sx).clamp(1.0, MAX_COORDINATE);
                    let mapped_h = (ch * sy).clamp(1.0, MAX_COORDINATE);
                    if let Some(blip) = child.descendant("blip") {
                        let src_rect = child.descendant("srcRect");
                        if let Some(mut el) =
                            self.resolve_image_element(blip, src_rect, mapped_w, mapped_h)
                        {
                            el.x = mapped_x;
                            el.y = mapped_y;
                            out.push(el);
                        }
                    }
                }
                "wgp" => {
                    let Some([cx, cy, cw, ch]) =
                        xfrm_box(child.child("grpSpPr").and_then(|p| p.child("xfrm")))
                    else {
                        continue;
                    };
                    let mapped_box = [
                        parent_x + (cx - ch_x) * sx,
                        parent_y + (cy - ch_y) * sy,
                        (cw * sx).clamp(1.0, MAX_COORDINATE),
                        (ch * sy).clamp(1.0, MAX_COORDINATE),
                    ];
                    self.parse_wpg_children(child, mapped_box, depth + 1, out)?;
                }
                _ => (),
            }
        }
        Ok(())
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

fn body_inset(body_pr: &Node, attr: &str, default: f32) -> f32 {
    body_pr
        .get_attr(attr)
        .filter(|s| !s.trim().is_empty())
        .map_or(default, |v| {
            (xml::number(v, default * EMU_PER_POINT) / EMU_PER_POINT).max(0.0)
        })
}

fn xfrm_box(xfrm: Option<&Node>) -> Option<[f32; 4]> {
    let xfrm = xfrm?;
    let off = xfrm.child("off")?;
    let ext = xfrm.child("ext")?;
    let x = xml::number(off.attr("x"), 0.0) / EMU_PER_POINT;
    let y = xml::number(off.attr("y"), 0.0) / EMU_PER_POINT;
    let w = xml::number(ext.attr("cx"), 0.0) / EMU_PER_POINT;
    let h = xml::number(ext.attr("cy"), 0.0) / EMU_PER_POINT;
    if w <= 0.0 || h <= 0.0 || !x.is_finite() || !y.is_finite() {
        return None;
    }
    Some([x, y, w, h])
}

fn group_child_space(
    xfrm: Option<&Node>,
    fallback_w: f32,
    fallback_h: f32,
) -> (f32, f32, f32, f32) {
    if let Some(xfrm) = xfrm {
        if let (Some(off), Some(ext)) = (xfrm.child("chOff"), xfrm.child("chExt")) {
            let cx = xml::number(off.attr("x"), 0.0) / EMU_PER_POINT;
            let cy = xml::number(off.attr("y"), 0.0) / EMU_PER_POINT;
            let cw = xml::number(ext.attr("cx"), 0.0) / EMU_PER_POINT;
            let ch = xml::number(ext.attr("cy"), 0.0) / EMU_PER_POINT;
            if cw > 0.0 && ch > 0.0 {
                return (cx, cy, cw, ch);
            }
        }
        if let Some([x, y, w, h]) = xfrm_box(Some(xfrm)) {
            return (x, y, w, h);
        }
    }
    (0.0, 0.0, fallback_w, fallback_h)
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
