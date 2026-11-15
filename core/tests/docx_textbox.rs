pub mod support;

use jz_office_core::model::{Document, ElementType, VerticalAlignment, WrapMode};
use jz_office_core::parse_reader;
use std::io::Cursor;
use support::checks;
use support::package::{archive, content_types, relationships, xml, Parts, TestResult};

fn parts(document_body: &str) -> Parts {
    vec![
        xml(
            "[Content_Types].xml",
            &content_types(&[("word/document.xml", "wordprocessingml.document.main")]),
        ),
        xml(
            "_rels/.rels",
            &relationships(&[("rOffice", "officeDocument", "word/document.xml")]),
        ),
        xml("word/document.xml", &document_xml(document_body)),
        xml(
            "word/_rels/document.xml.rels",
            &relationships(&[] as &[(&str, &str, &str)]),
        ),
    ]
}

fn document_xml(body: &str) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
 xmlns:v="urn:schemas-microsoft-com:vml"
 xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
 xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
 xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
 xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">
  <w:body>{body}<w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr></w:body>
</w:document>"#
    )
}

fn parse(body: &str) -> TestResult<Document> {
    let parts = parts(body);
    let archive = archive(&parts)?;
    Ok(parse_reader(Cursor::new(archive))?)
}

fn texts(document: &Document) -> Vec<String> {
    document
        .blocks
        .iter()
        .flat_map(|block| block.paragraphs.iter())
        .flat_map(|paragraph| paragraph.runs.iter())
        .map(|run| run.text.clone())
        .filter(|text| !text.is_empty())
        .collect()
}

#[test]
fn preserves_text_box_paragraphs_in_flow() -> TestResult {
    // Given a run-level legacy pict whose text box holds two paragraphs.
    let document = parse(
        r#"<w:p><w:r><w:t>Before</w:t></w:r></w:p>
<w:p><w:r><w:pict><v:shape><v:textbox><w:txbxContent>
  <w:p><w:r><w:t>First box line</w:t></w:r></w:p>
  <w:p><w:r><w:t>Second box line</w:t></w:r></w:p>
</w:txbxContent></v:textbox></v:shape></w:pict></w:r></w:p>
<w:p><w:r><w:t>After</w:t></w:r></w:p>"#,
    )?;

    // Then the box text is preserved in order instead of being dropped.
    assert_eq!(
        texts(&document),
        vec!["Before", "First box line", "Second box line", "After"]
    );
    assert!(document
        .warnings
        .iter()
        .all(|warning| !warning.contains("text boxes are omitted")));
    Ok(())
}

#[test]
fn preserves_body_level_text_box_content() -> TestResult {
    // Given a body-level txbxContent without any legacy drawing wrapper.
    let document =
        parse(r#"<w:txbxContent><w:p><w:r><w:t>Body level box</w:t></w:r></w:p></w:txbxContent>"#)?;

    // Then its paragraphs are still emitted.
    assert_eq!(texts(&document), vec!["Body level box"]);
    Ok(())
}

#[test]
fn skips_object_without_text_box() -> TestResult {
    // Given an embedded object with no text box content.
    let document = parse(r#"<w:p><w:r><w:object><v:shape/></w:object></w:r></w:p>"#)?;

    // Then nothing is emitted for it and parsing does not fail.
    assert!(texts(&document).is_empty());
    Ok(())
}

#[test]
fn parses_wps_shape_textbox_deduplicating_fallback_and_indexes_search() -> TestResult {
    let document = parse(
        r#"<w:p><w:r><mc:AlternateContent>
  <mc:Choice Requires="wps">
    <w:drawing><wp:anchor distT="0" distB="63500" distL="0" distR="127000" behindDoc="0">
      <wp:positionH relativeFrom="column"><wp:align>right</wp:align></wp:positionH>
      <wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>
      <wp:extent cx="2286000" cy="1143000"/>
      <wp:wrapSquare wrapText="bothSides"/>
      <a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">
        <wps:wsp>
          <wps:cNvSpPr txBox="1"/>
          <wps:spPr>
            <a:xfrm><a:off x="0" y="0"/><a:ext cx="2286000" cy="1143000"/></a:xfrm>
            <a:prstGeom prst="roundRect"><a:avLst/></a:prstGeom>
            <a:solidFill><a:srgbClr val="E8F0FE"/></a:solidFill>
            <a:ln w="25400"><a:solidFill><a:srgbClr val="1A73E8"/></a:solidFill></a:ln>
          </wps:spPr>
          <wps:txbx><w:txbxContent>
            <w:p><w:r><w:t>Callout Title</w:t></w:r></w:p>
            <w:p><w:r><w:t>Searchable shape body</w:t></w:r></w:p>
          </w:txbxContent></wps:txbx>
          <wps:bodyPr wrap="square" lIns="127000" tIns="127000" rIns="127000" bIns="127000" anchor="ctr"/>
        </wps:wsp>
      </a:graphicData></a:graphic>
    </wp:anchor></w:drawing>
  </mc:Choice>
  <mc:Fallback>
    <w:pict><v:shape><v:textbox><w:txbxContent>
      <w:p><w:r><w:t>Fallback Duplicate</w:t></w:r></w:p>
    </w:txbxContent></v:textbox></v:shape></w:pict>
  </mc:Fallback>
</mc:AlternateContent></w:r><w:r><w:t>Main body paragraph</w:t></w:r></w:p>"#,
    )?;

    assert_eq!(document.blocks.len(), 2);
    let shape = &document.blocks[0];
    assert!(matches!(shape.kind, ElementType::PATH));
    assert_eq!(shape.wrap_mode, WrapMode::Square);
    assert_eq!(shape.horizontal_align, 3);
    assert_eq!(shape.fill, 0xFFE8_F0FE);
    assert_eq!(shape.stroke, 0xFF1A_73E8);
    checks::near(shape.stroke_width, 2.0);
    checks::near(shape.padding, 10.0);
    assert_eq!(shape.vertical_alignment, VerticalAlignment::Center);
    assert!(shape.text_wrap);
    assert_eq!(shape.paragraphs.len(), 2);
    assert!(!texts(&document).iter().any(|t| t == "Fallback Duplicate"));

    let hits = document.search("Searchable");
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].element_index, 0);
    assert_eq!(hits[0].paragraph_index, 1);
    assert_eq!(hits[0].start_char, 0);
    assert_eq!(hits[0].end_char, 10);
    Ok(())
}
