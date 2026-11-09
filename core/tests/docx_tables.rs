pub mod support;

use jz_office_core::parse_reader;
use std::io::Cursor;
use support::package::{archive, content_types, relationships, xml, Parts, TestResult};

fn table_parts(body: &str) -> Parts {
    vec![
        xml(
            "[Content_Types].xml",
            &content_types(&[("word/document.xml", "wordprocessingml.document.main")]),
        ),
        xml(
            "_rels/.rels",
            &relationships(&[("rOffice", "officeDocument", "word/document.xml")]),
        ),
        xml(
            "word/document.xml",
            &format!(
                r#"<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>{body}<w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr></w:body>
</w:document>"#
            ),
        ),
    ]
}

#[test]
fn docx_table_parses_horizontal_and_vertical_merges() -> TestResult {
    // 3 rows x 3 columns table:
    // Row 0: Cell 0 spans 2 columns (0..1), Cell 1 in col 2
    // Row 1: Cell 0 restarts vMerge, Cell 1 regular, Cell 2 regular
    // Row 2: Cell 0 continues vMerge, Cell 1 regular, Cell 2 regular
    let body = r#"
<w:tbl>
  <w:tblGrid>
    <w:gridCol w:w="2000"/>
    <w:gridCol w:w="2000"/>
    <w:gridCol w:w="2000"/>
  </w:tblGrid>
  <w:tr>
    <w:tc>
      <w:tcPr><w:gridSpan w:val="2"/></w:tcPr>
      <w:p><w:r><w:t>Merged H</w:t></w:r></w:p>
    </w:tc>
    <w:tc>
      <w:p><w:r><w:t>Col 2</w:t></w:r></w:p>
    </w:tc>
  </w:tr>
  <w:tr>
    <w:tc>
      <w:tcPr><w:vMerge w:val="restart"/></w:tcPr>
      <w:p><w:r><w:t>Merged V</w:t></w:r></w:p>
    </w:tc>
    <w:tc><w:p><w:r><w:t>R1C1</w:t></w:r></w:p></w:tc>
    <w:tc><w:p><w:r><w:t>R1C2</w:t></w:r></w:p></w:tc>
  </w:tr>
  <w:tr>
    <w:tc>
      <w:tcPr><w:vMerge/></w:tcPr>
      <w:p/>
    </w:tc>
    <w:tc><w:p><w:r><w:t>R2C1</w:t></w:r></w:p></w:tc>
    <w:tc><w:p><w:r><w:t>R2C2</w:t></w:r></w:p></w:tc>
  </w:tr>
</w:tbl>
"#;

    let parts = table_parts(body);
    let doc = parse_reader(Cursor::new(archive(&parts)?))?;
    let table = &doc.blocks[0];

    assert!(!table.merges.is_empty());
    // Horizontal merge: row 0, cols 0..1
    assert!(table
        .merges
        .iter()
        .any(|m| m.start_row == 0 && m.end_row == 0 && m.start_column == 0 && m.end_column == 1));
    // Vertical merge: rows 1..2, col 0
    assert!(table
        .merges
        .iter()
        .any(|m| m.start_row == 1 && m.end_row == 2 && m.start_column == 0 && m.end_column == 0));

    // Merged table warning is no longer emitted
    assert!(!doc
        .warnings
        .iter()
        .any(|w| w.contains("unmerged rectangular")));

    Ok(())
}
