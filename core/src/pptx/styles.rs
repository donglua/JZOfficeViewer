use super::colors::Theme;
use super::geometry::points;
use crate::model::{Document, Element, ElementType, Path, PathCommand};
use crate::xml::Node;

pub(crate) struct Styles<'a> {
    pub doc: &'a mut Document,
    pub theme: &'a Theme,
}

impl Styles<'_> {
    pub fn drawing(&mut self, chain: &[&Node], element: &mut Element) -> bool {
        let mut preset = "rect";
        if chain.last().is_some_and(|n| n.name == "cxnSp") {
            preset = "line";
        }
        for shape in chain {
            if let Some(style) = shape.child("style") {
                if let Some(fill) = style.child("fillRef") {
                    element.fill = self.theme.fill_reference(fill, element.fill, self.doc);
                    element.fill_gradient = None;
                }
                if let Some(line) = style.child("lnRef") {
                    self.line_reference(element, line);
                }
                if style
                    .child("effectRef")
                    .is_some_and(|n| !matches!(n.attr("idx"), "" | "0"))
                {
                    self.doc.warn("PPTX theme effects are not supported.");
                }
            }
            if let Some(properties) = shape.child("spPr") {
                if properties.child("noFill").is_some() || properties.child("solidFill").is_some() {
                    element.fill_gradient = None;
                    element.fill = self.theme.fill(properties, element.fill, self.doc);
                } else if properties.child("gradFill").is_some() {
                    element.fill_gradient = self.theme.gradient(properties, self.doc);
                    if element.fill_gradient.is_none() {
                        self.doc.warn(
                            "PPTX unsupported or invalid shape gradient uses its fallback fill.",
                        );
                    }
                } else if ["pattFill", "blipFill", "grpFill"]
                    .iter()
                    .any(|name| properties.child(name).is_some())
                {
                    element.fill_gradient = None;
                    element.fill = self.theme.fill(properties, element.fill, self.doc);
                }
                if let Some(line) = properties.child("ln") {
                    self.line(element, line);
                }
                if let Some(geometry) = properties.child("prstGeom") {
                    element.paths.clear();
                    preset = geometry.attr("prst");
                    if preset == "roundRect" {
                        let size = [element.width, element.height];
                        match super::round_rect::radius(geometry, size) {
                            Some(0.0) => preset = "rect",
                            Some(radius) => {
                                element.paths.push(super::round_rect::path(size, radius));
                                preset = "path";
                            }
                            None => (),
                        }
                    } else if let Some(path) =
                        super::preset_geometry::path(geometry, [element.width, element.height])
                    {
                        element.paths.push(path);
                        preset = "path";
                    }
                }
                if properties.child("custGeom").is_some() {
                    if let Some(paths) =
                        super::path::parse(properties, [element.width, element.height])
                    {
                        element.paths = paths;
                        preset = "path";
                    } else {
                        element.paths.clear();
                        self.doc.warn("PPTX unsupported, invalid or excessive custom path was omitted; its text is retained.");
                        preset = "custom";
                    }
                }
            }
        }
        element.kind = match preset {
            "rect" => ElementType::RECT,
            "ellipse" => ElementType::ELLIPSE,
            "line" => ElementType::LINE,
            "path" => ElementType::PATH,
            _ => {
                self.doc
                    .warn("PPTX complex geometry is omitted; its text is retained.");
                return false;
            }
        };
        // 连接线箭头端点必须在此处编译：此时 kind 已定型为 LINE，
        // 生成箭头后整体改写为 PATH，且不会被上面的 match 覆盖。
        if preset == "line" {
            if let Some(line_node) = chain
                .iter()
                .rev()
                .find_map(|shape| shape.child("spPr").and_then(|p| p.child("ln")))
            {
                arrowheads(element, line_node);
            }
        }
        true
    }

    fn line_reference(&mut self, element: &mut Element, reference: &Node) {
        let index = reference.attr("idx").parse::<usize>().unwrap_or(0);
        if index == 0 {
            element.stroke = 0;
            return;
        }
        element.stroke = self.theme.color(reference, element.stroke, self.doc);
        if let Some(style) = self
            .theme
            .format_list("lnStyleLst")
            .and_then(|n| n.children.get(index - 1))
        {
            self.line(element, style);
        } else {
            self.doc
                .warn("Some PPTX theme line styles could not be resolved.");
        }
    }

    fn line(&mut self, element: &mut Element, node: &Node) {
        element.stroke = self.theme.fill(node, element.stroke, self.doc);
        if let Some(width) = points(node.attr("w")) {
            element.stroke_width = width.clamp(0.0, 1000.0);
        }
        element.stroke_dash = dash(node, element.stroke_width);
        if node.child("custDash").is_some() {
            self.doc
                .warn("PPTX custom line dash patterns are not supported.");
        }
    }
}

/// 将 `<a:prstDash val="...">` 换算为点线序列（单位 point，成对表示实线长度与间隔长度）。
///
/// 基准线宽取 `stroke_width` 的下限 1.0，避免极细线条生成退化的零长线段；
/// 未知取值一律按实线处理（返回空序列），保持对非规范文件的宽容。
fn dash(node: &Node, stroke_width: f32) -> Vec<f32> {
    let base = stroke_width.max(1.0);
    match node.child("prstDash").map_or("", |n| n.attr("val")) {
        "dot" | "sysDot" => vec![base, 2.0 * base],
        "dash" | "sysDash" => vec![4.0 * base, 3.0 * base],
        "lgDash" => vec![8.0 * base, 3.0 * base],
        "dashDot" | "sysDashDot" => vec![4.0 * base, 3.0 * base, base, 3.0 * base],
        "lgDashDot" => vec![8.0 * base, 3.0 * base, base, 3.0 * base],
        "lgDashDotDot" | "sysDashDotDot" => {
            vec![8.0 * base, 3.0 * base, base, 3.0 * base, base, 3.0 * base]
        }
        _ => Vec::new(),
    }
}

/// 箭头 `len` / `w` 属性到相对线宽的倍数。
fn arrow_scale(value: &str) -> f32 {
    match value {
        "sm" => 2.5,
        "lg" => 5.0,
        _ => 3.5,
    }
}

/// 将连接线 `headEnd` / `tailEnd` 编译为主干与端点箭头子路径。
///
/// 线长不足 1.0 或线条未描边（alpha 为 0）时保持原始 LINE，不生成退化箭头。
fn arrowheads(element: &mut Element, line: &Node) {
    let mut ends = Vec::new();
    for (node, at_start) in [
        (line.child("headEnd"), true),
        (line.child("tailEnd"), false),
    ] {
        let Some(end) = node else { continue };
        let kind = end.attr("type");
        if matches!(kind, "" | "none") {
            continue;
        }
        ends.push((kind, end.attr("len"), end.attr("w"), at_start));
    }
    if ends.is_empty() {
        return;
    }
    let (dx, dy) = (element.width, element.height);
    let length = (dx * dx + dy * dy).sqrt();
    if length <= 1.0 || element.stroke >> 24 == 0 {
        return;
    }
    let (ux, uy) = (dx / length, dy / length);
    let (nx, ny) = (-uy, ux);
    let scale = element.stroke_width.max(1.2);
    // 主干端点默认直达两端，被实心箭头覆盖时再内缩。
    let mut trunk_start = (0.0_f32, 0.0_f32);
    let mut trunk_end = (dx, dy);
    let mut arrows = Vec::with_capacity(ends.len());
    for (kind, len, width, at_start) in ends {
        let arrow_len = (arrow_scale(len) * scale).min(length * 0.45);
        let half = arrow_scale(width).max(0.5) * scale;
        // tip 锚定在真实线段端点（避免外伸穿入目标图形），基部沿 -sign * u 向线段内侧回缩。
        let (tip, inward) = if at_start {
            ((0.0_f32, 0.0_f32), 1.0_f32)
        } else {
            ((dx, dy), -1.0_f32)
        };
        let base = (
            tip.0 + inward * ux * arrow_len,
            tip.1 + inward * uy * arrow_len,
        );
        let arrow = match kind {
            // 开叉双翼线箭头：两翼从后撤的基线指向顶点 tip，主干略微内缩避免钝头刺出尖端。
            "arrow" => Path {
                fill: false,
                stroke: true,
                commands: vec![
                    PathCommand::Move([base.0 - nx * half, base.1 - ny * half]),
                    PathCommand::Line([tip.0, tip.1]),
                    PathCommand::Line([base.0 + nx * half, base.1 + ny * half]),
                ],
            },
            "diamond" => {
                let mid = (
                    tip.0 + inward * ux * arrow_len * 0.5,
                    tip.1 + inward * uy * arrow_len * 0.5,
                );
                Path {
                    fill: true,
                    stroke: false,
                    commands: vec![
                        PathCommand::Move([tip.0, tip.1]),
                        PathCommand::Line([mid.0 + nx * half, mid.1 + ny * half]),
                        PathCommand::Line([base.0, base.1]),
                        PathCommand::Line([mid.0 - nx * half, mid.1 - ny * half]),
                        PathCommand::Close,
                    ],
                }
            }
            "oval" => {
                // 圆点端点用四段三次贝塞尔近似整圆，圆心落在端点内侧半个半径处。
                let r = (arrow_len * 0.5).min(half).max(0.5);
                let center = (tip.0 + inward * ux * r, tip.1 + inward * uy * r);
                let c = r * 0.552_284_8;
                Path {
                    fill: true,
                    stroke: false,
                    commands: vec![
                        PathCommand::Move([center.0, center.1 - r]),
                        PathCommand::Cubic([
                            center.0 + c,
                            center.1 - r,
                            center.0 + r,
                            center.1 - c,
                            center.0 + r,
                            center.1,
                        ]),
                        PathCommand::Cubic([
                            center.0 + r,
                            center.1 + c,
                            center.0 + c,
                            center.1 + r,
                            center.0,
                            center.1 + r,
                        ]),
                        PathCommand::Cubic([
                            center.0 - c,
                            center.1 + r,
                            center.0 - r,
                            center.1 + c,
                            center.0 - r,
                            center.1,
                        ]),
                        PathCommand::Cubic([
                            center.0 - r,
                            center.1 - c,
                            center.0 - c,
                            center.1 - r,
                            center.0,
                            center.1 - r,
                        ]),
                        PathCommand::Close,
                    ],
                }
            }
            // triangle / stealth 统一按实心三角绘制。
            _ => Path {
                fill: true,
                stroke: false,
                commands: vec![
                    PathCommand::Move([tip.0, tip.1]),
                    PathCommand::Line([base.0 - nx * half, base.1 - ny * half]),
                    PathCommand::Line([base.0 + nx * half, base.1 + ny * half]),
                    PathCommand::Close,
                ],
            },
        };
        // 实心箭头与开叉箭头均需把主干端点向内收拢，避免粗线头刺穿箭头尖端。
        let inset_len = if arrow.fill {
            arrow_len * 0.7
        } else {
            (element.stroke_width * 0.5).min(arrow_len * 0.5)
        };
        let inset = (
            tip.0 + inward * ux * inset_len,
            tip.1 + inward * uy * inset_len,
        );
        if at_start {
            trunk_start = inset;
        } else {
            trunk_end = inset;
        }
        arrows.push(arrow);
    }
    let mut paths = vec![Path {
        fill: false,
        stroke: true,
        commands: vec![
            PathCommand::Move([trunk_start.0, trunk_start.1]),
            PathCommand::Line([trunk_end.0, trunk_end.1]),
        ],
    }];
    paths.extend(arrows);
    element.fill = element.stroke;
    element.kind = ElementType::PATH;
    element.paths = paths;
}
