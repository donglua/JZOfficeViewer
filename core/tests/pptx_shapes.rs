pub mod support;

use jz_office_core::{
    model::{Document, ElementType, PathCommand},
    parse_reader,
};
use std::io::Cursor;
use support::{
    checks,
    package::{archive, replace, TestResult},
    pptx,
};

fn with_layout_panel(preset: &str, adjustments: &str) -> TestResult<Document> {
    with_layout_panel_style(
        preset,
        adjustments,
        r#"<a:solidFill><a:schemeClr val="bg1"/></a:solidFill><a:ln><a:noFill/></a:ln>"#,
    )
}

fn with_layout_panel_style(preset: &str, adjustments: &str, style: &str) -> TestResult<Document> {
    let mut parts = pptx::parts();
    replace(
        &mut parts,
        "ppt/slideLayouts/slideLayout1.xml",
        &format!(
            r#"
<p:sldLayout xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" type="blank">
<p:cSld><p:spTree><p:sp><p:nvSpPr><p:cNvPr id="10" name="White panel"/>
<p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr>
<a:xfrm><a:off x="0" y="685800"/><a:ext cx="9144000" cy="4394200"/></a:xfrm>
<a:prstGeom prst="{preset}"><a:avLst>{adjustments}</a:avLst></a:prstGeom>
{style}
</p:spPr></p:sp></p:spTree></p:cSld></p:sldLayout>"#
        ),
    );
    Ok(parse_reader(Cursor::new(archive(&parts)?))?)
}

#[test]
fn zero_radius_layout_panel_matches_rectangle_before_slide_content() -> TestResult {
    let plain = with_layout_panel("rect", "")?;
    let square = with_layout_panel("roundRect", r#"<a:gd name="adj" fmla="val 0"/>"#)?;

    assert_eq!(
        serde_json::to_value(&square.pages)?,
        serde_json::to_value(&plain.pages)?
    );
    for page in &square.pages {
        let panel = &page.elements[0];
        assert!(matches!(panel.kind, ElementType::RECT));
        assert_eq!(panel.fill, 0xffffffff);
        assert_eq!(panel.stroke, 0);
        checks::bounds(panel, [0.0, 54.0, 720.0, 346.0]);
        assert!(matches!(page.elements[1].kind, ElementType::TEXT));
    }
    assert!(!square
        .warnings
        .iter()
        .any(|warning| warning.contains("complex geometry")));
    Ok(())
}

#[test]
fn default_rounding_matches_explicit_adjustment_before_slide_content() -> TestResult {
    let explicit = with_layout_panel("roundRect", r#"<a:gd name="adj" fmla="val 16667"/>"#)?;
    for adjustments in ["", r#"<a:gd name="other" fmla="val 0"/>"#] {
        let doc = with_layout_panel("roundRect", adjustments)?;
        assert_eq!(
            serde_json::to_value(&doc.pages)?,
            serde_json::to_value(&explicit.pages)?
        );
        for page in &doc.pages {
            let panel = &page.elements[0];
            assert!(matches!(panel.kind, ElementType::PATH));
            checks::bounds(panel, [0.0, 54.0, 720.0, 346.0]);
            assert_eq!(panel.fill, 0xffffffff);
            assert_eq!(panel.stroke, 0);
            assert!(panel.paths[0].fill && panel.paths[0].stroke);
            assert!(matches!(page.elements[1].kind, ElementType::TEXT));
        }
        assert!(!doc.warnings.iter().any(|w| w.contains("complex geometry")));
    }
    Ok(())
}

#[test]
fn round_rect_adjustment_clamps_radius_to_half_the_short_side() -> TestResult {
    for (adjustment, radius) in [(10000, 34.6), (50000, 173.0), (75000, 173.0)] {
        let doc = with_layout_panel(
            "roundRect",
            &format!(r#"<a:gd name="adj" fmla="val {adjustment}"/>"#),
        )?;
        let panel = &doc.pages[0].elements[0];
        let path = panel.paths.first().ok_or("rounded path missing")?;
        match path.commands.first().ok_or("move missing")? {
            PathCommand::Move([x, y]) => {
                assert_eq!(*x, 0.0);
                assert!((*y - radius).abs() < 0.001);
            }
            _ => return Err("path does not start at left corner".into()),
        }
        assert_eq!(
            path.commands
                .iter()
                .filter(|c| matches!(c, PathCommand::Cubic(_)))
                .count(),
            4
        );
        assert!(matches!(path.commands.last(), Some(PathCommand::Close)));
        for command in &path.commands {
            let points: &[f32] = match command {
                PathCommand::Move(points) | PathCommand::Line(points) => points,
                PathCommand::Quad(points) => points,
                PathCommand::Cubic(points) => points,
                PathCommand::Close => &[],
            };
            for point in points.chunks_exact(2) {
                assert!((0.0..=720.0).contains(&point[0]));
                assert!((0.0..=346.0).contains(&point[1]));
            }
        }
    }
    let negative = with_layout_panel("roundRect", r#"<a:gd name="adj" fmla="val -1000"/>"#)?;
    let square = with_layout_panel("rect", "")?;
    assert_eq!(
        serde_json::to_value(&negative.pages)?,
        serde_json::to_value(&square.pages)?
    );
    Ok(())
}

#[test]
fn rounded_panel_preserves_translucent_fill_stroke_and_circular_corners() -> TestResult {
    let doc = with_layout_panel_style(
        "roundRect",
        r#"<a:gd name="adj" fmla="val 10000"/>"#,
        r#"<a:solidFill><a:srgbClr val="FFFFFF"><a:alpha val="20000"/></a:srgbClr></a:solidFill><a:ln w="3175"><a:solidFill><a:srgbClr val="6096E6"><a:alpha val="20000"/></a:srgbClr></a:solidFill></a:ln>"#,
    )?;
    let panel = &doc.pages[0].elements[0];
    assert_eq!(panel.fill, 0x33ffffff);
    assert_eq!(panel.stroke, 0x336096e6);
    assert_eq!(panel.stroke_width, 0.25);
    let path = panel.paths.first().ok_or("rounded path missing")?;
    let mut start = [0.0, 34.6];
    let corners = [[34.6, 34.6], [685.4, 34.6], [685.4, 311.4], [34.6, 311.4]];
    let mut corner = 0;
    for command in &path.commands {
        match command {
            PathCommand::Move(point) | PathCommand::Line(point) => start = *point,
            PathCommand::Cubic([x1, y1, x2, y2, x, y]) => {
                let midpoint = [
                    (start[0] + 3.0 * x1 + 3.0 * x2 + x) / 8.0,
                    (start[1] + 3.0 * y1 + 3.0 * y2 + y) / 8.0,
                ];
                let center = corners[corner];
                assert!(
                    ((midpoint[0] - center[0]).hypot(midpoint[1] - center[1]) - 34.6).abs() < 0.01
                );
                start = [*x, *y];
                corner += 1;
            }
            PathCommand::Quad(_) => {
                return Err("rounded rectangle uses unexpected quadratic curve".into())
            }
            PathCommand::Close => (),
        }
    }
    assert_eq!(corner, 4);
    Ok(())
}

#[test]
fn unresolved_rounding_is_omitted_with_warning() -> TestResult {
    for adjustments in [
        r#"<a:gd name="adj" fmla="val invalid"/>"#,
        r#"<a:gd name="adj" fmla="val NaN"/>"#,
        r#"<a:gd name="adj" fmla="val 1.5"/>"#,
        r#"<a:gd name="adj" fmla="val 999999999999"/>"#,
        r#"<a:gd name="adj" fmla="val 0 extra"/>"#,
        r#"<a:gd name="adj" fmla="*/ 50000 1 2"/>"#,
    ] {
        let doc = with_layout_panel("roundRect", adjustments)?;
        for page in &doc.pages {
            assert!(
                matches!(page.elements[0].kind, ElementType::TEXT),
                "{adjustments}"
            );
        }
        assert!(doc
            .warnings
            .iter()
            .any(|warning| warning.contains("complex geometry")));
    }
    // star5 现已纳入支持的预设几何：即使携带无关的 adj 调整值也应生成星形路径，
    // 而不再退化为纯文本元素。
    let star = with_layout_panel("star5", r#"<a:gd name="adj" fmla="val 0"/>"#)?;
    assert!(matches!(star.pages[0].elements[0].kind, ElementType::PATH));
    assert!(!star
        .warnings
        .iter()
        .any(|warning| warning.contains("complex geometry")));
    Ok(())
}

#[test]
fn custom_geometry_paths_are_preserved_as_local_commands() -> TestResult {
    let mut parts = pptx::parts();
    replace(
        &mut parts,
        "ppt/slideLayouts/slideLayout1.xml",
        r#"
<p:sldLayout xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" type="blank">
<p:cSld><p:spTree><p:sp><p:nvSpPr><p:cNvPr id="10" name="Custom panel"/>
<p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr>
<a:xfrm><a:off x="0" y="685800"/><a:ext cx="9144000" cy="4394200"/></a:xfrm>
<a:custGeom><a:avLst/><a:gdLst/><a:pathLst><a:path w="100" h="50">
<a:moveTo><a:pt x="0" y="0"/></a:moveTo><a:lnTo><a:pt x="100" y="0"/></a:lnTo>
<a:cubicBezTo><a:pt x="100" y="20"/><a:pt x="80" y="50"/><a:pt x="0" y="50"/></a:cubicBezTo><a:close/>
</a:path></a:pathLst></a:custGeom><a:solidFill><a:srgbClr val="112233"/></a:solidFill>
<a:ln w="12700"><a:solidFill><a:srgbClr val="445566"/></a:solidFill></a:ln>
</p:spPr></p:sp></p:spTree></p:cSld></p:sldLayout>"#,
    );
    let document = parse_reader(Cursor::new(archive(&parts)?))?;
    let element = &document.pages[0].elements[0];
    assert!(matches!(element.kind, ElementType::PATH));
    assert_eq!(element.paths.len(), 1);
    assert_eq!(element.paths[0].commands.len(), 4);
    assert!(matches!(element.paths[0].commands[0], PathCommand::Move(_)));
    assert!(matches!(
        element.paths[0].commands[2],
        PathCommand::Cubic(_)
    ));
    assert_eq!(element.fill, 0xff112233);
    assert_eq!(element.stroke, 0xff445566);
    Ok(())
}
