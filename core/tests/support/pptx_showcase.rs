use super::{
    package::{relationships, Parts, TestResult},
    pptx, pptx_backgrounds, pptx_charts, pptx_colors, pptx_compat, pptx_compat_showcase,
    pptx_showcase_notes,
    pptx_showcase_xml::{self as xml, Frame, HEIGHT, WIDTH},
    pptx_typography, pptx_wrapping_showcase,
};
use roxmltree::Document;

pub type OwnedParts = Vec<(String, Vec<u8>)>;
pub const PAGE_COUNT: usize = 18;

pub fn parts() -> TestResult<OwnedParts> {
    let mut output = Vec::new();
    let mut slides = vec![String::from("slides/index.xml")];
    let mut masters = Vec::new();
    let mut layout_id = 2_147_483_648;
    let mut chapters = Vec::new();
    let mut types = String::from(
        r#"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/>
<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
<Override PartName="/ppt/slides/index.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>"#,
    );
    for (key, title, source) in [
        ("base", "基础元素：文字、图形、图片与表格", pptx::parts()),
        (
            "compat",
            "组合变换：缩放、旋转与段落排版",
            pptx_compat::parts(),
        ),
        (
            "charts",
            "图表：折线图与柱状图",
            pptx_charts::showcase_parts(),
        ),
        (
            "colors",
            "文字填色：渐变输入与纯色参照",
            pptx_colors::showcase_parts(),
        ),
        (
            "typography",
            "字体排版：窄框数字与章节标题",
            pptx_typography::parts(),
        ),
        (
            "wrapping",
            "换行对照：3 页覆盖 9 种条件",
            pptx_wrapping_showcase::parts()?,
        ),
        (
            "backgrounds",
            "背景：继承、透明图片与图形变换",
            pptx_backgrounds::parts(),
        ),
        (
            "compatibility",
            "兼容补充：自动编号与预设图形",
            pptx_compat_showcase::parts(),
        ),
    ] {
        let presentation = part(&source, "ppt/presentation.xml")?;
        let annotated = !matches!(key, "wrapping" | "compatibility");
        let frame = Frame::read(presentation, annotated)?;
        let mut targets = slide_targets(&source)?;
        if key == "compat" {
            targets.truncate(1);
        }
        let first = slides.len() + 1;
        slides.extend(
            targets
                .into_iter()
                .map(|target| format!("showcase/{key}/{target}")),
        );
        let pages = if first == slides.len() {
            format!("{first:02}")
        } else {
            format!("{first:02}-{:02}", slides.len())
        };
        chapters.push((title.to_owned(), pages));
        masters.push(format!("showcase/{key}/slideMasters/slideMaster1.xml"));
        let content_types = Document::parse(part(&source, "[Content_Types].xml")?)?;
        for node in content_types
            .descendants()
            .filter(|node| node.has_tag_name("Override"))
        {
            let name = node
                .attribute("PartName")
                .ok_or("content type part missing")?;
            if name == "/ppt/presentation.xml"
                || key == "compat" && name == "/ppt/slides/slide1.xml"
            {
                continue;
            }
            let kind = node
                .attribute("ContentType")
                .ok_or("content type missing")?;
            let path = name
                .strip_prefix("/ppt/")
                .ok_or("unexpected source content type path")?;
            types.push_str(&format!(
                r#"<Override PartName="/ppt/showcase/{key}/{path}" ContentType="{kind}"/>"#
            ));
        }
        for (path, bytes) in source {
            if matches!(
                path,
                "ppt/presentation.xml" | "ppt/_rels/presentation.xml.rels"
            ) {
                continue;
            }
            if key == "compat"
                && matches!(
                    path,
                    "ppt/slides/slide1.xml" | "ppt/slides/_rels/slide1.xml.rels"
                )
            {
                continue;
            }
            let Some(relative) = path.strip_prefix("ppt/") else {
                continue;
            };
            let bytes = if path.ends_with(".xml") {
                let normalized = frame.normalize(std::str::from_utf8(&bytes)?)?;
                if path.starts_with("ppt/slideMasters/") {
                    xml::layout_ids(&normalized, &mut layout_id)?.into_bytes()
                } else if path.starts_with("ppt/slides/") && annotated {
                    pptx_showcase_notes::annotate(&normalized, key, path)?.into_bytes()
                } else {
                    normalized.into_bytes()
                }
            } else {
                bytes
            };
            output.push((format!("ppt/showcase/{key}/{relative}"), bytes));
        }
    }
    types.push_str("</Types>");
    let slide_ids: Vec<_> = (0..slides.len())
        .map(|index| format!("rSlide{index}"))
        .collect();
    let master_ids: Vec<_> = (0..masters.len())
        .map(|index| format!("rMaster{index}"))
        .collect();
    let mut relations: Vec<_> = slide_ids
        .iter()
        .zip(&slides)
        .map(|(id, path)| (id.as_str(), "slide", path.as_str()))
        .collect();
    relations.extend(
        master_ids
            .iter()
            .zip(&masters)
            .map(|(id, path)| (id.as_str(), "slideMaster", path.as_str())),
    );
    let slide_list: String = slide_ids
        .iter()
        .enumerate()
        .map(|(index, id)| format!(r#"<p:sldId id="{}" r:id="{id}"/>"#, index + 256))
        .collect();
    let master_list: String = master_ids
        .iter()
        .enumerate()
        .map(|(index, id)| {
            format!(
                r#"<p:sldMasterId id="{}" r:id="{id}"/>"#,
                index + 2_147_483_648
            )
        })
        .collect();
    let presentation = format!(
        r#"<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<p:sldMasterIdLst>{master_list}</p:sldMasterIdLst><p:sldIdLst>{slide_list}</p:sldIdLst>
<p:sldSz cx="{WIDTH}" cy="{HEIGHT}" type="screen16x9"/><p:notesSz cx="6858000" cy="9144000"/>
<p:defaultTextStyle><a:defPPr><a:defRPr lang="en-US" sz="1200"/></a:defPPr></p:defaultTextStyle></p:presentation>"#
    );
    output.extend([
        ("[Content_Types].xml".to_owned(), types.into_bytes()),
        (
            "_rels/.rels".to_owned(),
            relationships(&[("rOffice", "officeDocument", "ppt/presentation.xml")]).into_bytes(),
        ),
        ("ppt/presentation.xml".to_owned(), presentation.into_bytes()),
        (
            "ppt/_rels/presentation.xml.rels".to_owned(),
            relationships(&relations).into_bytes(),
        ),
        (
            "ppt/slides/index.xml".to_owned(),
            xml::index(&chapters, slides.len() - 1).into_bytes(),
        ),
        (
            "ppt/slides/_rels/index.xml.rels".to_owned(),
            relationships(&[(
                "rLayout",
                "slideLayout",
                "../showcase/base/slideLayouts/slideLayout1.xml",
            )])
            .into_bytes(),
        ),
    ]);
    Ok(output)
}

fn part<'a>(parts: &'a Parts, path: &str) -> TestResult<&'a str> {
    let (_, bytes) = parts
        .iter()
        .find(|(name, _)| *name == path)
        .ok_or("source part missing")?;
    Ok(std::str::from_utf8(bytes)?)
}

fn slide_targets(parts: &Parts) -> TestResult<Vec<String>> {
    let presentation = Document::parse(part(parts, "ppt/presentation.xml")?)?;
    let relations = Document::parse(part(parts, "ppt/_rels/presentation.xml.rels")?)?;
    presentation
        .descendants()
        .filter(|node| node.has_tag_name("sldId"))
        .map(|node| {
            let id = node
                .attribute((
                    "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
                    "id",
                ))
                .ok_or("slide relationship ID missing")?;
            let target = relations
                .descendants()
                .find(|node| node.attribute("Id") == Some(id))
                .and_then(|node| node.attribute("Target"))
                .ok_or("slide relationship target missing")?;
            Ok(target.to_owned())
        })
        .collect()
}
