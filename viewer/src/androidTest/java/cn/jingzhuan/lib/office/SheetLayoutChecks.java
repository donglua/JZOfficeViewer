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
