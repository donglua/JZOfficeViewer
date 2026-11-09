pub mod support;

use jz_office_core::{model::Document, parse_reader};
use serde_json::json;
use std::io::Cursor;
use support::{docx, package, package::TestResult};

#[test]
fn serializes_explicit_font_when_saved_families_agree() -> TestResult {
    for face in ["monospace", "思源黑体 CN Light", "Unavailable Font"] {
        // Given a single explicit family and existing direct run formatting.
        let body = format!(
            r#"<w:p><w:r><w:rPr>{}<w:b/><w:i/><w:u/><w:sz w:val="36"/>
<w:color w:val="C03020"/></w:rPr><w:t>English 中文</w:t></w:r></w:p>"#,
            families(face)
        );

        // When the package is parsed and serialized using the existing run schema.
        let document = parse(&body, "")?;
        let run = serde_json::to_value(&document.blocks[0].paragraphs[0].runs[0])?;

        // Then the name reaches the viewer while font availability remains explicit.
        assert_eq!(document.schema_version, 9);
        assert_eq!(
            run,
            json!({"text":"English 中文", "fontFace":face, "size":18.0,
            "bold":true, "italic":true, "underline":true, "color":0xffc03020_u32})
        );
        assert_eq!(document.warnings.len(), 1);
        assert!(document.warnings[0].contains("device fonts"));
    }
    Ok(())
}

#[test]
fn serializes_available_family_when_other_script_names_are_unspecified() -> TestResult {
    for attributes in [
        r#"w:ascii="monospace""#,
        r#"w:hAnsi="monospace""#,
        r#"w:eastAsia="monospace""#,
        r#"w:cs="monospace""#,
        r#"w:ascii="monospace" w:hAnsi="monospace""#,
    ] {
        // Given consistent saved names with other script slots left to the viewer.
        let body = format!(
            r#"<w:p><w:r><w:rPr><w:rFonts {attributes}/></w:rPr><w:t>Text</w:t></w:r></w:p>"#
        );

        // When the package is parsed through its public entry point.
        let document = parse(&body, "")?;

        // Then the available family is passed through with the device fallback warning.
        assert_eq!(
            document.blocks[0].paragraphs[0].runs[0].font_face,
            "monospace"
        );
        assert_eq!(document.warnings.len(), 1);
        assert!(document.warnings[0].contains("device fonts"));
    }
    Ok(())
}

#[test]
fn bounds_font_names_before_inheritance_can_expand_them() -> TestResult {
    for face in ["A".repeat(256), "字".repeat(85)] {
        let styles = format!(
            "<w:docDefaults><w:rPrDefault><w:rPr>{}</w:rPr></w:rPrDefault></w:docDefaults>",
            families(&face)
        );
        let document = parse("<w:p><w:r><w:t>Text</w:t></w:r></w:p>", &styles)?;
        assert_eq!(document.blocks[0].paragraphs[0].runs[0].font_face, face);
    }
    for face in ["A".repeat(257), "字".repeat(86), "A".repeat(65_536)] {
        let properties = families(&face);
        let direct = format!("<w:p><w:r><w:rPr>{properties}</w:rPr><w:t>Text</w:t></w:r></w:p>");
        let inherited = format!("<w:p>{}</w:p>", "<w:r><w:t>x</w:t></w:r>".repeat(512));
        let styles = format!(
            "<w:docDefaults><w:rPrDefault><w:rPr>{properties}</w:rPr></w:rPrDefault></w:docDefaults>"
        );
        for (body, styles) in [(&direct, ""), (&inherited, styles.as_str())] {
            let error = parse(body, styles)
                .err()
                .ok_or("Excessive font name was accepted")?;
            assert!(error
                .to_string()
                .contains("font family name exceeds 256 bytes"));
        }
    }
    Ok(())
}

#[test]
fn nearest_font_wins_when_document_paragraph_and_character_styles_are_inherited() -> TestResult {
    // Given fonts at every style layer, including basedOn and a direct override.
    let styles = format!(
        r#"<w:docDefaults><w:rPrDefault><w:rPr>{}</w:rPr></w:rPrDefault></w:docDefaults>
<w:style w:type="paragraph" w:styleId="Base"><w:rPr>{}<w:b/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Child"><w:basedOn w:val="Base"/></w:style>
<w:style w:type="character" w:styleId="Emphasis"><w:rPr>{}<w:i/></w:rPr></w:style>
<w:style w:type="character" w:styleId="Inherited"><w:basedOn w:val="Emphasis"/></w:style>"#,
        families("serif"),
        families("sans-serif"),
        families("monospace")
    );
    let body = format!(
        r#"<w:p><w:r><w:t>Default</w:t></w:r></w:p>
<w:p><w:pPr><w:pStyle w:val="Child"/></w:pPr>
<w:r><w:t>Paragraph</w:t></w:r>
<w:r><w:rPr><w:rStyle w:val="Inherited"/></w:rPr><w:t>Character</w:t></w:r>
<w:r><w:rPr><w:rStyle w:val="Inherited"/>{}</w:rPr><w:t>Direct</w:t></w:r></w:p>"#,
        families("sans-serif-light")
    );

    // When normal DOCX paragraph and inline resolution runs.
    let document = parse(&body, &styles)?;

    // Then each layer replaces the preceding font without losing other properties.
    assert_eq!(document.blocks[0].paragraphs[0].runs[0].font_face, "serif");
    let runs = &document.blocks[1].paragraphs[0].runs;
    assert_eq!(
        runs.iter()
            .map(|run| run.font_face.as_str())
            .collect::<Vec<_>>(),
        ["sans-serif", "monospace", "sans-serif-light"]
    );
    assert!(runs.iter().all(|run| run.bold));
    assert!(!runs[0].italic);
    assert!(runs[1].italic && runs[2].italic);
    Ok(())
}

#[test]
fn preserves_per_script_inheritance_when_only_some_families_are_overridden() -> TestResult {
    // Given an inherited family with only its Latin slots replaced in one run.
    let styles = format!(
        r#"<w:docDefaults><w:rPrDefault><w:rPr>{}</w:rPr></w:rPrDefault></w:docDefaults>"#,
        families("serif")
    );
    let body = r#"<w:p>
<w:r><w:rPr><w:rFonts w:ascii="monospace" w:hAnsi="monospace"/></w:rPr><w:t>Mixed 中文</w:t></w:r>
<w:r><w:rPr><w:rFonts w:ascii="serif" w:hint="eastAsia"/></w:rPr><w:t>Consistent 中文</w:t></w:r>
</w:p>"#;

    // When missing slots inherit instead of being discarded.
    let document = parse(body, &styles)?;

    // Then mixed families keep the documented fallback and unchanged slots remain usable.
    let runs = &document.blocks[0].paragraphs[0].runs;
    assert!(runs[0].font_face.is_empty());
    assert_eq!(runs[1].font_face, "serif");
    assert!(document
        .warnings
        .iter()
        .any(|warning| warning.contains("Mixed-script")));
    Ok(())
}

#[test]
fn theme_overrides_explicit_font_when_both_are_saved_in_the_same_node() -> TestResult {
    for theme in ["asciiTheme", "hAnsiTheme", "eastAsiaTheme", "cstheme"] {
        // Given uniform explicit fonts and a theme choice for one script slot.
        let body = format!(
            r#"<w:p><w:r><w:rPr><w:rFonts w:ascii="serif" w:hAnsi="serif"
w:eastAsia="serif" w:cs="serif" w:{theme}="minorHAnsi"/></w:rPr><w:t>Text</w:t></w:r></w:p>"#
        );

        // When the effective run font is resolved.
        let document = parse(&body, "")?;

        // Then unresolved theme selection never masquerades as the saved explicit font.
        assert!(document.blocks[0].paragraphs[0].runs[0]
            .font_face
            .is_empty());
        assert_eq!(document.warnings.len(), 1);
        assert!(document.warnings[0].contains("Theme fonts"));
    }
    Ok(())
}

#[test]
fn theme_clears_explicit_family_when_it_overrides_an_inherited_font() -> TestResult {
    // Given explicit defaults overridden by an unresolved direct theme choice.
    let styles = format!(
        r#"<w:docDefaults><w:rPrDefault><w:rPr>{}</w:rPr></w:rPrDefault></w:docDefaults>"#,
        families("serif")
    );
    let body = r#"<w:p><w:r><w:rPr><w:rFonts w:asciiTheme="minorHAnsi"/></w:rPr><w:t>Text</w:t></w:r></w:p>"#;

    // When the effective font selection is materialized.
    let document = parse(body, &styles)?;

    // Then the inherited explicit font cannot leak through the unresolved theme.
    assert!(document.blocks[0].paragraphs[0].runs[0]
        .font_face
        .is_empty());
    assert_eq!(document.warnings.len(), 1);
    assert!(document.warnings[0].contains("Theme fonts"));
    Ok(())
}

#[test]
fn direct_explicit_font_replaces_theme_when_inherited_from_earlier_styles() -> TestResult {
    // Given theme defaults, fully replaced by explicit fonts in direct formatting.
    let styles = r#"<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:asciiTheme="minorHAnsi"
w:hAnsiTheme="minorHAnsi" w:eastAsiaTheme="minorEastAsia" w:cstheme="minorBidi"/>
</w:rPr></w:rPrDefault></w:docDefaults>"#;
    let body = format!(
        r#"<w:p><w:r><w:rPr>{}</w:rPr><w:t>Text</w:t></w:r></w:p>"#,
        families("monospace")
    );

    // When the nearest explicit values override each inherited theme slot.
    let document = parse(&body, styles)?;

    // Then the explicit name is emitted and obsolete theme warnings disappear.
    assert_eq!(
        document.blocks[0].paragraphs[0].runs[0].font_face,
        "monospace"
    );
    assert!(document
        .warnings
        .iter()
        .all(|warning| !warning.contains("Theme fonts")));
    Ok(())
}

#[test]
fn font_reaches_each_flow_run_when_tabs_breaks_and_empty_paragraphs_are_saved() -> TestResult {
    // Given a default family plus a distinct empty paragraph mark family.
    let styles = format!(
        r#"<w:docDefaults><w:rPrDefault><w:rPr>{}</w:rPr></w:rPrDefault></w:docDefaults>"#,
        families("monospace")
    );
    let body = format!(
        r#"<w:p><w:r><w:t>Text</w:t><w:tab/><w:br/><w:noBreakHyphen/></w:r></w:p>
<w:p><w:pPr><w:rPr>{}</w:rPr></w:pPr></w:p>"#,
        families("serif")
    );

    // When DOCX creates flow runs and the empty paragraph mark.
    let document = parse(&body, &styles)?;

    // Then every generated run retains its effective font.
    assert!(document.blocks[0].paragraphs[0]
        .runs
        .iter()
        .all(|run| run.font_face == "monospace"));
    assert_eq!(document.blocks[1].paragraphs[0].runs[0].font_face, "serif");
    Ok(())
}

#[test]
fn omits_font_when_no_names_are_saved() -> TestResult {
    for properties in [
        "",
        "<w:rFonts/>",
        r#"<w:rFonts w:ascii=" " w:hint="eastAsia"/>"#,
    ] {
        // Given a run without a usable family or theme choice.
        let body = format!(r#"<w:p><w:r><w:rPr>{properties}</w:rPr><w:t>Text</w:t></w:r></w:p>"#);

        // When the run is serialized.
        let document = parse(&body, "")?;

        // Then the default remains implicit and no font warning is needed.
        assert!(
            serde_json::to_value(&document.blocks[0].paragraphs[0].runs[0])?
                .get("fontFace")
                .is_none()
        );
        assert!(document.warnings.is_empty());
    }
    Ok(())
}

#[test]
fn resolves_theme_font_when_theme_xml_is_present() -> TestResult {
    let mut parts = docx::parts();
    package::replace(
        &mut parts,
        "word/document.xml",
        r#"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
<w:p><w:r><w:rPr><w:rFonts w:asciiTheme="minorHAnsi" w:hAnsiTheme="minorHAnsi" w:eastAsiaTheme="minorEastAsia" w:cstheme="minorBidi"/></w:rPr><w:t>Themed text</w:t></w:r></w:p>
</w:body></w:document>"#,
    );
    let theme_xml = r#"<?xml version="1.0" encoding="UTF-8"?>
<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme">
  <a:themeElements>
    <a:fontScheme name="Office">
      <a:majorFont><a:latin typeface="Calibri Light"/><a:ea typeface="DengXian Light"/><a:cs typeface="Times New Roman"/></a:majorFont>
      <a:minorFont><a:latin typeface="Calibri"/><a:ea typeface="Calibri"/><a:cs typeface="Calibri"/></a:minorFont>
    </a:fontScheme>
  </a:themeElements>
</a:theme>"#;
    parts.push(package::xml("word/theme/theme1.xml", theme_xml));
    package::replace(
        &mut parts,
        "word/_rels/document.xml.rels",
        &package::relationships(&[
            ("rStyles", "styles", "styles.xml"),
            ("rTheme", "theme", "theme/theme1.xml"),
        ]),
    );
    let doc = parse_reader(Cursor::new(package::archive(&parts)?))?;
    let run = &doc.blocks[0].paragraphs[0].runs[0];
    assert_eq!(run.font_face, "Calibri");
    assert!(!doc.warnings.iter().any(|w| w.contains("Theme fonts")));
    Ok(())
}

#[test]
fn prefers_chinese_theme_font_when_japanese_precedes_it_in_font_scheme() -> TestResult {
    let mut parts = docx::parts();
    package::replace(
        &mut parts,
        "word/document.xml",
        r#"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
<w:p><w:r><w:rPr><w:rFonts w:eastAsiaTheme="minorEastAsia"/></w:rPr><w:t>中文</w:t></w:r></w:p>
</w:body></w:document>"#,
    );
    let theme_xml = r#"<?xml version="1.0" encoding="UTF-8"?>
<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme">
  <a:themeElements>
    <a:fontScheme name="Office">
      <a:majorFont>
        <a:latin typeface="Calibri Light"/>
        <a:ea typeface=""/>
        <a:cs typeface=""/>
        <a:font script="Jpan" typeface="Yu Gothic Light"/>
        <a:font script="Hans" typeface="DengXian Light"/>
      </a:majorFont>
      <a:minorFont>
        <a:latin typeface="Calibri"/>
        <a:ea typeface=""/>
        <a:cs typeface=""/>
        <a:font script="Jpan" typeface="Yu Gothic"/>
        <a:font script="Hans" typeface="DengXian"/>
        <a:font script="Hant" typeface="Microsoft JhengHei"/>
      </a:minorFont>
    </a:fontScheme>
  </a:themeElements>
</a:theme>"#;
    parts.push(package::xml("word/theme/theme1.xml", theme_xml));
    package::replace(
        &mut parts,
        "word/_rels/document.xml.rels",
        &package::relationships(&[
            ("rStyles", "styles", "styles.xml"),
            ("rTheme", "theme", "theme/theme1.xml"),
        ]),
    );
    let doc = parse_reader(Cursor::new(package::archive(&parts)?))?;
    let run = &doc.blocks[0].paragraphs[0].runs[0];
    assert_eq!(run.font_face, "DengXian");
    Ok(())
}

fn families(face: &str) -> String {
    format!(r#"<w:rFonts w:ascii="{face}" w:hAnsi="{face}" w:eastAsia="{face}" w:cs="{face}"/>"#)
}

fn parse(body: &str, styles: &str) -> TestResult<Document> {
    let mut parts = docx::parts();
    package::replace(
        &mut parts,
        "word/document.xml",
        &format!(
            r#"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>{body}</w:body></w:document>"#
        ),
    );
    package::replace(
        &mut parts,
        "word/styles.xml",
        &format!(
            r#"<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">{styles}</w:styles>"#
        ),
    );
    Ok(parse_reader(Cursor::new(package::archive(&parts)?))?)
}
