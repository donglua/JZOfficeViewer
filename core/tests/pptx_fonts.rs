pub mod support;

use jz_office_core::{
    model::{Document, ElementType, Run},
    parse_reader,
};
use serde_json::json;
use std::io::Cursor;
use support::{checks, docx, package, package::TestResult, pptx};

#[test]
fn serializes_latin_typeface_when_explicitly_saved() -> TestResult {
    for face in [
        "Impact",
        "Source Han Sans CN Light",
        "+mj-lt",
        "Unavailable Font",
    ] {
        // Given a Latin typeface alongside existing run formatting.
        let body = format!(
            r#"<a:p><a:r><a:rPr sz="3600" b="1" i="1" u="sng">
<a:latin typeface="{face}"/><a:solidFill><a:srgbClr val="C03020"/></a:solidFill>
</a:rPr><a:t>0 1</a:t></a:r></a:p>"#
        );

        // When the PPTX is parsed and serialized for the viewer.
        let document = parse_bodies(["", "", &body])?;
        let run = serde_json::to_value(&runs(&document)?[0])?;

        // Then the raw font name and existing formatting survive the current schema.
        assert_eq!(document.schema_version, 9);
        let mut expected = json!({
            "text": "0 1", "fontFace": face, "size": 36.0,
            "bold": true, "italic": true, "underline": true, "color": 0xffc03020_u32
        });
        let weight = jz_office_core::model::infer_font_weight(face);
        if weight > 0 {
            expected["weight"] = json!(weight);
        }
        assert_eq!(run, expected);
    }
    Ok(())
}

#[test]
fn nearest_latin_typeface_wins_when_styles_are_inherited() -> TestResult {
    let master = r#"<a:lstStyle><a:lvl1pPr><a:defRPr sz="2400" b="1">
<a:latin typeface="Impact"/></a:defRPr></a:lvl1pPr></a:lstStyle>"#;
    let layout = r#"<a:p><a:pPr><a:defRPr><a:latin typeface="Arial"/></a:defRPr></a:pPr></a:p>"#;
    let paragraph =
        r#"<a:pPr><a:defRPr><a:latin typeface="Source Han Sans CN Light"/></a:defRPr></a:pPr>"#;
    for (layout_body, paragraph_style, run_style, expected) in [
        ("", "", "", "Impact"),
        (layout, "", "", "Arial"),
        (layout, paragraph, "", "Source Han Sans CN Light"),
        (
            layout,
            paragraph,
            r#"<a:latin typeface="Courier New"/>"#,
            "Courier New",
        ),
    ] {
        // Given distinct master, layout, paragraph, and direct font choices.
        let body = format!(
            r#"<a:p>{paragraph_style}<a:r><a:rPr i="1">{run_style}</a:rPr><a:t>Text</a:t></a:r></a:p>"#
        );

        // When the nearest style is resolved through the real package parser.
        let document = parse_bodies([master, layout_body, &body])?;
        let run = serde_json::to_value(&runs(&document)?[0])?;

        // Then missing direct fonts inherit without losing other properties.
        assert_eq!(run["fontFace"], expected);
        assert_eq!(run["size"], 24.0);
        assert_eq!(run["bold"], true);
        assert_eq!(run["italic"], true);
    }
    Ok(())
}

#[test]
fn preserves_latin_typeface_when_fields_breaks_and_empty_paragraphs_are_saved() -> TestResult {
    // Given each supported run kind with a distinct saved typeface.
    let body = r#"<a:lstStyle><a:lvl1pPr><a:defRPr><a:latin typeface="Arial"/>
</a:defRPr></a:lvl1pPr></a:lstStyle><a:p>
<a:fld id="field" type="slidenum"><a:rPr><a:latin typeface="Impact"/></a:rPr><a:t>1</a:t></a:fld>
<a:br><a:rPr><a:latin typeface="Courier New"/></a:rPr></a:br></a:p>
<a:p><a:endParaRPr><a:latin typeface="Source Han Sans CN Light"/></a:endParaRPr></a:p>"#;

    // When these runs are parsed and serialized.
    let document = parse_bodies(["", "", body])?;
    let element = checks::element(&document.pages[0].elements, ElementType::TEXT)?;
    let paragraphs = serde_json::to_value(&element.paragraphs)?;

    // Then all run kinds carry their saved font choice.
    assert_eq!(paragraphs[0]["runs"][0]["fontFace"], "Impact");
    assert_eq!(paragraphs[0]["runs"][1]["fontFace"], "Courier New");
    assert_eq!(
        paragraphs[1]["runs"][0]["fontFace"],
        "Source Han Sans CN Light"
    );
    Ok(())
}

#[test]
fn omits_font_face_when_latin_typeface_is_absent_or_empty() -> TestResult {
    for font in [
        "",
        "<a:latin/>",
        r#"<a:latin typeface=""/>"#,
        r#"<a:ea typeface="SimSun"/>"#,
    ] {
        // Given a run without a usable Latin typeface.
        let body = format!(r#"<a:p><a:r><a:rPr>{font}</a:rPr><a:t>Text</a:t></a:r></a:p>"#);

        // When the run is serialized for an existing schema-4 consumer.
        let document = parse_bodies(["", "", &body])?;
        let run = serde_json::to_value(&runs(&document)?[0])?;

        // Then no empty additive field is emitted.
        assert!(run.get("fontFace").is_none());
    }
    Ok(())
}

#[test]
fn omits_font_face_when_docx_uses_existing_run_defaults() -> TestResult {
    // Given a DOCX package containing inherited and direct formatting.
    let bytes = package::archive(&docx::parts())?;

    // When the same shared Run model is serialized for DOCX.
    let document = parse_reader(Cursor::new(bytes))?;
    let paragraphs = serde_json::to_value(&document.blocks[0].paragraphs)?;

    // Then the new PPTX property does not change DOCX run output.
    for run in paragraphs[0]["runs"].as_array().ok_or("missing runs")? {
        assert!(run.get("fontFace").is_none());
    }
    assert!(serde_json::to_value(Run::default())?
        .get("fontFace")
        .is_none());
    Ok(())
}

#[test]
fn serializes_ea_typeface_when_text_contains_cjk() -> TestResult {
    let body = r#"<a:p><a:r><a:rPr strike="sngStrike" baseline="30000" spc="150">
<a:ea typeface="Microsoft YaHei"/>
</a:rPr><a:t>幻灯片</a:t></a:r></a:p>"#;
    let document = parse_bodies(["", "", body])?;
    let run = &runs(&document)?[0];
    assert_eq!(run.font_face, "Microsoft YaHei");
    assert!(run.strike);
    assert_eq!(
        run.vert_align,
        jz_office_core::model::VertAlign::Superscript
    );
    assert_eq!(run.spacing, 1.5); // 150 hundredths of pt = 1.5 pt
    Ok(())
}

#[test]
fn serializes_ea_typeface_when_both_latin_and_ea_are_present_on_cjk_text() -> TestResult {
    let body = r#"<a:p><a:r><a:rPr>
<a:latin typeface="Arial"/><a:ea typeface="SimSun"/>
</a:rPr><a:t>中文</a:t></a:r>
<a:r><a:rPr>
<a:latin typeface="Arial"/><a:ea typeface="SimSun"/>
</a:rPr><a:t>English</a:t></a:r></a:p>"#;
    let document = parse_bodies(["", "", body])?;
    let runs = runs(&document)?;
    assert_eq!(runs[0].font_face, "SimSun");
    assert_eq!(runs[1].font_face, "Arial");
    Ok(())
}

#[test]
fn direct_zero_baseline_resets_inherited_superscript_and_invalid_preserves_it() -> TestResult {
    let master = r#"<a:lstStyle><a:lvl1pPr><a:defRPr baseline="30000"/></a:lvl1pPr></a:lstStyle>"#;
    for (baseline, expected) in [
        ("0", jz_office_core::model::VertAlign::Baseline),
        ("invalid", jz_office_core::model::VertAlign::Superscript),
    ] {
        let body =
            format!(r#"<a:p><a:r><a:rPr baseline="{baseline}"/><a:t>Text</a:t></a:r></a:p>"#);
        let document = parse_bodies([master, "", &body])?;
        assert_eq!(runs(&document)?[0].vert_align, expected);
    }
    Ok(())
}

fn parse_bodies(bodies: [&str; 3]) -> TestResult<Document> {
    let mut parts = pptx::parts();
    for ((path, root), body) in [
        ("ppt/slideMasters/slideMaster1.xml", "sldMaster"),
        ("ppt/slideLayouts/slideLayout1.xml", "sldLayout"),
        ("ppt/slides/slide2.xml", "sld"),
    ]
    .into_iter()
    .zip(bodies)
    {
        package::replace(
            &mut parts,
            path,
            &format!(
                r#"<p:{root}
xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
<p:cSld><p:spTree><p:sp><p:nvSpPr><p:cNvPr id="2" name="Text"/><p:cNvSpPr/>
<p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr>
<p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="4572000" cy="2743200"/></a:xfrm></p:spPr>
<p:txBody>{body}</p:txBody></p:sp></p:spTree></p:cSld></p:{root}>"#
            ),
        );
    }
    Ok(parse_reader(Cursor::new(package::archive(&parts)?))?)
}

fn runs(document: &Document) -> TestResult<&[Run]> {
    Ok(&checks::element(&document.pages[0].elements, ElementType::TEXT)?.paragraphs[0].runs)
}
