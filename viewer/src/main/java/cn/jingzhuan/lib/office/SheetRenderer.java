package cn.jingzhuan.lib.office;

import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.text.Layout;
import android.text.StaticLayout;
import android.text.TextDirectionHeuristics;
import android.text.TextPaint;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

final class SheetRenderer {
    static final float HEADER_WIDTH = 42, HEADER_HEIGHT = 20;
    private static final float PADDING = 2, VERTICAL_PADDING = 1;
    private static final int GRID_COLOR = 0xffdce1e5, HEADER_COLOR = 0xfff3f5f7;
    private static final int MAX_CACHED_LAYOUTS = 256, MAX_LAYOUT_COST = 256 * 1024;
    private static final int BUCKET_ROW_SIZE = 64;
    private static final Typeface[] TYPEFACES = {
        Typeface.create(Typeface.DEFAULT, Typeface.NORMAL),
        Typeface.create(Typeface.DEFAULT, Typeface.BOLD),
        Typeface.create(Typeface.DEFAULT, Typeface.ITALIC),
        Typeface.create(Typeface.DEFAULT, Typeface.BOLD_ITALIC)
    };

    float width, height;
    private SpreadsheetDocument.Sheet sheet;
    private List<SpreadsheetDocument.CellStyle> styles = Collections.emptyList();
    private SheetLayout layout;
    private SheetLayout.Axis rows, columns;
    private final List<Merge> merges = new ArrayList<>();
    private final List<Merge> visibleMerges = new ArrayList<>();
    private List<Merge>[] mergeBuckets;
    private int renderGen;
    private final LinkedHashMap<SpreadsheetDocument.Cell, StaticLayout> layouts = new LinkedHashMap<>(32, .75f, true);
    private int layoutCost;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint headerFont = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF cellBounds = new RectF();
    private final RectF body = new RectF();

    SheetRenderer() {
        headerFont.setTextSize(10);
        headerFont.setColor(0xff52606d);
    }

    void clear() {
        sheet = null; styles = Collections.emptyList(); rows = columns = null;
        layout = null; width = height = 0;
        merges.clear(); visibleMerges.clear(); layouts.clear(); layoutCost = 0;
        mergeBuckets = null;
    }

    void setSheet(SpreadsheetDocument.Sheet selected, List<SpreadsheetDocument.CellStyle> cellStyles) {
        setSheet(selected, cellStyles, new SheetLayout(selected, HEADER_WIDTH, HEADER_HEIGHT));
    }

    void setSheet(SpreadsheetDocument.Sheet selected, List<SpreadsheetDocument.CellStyle> cellStyles, SheetLayout precomputedLayout) {
        clear();
        sheet = selected; styles = cellStyles;
        layout = precomputedLayout;
        rows = layout.rows; columns = layout.columns;
        width = layout.width; height = layout.height;
        int bucketCount = Math.max(1, (layout.rows.offsets.length + BUCKET_ROW_SIZE - 1) / BUCKET_ROW_SIZE);
        @SuppressWarnings("unchecked")
        List<Merge>[] buckets = (List<Merge>[]) new List<?>[bucketCount];
        for (int i = 0; i < bucketCount; i++) {
            buckets[i] = new ArrayList<>();
        }
        for (SheetLayout.Merge source : layout.merges) {
            Merge merge = new Merge();
            merge.bounds.set(source.left, source.top, source.right, source.bottom);
            merge.anchor = source.anchor;
            merge.startRow = source.startRow;
            merge.endRow = source.endRow;
            merges.add(merge);
            int startBucket = Math.max(0, source.startRow / BUCKET_ROW_SIZE);
            int endBucket = Math.min(bucketCount - 1, source.endRow / BUCKET_ROW_SIZE);
            for (int b = startBucket; b <= endBucket; b++) {
                buckets[b].add(merge);
            }
        }
        mergeBuckets = buckets;
    }

    void draw(Canvas canvas, RectF viewport) {
        if (sheet == null || viewport.isEmpty()) return;
        int save = canvas.save();
        canvas.clipRect(viewport);
        body.set(Math.max(HEADER_WIDTH, viewport.left + HEADER_WIDTH),
            Math.max(HEADER_HEIGHT, viewport.top + HEADER_HEIGHT),
            Math.min(width, viewport.right), Math.min(height, viewport.bottom));
        if (!body.isEmpty()) {
            int bodySave = canvas.save();
            canvas.clipRect(body);
            fill(canvas, body, 0xffffffff);
            int firstRow = rows.first(body.top), firstColumn = columns.first(body.left);
            drawCells(canvas, firstRow, firstColumn, false);
            drawGrid(canvas, firstRow, firstColumn);
            visibleMerges.clear();
            if (mergeBuckets != null && mergeBuckets.length > 0) {
                int firstRowIdx = firstRow < rows.visible.length ? rows.visible[firstRow] : 0;
                int lastRowSearch = rows.first(body.bottom);
                int lastRowIdx = lastRowSearch < rows.visible.length
                    ? rows.visible[lastRowSearch]
                    : (rows.visible.length > 0 ? rows.visible[rows.visible.length - 1] : firstRowIdx);
                int startBucket = Math.max(0, firstRowIdx / BUCKET_ROW_SIZE);
                int endBucket = Math.min(mergeBuckets.length - 1, lastRowIdx / BUCKET_ROW_SIZE);
                int currentGen = ++renderGen;
                if (currentGen == 0) {
                    currentGen = renderGen = 1;
                    for (Merge m : merges) m.lastSeenGen = 0;
                }
                for (int b = startBucket; b <= endBucket; b++) {
                    List<Merge> bucket = mergeBuckets[b];
                    for (int i = 0; i < bucket.size(); i++) {
                        Merge merge = bucket.get(i);
                        if (merge.lastSeenGen == currentGen) continue;
                        merge.lastSeenGen = currentGen;
                        if (merge.bounds.isEmpty() || !RectF.intersects(body, merge.bounds)) continue;
                        visibleMerges.add(merge);
                        fill(canvas, merge.bounds, 0xffffffff);
                        if (merge.anchor != null) drawCell(canvas, merge.anchor, merge.bounds);
                        stroke(canvas, merge.bounds, GRID_COLOR, .5f);
                    }
                }
            }
            drawCells(canvas, firstRow, firstColumn, true);
            for (Merge merge : visibleMerges) {
                if (merge.anchor != null) drawBorders(canvas, merge.bounds, style(merge.anchor));
            }
            canvas.restoreToCount(bodySave);
        }
        drawHeaders(canvas, viewport);
        canvas.restoreToCount(save);
    }

    private void drawCells(Canvas canvas, int firstRow, int firstColumn, boolean bordersOnly) {
        if (firstColumn == columns.visible.length) return;
        int column = columns.visible[firstColumn];
        for (int r = firstRow; r < rows.visible.length; r++) {
            int row = rows.visible[r];
            if (rows.offsets[row] >= body.bottom) break;
            for (int i = layout.firstCell(row, column); i < layout.rowStarts[row + 1]; i++) {
                SpreadsheetDocument.Cell cell = sheet.cells.get(i);
                if (columns.offsets[cell.column] >= body.right) break;
                if (layout.mergedCells[i] || sheet.columnWidths[cell.column] == 0) continue;
                cellBounds.set(columns.offsets[cell.column], rows.offsets[row],
                    columns.offsets[cell.column + 1], rows.offsets[row + 1]);
                if (bordersOnly) drawBorders(canvas, cellBounds, style(cell));
                else drawCell(canvas, cell, cellBounds);
            }
        }
    }

    private void drawGrid(Canvas canvas, int firstRow, int firstColumn) {
        paint.setColor(GRID_COLOR); paint.setStyle(Paint.Style.STROKE); paint.setStrokeWidth(.5f);
        for (int r = firstRow; r < rows.visible.length; r++) {
            int row = rows.visible[r];
            if (rows.offsets[row] >= body.bottom) break;
            canvas.drawLine(body.left, rows.offsets[row + 1], body.right, rows.offsets[row + 1], paint);
        }
        for (int c = firstColumn; c < columns.visible.length; c++) {
            int column = columns.visible[c];
            if (columns.offsets[column] >= body.right) break;
            canvas.drawLine(columns.offsets[column + 1], body.top, columns.offsets[column + 1], body.bottom, paint);
        }
    }

    private SpreadsheetDocument.CellStyle style(SpreadsheetDocument.Cell cell) {
        return styles.get(cell.style);
    }

    private void drawCell(Canvas canvas, SpreadsheetDocument.Cell cell, RectF bounds) {
        SpreadsheetDocument.CellStyle style = style(cell);
        fill(canvas, bounds, style.fill);
        float availableWidth = bounds.width() - 2 * PADDING, availableHeight = bounds.height() - 2 * VERTICAL_PADDING;
        if (cell.text.isEmpty() || availableWidth <= 0 || availableHeight <= 0) return;
        StaticLayout layout = textLayout(cell, style, availableWidth, availableHeight);
        int alignment = alignment(cell, style);
        float x = bounds.left + PADDING;
        if (alignment == 1) x += (availableWidth - layout.getWidth()) / 2;
        else if (alignment == 2) x += availableWidth - layout.getWidth();
        float y = bounds.top + VERTICAL_PADDING;
        float remaining = Math.max(0, availableHeight - layout.getHeight());
        if (style.verticalAlignment == OfficeDocument.VerticalAlignment.CENTER) y += remaining / 2;
        else if (style.verticalAlignment == OfficeDocument.VerticalAlignment.BOTTOM) y += remaining;
        int save = canvas.save();
        canvas.clipRect(bounds.left + PADDING, bounds.top + VERTICAL_PADDING, bounds.right - PADDING, bounds.bottom - VERTICAL_PADDING);
        canvas.translate(x, y);
        layout.draw(canvas);
        canvas.restoreToCount(save);
    }

    private StaticLayout textLayout(SpreadsheetDocument.Cell cell, SpreadsheetDocument.CellStyle style,
                                    float availableWidth, float availableHeight) {
        StaticLayout cached = layouts.get(cell);
        if (cached != null) return cached;
        TextPaint font = new TextPaint(Paint.ANTI_ALIAS_FLAG);
        font.setTextSize(style.fontSize); font.setColor(style.color); font.setUnderlineText(style.underline);
        int typeface = style.bold ? (style.italic ? Typeface.BOLD_ITALIC : Typeface.BOLD)
            : (style.italic ? Typeface.ITALIC : Typeface.NORMAL);
        font.setTypeface(TYPEFACES[typeface]);
        String text = cell.previewText();
        int layoutWidth = Math.max(1, (int) availableWidth);
        if (!style.wrap) layoutWidth = Math.max(layoutWidth, (int) Math.ceil(Layout.getDesiredWidth(text, font)));
        int alignment = alignment(cell, style);
        Layout.Alignment textAlignment = alignment == 1 ? Layout.Alignment.ALIGN_CENTER
            : alignment == 2 ? Layout.Alignment.ALIGN_OPPOSITE : Layout.Alignment.ALIGN_NORMAL;
        int maxLines = Math.max(1, (int) Math.ceil(availableHeight / Math.max(1, font.getFontSpacing())) + 1);
        StaticLayout layout = StaticLayout.Builder.obtain(text, 0, text.length(), font, layoutWidth)
            .setAlignment(textAlignment).setTextDirection(TextDirectionHeuristics.LTR).setIncludePad(false)
            .setMaxLines(maxLines).build();
        int cost = layout.getText().length() + 8 * layout.getLineCount();
        if (cost <= MAX_LAYOUT_COST) {
            Iterator<Map.Entry<SpreadsheetDocument.Cell, StaticLayout>> iterator = layouts.entrySet().iterator();
            while (iterator.hasNext() && (layouts.size() >= MAX_CACHED_LAYOUTS || layoutCost + cost > MAX_LAYOUT_COST)) {
                Map.Entry<SpreadsheetDocument.Cell, StaticLayout> oldest = iterator.next();
                layoutCost -= oldest.getValue().getText().length() + 8 * oldest.getValue().getLineCount();
                iterator.remove();
            }
            layouts.put(cell, layout); layoutCost += cost;
        }
        return layout;
    }

    private static int alignment(SpreadsheetDocument.Cell cell, SpreadsheetDocument.CellStyle style) {
        return style.alignment == 3 ? (cell.numeric ? 2 : 0) : style.alignment;
    }

    private void drawBorders(Canvas canvas, RectF bounds, SpreadsheetDocument.CellStyle style) {
        paint.setStyle(Paint.Style.STROKE); paint.setStrokeWidth(1);
        for (int side = 0; side < 4; side++) {
            Integer color = style.borders[side];
            if (color == null) continue;
            paint.setColor(color);
            if (side == 0) canvas.drawLine(bounds.left, bounds.top, bounds.left, bounds.bottom, paint);
            else if (side == 1) canvas.drawLine(bounds.left, bounds.top, bounds.right, bounds.top, paint);
            else if (side == 2) canvas.drawLine(bounds.right, bounds.top, bounds.right, bounds.bottom, paint);
            else canvas.drawLine(bounds.left, bounds.bottom, bounds.right, bounds.bottom, paint);
        }
    }

    private void drawHeaders(Canvas canvas, RectF viewport) {
        float left = viewport.left, top = viewport.top;
        cellBounds.set(left, top, viewport.right, top + HEADER_HEIGHT);
        fill(canvas, cellBounds, HEADER_COLOR);
        cellBounds.set(left, top, left + HEADER_WIDTH, viewport.bottom);
        fill(canvas, cellBounds, HEADER_COLOR);
        int save = canvas.save();
        canvas.clipRect(left + HEADER_WIDTH, top, viewport.right, top + HEADER_HEIGHT);
        headerFont.setTextAlign(Paint.Align.CENTER);
        for (int c = columns.first(left + HEADER_WIDTH); c < columns.visible.length; c++) {
            int column = columns.visible[c];
            if (columns.offsets[column] >= viewport.right) break;
            cellBounds.set(columns.offsets[column], top, columns.offsets[column + 1], top + HEADER_HEIGHT);
            header(canvas, columnName(column), cellBounds, cellBounds.centerX());
        }
        canvas.restoreToCount(save);
        save = canvas.save();
        canvas.clipRect(left, top + HEADER_HEIGHT, left + HEADER_WIDTH, viewport.bottom);
        headerFont.setTextAlign(Paint.Align.RIGHT);
        for (int r = rows.first(top + HEADER_HEIGHT); r < rows.visible.length; r++) {
            int row = rows.visible[r];
            if (rows.offsets[row] >= viewport.bottom) break;
            cellBounds.set(left, rows.offsets[row], left + HEADER_WIDTH, rows.offsets[row + 1]);
            header(canvas, Integer.toString(row + 1), cellBounds, left + HEADER_WIDTH - 6);
        }
        canvas.restoreToCount(save);
        paint.setColor(0xffbfc7cd); paint.setStyle(Paint.Style.STROKE); paint.setStrokeWidth(.75f);
        canvas.drawLine(left + HEADER_WIDTH, top, left + HEADER_WIDTH, viewport.bottom, paint);
        canvas.drawLine(left, top + HEADER_HEIGHT, viewport.right, top + HEADER_HEIGHT, paint);
    }

    private void header(Canvas canvas, String text, RectF bounds, float x) {
        stroke(canvas, bounds, GRID_COLOR, .5f);
        int save = canvas.save();
        canvas.clipRect(bounds);
        canvas.drawText(text, x, bounds.centerY() - (headerFont.ascent() + headerFont.descent()) / 2, headerFont);
        canvas.restoreToCount(save);
    }

    private static String columnName(int column) {
        StringBuilder result = new StringBuilder();
        for (int value = column + 1; value > 0; value = (value - 1) / 26) result.append((char) ('A' + (value - 1) % 26));
        return result.reverse().toString();
    }

    private void fill(Canvas canvas, RectF bounds, int color) {
        if ((color >>> 24) == 0) return;
        paint.setStyle(Paint.Style.FILL); paint.setColor(color); canvas.drawRect(bounds, paint);
    }

    private void stroke(Canvas canvas, RectF bounds, int color, float strokeWidth) {
        paint.setStyle(Paint.Style.STROKE); paint.setColor(color); paint.setStrokeWidth(strokeWidth);
        canvas.drawRect(bounds, paint);
    }

    private static final class Merge {
        final RectF bounds = new RectF();
        SpreadsheetDocument.Cell anchor;
        int startRow, endRow;
        int lastSeenGen;
    }
}
