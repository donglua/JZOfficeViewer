pub mod support;

use jz_office_core::parse_reader;
use std::io::Cursor;
use support::{
    package::{archive, replace, TestResult},
    xlsx,
};

#[test]
fn zero_alpha_spreadsheet_colors_are_opaque_for_font_fill_and_borders() -> TestResult {
    let mut parts = xlsx::parts();
    let styles = xlsx::STYLES
        .replace("FFFFFFFF", "00FFFFFF")
        .replace("FF24745C", "0024745C")
        .replace("FF112233", "00112233");
    replace(&mut parts, "xl/styles.xml", &styles);

    let document = parse_reader(Cursor::new(archive(&parts)?))?;

    let style = &document.cell_styles[1];
    assert_eq!(style.color, 0xffffffff);
    assert_eq!(style.fill, 0xff24745c);
    assert_eq!(style.borders, [Some(0xff112233); 4]);
    assert_eq!(document.cell_styles[0].fill, 0);
    Ok(())
}

#[test]
fn parses_font_face_strike_and_vert_align() -> TestResult {
    let mut parts = xlsx::parts();
    let styles = r#"<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<fonts count="1">
  <font>
    <name val="Times New Roman"/>
    <strike/>
    <vertAlign val="subscript"/>
    <sz val="14"/>
  </font>
</fonts>
<fills count="1"><fill><patternFill patternType="none"/></fill></fills>
<borders count="1"><border><left/><right/><top/><bottom/></border></borders>
<cellStyleXfs count="1"><xf/></cellStyleXfs>
<cellXfs count="1">
  <xf fontId="0" applyFont="1"/>
</cellXfs>
</styleSheet>"#;
    replace(&mut parts, "xl/styles.xml", styles);
    for path in ["xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml"] {
        replace(&mut parts, path, &xlsx::sheet("<sheetData/>"));
    }
    let document = parse_reader(Cursor::new(archive(&parts)?))?;
    let cell_style = &document.cell_styles[0];
    assert_eq!(cell_style.font_face, "Times New Roman");
    assert!(cell_style.strike);
    assert_eq!(
        cell_style.vert_align,
        jz_office_core::model::VertAlign::Subscript
    );
    assert!(document
        .warnings
        .iter()
        .all(|w| !w.contains("Strikethrough and superscript")));
    Ok(())
}

#[test]
fn xlsx_font_name_exceeds_256_bytes_returns_limit_error() -> TestResult {
    let mut parts = xlsx::parts();
    let long_name = "A".repeat(257);
    let styles = format!(
        r#"<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<fonts count="1">
  <font><name val="{long_name}"/></font>
</fonts>
<fills count="1"><fill><patternFill patternType="none"/></fill></fills>
<borders count="1"><border/></borders>
<cellStyleXfs count="1"><xf/></cellStyleXfs>
<cellXfs count="1"><xf fontId="0" applyFont="1"/></cellXfs>
</styleSheet>"#
    );
    replace(&mut parts, "xl/styles.xml", &styles);
    for path in ["xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml"] {
        replace(&mut parts, path, &xlsx::sheet("<sheetData/>"));
    }
    assert!(matches!(
        parse_reader(Cursor::new(archive(&parts)?)),
        Err(jz_office_core::Error::Limit(_))
    ));
    Ok(())
}

#[test]
fn parses_xlsx_rfont_and_superscript() -> TestResult {
    let mut parts = xlsx::parts();
    let styles = r#"<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<fonts count="1">
  <font>
    <rFont val="Calibri"/>
    <strike val="false"/>
    <vertAlign val="superscript"/>
  </font>
</fonts>
<fills count="1"><fill><patternFill patternType="none"/></fill></fills>
<borders count="1"><border/></borders>
<cellStyleXfs count="1"><xf/></cellStyleXfs>
<cellXfs count="1"><xf fontId="0" applyFont="1"/></cellXfs>
</styleSheet>"#;
    replace(&mut parts, "xl/styles.xml", styles);
    for path in ["xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml"] {
        replace(&mut parts, path, &xlsx::sheet("<sheetData/>"));
    }
    let document = parse_reader(Cursor::new(archive(&parts)?))?;
    let cell_style = &document.cell_styles[0];
    assert_eq!(cell_style.font_face, "Calibri");
    assert!(!cell_style.strike);
    assert_eq!(
        cell_style.vert_align,
        jz_office_core::model::VertAlign::Superscript
    );
    Ok(())
}
