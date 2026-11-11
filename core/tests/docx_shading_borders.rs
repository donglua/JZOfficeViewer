pub mod support;

use jz_office_core::{
    model::{Document, ElementType, Paragraph},
    parse_reader,
};
use std::io::Cursor;
use support::{checks, docx, package, package::TestResult, pptx};

fn parse_docx(body: &str) -> TestResult<Document> {
    let mut parts = docx::parts();
    package::replace(
        &mut parts,
        "word/document.xml",
        &format!(
            r#"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>{body}</w:body></w:document>"#
        ),
    );
    Ok(parse_reader(Cursor::new(package::archive(&parts)?))?)
}

fn parse_pptx_body(body: &str) -> TestResult<Document> {
    let mut parts = pptx::parts();
    package::replace(
        &mut parts,
        "ppt/slides/slide2.xml",
        &format!(
            r#"<p:sld
xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
<p:cSld><p:spTree><p:sp><p:nvSpPr><p:cNvPr id="2" name="Text"/><p:cNvSpPr/>
<p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr>
<p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="4572000" cy="2743200"/></a:xfrm></p:spPr>
<p:txBody>{body}</p:txBody></p:sp></p:spTree></p:cSld></p:sld>"#
        ),
    );
    Ok(parse_reader(Cursor::new(package::archive(&parts)?))?)
}

fn pptx_paragraphs(document: &Document) -> TestResult<&[Paragraph]> {
    Ok(&checks::element(&document.pages[0].elements, ElementType::TEXT)?.paragraphs)
}

#[test]
fn docx_highlight_maps_standard_colors_and_hex() -> TestResult {
    let cases = [
        ("yellow", 0xFFFFFF00),
        ("green", 0xFF00FF00),
        ("cyan", 0xFF00FFFF),
        ("magenta", 0xFFFF00FF),
        ("blue", 0xFF0000FF),
        ("red", 0xFFFF0000),
        ("darkBlue", 0xFF000080),
        ("darkblue", 0xFF000080),
        ("darkCyan", 0xFF008080),
        ("darkcyan", 0xFF008080),
        ("darkGreen", 0xFF008000),
        ("darkgreen", 0xFF008000),
        ("darkMagenta", 0xFF800080),
        ("darkmagenta", 0xFF800080),
        ("darkRed", 0xFF800000),
        ("darkred", 0xFF800000),
        ("darkYellow", 0xFF808000),
        ("darkyellow", 0xFF808000),
        ("darkGray", 0xFF808080),
        ("darkgray", 0xFF808080),
        ("lightGray", 0xFFC0C0C0),
        ("lightgray", 0xFFC0C0C0),
        ("black", 0xFF000000),
        ("white", 0xFFFFFFFF),
        ("none", 0x00000000),
        ("123456", 0xFF123456),
    ];

    for (color_name, expected_color) in cases {
        let body = format!(
            r#"<w:p><w:r><w:rPr><w:highlight w:val="{color_name}"/></w:rPr><w:t>Text</w:t></w:r></w:p>"#
        );
        let doc = parse_docx(&body)?;
        let run = &doc.blocks[0].paragraphs[0].runs[0];
        assert_eq!(
            run.background, expected_color,
            "failed mapping for highlight color {color_name}"
        );
        assert!(
            !doc.warnings
                .iter()
                .any(|w| w.contains("advanced run formatting")),
            "highlight should not produce warning for {color_name}"
        );
    }
    Ok(())
}

#[test]
fn docx_run_shading_sets_background() -> TestResult {
    let body = r#"<w:p><w:r><w:rPr><w:shd w:val="clear" w:fill="00FF00"/></w:rPr><w:t>Shaded</w:t></w:r></w:p>"#;
    let doc = parse_docx(body)?;
    let run = &doc.blocks[0].paragraphs[0].runs[0];
    assert_eq!(run.background, 0xFF00FF00);

    // auto or none fill should be ignored and keep existing background
    let body_auto = r#"<w:p><w:r><w:rPr><w:highlight w:val="yellow"/><w:shd w:fill="auto"/></w:rPr><w:t>Auto</w:t></w:r></w:p>"#;
    let doc_auto = parse_docx(body_auto)?;
    assert_eq!(
        doc_auto.blocks[0].paragraphs[0].runs[0].background,
        0xFFFFFF00
    );

    let body_none = r#"<w:p><w:r><w:rPr><w:highlight w:val="yellow"/><w:shd w:fill="none"/></w:rPr><w:t>None</w:t></w:r></w:p>"#;
    let doc_none = parse_docx(body_none)?;
    assert_eq!(
        doc_none.blocks[0].paragraphs[0].runs[0].background,
        0xFFFFFF00
    );

    Ok(())
}

#[test]
fn docx_paragraph_shading_sets_paragraph_background() -> TestResult {
    let body = r#"<w:p><w:pPr><w:shd w:fill="EEEEEE"/></w:pPr><w:r><w:t>Para</w:t></w:r></w:p>"#;
    let doc = parse_docx(body)?;
    let para = &doc.blocks[0].paragraphs[0];
    assert_eq!(para.background, 0xFFEEEEEE);

    // auto / none does not set background
    let body_auto = r#"<w:p><w:pPr><w:shd w:fill="auto"/></w:pPr><w:r><w:t>Para</w:t></w:r></w:p>"#;
    let doc_auto = parse_docx(body_auto)?;
    assert_eq!(doc_auto.blocks[0].paragraphs[0].background, 0);

    Ok(())
}

#[test]
fn docx_paragraph_borders_set_colors_and_max_width() -> TestResult {
    let body = r#"<w:p><w:pPr><w:pBdr>
        <w:top w:val="single" w:sz="8" w:space="1" w:color="0000FF"/>
        <w:bottom w:val="single" w:sz="12" w:color="FF0000"/>
        <w:left w:val="single" w:sz="4" w:color="auto"/>
        <w:right w:val="none" w:sz="16" w:color="00FF00"/>
    </w:pBdr></w:pPr><w:r><w:t>Bordered</w:t></w:r></w:p>"#;
    let doc = parse_docx(body)?;
    let para = &doc.blocks[0].paragraphs[0];
    assert_eq!(para.border_top, 0xFF0000FF);
    assert_eq!(para.border_bottom, 0xFFFF0000);
    assert_eq!(para.border_left, 0xFF000000); // auto color maps to 0xFF000000
    assert_eq!(para.border_right, 0); // val="none" was skipped
    checks::near(para.border_width, 1.5); // max(8/8, 12/8, 4/8) = 12/8 = 1.5 pt

    Ok(())
}

#[test]
fn pptx_highlight_sets_run_background_and_removes_warning() -> TestResult {
    let body = r#"<a:p><a:r><a:rPr><a:highlight><a:srgbClr val="00FF00"/></a:highlight></a:rPr><a:t>Highlighted</a:t></a:r></a:p>"#;
    let doc = parse_pptx_body(body)?;
    let paragraphs = pptx_paragraphs(&doc)?;
    assert_eq!(paragraphs[0].runs[0].background, 0xFF00FF00);
    assert!(
        !doc.warnings
            .iter()
            .any(|w| w.contains("text highlighting is not supported")),
        "warning should be removed for PPTX highlighting"
    );
    Ok(())
}
