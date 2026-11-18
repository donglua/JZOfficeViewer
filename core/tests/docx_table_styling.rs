pub mod support;

use jz_office_core::{
    model::{CellBorder, Document},
    parse_reader,
};
use std::io::Cursor;
use support::{
    docx,
    package::{archive, relationships, xml, Parts, TestResult},
};

/// 把 body 片段包装成完整的 document.xml（带 sectPr，模拟真实 Word 文档）
fn document_xml(body: &str) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>{body}
    <w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr>
  </w:body>
</w:document>"#
    )
}

/// 直接遍历替换部件内容。
///
/// `support::package::replace` 带 `#[cfg(test)]`，集成测试作为独立 crate 不满足该条件，
/// 因此这里与计划 Step 1 一样直接改写字节。
fn replace_part(parts: &mut Parts, name: &str, text: &str) {
    for (path, bytes) in parts.iter_mut() {
        if *path == name {
            *bytes = text.as_bytes().to_vec();
        }
    }
}

/// 基于 docx::parts() 解析给定 body，可选替换 styles.xml 与附加 theme 部件
fn parse_docx(body: &str, styles: Option<&str>, theme: Option<&str>) -> TestResult<Document> {
    let mut parts = docx::parts();
    if let Some(theme) = theme {
        // 追加主题部件，并让 document.xml 通过关系指向它
        parts.push(xml("word/theme/theme1.xml", theme));
        replace_part(
            &mut parts,
            "word/_rels/document.xml.rels",
            &relationships(&[
                ("rStyles", "styles", "styles.xml"),
                ("rImage", "image", "media/../media/pixel.png"),
                ("rHeader", "header", "header1.xml"),
                ("rFooter", "footer", "footer1.xml"),
                ("rTheme", "theme", "theme/theme1.xml"),
            ]),
        );
    }
    if let Some(styles) = styles {
        replace_part(&mut parts, "word/styles.xml", styles);
    }
    replace_part(&mut parts, "word/document.xml", &document_xml(body));
    Ok(parse_reader(Cursor::new(archive(&parts)?))?)
}

/// 取第一个表格块
fn first_table(document: &Document) -> TestResult<&jz_office_core::model::Element> {
    document
        .blocks
        .first()
        .ok_or_else(|| std::io::Error::other("缺少表格块").into())
}

/// 按 OOXML 语义把主题色向白色插值（tint），`"80"` 约为 50%
fn tint_color(base: u32, tint: &str) -> u32 {
    let factor = |value: &str| -> f32 {
        u32::from_str_radix(value, 16)
            .map(|value| value as f32 / 255.0)
            .unwrap_or(0.0)
    };
    let percent = factor(tint);
    let channel = |shift: u32| {
        let current = f32::from(u8::try_from((base >> shift) & 0xff).unwrap_or(u8::MAX));
        (current + (255.0 - current) * percent).round() as u32
    };
    (base & 0xff00_0000) | (channel(16) << 16) | (channel(8) << 8) | channel(0)
}

/// 按 OOXML 语义把主题色按比例压暗（shade），`"80"` 约为 50%
fn shade_color(base: u32, shade: &str) -> u32 {
    let percent = u32::from_str_radix(shade, 16)
        .map(|value| value as f32 / 255.0)
        .unwrap_or(0.0);
    let channel = |shift: u32| {
        let current = f32::from(u8::try_from((base >> shift) & 0xff).unwrap_or(u8::MAX));
        (current * percent).round() as u32
    };
    (base & 0xff00_0000) | (channel(16) << 16) | (channel(8) << 8) | channel(0)
}

/// 每个矩阵的行列维度必须与 rows 严格一致，平台解码器按此校验
fn assert_matrix_shape(element: &jz_office_core::model::Element) {
    let cols = element.column_widths.len();
    for row in &element.cell_fills {
        assert_eq!(row.len(), cols, "cellFills 列数与 columnWidths 不一致");
    }
    for row in &element.cell_valigns {
        assert_eq!(row.len(), cols, "cellValigns 列数与 columnWidths 不一致");
    }
    for row in &element.cell_borders {
        assert_eq!(row.len(), cols, "cellBorders 列数与 columnWidths 不一致");
    }
}

#[test]
fn docx_table_parses_cell_shd_valign_and_three_line_borders() -> TestResult {
    let mut parts = docx::parts();
    for (path, bytes) in &mut parts {
        if *path == "word/document.xml" {
            let xml = r#"<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:tbl>
      <w:tblPr>
        <w:tblBorders>
          <w:top w:val="single" w:sz="12" w:color="112233"/>
          <w:bottom w:val="single" w:sz="12" w:color="112233"/>
          <w:left w:val="none"/>
          <w:right w:val="none"/>
          <w:insideH w:val="none"/>
          <w:insideV w:val="none"/>
        </w:tblBorders>
      </w:tblPr>
      <w:tblGrid>
        <w:gridCol w:w="2400"/>
        <w:gridCol w:w="2400"/>
      </w:tblGrid>
      <w:tr>
        <w:tc>
          <w:tcPr>
            <w:shd w:val="clear" w:fill="DAE8FC"/>
            <w:vAlign w:val="center"/>
            <w:tcBorders>
              <w:bottom w:val="single" w:sz="6" w:color="445566"/>
            </w:tcBorders>
          </w:tcPr>
          <w:p><w:r><w:t>Header A</w:t></w:r></w:p>
        </w:tc>
        <w:tc>
          <w:tcPr>
            <w:shd w:val="clear" w:fill="DAE8FC"/>
            <w:vAlign w:val="bottom"/>
            <w:tcBorders>
              <w:bottom w:val="single" w:sz="6" w:color="445566"/>
            </w:tcBorders>
          </w:tcPr>
          <w:p><w:r><w:t>Header B</w:t></w:r></w:p>
        </w:tc>
      </w:tr>
      <w:tr>
        <w:tc>
          <w:p><w:r><w:t>Cell A2</w:t></w:r></w:p>
        </w:tc>
        <w:tc>
          <w:p><w:r><w:t>Cell B2</w:t></w:r></w:p>
        </w:tc>
      </w:tr>
    </w:tbl>
  </w:body>
</w:document>"#;
            *bytes = xml.as_bytes().to_vec();
        }
    }
    let doc = parse_reader(Cursor::new(archive(&parts)?))?;
    let table = &doc.blocks[0];
    assert_eq!(
        table.cell_fills,
        vec![vec![0xFFDAE8FC, 0xFFDAE8FC], vec![0, 0]]
    );
    assert_eq!(table.cell_valigns, vec![vec![1, 2], vec![0, 0]]);
    assert_eq!(table.cell_borders.len(), 2);
    // 首行左单元格：top=1.5pt #112233, right=none, bottom=0.75pt #445566, left=none
    assert_eq!(
        table.cell_borders[0][0],
        [
            CellBorder {
                color: 0xFF112233,
                width: 1.5
            },
            CellBorder {
                color: 0,
                width: 0.0
            },
            CellBorder {
                color: 0xFF445566,
                width: 0.75
            },
            CellBorder {
                color: 0,
                width: 0.0
            },
        ]
    );
    // 末行左单元格：top=none, right=none, bottom=1.5pt #112233, left=none
    assert_eq!(
        table.cell_borders[1][0],
        [
            CellBorder {
                color: 0,
                width: 0.0
            },
            CellBorder {
                color: 0,
                width: 0.0
            },
            CellBorder {
                color: 0xFF112233,
                width: 1.5
            },
            CellBorder {
                color: 0,
                width: 0.0
            },
        ]
    );
    assert_matrix_shape(table);
    Ok(())
}

#[test]
fn docx_table_cell_shad_theme_fill_derives_tint_and_shade() -> TestResult {
    // 主题色 accent1 = 2A9D8F，dk1 = 000000，lt1 = FFFFFF
    let theme = r#"<?xml version="1.0" encoding="UTF-8"?>
<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Fixture theme">
  <a:themeElements>
    <a:clrScheme name="Fixture colors">
      <a:dk1><a:srgbClr val="000000"/></a:dk1>
      <a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>
      <a:dk2><a:srgbClr val="112233"/></a:dk2>
      <a:lt2><a:srgbClr val="F4F7FA"/></a:lt2>
      <a:accent1><a:srgbClr val="2A9D8F"/></a:accent1>
      <a:accent2><a:srgbClr val="E9C46A"/></a:accent2>
    </a:clrScheme>
  </a:themeElements>
</a:theme>"#;
    // 四个单元格分别验证：纯主题色、主题色 + tint、主题色 + shade、tx/bg 别名
    let body = r#"<w:tbl>
  <w:tblGrid><w:gridCol w:w="2000"/><w:gridCol w:w="2000"/><w:gridCol w:w="2000"/><w:gridCol w:w="2000"/></w:tblGrid>
  <w:tr>
    <w:tc><w:tcPr><w:shd w:val="clear" w:themeFill="accent1"/></w:tcPr><w:p/></w:tc>
    <w:tc><w:tcPr><w:shd w:val="clear" w:themeFill="accent1" w:themeFillTint="80"/></w:tcPr><w:p/></w:tc>
    <w:tc><w:tcPr><w:shd w:val="clear" w:themeFill="accent1" w:themeFillShade="80"/></w:tcPr><w:p/></w:tc>
    <w:tc><w:tcPr><w:shd w:val="clear" w:themeFill="bg1"/></w:tcPr><w:p/></w:tc>
  </w:tr>
</w:tbl>"#;
    let doc = parse_docx(body, None, Some(theme))?;
    let table = first_table(&doc)?;
    let base: u32 = 0xFF2A9D8F;
    let tinted = tint_color(base, "80");
    let shaded = shade_color(base, "80");
    assert_eq!(
        table.cell_fills,
        vec![vec![base, tinted, shaded, 0xFFFFFFFF]]
    );
    // tint 应变亮、shade 应变暗，否则说明方向搞反了
    assert_ne!(tinted, base);
    assert_ne!(shaded, base);
    for shift in [16, 8, 0] {
        assert!(
            (tinted >> shift) & 0xff > (base >> shift) & 0xff,
            "tint 应提亮"
        );
        assert!(
            (shaded >> shift) & 0xff < (base >> shift) & 0xff,
            "shade 应压暗"
        );
    }
    Ok(())
}

#[test]
fn docx_table_style_first_row_shading_follows_tbl_look() -> TestResult {
    let styles = r#"<?xml version="1.0" encoding="UTF-8"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val="22"/></w:rPr></w:rPrDefault></w:docDefaults>
  <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
  <w:style w:type="table" w:styleId="BaseTable">
    <w:name w:val="Base Table"/>
    <w:tcPr><w:shd w:val="clear" w:fill="EEEEEE"/></w:tcPr>
  </w:style>
  <w:style w:type="table" w:styleId="HeaderTable">
    <w:name w:val="Header Table"/><w:basedOn w:val="BaseTable"/>
    <w:tcPr><w:shd w:val="clear" w:fill="EEEEEE"/></w:tcPr>
    <w:tblStylePr w:type="firstRow"><w:tcPr><w:shd w:val="clear" w:fill="336699"/></w:tcPr></w:tblStylePr>
  </w:style>
</w:styles>"#;
    let body = |look: &str| {
        format!(
            r#"<w:tbl>
  <w:tblPr><w:tblStyle w:val="HeaderTable"/>{look}</w:tblPr>
  <w:tblGrid><w:gridCol w:w="2000"/><w:gridCol w:w="2000"/></w:tblGrid>
  <w:tr><w:tc><w:p/></w:tc><w:tc><w:p/></w:tc></w:tr>
  <w:tr><w:tc><w:p/></w:tc><w:tc><w:p/></w:tc></w:tr>
</w:tbl>"#
        )
    };

    // 未声明 tblLook 时默认启用 firstRow：首行用条件样式底纹，次行用样式默认底纹
    let doc = parse_docx(&body(""), Some(styles), None)?;
    let table = first_table(&doc)?;
    assert_eq!(
        table.cell_fills,
        vec![vec![0xFF336699, 0xFF336699], vec![0xFFEEEEEE, 0xFFEEEEEE]]
    );

    // tblLook 位掩码全 0 关闭 firstRow：两行都退回样式默认底纹
    let disabled = parse_docx(&body(r#"<w:tblLook w:val="0000"/>"#), Some(styles), None)?;
    let table = first_table(&disabled)?;
    assert_eq!(
        table.cell_fills,
        vec![vec![0xFFEEEEEE, 0xFFEEEEEE], vec![0xFFEEEEEE, 0xFFEEEEEE]]
    );
    Ok(())
}

#[test]
fn docx_table_cell_valign_maps_all_three_states() -> TestResult {
    let body = r#"<w:tbl>
  <w:tblGrid><w:gridCol w:w="1000"/><w:gridCol w:w="1000"/><w:gridCol w:w="1000"/><w:gridCol w:w="1000"/></w:tblGrid>
  <w:tr>
    <w:tc><w:tcPr><w:vAlign w:val="top"/></w:tcPr><w:p/></w:tc>
    <w:tc><w:tcPr><w:vAlign w:val="center"/></w:tcPr><w:p/></w:tc>
    <w:tc><w:tcPr><w:vAlign w:val="both"/></w:tcPr><w:p/></w:tc>
    <w:tc><w:tcPr><w:vAlign w:val="bottom"/></w:tcPr><w:p/></w:tc>
  </w:tr>
</w:tbl>"#;
    let doc = parse_docx(body, None, None)?;
    let table = first_table(&doc)?;
    // top → 0、center/both → 1、bottom → 2
    assert_eq!(table.cell_valigns, vec![vec![0, 1, 1, 2]]);
    // 存在非默认对齐时才会输出矩阵
    assert_eq!(table.cell_valigns.len(), 1);
    Ok(())
}

#[test]
fn docx_three_line_table_hides_vertical_and_inner_horizontal_edges() -> TestResult {
    let body = r#"<w:tbl>
  <w:tblPr>
    <w:tblBorders>
      <w:top w:val="single" w:sz="16" w:color="000000"/>
      <w:left w:val="none"/>
      <w:bottom w:val="single" w:sz="16" w:color="000000"/>
      <w:right w:val="none"/>
      <w:insideH w:val="none"/>
      <w:insideV w:val="none"/>
    </w:tblBorders>
  </w:tblPr>
  <w:tblGrid><w:gridCol w:w="2000"/><w:gridCol w:w="2000"/></w:tblGrid>
  <w:tr><w:tc><w:p/></w:tc><w:tc><w:p/></w:tc></w:tr>
  <w:tr><w:tc><w:p/></w:tc><w:tc><w:p/></w:tc></w:tr>
</w:tbl>"#;
    let doc = parse_docx(body, None, None)?;
    let table = first_table(&doc)?;
    // 存在消隐边 → 必须输出矩阵，平台层据此不再画默认灰框
    assert_eq!(table.cell_borders.len(), 2);
    for (row, cells) in table.cell_borders.iter().enumerate() {
        for (col, edges) in cells.iter().enumerate() {
            let [top, right, bottom, left] = *edges;
            // 左右竖线与内部横线全部消隐
            assert_eq!(right.color, 0, "({row},{col}) right 应消隐");
            assert_eq!(right.width, 0.0, "({row},{col}) right 应消隐");
            assert_eq!(left.color, 0, "({row},{col}) left 应消隐");
            assert_eq!(left.width, 0.0, "({row},{col}) left 应消隐");
            // 仅表格最顶与最底保留 2pt 黑线
            let expected_top = if row == 0 { 2.0 } else { 0.0 };
            let expected_bottom = if row + 1 == table.cell_borders.len() {
                2.0
            } else {
                0.0
            };
            assert_eq!(top.width, expected_top, "({row},{col}) top 线宽");
            assert_eq!(bottom.width, expected_bottom, "({row},{col}) bottom 线宽");
            if expected_top > 0.0 {
                assert_eq!(top.color, 0xFF000000);
            }
        }
    }
    assert_matrix_shape(table);
    Ok(())
}

#[test]
fn docx_merged_cell_borders_collapse_to_anchor_edges() -> TestResult {
    // 跨列合并：锚点 right 应取区域最右列（表格外框右边），而不是内部竖线
    let horizontal = r#"<w:tbl>
  <w:tblPr>
    <w:tblBorders>
      <w:top w:val="single" w:sz="4" w:color="111111"/>
      <w:left w:val="none"/>
      <w:bottom w:val="single" w:sz="4" w:color="222222"/>
      <w:right w:val="single" w:sz="24" w:color="444444"/>
      <w:insideH w:val="none"/>
      <w:insideV w:val="none"/>
    </w:tblBorders>
  </w:tblPr>
  <w:tblGrid><w:gridCol w:w="2000"/><w:gridCol w:w="2000"/></w:tblGrid>
  <w:tr><w:tc><w:tcPr><w:gridSpan w:val="2"/></w:tcPr><w:p/></w:tc></w:tr>
</w:tbl>"#;
    let doc = parse_docx(horizontal, None, None)?;
    let table = first_table(&doc)?;
    assert_eq!(table.cell_borders.len(), 1);
    let [top, right, bottom, left] = table.cell_borders[0][0];
    // 合并前锚点 right 来自 insideV（none → 0），合并后应取区域最右列的外框边
    assert_eq!(
        right,
        CellBorder {
            color: 0xFF444444,
            width: 3.0
        }
    );
    assert_eq!(top.color, 0xFF111111);
    assert_eq!(bottom.color, 0xFF222222);
    assert_eq!(left.color, 0);
    assert!(table
        .merges
        .iter()
        .any(|m| m.start_row == 0 && m.end_row == 0 && m.start_column == 0 && m.end_column == 1));

    // 跨行合并：锚点 bottom 应取区域最末行（表格外框底边），而不是内部横线
    let vertical = r#"<w:tbl>
  <w:tblPr>
    <w:tblBorders>
      <w:top w:val="single" w:sz="4" w:color="111111"/>
      <w:left w:val="none"/>
      <w:bottom w:val="single" w:sz="24" w:color="222222"/>
      <w:right w:val="none"/>
      <w:insideH w:val="single" w:sz="8" w:color="555555"/>
      <w:insideV w:val="none"/>
    </w:tblBorders>
  </w:tblPr>
  <w:tblGrid><w:gridCol w:w="2000"/></w:tblGrid>
  <w:tr><w:tc><w:tcPr><w:vMerge w:val="restart"/></w:tcPr><w:p/></w:tc></w:tr>
  <w:tr><w:tc><w:tcPr><w:vMerge/></w:tcPr><w:p/></w:tc></w:tr>
</w:tbl>"#;
    let doc = parse_docx(vertical, None, None)?;
    let table = first_table(&doc)?;
    assert_eq!(table.cell_borders.len(), 2);
    // 合并前锚点 bottom 来自 insideH（1pt #555555），合并后应取末行的表格底边
    assert_eq!(
        table.cell_borders[0][0][2],
        CellBorder {
            color: 0xFF222222,
            width: 3.0
        }
    );
    assert!(table
        .merges
        .iter()
        .any(|m| m.start_row == 0 && m.end_row == 1 && m.start_column == 0 && m.end_column == 0));
    Ok(())
}

#[test]
fn docx_empty_table_omits_all_cell_style_matrices() -> TestResult {
    // 没有任何行：三个矩阵都必须为空（0 列行在 DOCX 中会被补齐到至少 1 列，
    // 与空表格共用同一条 rows == 0 || cols == 0 保护）
    let body = r#"<w:tbl>
  <w:tblPr><w:tblBorders><w:insideV w:val="none"/></w:tblBorders></w:tblPr>
  <w:tblGrid><w:gridCol w:w="2000"/></w:tblGrid>
</w:tbl>"#;
    let doc = parse_docx(body, None, None)?;
    let table = first_table(&doc)?;
    assert!(table.rows.is_empty());
    assert!(table.cell_fills.is_empty());
    assert!(table.cell_valigns.is_empty());
    assert!(table.cell_borders.is_empty());
    Ok(())
}

#[test]
fn uniform_table_keeps_cell_style_fields_out_of_json() -> TestResult {
    // 全表均匀网格框且无底纹/无显式对齐：三个字段都不序列化，普通表格 JSON 零变化
    let body = r#"<w:tbl>
  <w:tblPr>
    <w:tblBorders>
      <w:top w:val="single" w:sz="4" w:color="999999"/>
      <w:left w:val="single" w:sz="4" w:color="999999"/>
      <w:bottom w:val="single" w:sz="4" w:color="999999"/>
      <w:right w:val="single" w:sz="4" w:color="999999"/>
      <w:insideH w:val="single" w:sz="4" w:color="999999"/>
      <w:insideV w:val="single" w:sz="4" w:color="999999"/>
    </w:tblBorders>
  </w:tblPr>
  <w:tblGrid><w:gridCol w:w="2000"/><w:gridCol w:w="2000"/></w:tblGrid>
  <w:tr><w:tc><w:p/></w:tc><w:tc><w:p/></w:tc></w:tr>
  <w:tr><w:tc><w:p/></w:tc><w:tc><w:p/></w:tc></w:tr>
</w:tbl>"#;
    let doc = parse_docx(body, None, None)?;
    let table = first_table(&doc)?;
    assert!(table.cell_fills.is_empty());
    assert!(table.cell_valigns.is_empty());
    assert!(table.cell_borders.is_empty());
    let json = serde_json::to_value(table)?;
    assert!(
        json.get("cellFills").is_none(),
        "均匀表格不应输出 cellFills"
    );
    assert!(
        json.get("cellValigns").is_none(),
        "无显式对齐不应输出 cellValigns"
    );
    assert!(
        json.get("cellBorders").is_none(),
        "均匀网格框不应输出 cellBorders"
    );
    Ok(())
}

#[test]
fn docx_table_without_any_border_declaration_keeps_grid_fallback() -> TestResult {
    // 最常见的普通表格：完全没有 tblBorders 声明。
    // 必须不输出 cellBorders，否则三端会走逐边绘制分支而完全不画框，
    // 丢失既有的灰色网格兜底（视觉回归 + 破坏"普通表格 JSON 零变化"约束）。
    let body = r#"<w:tbl>
  <w:tblGrid><w:gridCol w:w="2000"/><w:gridCol w:w="2000"/></w:tblGrid>
  <w:tr><w:tc><w:p/></w:tc><w:tc><w:p/></w:tc></w:tr>
</w:tbl>"#;
    let doc = parse_docx(body, None, None)?;
    let table = first_table(&doc)?;
    assert!(
        table.cell_borders.is_empty(),
        "无边框声明的表格不应输出 cellBorders"
    );
    // 平台层依靠这两个字段画兜底网格
    assert_eq!(table.stroke, 0xFFDADCE0);
    assert_eq!(table.stroke_width, 1.0);
    let json = serde_json::to_value(table)?;
    assert!(json.get("cellBorders").is_none());
    Ok(())
}

#[test]
fn docx_table_style_derived_shading_overrides_based_on_ancestor() -> TestResult {
    // 派生样式声明 shd=111111，basedOn 祖先声明 shd=EEEEEE；子样式应优先
    let styles = r#"<?xml version="1.0" encoding="UTF-8"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="table" w:styleId="Ancestor"><w:name w:val="A"/>
    <w:tcPr><w:shd w:val="clear" w:fill="EEEEEE"/></w:tcPr></w:style>
  <w:style w:type="table" w:styleId="Derived"><w:name w:val="D"/><w:basedOn w:val="Ancestor"/>
    <w:tcPr><w:shd w:val="clear" w:fill="111111"/></w:tcPr></w:style>
</w:styles>"#;
    let body = r#"<w:tbl>
  <w:tblPr><w:tblStyle w:val="Derived"/><w:tblLook w:val="0000"/></w:tblPr>
  <w:tblGrid><w:gridCol w:w="2000"/></w:tblGrid>
  <w:tr><w:tc><w:p/></w:tc></w:tr>
</w:tbl>"#;
    let doc = parse_docx(body, Some(styles), None)?;
    let table = first_table(&doc)?;
    // 子样式覆盖基于 basedOn 的祖先，而不是反过来
    assert_eq!(table.cell_fills[0][0], 0xFF111111);
    Ok(())
}

#[test]
fn docx_table_style_tbl_pr_borders_drive_uniform_grid() -> TestResult {
    // 表格样式的 tblPr/tblBorders 是 Word 最常见的存边框位置
    let styles = r#"<?xml version="1.0" encoding="UTF-8"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="table" w:styleId="Grid"><w:name w:val="Grid"/>
    <w:tblPr><w:tblBorders>
      <w:top w:val="single" w:sz="8" w:color="AA0000"/>
      <w:left w:val="single" w:sz="8" w:color="AA0000"/>
      <w:bottom w:val="single" w:sz="8" w:color="AA0000"/>
      <w:right w:val="single" w:sz="8" w:color="AA0000"/>
      <w:insideH w:val="single" w:sz="8" w:color="AA0000"/>
      <w:insideV w:val="single" w:sz="8" w:color="AA0000"/>
    </w:tblBorders></w:tblPr>
  </w:style>
</w:styles>"#;
    let body = r#"<w:tbl>
  <w:tblPr><w:tblStyle w:val="Grid"/></w:tblPr>
  <w:tblGrid><w:gridCol w:w="2000"/><w:gridCol w:w="2000"/></w:tblGrid>
  <w:tr><w:tc><w:p/></w:tc><w:tc><w:p/></w:tc></w:tr>
</w:tbl>"#;
    let doc = parse_docx(body, Some(styles), None)?;
    let table = first_table(&doc)?;
    // 六边一致属于均匀网格框，由表格级 stroke 承担统一绘制，不输出 cell_borders
    assert!(
        table.cell_borders.is_empty(),
        "均匀样式的网格框不应输出 cell_borders"
    );
    assert_eq!(table.stroke, 0xFFAA0000);
    assert_eq!(table.stroke_width, 1.0);
    Ok(())
}

// ---------------------------------------------------------------------------
// PPTX：<a:tcPr anchor="t|ctr|b"> 垂直对齐
// ---------------------------------------------------------------------------

/// 用指定的 tcPr 属性片段构造单行三列 PPTX 表格并输出元素 JSON
fn pptx_table_json(properties: &[&str]) -> TestResult<serde_json::Value> {
    let mut parts = support::pptx::parts();
    let cells: String = properties
        .iter()
        .map(|attributes| {
            format!(
                r#"<a:tc><a:txBody><a:bodyPr/><a:p><a:r><a:t>Cell</a:t></a:r></a:p></a:txBody><a:tcPr {attributes}/></a:tc>"#
            )
        })
        .collect();
    support::package::replace(
        &mut parts,
        "ppt/slides/slide2.xml",
        &format!(
            r#"<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
<p:cSld><p:spTree><p:graphicFrame><p:xfrm><a:off x="0" y="0"/><a:ext cx="9144000" cy="2528580"/></p:xfrm>
<a:graphic><a:graphicData><a:tbl><a:tblPr/><a:tblGrid><a:gridCol w="3048000"/><a:gridCol w="3048000"/><a:gridCol w="3048000"/></a:tblGrid><a:tr h="421430">{cells}</a:tr></a:tbl></a:graphicData></a:graphic>
</p:graphicFrame></p:spTree></p:cSld></p:sld>"#
        ),
    );
    let doc = parse_reader(Cursor::new(archive(&parts)?))?;
    let table = doc.pages[0]
        .elements
        .iter()
        .find(|element| matches!(element.kind, jz_office_core::model::ElementType::TABLE))
        .ok_or("PPTX table element missing")?;
    Ok(serde_json::to_value(table)?)
}

#[test]
fn pptx_table_cell_anchor_maps_to_cell_valigns() -> TestResult {
    let json = pptx_table_json(&[r#"anchor="t""#, r#"anchor="ctr""#, r#"anchor="b""#])?;
    // t -> 0 顶部、ctr -> 1 居中、b -> 2 底部
    assert_eq!(json["cellValigns"], serde_json::json!([[0, 1, 2]]));
    Ok(())
}

#[test]
fn pptx_table_without_explicit_anchor_omits_cell_valigns() -> TestResult {
    let json = pptx_table_json(&["", "", ""])?;
    assert!(
        json.get("cellValigns").is_none(),
        "没有显式 anchor 时不应输出 cellValigns，平台层沿用垂直居中"
    );
    Ok(())
}

#[test]
fn docx_merged_anchor_own_border_wins_over_implicit_edge() -> TestResult {
    // 跨列合并单元格自身声明 tcBorders.right = 24/8pt #ABCDEF
    let body = r#"<w:tbl>
  <w:tblPr><w:tblBorders>
    <w:top w:val="single" w:sz="4" w:color="111111"/>
    <w:left w:val="single" w:sz="4" w:color="111111"/>
    <w:bottom w:val="single" w:sz="4" w:color="111111"/>
    <w:right w:val="single" w:sz="4" w:color="111111"/>
    <w:insideH w:val="single" w:sz="4" w:color="111111"/>
    <w:insideV w:val="single" w:sz="4" w:color="111111"/>
  </w:tblBorders></w:tblPr>
  <w:tblGrid><w:gridCol w:w="2000"/><w:gridCol w:w="2000"/></w:tblGrid>
  <w:tr><w:tc><w:tcPr><w:gridSpan w:val="2"/>
    <w:tcBorders><w:right w:val="single" w:sz="24" w:color="ABCDEF"/></w:tcBorders>
  </w:tcPr><w:p/></w:tc></w:tr>
</w:tbl>"#;
    let doc = parse_docx(body, None, None)?;
    let table = first_table(&doc)?;
    // 锚点自身声明的 tcBorders.right 描述整个合并区域的外边，
    // 必须优先于归并推得的隐式边
    let right = table.cell_borders[0][0][1];
    assert_eq!(right.color, 0xFFABCDEF);
    assert_eq!(right.width, 3.0);
    Ok(())
}

#[test]
fn docx_cell_explicit_clear_shading_overrides_inherited_style() -> TestResult {
    let styles = r#"<?xml version="1.0" encoding="UTF-8"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="table" w:styleId="ShadedTable">
    <w:name w:val="Shaded Table"/>
    <w:tcPr><w:shd w:val="clear" w:fill="EEEEEE"/></w:tcPr>
    <w:tblStylePr w:type="firstRow">
      <w:tcPr>
        <w:shd w:val="clear" w:fill="336699"/>
        <w:tcBorders><w:bottom w:val="single" w:sz="12" w:color="112233"/></w:tcBorders>
      </w:tcPr>
    </w:tblStylePr>
  </w:style>
</w:styles>"#;
    let body = r#"<w:tbl>
  <w:tblPr><w:tblStyle w:val="ShadedTable"/></w:tblPr>
  <w:tblGrid><w:gridCol w:w="2000"/><w:gridCol w:w="2000"/></w:tblGrid>
  <w:tr>
    <w:tc><w:p/></w:tc>
    <w:tc><w:tcPr><w:shd w:val="clear" w:fill="auto"/></w:tcPr><w:p/></w:tc>
  </w:tr>
  <w:tr>
    <w:tc><w:p/></w:tc>
    <w:tc><w:tcPr><w:shd w:val="nil"/></w:tcPr><w:p/></w:tc>
  </w:tr>
</w:tbl>"#;
    let doc = parse_docx(body, Some(styles), None)?;
    let table = first_table(&doc)?;
    assert_eq!(
        table.cell_fills,
        vec![vec![0xFF336699, 0], vec![0xFFEEEEEE, 0]]
    );
    // 即便未声明 tblBorders，firstRow 的 tcBorders 也必须触发 cell_borders 输出
    assert_eq!(table.cell_borders.len(), 2);
    assert_eq!(
        table.cell_borders[0][0][2],
        CellBorder {
            color: 0xFF112233,
            width: 1.5
        }
    );
    Ok(())
}
