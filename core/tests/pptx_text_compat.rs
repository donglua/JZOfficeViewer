pub mod support;

use jz_office_core::{
    model::{Document, ElementType, LineSpacingRule, Paragraph},
    parse_reader,
};
use std::io::Cursor;
use support::{checks, package, package::TestResult, pptx};

const TEXT: &str = r#"<a:p><a:pPr><a:defRPr sz="2400"/></a:pPr>
<a:r><a:t>Text</a:t></a:r></a:p>"#;
const SHRINK: &str =
    r#"<a:bodyPr><a:normAutofit fontScale="50000" lnSpcReduction="20000"/></a:bodyPr>"#;

#[test]
fn parses_percentage_line_spacing_when_integer_or_percent_string() -> TestResult {
    for (value, expected) in [
        ("150000", 1.5),
        ("125%", 1.25),
        ("1e35", 10.0),
        ("1e35%", 10.0),
        ("0", 0.1),
        ("0%", 0.1),
        ("5%", 0.1),
    ] {
        let body =
            format!(r#"<a:p><a:pPr><a:lnSpc><a:spcPct val="{value}"/></a:lnSpc></a:pPr></a:p>"#);
        let doc = parse_bodies(["", "", &body])?;
        let paragraph = &paragraphs(&doc)?[0];
        assert_eq!(paragraph.line_spacing_rule, LineSpacingRule::Auto);
        checks::near(paragraph.line_spacing, expected);
        assert!(!doc
            .warnings
            .iter()
            .any(|w| w.contains("custom line spacing")));
    }
    Ok(())
}

#[test]
fn parses_fixed_line_spacing_when_points_are_saved() -> TestResult {
    let body = r#"<a:p><a:pPr><a:lnSpc><a:spcPts val="2250"/></a:lnSpc></a:pPr></a:p>"#;
    let doc = parse_bodies(["", "", body])?;
    let paragraph = &paragraphs(&doc)?[0];
    assert_eq!(paragraph.line_spacing_rule, LineSpacingRule::Exact);
    checks::near(paragraph.line_spacing, 22.5);
    Ok(())
}

#[test]
fn parses_margins_and_signed_first_line_indent_when_saved() -> TestResult {
    for (indent, expected) in [("-127000", -10.0), ("63500", 5.0)] {
        let body = format!(r#"<a:p><a:pPr marL="254000" marR="381000" indent="{indent}"/></a:p>"#);
        let doc = parse_bodies(["", "", &body])?;
        let paragraph = &paragraphs(&doc)?[0];
        checks::near(paragraph.indent, 20.0);
        checks::near(paragraph.right_indent, 30.0);
        checks::near(paragraph.first_line_indent, expected);
        assert!(!doc.warnings.iter().any(|w| w.contains("hanging indents")));
    }
    Ok(())
}

#[test]
fn inherits_paragraph_properties_and_honors_direct_zero_resets() -> TestResult {
    let master = r#"<a:lstStyle><a:lvl1pPr marL="254000" marR="508000" indent="-127000">
<a:lnSpc><a:spcPct val="200000"/></a:lnSpc></a:lvl1pPr></a:lstStyle>"#;
    let layout =
        r#"<a:p><a:pPr marR="381000"><a:lnSpc><a:spcPts val="2400"/></a:lnSpc></a:pPr></a:p>"#;
    let body = r#"<a:p/><a:p><a:pPr marL="0" marR="0" indent="0">
<a:lnSpc><a:spcPct val="125%"/></a:lnSpc></a:pPr></a:p>"#;
    let doc = parse_bodies([master, layout, body])?;
    let paragraphs = paragraphs(&doc)?;
    let inherited = &paragraphs[0];
    checks::near(inherited.indent, 20.0);
    checks::near(inherited.right_indent, 30.0);
    checks::near(inherited.first_line_indent, -10.0);
    assert_eq!(inherited.line_spacing_rule, LineSpacingRule::Exact);
    checks::near(inherited.line_spacing, 24.0);
    let direct = &paragraphs[1];
    checks::near(direct.indent, 0.0);
    checks::near(direct.right_indent, 0.0);
    checks::near(direct.first_line_indent, 0.0);
    assert_eq!(direct.line_spacing_rule, LineSpacingRule::Auto);
    checks::near(direct.line_spacing, 1.25);
    Ok(())
}

#[test]
fn scales_all_run_kinds_and_empty_paragraphs_when_normal_autofit_is_saved() -> TestResult {
    for scale in ["75000", "75%"] {
        let body = format!(
            r#"<a:bodyPr><a:normAutofit fontScale="{scale}"/></a:bodyPr>
<a:p><a:pPr><a:defRPr sz="2400"/></a:pPr>
<a:r><a:t>Default</a:t></a:r><a:r><a:rPr sz="1600"/><a:t>Small</a:t></a:r>
<a:fld id="field" type="slidenum"><a:rPr sz="3200"/><a:t>1</a:t></a:fld>
<a:br><a:rPr sz="1200"/></a:br></a:p><a:p><a:endParaRPr sz="2000"/></a:p>"#
        );
        let doc = parse_bodies(["", "", &body])?;
        let paragraphs = paragraphs(&doc)?;
        assert_eq!(paragraphs[0].runs.len(), 4);
        for (run, expected) in paragraphs[0].runs.iter().zip([18.0, 12.0, 24.0, 9.0]) {
            checks::near(run.size, expected);
        }
        checks::near(paragraphs[1].runs[0].size, 15.0);
    }
    Ok(())
}

#[test]
fn subtracts_autofit_reduction_only_from_percentage_line_spacing() -> TestResult {
    let body = r#"<a:bodyPr><a:normAutofit lnSpcReduction="20%"/></a:bodyPr>
<a:p><a:pPr><a:lnSpc><a:spcPct val="150000"/></a:lnSpc></a:pPr></a:p>
<a:p><a:pPr><a:lnSpc><a:spcPts val="2400"/></a:lnSpc></a:pPr></a:p><a:p/>"#;
    let doc = parse_bodies(["", "", body])?;
    let paragraphs = paragraphs(&doc)?;
    checks::near(paragraphs[0].line_spacing, 1.3);
    assert_eq!(paragraphs[1].line_spacing_rule, LineSpacingRule::Exact);
    checks::near(paragraphs[1].line_spacing, 24.0);
    checks::near(paragraphs[2].line_spacing, 0.8);
    checks::near(paragraphs[0].runs[0].size, 12.0);
    Ok(())
}

#[test]
fn bounds_saved_font_scale_and_preserves_minimum_run_size() -> TestResult {
    for (scale, expected) in [
        ("0", 24.0),
        ("0%", 24.0),
        ("1e35", 24.0),
        ("NaN", 24.0),
        ("-1", 24.0),
        ("101%", 24.0),
        ("500", 24.0),
        ("1000", 1.0),
        ("1%", 1.0),
        ("5000", 1.2),
        ("5%", 1.2),
    ] {
        let body = format!(r#"<a:bodyPr><a:normAutofit fontScale="{scale}"/></a:bodyPr>{TEXT}"#);
        let doc = parse_bodies(["", "", &body])?;
        checks::near(paragraphs(&doc)?[0].runs[0].size, expected);
    }
    Ok(())
}

#[test]
fn bounds_saved_reduction_and_keeps_effective_line_spacing_positive() -> TestResult {
    for (reduction, expected) in [
        ("0", 1.0),
        ("100000", 0.1),
        ("100%", 0.1),
        ("100001", 1.0),
        ("150%", 1.0),
        ("1e35", 1.0),
        ("NaN", 1.0),
        ("-1", 1.0),
    ] {
        let body = format!(
            r#"<a:bodyPr><a:normAutofit lnSpcReduction="{reduction}"/></a:bodyPr>{TEXT}
<a:p><a:pPr><a:lnSpc><a:spcPts val="2400"/></a:lnSpc></a:pPr></a:p>"#
        );
        let doc = parse_bodies(["", "", &body])?;
        let paragraphs = paragraphs(&doc)?;
        checks::near(paragraphs[0].line_spacing, expected);
        checks::near(paragraphs[1].line_spacing, 24.0);
    }
    Ok(())
}

#[test]
fn inherits_normal_autofit_and_applies_nearest_choice_once() -> TestResult {
    for (layout, direct, size, spacing) in [
        ("", "", 12.0, 0.8),
        (
            r#"<a:bodyPr><a:normAutofit fontScale="75%" lnSpcReduction="10%"/></a:bodyPr>"#,
            "",
            18.0,
            0.9,
        ),
        (
            "",
            r#"<a:bodyPr><a:normAutofit fontScale="60000"/></a:bodyPr>"#,
            14.4,
            1.0,
        ),
        ("", "<a:bodyPr><a:normAutofit/></a:bodyPr>", 24.0, 1.0),
    ] {
        let body = format!("{direct}{TEXT}");
        let doc = parse_bodies([SHRINK, layout, &body])?;
        let paragraph = &paragraphs(&doc)?[0];
        checks::near(paragraph.runs[0].size, size);
        checks::near(paragraph.line_spacing, spacing);
    }
    Ok(())
}

#[test]
fn clears_inherited_normal_autofit_when_no_autofit_or_shape_autofit_is_selected() -> TestResult {
    for choice in ["noAutofit", "spAutoFit"] {
        for level in [1, 2] {
            let reset = format!("<a:bodyPr><a:{choice}/></a:bodyPr>");
            let direct = format!("{reset}{TEXT}");
            let bodies = if level == 1 {
                [SHRINK, &reset, TEXT]
            } else {
                [SHRINK, "", &direct]
            };
            let doc = parse_bodies(bodies)?;
            let paragraph = &paragraphs(&doc)?[0];
            checks::near(paragraph.runs[0].size, 24.0);
            checks::near(paragraph.line_spacing, 1.0);
        }
    }
    Ok(())
}

#[test]
fn preserves_inherited_spacing_when_direct_values_are_invalid() -> TestResult {
    let layout = r#"<a:lstStyle><a:lvl1pPr marR="127000" indent="-63500">
<a:lnSpc><a:spcPts val="1800"/></a:lnSpc></a:lvl1pPr></a:lstStyle>"#;
    for value in ["NaN", "inf", "garbage", "-1"] {
        let body = format!(
            r#"<a:p><a:pPr marR="NaN" indent="inf">
<a:lnSpc><a:spcPct val="{value}"/></a:lnSpc></a:pPr></a:p>"#
        );
        let doc = parse_bodies(["", layout, &body])?;
        let paragraph = &paragraphs(&doc)?[0];
        assert_eq!(paragraph.line_spacing_rule, LineSpacingRule::Exact);
        checks::near(paragraph.line_spacing, 18.0);
        checks::near(paragraph.right_indent, 10.0);
        checks::near(paragraph.first_line_indent, -5.0);
    }
    Ok(())
}

#[test]
fn parses_percentage_paragraph_spacing() -> TestResult {
    let body = r#"<a:p><a:pPr><a:spcBef><a:spcPct val="50000"/></a:spcBef>
<a:spcAft><a:spcPct val="50000"/></a:spcAft></a:pPr></a:p>"#;
    let doc = parse_bodies(["", "", body])?;
    let paragraph = &paragraphs(&doc)?[0];
    checks::near(paragraph.before, 9.0);
    checks::near(paragraph.after, 9.0);
    assert!(!doc
        .warnings
        .iter()
        .any(|w| w == "PPTX percentage paragraph spacing is not supported."));

    let body_custom_font = r#"<a:p><a:pPr><a:defRPr sz="2400"/><a:spcBef><a:spcPct val="50000"/></a:spcBef>
<a:spcAft><a:spcPct val="100000"/></a:spcAft></a:pPr></a:p>"#;
    let doc_custom = parse_bodies(["", "", body_custom_font])?;
    let paragraph_custom = &paragraphs(&doc_custom)?[0];
    checks::near(paragraph_custom.before, 12.0);
    checks::near(paragraph_custom.after, 24.0);
    Ok(())
}

#[test]
fn parses_justified_paragraph_alignments() -> TestResult {
    for align in ["just", "dist", "justLow", "thaiDist"] {
        let body = format!(r#"<a:p><a:pPr algn="{align}"/></a:p>"#);
        let doc = parse_bodies(["", "", &body])?;
        let paragraph = &paragraphs(&doc)?[0];
        assert_eq!(paragraph.alignment, 3);
        assert!(!doc
            .warnings
            .iter()
            .any(|w| w == "PPTX justified paragraphs use left alignment."));
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

fn paragraphs(document: &Document) -> TestResult<&[Paragraph]> {
    Ok(&checks::element(&document.pages[0].elements, ElementType::TEXT)?.paragraphs)
}
