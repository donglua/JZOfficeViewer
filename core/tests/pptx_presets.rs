pub mod support;

use jz_office_core::{
    model::{Document, ElementType},
    parse_reader,
};
use std::io::Cursor;
use support::{
    package::{archive, replace, TestResult},
    pptx,
};

const BOUNDS: &str =
    r#"<a:xfrm><a:off x="127000" y="254000"/><a:ext cx="2540000" cy="1270000"/></a:xfrm>"#;
const PAINT: &str = r#"<a:solidFill><a:srgbClr val="112233"/></a:solidFill><a:ln w="25400"><a:solidFill><a:srgbClr val="445566"/></a:solidFill></a:ln>"#;

fn document(properties: &str, inherited: &str) -> TestResult<Document> {
    let mut parts = pptx::parts();
    for (path, tag, properties, text) in [
        ("ppt/slides/slide2.xml", "sld", properties, "Retained"),
        (
            "ppt/slideLayouts/slideLayout1.xml",
            "sldLayout",
            inherited,
            "",
        ),
    ] {
        replace(
            &mut parts,
            path,
            &format!(
                r#"<p:{tag} xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree><p:sp><p:nvSpPr><p:cNvPr id="1" name="Preset"/><p:cNvSpPr/><p:nvPr><p:ph idx="42"/></p:nvPr></p:nvSpPr><p:spPr>{properties}</p:spPr><p:txBody><a:bodyPr/><a:p><a:r><a:t>{text}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:{tag}>"#
            ),
        );
    }
    Ok(parse_reader(Cursor::new(archive(&parts)?))?)
}

fn preset(name: &str, adjustments: &str) -> String {
    format!(r#"<a:prstGeom prst="{name}"><a:avLst>{adjustments}</a:avLst></a:prstGeom>"#)
}

#[test]
fn simple_presets_emit_closed_paths_with_ooxml_vertex_order() -> TestResult {
    for (name, points) in [
        ("triangle", vec![[0.0, 100.0], [100.0, 0.0], [200.0, 100.0]]),
        ("rtTriangle", vec![[0.0, 100.0], [0.0, 0.0], [200.0, 100.0]]),
        (
            "diamond",
            vec![[0.0, 50.0], [100.0, 0.0], [200.0, 50.0], [100.0, 100.0]],
        ),
    ] {
        let properties = format!("{BOUNDS}{PAINT}{}", preset(name, ""));
        let doc = document(&properties, "")?;
        let element = &doc.pages[0].elements[0];
        assert!(matches!(element.kind, ElementType::PATH), "{name}");
        let json = serde_json::to_value(element)?;
        let commands = json["paths"][0]["commands"]
            .as_array()
            .ok_or("path commands missing")?;
        assert_eq!(commands.len(), points.len() + 1);
        for (index, point) in points.iter().enumerate() {
            assert_eq!(commands[index]["points"], serde_json::json!(point));
            assert_eq!(
                commands[index]["op"],
                if index == 0 { "MOVE" } else { "LINE" }
            );
        }
        assert_eq!(commands[points.len()]["op"], "CLOSE");
        assert!(element.paths[0].fill && element.paths[0].stroke);
        assert!(!doc.warnings.iter().any(|w| w.contains("complex geometry")));
    }
    Ok(())
}

#[test]
fn triangle_apex_uses_literal_adjustments_clamped_to_shape_width() -> TestResult {
    for (adjustment, apex) in [
        (-5000, 0.0),
        (0, 0.0),
        (25000, 50.0),
        (100000, 200.0),
        (150000, 200.0),
    ] {
        let geometry = preset(
            "triangle",
            &format!(r#"<a:gd name="adj" fmla="val {adjustment}"/>"#),
        );
        let doc = document(&format!("{BOUNDS}{PAINT}{geometry}"), "")?;
        let element = serde_json::to_value(&doc.pages[0].elements[0])?;
        assert_eq!(
            element["paths"][0]["commands"][1]["points"],
            serde_json::json!([apex, 0.0])
        );
        assert!(!doc.warnings.iter().any(|w| w.contains("complex geometry")));
    }
    Ok(())
}

#[test]
fn invalid_triangle_adjustment_omits_geometry_but_retains_text_and_warning() -> TestResult {
    for formula in [
        "val NaN",
        "val 1.5",
        "val 2147483648",
        "val",
        "val 25000 extra",
        "*/ 50000 1 2",
    ] {
        let geometry = preset(
            "triangle",
            &format!(r#"<a:gd name="adj" fmla="{formula}"/>"#),
        );
        let doc = document(&format!("{BOUNDS}{PAINT}{geometry}"), "")?;
        assert_eq!(doc.pages[0].elements.len(), 1, "{formula}");
        assert!(matches!(doc.pages[0].elements[0].kind, ElementType::TEXT));
        assert!(doc.warnings.iter().any(|w| w.contains("complex geometry")));
    }
    Ok(())
}

#[test]
fn preset_path_preserves_paint_transform_and_text() -> TestResult {
    let bounds = BOUNDS.replace("<a:xfrm>", r#"<a:xfrm rot="5400000" flipH="1" flipV="1">"#);
    let reference = document(&format!("{bounds}{PAINT}{}", preset("rect", "")), "")?;
    for name in ["triangle", "rtTriangle", "diamond"] {
        let doc = document(&format!("{bounds}{PAINT}{}", preset(name, "")), "")?;
        let element = &doc.pages[0].elements[0];
        assert!(matches!(element.kind, ElementType::PATH));
        assert_eq!(element.fill, 0xff112233);
        assert_eq!(element.stroke, 0xff445566);
        assert_eq!(element.stroke_width, 2.0);
        assert_eq!(element.transform, reference.pages[0].elements[0].transform);
        assert_eq!(
            serde_json::to_value(&doc.pages[0].elements[1])?,
            serde_json::to_value(&reference.pages[0].elements[1])?
        );
    }
    Ok(())
}

#[test]
fn inherited_preset_uses_slide_dimensions_and_local_geometry_can_replace_it() -> TestResult {
    let geometry = preset("triangle", r#"<a:gd name="adj" fmla="val 25000"/>"#);
    let inherited = format!("{BOUNDS}{PAINT}{geometry}");
    for (local, expected_type, expected_apex) in [
        ("".to_owned(), "PATH", 50.0),
        (BOUNDS.replace("2540000", "5080000"), "PATH", 100.0),
        (preset("diamond", ""), "PATH", 100.0),
        (preset("rect", ""), "RECT", 0.0),
    ] {
        let doc = document(&local, &inherited)?;
        let element = serde_json::to_value(&doc.pages[0].elements[0])?;
        assert_eq!(element["type"], expected_type);
        assert_eq!(element["fill"], 0xff112233_u32);
        if expected_type == "PATH" {
            assert_eq!(
                element["paths"][0]["commands"][1]["points"],
                serde_json::json!([expected_apex, 0.0])
            );
        } else {
            assert!(element.get("paths").is_none());
        }
        assert!(!doc.warnings.iter().any(|w| w.contains("complex geometry")));
    }
    Ok(())
}
