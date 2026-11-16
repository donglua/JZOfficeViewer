pub mod support;

use jz_office_core::model::{Document, ElementType, WrapMode};
use jz_office_core::parse_reader;
use std::io::Cursor;
use support::checks;
use support::package::{archive, content_types, relationships, xml, Parts, TestResult, PNG};

fn docx_parts(body: &str) -> Parts {
    docx_parts_with_theme(body, None)
}

fn docx_parts_with_theme(body: &str, theme_xml: Option<&str>) -> Parts {
    let document = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
 xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
 xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
 xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
 xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"
 xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
 xmlns:wpg="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup">
  <w:body>{body}<w:sectPr><w:pgSz w:w="11900" w:h="16840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr></w:body>
</w:document>"#
    );
    let mut rels = vec![("rImage", "image", "media/pixel.png")];
    let mut types = vec![("word/document.xml", "wordprocessingml.document.main")];
    if theme_xml.is_some() {
        rels.push(("rTheme", "theme", "theme/theme1.xml"));
        types.push(("word/theme/theme1.xml", "theme"));
    }
    let mut parts = vec![
        xml("[Content_Types].xml", &content_types(&types)),
        xml(
            "_rels/.rels",
            &relationships(&[("rOffice", "officeDocument", "word/document.xml")]),
        ),
        xml("word/document.xml", &document),
        xml("word/_rels/document.xml.rels", &relationships(&rels)),
        ("word/media/pixel.png", PNG.to_vec()),
    ];
    if let Some(theme) = theme_xml {
        parts.push(xml("word/theme/theme1.xml", theme));
    }
    parts
}

fn parse_docx_with_theme(body: &str, theme_xml: &str) -> TestResult<Document> {
    let bytes = archive(&docx_parts_with_theme(body, Some(theme_xml)))?;
    Ok(parse_reader(Cursor::new(bytes))?)
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

#[test]
fn parses_wps_shape_with_theme_gradient_and_group_coordinates() -> TestResult {
    let theme = r#"<?xml version="1.0" encoding="UTF-8"?>
<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office">
  <a:themeElements>
    <a:clrScheme name="Custom">
      <a:dk1><a:srgbClr val="112233"/></a:dk1>
      <a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>
      <a:dk2><a:srgbClr val="445566"/></a:dk2>
      <a:lt2><a:srgbClr val="EEEEEE"/></a:lt2>
      <a:accent1><a:srgbClr val="336699"/></a:accent1>
      <a:accent2><a:srgbClr val="CC4422"/></a:accent2>
    </a:clrScheme>
    <a:fmtScheme name="Office">
      <a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>
      <a:lnStyleLst><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>
    </a:fmtScheme>
  </a:themeElements>
</a:theme>"#;

    let grad_shape = r#"<w:p><w:r><w:drawing><wp:anchor behindDoc="1">
  <wp:positionH relativeFrom="column"><wp:align>left</wp:align></wp:positionH>
  <wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>
  <wp:extent cx="1270000" cy="635000"/>
  <wp:wrapNone/>
  <a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">
    <wps:wsp>
      <wps:spPr>
        <a:xfrm><a:off x="0" y="0"/><a:ext cx="1270000" cy="635000"/></a:xfrm>
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
        <a:gradFill>
          <a:gsLst>
            <a:gs pos="0"><a:schemeClr val="accent1"/></a:gs>
            <a:gs pos="100000"><a:schemeClr val="accent2"/></a:gs>
          </a:gsLst>
          <a:lin ang="0" scaled="1"/>
        </a:gradFill>
        <a:ln w="12700"><a:solidFill><a:schemeClr val="accent1"/></a:solidFill></a:ln>
      </wps:spPr>
    </wps:wsp>
  </a:graphicData></a:graphic>
</wp:anchor></w:drawing></w:r></w:p>"#;

    let group_shapes = r#"<w:p><w:r><w:drawing><wp:anchor distL="127000" distR="127000">
  <wp:positionH relativeFrom="column"><wp:align>left</wp:align></wp:positionH>
  <wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>
  <wp:extent cx="2540000" cy="1270000"/>
  <wp:wrapSquare wrapText="bothSides"/>
  <a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup">
    <wpg:wgp>
      <wpg:grpSpPr>
        <a:xfrm>
          <a:off x="0" y="0"/><a:ext cx="2540000" cy="1270000"/>
          <a:chOff x="0" y="0"/><a:chExt cx="2540000" cy="1270000"/>
        </a:xfrm>
      </wpg:grpSpPr>
      <wps:wsp>
        <wps:spPr>
          <a:xfrm><a:off x="0" y="0"/><a:ext cx="1270000" cy="1270000"/></a:xfrm>
          <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
          <a:solidFill><a:schemeClr val="accent1"/></a:solidFill>
        </wps:spPr>
      </wps:wsp>
      <wps:wsp>
        <wps:spPr>
          <a:xfrm><a:off x="1270000" y="254000"/><a:ext cx="1270000" cy="635000"/></a:xfrm>
          <a:prstGeom prst="ellipse"><a:avLst/></a:prstGeom>
          <a:solidFill><a:schemeClr val="accent2"/></a:solidFill>
        </wps:spPr>
        <wps:txbx><w:txbxContent>
          <w:p><w:r><w:t>Group Pill</w:t></w:r></w:p>
        </w:txbxContent></wps:txbx>
      </wps:wsp>
    </wpg:wgp>
  </a:graphicData></a:graphic>
</wp:anchor></w:drawing></w:r></w:p>"#;

    let body = format!("{grad_shape}{group_shapes}");
    let doc = parse_docx_with_theme(&body, theme)?;
    assert_eq!(doc.blocks.len(), 3);

    // Shape 0: theme gradient + behindDoc + wrapNone
    let grad = &doc.blocks[0];
    assert!(matches!(grad.kind, ElementType::RECT));
    assert_eq!(grad.wrap_mode, WrapMode::None);
    assert!(grad.behind_doc);
    checks::near(grad.width, 100.0);
    checks::near(grad.height, 50.0);
    assert_eq!(grad.stroke, 0xFF33_6699);
    let fill_grad = grad.fill_gradient.as_ref().ok_or("missing gradient fill")?;
    assert_eq!(fill_grad.colors, vec![0xFF33_6699, 0xFFCC_4422]);
    assert!(fill_grad.points[2] > fill_grad.points[0]);

    // Shape 1 & 2: group children mapped into (margin_left = 72pt) anchor coordinates
    let child_rect = &doc.blocks[1];
    assert!(matches!(child_rect.kind, ElementType::RECT));
    assert_eq!(child_rect.wrap_mode, WrapMode::Square);
    assert_eq!(child_rect.fill, 0xFF33_6699);
    checks::near(child_rect.x, 72.0);
    checks::near(child_rect.y, 0.0);
    checks::near(child_rect.width, 100.0);
    checks::near(child_rect.height, 100.0);

    let child_ellipse = &doc.blocks[2];
    assert!(matches!(child_ellipse.kind, ElementType::ELLIPSE));
    assert_eq!(child_ellipse.wrap_mode, WrapMode::Square);
    assert_eq!(child_ellipse.fill, 0xFFCC_4422);
    checks::near(child_ellipse.x, 72.0 + 100.0);
    checks::near(child_ellipse.y, 20.0);
    checks::near(child_ellipse.width, 100.0);
    checks::near(child_ellipse.height, 50.0);
    assert_eq!(checks::text(&child_ellipse.paragraphs), "Group Pill");

    Ok(())
}

#[test]
fn inline_drawings_inherit_paragraph_jc_alignment() -> TestResult {
    let inline_img = r#"<w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">
  <wp:extent cx="914400" cy="457200"/>
  <wp:docPr id="1" name="Inline PNG"/>
  <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
    <pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="pixel.png"/><pic:cNvPicPr/></pic:nvPicPr>
      <pic:blipFill><a:blip r:embed="rImage"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>
    </pic:pic>
  </a:graphicData></a:graphic>
</wp:inline></w:drawing></w:r>"#;

    let body = format!(
        r#"<w:p>{inline_img}</w:p>
<w:p><w:pPr><w:jc w:val="center"/></w:pPr>{inline_img}</w:p>
<w:p><w:pPr><w:jc w:val="right"/></w:pPr>{inline_img}</w:p>
<w:p><w:pPr><w:jc w:val="both"/></w:pPr>{inline_img}</w:p>"#
    );
    let doc = parse_docx(&body)?;
    assert_eq!(doc.blocks.len(), 4);
    for (idx, expected) in [(0, 1u8), (1, 2u8), (2, 3u8), (3, 1u8)] {
        assert_eq!(doc.blocks[idx].wrap_mode, WrapMode::Inline);
        assert_eq!(doc.blocks[idx].horizontal_align, expected);
    }
    Ok(())
}

#[test]
fn transparent_autofit_nowrap_wsp_textbox_autofits_and_centers_paragraph() -> TestResult {
    let body = r#"<w:p><w:r><w:drawing><wp:anchor behindDoc="0">
  <wp:positionH relativeFrom="margin"><wp:align>center</wp:align></wp:positionH>
  <wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>
  <wp:extent cx="1828800" cy="1828800"/>
  <wp:wrapNone/>
  <a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">
    <wps:wsp>
      <wps:cNvSpPr txBox="1"/>
      <wps:spPr>
        <a:xfrm><a:off x="0" y="0"/><a:ext cx="1828800" cy="1828800"/></a:xfrm>
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
        <a:noFill/>
        <a:ln w="6350"><a:noFill/></a:ln>
      </wps:spPr>
      <wps:txbx><w:txbxContent>
        <w:p><w:r><w:t>1</w:t></w:r></w:p>
      </w:txbxContent></wps:txbx>
      <wps:bodyPr wrap="none" lIns="0" tIns="0" rIns="0" bIns="0" anchor="t"><a:spAutoFit/></wps:bodyPr>
    </wps:wsp>
  </a:graphicData></a:graphic>
</wp:anchor></w:drawing></w:r></w:p>"#;
    let doc = parse_docx(body)?;
    assert_eq!(doc.blocks.len(), 1);
    let box_el = &doc.blocks[0];
    assert!(matches!(box_el.kind, ElementType::TEXT));
    assert_eq!(box_el.wrap_mode, WrapMode::None);
    assert_eq!(box_el.horizontal_align, 2);
    assert!(!box_el.text_wrap);
    checks::near(box_el.width, 0.0);
    checks::near(box_el.height, 0.0);
    assert_eq!(box_el.paragraphs.len(), 1);
    assert_eq!(box_el.paragraphs[0].alignment, 1);
    assert_eq!(checks::text(&box_el.paragraphs), "1");
    Ok(())
}
