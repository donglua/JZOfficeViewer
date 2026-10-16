use super::{format, rich_text, unsigned, Workbook};
use crate::model::{Cell, Document};
use crate::xml::Node;
use crate::{Error, Result};

impl Workbook {
    pub(super) fn style_index(&self, value: &str, fallback: u32) -> Result<u32> {
        let index = if value.is_empty() {
            fallback
        } else {
            unsigned(value)?
        };
        if usize::try_from(index)
            .ok()
            .is_none_or(|index| index >= self.styles.len())
        {
            return Err(Error::Invalid("Invalid XLSX cell style reference"));
        }
        Ok(index)
    }

    pub(super) fn cell(
        &mut self,
        node: &Node,
        mut cell: Cell,
        document: &mut Document,
    ) -> Result<Cell> {
        self.budget.cell()?;
        cell.style = self.style_index(node.attr("s"), cell.style)?;
        let formula = node.child("f");
        let value = node.child("v");
        if let Some(formula) = formula {
            if value.is_none_or(|value| value.text.is_empty() && node.attr("t") != "str") {
                cell.text = if formula.text.is_empty() {
                    "[Formula result unavailable]".to_owned()
                } else {
                    format!("={}", formula.text)
                };
                document.warn("Formula without a cached result is shown without evaluation");
                self.budget.text(&cell.text)?;
                truncate_preview(&mut cell.text, document);
                return Ok(cell);
            }
        }
        let raw = value.map_or("", |value| value.text.as_str());
        match node.attr("t") {
            "inlineStr" => {
                cell.text = node.child("is").map(rich_text).unwrap_or_default();
            }
            "s" => {
                let index = usize::try_from(unsigned(raw)?)
                    .map_err(|_| Error::Invalid("Invalid shared string index"))?;
                cell.text = self
                    .strings
                    .get(index)
                    .ok_or(Error::Invalid("Invalid shared string index"))?
                    .clone();
            }
            "b" => {
                cell.text = match raw {
                    "1" => "TRUE",
                    "0" => "FALSE",
                    _ => return Err(Error::Invalid("Invalid XLSX boolean cell")),
                }
                .to_owned();
            }
            "str" | "e" => cell.text = raw.to_owned(),
            "d" => {
                cell.text = raw.to_owned();
                document.warn("ISO date cells are displayed as stored without number formatting");
            }
            "" | "n" => {
                if !raw.is_empty() {
                    if !raw.parse::<f64>().is_ok_and(f64::is_finite) {
                        return Err(Error::Invalid("Invalid XLSX numeric cell"));
                    }
                    cell.numeric = true;
                    let index = usize::try_from(cell.style)
                        .map_err(|_| Error::Invalid("Invalid style index"))?;
                    let code = self.styles[index].format.as_deref();
                    cell.text = match code
                        .and_then(|code| format::display(raw, code, self.date1904))
                    {
                        Some(text) => text,
                        None => {
                            document.warn("Unsupported number format or precision; raw numeric value retained");
                            raw.to_owned()
                        }
                    };
                }
            }
            _ => return Err(Error::Invalid("Unsupported XLSX cell type")),
        }
        self.budget.text(&cell.text)?;
        truncate_preview(&mut cell.text, document);
        Ok(cell)
    }
}

const MAX_CELL_PREVIEW_UTF16: usize = 4096;

fn truncate_preview(text: &mut String, document: &mut Document) {
    if text.len() <= MAX_CELL_PREVIEW_UTF16 {
        return;
    }
    let mut units = 0_usize;
    let mut split_at = None;
    let mut last_boundary = 0_usize;
    for (idx, ch) in text.char_indices() {
        let len = ch.len_utf16();
        if units + len <= MAX_CELL_PREVIEW_UTF16 - 1 {
            last_boundary = idx + ch.len_utf8();
        }
        units += len;
        if units > MAX_CELL_PREVIEW_UTF16 {
            split_at = Some(last_boundary);
            break;
        }
    }
    if let Some(end) = split_at {
        text.truncate(end);
        text.push('\u{2026}');
        document.warn("Long spreadsheet cell text is truncated in the preview");
    }
}
