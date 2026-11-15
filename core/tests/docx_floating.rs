pub mod support;

use jz_office_core::model::{Document, ElementType, WrapMode};
use jz_office_core::parse_reader;
use std::io::Cursor;
use support::checks;
use support::package::{archive, content_types, relationships, xml, Parts, TestResult, PNG};

fn docx_parts(body: &str) -> Parts {
    let document = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
 xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
 xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
 xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
 xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
  <w:body>{body}<w:sectPr><w:pgSz w:w="11900" w:h="16840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr></w:body>
</w:document>"#
    );
    vec![
        xml(
            "[Content_Types].xml",
            &content_types(&[("word/document.xml", "wordprocessingml.document.main")]),
        ),
        xml(
            "_rels/.rels",
            &relationships(&[("rOffice", "officeDocument", "word/document.xml")]),
        ),
        xml("word/document.xml", &document),
        xml(
            "word/_rels/document.xml.rels",
            &relationships(&[("rImage", "image", "media/pixel.png")]),
        ),
        ("word/media/pixel.png", PNG.to_vec()),
    ]
}

fn parse_docx(body: &str) -> TestResult<Document> {
    let bytes = archive(&docx_parts(body))?;
    Ok(parse_reader(Cursor::new(bytes))?)
}

fn anchor_image_xml(attrs: &str, pos_h: &str, pos_v: &str, wrap: &str) -> String {
    format!(
        r#"<w:r><w:drawing><wp:anchor {attrs}>
  <wp:simplePos x="0" y="0"/>
  {pos_h}
  {pos_v}
  <wp:extent cx="914400" cy="457200"/>
  <wp:docPr id="1" name="Anchor PNG"/>
  <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
    <pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="pixel.png"/><pic:cNvPicPr/></pic:nvPicPr>
      <pic:blipFill><a:blip r:embed="rImage"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>
    </pic:pic>
  </a:graphicData></a:graphic>
  {wrap}
</wp:anchor></w:drawing></w:r>"#
    )
}

#[test]
fn parses_anchor_wrap_modes_distances_and_behind_doc() -> TestResult {
    let square = anchor_image_xml(
        r#"distT="63500" distB="127000" distL="114300" distR="114300" behindDoc="0""#,
        r#"<wp:positionH relativeFrom="column"><wp:align>left</wp:align></wp:positionH>"#,
        r#"<wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>"#,
        r#"<wp:wrapSquare wrapText="bothSides"/>"#,
    );
    let tight = anchor_image_xml(
        r#"behindDoc="0""#,
        r#"<wp:positionH relativeFrom="column"><wp:align>right</wp:align></wp:positionH>"#,
        r#"<wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>"#,
        r#"<wp:wrapTight wrapText="bothSides"/>"#,
    );
    let through = anchor_image_xml(
        r#"behindDoc="0""#,
        r#"<wp:positionH relativeFrom="column"><wp:align>left</wp:align></wp:positionH>"#,
        r#"<wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>"#,
        r#"<wp:wrapThrough wrapText="bothSides"/>"#,
    );
    let top_bottom = anchor_image_xml(
        r#"distT="38100" distB="76200""#,
        r#"<wp:positionH relativeFrom="column"><wp:align>center</wp:align></wp:positionH>"#,
        r#"<wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>"#,
        r#"<wp:wrapTopAndBottom/>"#,
    );
    let behind = anchor_image_xml(
        r#"behindDoc="1""#,
        r#"<wp:positionH relativeFrom="column"><wp:posOffset>0</wp:posOffset></wp:positionH>"#,
        r#"<wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>"#,
        r#"<wp:wrapNone/>"#,
    );
    let front = anchor_image_xml(
        r#"behindDoc="0""#,
        r#"<wp:positionH relativeFrom="column"><wp:posOffset>0</wp:posOffset></wp:positionH>"#,
        r#"<wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>"#,
        r#"<wp:wrapNone/>"#,
    );

    let body = format!(
        "<w:p>{square}</w:p><w:p>{tight}</w:p><w:p>{through}</w:p><w:p>{top_bottom}</w:p><w:p>{behind}</w:p><w:p>{front}</w:p>"
    );
    let doc = parse_docx(&body)?;
    assert_eq!(doc.blocks.len(), 6);

    assert_eq!(doc.blocks[0].wrap_mode, WrapMode::Square);
    assert!(!doc.blocks[0].behind_doc);
    checks::near(doc.blocks[0].dist_top, 5.0);
    checks::near(doc.blocks[0].dist_bottom, 10.0);
    checks::near(doc.blocks[0].dist_left, 9.0);
    checks::near(doc.blocks[0].dist_right, 9.0);

    assert_eq!(doc.blocks[1].wrap_mode, WrapMode::Tight);
    assert_eq!(doc.blocks[2].wrap_mode, WrapMode::Through);

    assert_eq!(doc.blocks[3].wrap_mode, WrapMode::TopAndBottom);
    checks::near(doc.blocks[3].dist_top, 3.0);
    checks::near(doc.blocks[3].dist_bottom, 6.0);

    assert_eq!(doc.blocks[4].wrap_mode, WrapMode::None);
    assert!(doc.blocks[4].behind_doc);

    assert_eq!(doc.blocks[5].wrap_mode, WrapMode::None);
    assert!(!doc.blocks[5].behind_doc);

    assert!(doc
        .warnings
        .iter()
        .all(|w| !w.contains("anchors and wrapping are ignored") && !w.contains("Inline images")));
    Ok(())
}

#[test]
fn parses_anchor_position_h_align_and_offsets() -> TestResult {
    // page_width = 11900 / 20 = 595, margin_left/right = 1440 / 20 = 72, content_width = 451, image width = 72
    let align_left = anchor_image_xml(
        "",
        r#"<wp:positionH relativeFrom="column"><wp:align>left</wp:align></wp:positionH>"#,
        r#"<wp:positionV relativeFrom="paragraph"><wp:posOffset>127000</wp:posOffset></wp:positionV>"#,
        r#"<wp:wrapSquare/>"#,
    );
    let align_center = anchor_image_xml(
        "",
        r#"<wp:positionH relativeFrom="column"><wp:align>center</wp:align></wp:positionH>"#,
        r#"<wp:positionV relativeFrom="margin"><wp:posOffset>127000</wp:posOffset></wp:positionV>"#,
        r#"<wp:wrapTopAndBottom/>"#,
    );
    let align_right = anchor_image_xml(
        "",
        r#"<wp:positionH relativeFrom="column"><wp:align>right</wp:align></wp:positionH>"#,
        r#"<wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>"#,
        r#"<wp:wrapSquare/>"#,
    );
    let offset_page = anchor_image_xml(
        "",
        r#"<wp:positionH relativeFrom="page"><wp:posOffset>254000</wp:posOffset></wp:positionH>"#,
        r#"<wp:positionV relativeFrom="page"><wp:posOffset>190500</wp:posOffset></wp:positionV>"#,
        r#"<wp:wrapNone/>"#,
    );
    let offset_column = anchor_image_xml(
        "",
        r#"<wp:positionH relativeFrom="column"><wp:posOffset>254000</wp:posOffset></wp:positionH>"#,
        r#"<wp:positionV relativeFrom="paragraph"><wp:posOffset>63500</wp:posOffset></wp:positionV>"#,
        r#"<wp:wrapNone/>"#,
    );

    let body = format!(
        "<w:p>{align_left}</w:p><w:p>{align_center}</w:p><w:p>{align_right}</w:p><w:p>{offset_page}</w:p><w:p>{offset_column}</w:p>"
    );
    let doc = parse_docx(&body)?;
    assert_eq!(doc.blocks.len(), 5);

    assert_eq!(doc.blocks[0].horizontal_align, 1);
    checks::near(doc.blocks[0].x, 72.0);
    checks::near(doc.blocks[0].y, 10.0);

    assert_eq!(doc.blocks[1].horizontal_align, 2);
    checks::near(doc.blocks[1].x, 72.0 + (451.0 - 72.0) * 0.5);
    checks::near(doc.blocks[1].y, 72.0 + 10.0);

    assert_eq!(doc.blocks[2].horizontal_align, 3);
    checks::near(doc.blocks[2].x, 595.0 - 72.0 - 72.0);

    assert_eq!(doc.blocks[3].horizontal_align, 0);
    checks::near(doc.blocks[3].x, 20.0);
    checks::near(doc.blocks[3].y, 15.0);

    assert_eq!(doc.blocks[4].horizontal_align, 0);
    checks::near(doc.blocks[4].x, 72.0 + 20.0);
    checks::near(doc.blocks[4].y, 5.0);
    Ok(())
}

#[test]
fn anchor_inside_paragraph_preserves_unbroken_paragraph_flow() -> TestResult {
    let square = anchor_image_xml(
        r#"distR="114300""#,
        r#"<wp:positionH relativeFrom="column"><wp:align>left</wp:align></wp:positionH>"#,
        r#"<wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>"#,
        r#"<wp:wrapSquare wrapText="bothSides"/>"#,
    );
    let body = format!(
        r#"<w:p><w:r><w:t xml:space="preserve">First part </w:t></w:r>{square}<w:r><w:t>second part</w:t></w:r></w:p>"#
    );
    let doc = parse_docx(&body)?;
    assert_eq!(doc.blocks.len(), 2);
    assert!(matches!(doc.blocks[0].kind, ElementType::IMAGE));
    assert_eq!(doc.blocks[0].wrap_mode, WrapMode::Square);
    assert!(matches!(doc.blocks[1].kind, ElementType::TEXT));
    assert_eq!(doc.blocks[1].paragraphs.len(), 1);
    assert_eq!(
        checks::text(&doc.blocks[1].paragraphs),
        "First part second part"
    );
    Ok(())
}
