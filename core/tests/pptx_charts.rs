pub mod support;

use jz_office_core::{
    model::{Document, ElementType, Page},
    parse_reader,
};
use std::io::Cursor;
use support::{
    checks,
    package::{archive, replace, TestResult},
    pptx_charts::{
        self as fixture, assert_series, data_segments, BLUE, FIRST_CHART, FRAME, RED, VALUES,
    },
};

#[test]
fn cached_series_render_inside_the_frame_in_presentation_order() -> TestResult {
    let document = parse_reader(Cursor::new(archive(&fixture::parts())?))?;

    assert_eq!(document.pages.len(), 2);
    assert!(texts(&document.pages[0]).contains(&"Category cache".to_owned()));
    assert!(texts(&document.pages[1]).contains(&"Date cache".to_owned()));
    for page in &document.pages {
        checks::near(page.width, 720.0);
        checks::near(page.height, 405.0);
    }
    assert_series(&document.pages[0], RED, [10.0, 25.0, 15.0, 30.0]);
    assert_series(&document.pages[0], BLUE, [30.0, 20.0, 25.0, 10.0]);
    Ok(())
}

#[test]
fn chart_title_legend_and_categories_come_from_indexed_caches() -> TestResult {
    let document = parse_reader(Cursor::new(archive(&fixture::parts())?))?;

    let page = &document.pages[0];
    let labels = texts(page);
    for text in ["Cached categories", "Alpha", "Beta", "Q1", "Q2", "Q3", "Q4"] {
        assert!(
            labels.iter().any(|label| label == text),
            "Missing {text}: {labels:?}"
        );
    }
    let mut categories: Vec<_> = page
        .elements
        .iter()
        .filter_map(|element| {
            let text = checks::text(&element.paragraphs);
            ["Q1", "Q2", "Q3", "Q4"]
                .contains(&text.as_str())
                .then_some((element.x, text))
        })
        .collect();
    categories.sort_by(|a, b| a.0.total_cmp(&b.0));
    assert_eq!(
        categories
            .iter()
            .map(|(_, text)| text.as_str())
            .collect::<Vec<_>>(),
        ["Q1", "Q2", "Q3", "Q4"]
    );
    Ok(())
}

#[test]
fn date_axis_renders_cached_excel_dates_without_the_external_csv() -> TestResult {
    let parts = fixture::parts();
    assert!(parts.iter().all(|(name, _)| !name.ends_with(".csv")));

    let document = parse_reader(Cursor::new(archive(&parts)?))?;

    let page = &document.pages[1];
    assert_series(page, RED, [10.0, 25.0, 15.0, 30.0]);
    let labels = texts(page);
    for date in ["2024-01-01", "2024-01-02", "2024-01-03", "2024-01-04"] {
        assert!(
            labels.iter().any(|label| label == date),
            "Missing formatted cached date {date}: {labels:?}"
        );
    }
    assert!(labels.iter().any(|label| label == "Cached dates"));
    assert!(labels.iter().any(|label| label == "Daily"));
    Ok(())
}

#[test]
fn sparse_values_leave_a_gap_at_the_missing_index_by_default() -> TestResult {
    let chart = fixture::category_chart()
        .replace(r#"<c:pt idx="1"><c:v>25</c:v></c:pt>"#, "")
        .replace(r#"<c:dispBlanksAs val="gap"/>"#, "");

    let document = document(&chart)?;

    let segments = data_segments(&document.pages[0], RED);
    assert_eq!(segments.len(), 1, "Must not connect across missing point 1");
    let [(x1, y1), (x2, y2)] = segments[0];
    assert!(x1 > FRAME[0] + FRAME[2] / 2.0 && x2 > x1);
    assert!(y2 < y1, "Remaining segment must connect values 15 and 30");
    assert_series(&document.pages[0], BLUE, [30.0, 20.0, 25.0, 10.0]);
    Ok(())
}

#[test]
fn sparse_values_honor_zero_and_span_policies() -> TestResult {
    for mode in ["zero", "span"] {
        let chart = fixture::category_chart()
            .replace(r#"<c:pt idx="1"><c:v>25</c:v></c:pt>"#, "")
            .replace(
                r#"dispBlanksAs val="gap""#,
                &format!(r#"dispBlanksAs val="{mode}""#),
            );

        let document = document(&chart)?;

        let page = &document.pages[0];
        if mode == "zero" {
            assert_series(page, RED, [10.0, 0.0, 15.0, 30.0]);
        } else {
            let segments = data_segments(page, RED);
            assert_eq!(segments.len(), 2);
            let [a, b] = segments[0];
            let [c, d] = segments[1];
            checks::near(b.0, c.0);
            checks::near(b.1, c.1);
            checks::near((b.0 - a.0) / (d.0 - c.0), 2.0);
            checks::near((b.1 - a.1) / (d.1 - a.1), 0.25);
            assert!(a.1 > b.1 && b.1 > d.1);
        }
    }
    Ok(())
}

#[test]
fn missing_value_cache_warns_without_fabricating_data_lines() -> TestResult {
    let chart = fixture::category_chart().replace(
        VALUES,
        r#"<c:val><c:numRef><c:f>Missing!B2:B5</c:f></c:numRef></c:val>"#,
    );

    assert_omitted(&chart)
}

#[test]
fn malformed_value_caches_warn_without_fabricating_data_lines() -> TestResult {
    for values in [
        VALUES.replace("<c:v>15</c:v>", "<c:v>NaN</c:v>"),
        VALUES.replace(r#"idx="2""#, r#"idx="0""#),
        VALUES.replace(r#"idx="2""#, r#"idx="4""#),
        VALUES.replace(r#"idx="2""#, r#"idx="invalid""#),
    ] {
        let chart = fixture::category_chart().replace(VALUES, &values);
        assert_omitted(&chart)?;
    }
    Ok(())
}

#[test]
fn unsupported_bar_and_stacked_charts_warn_without_data_lines() -> TestResult {
    for chart in [
        fixture::category_chart().replace("lineChart", "barChart"),
        fixture::category_chart()
            .replace(
                "<c:lineChart><c:grouping val=\"standard\"/>",
                "<c:barChart><c:barDir val=\"bar\"/><c:grouping val=\"clustered\"/>",
            )
            .replace("</c:lineChart>", "</c:barChart>"),
        fixture::category_chart()
            .replace(
                "<c:lineChart><c:grouping val=\"standard\"/>",
                "<c:barChart><c:barDir val=\"col\"/><c:grouping val=\"stacked\"/>",
            )
            .replace("</c:lineChart>", "</c:barChart>"),
        fixture::category_chart()
            .replace(r#"grouping val="standard""#, r#"grouping val="stacked""#),
        fixture::category_chart().replace(
            r#"grouping val="standard""#,
            r#"grouping val="percentStacked""#,
        ),
    ] {
        assert_omitted(&chart)?;
    }
    Ok(())
}

#[test]
fn explicit_value_axis_bounds_clip_crossing_segments() -> TestResult {
    let chart = fixture::category_chart().replace(
        r#"<c:valAx><c:axId val="200"/><c:scaling>"#,
        r#"<c:valAx><c:axId val="200"/><c:scaling><c:min val="15"/><c:max val="25"/>"#,
    ).replace("<c:majorGridlines/>", r#"<c:majorGridlines><c:spPr><a:ln><a:solidFill><a:srgbClr val="11AB22"/></a:solidFill></a:ln></c:spPr></c:majorGridlines>"#);

    let document = document(&chart)?;

    let page = &document.pages[0];
    let mut grid_y: Vec<_> = page
        .elements
        .iter()
        .filter(|e| matches!(e.kind, ElementType::LINE) && e.stroke == 0xff11ab22)
        .map(|e| fixture::endpoints(e)[0].1)
        .collect();
    grid_y.sort_by(f32::total_cmp);
    let top = *grid_y.first().ok_or("Missing range gridlines")?;
    let bottom = *grid_y.last().ok_or("Missing range gridlines")?;
    assert!(bottom > top);
    let segments = data_segments(page, RED);
    assert_eq!(segments.len(), 3);
    let full_width = segments[1][1].0 - segments[1][0].0;
    for index in [0, 2] {
        checks::near(
            (segments[index][1].0 - segments[index][0].0) / full_width,
            2.0 / 3.0,
        );
    }
    for ((_, y), value) in segments
        .into_iter()
        .flatten()
        .zip([15.0, 25.0, 25.0, 15.0, 15.0, 25.0])
    {
        checks::near((bottom - y) / (bottom - top), (value - 15.0) / 10.0);
    }
    Ok(())
}

#[test]
fn logarithmic_and_invalid_explicit_scales_warn_without_data_lines() -> TestResult {
    for scale in [
        r#"<c:logBase val="10"/>"#,
        r#"<c:min val="40"/><c:max val="5"/>"#,
    ] {
        let chart = fixture::category_chart().replace(
            r#"<c:valAx><c:axId val="200"/><c:scaling>"#,
            &format!(r#"<c:valAx><c:axId val="200"/><c:scaling>{scale}"#),
        );
        assert_omitted(&chart)?;
    }
    Ok(())
}

#[test]
fn caches_over_point_or_series_budgets_warn_without_partial_charts() -> TestResult {
    for counts in [&[2049][..], &[2048, 2048, 2], &[2; 9]] {
        assert_omitted(&fixture::oversized_chart(counts))?;
    }
    Ok(())
}

#[test]
fn column_chart_renders_rectangles_for_each_series_bar() -> TestResult {
    let chart_xml = fixture::category_chart()
        .replace(
            "<c:lineChart><c:grouping val=\"standard\"/>",
            "<c:barChart><c:barDir val=\"col\"/><c:grouping val=\"clustered\"/>",
        )
        .replace("</c:lineChart>", "</c:barChart>");

    let document = document(&chart_xml)?;
    let page = &document.pages[0];

    // Verify warning mentions column charts
    assert!(
        document
            .warnings
            .iter()
            .any(|w| w.contains("column charts")),
        "Expected column chart warning, got: {:?}",
        document.warnings
    );

    // Filter bars: filled RECTs with RED or BLUE fill
    let red_bars: Vec<_> = page
        .elements
        .iter()
        .filter(|e| matches!(e.kind, ElementType::RECT) && e.fill == RED)
        .collect();
    let blue_bars: Vec<_> = page
        .elements
        .iter()
        .filter(|e| matches!(e.kind, ElementType::RECT) && e.fill == BLUE)
        .collect();

    // 4 categories each with 1 red bar and 1 blue bar (plus legend swatches)
    assert_eq!(
        red_bars.len(),
        5,
        "Expected 4 data bars + 1 legend swatch for RED"
    );
    assert_eq!(
        blue_bars.len(),
        5,
        "Expected 4 data bars + 1 legend swatch for BLUE"
    );

    // All categories present
    let labels = texts(page);
    for cat in ["Q1", "Q2", "Q3", "Q4", "Alpha", "Beta"] {
        assert!(labels.contains(&cat.to_owned()), "Missing label {cat}");
    }

    Ok(())
}

#[test]
fn column_chart_renders_negative_values_from_zero_baseline() -> TestResult {
    let negative_values = r#"<c:val><c:numLit><c:formatCode>General</c:formatCode><c:ptCount val="2"/>
<c:pt idx="0"><c:v>-15</c:v></c:pt>
<c:pt idx="1"><c:v>25</c:v></c:pt></c:numLit></c:val>"#;
    let single_series = format!(
        r#"<c:barChart><c:barDir val="col"/><c:grouping val="clustered"/>{}<c:axId val="100"/><c:axId val="200"/></c:barChart>"#,
        fixture::series(
            (0, "Delta", "C03050"),
            r#"<c:cat><c:strLit><c:ptCount val="2"/><c:pt idx="0"><c:v>Down</c:v></c:pt><c:pt idx="1"><c:v>Up</c:v></c:pt></c:strLit></c:cat>"#,
            negative_values
        )
    );
    let chart_xml = fixture::category_chart()
        .replace(
            "<c:lineChart><c:grouping val=\"standard\"/>",
            &single_series,
        )
        .replace("</c:lineChart>", "");

    let document = document(&chart_xml)?;
    let page = &document.pages[0];

    let bars: Vec<_> = page
        .elements
        .iter()
        .filter(|e| matches!(e.kind, ElementType::RECT) && e.fill == RED)
        .collect();
    // 2 data bars + 1 legend swatch = 3
    assert_eq!(bars.len(), 3, "Expected 2 data bars + 1 legend swatch");

    let down_bar = bars
        .iter()
        .find(|b| b.width > 12.0 && b.x < 300.0)
        .ok_or("Missing down bar")?;
    let up_bar = bars
        .iter()
        .find(|b| b.width > 12.0 && b.x > 300.0)
        .ok_or("Missing up bar")?;

    // Negative bar starts at zero baseline and goes down (so its top is baseline)
    // Positive bar starts below and reaches zero baseline at its bottom (so its bottom is baseline)
    checks::near(down_bar.y, up_bar.y + up_bar.height);
    assert!(down_bar.height > 0.0);
    assert!(up_bar.height > 0.0);

    Ok(())
}

fn document(chart: &str) -> TestResult<Document> {
    let mut parts = fixture::parts();
    replace(&mut parts, FIRST_CHART, chart);
    replace(
        &mut parts,
        "ppt/slides/slide1.xml",
        r#"<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree/></p:cSld></p:sld>"#,
    );
    Ok(parse_reader(Cursor::new(archive(&parts)?))?)
}

fn assert_omitted(chart: &str) -> TestResult {
    let document = document(chart)?;
    assert!(
        document.pages[0].elements.iter().all(|element| {
            !matches!(element.kind, ElementType::LINE) || ![RED, BLUE].contains(&element.stroke)
        }),
        "Rejected chart emitted series lines"
    );
    assert!(
        document
            .warnings
            .iter()
            .any(|warning| warning.to_lowercase().contains("chart")),
        "Missing chart warning: {:?}",
        document.warnings
    );
    Ok(())
}

fn texts(page: &Page) -> Vec<String> {
    page.elements
        .iter()
        .filter(|element| matches!(element.kind, ElementType::TEXT))
        .map(|element| checks::text(&element.paragraphs))
        .collect()
}
