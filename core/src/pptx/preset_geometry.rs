use crate::model::{Path, PathCommand};
use crate::xml::Node;

/// 三次贝塞尔拟合圆弧的切向控制点系数（半圆等分四段时使用的经典常数）。
const KAPPA: f32 = 0.552_284_8;

/// 读取 `a:avLst` 中指定名称的调整值，返回归一化比例 `0.0..=1.0`。
///
/// 仅接受 `val <int>` 形式的公式；公式缺失时使用 `default`，
/// 公式非法（多余 token、非整数、超出 `min..=max`）时返回 `None`，
/// 由调用方将整个几何视为不可解析并沿用既有告警语义。
fn adj(geometry: &Node, name: &str, default: i32, min: i32, max: i32) -> Option<f32> {
    let guide = geometry
        .child("avLst")
        .and_then(|list| list.named("gd").find(|g| g.attr("name") == name));
    let value = match guide {
        Some(guide) => {
            let mut formula = guide.attr("fmla").split_whitespace();
            if formula.next()? != "val" {
                return None;
            }
            let value = formula.next()?.parse::<i32>().ok()?;
            if formula.next().is_some() {
                return None;
            }
            value
        }
        None => default,
    };
    // 先钳位到合法区间再归一化，避免极端值放大出非法坐标。
    let clamped = value.clamp(min, max);
    Some(clamped as f32 / 100_000.0)
}

/// 直线闭合多边形路径辅助：从首点 Move，其余 Line，最后 Close。
fn polygon(points: &[[f32; 2]]) -> Option<Vec<PathCommand>> {
    let (first, rest) = points.split_first()?;
    let mut commands = Vec::with_capacity(points.len() + 1);
    commands.push(PathCommand::Move(*first));
    for point in rest {
        commands.push(PathCommand::Line(*point));
    }
    commands.push(PathCommand::Close);
    Some(commands)
}

fn closed(commands: Vec<PathCommand>) -> Option<Path> {
    Some(Path {
        fill: true,
        stroke: true,
        commands,
    })
}

/// 方向箭头（右、左、上、下）：adj1 控制箭杆宽比，adj2 控制箭头长比。
fn arrow(name: &str, geometry: &Node, [width, height]: [f32; 2]) -> Option<Path> {
    let stem = adj(geometry, "adj1", 50_000, 0, 100_000)?;
    let head = adj(geometry, "adj2", 50_000, 0, 100_000)?;
    let points = match name {
        "rightArrow" => {
            let d = width.min(height);
            let half = height * stem / 2.0;
            let tip = width - d * head;
            vec![
                [0.0, height / 2.0 - half],
                [tip, height / 2.0 - half],
                [tip, 0.0],
                [width, height / 2.0],
                [tip, height],
                [tip, height / 2.0 + half],
                [0.0, height / 2.0 + half],
            ]
        }
        "leftArrow" => {
            let d = width.min(height);
            let half = height * stem / 2.0;
            let tip = d * head;
            vec![
                [width, height / 2.0 - half],
                [tip, height / 2.0 - half],
                [tip, 0.0],
                [0.0, height / 2.0],
                [tip, height],
                [tip, height / 2.0 + half],
                [width, height / 2.0 + half],
            ]
        }
        "upArrow" => {
            let d = width.min(height);
            let half = width * stem / 2.0;
            let tip = d * head;
            vec![
                [width / 2.0 - half, height],
                [width / 2.0 - half, tip],
                [0.0, tip],
                [width / 2.0, 0.0],
                [width, tip],
                [width / 2.0 + half, tip],
                [width / 2.0 + half, height],
            ]
        }
        _ => {
            // downArrow
            let d = width.min(height);
            let half = width * stem / 2.0;
            let tip = height - d * head;
            vec![
                [width / 2.0 - half, 0.0],
                [width / 2.0 - half, tip],
                [0.0, tip],
                [width / 2.0, height],
                [width, tip],
                [width / 2.0 + half, tip],
                [width / 2.0 + half, 0.0],
            ]
        }
    };
    closed(polygon(&points)?)
}

/// 双向对称箭头。
fn double_arrow(name: &str, geometry: &Node, [width, height]: [f32; 2]) -> Option<Path> {
    let stem = adj(geometry, "adj1", 50_000, 0, 100_000)?;
    let head = adj(geometry, "adj2", 50_000, 0, 100_000)?;
    let points = if name == "leftRightArrow" {
        let d = width.min(height);
        let half = height * stem / 2.0;
        let inset = d * head;
        vec![
            [0.0, height / 2.0],
            [inset, 0.0],
            [inset, height / 2.0 - half],
            [width - inset, height / 2.0 - half],
            [width - inset, 0.0],
            [width, height / 2.0],
            [width - inset, height],
            [width - inset, height / 2.0 + half],
            [inset, height / 2.0 + half],
            [inset, height],
        ]
    } else {
        // upDownArrow
        let d = width.min(height);
        let half = width * stem / 2.0;
        let inset = d * head;
        vec![
            [width / 2.0, 0.0],
            [width, inset],
            [width / 2.0 + half, inset],
            [width / 2.0 + half, height - inset],
            [width, height - inset],
            [width / 2.0, height],
            [0.0, height - inset],
            [width / 2.0 - half, height - inset],
            [width / 2.0 - half, inset],
            [0.0, inset],
        ]
    };
    closed(polygon(&points)?)
}

/// 星形：外径顶点与内径凹点交替连线闭合，`count` 为角数。
fn star([width, height]: [f32; 2], count: usize, inner: f32) -> Option<Path> {
    let (cx, cy) = (width / 2.0, height / 2.0);
    let (rx, ry) = (width / 2.0, height / 2.0);
    let mut points = Vec::with_capacity(count * 2);
    // 起始角指向正上方（-90°），与 Office 渲染方向一致。
    let start = -std::f32::consts::FRAC_PI_2;
    let step = std::f32::consts::PI / count as f32;
    for index in 0..(count * 2) {
        let angle = start + step * index as f32;
        let scale = if index % 2 == 0 { 1.0 } else { inner };
        points.push([cx + rx * scale * angle.cos(), cy + ry * scale * angle.sin()]);
    }
    closed(polygon(&points)?)
}

/// 跑道形框：两端半圆弧矩形（flowChartTerminator）。
fn terminator([width, height]: [f32; 2]) -> Option<Path> {
    let radius = height / 2.0;
    if width <= height {
        // 宽度不足以容纳两端半圆时退化为椭圆，保持几何合法。
        let rx = width / 2.0;
        let ry = height / 2.0;
        return closed(vec![
            PathCommand::Move([rx, 0.0]),
            PathCommand::Cubic([rx + rx * KAPPA, 0.0, width, ry - ry * KAPPA, width, ry]),
            PathCommand::Cubic([width, ry + ry * KAPPA, rx + rx * KAPPA, height, rx, height]),
            PathCommand::Cubic([rx - rx * KAPPA, height, 0.0, ry + ry * KAPPA, 0.0, ry]),
            PathCommand::Cubic([0.0, ry - ry * KAPPA, rx - rx * KAPPA, 0.0, rx, 0.0]),
            PathCommand::Close,
        ]);
    }
    let control = radius * KAPPA;
    let right = width - radius;
    closed(vec![
        PathCommand::Move([radius, 0.0]),
        PathCommand::Line([right, 0.0]),
        PathCommand::Cubic([right + control, 0.0, right + control, height, right, height]),
        PathCommand::Line([radius, height]),
        PathCommand::Cubic([radius - control, height, 0.0, height, radius - control, 0.0]),
        PathCommand::Close,
    ])
}

/// 文档形状：矩形主体 + 底部 S 型波浪线（flowChartDocument）。
fn document([width, height]: [f32; 2]) -> Option<Path> {
    // 波浪占据底部约四分之一高度，波谷先下后上，与 Word 文档图标一致。
    let wave = (height * 0.25).max(0.0);
    let baseline = height - wave;
    closed(vec![
        PathCommand::Move([0.0, 0.0]),
        PathCommand::Line([width, 0.0]),
        PathCommand::Line([width, baseline]),
        PathCommand::Cubic([
            width * 0.75,
            baseline + wave * 1.4,
            width * 0.25,
            baseline - wave * 0.4,
            0.0,
            height,
        ]),
        PathCommand::Close,
    ])
}

/// 矩形标注气泡：矩形主体 + 底部指向尖角（wedgeRectCallout）。
fn callout([width, height]: [f32; 2]) -> Option<Path> {
    // 主体占上部，尖角在底部中心偏左，样式接近 Office 默认标注。
    let body = height * 0.78;
    let tip_x = width * 0.28;
    closed(vec![
        PathCommand::Move([0.0, 0.0]),
        PathCommand::Line([width, 0.0]),
        PathCommand::Line([width, body]),
        PathCommand::Line([tip_x + width * 0.18, body]),
        PathCommand::Line([tip_x, height]),
        PathCommand::Line([tip_x - width * 0.04, body]),
        PathCommand::Line([0.0, body]),
        PathCommand::Close,
    ])
}

/// 顶部双圆角、底部直角的矩形（round2SameRect）。
fn round2_same_rect(geometry: &Node, [width, height]: [f32; 2]) -> Option<Path> {
    let ratio = adj(geometry, "adj1", 16_667, 0, 50_000)?;
    let radius = width.min(height) * ratio;
    let control = radius * KAPPA;
    closed(vec![
        PathCommand::Move([0.0, radius]),
        PathCommand::Cubic([0.0, radius - control, radius - control, 0.0, radius, 0.0]),
        PathCommand::Line([width - radius, 0.0]),
        PathCommand::Cubic([
            width - radius + control,
            0.0,
            width,
            radius - control,
            width,
            radius,
        ]),
        PathCommand::Line([width, height]),
        PathCommand::Line([0.0, height]),
        PathCommand::Close,
    ])
}

/// 生成预设几何路径；`None` 表示该预设不受支持或调整值非法。
pub(super) fn path(geometry: &Node, [width, height]: [f32; 2]) -> Option<Path> {
    let short = width.min(height);
    let commands = match geometry.attr("prst") {
        "triangle" => {
            let adjustment = adj(geometry, "adj", 50_000, 0, 100_000)?;
            return closed(vec![
                PathCommand::Move([0.0, height]),
                PathCommand::Line([width * adjustment, 0.0]),
                PathCommand::Line([width, height]),
                PathCommand::Close,
            ]);
        }
        "rtTriangle" => vec![
            PathCommand::Move([0.0, height]),
            PathCommand::Line([0.0, 0.0]),
            PathCommand::Line([width, height]),
            PathCommand::Close,
        ],
        "diamond" | "flowChartDecision" => vec![
            PathCommand::Move([0.0, height / 2.0]),
            PathCommand::Line([width / 2.0, 0.0]),
            PathCommand::Line([width, height / 2.0]),
            PathCommand::Line([width / 2.0, height]),
            PathCommand::Close,
        ],
        // 注意：`rect` 必须继续返回 None，由 styles.rs 映射为 ElementType::RECT，
        // 只有同为矩形语义的 flowChartProcess 需要生成显式路径。
        "flowChartProcess" => vec![
            PathCommand::Move([0.0, 0.0]),
            PathCommand::Line([width, 0.0]),
            PathCommand::Line([width, height]),
            PathCommand::Line([0.0, height]),
            PathCommand::Close,
        ],
        "parallelogram" | "flowChartData" => {
            let offset = short * adj(geometry, "adj", 25_000, 0, 100_000)?;
            return closed(polygon(&[
                [offset, 0.0],
                [width, 0.0],
                [width - offset, height],
                [0.0, height],
            ])?);
        }
        "trapezoid" => {
            let offset = short * adj(geometry, "adj", 25_000, 0, 100_000)?;
            return closed(polygon(&[
                [offset, 0.0],
                [width - offset, 0.0],
                [width, height],
                [0.0, height],
            ])?);
        }
        "pentagon" => {
            return closed(polygon(&[
                [width * 0.5, 0.0],
                [width, height * 0.38],
                [width * 0.81, height],
                [width * 0.19, height],
                [0.0, height * 0.38],
            ])?);
        }
        "hexagon" => {
            let inset = short * adj(geometry, "adj", 25_000, 0, 100_000)?;
            return closed(polygon(&[
                [inset, 0.0],
                [width - inset, 0.0],
                [width, height / 2.0],
                [width - inset, height],
                [inset, height],
                [0.0, height / 2.0],
            ])?);
        }
        "octagon" => {
            let cut = short * adj(geometry, "adj", 29_289, 0, 100_000)?;
            let (cw, ch) = ((width - cut).max(0.0), (height - cut).max(0.0));
            return closed(polygon(&[
                [cut, 0.0],
                [cw, 0.0],
                [width, cut],
                [width, ch],
                [cw, height],
                [cut, height],
                [0.0, ch],
                [0.0, cut],
            ])?);
        }
        "plus" | "mathPlus" => {
            let depth = short * adj(geometry, "adj", 25_000, 0, 50_000)?;
            let (left, right) = (depth, (width - depth).max(depth));
            let (top, bottom) = (depth, (height - depth).max(depth));
            return closed(polygon(&[
                [left, 0.0],
                [right, 0.0],
                [right, top],
                [width, top],
                [width, bottom],
                [right, bottom],
                [right, height],
                [left, height],
                [left, bottom],
                [0.0, bottom],
                [0.0, top],
                [left, top],
            ])?);
        }
        "snip1Rect" => {
            let cut = short * adj(geometry, "adj", 16_667, 0, 100_000)?;
            return closed(polygon(&[
                [0.0, 0.0],
                [(width - cut).max(0.0), 0.0],
                [width, cut],
                [width, height],
                [0.0, height],
            ])?);
        }
        "round2SameRect" => return round2_same_rect(geometry, [width, height]),
        "rightArrow" | "leftArrow" | "upArrow" | "downArrow" => {
            return arrow(geometry.attr("prst"), geometry, [width, height]);
        }
        "leftRightArrow" | "upDownArrow" => {
            return double_arrow(geometry.attr("prst"), geometry, [width, height]);
        }
        "chevron" => {
            let inset = (short * adj(geometry, "adj", 50_000, 0, 100_000)?).min(width);
            return closed(polygon(&[
                [0.0, 0.0],
                [(width - inset).max(0.0), 0.0],
                [width, height / 2.0],
                [(width - inset).max(0.0), height],
                [0.0, height],
                [inset, height / 2.0],
            ])?);
        }
        "homePlate" => {
            let inset = (short * adj(geometry, "adj", 50_000, 0, 100_000)?).min(width);
            return closed(polygon(&[
                [0.0, 0.0],
                [(width - inset).max(0.0), 0.0],
                [width, height / 2.0],
                [(width - inset).max(0.0), height],
                [0.0, height],
            ])?);
        }
        "notchedRightArrow" => {
            let stem = adj(geometry, "adj1", 50_000, 0, 100_000)?;
            let head = adj(geometry, "adj2", 50_000, 0, 100_000)?;
            let half = height * stem / 2.0;
            let tip = (width - short * head).max(0.0);
            let notch = (short * 0.12).min(width * 0.2);
            return closed(polygon(&[
                [0.0, height / 2.0 - half],
                [tip, height / 2.0 - half],
                [tip, 0.0],
                [width, height / 2.0],
                [tip, height],
                [tip, height / 2.0 + half],
                [notch, height / 2.0 + half],
                [0.0, height / 2.0],
                [notch, height / 2.0 - half],
            ])?);
        }
        "star4" => return star([width, height], 4, 0.38),
        "star5" => return star([width, height], 5, 0.382),
        "flowChartTerminator" => return terminator([width, height]),
        "flowChartDocument" => return document([width, height]),
        "wedgeRectCallout" => return callout([width, height]),
        _ => return None,
    };
    closed(commands)
}
