mod appearance;
mod cells;
mod colors;
mod coordinates;
mod dates;
mod format;
mod styles;
mod worksheet;

pub(crate) use format::display as format_value;

use crate::model::{Document, Kind};
use crate::xml::Node;
use crate::{Error, Package, Result};
use styles::Style;

const MAX_ROWS: u32 = 10_000;
pub(crate) const MAX_COLUMNS: u32 = 256;
const MAX_STYLES: usize = 2_048;
pub(crate) const MAX_SHEETS: usize = 32;
const MAX_CELLS: usize = 50_000;
const MAX_TEXT: usize = 8 * 1024 * 1024;

#[derive(Default)]
struct Budget {
    cells: usize,
    text: usize,
    merges: usize,
}

impl Budget {
    fn text(&mut self, value: &str) -> Result<()> {
        self.text += value.len();
        if self.text > MAX_TEXT {
            return Err(Error::Limit("XLSX text exceeds 8 MiB"));
        }
        Ok(())
    }

    fn cell(&mut self) -> Result<()> {
        self.cells += 1;
        if self.cells > MAX_CELLS {
            return Err(Error::Limit("XLSX exceeds 50000 stored cells"));
        }
        Ok(())
    }
}

struct Workbook {
    styles: Vec<Style>,
    strings: Vec<String>,
    date1904: bool,
    budget: Budget,
}

pub(crate) fn parse(package: &mut Package, part: &str, scope: crate::Scope) -> Result<Document> {
    let root = package.xml(part)?;
    let mut document = Document::new(Kind::XLSX);
    let sheet_nodes = root
        .child("sheets")
        .ok_or(Error::Invalid("Missing XLSX sheets"))?;
    if sheet_nodes.named("sheet").count() > MAX_SHEETS {
        return Err(Error::Limit("XLSX exceeds 32 sheets"));
    }
    let theme = related_xml(package, part, "theme")?;
    let style_root = related_xml(package, part, "styles")?;
    let styles = styles::parse(style_root.as_ref(), theme.as_ref(), &mut document)?;
    document.cell_styles = styles.iter().map(|style| style.cell.clone()).collect();
    let mut workbook = Workbook {
        styles,
        strings: Vec::new(),
        date1904: root
            .child("workbookPr")
            .map_or(Ok(false), |n| boolean(n.attr("date1904"), false))?,
        budget: Budget::default(),
    };
    if let Some(strings) = related_xml(package, part, "sharedStrings")? {
        if strings.name != "sst" {
            return Err(Error::Invalid("Invalid shared strings part"));
        }
        for node in strings.named("si") {
            if workbook.strings.len() >= MAX_CELLS {
                return Err(Error::Limit("XLSX exceeds 50000 shared strings"));
            }
            let text = rich_text(node);
            workbook.budget.text(&text)?;
            workbook.strings.push(text);
        }
    }
    let relationships = package.relationships(part)?;
    let mut names = std::collections::HashSet::new();
    // 首屏范围只解析首个可见工作表，其余工作表保留名称以便页数与切表栏仍可展示
    let first_viewport = scope == crate::Scope::FirstViewport;
    let mut parsed_sheets = 0_usize;
    for sheet in sheet_nodes.named("sheet") {
        let name = sheet.attr("name");
        if name.is_empty() || !names.insert(name.to_owned()) {
            return Err(Error::Invalid("Missing or duplicate XLSX sheet name"));
        }
        workbook.budget.text(name)?;
        match sheet.attr("state") {
            "hidden" | "veryHidden" => {
                document.warn("Hidden worksheets are not displayed");
                continue;
            }
            "" | "visible" => (),
            _ => return Err(Error::Invalid("Invalid worksheet visibility")),
        }
        let target = relationships
            .get(sheet.attr("r:id"))
            .ok_or(Error::Invalid("Missing worksheet relationship"))?;
        if first_viewport && parsed_sheets > 0 {
            // 首屏之外的工作表只保留名称与一格占位维度：页数与切表栏仍完整，但不读取其行列数据。
            // 平台层解码器要求行列维度非空（完整解析同样至少有 1 行 1 列），占位值不参与任何绘制。
            document.sheets.push(crate::spreadsheet::Sheet {
                name: name.to_owned(),
                row_heights: vec![15.0],
                column_widths: vec![48.0],
                cells: Vec::new(),
                merges: Vec::new(),
                geometry: Some(crate::spreadsheet::SheetGeometry::compute(
                    &crate::spreadsheet::Sheet {
                        name: name.to_owned(),
                        row_heights: vec![15.0],
                        column_widths: vec![48.0],
                        cells: Vec::new(),
                        merges: Vec::new(),
                        geometry: None,
                    },
                )),
            });
            continue;
        }
        let node = package.xml(target)?;
        if node.name != "worksheet" {
            document.warn("Non-worksheet sheets are not supported");
            continue;
        }
        let mut parsed = worksheet::parse(&node, name, &mut workbook, &mut document)?;
        parsed.geometry = Some(crate::spreadsheet::SheetGeometry::compute(&parsed));
        document.sheets.push(parsed);
        parsed_sheets += 1;
    }
    if document.sheets.is_empty() {
        return Err(Error::Invalid(
            "Workbook has no visible supported worksheets",
        ));
    }
    Ok(document)
}

fn related_xml(package: &mut Package, source: &str, kind: &str) -> Result<Option<Node>> {
    match package.related_by_type(source, kind)? {
        Some(part) => package.xml(&part).map(Some),
        None => Ok(None),
    }
}

fn boolean(value: &str, fallback: bool) -> Result<bool> {
    match value {
        "" => Ok(fallback),
        "1" | "true" => Ok(true),
        "0" | "false" => Ok(false),
        _ => Err(Error::Invalid("Invalid XLSX boolean")),
    }
}

fn unsigned(value: &str) -> Result<u32> {
    if value.is_empty() || !value.bytes().all(|b| b.is_ascii_digit()) {
        return Err(Error::Invalid("Invalid XLSX integer"));
    }
    value
        .parse()
        .map_err(|_| Error::Invalid("Invalid XLSX integer"))
}

fn dimension(value: &str, fallback: f32, maximum: f32) -> Result<f32> {
    if value.is_empty() {
        return Ok(fallback);
    }
    let value = value
        .parse::<f32>()
        .map_err(|_| Error::Invalid("Invalid XLSX dimension"))?;
    if !value.is_finite() || !(0.0..=maximum).contains(&value) {
        return Err(Error::Invalid("Invalid XLSX dimension"));
    }
    Ok(value)
}

fn rich_text(node: &Node) -> String {
    let mut result = String::new();
    for child in &node.children {
        match child.name.as_str() {
            "t" => result.push_str(&child.text),
            "r" => {
                for text in child.named("t") {
                    result.push_str(&text.text);
                }
            }
            _ => (),
        }
    }
    result
}
