pub mod support;

use jz_office_core::{model::ElementType, parse_reader};
use std::io::Cursor;
use support::package::{archive, replace, TestResult};
use support::pptx;

fn table_json(fills: &[&str]) -> TestResult<serde_json::Value> {
    let mut parts = pptx::parts();
    let cells = fills
        .iter()
        .map(|fill| format!(r#"<a:tc><a:txBody><a:bodyPr/><a:p><a:r><a:t>Cell</a:t></a:r></a:p></a:txBody><a:tcPr>{fill}</a:tcPr></a:tc>"#))
        .collect::<Vec<_>>();
    let rows = cells
        .chunks(3)
        .map(|row| format!(r#"<a:tr h="421430">{}</a:tr>"#, row.join("")))
        .collect::<String>();
    replace(
        &mut parts,
        "ppt/slides/slide2.xml",
        &format!(
            r#"
<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
<p:cSld><p:spTree><p:graphicFrame><p:xfrm><a:off x="0" y="0"/><a:ext cx="9144000" cy="2528580"/></p:xfrm>
<a:graphic><a:graphicData><a:tbl><a:tblPr/><a:tblGrid><a:gridCol w="3048000"/><a:gridCol w="3048000"/><a:gridCol w="3048000"/></a:tblGrid>{rows}</a:tbl></a:graphicData></a:graphic>
</p:graphicFrame></p:spTree></p:cSld></p:sld>"#
        ),
    );
    let document = parse_reader(Cursor::new(archive(&parts)?))?;
    let table = document.pages[0]
        .elements
        .iter()
        .find(|e| matches!(e.kind, ElementType::TABLE))
        .ok_or("table missing")?;
    Ok(serde_json::to_value(table)?)
}

#[test]
fn translucent_header_and_fully_transparent_body_fills_survive_serialization() -> TestResult {
    let header =
        r#"<a:solidFill><a:srgbClr val="3D8F8A"><a:alpha val="20000"/></a:srgbClr></a:solidFill>"#;
    let body =
        r#"<a:solidFill><a:srgbClr val="FFFFFF"><a:alpha val="0"/></a:srgbClr></a:solidFill>"#;
    let json = table_json(&[header, header, header, body, body, body])?;
    assert_eq!(
        json["cellFills"],
        serde_json::json!([
            [0x333d8f8au32, 0x333d8f8au32, 0x333d8f8au32],
            [0x00ffffffu32, 0x00ffffffu32, 0x00ffffffu32]
        ])
    );
    assert_eq!(json["rows"][0][0][0]["runs"][0]["text"], "Cell");
    Ok(())
}

#[test]
fn table_cell_theme_colors_and_explicit_or_missing_no_fill_are_preserved() -> TestResult {
    let json = table_json(&[
        r#"<a:solidFill><a:schemeClr val="dk1"/></a:solidFill>"#,
        "<a:noFill/>",
        "",
    ])?;
    assert_eq!(
        json["cellFills"],
        serde_json::json!([[0xff202124u32, 0, 0]])
    );
    assert_eq!(
        json["columnWidths"],
        serde_json::json!([240.0, 240.0, 240.0])
    );
    Ok(())
}
