package cn.jingzhuan.lib.office;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Geometry and sparse-cell indexes for a decoded sheet. Do not mutate the sheet while in use. */
final class SheetLayout {
    final Axis rows, columns;
    final float width, height;
    final int[] rowStarts;
    final boolean[] mergedCells;
    final List<Merge> merges = new ArrayList<>();
    private final SpreadsheetDocument.Sheet sheet;

    SheetLayout(SpreadsheetDocument.Sheet sheet, float headerWidth, float headerHeight) {
        this.sheet = sheet;
        rows = new Axis(sheet.rowHeights, headerHeight);
        columns = new Axis(sheet.columnWidths, headerWidth);
        width = columns.offsets[columns.offsets.length - 1];
        height = rows.offsets[rows.offsets.length - 1];
        rowStarts = new int[sheet.rowHeights.length + 1];
        int next = 0;
        for (int row = 0; row < sheet.rowHeights.length; row++) {
            rowStarts[row] = next;
            while (next < sheet.cells.size() && sheet.cells.get(next).row == row) next++;
        }
        rowStarts[sheet.rowHeights.length] = next;
        mergedCells = new boolean[sheet.cells.size()];
        for (SpreadsheetDocument.CellRange range : sheet.merges) {
            SpreadsheetDocument.Cell anchor = null;
            for (int row = range.startRow; row <= range.endRow; row++) {
                for (int i = firstCell(row, range.startColumn); i < rowStarts[row + 1]; i++) {
                    SpreadsheetDocument.Cell cell = sheet.cells.get(i);
                    if (cell.column > range.endColumn) break;
                    mergedCells[i] = true;
                    if (row == range.startRow && cell.column == range.startColumn) anchor = cell;
                }
            }
            merges.add(new Merge(columns.offsets[range.startColumn], rows.offsets[range.startRow],
                columns.offsets[range.endColumn + 1], rows.offsets[range.endRow + 1],
                range.startRow, range.endRow, anchor));
        }
    }

    int firstCell(int row, int column) {
        int low = rowStarts[row], high = rowStarts[row + 1];
        while (low < high) {
            int middle = (low + high) >>> 1;
            if (sheet.cells.get(middle).column < column) low = middle + 1;
            else high = middle;
        }
        return low;
    }

    static final class Merge {
        final float left, top, right, bottom;
        final int startRow, endRow;
        final SpreadsheetDocument.Cell anchor;

        Merge(float left, float top, float right, float bottom, SpreadsheetDocument.Cell anchor) {
            this(left, top, right, bottom, 0, 0, anchor);
        }

        Merge(float left, float top, float right, float bottom, int startRow, int endRow, SpreadsheetDocument.Cell anchor) {
            this.left = left; this.top = top; this.right = right; this.bottom = bottom;
            this.startRow = startRow; this.endRow = endRow; this.anchor = anchor;
        }
    }

    static final class Axis {
        final float[] offsets;
        final int[] visible;

        Axis(float[] sizes, float gutter) {
            offsets = new float[sizes.length + 1]; offsets[0] = gutter;
            int[] indices = new int[sizes.length];
            int count = 0;
            for (int i = 0; i < sizes.length; i++) {
                offsets[i + 1] = offsets[i] + sizes[i];
                if (sizes[i] > 0) indices[count++] = i;
            }
            visible = Arrays.copyOf(indices, count);
        }

        int first(float position) {
            int low = 0, high = visible.length;
            while (low < high) {
                int middle = (low + high) >>> 1;
                if (offsets[visible[middle] + 1] <= position) low = middle + 1;
                else high = middle;
            }
            return low;
        }
    }
}
