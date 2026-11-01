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
