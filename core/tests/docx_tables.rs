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

#[test]
fn docx_table_vmerge_closes_when_row_omits_or_covers_column() -> TestResult {
    // 3 rows:
    // Row 0: Cell 0 restarts vMerge, Cell 1 normal, Cell 2 restarts vMerge
    // Row 1: Cell 0 continues vMerge, Cell 1 normal (Row 1 omits Cell 2)
    // Row 2: Cell 0 spans 2 cols without vMerge, Cell 2 normal
    let body = r#"
<w:tbl>
  <w:tblGrid>
    <w:gridCol w:w="2000"/><w:gridCol w:w="2000"/><w:gridCol w:w="2000"/>
  </w:tblGrid>
  <w:tr>
    <w:tc><w:tcPr><w:vMerge w:val="restart"/></w:tcPr><w:p><w:r><w:t>R0C0</w:t></w:r></w:p></w:tc>
    <w:tc><w:p><w:r><w:t>R0C1</w:t></w:r></w:p></w:tc>
    <w:tc><w:tcPr><w:vMerge w:val="restart"/></w:tcPr><w:p><w:r><w:t>R0C2</w:t></w:r></w:p></w:tc>
  </w:tr>
  <w:tr>
    <w:tc><w:tcPr><w:vMerge/></w:tcPr><w:p/></w:tc>
    <w:tc><w:p><w:r><w:t>R1C1</w:t></w:r></w:p></w:tc>
  </w:tr>
  <w:tr>
    <w:tc><w:tcPr><w:gridSpan w:val="2"/></w:tcPr><w:p><w:r><w:t>R2C0-1</w:t></w:r></w:p></w:tc>
    <w:tc><w:p><w:r><w:t>R2C2</w:t></w:r></w:p></w:tc>
  </w:tr>
</w:tbl>
"#;
    let parts = table_parts(body);
    let doc = parse_reader(Cursor::new(archive(&parts)?))?;
    let table = &doc.blocks[0];

    // Col 0: merged across Row 0..1 only (closed when Row 2 spans cols 0..1 without vMerge)
    assert!(table
        .merges
        .iter()
        .any(|m| m.start_row == 0 && m.end_row == 1 && m.start_column == 0 && m.end_column == 0));
    // Col 2: closed at row 0 because row 1 omitted col 2; it must NOT leak to row 2
    assert!(!table
        .merges
        .iter()
        .any(|m| m.start_column == 2 && m.end_row == 2));
    // Row 2: horizontal merge across cols 0..1
    assert!(table
        .merges
        .iter()
        .any(|m| m.start_row == 2 && m.end_row == 2 && m.start_column == 0 && m.end_column == 1));

    Ok(())
}

#[test]
fn docx_table_cell_contains_drawing_image() -> TestResult {
    let mut parts = support::docx::parts();
    let body = r#"
<w:tbl>
  <w:tblGrid><w:gridCol w:w="3000"/><w:gridCol w:w="3000"/></w:tblGrid>
  <w:tr>
    <w:tc><w:p><w:r><w:t>Cell with image</w:t></w:r></w:p></w:tc>
    <w:tc>
      <w:p>
        <w:r>
          <w:drawing>
            <wp:inline distT="0" distB="0" distL="0" distR="0">
              <wp:extent cx="914400" cy="457200"/>
              <wp:docPr id="1" name="Small teal PNG"/>
              <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>
              <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
                <pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="pixel.png"/><pic:cNvPicPr/></pic:nvPicPr>
                  <pic:blipFill><a:blip r:embed="rImage"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>
                  <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="457200"/></a:xfrm>
                    <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>
                </pic:pic>
              </a:graphicData></a:graphic>
            </wp:inline>
          </w:drawing>
        </w:r>
      </w:p>
    </w:tc>
  </w:tr>
</w:tbl>
"#;
    support::package::replace(
        &mut parts,
        "word/document.xml",
        &format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
 xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
 xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
 xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
 xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
  <w:body>{body}<w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr></w:body>
</w:document>"#
        ),
    );
    let doc = parse_reader(Cursor::new(archive(&parts)?))?;
    let table = &doc.blocks[0];
    assert_eq!(table.rows.len(), 1);
    let cell_img = &table.rows[0][1];
    assert!(!cell_img.is_empty());
    let para = &cell_img[0];
    assert!(para.image.is_some());
    assert_eq!(para.image.as_deref(), Some("word/media/pixel.png"));
    assert_eq!(para.image_width, Some(72.0));
    assert_eq!(para.image_height, Some(36.0));
    assert!(!doc
        .warnings
        .iter()
        .any(|w| w.contains("Images inside table cells are omitted")));
    Ok(())
}

#[test]
fn docx_table_parses_tbl_borders() -> TestResult {
    let body = r#"
<w:tbl>
  <w:tblPr>
    <w:tblBorders>
      <w:top w:val="single" w:sz="8" w:space="0" w:color="FF0000"/>
    </w:tblBorders>
  </w:tblPr>
  <w:tblGrid><w:gridCol w:w="3000"/></w:tblGrid>
  <w:tr>
    <w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc>
  </w:tr>
</w:tbl>
"#;
    let parts = table_parts(body);
    let doc = parse_reader(Cursor::new(archive(&parts)?))?;
    let table = &doc.blocks[0];
    assert_eq!(table.stroke, 0xffff0000);
    assert_eq!(table.stroke_width, 1.0);
    Ok(())
}
