pub mod support;

use jz_office_core::Package;
use std::{collections::HashSet, io::Cursor};
use support::{
    package::{archive, TestResult},
    pptx_showcase,
};

#[test]
fn showcase_package_has_namespaced_dependencies_content_types_and_unique_shape_ids() -> TestResult {
    let parts = pptx_showcase::parts()?;
    let mut package = Package::new(Cursor::new(archive(&parts)?))?;
    let type_bytes = package.read("[Content_Types].xml", 64 * 1024)?;
    let types = roxmltree::Document::parse(std::str::from_utf8(&type_bytes)?)?;
    let mut layout_ids = HashSet::new();

    for (path, bytes) in &parts {
        if path.ends_with(".xml") || path.ends_with(".rels") {
            let xml = roxmltree::Document::parse(std::str::from_utf8(bytes)?)?;
            for node in xml
                .descendants()
                .filter(|node| node.has_tag_name("sldLayoutId"))
            {
                let id = node
                    .attribute("id")
                    .ok_or("layout ID missing")?
                    .parse::<u32>()?;
                assert!(
                    layout_ids.insert(id),
                    "Duplicate presentation layout ID {id}"
                );
            }
            if xml.root_element().has_tag_name("chartSpace") {
                let children: Vec<_> = xml
                    .root_element()
                    .children()
                    .filter(|node| node.is_element())
                    .map(|node| node.tag_name().name())
                    .collect();
                let text = children
                    .iter()
                    .position(|name| *name == "txPr")
                    .ok_or("chart text style missing")?;
                let external = children
                    .iter()
                    .position(|name| *name == "externalData")
                    .ok_or("chart external data missing")?;
                assert!(
                    text < external,
                    "Chart text style must precede externalData"
                );
            }
            if xml.root_element().has_tag_name("sld") {
                let mut ids = HashSet::new();
                for node in xml.descendants().filter(|node| node.has_tag_name("cNvPr")) {
                    let id = node
                        .attribute("id")
                        .ok_or("shape ID missing")?
                        .parse::<u32>()?;
                    assert!(ids.insert(id), "Duplicate shape ID {id} in {path}");
                }
                assert!(!ids.is_empty());
            }
        }
        if path != "[Content_Types].xml" {
            let absolute = format!("/{path}");
            assert!(
                types.root_element().children().any(|node| {
                    node.attribute("PartName") == Some(absolute.as_str())
                        || node.has_tag_name("Default")
                            && node.attribute("Extension") == path.rsplit('.').next()
                }),
                "Content type missing for {path}"
            );
        }
        let source = if path == "_rels/.rels" {
            Some(String::new())
        } else {
            path.split_once("/_rels/").and_then(|(prefix, leaf)| {
                leaf.strip_suffix(".rels")
                    .map(|leaf| format!("{prefix}/{leaf}"))
            })
        };
        if let Some(source) = source {
            for target in package.relationships(&source)?.values() {
                assert!(package.has(target), "Unresolved {target} from {source}");
            }
        }
    }
    assert_eq!(layout_ids.len(), 8);
    for name in [
        "base",
        "compat",
        "charts",
        "colors",
        "typography",
        "wrapping",
        "backgrounds",
        "compatibility",
    ] {
        assert!(package.has(&format!("ppt/showcase/{name}/theme/theme1.xml")));
        assert!(package.has(&format!(
            "ppt/showcase/{name}/slideMasters/slideMaster1.xml"
        )));
    }
    for path in [
        "ppt/showcase/charts/charts/chart1.xml",
        "ppt/showcase/charts/charts/chart2.xml",
        "ppt/showcase/base/media/pixel.png",
        "ppt/showcase/compat/media/pixel.png",
        "ppt/showcase/backgrounds/media/transparent-title.png",
    ] {
        assert!(package.has(path), "Missing dependency {path}");
    }
    Ok(())
}
