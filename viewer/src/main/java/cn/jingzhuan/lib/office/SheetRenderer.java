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
    /** 冻结区占可用正文区的最大比例：超出后该轴冻结降级为不冻结，避免正文被挤没 */
    static final float MAX_FROZEN_RATIO = 0.75f;
    private static final float PADDING = 2, VERTICAL_PADDING = 1;
    private static final int GRID_COLOR = 0xffdce1e5, HEADER_COLOR = 0xfff3f5f7;
    private static final int HEADER_SEPARATOR_COLOR = 0xffbfc7cd;
    /** 冻结交界线使用中性蓝灰，区别于普通网格线与表头分隔线 */
    private static final int FREEZE_DIVIDER_COLOR = 0xff9aa5b1;
    private static final int MAX_CACHED_LAYOUTS = 256, MAX_LAYOUT_COST = 256 * 1024;
    private static final int BUCKET_ROW_SIZE = 64;

    float width, height;
    private SpreadsheetDocument.Sheet sheet;
    private List<SpreadsheetDocument.CellStyle> styles = Collections.emptyList();
    SheetLayout layout;
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
    private final RectF shiftedBounds = new RectF();
    /** 当前帧的冻结几何，draw 计算出后供各绘制阶段与外部高亮避让复用 */
    private FreezePlan plan;

    SheetRenderer() {
        headerFont.setTextSize(10);
        headerFont.setColor(0xff52606d);
    }

    void clear() {
        sheet = null; styles = Collections.emptyList(); rows = columns = null;
        layout = null; width = height = 0;
        merges.clear(); visibleMerges.clear(); layouts.clear(); layoutCost = 0;
        mergeBuckets = null; plan = null;
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
        plan = computePlan(sheet, columns, rows, width, height, viewport);
        int save = canvas.save();
        canvas.clipRect(viewport);
        // 四象限正文绘制，从底到顶：滚动正文 → 冻结列 → 冻结行 → 交叉角
        for (Quadrant quadrant : quadrants(plan)) {
            drawQuadrant(canvas, quadrant);
        }
        drawHeaders(canvas, viewport);
        drawFreezeDivider(canvas, viewport);
        canvas.restoreToCount(save);
    }

    /**
     * 计算当前帧的冻结几何：按 X/Y 轴独立执行视口占比保护，两轴互不影响。
     * 冻结区尺寸直接取 core 预计算的行列前缀和差值，常数时间得出。
     */
    static FreezePlan computePlan(SpreadsheetDocument.Sheet sheet, SheetLayout.Axis columns, SheetLayout.Axis rows,
                                  float width, float height, RectF viewport) {
        int rowCount = Math.max(0, rows.offsets.length - 1);
        int columnCount = Math.max(0, columns.offsets.length - 1);
        float scrollX = Math.max(0, viewport.left), scrollY = Math.max(0, viewport.top);
        // 扣除表头后的可用正文区
        float availBodyW = Math.max(0, viewport.width() - HEADER_WIDTH);
        float availBodyH = Math.max(0, viewport.height() - HEADER_HEIGHT);
        int declaredRows = Math.min(Math.max(0, sheet.frozenRows), rowCount);
        int declaredColumns = Math.min(Math.max(0, sheet.frozenColumns), columnCount);
        float dataW = declaredColumns > 0 ? Math.max(0, columns.offsets[declaredColumns] - columns.offsets[0]) : 0;
        float dataH = declaredRows > 0 ? Math.max(0, rows.offsets[declaredRows] - rows.offsets[0]) : 0;
        // 高倍缩放或小窗口下冻结区可能占满视口，此时仅取消超限的那个轴
        boolean columnsFit = declaredColumns > 0 && availBodyW > 0 && dataW <= availBodyW * MAX_FROZEN_RATIO;
        boolean rowsFit = declaredRows > 0 && availBodyH > 0 && dataH <= availBodyH * MAX_FROZEN_RATIO;
        FreezePlan result = new FreezePlan();
        result.effectiveColumns = columnsFit ? declaredColumns : 0;
        result.effectiveRows = rowsFit ? declaredRows : 0;
        result.rowCount = rowCount;
        result.columnCount = columnCount;
        result.scrollX = scrollX;
        result.scrollY = scrollY;
        result.frozenOriginX = HEADER_WIDTH + scrollX;
        result.frozenOriginY = HEADER_HEIGHT + scrollY;
        result.frozenDataWidth = columnsFit ? dataW : 0;
        result.frozenDataHeight = rowsFit ? dataH : 0;
        result.frozenRight = result.frozenOriginX + result.frozenDataWidth;
        result.frozenBottom = result.frozenOriginY + result.frozenDataHeight;
        result.bodyMaxRight = Math.min(width, viewport.right);
        result.bodyMaxBottom = Math.min(height, viewport.bottom);
        return result;
    }

    /** 当前帧冻结几何，未绘制时按整屏视口现场计算 */
    FreezePlan currentPlan(RectF viewport) {
        if (plan != null) return plan;
        return computePlan(sheet, columns, rows, width, height, viewport);
    }

    /** 按给定视口即时计算冻结几何（不复用上一帧缓存，供缩放收敛或跳转计算使用） */
    FreezePlan computeCurrentPlan(RectF viewport) {
        if (sheet == null || columns == null || rows == null) return null;
        return computePlan(sheet, columns, rows, width, height, viewport);
    }

    /** 把正文数据区切成最多 4 个互不重叠的象限；未冻结时退化为单个滚动正文象限 */
    static List<Quadrant> quadrants(FreezePlan plan) {
        List<Quadrant> result = new ArrayList<>(4);
        int frozenRows = Math.min(plan.effectiveRows, plan.rowCount);
        int frozenColumns = Math.min(plan.effectiveColumns, plan.columnCount);
        if (frozenColumns < plan.columnCount && frozenRows < plan.rowCount) {
            result.add(new Quadrant(frozenRows, plan.rowCount, frozenColumns, plan.columnCount,
                0, 0, plan.frozenRight, plan.frozenBottom, plan.bodyMaxRight, plan.bodyMaxBottom));
        }
        if (frozenColumns > 0 && frozenRows < plan.rowCount) {
            result.add(new Quadrant(frozenRows, plan.rowCount, 0, frozenColumns,
                plan.scrollX, 0, plan.frozenOriginX, plan.frozenBottom, plan.frozenRight, plan.bodyMaxBottom));
        }
        if (frozenRows > 0 && frozenColumns < plan.columnCount) {
            result.add(new Quadrant(0, frozenRows, frozenColumns, plan.columnCount,
                0, plan.scrollY, plan.frozenRight, plan.frozenOriginY, plan.bodyMaxRight, plan.frozenBottom));
        }
        if (frozenColumns > 0 && frozenRows > 0) {
            result.add(new Quadrant(0, frozenRows, 0, frozenColumns,
                plan.scrollX, plan.scrollY, plan.frozenOriginX, plan.frozenOriginY, plan.frozenRight, plan.frozenBottom));
        }
        return result;
    }

    /**
     * 绘制单个象限：save -> clipRect -> 填充白底 -> 普通单元格 -> 网格线 ->
     * 相交合并单元格 -> 单元格边框 -> restore。
     */
    private void drawQuadrant(Canvas canvas, Quadrant quadrant) {
        if (quadrant.isEmpty()) return;
        int quadrantSave = canvas.save();
        canvas.clipRect(quadrant.clipLeft, quadrant.clipTop, quadrant.clipRight, quadrant.clipBottom);
        body.set(quadrant.clipLeft, quadrant.clipTop, quadrant.clipRight, quadrant.clipBottom);
        fill(canvas, body, 0xffffffff);
        drawCells(canvas, quadrant, false);
        drawGrid(canvas, quadrant);
        visibleMerges.clear();
        drawMerges(canvas, quadrant);
        drawCells(canvas, quadrant, true);
        for (int i = 0; i < visibleMerges.size(); i++) {
            Merge merge = visibleMerges.get(i);
            if (merge.anchor == null) continue;
            shifted(merge, quadrant, shiftedBounds);
            drawBorders(canvas, shiftedBounds, style(merge.anchor));
        }
        canvas.restoreToCount(quadrantSave);
    }

    /** 合并区域平移到象限坐标系后的边界 */
    private static void shifted(Merge merge, Quadrant quadrant, RectF out) {
        out.set(merge.bounds);
        out.offset(quadrant.translateX, quadrant.translateY);
    }

    private void drawCells(Canvas canvas, Quadrant quadrant, boolean bordersOnly) {
        int firstRow = startIndex(rows, body.top - quadrant.translateY, quadrant.startRow);
        for (int r = firstRow; r < rows.visible.length; r++) {
            int row = rows.visible[r];
            if (row >= quadrant.endRow) break;
            float rowTop = rows.offsets[row] + quadrant.translateY;
            float rowBottom = rows.offsets[row + 1] + quadrant.translateY;
            if (rowTop >= body.bottom) break;
            if (rowBottom <= body.top) continue;
            int column = columnAtOrAfter(quadrant.startColumn);
            for (int i = layout.firstCell(row, column); i < layout.rowStarts[row + 1]; i++) {
                SpreadsheetDocument.Cell cell = sheet.cells.get(i);
                if (cell.column >= quadrant.endColumn) break;
                if (cell.column + 1 >= columns.offsets.length) break;
                if (layout.mergedCells[i] || sheet.columnWidths[cell.column] == 0) continue;
                float left = columns.offsets[cell.column] + quadrant.translateX;
                float right = columns.offsets[cell.column + 1] + quadrant.translateX;
                if (left >= body.right) break;
                if (right <= body.left) continue;
                cellBounds.set(left, rowTop, right, rowBottom);
                if (bordersOnly) drawBorders(canvas, cellBounds, style(cell));
                else drawCell(canvas, cell, cellBounds);
            }
        }
    }

    /** 象限起始列在文档坐标系下的实际列号（跳过隐藏列） */
    private int columnAtOrAfter(int docColumn) {
        int index = firstVisibleIndex(columns.visible, docColumn);
        return index < columns.visible.length ? columns.visible[index] : docColumn;
    }

    /**
     * 可见索引起点：同时受滚动位置与象限下界约束。
     * 两者取较大者，既避免从表头开始逐行扫描，也保证不越过象限边界。
     */
    private static int startIndex(SheetLayout.Axis axis, float position, int minIndex) {
        return Math.max(axis.first(position), firstVisibleIndex(axis.visible, minIndex));
    }

    /** 在升序可见索引中二分出第一个 >= target 的位置 */
    private static int firstVisibleIndex(int[] visible, int target) {
        int low = 0, high = visible.length;
        while (low < high) {
            int middle = (low + high) >>> 1;
            if (visible[middle] < target) low = middle + 1;
            else high = middle;
        }
        return low;
    }

    private void drawGrid(Canvas canvas, Quadrant quadrant) {
        paint.setColor(GRID_COLOR); paint.setStyle(Paint.Style.STROKE); paint.setStrokeWidth(.5f);
        for (int r = startIndex(rows, body.top - quadrant.translateY, quadrant.startRow); r < rows.visible.length; r++) {
            int row = rows.visible[r];
            if (row >= quadrant.endRow) break;
            float y = rows.offsets[row + 1] + quadrant.translateY;
            if (y < body.top) continue;
            if (y > body.bottom) break;
            canvas.drawLine(body.left, y, body.right, y, paint);
        }
        for (int c = startIndex(columns, body.left - quadrant.translateX, quadrant.startColumn); c < columns.visible.length; c++) {
            int column = columns.visible[c];
            if (column >= quadrant.endColumn) break;
            float x = columns.offsets[column + 1] + quadrant.translateX;
            if (x < body.left) continue;
            if (x > body.right) break;
            canvas.drawLine(x, body.top, x, body.bottom, paint);
        }
    }

    /**
     * 合并单元格：按行分桶定位与象限行区间相交的候选，代际去重按象限独立推进，
     * 使跨冻结边界的合并区域在每个象限各自平移并裁剪绘制。
     */
    private void drawMerges(Canvas canvas, Quadrant quadrant) {
        if (mergeBuckets == null || mergeBuckets.length == 0 || rows == null || rows.visible.length == 0) return;
        // 与象限可见行区间求交集后再定位行桶，避免大表冻结时每帧扫描整表所有合并桶
        int firstIdx = startIndex(rows, body.top - quadrant.translateY, quadrant.startRow);
        if (firstIdx >= rows.visible.length) return;
        int firstRow = rows.visible[firstIdx];
        if (firstRow >= quadrant.endRow) return;
        int lastIdx = Math.min(rows.visible.length - 1, rows.first(body.bottom - quadrant.translateY));
        int lastRow = Math.min(quadrant.endRow - 1, rows.visible[Math.max(firstIdx, lastIdx)]);
        if (lastRow < firstRow) return;
        int startBucket = Math.max(0, firstRow / BUCKET_ROW_SIZE);
        int endBucket = Math.min(mergeBuckets.length - 1, lastRow / BUCKET_ROW_SIZE);
        int currentGen = ++renderGen;
        if (currentGen == 0) {
            currentGen = renderGen = 1;
            for (Merge merge : merges) merge.lastSeenGen = 0;
        }
        for (int b = startBucket; b <= endBucket; b++) {
            List<Merge> bucket = mergeBuckets[b];
            for (int i = 0; i < bucket.size(); i++) {
                Merge merge = bucket.get(i);
                if (merge.lastSeenGen == currentGen) continue;
                merge.lastSeenGen = currentGen;
                if (merge.bounds.isEmpty()) continue;
                // 行区间与列区间都要和象限相交，避免同一象限内画出界外的合并
                if (merge.endRow < quadrant.startRow || merge.startRow >= quadrant.endRow) continue;
                shifted(merge, quadrant, shiftedBounds);
                if (!RectF.intersects(body, shiftedBounds)) continue;
                visibleMerges.add(merge);
                fill(canvas, shiftedBounds, 0xffffffff);
                if (merge.anchor != null) drawCell(canvas, merge.anchor, shiftedBounds);
                stroke(canvas, shiftedBounds, GRID_COLOR, .5f);
            }
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
        if ("superscript".equals(style.vertAlign)) {
            y += (int) (layout.getPaint().ascent() * 0.35f);
        } else if ("subscript".equals(style.vertAlign)) {
            y += (int) (layout.getPaint().descent() * 0.35f);
        }
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
        font.setTypeface(OfficeTextLayout.resolveTypeface(style.fontFace, typeface, 0));
        font.setStrikeThruText(style.strike);
        if ("superscript".equals(style.vertAlign) || "subscript".equals(style.vertAlign)) {
            font.setTextSize(Math.max(1f, style.fontSize * 0.65f));
        }
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

    /**
     * 表头分段绘制：可滚动段随内容滚动，冻结段锁定；
     * 左上角交汇块最后覆盖，保持背景与边框干净。
     */
    private void drawHeaders(Canvas canvas, RectF viewport) {
        float left = plan.scrollX, top = plan.scrollY;
        float headerRight = left + HEADER_WIDTH, headerBottom = top + HEADER_HEIGHT;
        // 表头底板
        cellBounds.set(left, top, viewport.right, headerBottom);
        fill(canvas, cellBounds, HEADER_COLOR);
        cellBounds.set(left, top, headerRight, viewport.bottom);
        fill(canvas, cellBounds, HEADER_COLOR);

        headerFont.setTextAlign(Paint.Align.CENTER);
        // 可滚动列头：[frozenRight..viewport.right]
        int save = canvas.save();
        canvas.clipRect(Math.max(headerRight, plan.frozenRight), top, viewport.right, headerBottom);
        for (int c = startIndex(columns, viewport.left, plan.effectiveColumns); c < columns.visible.length; c++) {
            int column = columns.visible[c];
            float x = columns.offsets[column];
            if (x >= viewport.right) break;
            cellBounds.set(x, top, columns.offsets[column + 1], headerBottom);
            header(canvas, columnName(column), cellBounds, cellBounds.centerX());
        }
        canvas.restoreToCount(save);
        // 冻结列头：[frozenOriginX..frozenRight]，X 锁定
        if (plan.effectiveColumns > 0) {
            save = canvas.save();
            canvas.clipRect(plan.frozenOriginX, top, plan.frozenRight, headerBottom);
            for (int c = 0; c < columns.visible.length; c++) {
                int column = columns.visible[c];
                if (column >= plan.effectiveColumns) break;
                float x = columns.offsets[column] + plan.scrollX;
                cellBounds.set(x, top, columns.offsets[column + 1] + plan.scrollX, headerBottom);
                header(canvas, columnName(column), cellBounds, cellBounds.centerX());
            }
            canvas.restoreToCount(save);
        }

        headerFont.setTextAlign(Paint.Align.RIGHT);
        // 可滚动行头：[frozenBottom..viewport.bottom]
        save = canvas.save();
        canvas.clipRect(left, Math.max(headerBottom, plan.frozenBottom), headerRight, viewport.bottom);
        for (int r = startIndex(rows, viewport.top, plan.effectiveRows); r < rows.visible.length; r++) {
            int row = rows.visible[r];
            float y = rows.offsets[row];
            if (y >= viewport.bottom) break;
            cellBounds.set(left, y, headerRight, rows.offsets[row + 1]);
            header(canvas, Integer.toString(row + 1), cellBounds, headerRight - 6);
        }
        canvas.restoreToCount(save);
        // 冻结行头：[frozenOriginY..frozenBottom]，Y 锁定
        if (plan.effectiveRows > 0) {
            save = canvas.save();
            canvas.clipRect(left, plan.frozenOriginY, headerRight, plan.frozenBottom);
            for (int r = 0; r < rows.visible.length; r++) {
                int row = rows.visible[r];
                if (row >= plan.effectiveRows) break;
                float y = rows.offsets[row] + plan.scrollY;
                cellBounds.set(left, y, headerRight, rows.offsets[row + 1] + plan.scrollY);
                header(canvas, Integer.toString(row + 1), cellBounds, headerRight - 6);
            }
            canvas.restoreToCount(save);
        }

        // 左上角交汇块与表头分隔线
        cellBounds.set(left, top, headerRight, headerBottom);
        fill(canvas, cellBounds, HEADER_COLOR);
        paint.setColor(HEADER_SEPARATOR_COLOR); paint.setStyle(Paint.Style.STROKE); paint.setStrokeWidth(.75f);
        canvas.drawLine(headerRight, top, headerRight, viewport.bottom, paint);
        canvas.drawLine(left, headerBottom, viewport.right, headerBottom, paint);
    }

    /**
     * 冻结交界线：沿冻结边界从表头起点延伸至正文右下边界，画在正文与表头之上。
     * 线宽 1px，颜色区别于普通网格线与表头分隔线。
     */
    private void drawFreezeDivider(Canvas canvas, RectF viewport) {
        if (plan.effectiveColumns <= 0 && plan.effectiveRows <= 0) return;
        paint.setColor(FREEZE_DIVIDER_COLOR);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(1);
        if (plan.effectiveColumns > 0) {
            // 纵向分割线：从表头顶部（含表头区域）延伸到正文下边界
            canvas.drawLine(plan.frozenRight, plan.scrollY, plan.frozenRight,
                Math.min(plan.bodyMaxBottom, viewport.bottom), paint);
        }
        if (plan.effectiveRows > 0) {
            // 横向分割线：从表头左边界延伸到正文右边界
            canvas.drawLine(plan.scrollX, plan.frozenBottom,
                Math.min(plan.bodyMaxRight, viewport.right), plan.frozenBottom, paint);
        }
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

    /** 单帧冻结几何（文档坐标系，与绘制 viewport 同一套坐标） */
    static final class FreezePlan {
        int effectiveRows, effectiveColumns, rowCount, columnCount;
        float scrollX, scrollY;
        float frozenOriginX, frozenOriginY, frozenDataWidth, frozenDataHeight;
        float frozenRight, frozenBottom, bodyMaxRight, bodyMaxBottom;

        boolean hasFrozen() { return effectiveRows > 0 || effectiveColumns > 0; }
    }

    /** 四象限之一：行列区间、平移量与裁剪区域 */
    static final class Quadrant {
        final int startRow, endRow, startColumn, endColumn;
        final float translateX, translateY;
        final float clipLeft, clipTop, clipRight, clipBottom;

        Quadrant(int startRow, int endRow, int startColumn, int endColumn,
                 float translateX, float translateY,
                 float clipLeft, float clipTop, float clipRight, float clipBottom) {
            this.startRow = startRow; this.endRow = endRow;
            this.startColumn = startColumn; this.endColumn = endColumn;
            this.translateX = translateX; this.translateY = translateY;
            this.clipLeft = clipLeft; this.clipTop = clipTop;
            this.clipRight = clipRight; this.clipBottom = clipBottom;
        }

        boolean isEmpty() { return clipRight <= clipLeft || clipBottom <= clipTop || endRow <= startRow || endColumn <= startColumn; }
    }

    private static final class Merge {
        final RectF bounds = new RectF();
        SpreadsheetDocument.Cell anchor;
        int startRow, endRow;
        int lastSeenGen;
    }
}
