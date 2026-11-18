//! DOCX 表格单元格样式结算：底纹（`w:shd`）、垂直对齐（`w:vAlign`）与四边边框（`w:tblBorders` / `w:tcBorders`）。
//!
//! 全部级联（表格样式条件块 ➔ `tblPr` ➔ `trPr`/`tblPrEx` ➔ `tcPr`）与合并单元格
//! 外框归并都在这里一次性预结算为 `rows × cols` 矩阵，平台层只做查表绘制。

use super::format;
use super::styles::Styles;
use crate::model::{CellBorder, CellRange, Element};
use crate::xml::{self, Node};
use std::collections::HashMap;

/// 表格级六条边的索引，与 OOXML `tblBorders` 子元素一一对应
const TOP: usize = 0;
const RIGHT: usize = 1;
const BOTTOM: usize = 2;
const LEFT: usize = 3;
const INSIDE_H: usize = 4;
const INSIDE_V: usize = 5;
const EDGE_COUNT: usize = 6;

/// 单边边框的结算结果
#[derive(Debug, Clone, Copy, PartialEq)]
enum Edge {
    /// 未声明，继承上一级
    Unset,
    /// 显式声明为 none / nil
    Hidden,
    /// 实线
    Line(CellBorder),
}

impl Edge {
    const UNSET: Self = Self::Unset;

    fn color(self) -> u32 {
        match self {
            Self::Line(border) => border.color,
            Self::Unset | Self::Hidden => 0,
        }
    }

    fn width(self) -> f32 {
        match self {
            Self::Line(border) => border.width,
            Self::Unset | Self::Hidden => 0.0,
        }
    }

    /// 是否绘制为实线（none/nil 与未声明都不绘制）
    fn is_line(self) -> bool {
        matches!(self, Self::Line(_))
    }

    /// 两条边在几何与颜色上是否等价
    fn same(self, other: Self) -> bool {
        self.is_line() == other.is_line()
            && self.color() == other.color()
            && (self.width() - other.width()).abs() <= f32::EPSILON
    }
}

/// 表格样式的条件块启用状态，由 `w:tblLook` 决定
#[derive(Debug, Clone, Copy)]
struct Look {
    first_row: bool,
    last_row: bool,
    first_column: bool,
    last_column: bool,
}

impl Default for Look {
    fn default() -> Self {
        // 未声明 tblLook 时按 Word 常见表头样式默认启用 firstRow
        Self {
            first_row: true,
            last_row: false,
            first_column: false,
            last_column: false,
        }
    }
}

impl Look {
    /// 解析 `<w:tblLook>`，同时支持属性显式声明与 `w:val` 十六进制位掩码
    fn parse(node: Option<&Node>) -> Self {
        let Some(node) = node else {
            return Self::default();
        };
        let mut look = Self {
            first_row: false,
            last_row: false,
            first_column: false,
            last_column: false,
        };
        let mask = node
            .attr("val")
            .trim_start_matches("0x")
            .trim_start_matches("0X");
        if let Ok(bits) = u32::from_str_radix(mask, 16) {
            look.first_row = bits & 0x0020 != 0;
            look.last_row = bits & 0x0040 != 0;
            look.first_column = bits & 0x0080 != 0;
            look.last_column = bits & 0x0100 != 0;
        }
        // 显式属性优先于位掩码
        for (name, slot) in [
            ("firstRow", &mut look.first_row),
            ("lastRow", &mut look.last_row),
            ("firstColumn", &mut look.first_column),
            ("lastColumn", &mut look.last_column),
        ] {
            if let Some(value) = node.get_attr(name) {
                *slot = format::enabled(value);
            }
        }
        look
    }

    /// 该条件块类型在给定网格位置是否命中
    fn hits(self, kind: &str, row: usize, col: usize, rows: usize, cols: usize) -> bool {
        match kind {
            "firstRow" => self.first_row && row == 0,
            "lastRow" => self.last_row && rows > 0 && row + 1 == rows,
            "firstCol" => self.first_column && col == 0,
            "lastCol" => self.last_column && cols > 0 && col + 1 == cols,
            _ => false,
        }
    }
}

/// 解析 `w:shd`：返回 `Some(argb)` 表示显式颜色，`Some(0)` 表示显式清除底纹，`None` 表示未声明或无法解析
fn shading(node: &Node, styles: &Styles) -> Option<u32> {
    let theme = node.attr("themeFill");
    if !theme.is_empty() {
        if let Some(base) = styles.theme_color(theme) {
            return Some(apply_tint_shade(
                base,
                node.attr("themeFillTint"),
                node.attr("themeFillShade"),
            ));
        }
    }
    let val = node.attr("val");
    let fill = node.attr("fill");
    if val.eq_ignore_ascii_case("nil")
        || fill.eq_ignore_ascii_case("auto")
        || fill.eq_ignore_ascii_case("none")
        || (fill.is_empty() && val.eq_ignore_ascii_case("clear"))
    {
        return Some(0);
    }
    if !fill.is_empty() {
        let color = xml::color(fill, 0);
        if color != 0 {
            return Some(color);
        }
    }
    None
}

/// 应用 OOXML 的 tint / shade 十六进制比例（`"80"` 表示 50%）
fn apply_tint_shade(base: u32, tint: &str, shade: &str) -> u32 {
    let channel = |value: u32, shift: u32| (value >> shift) & 0xff;
    let mut rgb = [channel(base, 16), channel(base, 8), channel(base, 0)];
    if let Ok(percent) = u8::from_str_radix(shade, 16) {
        // shade 按比例压暗，0 表示全黑
        let factor = f32::from(percent) / 255.0;
        for value in &mut rgb {
            *value = (*value as f32 * factor).round() as u32;
        }
    }
    if let Ok(percent) = u8::from_str_radix(tint, 16) {
        // tint 向白色插值，0 表示保持原色
        let factor = f32::from(percent) / 255.0;
        for value in &mut rgb {
            let current = f32::from(u8::try_from(*value).unwrap_or(u8::MAX));
            *value = (current + (255.0 - current) * factor).round() as u32;
        }
    }
    (base & 0xff00_0000) | (rgb[0].min(255) << 16) | (rgb[1].min(255) << 8) | rgb[2].min(255)
}

/// 解析单边边框节点为 [`Edge`]
fn edge(node: Option<&Node>) -> Edge {
    let Some(node) = node else {
        return Edge::Unset;
    };
    let val = node.attr("val");
    if val.is_empty() {
        return Edge::Unset;
    }
    if val == "none" || val == "nil" {
        return Edge::Hidden;
    }
    let color = if node.attr("color").is_empty() || node.attr("color").eq_ignore_ascii_case("auto")
    {
        0xff00_0000
    } else {
        xml::color(node.attr("color"), 0xff00_0000)
    };
    // sz 以 1/8 pt 为单位，钳位到平台层可接受的线宽范围
    let width = (xml::number(node.attr("sz"), 4.0) / 8.0).clamp(0.5, 36.0);
    Edge::Line(CellBorder { color, width })
}

/// 解析六边 `tblBorders` 为 `[top, right, bottom, left, insideH, insideV]`
fn table_edges(node: Option<&Node>) -> [Edge; EDGE_COUNT] {
    let Some(node) = node else {
        return [Edge::UNSET; EDGE_COUNT];
    };
    [
        edge(node.child("top")),
        edge(node.child("right")),
        edge(node.child("bottom")),
        edge(node.child("left")),
        edge(node.child("insideH")),
        edge(node.child("insideV")),
    ]
}

/// 解析四边 `tcBorders` 为 `[top, right, bottom, left]`
fn cell_edges(node: Option<&Node>) -> [Edge; 4] {
    let Some(node) = node else {
        return [Edge::UNSET; 4];
    };
    [
        edge(node.child("top")),
        edge(node.child("right")),
        edge(node.child("bottom")),
        edge(node.child("left")),
    ]
}

/// 叠加四边：仅对已声明（非 `Unset`）的边生效
fn overlay(base: &mut [Edge; 4], over: [Edge; 4]) {
    for (slot, value) in base.iter_mut().zip(over) {
        if !matches!(value, Edge::Unset) {
            *slot = value;
        }
    }
}

/// 垂直对齐枚举：0 顶部、1 居中、2 底部
fn valign(node: Option<&Node>) -> Option<u8> {
    match node?.attr("val") {
        "top" => Some(0),
        "center" | "both" => Some(1),
        "bottom" => Some(2),
        _ => None,
    }
}

/// 表格样式链派生出的声明：无条件段默认 `tcPr` 与按类型索引的条件块 `tcPr`
struct StyleDefaults {
    base: Option<Node>,
    /// 条件块按 (类型, tcPr) 收集；同一类型出现多次时按链顺序叠加
    conditional: Vec<(String, Node)>,
    /// 表格样式自身 `tblPr/tblBorders`（Word 最常见的存边框位置）
    table_borders: Option<Node>,
    /// 表格样式自身 `tblPr/shd`
    table_shading: Option<Node>,
}

impl StyleDefaults {
    fn load(node: &Node, styles: &Styles) -> Self {
        let chain = styles.table_chain(node.attr("val"));
        let mut base = None;
        let mut conditional = Vec::new();
        let mut table_borders = None;
        let mut table_shading = None;
        // 链顺序为自身 → 祖先；逆序遍历（祖先在前）让子样式的声明覆盖祖先
        for style in chain.iter().rev() {
            if let Some(tc_pr) = style.child("tcPr") {
                base = Some(merge_tc_pr(base.as_ref(), tc_pr));
            }
            for block in style.named("tblStylePr") {
                if let Some(tc_pr) = block.child("tcPr") {
                    conditional.push((block.attr("type").to_owned(), tc_pr.clone()));
                }
            }
            if let Some(tbl_pr) = style.child("tblPr") {
                if let Some(borders) = tbl_pr.child("tblBorders") {
                    table_borders = Some(borders.clone());
                }
                if let Some(shd) = tbl_pr.child("shd") {
                    table_shading = Some(shd.clone());
                }
            }
        }
        Self {
            base,
            conditional,
            table_borders,
            table_shading,
        }
    }

    /// 命中给定网格位置的条件块 `tcPr`，按声明顺序返回（后者优先级更高）
    fn matched(&self, look: Look, row: usize, col: usize, rows: usize, cols: usize) -> Vec<&Node> {
        self.conditional
            .iter()
            .filter(|(kind, _)| look.hits(kind, row, col, rows, cols))
            .map(|(_, node)| node)
            .collect()
    }
}

/// 合并同一表格样式链上父子样式的 `tcPr`：子样式已声明的子节点覆盖祖先
fn merge_tc_pr(parent: Option<&Node>, child: &Node) -> Node {
    let Some(parent) = parent else {
        return child.clone();
    };
    let mut merged = parent.clone();
    for node in &child.children {
        match merged.children.iter_mut().find(|n| n.name == node.name) {
            Some(slot) => *slot = node.clone(),
            None => merged.children.push(node.clone()),
        }
    }
    merged
}

/// 单个单元格自身声明的样式（条件样式在结算阶段按最终网格位置叠加）
#[derive(Debug, Clone, Copy, Default)]
struct CellStyle {
    fill: Option<u32>,
    valign: Option<u8>,
    /// 单元格四边覆盖
    borders: Option<[Edge; 4]>,
}

/// 表格样式结算器：随解析循环累积声明，最后一次性生成三个矩阵
pub(super) struct TableStyler {
    /// 表格级六边基准（表格样式 tcBorders + tblPr/tblBorders）
    base: [Edge; EDGE_COUNT],
    /// 表格级底纹（tblPr/shd 优先于表格样式 tcPr/shd）
    default_fill: Option<u32>,
    /// 表格级垂直对齐（表格样式 tcPr/vAlign）
    default_valign: Option<u8>,
    look: Look,
    style: StyleDefaults,
    cells: HashMap<(u32, u32), CellStyle>,
    /// 行级 `trPr/tblPrEx` 的四边覆盖
    row_edges: HashMap<u32, [Edge; 4]>,
    /// 行级底纹
    row_fill: HashMap<u32, u32>,
}

impl TableStyler {
    /// 依据表格节点建立结算器
    pub(super) fn new(node: &Node, styles: &Styles) -> Self {
        let look = Look::parse(node.child("tblPr").and_then(|n| n.child("tblLook")));
        let style = node
            .child("tblPr")
            .and_then(|n| n.child("tblStyle"))
            .map_or_else(
                || StyleDefaults {
                    base: None,
                    conditional: Vec::new(),
                    table_borders: None,
                    table_shading: None,
                },
                |style_node| StyleDefaults::load(style_node, styles),
            );
        let mut base = [Edge::UNSET; EDGE_COUNT];
        let mut default_fill = None;
        let mut default_valign = None;
        // 表格样式的默认 tcPr 优先级最低
        if let Some(tc_pr) = &style.base {
            if let Some(color) = tc_pr.child("shd").and_then(|shd| shading(shd, styles)) {
                default_fill = Some(color);
            }
            default_valign = valign(tc_pr.child("vAlign"));
            // 表格样式的 tcBorders 同时作为六边基准（兼容 insideH/insideV）
            base = table_edges(tc_pr.child("tcBorders"));
        }
        // 表格样式自身的 tblPr/tblBorders 与 tblPr/shd（Word 最常见的存放位置）
        if let Some(shd) = &style.table_shading {
            if let Some(color) = shading(shd, styles) {
                default_fill = Some(color);
            }
        }
        let styled_table = table_edges(style.table_borders.as_ref());
        for (slot, value) in base.iter_mut().zip(styled_table) {
            if !matches!(value, Edge::Unset) {
                *slot = value;
            }
        }
        // 表格自身 tblPr 的声明优先级最高
        if let Some(tbl_pr) = node.child("tblPr") {
            if let Some(color) = tbl_pr.child("shd").and_then(|shd| shading(shd, styles)) {
                default_fill = Some(color);
            }
            let declared = table_edges(tbl_pr.child("tblBorders"));
            for (slot, value) in base.iter_mut().zip(declared) {
                if !matches!(value, Edge::Unset) {
                    *slot = value;
                }
            }
        }
        Self {
            base,
            default_fill,
            default_valign,
            look,
            style,
            cells: HashMap::new(),
            row_edges: HashMap::new(),
            row_fill: HashMap::new(),
        }
    }

    /// 登记行级 `trPr/tblPrEx` 的底纹与边框覆盖
    pub(super) fn row(&mut self, row: u32, properties: Option<&Node>, styles: &Styles) {
        let Some(ex) = properties.and_then(|p| p.child("tblPrEx")) else {
            return;
        };
        let declared = cell_edges(ex.child("tblBorders"));
        if declared.iter().any(|e| !matches!(e, Edge::Unset)) {
            self.row_edges.insert(row, declared);
        }
        if let Some(color) = ex.child("shd").and_then(|shd| shading(shd, styles)) {
            self.row_fill.insert(row, color);
        }
    }

    /// 登记单元格自身的 `tcPr` 声明
    pub(super) fn cell(&mut self, row: u32, col: u32, properties: Option<&Node>, styles: &Styles) {
        let mut style = CellStyle::default();
        if let Some(properties) = properties {
            style.fill = properties.child("shd").and_then(|shd| shading(shd, styles));
            style.valign = valign(properties.child("vAlign"));
            let declared = cell_edges(properties.child("tcBorders"));
            if declared.iter().any(|e| !matches!(e, Edge::Unset)) {
                style.borders = Some(declared);
            }
        }
        self.cells.insert((row, col), style);
    }

    /// 结算并写入 `Element` 的三个样式矩阵。
    ///
    /// 调用前提：`rows`/`cols` 已确定且行已补齐，`merges` 已收集完毕。
    pub(super) fn finish(
        element: &mut Element,
        styler: Self,
        styles: &Styles,
        rows: usize,
        cols: usize,
        merges: &[CellRange],
    ) {
        if rows == 0 || cols == 0 {
            return;
        }
        let mut fills = vec![vec![0u32; cols]; rows];
        let mut valigns = vec![vec![0u8; cols]; rows];
        let mut borders = vec![vec![[CellBorder::default(); 4]; cols]; rows];
        let mut any_fill = false;
        let mut any_valign = false;
        // 判定是否出现"非均匀边框"。两种情形都视为均匀、不输出 cell_borders：
        // 1. 六边基准完全未声明（全 Unset）——文档没有任何边框配置，平台层沿用
        //    既有的表格级 stroke 兜底网格，普通表格 JSON 才能保持零变化；
        // 2. 六边基准全部为实线且颜色/线宽一致——由 stroke 承担统一绘制。
        let base_all_unset = styler.base.iter().all(|e| matches!(e, Edge::Unset));
        let mut uniform = base_all_unset
            || (styler.base.iter().all(|e| e.is_line())
                && styler.base.iter().all(|e| e.same(styler.base[TOP])));
        if styler
            .row_edges
            .values()
            .any(|edges| edges.iter().any(|e| !matches!(e, Edge::Unset)))
        {
            uniform = false;
        }
        if styler.cells.values().any(|style| {
            style
                .borders
                .is_some_and(|b| b.iter().any(|e| !matches!(e, Edge::Unset)))
        }) {
            uniform = false;
        }

        for row in 0..rows {
            let row_key = row as u32;
            let row_fill = styler.row_fill.get(&row_key).copied();
            let row_override = styler.row_edges.get(&row_key).copied();
            for col in 0..cols {
                let own = styler
                    .cells
                    .get(&(row_key, col as u32))
                    .copied()
                    .unwrap_or_default();

                // 条件样式（firstRow 等）按最终网格位置叠加，优先级低于行级与单元格自身
                let mut conditional_fill = None;
                let mut conditional_valign = None;
                let mut conditional_borders: Option<[Edge; 4]> = None;
                for tc_pr in styler.style.matched(styler.look, row, col, rows, cols) {
                    if let Some(color) = tc_pr.child("shd").and_then(|shd| shading(shd, styles)) {
                        conditional_fill = Some(color);
                    }
                    if let Some(value) = valign(tc_pr.child("vAlign")) {
                        conditional_valign = Some(value);
                    }
                    let declared = cell_edges(tc_pr.child("tcBorders"));
                    if declared.iter().any(|e| !matches!(e, Edge::Unset)) {
                        let slot = conditional_borders.get_or_insert([Edge::UNSET; 4]);
                        overlay(slot, declared);
                    }
                }
                if conditional_borders.is_some() {
                    uniform = false;
                }

                // 底纹优先级：tcPr > trPr/tblPrEx > 条件样式 > 表格级（Some(0) 表示显式清除）
                let fill = own
                    .fill
                    .or(row_fill)
                    .or(conditional_fill)
                    .or(styler.default_fill)
                    .unwrap_or(0);
                fills[row][col] = fill;
                any_fill |= fill != 0;

                // 垂直对齐：tcPr > 条件样式 > 表格样式默认 > 顶部
                let align = own
                    .valign
                    .or(conditional_valign)
                    .or(styler.default_valign)
                    .unwrap_or(0);
                valigns[row][col] = align;
                any_valign |= align != 0;

                // 四边边框：表格级基准（外框与内部线分取）→ 行级 → 条件样式 → 单元格级
                let mut resolved = [
                    styler.base[if row == 0 { TOP } else { INSIDE_H }],
                    styler.base[if col + 1 == cols { RIGHT } else { INSIDE_V }],
                    styler.base[if row + 1 == rows { BOTTOM } else { INSIDE_H }],
                    styler.base[if col == 0 { LEFT } else { INSIDE_V }],
                ];
                if let Some(row_override) = row_override {
                    overlay(&mut resolved, row_override);
                }
                if let Some(conditional) = conditional_borders {
                    overlay(&mut resolved, conditional);
                }
                if let Some(borders) = own.borders {
                    overlay(&mut resolved, borders);
                }
                for (slot, value) in resolved.into_iter().enumerate() {
                    // 表格级基准中不存在一条边同时对应 top/insideH，故用"是否实线 + 颜色 + 线宽"
                    // 与对应方向的基准边比较；任一单元格出现差异即退出统一网格框模式
                    let reference = styler.base[match slot {
                        0 if row == 0 => TOP,
                        2 if row + 1 == rows => BOTTOM,
                        1 if col + 1 == cols => RIGHT,
                        3 if col == 0 => LEFT,
                        0 | 2 => INSIDE_H,
                        _ => INSIDE_V,
                    }];
                    // 基准边未声明时无可区分语义，不参与均匀性判定
                    if !matches!(reference, Edge::Unset) && !value.same(reference) {
                        uniform = false;
                    }
                    borders[row][col][slot] = CellBorder {
                        color: value.color(),
                        width: value.width(),
                    };
                }
            }
        }

        // 合并区域外框归并：把跨行/跨列的外边收拢到锚点 (start_row, start_column)
        for range in merges {
            let (start_row, start_col) = (range.start_row as usize, range.start_column as usize);
            let (end_row, end_col) = (range.end_row as usize, range.end_column as usize);
            if start_row >= rows || end_row >= rows || start_col >= cols || end_col >= cols {
                continue;
            }
            if start_row == end_row && start_col == end_col {
                continue;
            }
            // top/left 取锚点自身，right 取区域最右列、bottom 取区域最末行。
            // 但锚点若通过 tcBorders 显式声明了该边，则该声明描述的是整个合并区域的外边，
            // 必须优先于区域内单元格推得的隐式边。
            let anchor = styler
                .cells
                .get(&(start_row as u32, start_col as u32))
                .copied()
                .unwrap_or_default();
            let declared = |slot: usize| {
                anchor
                    .borders
                    .is_some_and(|edges| !matches!(edges[slot], Edge::Unset))
            };
            if !declared(RIGHT) {
                borders[start_row][start_col][RIGHT] = borders[start_row][end_col][RIGHT];
            }
            if !declared(BOTTOM) {
                borders[start_row][start_col][BOTTOM] = borders[end_row][start_col][BOTTOM];
            }
        }

        if any_fill {
            element.cell_fills = fills;
        }
        if any_valign {
            element.cell_valigns = valigns;
        }
        if !uniform {
            element.cell_borders = borders;
        } else if let Edge::Line(border) = styler.base[TOP] {
            // 均匀网格框由表格级 `stroke` / `stroke_width` 承担统一绘制；
            // 样式派生的边框在这里补齐，避免只有 `tblPr/tblBorders` 的旧路径生效。
            element.stroke = border.color;
            element.stroke_width = border.width;
        }
    }
}
