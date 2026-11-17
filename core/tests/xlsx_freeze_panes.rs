pub mod support;

use jz_office_core::{model::Document, parse_reader, Error};
use serde_json::Value;
use std::io::Cursor;
use support::{
    package::{archive, replace, TestResult},
    xlsx,
};

/// 生成 3 行 3 列的工作表，`views` 为插在 sheetData 之前的 `<sheetViews>` 片段
const DATA: &str = r#"<sheetData><row r="1"><c r="A1"><v>1</v></c><c r="B1"><v>2</v></c><c r="C1"><v>3</v></c></row><row r="2"><c r="A2"><v>4</v></c><c r="B2"><v>5</v></c><c r="C2"><v>6</v></c></row><row r="3"><c r="A3"><v>7</v></c><c r="B3"><v>8</v></c><c r="C3"><v>9</v></c></row></sheetData>"#;

/// 把 `<sheetViews>` 片段与 3x3 数据包装成完整工作簿字节
fn workbook(views: &str) -> TestResult<Vec<u8>> {
    let mut parts = xlsx::parts();
    replace(
        &mut parts,
        "xl/worksheets/sheet2.xml",
        &xlsx::sheet(&format!("{views}{DATA}")),
    );
    archive(&parts)
}

fn parse(views: &str) -> TestResult<Document> {
    Ok(parse_reader(Cursor::new(workbook(views)?))?)
}

/// 只关心首个工作表（Overview，映射到 sheet2.xml）的冻结列数与行数
fn freeze(views: &str) -> TestResult<(u32, u32)> {
    let document = parse(views)?;
    let sheet = document.sheets.first().ok_or("Missing worksheet")?;
    Ok((sheet.frozen_rows, sheet.frozen_columns))
}

fn has_warning(views: &str, fragment: &str) -> TestResult<bool> {
    let document = parse(views)?;
    Ok(document.warnings.iter().any(|w| w.contains(fragment)))
}

fn sheet_json(views: &str) -> TestResult<Value> {
    let document = parse(views)?;
    let sheet = document.sheets.first().ok_or("Missing worksheet")?;
    Ok(serde_json::to_value(sheet)?)
}

#[test]
fn frozen_rows_only() -> TestResult {
    let views = r#"<sheetViews><sheetView workbookViewId="0"><pane ySplit="2" topLeftCell="A3" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>"#;
    assert_eq!(freeze(views)?, (2, 0));
    Ok(())
}

#[test]
fn frozen_columns_only() -> TestResult {
    let views = r#"<sheetViews><sheetView workbookViewId="0"><pane xSplit="1" topLeftCell="B1" activePane="topRight" state="frozen"/></sheetView></sheetViews>"#;
    assert_eq!(freeze(views)?, (0, 1));
    Ok(())
}

#[test]
fn frozen_rows_and_columns_accept_integer_notation() -> TestResult {
    let views = r#"<sheetViews><sheetView workbookViewId="0"><pane xSplit="1" ySplit="2" topLeftCell="B3" activePane="bottomRight" state="frozen"/></sheetView></sheetViews>"#;
    assert_eq!(freeze(views)?, (2, 1));
    Ok(())
}

#[test]
fn frozen_splits_written_as_floats_are_accepted() -> TestResult {
    let views = r#"<sheetViews><sheetView workbookViewId="0"><pane xSplit="1.0" ySplit="2.0" topLeftCell="B3" activePane="bottomRight" state="frozen"/></sheetView></sheetViews>"#;
    assert_eq!(freeze(views)?, (2, 1));
    assert!(!has_warning(views, "Fractional")?);
    Ok(())
}

#[test]
fn frozen_split_state_is_honoured() -> TestResult {
    let views = r#"<sheetViews><sheetView workbookViewId="0"><pane xSplit="1" ySplit="1" state="frozenSplit"/></sheetView></sheetViews>"#;
    assert_eq!(freeze(views)?, (1, 1));
    assert!(!has_warning(views, "split panes")?);
    Ok(())
}

#[test]
fn empty_split_attributes_freeze_nothing() -> TestResult {
    let views = r#"<sheetViews><sheetView workbookViewId="0"><pane state="frozen"/></sheetView></sheetViews>"#;
    assert_eq!(freeze(views)?, (0, 0));
    assert!(!has_warning(views, "Fractional")?);
    Ok(())
}

#[test]
fn free_split_state_is_ignored_with_warning() -> TestResult {
    let views = r#"<sheetViews><sheetView workbookViewId="0"><pane xSplit="2000" ySplit="1000" topLeftCell="B3" activePane="bottomRight" state="split"/></sheetView></sheetViews>"#;
    assert_eq!(freeze(views)?, (0, 0));
    assert!(has_warning(
        views,
        "Non-frozen XLSX split panes are not supported"
    )?);
    Ok(())
}

#[test]
fn split_without_state_but_with_offsets_is_ignored_with_warning() -> TestResult {
    let views = r#"<sheetViews><sheetView workbookViewId="0"><pane xSplit="1" ySplit="1" topLeftCell="B2" activePane="bottomRight"/></sheetView></sheetViews>"#;
    assert_eq!(freeze(views)?, (0, 0));
    assert!(has_warning(
        views,
        "Non-frozen XLSX split panes are not supported"
    )?);
    Ok(())
}

#[test]
fn fractional_splits_are_truncated_with_warning() -> TestResult {
    let views = r#"<sheetViews><sheetView workbookViewId="0"><pane xSplit="1.5" ySplit="1.5" topLeftCell="B2" state="frozen"/></sheetView></sheetViews>"#;
    assert_eq!(freeze(views)?, (1, 1));
    assert!(has_warning(
        views,
        "Fractional XLSX frozen pane splits are truncated to whole rows or columns"
    )?);
    Ok(())
}

#[test]
fn scrolled_sheet_view_keeps_frozen_panes_and_warns() -> TestResult {
    let views = r#"<sheetViews><sheetView workbookViewId="0" topLeftCell="C4"><pane xSplit="1" ySplit="1" topLeftCell="B2" state="frozen"/></sheetView></sheetViews>"#;
    assert_eq!(freeze(views)?, (1, 1));
    let document = parse(views)?;
    // 只应出现一条与滚动位置相关的提示：<pane> 自身的 topLeftCell 不参与判定也不告警
    let scrolled = document
        .warnings
        .iter()
        .filter(|w| w.contains("scrolled away from A1"))
        .count();
    assert_eq!(scrolled, 1);
    // 小写 "a1" 视同从首格开始视图，不误报滚动告警
    let lowercase_origin = r#"<sheetViews><sheetView workbookViewId="0" topLeftCell="a1"><pane xSplit="1" ySplit="1" topLeftCell="B2" state="frozen"/></sheetView></sheetViews>"#;
    assert_eq!(freeze(lowercase_origin)?, (1, 1));
    assert!(!has_warning(lowercase_origin, "scrolled away from A1")?);
    Ok(())
}

#[test]
fn pane_top_left_cell_alone_does_not_warn() -> TestResult {
    let views = r#"<sheetViews><sheetView workbookViewId="0"><pane xSplit="1" topLeftCell="B1" activePane="topRight" state="frozen"/></sheetView></sheetViews>"#;
    assert_eq!(freeze(views)?, (0, 1));
    assert!(!has_warning(views, "scrolled away from A1")?);
    Ok(())
}

#[test]
fn invalid_split_values_are_rejected() -> TestResult {
    for value in ["-1", "-0.5", "abc", "nan", "NaN", "inf", "-inf", "Infinity"] {
        for attribute in ["xSplit", "ySplit"] {
            let views = format!(
                r#"<sheetViews><sheetView workbookViewId="0"><pane {attribute}="{value}" state="frozen"/></sheetView></sheetViews>"#
            );
            assert!(
                matches!(
                    parse_reader(Cursor::new(workbook(&views)?)),
                    Err(Error::Invalid("Invalid XLSX frozen pane split"))
                ),
                "{attribute}={value}"
            );
        }
    }
    Ok(())
}

#[test]
fn invalid_split_values_are_rejected_regardless_of_state() -> TestResult {
    // 损坏的数值不因 pane 状态不同而被放过
    for state in ["frozen", "frozenSplit", "split", ""] {
        let views = format!(
            r#"<sheetViews><sheetView workbookViewId="0"><pane xSplit="abc" state="{state}"/></sheetView></sheetViews>"#
        );
        assert!(
            matches!(
                parse_reader(Cursor::new(workbook(&views)?)),
                Err(Error::Invalid("Invalid XLSX frozen pane split"))
            ),
            "state={state}"
        );
    }
    Ok(())
}

#[test]
fn frozen_splits_are_clamped_to_sheet_extents() -> TestResult {
    // 工作表只有 3 行 3 列，9 行 9 列的冻结请求必须钳位到实际维度
    let views = r#"<sheetViews><sheetView workbookViewId="0"><pane xSplit="9" ySplit="9" state="frozen"/></sheetView></sheetViews>"#;
    assert_eq!(freeze(views)?, (3, 3));
    Ok(())
}

#[test]
fn unselected_sheet_views_are_skipped() -> TestResult {
    let views = r#"<sheetViews><sheetView workbookViewId="1"><pane ySplit="5" state="frozen"/></sheetView><sheetView workbookViewId="0"><pane ySplit="1" state="frozen"/></sheetView></sheetViews>"#;
    assert_eq!(freeze(views)?, (1, 0));
    // 全部 workbookViewId 都非 0 时回退到第一个 sheetView
    let views = r#"<sheetViews><sheetView workbookViewId="2"><pane ySplit="2" state="frozen"/></sheetView><sheetView workbookViewId="1"><pane ySplit="1" state="frozen"/></sheetView></sheetViews>"#;
    assert_eq!(freeze(views)?, (2, 0));
    // 未声明 workbookViewId 的 sheetView 视同 0
    let views =
        r#"<sheetViews><sheetView><pane ySplit="2" state="frozen"/></sheetView></sheetViews>"#;
    assert_eq!(freeze(views)?, (2, 0));
    Ok(())
}

#[test]
fn sheets_without_panes_freeze_nothing_and_omit_json_fields() -> TestResult {
    let json = sheet_json("")?;
    assert!(json.get("frozenRows").is_none());
    assert!(json.get("frozenColumns").is_none());
    // 无 <pane> 的 sheetViews 同样不写字段
    let json = sheet_json(r#"<sheetViews><sheetView workbookViewId="0"/></sheetViews>"#)?;
    assert!(json.get("frozenRows").is_none());
    assert!(json.get("frozenColumns").is_none());
    Ok(())
}

#[test]
fn frozen_panes_are_serialized_with_camel_case_keys() -> TestResult {
    let views = r#"<sheetViews><sheetView workbookViewId="0"><pane xSplit="1" ySplit="2" state="frozen"/></sheetView></sheetViews>"#;
    let json = sheet_json(views)?;
    assert_eq!(json["frozenRows"], 2);
    assert_eq!(json["frozenColumns"], 1);
    Ok(())
}
