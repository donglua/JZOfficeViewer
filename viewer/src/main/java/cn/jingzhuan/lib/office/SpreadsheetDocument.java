package cn.jingzhuan.lib.office;

import java.util.ArrayList;
import java.util.List;

final class SpreadsheetDocument {
    private SpreadsheetDocument() { }

    static final class Sheet {
        String name = "";
        float[] rowHeights = {15};
        float[] columnWidths = {64};
        final List<Cell> cells = new ArrayList<>();
        final List<CellRange> merges = new ArrayList<>();
        /** 预计算的几何布局（来自 core），为 null 时由平台层现场计算（兼容旧 core） */
        Geometry geometry;
    }

    /** 预计算的工作表几何数据（core 输出） */
    static final class Geometry {
        float[] columnOffsets;
        float[] rowOffsets;
        int[] columnVisible;
        int[] rowVisible;
        int[] rowStarts;
        boolean[] mergedCells;
        final List<MergeRect> mergeRects = new ArrayList<>();
    }

    static final class MergeRect {
        float left, top, right, bottom;
        int anchor; // cells 数组索引，-1 表示无 anchor
        int startRow, endRow; // 合并区域行范围（用于分桶索引）
    }

    static final class Cell {
        static final int MAX_PREVIEW_LENGTH = 4096;
        int row, column, style;
        String text = "";
        boolean numeric;

        String previewText() {
            if (text.length() <= MAX_PREVIEW_LENGTH) return text;
            int end = MAX_PREVIEW_LENGTH - 1;
            if (Character.isHighSurrogate(text.charAt(end - 1)) && Character.isLowSurrogate(text.charAt(end))) end--;
            return text.substring(0, end) + "\u2026";
        }
    }

    static final class CellRange {
        int startRow, startColumn, endRow, endColumn;
    }

    static final class CellStyle {
        float fontSize = 11;
        boolean bold, italic, underline, wrap;
        int color = 0xff202124, fill;
        int alignment = 3;
        OfficeDocument.VerticalAlignment verticalAlignment = OfficeDocument.VerticalAlignment.BOTTOM;
        final Integer[] borders = new Integer[4];
    }
}
