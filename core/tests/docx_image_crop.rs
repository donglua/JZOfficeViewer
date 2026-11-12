pub mod support;

use jz_office_core::{model::Document, parse_reader};
use std::io::Cursor;
use support::package::{archive, content_types, relationships, xml, Parts, TestResult, PNG};

fn parts(src_rect: Option<&str>) -> Parts {
    let crop = src_rect.map_or_else(String::new, |rect| format!("<a:srcRect {rect}/>"));
    let body = format!(
        r#"<w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">
  <wp:extent cx="914400" cy="457200"/>
  <wp:docPr id="1" name="Cropped PNG"/>
  <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
    <pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="pixel.png"/><pic:cNvPicPr/></pic:nvPicPr>
      <pic:blipFill><a:blip r:embed="rImage"/>{crop}<a:stretch><a:fillRect/></a:stretch></pic:blipFill>
    </pic:pic>
  </a:graphicData></a:graphic>
</wp:inline></w:drawing></w:r></w:p>"#
    );
    let document = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
 xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
 xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
 xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
 xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
  <w:body>{body}<w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr></w:body>
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

fn parse(src_rect: Option<&str>) -> TestResult<Document> {
    let parts = parts(src_rect);
    let archive = archive(&parts)?;
    Ok(parse_reader(Cursor::new(archive))?)
}

fn image_bounds(document: &Document) -> Option<[f32; 4]> {
    document
        .blocks
        .iter()
        .find(|block| block.image.is_some())
        .and_then(|block| block.image_bounds)
}

#[test]
fn projects_src_rect_crop_into_image_bounds() -> TestResult {
    // Given an inline image cropped by 25% on both horizontal sides.
    let document = parse(Some(r#"l="25000" r="25000""#))?;

    // Then the bounds scale the image so only the cropped region fills the extent.
    let Some(bounds) = image_bounds(&document) else {
        panic!("crop should produce image bounds");
    };
    assert_eq!(bounds, [-36.0, 0.0, 108.0, 36.0]);
    assert!(document
        .warnings
        .iter()
        .all(|warning| !warning.contains("cropping")));
    Ok(())
}

#[test]
fn accepts_percent_form_crop_values() -> TestResult {
    // Given the same crop expressed with percent signs instead of 1/100000 units.
    let document = parse(Some(r#"l="25%" r="25%""#))?;

    // Then it resolves to the same projected bounds.
    assert_eq!(image_bounds(&document), Some([-36.0, 0.0, 108.0, 36.0]));
    Ok(())
}

#[test]
fn falls_back_to_full_image_for_invalid_crop() -> TestResult {
    // Given a crop whose left and right fractions leave no source width.
    let document = parse(Some(r#"l="60000" r="60000""#))?;

    // Then the full image is used and the fallback is reported.
    assert_eq!(image_bounds(&document), None);
    assert!(document
        .warnings
        .iter()
        .any(|warning| warning.contains("invalid crop bounds")));
    Ok(())
}

#[test]
fn leaves_images_without_crop_unbounded() -> TestResult {
    // Given an inline image without any srcRect.
    let document = parse(None)?;

    // Then no crop projection is emitted.
    assert_eq!(image_bounds(&document), None);
    Ok(())
}
