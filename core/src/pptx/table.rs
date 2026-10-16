use super::flag;
use super::geometry::{points, Bounds};
use super::render::Render;
use crate::model::{Element, ElementType};
use crate::xml::Node;
use crate::{Error, Result};

impl Render<'_> {
    pub fn graphic(
        &mut self,
        part: &super::parts::Part,
        shape: &Node,
        bounds: Bounds,
    ) -> Result<Vec<Element>> {
        let data = shape.child("graphic").and_then(|n| n.child("graphicData"));
        if let Some(chart) = data.and_then(|n| n.child("chart")) {
            return self.chart(part, chart, bounds);
        }
        let Some(table) = data.and_then(|n| n.child("tbl")) else {
            match data.map_or("", |n| n.attr("uri")) {
                uri if uri.contains("diagram") => self.doc.warn("PPTX SmartArt is omitted."),
                _ => self
                    .doc
                    .warn("Unsupported PPTX graphic frames are omitted."),
            }
            return Ok(Vec::new());
        };
        let Some(grid) = table.child("tblGrid") else {
            self.doc
                .warn("PPTX tables with missing column widths are omitted.");
            return Ok(Vec::new());
        };
        let mut element = bounds.element(ElementType::TABLE);
        for column in grid.named("gridCol") {
            if element.column_widths.len() >= 32 {
                return Err(Error::Limit("PPTX table exceeds 32 columns"));
            }
            let width = points(column.attr("w"))
                .filter(|w| *w > 0.0)
                .ok_or(Error::Invalid("Invalid PPTX table column width"))?;
            element.column_widths.push(width);
        }
        if element.column_widths.is_empty() {
            return Err(Error::Invalid("PPTX table has no columns"));
        }
        let total_weight: f32 = element.column_widths.iter().map(|w| w.max(1.0)).sum();
        if total_weight > 0.0 && element.width > 0.0 {
            let table_width = element.width;
            for width in &mut element.column_widths {
                *width = table_width * width.max(1.0) / total_weight;
            }
        }
        for row in table.named("tr") {
            if element.rows.len() >= 500 {
                return Err(Error::Limit("PPTX table exceeds 500 rows"));
            }
            let mut cells = Vec::new();
            let mut fills = Vec::new();
            for cell in row.named("tc") {
                if cells.len() >= element.column_widths.len() {
                    return Err(Error::Invalid("PPTX table is not rectangular"));
                }
                self.budget.object()?;
                if !matches!(cell.attr("gridSpan"), "" | "1")
                    || !matches!(cell.attr("rowSpan"), "" | "1")
                    || flag(cell.attr("hMerge"), false)
                    || flag(cell.attr("vMerge"), false)
                {
                    self.doc
                        .warn("PPTX merged table cells are displayed as separate cells.");
                }
                let paragraphs = match cell.child("txBody") {
                    Some(body) => self.paragraphs(body, &[])?,
                    None => Vec::new(),
                };
                cells.push(paragraphs);
                let fill = match cell.child("tcPr") {
                    Some(properties) => self.theme.fill(properties, 0, self.doc),
                    None => 0,
                };
                fills.push(fill);
                if cell.child("tcPr").is_some() {
                    self.doc
                        .warn("PPTX cell borders, margins, and vertical alignment are simplified.");
                }
            }
            if cells.len() != element.column_widths.len() {
                return Err(Error::Invalid("PPTX table is not rectangular"));
            }
            element.rows.push(cells);
            element.cell_fills.push(fills);
        }
        if element.rows.is_empty() {
            return Ok(Vec::new());
        }
        self.doc.warn("PPTX table row heights are approximate.");
        if table.child("tblPr").is_some() {
            self.doc.warn("PPTX table styles are simplified.");
        }
        Ok(vec![element])
    }
}
