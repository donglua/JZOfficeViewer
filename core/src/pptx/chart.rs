use super::chart_data::{self, value, Chart, ChartType};
use super::geometry::{points, Bounds};
use super::parts::Part;
use super::render::Render;
use super::text_style::TextStyle;
use crate::model::{Element, ElementType, Paragraph, Run};
use crate::xml::Node;
use crate::Result;

impl Render<'_> {
    pub fn chart(&mut self, part: &Part, reference: &Node, bounds: Bounds) -> Result<Vec<Element>> {
        let Some(path) = part
            .rels
            .get(super::relation_id(reference, "id"))
            .filter(|path| self.pkg.has(path))
        else {
            self.doc
                .warn("PPTX charts with missing or external parts were omitted.");
            return Ok(Vec::new());
        };
        let root = self.pkg.xml(path)?;
        let Some(chart) = Chart::parse(&root) else {
            self.doc.warn(
                "PPTX charts without supported cached standard line or column data were omitted.",
            );
            return Ok(Vec::new());
        };
        let frame = bounds.element(ElementType::RECT);
        let mut painter = ChartPaint {
            render: self,
            elements: Vec::new(),
        };
        if !painter.draw(&root, &chart, &frame) {
            painter
                .render
                .doc
                .warn("PPTX charts with insufficient drawing space were omitted.");
            return Ok(Vec::new());
        }
        match chart.chart_type {
            ChartType::Line => {
                painter.render.doc.warn(
                    "PPTX line charts use cached values; layout, markers and styling are simplified.",
                );
            }
            ChartType::Column => {
                painter.render.doc.warn(
                    "PPTX column charts use cached values; layout, bars and styling are simplified.",
                );
            }
        }
        for element in &mut painter.elements {
            for paragraph in &element.paragraphs {
                for run in &paragraph.runs {
                    painter.render.budget.text(run.text.len())?;
                }
            }
            place(element, &frame);
        }
        Ok(painter.elements)
    }
}

struct ChartPaint<'a, 'b> {
    render: &'a mut Render<'b>,
    elements: Vec<Element>,
}

#[derive(Clone, Copy)]
struct Plot {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
}

impl ChartPaint<'_, '_> {
    fn draw(&mut self, root: &Node, chart: &Chart<'_>, frame: &Element) -> bool {
        let base = self.style(root, 7.0);
        let xs = self.style(chart.x_axis, base.size);
        let ys = self.style(chart.y_axis, base.size);
        let title = chart.node.child("title");
        let title_text = title.map(chart_data::text).unwrap_or_default();
        let title_style = title
            .map(|n| self.style(n, base.size * 1.2))
            .unwrap_or(base.clone());
        let legend = chart.node.child("legend");
        let legend_style = legend
            .map(|n| self.style(n, base.size))
            .unwrap_or(base.clone());
        let named: Vec<_> = chart.series.iter().filter(|s| !s.name.is_empty()).collect();
        let legend_height = if legend.is_some() {
            named.len() as f32 * legend_style.size * 1.7
        } else {
            0.0
        };
        let plot = Plot {
            x: (ys.size * 4.8).max(26.0),
            y: if title_text.is_empty() {
                8.0
            } else {
                title_style.size * 2.5
            },
            width: frame.width - (ys.size * 4.8).max(26.0) - 12.0,
            height: frame.height
                - xs.size * 2.8
                - legend_height
                - if title_text.is_empty() {
                    8.0
                } else {
                    title_style.size * 2.5
                },
        };
        if plot.width < 24.0 || plot.height < 16.0 {
            return false;
        }
        self.background(
            root,
            Plot {
                x: 0.0,
                y: 0.0,
                width: frame.width,
                height: frame.height,
            },
        );
        self.background(chart.plot, plot);
        if !title_text.is_empty() {
            self.label(
                title_text,
                title_style,
                Plot {
                    x: 4.0,
                    y: 2.0,
                    width: frame.width - 8.0,
                    height: plot.y - 3.0,
                },
                1,
            );
        }
        self.axes(chart, plot, xs, ys);
        match chart.chart_type {
            ChartType::Line => {
                for (index, series) in chart.series.iter().enumerate() {
                    let (color, width) =
                        self.stroke(series.node, self.render.theme.accent(index), 1.5);
                    let mut previous = None;
                    for (i, value) in series.values.iter().enumerate() {
                        let point = series
                            .x(i)
                            .zip(value.or((chart.blanks == "zero").then_some(0.0)))
                            .map(|(x, y)| {
                                (
                                    fraction(x, chart.x_range, chart.x_axis),
                                    1.0 - fraction(y, chart.y_range, chart.y_axis),
                                )
                            });
                        if let Some(point) = point {
                            if let Some(prior) = previous {
                                if let Some((a, b)) = clip(prior, point) {
                                    self.line(
                                        (
                                            plot.x + a.0 as f32 * plot.width,
                                            plot.y + a.1 as f32 * plot.height,
                                        ),
                                        (
                                            plot.x + b.0 as f32 * plot.width,
                                            plot.y + b.1 as f32 * plot.height,
                                        ),
                                        color,
                                        width,
                                    );
                                }
                            }
                            previous = Some(point);
                        } else if chart.blanks != "span" {
                            previous = None;
                        }
                    }
                }
            }
            ChartType::Column => {
                let category_count = chart.series.first().map_or(0, |s| s.values.len());
                if category_count > 0 {
                    let slot_width = plot.width / category_count as f32;
                    let series_count = chart.series.len().max(1) as f32;
                    let group_width = slot_width * 0.7;
                    let bar_width = group_width / series_count;
                    let group_offset = (slot_width - group_width) / 2.0;
                    let zero_frac = fraction(0.0, chart.y_range, chart.y_axis);
                    let zero_y = plot.y + (1.0 - zero_frac) as f32 * plot.height;
                    let baseline_y = zero_y.clamp(plot.y, plot.y + plot.height);

                    for (s_idx, series) in chart.series.iter().enumerate() {
                        let fill = self.series_fill(series.node, s_idx);
                        for (i, value) in series.values.iter().enumerate() {
                            let y_val = value.or((chart.blanks == "zero").then_some(0.0));
                            if let Some(y) = y_val {
                                let y_frac = fraction(y, chart.y_range, chart.y_axis);
                                let val_y = plot.y + (1.0 - y_frac) as f32 * plot.height;
                                let bar_top =
                                    val_y.min(baseline_y).clamp(plot.y, plot.y + plot.height);
                                let bar_bottom =
                                    val_y.max(baseline_y).clamp(plot.y, plot.y + plot.height);
                                let bar_h = (bar_bottom - bar_top).max(0.5);
                                let bar_x = plot.x
                                    + i as f32 * slot_width
                                    + group_offset
                                    + s_idx as f32 * bar_width;

                                self.elements.push(Element {
                                    kind: ElementType::RECT,
                                    x: bar_x,
                                    y: bar_top,
                                    width: bar_width,
                                    height: bar_h,
                                    fill,
                                    ..Element::default()
                                });
                            }
                        }
                    }
                }
            }
        }
        if legend.is_some() {
            for (row, series) in named.iter().enumerate() {
                let index = chart
                    .series
                    .iter()
                    .position(|s| std::ptr::eq(s, *series))
                    .unwrap_or(0);
                let (color, width) = self.stroke(series.node, self.render.theme.accent(index), 1.5);
                let y = frame.height - legend_height + row as f32 * legend_style.size * 1.7;
                match chart.chart_type {
                    ChartType::Line => {
                        self.line(
                            (plot.x, y + legend_style.size * 0.6),
                            (plot.x + 14.0, y + legend_style.size * 0.6),
                            color,
                            width,
                        );
                    }
                    ChartType::Column => {
                        let fill = self.series_fill(series.node, index);
                        self.elements.push(Element {
                            kind: ElementType::RECT,
                            x: plot.x,
                            y: y + legend_style.size * 0.2,
                            width: 12.0,
                            height: legend_style.size * 0.8,
                            fill,
                            ..Element::default()
                        });
                    }
                }
                self.label(
                    series.name.clone(),
                    legend_style.clone(),
                    Plot {
                        x: plot.x + 18.0,
                        y,
                        width: frame.width - plot.x - 22.0,
                        height: legend_style.size * 1.6,
                    },
                    0,
                );
            }
        }
        true
    }

    fn axes(&mut self, chart: &Chart<'_>, plot: Plot, xs: Run, ys: Run) {
        let (min, max) = chart.y_range;
        let mut tick = (min / chart.y_step).ceil() * chart.y_step;
        for _ in 0..101 {
            if tick > max + chart.y_step * 0.000001 {
                break;
            }
            let y =
                plot.y + (1.0 - fraction(tick, chart.y_range, chart.y_axis)) as f32 * plot.height;
            if let Some(grid) = chart.y_axis.child("majorGridlines") {
                let (color, width) = self.stroke(grid, 0xffdedede, 0.5);
                self.line((plot.x, y), (plot.x + plot.width, y), color, width);
            }
            if axis_labels(chart.y_axis) {
                let text = self.number(tick, chart.y_axis, false, chart.date1904);
                self.label(
                    text,
                    ys.clone(),
                    Plot {
                        x: 0.0,
                        y: y - ys.size * 0.7,
                        width: plot.x - 4.0,
                        height: ys.size * 1.5,
                    },
                    2,
                );
            }
            tick += chart.y_step;
        }
        let first = &chart.series[0];
        let label_width = if first.dates.is_some() {
            xs.size * 7.0
        } else {
            xs.size * 6.0
        }
        .min(plot.x + plot.width + 12.0);
        let count = (plot.width / (label_width + 3.0)).floor().max(1.0) as usize;
        let stride = (first.values.len().saturating_sub(1))
            .div_ceil(count)
            .max(1);
        let mut last_right = f32::NEG_INFINITY;
        if axis_labels(chart.x_axis) {
            for offset in (0..first.values.len()).step_by(stride) {
                let i = if reversed(chart.x_axis) {
                    first.values.len() - 1 - offset
                } else {
                    offset
                };
                let Some(value) = first.x(i) else { continue };
                let x = if chart.chart_type == ChartType::Column && first.dates.is_none() {
                    let slot_width = plot.width / first.values.len().max(1) as f32;
                    let center_x = plot.x + (i as f32 + 0.5) * slot_width;
                    (center_x - label_width / 2.0)
                        .clamp(0.0, plot.x + plot.width + 12.0 - label_width)
                } else {
                    let fraction = fraction(value, chart.x_range, chart.x_axis);
                    if !(0.0..=1.0).contains(&fraction) {
                        continue;
                    }
                    (plot.x + fraction as f32 * plot.width - label_width / 2.0)
                        .clamp(0.0, plot.x + plot.width + 12.0 - label_width)
                };
                if x < last_right {
                    continue;
                }
                let text = if first.dates.is_some() {
                    self.number(value, chart.x_axis, true, chart.date1904)
                } else {
                    first.categories[i]
                        .map(str::to_owned)
                        .unwrap_or_else(|| (i + 1).to_string())
                };
                self.label(
                    text,
                    xs.clone(),
                    Plot {
                        x,
                        y: plot.y + plot.height + 3.0,
                        width: label_width,
                        height: xs.size * 1.6,
                    },
                    1,
                );
                last_right = x + label_width + 2.0;
            }
        }
        for (axis, a, b) in [
            (
                chart.x_axis,
                (plot.x, plot.y + plot.height),
                (plot.x + plot.width, plot.y + plot.height),
            ),
            (
                chart.y_axis,
                (plot.x, plot.y),
                (plot.x, plot.y + plot.height),
            ),
        ] {
            if super::flag(value(axis, "delete"), false) {
                continue;
            }
            let (color, width) = self.stroke(axis, 0xffaaaaaa, 0.5);
            self.line(a, b, color, width);
        }
    }

    fn number(&mut self, number: f64, axis: &Node, date: bool, date1904: bool) -> String {
        let raw = if !date && number.abs() < 1e12 && number.abs() >= 1e-6 {
            format!("{number:.6}")
                .trim_end_matches('0')
                .trim_end_matches('.')
                .to_owned()
        } else {
            number.to_string()
        };
        let code = axis.child("numFmt").map_or("", |n| n.attr("formatCode"));
        let code = if code.is_empty() {
            if date {
                "yyyy-mm-dd"
            } else {
                "General"
            }
        } else {
            code
        };
        crate::xlsx::format_value(&raw, code, date1904).unwrap_or_else(|| {
            self.render
                .doc
                .warn("Some PPTX chart number formats are simplified.");
            raw
        })
    }

    fn style(&mut self, node: &Node, size: f32) -> Run {
        let mut run = Run {
            size,
            color: self.render.theme.text_color(),
            ..Run::default()
        };
        let properties = node
            .child("txPr")
            .or_else(|| node.child("tx").and_then(|n| n.child("rich")))
            .and_then(|n| n.descendant("defRPr"));
        TextStyle {
            theme: self.render.theme,
            doc: self.render.doc,
        }
        .run(&mut run, properties);
        run
    }

    fn stroke(&mut self, node: &Node, fallback: u32, width: f32) -> (u32, f32) {
        match node.child("spPr").and_then(|n| n.child("ln")) {
            Some(line) => (
                self.render.theme.fill(line, fallback, self.render.doc),
                points(line.attr("w")).unwrap_or(width).clamp(0.0, 20.0),
            ),
            None => (fallback, width),
        }
    }

    fn series_fill(&mut self, node: &Node, index: usize) -> u32 {
        let fallback = self.render.theme.accent(index);
        let Some(sp_pr) = node.child("spPr") else {
            return fallback;
        };
        let fill = self.render.theme.fill(sp_pr, 0, self.render.doc);
        if fill != 0 {
            return fill;
        }
        if let Some(line) = sp_pr.child("ln") {
            return self.render.theme.fill(line, fallback, self.render.doc);
        }
        fallback
    }

    fn background(&mut self, node: &Node, bounds: Plot) {
        let fill = node
            .child("spPr")
            .map_or(0, |p| self.render.theme.fill(p, 0, self.render.doc));
        let (stroke, stroke_width) = self.stroke(node, 0, 0.5);
        if fill != 0 || stroke != 0 {
            self.elements.push(Element {
                kind: ElementType::RECT,
                x: bounds.x,
                y: bounds.y,
                width: bounds.width,
                height: bounds.height,
                fill,
                stroke,
                stroke_width,
                ..Element::default()
            });
        }
    }

    fn line(&mut self, a: (f32, f32), b: (f32, f32), stroke: u32, stroke_width: f32) {
        if stroke >> 24 == 0 || stroke_width <= 0.0 {
            return;
        }
        self.elements.push(Element {
            kind: ElementType::LINE,
            x: a.0.min(b.0),
            y: a.1.min(b.1),
            width: (b.0 - a.0).abs(),
            height: (b.1 - a.1).abs(),
            flip_h: b.0 < a.0,
            flip_v: b.1 < a.1,
            stroke,
            stroke_width,
            ..Element::default()
        });
    }

    fn label(&mut self, text: String, mut run: Run, bounds: Plot, alignment: u8) {
        run.text = text;
        self.elements.push(Element {
            kind: ElementType::TEXT,
            x: bounds.x,
            y: bounds.y,
            width: bounds.width,
            height: bounds.height,
            padding: 0.0,
            paragraphs: vec![Paragraph {
                runs: vec![run],
                alignment,
                after: 0.0,
                ..Paragraph::default()
            }],
            ..Element::default()
        });
    }
}

fn axis_labels(axis: &Node) -> bool {
    !super::flag(value(axis, "delete"), false) && value(axis, "tickLblPos") != "none"
}

fn fraction(number: f64, range: (f64, f64), axis: &Node) -> f64 {
    let value = (number - range.0) / (range.1 - range.0);
    if reversed(axis) {
        1.0 - value
    } else {
        value
    }
}

fn reversed(axis: &Node) -> bool {
    axis.child("scaling")
        .is_some_and(|n| chart_data::value(n, "orientation") == "maxMin")
}

fn clip(a: (f64, f64), b: (f64, f64)) -> Option<((f64, f64), (f64, f64))> {
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let (mut low, mut high): (f64, f64) = (0.0, 1.0);
    for (p, q) in [(-dx, a.0), (dx, 1.0 - a.0), (-dy, a.1), (dy, 1.0 - a.1)] {
        if p == 0.0 {
            if q < 0.0 {
                return None;
            }
        } else if p < 0.0 {
            low = low.max(q / p);
        } else {
            high = high.min(q / p);
        }
    }
    (low <= high).then_some((
        (a.0 + low * dx, a.1 + low * dy),
        (a.0 + high * dx, a.1 + high * dy),
    ))
}

fn place(element: &mut Element, frame: &Element) {
    let mut dx = element.x + element.width / 2.0 - frame.width / 2.0;
    let mut dy = element.y + element.height / 2.0 - frame.height / 2.0;
    if frame.flip_h {
        dx = -dx;
        element.flip_h = !element.flip_h;
    }
    if frame.flip_v {
        dy = -dy;
        element.flip_v = !element.flip_v;
    }
    let (sin, cos) = frame.rotation.to_radians().sin_cos();
    element.x = frame.x + frame.width / 2.0 + cos * dx - sin * dy - element.width / 2.0;
    element.y = frame.y + frame.height / 2.0 + sin * dx + cos * dy - element.height / 2.0;
    element.rotation = frame.rotation;
}
