use super::{boolean, coordinates, dimension, unsigned, Workbook};
use crate::model::{Cell, Document, Sheet};
use crate::xml::Node;
use crate::{Error, Result};
use std::collections::HashSet;

pub(super) fn parse(
    root: &Node,
    name: &str,
    workbook: &mut Workbook,
    document: &mut Document,
) -> Result<Sheet> {
    let defaults = root.child("sheetFormatPr");
    let row_height = dimension(
        defaults.map_or("", |n| n.attr("defaultRowHeight")),
        15.0,
        409.5,
    )?;
    let column_width = width(defaults.map_or("", |n| n.attr("defaultColWidth")), 8.43)?;
    let default_hidden = defaults.map_or(Ok(false), |n| boolean(n.attr("zeroHeight"), false))?;
    let default_height = if default_hidden { 0.0 } else { row_height };
    let mut sheet = Sheet {
        name: name.to_owned(),
        row_heights: vec![default_height],
        column_widths: vec![column_width],
        cells: Vec::new(),
        merges: Vec::new(),
        frozen_rows: 0,
        frozen_columns: 0,
        geometry: None,
    };
    let mut column_styles = [0_u32; 256];
    if let Some(columns) = root.child("cols") {
        for col in columns.named("col") {
            let start = coordinates::column_index(unsigned(col.attr("min"))?)?;
            let end = coordinates::column_index(unsigned(col.attr("max"))?)?;
            if start > end {
                return Err(Error::Invalid("Reversed XLSX column range"));
            }
            let style = workbook.style_index(col.attr("style"), 0)?;
            let size = if boolean(col.attr("hidden"), false)? {
                0.0
            } else if col.attr("width").is_empty() {
                column_width
            } else {
                width(col.attr("width"), 8.43)?
            };
            // Widths are character units; the renderer receives points using the Calibri 11 digit metric.
            extend_columns(&mut sheet, end, column_width)?;
            for column in start..=end {
                sheet.column_widths[index(column)?] = size;
                column_styles[index(column)?] = style;
            }
        }
    }
    let mut seen_rows = HashSet::new();
    let mut seen_cells = HashSet::new();
    let mut next_row = 0;
    if let Some(data) = root.child("sheetData") {
        for row in data.named("row") {
            let row_index = if row.attr("r").is_empty() {
                coordinates::row_index(next_row + 1)?
            } else {
                coordinates::row_index(unsigned(row.attr("r"))?)?
            };
            if !seen_rows.insert(row_index) {
                return Err(Error::Invalid("Duplicate XLSX row"));
            }
            next_row = row_index + 1;
            extend_rows(&mut sheet, row_index, default_height)?;
            let hidden = boolean(row.attr("hidden"), default_hidden)?;
            sheet.row_heights[index(row_index)?] = if hidden {
                0.0
            } else {
                dimension(row.attr("ht"), row_height, 409.5)?
            };
            let row_style = workbook.style_index(row.attr("s"), 0)?;
            let use_row_style = boolean(row.attr("customFormat"), !row.attr("s").is_empty())?;
            let mut next_column = 0;
            for node in row.named("c") {
                let (cell_row, column) = if node.attr("r").is_empty() {
                    (row_index, coordinates::column_index(next_column + 1)?)
                } else {
                    coordinates::coordinate(node.attr("r"))?
                };
                if cell_row != row_index {
                    return Err(Error::Invalid("Cell reference does not match its row"));
                }
                if !seen_cells.insert((cell_row, column)) {
                    return Err(Error::Invalid("Duplicate XLSX cell"));
                }
                next_column = column + 1;
                extend_columns(&mut sheet, column, column_width)?;
                let style = if use_row_style {
                    row_style
                } else {
                    column_styles[index(column)?]
                };
                let cell = Cell {
                    row: cell_row,
                    column,
                    text: String::new(),
                    style,
                    numeric: false,
                };
                sheet.cells.push(workbook.cell(node, cell, document)?);
            }
        }
    }
    if let Some(merges) = root.child("mergeCells") {
        for node in merges.named("mergeCell") {
            workbook.budget.merges += 1;
            if workbook.budget.merges > 1000 {
                return Err(Error::Limit("XLSX exceeds 1000 merged ranges"));
            }
            let range = coordinates::range(node.attr("ref"))?;
            if sheet
                .merges
                .iter()
                .any(|other| coordinates::overlaps(&range, other))
            {
                return Err(Error::Invalid("Overlapping XLSX merged ranges"));
            }
            extend_rows(&mut sheet, range.end_row, default_height)?;
            extend_columns(&mut sheet, range.end_column, column_width)?;
            sheet.merges.push(range);
        }
    }
    // sheetViews 必须放在 sheetData / mergeCells 之后解析：只有此时 row_heights 与 column_widths
    // 的最终维度才确定，冻结行列数才能钳位到工作表实际范围。
    freeze::apply(root, &mut sheet, document)?;
    for feature in [
        "drawing",
        "legacyDrawing",
        "picture",
        "pivotTableParts",
        "conditionalFormatting",
        "autoFilter",
        "tableParts",
        "extLst",
    ] {
        if root.child(feature).is_some() {
            document.warn(
                "Worksheet drawings, tables, filters and conditional formatting are not rendered",
            );
        }
    }
    sheet
        .cells
        .sort_unstable_by_key(|cell| (cell.row, cell.column));
    Ok(sheet)
}

fn index(value: u32) -> Result<usize> {
    usize::try_from(value).map_err(|_| Error::Invalid("Invalid XLSX index"))
}

fn extend_rows(sheet: &mut Sheet, row: u32, height: f32) -> Result<()> {
    let length = index(row)? + 1;
    if length > sheet.row_heights.len() {
        sheet.row_heights.resize(length, height);
    }
    Ok(())
}

fn extend_columns(sheet: &mut Sheet, column: u32, width: f32) -> Result<()> {
    let length = index(column)? + 1;
    if length > sheet.column_widths.len() {
        sheet.column_widths.resize(length, width);
    }
    Ok(())
}

fn width(value: &str, fallback: f32) -> Result<f32> {
    let width = dimension(value, fallback, 255.0)?;
    if width == 0.0 {
        return Ok(0.0);
    }
    Ok(((256.0 * width + (128.0_f32 / 7.0).floor()) / 256.0 * 7.0).floor() * 0.75)
}

/// `<sheetViews>/<sheetView>/<pane>` 冻结窗格解析。
///
/// 仅支持 OOXML 的 `state="frozen"` / `state="frozenSplit"` 按行列冻结；自由拆分（`state="split"`）
/// 不做几何模拟，只记录 warning。所有解析结果都会钳位到工作表已确定的行列维度。
mod freeze {
    use super::Sheet;
    use crate::model::Document;
    use crate::xml::Node;
    use crate::{Error, Result};

    pub(super) fn apply(root: &Node, sheet: &mut Sheet, document: &mut Document) -> Result<()> {
        let Some(views) = root.child("sheetViews") else {
            return Ok(());
        };
        let Some(view) = target(views) else {
            return Ok(());
        };
        let Some(pane) = view.child("pane") else {
            return Ok(());
        };
        // 所选 sheetView 自身携带非空且非 A1 的 topLeftCell，说明冻结配置是在滚动后保存的：
        // 冻结的仍是文档首行/首列，只是保存时的滚动位置不同，平台层按冻结行列数处理即可。
        // `<pane>` 自身的 topLeftCell 只是拆分后的活动单元格，不参与判定。
        let top_left = view.attr("topLeftCell");
        if !top_left.is_empty() && !top_left.eq_ignore_ascii_case("A1") {
            document.warn(
                "XLSX frozen panes are applied from the leading rows and columns even when the sheet view was scrolled away from A1",
            );
        }
        let x_split = pane.attr("xSplit");
        let y_split = pane.attr("ySplit");
        // 数值校验对任何 pane 都生效：负值、非数字与 NaN/inf 都是损坏的输入，不因状态不同而放宽
        let rows = count(y_split)?;
        let columns = count(x_split)?;
        match pane.attr("state") {
            "frozen" | "frozenSplit" => {
                if fractional(y_split) || fractional(x_split) {
                    document.warn(
                        "Fractional XLSX frozen pane splits are truncated to whole rows or columns",
                    );
                }
                // 钳位到工作表已确定的行列维度，避免平台层按越界索引取偏移
                sheet.frozen_rows =
                    rows.min(u32::try_from(sheet.row_heights.len()).unwrap_or(u32::MAX));
                sheet.frozen_columns =
                    columns.min(u32::try_from(sheet.column_widths.len()).unwrap_or(u32::MAX));
            }
            "split" => document.warn("Non-frozen XLSX split panes are not supported"),
            // state 缺省但给出了拆分值时，Excel 与 OOXML 都按自由拆分处理，同样不支持。
            "" if rows != 0 || columns != 0 => {
                document.warn("Non-frozen XLSX split panes are not supported");
            }
            _ => (),
        }
        Ok(())
    }

    /// 选取目标 sheetView：优先 `workbookViewId="0"` 或未声明该属性的视图，全部非 0 时回退第一个
    fn target(views: &Node) -> Option<&Node> {
        let mut first = None;
        for view in views.named("sheetView") {
            let id = view.attr("workbookViewId");
            if id.is_empty() || id == "0" {
                return Some(view);
            }
            if first.is_none() {
                first = Some(view);
            }
        }
        first
    }

    /// 解析冻结分量：属性缺失或空串按 0 处理，其余必须是有限的非负数（兼容 `"2"` 与 `"2.0"`）
    fn count(value: &str) -> Result<u32> {
        if value.is_empty() {
            return Ok(0);
        }
        let number = value
            .parse::<f64>()
            .map_err(|_| Error::Invalid("Invalid XLSX frozen pane split"))?;
        if !number.is_finite() || number < 0.0 {
            return Err(Error::Invalid("Invalid XLSX frozen pane split"));
        }
        // 浮点转整数的 `as` 转换在 Rust 中是饱和语义，超出 u32 的极端值落到上限后再由维度钳位收敛
        Ok(number as u32)
    }

    /// 冻结态下是否存在非零小数部分（如 `"1.5"`），用于发出截断告警
    fn fractional(value: &str) -> bool {
        value
            .parse::<f64>()
            .is_ok_and(|number| number.is_finite() && number.fract() != 0.0)
    }
}
