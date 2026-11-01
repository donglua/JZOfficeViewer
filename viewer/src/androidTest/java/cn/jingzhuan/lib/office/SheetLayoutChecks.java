package cn.jingzhuan.lib.office;

import java.util.Arrays;
import java.util.Random;

public final class SheetLayoutChecks {
    public static void main(String[] args) { System.out.print(run()); }

    static String run() {
        SpreadsheetDocument.Sheet sheet = new SpreadsheetDocument.Sheet();
        sheet.rowHeights = new float[] {28, 0, 36, 30, 70, 0};
        sheet.columnWidths = new float[] {80, 0, 100, 70, 90};
        sheet.cells.add(cell(0, 0)); sheet.cells.add(cell(1, 3)); sheet.cells.add(cell(2, 2));
        sheet.cells.add(cell(4, 1)); sheet.cells.add(cell(4, 4));
        sheet.merges.add(range(0, 0, 3, 2));
        sheet.merges.add(range(4, 2, 5, 3));
        sheet.merges.add(range(5, 4, 5, 4));
        SheetLayout layout = new SheetLayout(sheet, 42, 20);
        check(layout.width == 382 && layout.height == 184, "Hidden dimensions and headers");
        check(Arrays.equals(layout.rowStarts, new int[] {0, 1, 2, 3, 3, 5, 5}), "Sparse and trailing empty rows");
        check(Arrays.equals(layout.mergedCells, new boolean[] {true, false, true, false, false}), "Merge membership");
        SheetLayout.Merge merge = layout.merges.get(0);
        check(merge.left == 42 && merge.top == 20 && merge.right == 222 && merge.bottom == 114, "Inclusive merge bounds");
        check(merge.startRow == 0 && merge.endRow == 3, "Merge row bounds");
        check(merge.anchor == sheet.cells.get(0), "Anchor identity retained for renderer text cache");
        check(layout.merges.get(1).anchor == null, "Missing anchor stays empty");
        check(layout.merges.get(2).top == layout.merges.get(2).bottom, "Hidden merge has zero height");
        verify(sheet);

        SpreadsheetDocument.Sheet hidden = new SpreadsheetDocument.Sheet();
        hidden.rowHeights = new float[] {0, 0}; hidden.columnWidths = new float[] {0};
        verify(hidden);
        SheetLayout empty = new SheetLayout(hidden, 42, 20);
        check(empty.width == 42 && empty.height == 20 && empty.rows.first(0) == 0, "All-hidden sheet");
        check(empty.merges.isEmpty() && empty.mergedCells.length == 0, "Replacement has no prior sheet state");

        Random random = new Random(20260921);
        for (int sample = 0; sample < 200; sample++) {
            SpreadsheetDocument.Sheet generated = new SpreadsheetDocument.Sheet();
            generated.rowHeights = new float[1 + random.nextInt(30)];
            generated.columnWidths = new float[1 + random.nextInt(15)];
            for (int row = 0; row < generated.rowHeights.length; row++) {
                generated.rowHeights[row] = random.nextInt(5) * 7.25f;
                for (int column = 0; column < generated.columnWidths.length; column++) {
                    if (random.nextInt(4) == 0) generated.cells.add(cell(row, column));
                }
                if (row % 3 == 0) {
                    int column = random.nextInt(generated.columnWidths.length);
                    generated.merges.add(range(row, column, Math.min(row + 1, generated.rowHeights.length - 1),
                        Math.min(column + 2, generated.columnWidths.length - 1)));
                }
            }
            for (int column = 0; column < generated.columnWidths.length; column++) {
                generated.columnWidths[column] = random.nextInt(5) * 15.5f;
            }
            verify(generated);
        }
        return "PASS sheet layout: sparse lookup, hidden axes, merge bounds/anchors and 200 seeded reference comparisons\n";
    }

    private static void verify(SpreadsheetDocument.Sheet sheet) {
        SheetLayout layout = new SheetLayout(sheet, 42, 20);
        if (sheet.geometry == null) verifyPrecomputedGeometry(sheet);
        verifyAxis(layout.rows, sheet.rowHeights, 20);
        verifyAxis(layout.columns, sheet.columnWidths, 42);
        for (int row = 0; row < sheet.rowHeights.length; row++) {
            for (int column = 0; column <= sheet.columnWidths.length; column++) {
                int expected = 0;
                while (expected < sheet.cells.size()) {
                    SpreadsheetDocument.Cell cell = sheet.cells.get(expected);
                    if (cell.row > row || cell.row == row && cell.column >= column) break;
                    expected++;
                }
                check(layout.firstCell(row, column) == expected, "Sparse lower bound");
            }
        }
        check(layout.merges.size() == sheet.merges.size(), "Merge count");
        for (int index = 0; index < sheet.cells.size(); index++) {
            SpreadsheetDocument.Cell cell = sheet.cells.get(index);
            boolean covered = false;
            for (SpreadsheetDocument.CellRange range : sheet.merges) {
                covered |= cell.row >= range.startRow && cell.row <= range.endRow
                    && cell.column >= range.startColumn && cell.column <= range.endColumn;
            }
            check(layout.mergedCells[index] == covered, "Merge membership matches coordinates");
        }
        for (int index = 0; index < sheet.merges.size(); index++) {
            SpreadsheetDocument.CellRange range = sheet.merges.get(index);
            SheetLayout.Merge merge = layout.merges.get(index);
            check(merge.left == offset(sheet.columnWidths, range.startColumn, 42)
                && merge.right == offset(sheet.columnWidths, range.endColumn + 1, 42)
                && merge.top == offset(sheet.rowHeights, range.startRow, 20)
                && merge.bottom == offset(sheet.rowHeights, range.endRow + 1, 20), "Merge geometry matches dimensions");
            SpreadsheetDocument.Cell anchor = null;
            for (SpreadsheetDocument.Cell cell : sheet.cells) {
                if (cell.row == range.startRow && cell.column == range.startColumn) anchor = cell;
            }
            check(merge.anchor == anchor, "Anchor is the top-left cell, including hidden anchors");
        }
    }

    /**
     * 校验 core 预计算几何分支：与现场计算结果完全一致；长度不匹配的几何数据安全回退。
     */
    private static void verifyPrecomputedGeometry(SpreadsheetDocument.Sheet sheet) {
        SheetLayout expected = new SheetLayout(sheet, 42, 20);
        sheet.geometry = geometry(sheet);
        SheetLayout actual = new SheetLayout(sheet, 42, 20);
        check(actual.width == expected.width && actual.height == expected.height, "Precomputed geometry size matches");
        check(Arrays.equals(actual.rowStarts, expected.rowStarts), "Precomputed row starts match");
        check(Arrays.equals(actual.mergedCells, expected.mergedCells), "Precomputed merge membership matches");
        check(actual.merges.size() == expected.merges.size(), "Precomputed merge count matches");
        for (int index = 0; index < actual.merges.size(); index++) {
            SheetLayout.Merge left = expected.merges.get(index), right = actual.merges.get(index);
            check(left.left == right.left && left.top == right.top
                && left.right == right.right && left.bottom == right.bottom
                && left.startRow == right.startRow && left.endRow == right.endRow
                && left.anchor == right.anchor, "Precomputed merge bounds and anchor match");
        }

        // 几何数据与行列维度不匹配时必须回退现场计算，不能越界
        SpreadsheetDocument.Geometry saved = sheet.geometry;
        sheet.geometry = copy(saved);
        sheet.geometry.rowStarts = truncated(saved.rowStarts, 1);
        verifyFallback(sheet, expected, "row starts");
        sheet.geometry = new SpreadsheetDocument.Geometry();
        sheet.geometry.columnOffsets = new float[0];
        sheet.geometry.rowOffsets = saved.rowOffsets;
        sheet.geometry.rowStarts = saved.rowStarts;
        sheet.geometry.mergedCells = saved.mergedCells;
        verifyFallback(sheet, expected, "empty column offsets");
        sheet.geometry = saved;
    }

    private static SpreadsheetDocument.Geometry copy(SpreadsheetDocument.Geometry source) {
        SpreadsheetDocument.Geometry target = new SpreadsheetDocument.Geometry();
        target.columnOffsets = source.columnOffsets;
        target.rowOffsets = source.rowOffsets;
        target.columnVisible = source.columnVisible;
        target.rowVisible = source.rowVisible;
        target.rowStarts = source.rowStarts;
        target.mergedCells = source.mergedCells;
        target.mergeRects.addAll(source.mergeRects);
        return target;
    }

    private static void verifyFallback(SpreadsheetDocument.Sheet sheet, SheetLayout expected, String label) {
        SheetLayout fallback = new SheetLayout(sheet, 42, 20);
        check(fallback.width == expected.width && fallback.height == expected.height
            && Arrays.equals(fallback.rowStarts, expected.rowStarts)
            && fallback.merges.size() == expected.merges.size(), "Malformed geometry falls back: " + label);
    }

    /** 按 core 的算法构造预计算几何，供预计算分支与现场计算分支对照 */
    private static SpreadsheetDocument.Geometry geometry(SpreadsheetDocument.Sheet sheet) {
        SpreadsheetDocument.Geometry g = new SpreadsheetDocument.Geometry();
        g.columnOffsets = offsets(sheet.columnWidths);
        g.rowOffsets = offsets(sheet.rowHeights);
        g.columnVisible = visibleIndices(sheet.columnWidths);
        g.rowVisible = visibleIndices(sheet.rowHeights);
        int rowCount = sheet.rowHeights.length;
        g.rowStarts = new int[rowCount + 1];
        int next = 0;
        for (int row = 0; row < rowCount; row++) {
            g.rowStarts[row] = next;
            while (next < sheet.cells.size() && sheet.cells.get(next).row == row) next++;
        }
        g.rowStarts[rowCount] = next;
        g.mergedCells = new boolean[sheet.cells.size()];
        for (SpreadsheetDocument.CellRange range : sheet.merges) {
            int anchor = -1;
            for (int row = range.startRow; row <= range.endRow && row < rowCount; row++) {
                for (int index = 0; index < sheet.cells.size(); index++) {
                    SpreadsheetDocument.Cell cell = sheet.cells.get(index);
                    if (cell.row != row || cell.column < range.startColumn || cell.column > range.endColumn) continue;
                    g.mergedCells[index] = true;
                    if (row == range.startRow && cell.column == range.startColumn) anchor = index;
                }
            }
            SpreadsheetDocument.MergeRect rect = new SpreadsheetDocument.MergeRect();
            rect.left = g.columnOffsets[range.startColumn];
            rect.top = g.rowOffsets[range.startRow];
            rect.right = g.columnOffsets[Math.min(range.endColumn + 1, g.columnOffsets.length - 1)];
            rect.bottom = g.rowOffsets[Math.min(range.endRow + 1, g.rowOffsets.length - 1)];
            rect.anchor = anchor;
            rect.startRow = range.startRow;
            rect.endRow = range.endRow;
            g.mergeRects.add(rect);
        }
        return g;
    }

    private static float[] offsets(float[] sizes) {
        float[] values = new float[sizes.length + 1];
        for (int index = 0; index < sizes.length; index++) values[index + 1] = values[index] + sizes[index];
        return values;
    }

    private static int[] visibleIndices(float[] sizes) {
        int[] indices = new int[sizes.length];
        int count = 0;
        for (int index = 0; index < sizes.length; index++) {
            if (sizes[index] > 0) indices[count++] = index;
        }
        return Arrays.copyOf(indices, count);
    }

    private static int[] truncated(int[] values, int length) {
        return Arrays.copyOf(values, Math.max(0, values.length - length));
    }

    private static void verifyAxis(SheetLayout.Axis axis, float[] sizes, float gutter) {
        int visible = 0;
        for (int index = 0; index < sizes.length; index++) {
            check(axis.offsets[index] == offset(sizes, index, gutter), "Axis prefix position");
            if (sizes[index] > 0) check(axis.visible[visible++] == index, "Visible index preserves original numbering");
        }
        check(axis.visible.length == visible, "Visible count");
        float end = offset(sizes, sizes.length, gutter);
        check(axis.offsets[sizes.length] == end, "Axis end");
        for (float position = -1; position <= end + 1; position += .5f) {
            int expected = 0;
            for (int index = 0; index < sizes.length; index++) {
                if (sizes[index] > 0 && offset(sizes, index + 1, gutter) <= position) expected++;
            }
            check(axis.first(position) == expected, "Viewport lower bound at and between row/column edges");
        }
    }

    private static float offset(float[] sizes, int end, float gutter) {
        for (int index = 0; index < end; index++) gutter += sizes[index];
        return gutter;
    }

    static SpreadsheetDocument.Cell cell(int row, int column) {
        SpreadsheetDocument.Cell cell = new SpreadsheetDocument.Cell();
        cell.row = row; cell.column = column; cell.text = row + ":" + column;
        return cell;
    }

    static SpreadsheetDocument.CellRange range(int startRow, int startColumn, int endRow, int endColumn) {
        SpreadsheetDocument.CellRange range = new SpreadsheetDocument.CellRange();
        range.startRow = startRow; range.startColumn = startColumn; range.endRow = endRow; range.endColumn = endColumn;
        return range;
    }

    private static void check(boolean condition, String label) {
        if (!condition) throw new AssertionError(label);
    }
}
