pub mod support;

use jz_office_core::parse_reader;
use std::io::Cursor;
use support::package::{archive, content_types, relationships, xml, Parts, TestResult};

fn numbering_parts(document_body: &str, numbering_body: &str) -> Parts {
    vec![
        xml(
            "[Content_Types].xml",
            &content_types(&[
                ("word/document.xml", "wordprocessingml.document.main"),
                ("word/numbering.xml", "wordprocessingml.numbering"),
            ]),
        ),
        xml(
            "_rels/.rels",
            &relationships(&[("rOffice", "officeDocument", "word/document.xml")]),
        ),
        xml("word/document.xml", &document_xml(document_body)),
        xml("word/numbering.xml", &numbering_xml(numbering_body)),
        xml(
            "word/_rels/document.xml.rels",
            &relationships(&[("rNum", "numbering", "numbering.xml")]),
        ),
    ]
}

fn document_xml(body: &str) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>{body}<w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr></w:body>
</w:document>"#
    )
}

fn numbering_xml(body: &str) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  {body}
</w:numbering>"#
    )
}

#[test]
fn docx_numbering_formats_ordered_and_nested_lists() -> TestResult {
    let numbering = r#"
<w:abstractNum w:abstractNumId="0">
  <w:lvl w:ilvl="0">
    <w:start w:val="1"/>
    <w:numFmt w:val="decimal"/>
    <w:lvlText w:val="%1."/>
  </w:lvl>
  <w:lvl w:ilvl="1">
    <w:start w:val="1"/>
    <w:numFmt w:val="lowerLetter"/>
    <w:lvlText w:val="(%2)"/>
  </w:lvl>
</w:abstractNum>
<w:num w:numId="1">
  <w:abstractNumId w:val="0"/>
</w:num>
"#;

    let body = r#"
<w:p>
  <w:pPr><w:numPr><w:numId w:val="1"/><w:ilvl w:val="0"/></w:numPr></w:pPr>
  <w:r><w:t>First</w:t></w:r>
</w:p>
<w:p>
  <w:pPr><w:numPr><w:numId w:val="1"/><w:ilvl w:val="0"/></w:numPr></w:pPr>
  <w:r><w:t>Second</w:t></w:r>
</w:p>
<w:p>
  <w:pPr><w:numPr><w:numId w:val="1"/><w:ilvl w:val="1"/></w:numPr></w:pPr>
  <w:r><w:t>Subitem</w:t></w:r>
</w:p>
<w:p>
  <w:pPr><w:numPr><w:numId w:val="1"/><w:ilvl w:val="0"/></w:numPr></w:pPr>
  <w:r><w:t>Third</w:t></w:r>
</w:p>
"#;

    let parts = numbering_parts(body, numbering);
    let doc = parse_reader(Cursor::new(archive(&parts)?))?;

    assert_eq!(doc.blocks[0].paragraphs[0].bullet, "1. ");
    assert_eq!(doc.blocks[1].paragraphs[0].bullet, "2. ");
    assert_eq!(doc.blocks[2].paragraphs[0].bullet, "(a) ");
    assert_eq!(doc.blocks[3].paragraphs[0].bullet, "3. ");
    assert!(!doc.warnings.iter().any(|w| w.contains("fallback bullets")));

    Ok(())
}

#[test]
fn docx_numbering_multi_level_preserves_each_referenced_level_format() -> TestResult {
    let numbering = r#"
<w:abstractNum w:abstractNumId="0">
  <w:lvl w:ilvl="0">
    <w:start w:val="1"/>
    <w:numFmt w:val="upperRoman"/>
    <w:lvlText w:val="Chapter %1"/>
  </w:lvl>
  <w:lvl w:ilvl="1">
    <w:start w:val="1"/>
    <w:numFmt w:val="decimal"/>
    <w:lvlText w:val="%1.%2"/>
  </w:lvl>
</w:abstractNum>
<w:num w:numId="1">
  <w:abstractNumId w:val="0"/>
</w:num>
"#;

    let body = r#"
<w:p>
  <w:pPr><w:numPr><w:numId w:val="1"/><w:ilvl w:val="0"/></w:numPr></w:pPr>
  <w:r><w:t>Introduction</w:t></w:r>
</w:p>
<w:p>
  <w:pPr><w:numPr><w:numId w:val="1"/><w:ilvl w:val="1"/></w:numPr></w:pPr>
  <w:r><w:t>Background</w:t></w:r>
</w:p>
"#;

    let parts = numbering_parts(body, numbering);
    let doc = parse_reader(Cursor::new(archive(&parts)?))?;

    assert_eq!(doc.blocks[0].paragraphs[0].bullet, "Chapter I ");
    assert_eq!(doc.blocks[1].paragraphs[0].bullet, "I.1 ");

    Ok(())
}
