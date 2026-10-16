pub mod support;

use jz_office_core::{model::ElementType, parse_reader, Package};
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
fn optional_header_adds_warning_without_entering_document_flow() -> TestResult {
    let mut baseline = docx::parts();
    replace(
        &mut baseline,
        "word/document.xml",
        &docx::DOCUMENT.replace(docx::HEADER_REFERENCE, ""),
    );
    let baseline = parse_reader(Cursor::new(archive(&baseline)?))?;

    let document = parse_reader(Cursor::new(archive(&docx::parts())?))?;

    assert_eq!(document.warnings.len(), baseline.warnings.len() + 1);
    assert_eq!(
        serde_json::to_value(&document.blocks)?,
        serde_json::to_value(&baseline.blocks)?
    );
    assert!(document
        .blocks
        .iter()
        .all(|block| !checks::text(&block.paragraphs).contains("Optional header")));
    Ok(())
}

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
