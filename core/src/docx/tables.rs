use super::{alternate, format, skipped, Parser, MAX_CELLS, MAX_COLUMNS, MAX_ROWS};
use crate::model::{Element, ElementType, Paragraph};
use crate::xml::{self, Node};
use crate::{Error, Result};

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
        for row in node.named("tr") {
            if table.rows.len() >= MAX_ROWS {
                return Err(Error::Limit("DOCX table exceeds 500 rows"));
            }
            let properties = row.child("trPr");
            let before = grid_count(properties, "gridBefore", 0)?;
            let after = grid_count(properties, "gridAfter", 0)?;
            let mut cells = Vec::new();
            self.pad(&mut cells, before)?;
            for cell in row.named("tc") {
                let properties = cell.child("tcPr");
                let span = grid_count(properties, "gridSpan", 1)?;
                let end = cells.len() + span;
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
            }
            let end = cells.len() + after;
            self.pad(&mut cells, end)?;
            while table.column_widths.len() < end {
                table.column_widths.push(0.0);
            }
            table.rows.push(cells);
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
