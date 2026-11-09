use super::{alternate, format, skipped, Parser, MAX_CELLS, MAX_COLUMNS, MAX_ROWS};
use crate::model::{CellRange, Element, ElementType, Paragraph};
use crate::xml::{self, Node};
use crate::{Error, Result};
use std::collections::HashMap;

impl Parser<'_> {
    pub(super) fn table(&mut self, node: &Node) -> Result<Element> {
        let mut table = Element {
            kind: ElementType::TABLE,
            stroke: 0xffdadce0,
            ..Element::default()
        };
        if let Some(grid) = node.child("tblGrid") {
            for column in grid.named("gridCol") {
                columns(table.column_widths.len() + 1)?;
                table
                    .column_widths
                    .push(format::points(column.attr("w"), 0.0));
            }
        }
        let mut active_v_merges: HashMap<usize, (u32, u32, u32)> = HashMap::new();
        for (r_idx, row) in node.named("tr").enumerate() {
            let row_num = r_idx as u32;
            if table.rows.len() >= MAX_ROWS {
                return Err(Error::Limit("DOCX table exceeds 500 rows"));
            }
            let properties = row.child("trPr");
            let before = grid_count(properties, "gridBefore", 0)?;
            let after = grid_count(properties, "gridAfter", 0)?;
            let mut cells = Vec::new();
            self.pad(&mut cells, before)?;
            let mut continued_in_row = Vec::new();
            for cell in row.named("tc") {
                let properties = cell.child("tcPr");
                let span = grid_count(properties, "gridSpan", 1)?;
                let start_col = cells.len() as u32;
                let end = cells.len() + span;
                let end_col = (end.saturating_sub(1)) as u32;
                columns(end)?;
                self.claim_cells(span)?;
                while table.column_widths.len() < end {
                    table.column_widths.push(0.0);
                }
                if span == 1 {
                    if let Some(width) = properties.and_then(|n| n.child("tcW")) {
                        if matches!(width.attr("type"), "" | "dxa") {
                            if let Some(slot) = table.column_widths.get_mut(cells.len()) {
                                if *slot == 0.0 {
                                    *slot = format::points(width.attr("w"), 0.0);
                                }
                            }
                        }
                    }
                }
                let mut paragraphs = Vec::new();
                self.cell(cell, &mut paragraphs)?;
                cells.push(paragraphs);
                cells.resize_with(end, Vec::new);

                let v_merge = properties.and_then(|p| p.child("vMerge"));
                match v_merge {
                    Some(vm) if vm.attr("val") == "restart" => {
                        for c in start_col..=end_col {
                            if let Some((s_row, s_col, e_col)) =
                                active_v_merges.remove(&(c as usize))
                            {
                                if s_row < row_num.saturating_sub(1) || e_col > s_col {
                                    table.merges.push(CellRange {
                                        start_row: s_row,
                                        start_column: s_col,
                                        end_row: row_num.saturating_sub(1),
                                        end_column: e_col,
                                    });
                                }
                            }
                        }
                        active_v_merges.insert(start_col as usize, (row_num, start_col, end_col));
                        continued_in_row.push(start_col as usize);
                    }
                    Some(_) => {
                        active_v_merges
                            .entry(start_col as usize)
                            .or_insert((row_num, start_col, end_col));
                        continued_in_row.push(start_col as usize);
                    }
                    None => {
                        for c in start_col..=end_col {
                            if let Some((s_row, s_col, e_col)) =
                                active_v_merges.remove(&(c as usize))
                            {
                                if s_row < row_num.saturating_sub(1) || e_col > s_col {
                                    table.merges.push(CellRange {
                                        start_row: s_row,
                                        start_column: s_col,
                                        end_row: row_num.saturating_sub(1),
                                        end_column: e_col,
                                    });
                                }
                            }
                        }
                        if span > 1 {
                            table.merges.push(CellRange {
                                start_row: row_num,
                                start_column: start_col,
                                end_row: row_num,
                                end_column: end_col,
                            });
                        }
                    }
                }
            }
            let mut uncontinued = Vec::new();
            for &c in active_v_merges.keys() {
                if !continued_in_row.contains(&c) {
                    uncontinued.push(c);
                }
            }
            for c in uncontinued {
                if let Some((s_row, s_col, e_col)) = active_v_merges.remove(&c) {
                    if s_row < row_num.saturating_sub(1) || e_col > s_col {
                        table.merges.push(CellRange {
                            start_row: s_row,
                            start_column: s_col,
                            end_row: row_num.saturating_sub(1),
                            end_column: e_col,
                        });
                    }
                }
            }
            let end = cells.len() + after;
            self.pad(&mut cells, end)?;
            while table.column_widths.len() < end {
                table.column_widths.push(0.0);
            }
            table.rows.push(cells);
        }
        let total_rows = table.rows.len() as u32;
        for (_, (s_row, s_col, e_col)) in active_v_merges {
            if s_row < total_rows.saturating_sub(1) || e_col > s_col {
                table.merges.push(CellRange {
                    start_row: s_row,
                    start_column: s_col,
                    end_row: total_rows.saturating_sub(1),
                    end_column: e_col,
                });
            }
        }
        if table.column_widths.is_empty() {
            table.column_widths.push(0.0);
        }
        for row in &mut table.rows {
            self.pad(row, table.column_widths.len())?;
        }
        let count = u16::try_from(table.column_widths.len())
            .map_err(|_| Error::Limit("DOCX table exceeds 32 columns"))?;
        let available = self.flow_width();
        for width in &mut table.column_widths {
            if *width <= 0.0 {
                *width = available / f32::from(count);
            }
        }
        let total: f32 = table.column_widths.iter().sum();
        let mut desired = total.min(available);
        if let Some(width) = node.child("tblPr").and_then(|n| n.child("tblW")) {
            let value = xml::number(width.attr("w"), 0.0);
            if value > 0.0 {
                desired = match width.attr("type") {
                    "" | "dxa" => (value / 20.0).clamp(1.0, available),
                    "pct" => (available * (value / 5000.0).min(1.0)).clamp(1.0, available),
                    _ => desired,
                };
            }
        }
        for width in &mut table.column_widths {
            *width = *width / total * desired;
        }
        table.width = desired;
        Ok(table)
    }

    fn cell(&mut self, parent: &Node, paragraphs: &mut Vec<Paragraph>) -> Result<()> {
        for node in &parent.children {
            match node.name.as_str() {
                "p" => {
                    for mut block in self.paragraph(node, true)? {
                        paragraphs.append(&mut block.paragraphs);
                    }
                }
                "tbl" => self.document.warn("Nested tables are omitted."),
                "sdt" => {
                    if let Some(content) = node.child("sdtContent") {
                        self.cell(content, paragraphs)?;
                    }
                }
                "AlternateContent" => {
                    if let Some(content) = alternate(node) {
                        self.cell(content, paragraphs)?;
                    }
                }
                name if skipped(name) => (),
                _ => self.cell(node, paragraphs)?,
            }
        }
        Ok(())
    }

    fn pad(&mut self, row: &mut Vec<Vec<Paragraph>>, count: usize) -> Result<()> {
        columns(count)?;
        self.claim_cells(count.saturating_sub(row.len()))?;
        row.resize_with(count, Vec::new);
        Ok(())
    }

    fn claim_cells(&mut self, count: usize) -> Result<()> {
        if count > MAX_CELLS.saturating_sub(self.cells) {
            return Err(Error::Limit("DOCX exceeds 5000 table cells"));
        }
        self.cells += count;
        Ok(())
    }
}

fn grid_count(properties: Option<&Node>, name: &str, fallback: usize) -> Result<usize> {
    let count = match properties.and_then(|n| n.child(name)) {
        Some(node) => node
            .attr("val")
            .parse::<usize>()
            .map_err(|_| Error::Invalid("Invalid DOCX table grid count"))?
            .max(fallback),
        None => fallback,
    };
    columns(count)?;
    Ok(count)
}

fn columns(count: usize) -> Result<()> {
    if count > MAX_COLUMNS {
        Err(Error::Limit("DOCX table exceeds 32 columns"))
    } else {
        Ok(())
    }
}
