use crate::model::VerticalAlignment;
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Sheet {
    pub name: String,
    pub row_heights: Vec<f32>,
    pub column_widths: Vec<f32>,
    pub cells: Vec<Cell>,
    pub merges: Vec<CellRange>,
    /// 预计算的几何布局数据，平台层直接使用，无需重复计算（schemaVersion 9 新增可选字段）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub geometry: Option<SheetGeometry>,
}

/// 预计算的工作表几何布局：行列偏移前缀和、可见索引、行起始索引、合并单元格标记与合并区域
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SheetGeometry {
    /// 列偏移前缀和，长度 = columnWidths.len() + 1，offsets[0] = 0
    pub column_offsets: Vec<f32>,
    /// 行偏移前缀和，长度 = rowHeights.len() + 1，offsets[0] = 0
    pub row_offsets: Vec<f32>,
    /// 宽度 > 0 的列索引
    pub column_visible: Vec<u32>,
    /// 高度 > 0 的行索引
    pub row_visible: Vec<u32>,
    /// 每行第一个 cell 在 cells 数组中的起始索引，长度 = rowHeights.len() + 1
    pub row_starts: Vec<u32>,
    /// 每个 cell 是否属于合并区域（非 anchor）
    pub merged_cells: Vec<bool>,
    /// 合并区域的屏幕坐标与 anchor cell 索引
    pub merge_rects: Vec<MergeRect>,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MergeRect {
    pub left: f32,
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
    /// anchor cell 在 cells 数组中的索引，无 anchor 时为 -1
    pub anchor: i32,
    /// 合并区域起始行（用于平台层分桶索引）
    pub start_row: u32,
    /// 合并区域结束行
    pub end_row: u32,
}

impl SheetGeometry {
    /// 为给定工作表计算几何布局
    pub fn compute(sheet: &Sheet) -> Self {
        let column_offsets = prefix_sums(&sheet.column_widths);
        let row_offsets = prefix_sums(&sheet.row_heights);
        let column_visible = visible_indices(&sheet.column_widths);
        let row_visible = visible_indices(&sheet.row_heights);

        // rowStarts: 每行第一个 cell 的索引（cells 已按 row, column 排序）
        let row_count = sheet.row_heights.len();
        let mut row_starts = Vec::with_capacity(row_count + 1);
        let mut next = 0_usize;
        for row in 0..row_count {
            row_starts.push(next as u32);
            while next < sheet.cells.len() && sheet.cells[next].row as usize == row {
                next += 1;
            }
        }
        row_starts.push(next as u32);

        // firstCell 二分查找辅助
        let first_cell = |row: u32, column: u32| -> usize {
            let mut low = row_starts[row as usize] as usize;
            let mut high = row_starts[row as usize + 1] as usize;
            while low < high {
                let mid = (low + high) / 2;
                if sheet.cells[mid].column < column {
                    low = mid + 1;
                } else {
                    high = mid;
                }
            }
            low
        };

        let mut merged_cells = vec![false; sheet.cells.len()];
        let mut merge_rects = Vec::with_capacity(sheet.merges.len());
        for range in &sheet.merges {
            let mut anchor = -1_i32;
            for row in range.start_row..=range.end_row {
                if row as usize >= row_count {
                    break;
                }
                let start = first_cell(row, range.start_column);
                let end = row_starts[row as usize + 1] as usize;
                for (i, cell) in sheet.cells.iter().enumerate().take(end).skip(start) {
                    if cell.column > range.end_column {
                        break;
                    }
                    merged_cells[i] = true;
                    if row == range.start_row && cell.column == range.start_column {
                        anchor = i32::try_from(i).unwrap_or(-1);
                    }
                }
            }
            let left = column_offsets
                .get(range.start_column as usize)
                .copied()
                .unwrap_or(0.0);
            let top = row_offsets
                .get(range.start_row as usize)
                .copied()
                .unwrap_or(0.0);
            let right = column_offsets
                .get(range.end_column as usize + 1)
                .copied()
                .unwrap_or(left);
            let bottom = row_offsets
                .get(range.end_row as usize + 1)
                .copied()
                .unwrap_or(top);
            merge_rects.push(MergeRect {
                left,
                top,
                right,
                bottom,
                anchor,
                start_row: range.start_row,
                end_row: range.end_row,
            });
        }

        Self {
            column_offsets,
            row_offsets,
            column_visible,
            row_visible,
            row_starts,
            merged_cells,
            merge_rects,
        }
    }
}

fn prefix_sums(sizes: &[f32]) -> Vec<f32> {
    let mut offsets = Vec::with_capacity(sizes.len() + 1);
    offsets.push(0.0);
    let mut acc = 0.0;
    for &s in sizes {
        acc += s;
        offsets.push(acc);
    }
    offsets
}

fn visible_indices(sizes: &[f32]) -> Vec<u32> {
    sizes
        .iter()
        .enumerate()
        .filter(|(_, &s)| s > 0.0)
        .map(|(i, _)| i as u32)
        .collect()
}

#[derive(Debug, Clone, Serialize)]
pub struct Cell {
    pub row: u32,
    pub column: u32,
    pub text: String,
    pub style: u32,
    pub numeric: bool,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CellRange {
    pub start_row: u32,
    pub start_column: u32,
    pub end_row: u32,
    pub end_column: u32,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CellStyle {
    pub font_size: f32,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub color: u32,
    pub fill: u32,
    pub alignment: u8,
    pub vertical_alignment: VerticalAlignment,
    pub wrap: bool,
    pub borders: [Option<u32>; 4],
}

impl Default for CellStyle {
    fn default() -> Self {
        Self {
            font_size: 11.0,
            bold: false,
            italic: false,
            underline: false,
            color: 0xff202124,
            fill: 0,
            alignment: 3,
            vertical_alignment: VerticalAlignment::Bottom,
            wrap: false,
            borders: [None; 4],
        }
    }
}
