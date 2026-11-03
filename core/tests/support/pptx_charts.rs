#[cfg(test)]
use super::checks;
use super::{
    package::{relationships, xml, Parts},
    pptx, pptx_shapes,
};
#[cfg(test)]
use jz_office_core::model::{Element, ElementType, Page};

pub const RED: u32 = 0xffc03050;
pub const BLUE: u32 = 0xff2070c0;
pub const FRAME: [f32; 4] = [48.0, 96.0, 624.0, 276.0];
pub const FIRST_CHART: &str = "ppt/charts/chart1.xml";
pub const VALUES: &str = r#"<c:val><c:numRef><c:f>'missing.csv'!$B$2:$B$5</c:f>
<c:numCache><c:formatCode>General</c:formatCode><c:ptCount val="4"/>
<c:pt idx="2"><c:v>15</c:v></c:pt><c:pt idx="0"><c:v>10</c:v></c:pt>
<c:pt idx="3"><c:v>30</c:v></c:pt><c:pt idx="1"><c:v>25</c:v></c:pt>
</c:numCache></c:numRef></c:val>"#;
const CATEGORIES: &str = r#"<c:cat><c:strRef><c:f>'missing.csv'!$A$2:$A$5</c:f>
<c:strCache><c:ptCount val="4"/>
<c:pt idx="2"><c:v>Q3</c:v></c:pt><c:pt idx="0"><c:v>Q1</c:v></c:pt>
<c:pt idx="3"><c:v>Q4</c:v></c:pt><c:pt idx="1"><c:v>Q2</c:v></c:pt>
</c:strCache></c:strRef></c:cat>"#;
const CHART_TYPES: &str = r#"<Override PartName="/ppt/charts/chart1.xml" ContentType="application/vnd.openxmlformats-officedocument.drawingml.chart+xml"/>
<Override PartName="/ppt/charts/chart2.xml" ContentType="application/vnd.openxmlformats-officedocument.drawingml.chart+xml"/></Types>"#;
const EXTERNAL: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rCsv" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/package"
Target="file:///__jz_office_nonexistent__/missing.csv" TargetMode="External"/></Relationships>"#;

pub fn parts() -> Parts {
    let mut parts = pptx::parts();
    for (name, bytes) in &mut parts {
        let replacement = match *name {
            "[Content_Types].xml" => {
                String::from_utf8_lossy(bytes).replace("</Types>", CHART_TYPES)
            }
            "ppt/slides/slide2.xml" => slide("Category cache", "rChart"),
            "ppt/slides/slide1.xml" => slide("Date cache", "rChart"),
            "ppt/slides/_rels/slide2.xml.rels" => slide_relationships("../charts/chart1.xml"),
            "ppt/slides/_rels/slide1.xml.rels" => slide_relationships("../charts/chart2.xml"),
            _ => continue,
        };
        *bytes = replacement.into_bytes();
    }
    parts.extend([
        xml(FIRST_CHART, &category_chart()),
        xml("ppt/charts/chart2.xml", &date_chart()),
        xml("ppt/charts/_rels/chart1.xml.rels", EXTERNAL),
        xml("ppt/charts/_rels/chart2.xml.rels", EXTERNAL),
    ]);
    parts
}

pub fn column_chart() -> String {
    category_chart()
        .replace(
            "<c:lineChart><c:grouping val=\"standard\"/>",
            "<c:barChart><c:barDir val=\"col\"/><c:grouping val=\"clustered\"/>",
        )
        .replace("</c:lineChart>", "</c:barChart>")
}

pub fn showcase_parts() -> Parts {
    let mut parts = pptx::parts();
    for (name, bytes) in &mut parts {
        let replacement = match *name {
            "[Content_Types].xml" => {
                String::from_utf8_lossy(bytes).replace("</Types>", CHART_TYPES)
            }
            "ppt/slides/slide2.xml" => slide("Category cache", "rChart"),
            "ppt/slides/slide1.xml" => slide("Date cache", "rChart"),
            "ppt/slides/_rels/slide2.xml.rels" => slide_relationships("../charts/chart1.xml"),
            "ppt/slides/_rels/slide1.xml.rels" => slide_relationships("../charts/chart2.xml"),
            _ => continue,
        };
        *bytes = replacement.into_bytes();
    }
    parts.extend([
        xml(FIRST_CHART, &column_chart()),
        xml("ppt/charts/chart2.xml", &date_chart()),
        xml("ppt/charts/_rels/chart1.xml.rels", EXTERNAL),
        xml("ppt/charts/_rels/chart2.xml.rels", EXTERNAL),
    ]);
    parts
}

pub fn category_chart() -> String {
    let literal = r#"<c:val><c:numLit><c:formatCode>General</c:formatCode><c:ptCount val="4"/>
<c:pt idx="3"><c:v>10</c:v></c:pt><c:pt idx="1"><c:v>20</c:v></c:pt>
<c:pt idx="0"><c:v>30</c:v></c:pt><c:pt idx="2"><c:v>25</c:v></c:pt></c:numLit></c:val>"#;
    chart(
        "Cached categories",
        &format!(
            "{}{}",
            series((0, "Alpha", "C03050"), CATEGORIES, VALUES),
            series((1, "Beta", "2070C0"), CATEGORIES, literal)
        ),
        "catAx",
    )
}

fn date_chart() -> String {
    let categories = r#"<c:cat><c:numRef><c:f>'missing.csv'!$A$2:$A$5</c:f>
<c:numCache><c:formatCode>yyyy-mm-dd</c:formatCode><c:ptCount val="4"/>
<c:pt idx="2"><c:v>45294</c:v></c:pt><c:pt idx="0"><c:v>45292</c:v></c:pt>
<c:pt idx="3"><c:v>45295</c:v></c:pt><c:pt idx="1"><c:v>45293</c:v></c:pt>
</c:numCache></c:numRef></c:cat>"#;
    chart(
        "Cached dates",
        &series((0, "Daily", "C03050"), categories, VALUES),
        "dateAx",
    )
}

pub fn series((index, name, color): (usize, &str, &str), categories: &str, values: &str) -> String {
    format!(
        r#"<c:ser><c:idx val="{index}"/><c:order val="{index}"/><c:tx><c:v>{name}</c:v></c:tx>
<c:spPr><a:ln w="25400"><a:solidFill><a:srgbClr val="{color}"/></a:solidFill></a:ln></c:spPr>
<c:marker><c:symbol val="none"/></c:marker>{categories}{values}<c:smooth val="0"/></c:ser>"#
    )
}

fn chart(title: &str, series: &str, category_axis: &str) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart"
xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<c:date1904 val="0"/><c:chart><c:title><c:tx><c:rich><a:bodyPr/><a:lstStyle/>
<a:p><a:r><a:rPr sz="1600"/><a:t>{title}</a:t></a:r></a:p></c:rich></c:tx><c:overlay val="0"/></c:title>
<c:plotArea><c:layout/><c:lineChart><c:grouping val="standard"/>{series}
<c:axId val="100"/><c:axId val="200"/></c:lineChart>
<c:{category_axis}><c:axId val="100"/><c:scaling><c:orientation val="minMax"/></c:scaling>
<c:delete val="0"/><c:axPos val="b"/><c:tickLblPos val="nextTo"/><c:crossAx val="200"/>
<c:crosses val="autoZero"/></c:{category_axis}>
<c:valAx><c:axId val="200"/><c:scaling><c:orientation val="minMax"/></c:scaling>
<c:delete val="0"/><c:axPos val="l"/><c:majorGridlines/><c:numFmt formatCode="General" sourceLinked="1"/>
<c:tickLblPos val="nextTo"/><c:crossAx val="100"/><c:crosses val="autoZero"/></c:valAx></c:plotArea>
<c:legend><c:legendPos val="b"/><c:overlay val="0"/></c:legend><c:plotVisOnly val="1"/>
<c:dispBlanksAs val="gap"/></c:chart><c:externalData r:id="rCsv"><c:autoUpdate val="1"/></c:externalData>
</c:chartSpace>"#
    )
}

fn slide(title: &str, relation: &str) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<p:cSld><p:spTree>{}{}
<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="3" name="Cached chart"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>
<p:xfrm><a:off x="609600" y="1219200"/><a:ext cx="7924800" cy="3505200"/></p:xfrm>
<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/chart">
<c:chart xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" r:id="{relation}"/>
</a:graphicData></a:graphic></p:graphicFrame></p:spTree></p:cSld>
<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"#,
        pptx_shapes::GROUP,
        pptx_shapes::title(title, "202124")
    )
}

fn slide_relationships(chart: &str) -> String {
    relationships(&[
        ("rLayout", "slideLayout", "../slideLayouts/slideLayout1.xml"),
        ("rChart", "chart", chart),
    ])
}

pub fn oversized_chart(point_counts: &[usize]) -> String {
    let series = point_counts.iter().enumerate().map(|(index, count)| {
        let points: String = (0..*count).map(|i| {
            format!(r#"<c:pt idx="{i}"><c:v>{}</c:v></c:pt>"#, i % 2)
        }).collect();
        let values = format!(r#"<c:val><c:numLit><c:ptCount val="{count}"/>{points}</c:numLit></c:val>"#);
        let categories = format!(r#"<c:cat><c:numRef><c:f>Missing!A:A</c:f><c:numCache><c:ptCount val="{count}"/>{points}</c:numCache></c:numRef></c:cat>"#);
        series((index, "Bounded", "C03050"), &categories, &values)
    }).collect::<String>();
    chart("Bounded cache", &series, "catAx")
}

#[cfg(test)]
pub fn data_segments(page: &Page, color: u32) -> Vec<[(f32, f32); 2]> {
    let mut segments: Vec<_> = page
        .elements
        .iter()
        .filter(|element| matches!(element.kind, ElementType::LINE) && element.stroke == color)
        .map(endpoints)
        .filter(|[start, end]| (end.1 - start.1).abs() > 0.01)
        .collect();
    segments.sort_by(|a, b| a[0].0.total_cmp(&b[0].0));
    segments
}

#[cfg(test)]
pub fn endpoints(element: &Element) -> [(f32, f32); 2] {
    let [a, b, c, d, tx, ty] = element.transform;
    let mut points = [(0.0, 0.0), (element.width, element.height)]
        .map(|(x, y)| (a * x + c * y + tx, b * x + d * y + ty));
    points.sort_by(|a, b| a.0.total_cmp(&b.0));
    points
}

#[cfg(test)]
pub fn assert_series(page: &Page, color: u32, values: [f32; 4]) {
    let segments = data_segments(page, color);
    assert_eq!(
        segments.len(),
        3,
        "Expected three data segments for {color:#x}"
    );
    for (index, [start, end]) in segments.iter().enumerate() {
        assert!(end.0 > start.0);
        assert_eq!(
            (end.1 - start.1).is_sign_negative(),
            values[index + 1] > values[index]
        );
        for &(x, y) in [start, end] {
            assert!(x.is_finite() && (FRAME[0]..=FRAME[0] + FRAME[2]).contains(&x));
            assert!(y.is_finite() && (FRAME[1]..=FRAME[1] + FRAME[3]).contains(&y));
        }
        if index > 0 {
            checks::near(start.0, segments[index - 1][1].0);
            checks::near(start.1, segments[index - 1][1].1);
        }
    }
    let y0 = segments[0][0].1;
    let y3 = segments[2][1].1;
    for index in 1..3 {
        checks::near(
            (segments[index][0].1 - y0) / (y3 - y0),
            (values[index] - values[0]) / (values[3] - values[0]),
        );
    }
}
