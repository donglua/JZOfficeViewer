use crate::xml::Node;

pub(super) struct Series<'a> {
    pub node: &'a Node,
    pub values: Vec<Option<f64>>,
    pub categories: Vec<Option<&'a str>>,
    pub dates: Option<Vec<Option<f64>>>,
    pub name: String,
}

#[derive(Clone, Copy, PartialEq)]
pub(super) enum ChartType {
    Line,
    Column,
    /// 横向条形图（`barChart` 且 `barDir="bar"`）
    Bar,
    /// 饼图（`hole_ratio == 0.0`）与环形图（`hole_ratio > 0.0`）
    Pie {
        hole_ratio: f32,
    },
}

pub(super) struct Chart<'a> {
    pub node: &'a Node,
    pub plot: &'a Node,
    /// 分类轴；饼图与环形图没有坐标轴，此时为 `None`。
    pub x_axis: Option<&'a Node>,
    /// 数值轴；饼图与环形图没有坐标轴，此时为 `None`。
    pub y_axis: Option<&'a Node>,
    pub series: Vec<Series<'a>>,
    pub x_range: (f64, f64),
    pub y_range: (f64, f64),
    pub y_step: f64,
    pub blanks: &'a str,
    pub date1904: bool,
    pub chart_type: ChartType,
}

pub(super) fn value<'a>(node: &'a Node, name: &str) -> &'a str {
    node.child(name).map_or("", |n| n.attr("val"))
}

pub(super) fn numeric(text: &str) -> Option<f64> {
    text.parse::<f64>()
        .ok()
        .filter(|n| n.is_finite() && n.abs() <= 1e100)
}

fn cache(parent: &Node) -> Option<Vec<Option<&str>>> {
    let node = ["numRef", "strRef"]
        .iter()
        .find_map(|name| parent.child(name))
        .and_then(|n| n.child("numCache").or_else(|| n.child("strCache")))
        .or_else(|| parent.child("numLit"))
        .or_else(|| parent.child("strLit"))?;
    let count = value(node, "ptCount").parse::<usize>().ok()?;
    if count == 0 || count > 2048 {
        return None;
    }
    let mut points = vec![None; count];
    for point in node.named("pt") {
        let index = point.attr("idx").parse::<usize>().ok()?;
        let slot = points.get_mut(index)?;
        if slot.is_some() {
            return None;
        }
        *slot = Some(point.child("v")?.text.as_str());
    }
    Some(points)
}

pub(super) fn text(node: &Node) -> String {
    if let Some(values) = cache(node) {
        return values.into_iter().flatten().collect::<Vec<_>>().join(" ");
    }
    if let Some(value) = node.child("v") {
        return value.text.clone();
    }
    fn append(node: &Node, result: &mut String) {
        if node.name == "t" {
            result.push_str(&node.text);
        }
        for child in &node.children {
            append(child, result);
        }
    }
    let mut result = String::new();
    append(node, &mut result);
    result
}

impl<'a> Chart<'a> {
    pub fn parse(root: &'a Node) -> Option<Self> {
        if root.name != "chartSpace" {
            return None;
        }
        let node = root.child("chart")?;
        let plot = node.child("plotArea")?;
        let charts: Vec<_> = plot
            .children
            .iter()
            .filter(|n| n.name.ends_with("Chart"))
            .collect();
        if charts.len() != 1 {
            return None;
        }
        let chart_node = charts[0];
        let chart_type = match chart_node.name.as_str() {
            "lineChart" => {
                if !matches!(value(chart_node, "grouping"), "" | "standard") {
                    return None;
                }
                ChartType::Line
            }
            "barChart" => {
                if !matches!(value(chart_node, "grouping"), "" | "clustered" | "standard") {
                    return None;
                }
                match value(chart_node, "barDir") {
                    "col" => ChartType::Column,
                    "bar" => ChartType::Bar,
                    _ => return None,
                }
            }
            "pieChart" => ChartType::Pie { hole_ratio: 0.0 },
            "doughnutChart" => ChartType::Pie {
                hole_ratio: hole_ratio(chart_node),
            },
            _ => return None,
        };
        // 饼图与环形图不依赖坐标轴，缺少 catAx / valAx 也应正常渲染。
        let no_axes = matches!(chart_type, ChartType::Pie { .. });
        let axes: Vec<_> = plot
            .children
            .iter()
            .filter(|n| n.name.ends_with("Ax"))
            .collect();
        // 饼图/环形图允许完全没有坐标轴；其余图表要求分类轴与数值轴各一。
        let (x_axis, y_axis) = if no_axes && axes.is_empty() {
            (None, None)
        } else {
            if axes.len() != 2 {
                return None;
            }
            for axis in &axes {
                let id = value(axis, "axId");
                if id.is_empty() || !chart_node.named("axId").any(|n| n.attr("val") == id) {
                    return None;
                }
                if axis
                    .child("scaling")
                    .is_some_and(|n| n.child("logBase").is_some())
                    || axis.child("dispUnits").is_some()
                {
                    return None;
                }
            }
            (
                Some(
                    *axes
                        .iter()
                        .find(|n| matches!(n.name.as_str(), "catAx" | "dateAx"))?,
                ),
                Some(*axes.iter().find(|n| n.name == "valAx")?),
            )
        };
        let blanks = match value(node, "dispBlanksAs") {
            "" | "gap" => "gap",
            "zero" => "zero",
            "span" => "span",
            _ => return None,
        };
        let mut series = Vec::new();
        let mut total = 0;
        for source in chart_node.named("ser") {
            if series.len() >= 8 {
                return None;
            }
            let raw_values = cache(source.child("val")?)?;
            total += raw_values.len();
            if total > 4096 {
                return None;
            }
            let mut values = Vec::new();
            for raw in raw_values {
                values.push(match raw {
                    None | Some("" | "#N/A") => None,
                    Some(raw) => Some(numeric(raw)?),
                });
            }
            if !values.iter().any(Option::is_some) {
                return None;
            }
            let categories = match source.child("cat") {
                Some(cat) => cache(cat)?,
                None => (0..values.len()).map(|_| None).collect(),
            };
            if categories.len() != values.len() {
                return None;
            }
            let dates = if x_axis.is_some_and(|n| n.name == "dateAx") {
                Some(
                    categories
                        .iter()
                        .zip(&values)
                        .map(|(raw, y)| match raw {
                            Some(raw) => numeric(raw).map(Some),
                            None if y.is_none() => Some(None),
                            None => None,
                        })
                        .collect::<Option<Vec<_>>>()?,
                )
            } else {
                None
            };
            series.push(Series {
                node: source,
                values,
                categories,
                dates,
                name: source.child("tx").map(text).unwrap_or_default(),
            });
        }
        if series.is_empty() {
            return None;
        }
        series.sort_by_key(|s| value(s.node, "order").parse::<usize>().unwrap_or(0));
        let mut xs = Vec::new();
        let mut ys = Vec::new();
        for series in &series {
            for (i, y) in series.values.iter().enumerate() {
                if let Some(x) = series.x(i) {
                    xs.push(x);
                }
                if let Some(y) = y.or((blanks == "zero").then_some(0.0)) {
                    ys.push(y);
                }
            }
        }
        if matches!(chart_type, ChartType::Column | ChartType::Bar)
            && !ys.is_empty()
            && ys.iter().all(|&y| y >= 0.0)
        {
            ys.push(0.0);
        }
        // 饼图/环形图不使用坐标轴范围，按扇区求和绘制，这里给出占位范围。
        let (x_range, y_range, y_step) = match (x_axis, y_axis) {
            (Some(x_axis), Some(y_axis)) => {
                let (x_range, _) = range(&xs, x_axis, false)?;
                let (y_range, y_step) = range(&ys, y_axis, true)?;
                (x_range, y_range, y_step)
            }
            _ => ((0.0, 1.0), (0.0, 1.0), 1.0),
        };
        Some(Self {
            node,
            plot,
            x_axis,
            y_axis,
            series,
            x_range,
            y_range,
            y_step,
            blanks,
            date1904: super::flag(value(root, "date1904"), false),
            chart_type,
        })
    }
}

/// 解析环形图 `<c:holeSize val="...">`，合法范围 1..=90（默认 50），
/// 换算为内半径占比并钳位到 `0.1..=0.9`，避免退化或自交的环。
fn hole_ratio(chart_node: &Node) -> f32 {
    let parsed = chart_node
        .child("holeSize")
        .and_then(|n| n.attr("val").parse::<i32>().ok())
        .filter(|value| (1..=90).contains(value))
        .unwrap_or(50);
    (parsed as f32 / 100.0).clamp(0.1, 0.9)
}

impl Series<'_> {
    pub fn x(&self, index: usize) -> Option<f64> {
        self.dates
            .as_ref()
            .map_or(Some(index as f64), |dates| dates[index])
    }
}

fn range(values: &[f64], axis: &Node, round: bool) -> Option<((f64, f64), f64)> {
    let mut min = values.iter().copied().reduce(f64::min)?;
    let mut max = values.iter().copied().reduce(f64::max)?;
    if min == max {
        let extra = (min.abs() * 0.1).max(1.0);
        min -= extra;
        max += extra;
    }
    let raw_step = (max - min) / 4.0;
    let power = 10.0_f64.powf(raw_step.log10().floor());
    let step = [1.0, 2.0, 5.0, 10.0]
        .into_iter()
        .find(|n| raw_step <= n * power)?
        * power;
    if round {
        min = (min / step).floor() * step;
        max = (max / step).ceil() * step;
    }
    if let Some(scaling) = axis.child("scaling") {
        if let Some(n) = scaling.child("min") {
            min = numeric(n.attr("val"))?;
        }
        if let Some(n) = scaling.child("max") {
            max = numeric(n.attr("val"))?;
        }
    }
    let step = match axis.child("majorUnit") {
        Some(n) if round => numeric(n.attr("val"))?,
        _ => step,
    };
    if max <= min || step <= 0.0 || !step.is_finite() || (max - min) / step > 100.0 {
        return None;
    }
    Some(((min, max), step))
}
