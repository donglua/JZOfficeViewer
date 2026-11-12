pub mod support;

use jz_office_core::{model::Document, parse_reader};
use std::io::Cursor;
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
 xmlns:v="urn:schemas-microsoft-com:vml">
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
