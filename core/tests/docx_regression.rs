pub mod support;

use jz_office_core::{model::ElementType, parse_reader, Error, Package};
use std::io::Cursor;
use support::{
    checks, docx,
    package::{archive, replace, TestResult, PNG},
};

#[test]
fn direct_bold_off_overrides_inherited_style_when_parsing_docx() -> TestResult {
    let bytes = archive(&docx::parts())?;

    let document = parse_reader(Cursor::new(bytes))?;

    let title = &document.blocks[0].paragraphs[0];
    assert_eq!(title.alignment, 1);
    checks::near(title.before, 12.0);
    checks::near(title.after, 8.0);
    assert_eq!(title.runs.len(), 2);
    let inherited = &title.runs[0];
    assert_eq!(inherited.text, "\u{4e2d}\u{6587} Office");
    assert!(inherited.bold);
    assert!(!inherited.italic);
    assert!(!inherited.underline);
    checks::near(inherited.size, 18.0);
    assert_eq!(inherited.color, 0xff336699);
    let direct = &title.runs[1];
    assert_eq!(direct.text, " English regular");
    assert!(!direct.bold);
    assert!(direct.italic);
    assert!(direct.underline);
    checks::near(direct.size, 14.0);
    assert_eq!(direct.color, 0xffc03020);
    Ok(())
}

#[test]
fn explicit_false_spellings_override_bold_when_inherited() -> TestResult {
    for value in ["0", "false", "off"] {
        let mut parts = docx::parts();
        replace(
            &mut parts,
            "word/document.xml",
            &docx::DOCUMENT.replace(r#"<w:b w:val="0"/>"#, &format!(r#"<w:b w:val="{value}"/>"#)),
        );

        let document = parse_reader(Cursor::new(archive(&parts)?))?;

        assert!(document.blocks[0].paragraphs[0].runs[0].bold);
        assert!(!document.blocks[0].paragraphs[0].runs[1].bold, "{value}");
    }
    Ok(())
}

#[test]
fn docx_reads_line_spacing_and_first_hanging_and_right_indents() -> TestResult {
    let mut parts = docx::parts();
    let document = String::from_utf8(
        parts
            .iter()
            .find(|(name, _)| *name == "word/document.xml")
            .ok_or("missing document")?
            .1
            .clone(),
    )?
    .replace(
        "<w:p><w:r><w:t>Plain paragraph",
        "<w:p><w:pPr><w:spacing w:line=\"480\" w:lineRule=\"auto\"/><w:ind w:left=\"240\" w:right=\"120\" w:hanging=\"120\"/></w:pPr><w:r><w:t>Plain paragraph",
    );
    support::package::replace(&mut parts, "word/document.xml", &document);

    let parsed = parse_reader(Cursor::new(archive(&parts)?))?;
    let paragraph = &parsed.blocks[1].paragraphs[0];
    checks::near(paragraph.line_spacing, 2.0);
    assert_eq!(
        paragraph.line_spacing_rule,
        jz_office_core::model::LineSpacingRule::Auto
    );
    checks::near(paragraph.indent, 12.0);
    checks::near(paragraph.right_indent, 6.0);
    checks::near(paragraph.first_line_indent, -6.0);
    Ok(())
}

#[test]
fn tabs_line_breaks_and_plain_defaults_survive_docx_flow() -> TestResult {
    let bytes = archive(&docx::parts())?;

    let document = parse_reader(Cursor::new(bytes))?;

    checks::near(document.width, 612.0);
    let plain = &document.blocks[1].paragraphs;
    assert_eq!(
        checks::text(plain),
        "Plain paragraph with italic\ttab\nnext line"
    );
    checks::near(plain[0].runs[0].size, 11.0);
    assert!(!plain[0].runs[0].bold);
    assert!(plain[0].runs[1].italic);
    Ok(())
}

#[test]
fn rectangular_docx_table_preserves_cell_order_and_column_points() -> TestResult {
    let bytes = archive(&docx::parts())?;

    let document = parse_reader(Cursor::new(bytes))?;

    let table = checks::element(&document.blocks, ElementType::TABLE)?;
    assert_eq!(table.rows.len(), 2);
    assert!(table.rows.iter().all(|row| row.len() == 2));
    assert_eq!(table.column_widths.len(), 2);
    checks::near(table.column_widths[0], 144.0);
    checks::near(table.column_widths[1], 216.0);
    checks::near(table.width, 360.0);
    assert_eq!(checks::text(&table.rows[0][0]), "Language");
    assert_eq!(checks::text(&table.rows[0][1]), "Greeting");
    assert_eq!(checks::text(&table.rows[1][0]), "\u{4e2d}\u{6587}");
    assert_eq!(checks::text(&table.rows[1][1]), "Hello \u{4f60}\u{597d}");
    Ok(())
}

#[test]
fn docx_image_uses_normalized_relative_package_path() -> TestResult {
    let bytes = archive(&docx::parts())?;

    let document = parse_reader(Cursor::new(bytes.clone()))?;

    let image = checks::element(&document.blocks, ElementType::IMAGE)?;
    assert_eq!(image.image.as_deref(), Some("word/media/pixel.png"));
    checks::near(image.width, 72.0);
    checks::near(image.height, 36.0);
    let mut package = Package::new(Cursor::new(bytes))?;
    assert_eq!(package.read("word/media/pixel.png", 1024)?, PNG);
    Ok(())
}

#[test]
fn header_is_parsed_into_header_blocks_not_document_flow() -> TestResult {
    let mut baseline = docx::parts();
    replace(
        &mut baseline,
        "word/document.xml",
        &docx::DOCUMENT.replace(docx::HEADER_REFERENCE, ""),
    );
    let baseline = parse_reader(Cursor::new(archive(&baseline)?))?;

    let document = parse_reader(Cursor::new(archive(&docx::parts())?))?;

    // 页眉不再产生 warning
    assert_eq!(document.warnings.len(), baseline.warnings.len());
    // 页眉内容进入 header_blocks，不进入正文 blocks
    assert!(!document.header_blocks.is_empty());
    assert!(document
        .blocks
        .iter()
        .all(|block| !checks::text(&block.paragraphs).contains("示例文档")));
    assert!(checks::text(&document.header_blocks[0].paragraphs).contains("示例文档"));
    // 页脚也已解析
    assert!(!document.footer_blocks.is_empty());
    assert!(checks::text(&document.footer_blocks[0].paragraphs).contains("页脚"));
    // 页边距已解析
    assert!(document.margin_top > 0.0);
    assert!(document.header_distance > 0.0);
    Ok(())
}

#[test]
fn header_images_use_the_header_relationship_part() -> TestResult {
    let mut parts = docx::parts();
    // 页眉部件内含图片引用 rLogo；正文关系表故意把同一个 rId 指向另一张图片
    parts.push(("word/media/header.png", PNG.to_vec()));
    parts.push((
        "word/_rels/header1.xml.rels",
        support::package::relationships(&[("rLogo", "image", "media/header.png")]).into_bytes(),
    ));
    replace(&mut parts, "word/header1.xml", HEADER_WITH_IMAGE);
    let document_rels = support::package::relationships(&[
        ("rStyles", "styles", "styles.xml"),
        ("rImage", "image", "media/pixel.png"),
        ("rHeader", "header", "header1.xml"),
        ("rFooter", "footer", "footer1.xml"),
        ("rLogo", "image", "media/pixel.png"),
    ]);
    replace(&mut parts, "word/_rels/document.xml.rels", &document_rels);

    let document = parse_reader(Cursor::new(archive(&parts)?))?;

    let image = checks::element(&document.header_blocks, ElementType::IMAGE)?;
    assert_eq!(image.image.as_deref(), Some("word/media/header.png"));
    Ok(())
}

const HEADER_WITH_IMAGE: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
 xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
 xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
 xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
 xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
<w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">
  <wp:extent cx="914400" cy="457200"/>
  <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
    <pic:pic><pic:blipFill><a:blip r:embed="rLogo"/></pic:blipFill></pic:pic>
  </a:graphicData></a:graphic>
</wp:inline></w:drawing></w:r></w:p>
</w:hdr>"#;

#[test]
fn header_blocks_stop_at_the_platform_section_limit() -> TestResult {
    let mut paragraphs = String::new();
    for index in 0..=500 {
        paragraphs.push_str(&format!("<w:p><w:r><w:t>Line {index}</w:t></w:r></w:p>"));
    }
    let header = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">{paragraphs}</w:hdr>"#
    );
    let mut parts = docx::parts();
    replace(&mut parts, "word/header1.xml", &header);

    let error = parse_reader(Cursor::new(archive(&parts)?));

    assert!(matches!(
        error,
        Err(Error::Limit("DOCX header/footer exceeds 500 blocks"))
    ));
    Ok(())
}

#[test]
fn later_sections_inherit_header_and_footer_from_earlier_sections() -> TestResult {
    let mut parts = docx::parts();
    replace(&mut parts, "word/document.xml", MULTI_SECTION_DOCUMENT);

    let document = parse_reader(Cursor::new(archive(&parts)?))?;

    // 最后一节未重复声明引用，按继承规则沿用第一节的页眉页脚
    assert!(checks::text(&document.header_blocks[0].paragraphs).contains("示例文档"));
    assert!(checks::text(&document.footer_blocks[0].paragraphs).contains("页脚"));
    Ok(())
}

#[test]
fn unsupported_header_content_records_warnings() -> TestResult {
    let mut parts = docx::parts();
    let header = r#"<?xml version="1.0" encoding="UTF-8"?>
<w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
 xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math">
<w:p><m:oMath><m:r><m:t>x=1</m:t></m:r></m:oMath></w:p>
</w:hdr>"#;
    replace(&mut parts, "word/header1.xml", header);

    let document = parse_reader(Cursor::new(archive(&parts)?))?;

    assert!(document
        .warnings
        .iter()
        .any(|warning| warning == "Mathematical equations are omitted."));
    Ok(())
}

const MULTI_SECTION_DOCUMENT: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
 xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<w:body>
  <w:p><w:pPr><w:sectPr>
    <w:headerReference w:type="default" r:id="rHeader"/>
    <w:footerReference w:type="default" r:id="rFooter"/>
    <w:pgSz w:w="12240" w:h="15840"/>
  </w:sectPr></w:pPr><w:r><w:t>First section</w:t></w:r></w:p>
  <w:p><w:r><w:t>Second section body</w:t></w:r></w:p>
  <w:sectPr><w:pgSz w:w="12240" w:h="15840"/>
    <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720"/>
  </w:sectPr>
</w:body></w:document>"#;

#[test]
fn hidden_runs_and_ruby_rt_are_omitted_from_document_flow() -> TestResult {
    let mut parts = docx::parts();
    let body_with_hidden = r#"<w:p>
        <w:r><w:t>Visible start</w:t></w:r>
        <w:r><w:rPr><w:vanish/></w:rPr><w:t> Hidden vanish text</w:t></w:r>
        <w:r><w:rPr><w:webHidden w:val="true"/></w:rPr><w:t> Hidden web text</w:t></w:r>
        <w:ruby>
            <w:rubyPr/>
            <w:rt><w:r><w:t>pinyin</w:t></w:r></w:rt>
            <w:rp><w:r><w:t>(</w:t></w:r></w:rp>
            <w:rubyBase><w:r><w:t> 汉字</w:t></w:r></w:rubyBase>
            <w:rp><w:r><w:t>)</w:t></w:r></w:rp>
        </w:ruby>
    </w:p>"#;
    replace(
        &mut parts,
        "word/document.xml",
        &docx::DOCUMENT.replace(
            r#"<w:p><w:pPr><w:pStyle w:val="FixtureTitle"/></w:pPr>"#,
            &format!("{body_with_hidden}<w:p><w:pPr><w:pStyle w:val=\"FixtureTitle\"/></w:pPr>"),
        ),
    );
    let document = parse_reader(Cursor::new(archive(&parts)?))?;
    let all_text = checks::text(&document.blocks[0].paragraphs);
    assert!(all_text.contains("Visible start"));
    assert!(all_text.contains("汉字"));
    assert!(!all_text.contains("Hidden vanish text"));
    assert!(!all_text.contains("Hidden web text"));
    assert!(!all_text.contains("pinyin"));
    assert!(!all_text.contains('('));
    assert!(!all_text.contains(')'));
    Ok(())
}
