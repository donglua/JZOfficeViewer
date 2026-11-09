pub mod support;

use jz_office_core::{
    model::{Element, LineSpacingRule, Paragraph},
    parse_reader,
};
use std::io::Cursor;
use support::{
    checks,
    package::{archive, content_types, relationships, xml, Parts, TestResult},
};

fn layout_parts(document_body: &str, styles_body: &str) -> Parts {
    vec![
        xml(
            "[Content_Types].xml",
            &content_types(&[
                ("word/document.xml", "wordprocessingml.document.main"),
                ("word/styles.xml", "wordprocessingml.styles"),
            ]),
        ),
        xml(
            "_rels/.rels",
            &relationships(&[("rOffice", "officeDocument", "word/document.xml")]),
        ),
        xml("word/document.xml", &document_xml(document_body)),
        xml("word/styles.xml", &styles_xml(styles_body)),
        xml(
            "word/_rels/document.xml.rels",
            &relationships(&[("rStyles", "styles", "styles.xml")]),
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

fn styles_xml(body: &str) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  {body}
</w:styles>"#
    )
}

fn text_paragraph(text: &str, properties: &str) -> String {
    format!(r#"<w:p><w:pPr>{properties}</w:pPr><w:r><w:t>{text}</w:t></w:r></w:p>"#)
}

fn paragraph_at(blocks: &[Element], index: usize) -> &Paragraph {
    &blocks[index].paragraphs[0]
}

#[test]
fn parses_direct_docx_line_spacing_rules_when_present() -> TestResult {
    let body = [
        text_paragraph("auto", r#"<w:spacing w:line="360" w:lineRule="auto"/>"#),
        text_paragraph("exact", r#"<w:spacing w:line="300" w:lineRule="exact"/>"#),
        text_paragraph(
            "atLeast",
            r#"<w:spacing w:line="480" w:lineRule="atLeast"/>"#,
        ),
    ]
    .join("");
    let parts = layout_parts(&body, "");

    let document = parse_reader(Cursor::new(archive(&parts)?))?;

    let auto = paragraph_at(&document.blocks, 0);
    assert_eq!(auto.line_spacing_rule, LineSpacingRule::Auto);
    checks::near(auto.line_spacing, 1.5);
    let exact = paragraph_at(&document.blocks, 1);
    assert_eq!(exact.line_spacing_rule, LineSpacingRule::Exact);
    checks::near(exact.line_spacing, 15.0);
    let at_least = paragraph_at(&document.blocks, 2);
    assert_eq!(at_least.line_spacing_rule, LineSpacingRule::AtLeast);
    checks::near(at_least.line_spacing, 24.0);
    Ok(())
}

#[test]
fn inherits_docx_line_units_and_rule_independently() -> TestResult {
    let styles = r#"
<w:docDefaults><w:pPrDefault><w:pPr><w:spacing w:line="360"/></w:pPr></w:pPrDefault></w:docDefaults>
<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
<w:style w:type="paragraph" w:styleId="Base"><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:lineRule="exact"/></w:pPr></w:style>
<w:style w:type="paragraph" w:styleId="Child"><w:basedOn w:val="Base"/><w:pPr><w:spacing w:line="480"/></w:pPr></w:style>
"#;
    let body = [
        text_paragraph("base", r#"<w:pStyle w:val="Base"/>"#),
        text_paragraph("child", r#"<w:pStyle w:val="Child"/>"#),
        text_paragraph(
            "direct reset",
            r#"<w:pStyle w:val="Child"/><w:spacing w:lineRule="auto"/>"#,
        ),
    ]
    .join("");
    let parts = layout_parts(&body, styles);

    let document = parse_reader(Cursor::new(archive(&parts)?))?;

    let base = paragraph_at(&document.blocks, 0);
    assert_eq!(base.line_spacing_rule, LineSpacingRule::Exact);
    checks::near(base.line_spacing, 18.0);
    let child = paragraph_at(&document.blocks, 1);
    assert_eq!(child.line_spacing_rule, LineSpacingRule::Exact);
    checks::near(child.line_spacing, 24.0);
    let direct = paragraph_at(&document.blocks, 2);
    assert_eq!(direct.line_spacing_rule, LineSpacingRule::Auto);
    checks::near(direct.line_spacing, 2.0);
    Ok(())
}

#[test]
fn applies_point_indents_with_ltr_precedence_and_hanging_rules() -> TestResult {
    let styles = r#"
<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
<w:style w:type="paragraph" w:styleId="Indented"><w:basedOn w:val="Normal"/><w:pPr><w:ind w:left="240" w:right="120" w:hanging="80"/></w:pPr></w:style>
"#;
    let body = [
        text_paragraph(
            "direct first",
            r#"<w:pStyle w:val="Indented"/><w:ind w:left="240" w:start="480" w:right="120" w:end="360" w:firstLine="200"/>"#,
        ),
        text_paragraph(
            "same node hanging",
            r#"<w:ind w:firstLine="400" w:hanging="100"/>"#,
        ),
    ]
    .join("");
    let parts = layout_parts(&body, styles);

    let document = parse_reader(Cursor::new(archive(&parts)?))?;

    let direct = paragraph_at(&document.blocks, 0);
    checks::near(direct.indent, 24.0);
    checks::near(direct.right_indent, 18.0);
    checks::near(direct.first_line_indent, 10.0);
    let hanging = paragraph_at(&document.blocks, 1);
    checks::near(hanging.first_line_indent, -5.0);
    Ok(())
}

#[test]
fn clamps_invalid_docx_spacing_and_indents_without_nan() -> TestResult {
    let body = [
        text_paragraph(
            "low",
            r#"<w:spacing w:before="-40" w:after="NaN" w:line="-120" w:lineRule="auto"/><w:ind w:left="-20" w:right="NaN" w:firstLine="-80"/>"#,
        ),
        text_paragraph(
            "high",
            r#"<w:spacing w:line="999999" w:lineRule="exact"/><w:ind w:start="999999" w:end="999999" w:hanging="999999"/>"#,
        ),
    ]
    .join("");
    let parts = layout_parts(&body, "");

    let document = parse_reader(Cursor::new(archive(&parts)?))?;

    let low = paragraph_at(&document.blocks, 0);
    checks::near(low.before, 0.0);
    checks::near(low.after, 6.0);
    checks::near(low.line_spacing, 0.1);
    checks::near(low.indent, 0.0);
    checks::near(low.right_indent, 0.0);
    checks::near(low.first_line_indent, 0.0);
    assert!(layout_values(low).into_iter().all(f32::is_finite));
    let high = paragraph_at(&document.blocks, 1);
    checks::near(high.line_spacing, 400.0);
    checks::near(high.indent, 1200.0);
    checks::near(high.right_indent, 1200.0);
    checks::near(high.first_line_indent, -1200.0);
    assert!(layout_values(high).into_iter().all(f32::is_finite));
    Ok(())
}

#[test]
fn warns_for_unsupported_line_count_spacing() -> TestResult {
    let body = text_paragraph(
        "unsupported units",
        r#"<w:spacing w:beforeLines="100" w:afterLines="200"/>"#,
    );
    let parts = layout_parts(&body, "");

    let document = parse_reader(Cursor::new(archive(&parts)?))?;

    assert!(document.warnings.iter().any(
        |warning| warning == "Line-count paragraph spacing uses the viewer's default spacing."
    ));
    Ok(())
}

#[test]
fn character_unit_paragraph_indents_are_supported() -> TestResult {
    let body = text_paragraph(
        "character indents",
        r#"<w:ind w:firstLineChars="200" w:startChars="150" w:endChars="100"/>"#,
    );
    let parts = layout_parts(&body, "");
    let document = parse_reader(Cursor::new(archive(&parts)?))?;
    let paragraph = &document.blocks[0].paragraphs[0];
    checks::near(paragraph.first_line_indent, 24.0);
    checks::near(paragraph.indent, 18.0);
    checks::near(paragraph.right_indent, 12.0);
    assert!(!document
        .warnings
        .iter()
        .any(|warning| warning.contains("Character-unit")));

    let hanging_body = text_paragraph(
        "hanging character indents",
        r#"<w:ind w:hangingChars="100" w:leftChars="200" w:rightChars="50"/>"#,
    );
    let hanging_parts = layout_parts(&hanging_body, "");
    let hanging_doc = parse_reader(Cursor::new(archive(&hanging_parts)?))?;
    let hanging_paragraph = &hanging_doc.blocks[0].paragraphs[0];
    checks::near(hanging_paragraph.first_line_indent, -12.0);
    checks::near(hanging_paragraph.indent, 24.0);
    checks::near(hanging_paragraph.right_indent, 6.0);
    Ok(())
}

fn layout_values(paragraph: &Paragraph) -> [f32; 6] {
    [
        paragraph.before,
        paragraph.after,
        paragraph.indent,
        paragraph.right_indent,
        paragraph.first_line_indent,
        paragraph.line_spacing,
    ]
}
