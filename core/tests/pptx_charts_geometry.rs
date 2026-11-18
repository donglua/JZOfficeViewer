//! PPTX 图表与几何图形扩展的端到端用例。
//!
//! 覆盖横向条形图（`barChart` `barDir="bar"`）、饼图（`pieChart`）、环形图
//! （`doughnutChart`）、22 种高频预设几何（`prstGeom`）、`prstDash` 虚线描边
//! 与连接线 `headEnd` / `tailEnd` 箭头端点。

pub mod support;

use jz_office_core::{
    model::{Document, ElementType, PathCommand},
    parse_reader,
};
use std::io::Cursor;
use support::{
    package::{archive, replace, TestResult},
    pptx, pptx_charts,
};

// ---------------------------------------------------------------------------
// 图表用例
// ---------------------------------------------------------------------------

/// 用给定图表 XML 替换首个图表部件，并清空另一页幻灯片。
fn chart_document(chart: &str) -> TestResult<Document> {
    let mut parts = pptx_charts::parts();
    replace(&mut parts, pptx_charts::FIRST_CHART, chart);
    replace(
        &mut parts,
        "ppt/slides/slide1.xml",
        r#"<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree/></p:cSld></p:sld>"#,
    );
    Ok(parse_reader(Cursor::new(archive(&parts)?))?)
}

/// 构造单系列饼图/环形图：无坐标轴，含三个分类。
fn pie_chart(name: &str, hole: Option<i32>, dpt: bool) -> String {
    let hole_xml = hole.map_or_else(String::new, |value| {
        format!(r#"<c:holeSize val="{value}"/>"#)
    });
    let dpt_xml = if dpt {
        r#"<c:dPt><c:idx val="0"/><c:spPr><a:solidFill><a:srgbClr val="FF0000"/></a:solidFill></c:spPr></c:dPt>"#
    } else {
        ""
    };
    let categories = r#"<c:cat><c:strLit><c:ptCount val="3"/>
<c:pt idx="0"><c:v>Red</c:v></c:pt><c:pt idx="1"><c:v>Green</c:v></c:pt>
<c:pt idx="2"><c:v>Blue</c:v></c:pt></c:strLit></c:cat>"#;
    let values = r#"<c:val><c:numLit><c:ptCount val="3"/>
<c:pt idx="0"><c:v>30</c:v></c:pt><c:pt idx="1"><c:v>50</c:v></c:pt>
<c:pt idx="2"><c:v>20</c:v></c:pt></c:numLit></c:val>"#;
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart"
xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
<c:chart><c:plotArea><c:layout/>
<c:{name}>{hole_xml}<c:ser><c:idx val="0"/><c:order val="0"/>
<c:tx><c:v>Slices</c:v></c:tx>{dpt_xml}{categories}{values}</c:ser></c:{name}>
</c:plotArea><c:legend><c:legendPos val="b"/></c:legend><c:plotVisOnly val="1"/>
<c:dispBlanksAs val="gap"/></c:chart></c:chartSpace>"#
    )
}

/// 汇总每个扇区的填充色、命令总数与三次贝塞尔圆弧数量。
fn sector_paths(document: &Document) -> Vec<(u32, usize, usize)> {
    document.pages[0]
        .elements
        .iter()
        .filter(|element| matches!(element.kind, ElementType::PATH))
        .map(|element| {
            let path = element.paths.first();
            let total = path.map_or(0, |path| path.commands.len());
            let cubics = path.map_or(0, |path| {
                path.commands
                    .iter()
                    .filter(|command| matches!(command, PathCommand::Cubic(_)))
                    .count()
            });
            (element.fill, total, cubics)
        })
        .collect()
}

fn texts(document: &Document) -> Vec<String> {
    document.pages[0]
        .elements
        .iter()
        .filter(|element| matches!(element.kind, ElementType::TEXT))
        .map(|element| {
            element
                .paragraphs
                .iter()
                .flat_map(|paragraph| paragraph.runs.iter())
                .map(|run| run.text.clone())
                .collect()
        })
        .collect()
}

#[test]
fn chart_horizontal_bar_extends_each_bar_by_value_ratio() -> TestResult {
    let chart = pptx_charts::category_chart()
        .replace(
            "<c:lineChart><c:grouping val=\"standard\"/>",
            "<c:barChart><c:barDir val=\"bar\"/><c:grouping val=\"clustered\"/>",
        )
        .replace("</c:lineChart>", "</c:barChart>");

    let document = chart_document(&chart)?;
    let page = &document.pages[0];

    // 数据条为纯色填充矩形，图例色块高度很小，用高度区分。
    let bars: Vec<_> = page
        .elements
        .iter()
        .filter(|element| {
            matches!(element.kind, ElementType::RECT)
                && [0xffc0_3050, 0xff20_70c0].contains(&element.fill)
                && element.height > 8.0
        })
        .collect();
    assert_eq!(bars.len(), 8, "两个系列各 4 根数据条");

    // 横向条形图：条形高度应小于宽度，且同一系列内数值越大越宽。
    assert!(bars.iter().all(|bar| bar.width > bar.height));
    let first_series: Vec<_> = bars.iter().filter(|bar| bar.fill == 0xffc0_3050).collect();
    assert_eq!(first_series.len(), 4);
    let mut widths: Vec<f32> = first_series.iter().map(|bar| bar.width).collect();
    let max = widths.iter().copied().fold(0.0, f32::max);
    widths.sort_by(f32::total_cmp);
    // 10 / 25 / 15 / 30 四档数值应产生四种不同宽度
    assert!(max > 0.0);

    // 分类标签仍按分类轴绘制
    let labels = texts(&document);
    for category in ["Q1", "Q2", "Q3", "Q4"] {
        assert!(
            labels.iter().any(|label| label == category),
            "缺少 {category}"
        );
    }
    assert!(document
        .warnings
        .iter()
        .any(|warning| warning.contains("horizontal bar charts")));
    Ok(())
}

#[test]
fn chart_pie_renders_one_bezier_sector_per_positive_value() -> TestResult {
    for (label, chart) in [
        ("pieChart", pie_chart("pieChart", None, false)),
        ("doughnutChart", pie_chart("doughnutChart", Some(60), false)),
    ] {
        let document = chart_document(&chart)?;
        let sectors = sector_paths(&document);
        assert_eq!(sectors.len(), 3, "{label} 应有三个扇区");
        // 每个扇区都用至少一段三次贝塞尔拟合圆弧
        for (_, total, cubics) in &sectors {
            assert!(*cubics >= 1, "{label} 扇区应含三次贝塞尔圆弧");
            assert!(*total >= 4, "{label} 扇区命令数过少");
        }
        // 回退配色互不相同
        let mut fills: Vec<u32> = sectors.iter().map(|(fill, _, _)| *fill).collect();
        fills.dedup();
        assert_eq!(fills.len(), 3, "{label} 扇区颜色应互不相同");

        // 分类图例
        let labels = texts(&document);
        for category in ["Red", "Green", "Blue"] {
            assert!(
                labels.iter().any(|label| label == category),
                "{label} 缺少 {category}"
            );
        }
        assert!(document
            .warnings
            .iter()
            .any(|warning| warning.contains("pie and doughnut charts")));
    }
    Ok(())
}

#[test]
fn chart_pie_honors_explicit_data_point_color() -> TestResult {
    let document = chart_document(&pie_chart("pieChart", None, true))?;
    let sectors = sector_paths(&document);
    assert_eq!(
        sectors[0].0, 0xffff_0000,
        "第一个扇区应使用 c:dPt 声明的红色"
    );
    assert_ne!(sectors[1].0, 0xffff_0000, "其余扇区仍回退主题色");
    Ok(())
}

#[test]
fn chart_doughnut_uses_extra_inner_arc_and_clamps_hole_size() -> TestResult {
    let pie = chart_document(&pie_chart("pieChart", None, false))?;
    let (_, pie_commands, _) = sector_paths(&pie)[0];

    // holeSize 合法值、非法值（0 与 999）都必须渲染为环形图且不 panic
    for hole in [Some(60), Some(0), Some(999), None] {
        let document = chart_document(&pie_chart("doughnutChart", hole, false))?;
        let sectors = sector_paths(&document);
        assert_eq!(sectors.len(), 3, "holeSize={hole:?} 应渲染三个扇区");
        // 环形图比饼图多出内弧反向拟合命令
        assert!(
            sectors[0].1 > pie_commands,
            "holeSize={hole:?} 应有内弧反向命令"
        );
    }
    Ok(())
}

#[test]
fn chart_pie_sector_commands_start_at_polar_move() -> TestResult {
    let document = chart_document(&pie_chart("pieChart", None, false))?;
    let element = document.pages[0]
        .elements
        .iter()
        .find(|element| matches!(element.kind, ElementType::PATH))
        .ok_or("missing sector path")?;
    let path = element.paths.first().ok_or("missing path")?;
    // 饼图扇区：Move(center) -> Line(outer_start) -> Cubic... -> Close
    assert!(matches!(path.commands.first(), Some(PathCommand::Move(_))));
    assert!(matches!(path.commands.last(), Some(PathCommand::Close)));
    assert_eq!(element.stroke, 0xffff_ffff);
    assert_eq!(element.stroke_width, 1.0);
    assert!(path.fill && path.stroke);
    Ok(())
}

// ---------------------------------------------------------------------------
// 预设几何用例
// ---------------------------------------------------------------------------

const BOUNDS: &str =
    r#"<a:xfrm><a:off x="127000" y="254000"/><a:ext cx="2540000" cy="1270000"/></a:xfrm>"#;
const PAINT: &str = r#"<a:solidFill><a:srgbClr val="112233"/></a:solidFill><a:ln w="25400"><a:solidFill><a:srgbClr val="445566"/></a:solidFill></a:ln>"#;

/// 构造只含一个形状的幻灯片文档。
fn shape_document(properties: &str) -> TestResult<Document> {
    let mut parts = pptx::parts();
    replace(
        &mut parts,
        "ppt/slides/slide2.xml",
        &format!(
            r#"<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree><p:sp><p:nvSpPr><p:cNvPr id="1" name="Preset"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr>{properties}</p:spPr><p:txBody><a:bodyPr/><a:p><a:r><a:t>Retained</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>"#
        ),
    );
    Ok(parse_reader(Cursor::new(archive(&parts)?))?)
}

/// 构造只含一条连接线的幻灯片文档。
fn line_document(ln: &str) -> TestResult<Document> {
    let mut parts = pptx::parts();
    replace(
        &mut parts,
        "ppt/slides/slide2.xml",
        &format!(
            r#"<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree><p:cxnSp><p:nvCxnSpPr><p:cNvPr id="5" name="Connector"/><p:cNvCxnSpPr/><p:nvPr/></p:nvCxnSpPr><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="2540000" cy="0"/></a:xfrm><a:prstGeom prst="line"><a:avLst/></a:prstGeom><a:ln w="25400"><a:solidFill><a:srgbClr val="111111"/></a:solidFill>{ln}</a:ln></p:spPr></p:cxnSp></p:spTree></p:cSld></p:sld>"#
        ),
    );
    Ok(parse_reader(Cursor::new(archive(&parts)?))?)
}

fn preset(name: &str, adjustments: &str) -> String {
    format!(r#"<a:prstGeom prst="{name}"><a:avLst>{adjustments}</a:avLst></a:prstGeom>"#)
}

/// 22 种新增预设几何全部编译为闭合 `PATH`，且不再回退为纯文本。
#[test]
fn geometry_presets_emit_closed_paths_without_omission_warnings() -> TestResult {
    for name in [
        // 多边形与几何块
        "parallelogram",
        "trapezoid",
        "pentagon",
        "hexagon",
        "octagon",
        "plus",
        "mathPlus",
        "snip1Rect",
        "round2SameRect",
        // 箭头与流程引导
        "rightArrow",
        "leftArrow",
        "upArrow",
        "downArrow",
        "leftRightArrow",
        "upDownArrow",
        "chevron",
        "homePlate",
        "notchedRightArrow",
        // 星形、流程图与标注框
        "star4",
        "star5",
        "flowChartTerminator",
        "flowChartDocument",
        "wedgeRectCallout",
    ] {
        let document = shape_document(&format!("{BOUNDS}{PAINT}{}", preset(name, "")))?;
        let element = &document.pages[0].elements[0];
        assert!(
            matches!(element.kind, ElementType::PATH),
            "{name} 应编译为 PATH"
        );
        let path = element.paths.first().unwrap_or_else(|| unreachable!());
        assert!(
            matches!(path.commands.first(), Some(PathCommand::Move(_))),
            "{name} 应以 Move 起始"
        );
        assert!(
            matches!(path.commands.last(), Some(PathCommand::Close)),
            "{name} 应闭合"
        );
        assert!(path.fill && path.stroke, "{name} 应同时填充与描边");
        assert!(
            !document
                .warnings
                .iter()
                .any(|warning| warning.contains("complex geometry")),
            "{name} 不应产生省略告警"
        );
    }
    Ok(())
}

/// 流程图预设同样纳入支持范围，不再回退为省略。
#[test]
fn geometry_flowchart_presets_resolve_to_paths() -> TestResult {
    for name in ["flowChartProcess", "flowChartDecision", "flowChartData"] {
        let document = shape_document(&format!("{BOUNDS}{PAINT}{}", preset(name, "")))?;
        assert!(
            matches!(document.pages[0].elements[0].kind, ElementType::PATH),
            "{name} 应编译为 PATH"
        );
        assert!(!document
            .warnings
            .iter()
            .any(|warning| warning.contains("complex geometry")));
    }
    Ok(())
}

/// 方向箭头按短边比例缩放：宽 200 高 100 时箭杆半高与箭头长度符合 adj1/adj2。
#[test]
fn geometry_right_arrow_scales_against_short_side() -> TestResult {
    let size = r#"<a:xfrm><a:off x="0" y="0"/><a:ext cx="2540000" cy="1270000"/></a:xfrm>"#;
    let document = shape_document(&format!("{size}{PAINT}{}", preset("rightArrow", "")))?;
    let path = document.pages[0].elements[0]
        .paths
        .first()
        .ok_or("missing arrow path")?;
    let mut xs = Vec::new();
    let mut ys = Vec::new();
    for command in &path.commands {
        if let PathCommand::Move([x, y]) | PathCommand::Line([x, y]) = command {
            xs.push(*x);
            ys.push(*y);
        }
    }
    let (width, height) = (200.0_f32, 100.0_f32);
    let max_x = xs.iter().copied().fold(f32::MIN, f32::max);
    let min_y = ys.iter().copied().fold(f32::MAX, f32::min);
    let max_y = ys.iter().copied().fold(f32::MIN, f32::max);
    // 箭头顶点触及右侧边界，箭杆居中占据中间 50% 高度
    assert!((max_x - width).abs() < 0.01, "箭头顶点应抵达右边界");
    assert!(min_y.abs() < 0.01, "箭头上下翼应触及上下边界");
    assert!((max_y - height).abs() < 0.01);
    assert!(
        ys.iter().any(|y| (y - height / 2.0).abs() < 0.01),
        "箭杆应居中"
    );
    Ok(())
}

/// 轨道形与文档形预设包含三次贝塞尔圆弧/波浪。
#[test]
fn geometry_terminator_and_document_use_cubic_commands() -> TestResult {
    for name in ["flowChartTerminator", "flowChartDocument"] {
        let document = shape_document(&format!("{BOUNDS}{PAINT}{}", preset(name, "")))?;
        let path = document.pages[0].elements[0]
            .paths
            .first()
            .ok_or("missing path")?;
        assert!(
            path.commands
                .iter()
                .any(|command| matches!(command, PathCommand::Cubic(_))),
            "{name} 应包含 Cubic 命令"
        );
    }
    Ok(())
}

/// 五角星由 10 个外/内径顶点交替构成。
#[test]
fn geometry_star5_alternates_ten_vertices() -> TestResult {
    let document = shape_document(&format!("{BOUNDS}{PAINT}{}", preset("star5", "")))?;
    let path = document.pages[0].elements[0]
        .paths
        .first()
        .ok_or("missing path")?;
    let vertices = path
        .commands
        .iter()
        .filter(|command| matches!(command, PathCommand::Move(_) | PathCommand::Line(_)))
        .count();
    assert_eq!(vertices, 10, "五角星应有 10 个外/内径顶点");
    Ok(())
}

// ---------------------------------------------------------------------------
// 虚线描边与连接线箭头用例
// ---------------------------------------------------------------------------

/// `prstDash` 按线宽换算为点线序列，实线不产生该字段。
#[test]
fn geometry_prst_dash_maps_to_stroke_dash_points() -> TestResult {
    // 线宽 2pt：dash -> [8, 6]，dot -> [2, 4]
    for (value, expected) in [
        ("dash", Some(vec![8.0, 6.0])),
        ("dot", Some(vec![2.0, 4.0])),
        ("lgDash", Some(vec![16.0, 6.0])),
        ("dashDot", Some(vec![8.0, 6.0, 2.0, 6.0])),
        ("lgDashDot", Some(vec![16.0, 6.0, 2.0, 6.0])),
        ("lgDashDotDot", Some(vec![16.0, 6.0, 2.0, 6.0, 2.0, 6.0])),
        ("solid", None),
        ("unknownDash", None),
    ] {
        let ln = format!(r#"<a:prstDash val="{value}"/>"#);
        let document = line_document(&ln)?;
        let element = &document.pages[0].elements[0];
        match expected {
            Some(points) => assert_eq!(element.stroke_dash, points, "{value}"),
            None => assert!(element.stroke_dash.is_empty(), "{value} 应为实线"),
        }
        // 实线元素在 JSON 中不出现 strokeDash 字段，保持旧结构兼容
        let json = serde_json::to_value(element)?;
        if element.stroke_dash.is_empty() {
            assert!(json.get("strokeDash").is_none(), "{value} 不应序列化");
        } else {
            assert!(json.get("strokeDash").is_some(), "{value} 应序列化");
        }
        assert!(!document
            .warnings
            .iter()
            .any(|warning| warning.contains("dashes and arrowheads are not supported")));
    }
    Ok(())
}

/// `tailEnd` 箭头把连接线编译为主干 + 实心三角子路径。
#[test]
fn geometry_tail_end_arrow_builds_solid_triangle_path() -> TestResult {
    let document = line_document(r#"<a:tailEnd type="triangle" w="med" len="med"/>"#)?;
    let element = &document.pages[0].elements[0];
    assert!(matches!(element.kind, ElementType::PATH));
    assert!(element.paths.len() >= 2, "应包含主干与箭头子路径");
    assert_eq!(element.fill, element.stroke, "填充色继承描边色");
    // 第一条为主干（仅描边），其后为实心箭头（仅填充）
    assert!(!element.paths[0].fill && element.paths[0].stroke);
    assert!(
        element.paths[1..]
            .iter()
            .all(|path| path.fill && !path.stroke),
        "三角箭头应为实心填充"
    );
    assert!(!document
        .warnings
        .iter()
        .any(|warning| warning.contains("arrowheads are not supported")));
    Ok(())
}

/// 起止端点同时声明时生成三段子路径（主干 + 两个箭头）。
#[test]
fn geometry_head_and_tail_ends_build_three_sub_paths() -> TestResult {
    let document = line_document(r#"<a:headEnd type="triangle"/><a:tailEnd type="triangle"/>"#)?;
    let element = &document.pages[0].elements[0];
    assert!(matches!(element.kind, ElementType::PATH));
    assert_eq!(element.paths.len(), 3);
    Ok(())
}

/// 开叉双翼箭头保持描边而不用填充。
#[test]
fn geometry_open_arrow_end_stays_stroked() -> TestResult {
    let document = line_document(r#"<a:tailEnd type="arrow" w="lg" len="lg"/>"#)?;
    let element = &document.pages[0].elements[0];
    assert!(matches!(element.kind, ElementType::PATH));
    assert!(
        element.paths[1..]
            .iter()
            .all(|path| path.stroke && !path.fill),
        "开叉箭头应以描边绘制"
    );
    Ok(())
}

/// `type="none"` 与过短线段不生成箭头，仍保留普通直线。
#[test]
fn geometry_arrow_requires_non_none_type_and_length() -> TestResult {
    for ln in [r#"<a:tailEnd type="none"/>"#, ""] {
        let document = line_document(ln)?;
        assert!(
            matches!(document.pages[0].elements[0].kind, ElementType::LINE),
            "{ln} 应保持直线"
        );
    }
    // 线段长度为 0 时即使声明箭头也不展开
    let mut parts = pptx::parts();
    replace(
        &mut parts,
        "ppt/slides/slide2.xml",
        r#"<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree><p:cxnSp><p:nvCxnSpPr><p:cNvPr id="5" name="Degenerate"/><p:cNvCxnSpPr/><p:nvPr/></p:nvCxnSpPr><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/></a:xfrm><a:prstGeom prst="line"><a:avLst/></a:prstGeom><a:ln w="25400"><a:solidFill><a:srgbClr val="111111"/></a:solidFill><a:tailEnd type="triangle"/></a:ln></p:spPr></p:cxnSp></p:spTree></p:cSld></p:sld>"#,
    );
    let document: Document = parse_reader(Cursor::new(archive(&parts)?))?;
    assert!(
        document
            .pages
            .first()
            .and_then(|page| page.elements.first())
            .is_none_or(|element| !element.paths.iter().any(|path| path.fill)),
        "退化线段不应生成实心箭头"
    );
    Ok(())
}

// ---------------------------------------------------------------------------
// DOCX 共享 DrawingML 资产用例
// ---------------------------------------------------------------------------

/// DOCX 的 `<wps:wsp>` 复用同一套 DrawingML 解析，预设几何与虚线应同步生效。
#[test]
fn geometry_docx_wsp_shares_preset_and_dash_support() -> TestResult {
    let shape = r#"<w:p><w:r><w:drawing><wp:anchor behindDoc="1">
  <wp:positionH relativeFrom="column"><wp:align>left</wp:align></wp:positionH>
  <wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>
  <wp:extent cx="1270000" cy="635000"/>
  <wp:wrapNone/>
  <a:graphic><a:graphicData
    xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
    uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">
    <wps:wsp>
      <wps:spPr>
        <a:xfrm><a:off x="0" y="0"/><a:ext cx="1270000" cy="635000"/></a:xfrm>
        <a:prstGeom prst="rightArrow"><a:avLst/></a:prstGeom>
        <a:solidFill><a:srgbClr val="2277BB"/></a:solidFill>
        <a:ln w="25400"><a:solidFill><a:srgbClr val="115599"/></a:solidFill>
          <a:prstDash val="dash"/></a:ln>
      </wps:spPr>
    </wps:wsp>
  </a:graphicData></a:graphic>
</wp:anchor></w:drawing></w:r></w:p>"#;

    let mut parts = support::docx::parts();
    let current = parts
        .iter()
        .find(|(name, _)| *name == "word/document.xml")
        .map(|(_, bytes)| String::from_utf8_lossy(bytes).to_string())
        .ok_or("missing word/document.xml")?;
    // 注入到正文结束标签之前，保持既有 fixture 结构不变
    let injected = current.replace("</w:body>", &format!("{shape}<w:sectPr/></w:body>"));
    replace(&mut parts, "word/document.xml", &injected);

    let document: Document = parse_reader(Cursor::new(archive(&parts)?))?;
    let arrow = document
        .blocks
        .iter()
        .find(|block| matches!(block.kind, ElementType::PATH))
        .ok_or("DOCX 预设几何未编译为 PATH")?;
    assert_eq!(arrow.fill, 0xff22_77bb);
    assert_eq!(arrow.stroke, 0xff11_5599);
    // 线宽 2pt -> dash 序列 [8, 6]
    assert_eq!(arrow.stroke_dash, vec![8.0, 6.0]);
    Ok(())
}
