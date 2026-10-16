pub mod support;

use jz_office_core::{parse_reader, Error};
use std::io::Cursor;
use support::{
    package::{archive, replace, TestResult},
    xlsx,
};

#[test]
fn workbook_without_visible_supported_sheets_is_rejected() -> TestResult {
    let mut parts = xlsx::parts();
    replace(
        &mut parts,
        "xl/workbook.xml",
        &xlsx::WORKBOOK.replace("<sheet name=", "<sheet state=\"hidden\" name="),
    );
    assert!(matches!(
        parse_reader(Cursor::new(archive(&parts)?)),
        Err(Error::Invalid(
            "Workbook has no visible supported worksheets"
        ))
    ));
    Ok(())
}

#[test]
fn hidden_sheets_are_skipped_with_warning() -> TestResult {
    let mut parts = xlsx::parts();
    replace(
        &mut parts,
        "xl/workbook.xml",
        &xlsx::WORKBOOK.replace(
            "name=\"Overview\"",
            "name=\"Overview\" state=\"veryHidden\"",
        ),
    );
    let document = parse_reader(Cursor::new(archive(&parts)?))?;
    assert_eq!(document.sheets.len(), 1);
    assert_eq!(document.sheets[0].name, "Data");
    assert!(!document.warnings.is_empty());
    Ok(())
}

#[test]
fn missing_style_part_and_implicit_references_use_defaults() -> TestResult {
    let mut parts = xlsx::parts();
    replace(
        &mut parts,
        "xl/_rels/workbook.xml.rels",
        &support::package::relationships(&[
            ("first", "worksheet", "worksheets/sheet1.xml"),
            ("second", "worksheet", "worksheets/sheet2.xml"),
        ]),
    );
    for path in ["xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml"] {
        replace(
            &mut parts,
            path,
            &xlsx::sheet(
                "<sheetData><row><c><v>12345678901234567890</v></c><c/></row></sheetData>",
            ),
        );
    }
    let document = parse_reader(Cursor::new(archive(&parts)?))?;
    assert_eq!(document.cell_styles.len(), 1);
    assert_eq!(document.sheets[0].cells[0].text, "12345678901234567890");
    assert_eq!(document.sheets[0].cells[1].column, 1);
    assert_eq!(document.sheets[0].cells[1].text, "");
    Ok(())
}

#[test]
fn unsupported_number_formats_retain_raw_value_and_warn() -> TestResult {
    let mut parts = xlsx::parts();
    replace(
        &mut parts,
        "xl/styles.xml",
        &xlsx::STYLES.replace("yyyy-mm-dd", "[Red][&lt;0]0.0;0.0"),
    );
    let document = parse_reader(Cursor::new(archive(&parts)?))?;
    let cell = document.sheets[0]
        .cells
        .iter()
        .find(|c| c.row == 3 && c.column == 1)
        .ok_or("Missing date cell")?;
    assert_eq!(cell.text, "45292");
    assert!(document
        .warnings
        .iter()
        .any(|w| w.contains("Unsupported number format")));
    Ok(())
}

#[test]
fn formula_cached_empty_string_is_a_valid_result() -> TestResult {
    let mut parts = xlsx::parts();
    replace(
        &mut parts,
        "xl/worksheets/sheet2.xml",
        &xlsx::sheet(
            r#"<sheetData><row><c t="str"><f>IF(1,"",1)</f><v/></c><c t="b"><f>1=2</f><v>0</v></c><c t="e"><f>1/0</f><v>#DIV/0!</v></c><c><f t="shared" si="0"/></c></row></sheetData>"#,
        ),
    );
    let document = parse_reader(Cursor::new(archive(&parts)?))?;
    let cells = &document.sheets[0].cells;
    assert_eq!(cells[0].text, "");
    assert_eq!(cells[1].text, "FALSE");
    assert_eq!(cells[2].text, "#DIV/0!");
    assert_eq!(cells[3].text, "[Formula result unavailable]");
    Ok(())
}

#[test]
fn column_defaults_and_out_of_order_definitions_preserve_extents() -> TestResult {
    let mut parts = xlsx::parts();
    replace(
        &mut parts,
        "xl/worksheets/sheet2.xml",
        &xlsx::sheet(
            r#"<sheetFormatPr defaultColWidth="20"/><cols><col min="5" max="5" width="30"/><col min="2" max="2"/></cols><sheetData/>"#,
        ),
    );
    let document = parse_reader(Cursor::new(archive(&parts)?))?;
    let widths = &document.sheets[0].column_widths;
    assert_eq!(widths.len(), 5);
    assert_eq!(widths[0], widths[1]);
    assert!(widths[4] > widths[0]);
    Ok(())
}

#[test]
fn row_and_column_styles_inherit_and_cell_override_wins() -> TestResult {
    let mut parts = xlsx::parts();
    replace(
        &mut parts,
        "xl/worksheets/sheet2.xml",
        &xlsx::sheet(
            r#"<cols><col min="1" max="2" style="2"/></cols><sheetData><row><c><v>1234</v></c></row><row s="3" customFormat="1"><c><v>0.5</v></c><c s="2"><v>2</v></c></row></sheetData>"#,
        ),
    );
    let document = parse_reader(Cursor::new(archive(&parts)?))?;
    let cells = &document.sheets[0].cells;
    assert_eq!(cells[0].text, "1,234.00");
    assert_eq!(cells[1].text, "50.00%");
    assert_eq!(cells[2].text, "2.00");
    Ok(())
}

#[test]
fn long_cells_retain_full_text_and_emit_truncation_warning_in_core() -> TestResult {
    let mut parts = xlsx::parts();
    let exact = "W".repeat(4096);
    let over = "W".repeat(4097);
    let emoji_split = format!("{}😀TAIL", "中".repeat(4094));
    let emoji_fit = format!("{}😀TAIL", "中".repeat(4093));
    replace(
        &mut parts,
        "xl/worksheets/sheet2.xml",
        &xlsx::sheet(&format!(
            r#"<sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>{exact}</t></is></c><c r="B1" t="inlineStr"><is><t>{over}</t></is></c><c r="C1" t="inlineStr"><is><t>{emoji_split}</t></is></c><c r="D1" t="inlineStr"><is><t>{emoji_fit}</t></is></c></row></sheetData>"#
        )),
    );
    let document = parse_reader(Cursor::new(archive(&parts)?))?;
    let cells = &document.sheets[0].cells;
    assert_eq!(cells[0].text, exact);
    assert_eq!(cells[1].text, format!("{}…", "W".repeat(4095)));
    assert_eq!(cells[2].text, format!("{}…", "中".repeat(4094)));
    assert_eq!(cells[3].text, format!("{}😀…", "中".repeat(4093)));
    assert_eq!(
        document
            .warnings
            .iter()
            .filter(|w| *w == "Long spreadsheet cell text is truncated in the preview")
            .count(),
        1
    );
    Ok(())
}
