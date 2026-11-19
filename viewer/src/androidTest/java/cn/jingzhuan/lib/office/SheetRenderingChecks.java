package cn.jingzhuan.lib.office;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Rect;
import android.graphics.RectF;
import android.text.StaticLayout;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import org.json.JSONObject;

final class SheetRenderingChecks {
    private SheetRenderingChecks() { }

    static String run() throws Exception { return run(null); }

    static String run(Context context) throws Exception {
        StringBuilder log = new StringBuilder("SHEET RENDERING CHECKS\n");
        checkDecoder();
        log.append("PASS schema9 styles, hidden dimensions, sparse cells, ranges and invalid-model rejection\n");
        checkMergedViewport(context);
        log.append("PASS offscreen merged anchor, hidden rows/columns, merged grid suppression and pinned headers\n");
        checkText();
        log.append("PASS wrap, explicit multiline, numeric alignment, font styling and text clipping\n");
        checkCache();
        log.append("PASS visible-only layout, bounded cache, sheet replacement and clear\n");
        checkFreezePanes();
        log.append("PASS frozen rows/columns stay locked under scroll, freeze divider, cross-boundary merges and 75% viewport degradation\n");
        log.append(SheetTextChecks.run());
        return log.append("SHEET RENDERING CHECKS PASSED\n").toString();
    }

    private static void checkDecoder() throws Exception {
        String json = "{\"schemaVersion\":9,\"kind\":\"XLSX\",\"width\":595,\"warnings\":[],\"blocks\":[],\"pages\":[],"
            + "\"cellStyles\":[{\"fontSize\":13,\"bold\":true,\"italic\":true,\"underline\":true,\"color\":4279385946,"
            + "\"fill\":4294967295,\"alignment\":3,\"verticalAlignment\":\"BOTTOM\",\"wrap\":true,"
            + "\"borders\":[4278190335,null,4278190335,null]}],"
            + "\"sheets\":[{\"name\":\"Sheet 1\",\"rowHeights\":[28,0,36],\"columnWidths\":[80,0,100],"
            + "\"cells\":[{\"row\":0,\"column\":0,\"text\":\"123.45\",\"style\":0,\"numeric\":true}],"
            + "\"merges\":[{\"startRow\":0,\"startColumn\":0,\"endRow\":2,\"endColumn\":2}]}]}";
        OfficeDocument document = DocumentDecoder.decode(json);
        SpreadsheetDocument.Sheet sheet = document.sheets.get(0);
        SpreadsheetDocument.CellStyle style = document.cellStyles.get(0);
        check(document.kind == OfficeDocument.Kind.XLSX && sheet.name.equals("Sheet 1"), "Spreadsheet kind and name");
        check(sheet.rowHeights[1] == 0 && sheet.columnWidths[1] == 0, "Hidden dimensions are retained");
        check(sheet.cells.size() == 1 && sheet.cells.get(0).numeric && sheet.cells.get(0).text.equals("123.45"), "Sparse numeric text");
        check(style.fill == Color.WHITE && style.bold && style.italic && style.underline && style.wrap, "Cell style flags and unsigned color");
        check(style.borders[0] == Color.BLUE && style.borders[1] == null, "Optional borders");
        check(sheet.merges.get(0).endRow == 2 && sheet.merges.get(0).endColumn == 2, "Inclusive merged range");

        JSONObject invalid = new JSONObject(json);
        invalid.getJSONArray("sheets").getJSONObject(0).getJSONArray("cells").getJSONObject(0).put("style", 1);
        reject(invalid, "Out-of-range style");
        invalid = new JSONObject(json);
        invalid.getJSONArray("sheets").getJSONObject(0).getJSONArray("cells").getJSONObject(0).put("row", .5);
        reject(invalid, "Fractional coordinate");
        invalid = new JSONObject(json);
        invalid.getJSONArray("sheets").getJSONObject(0).getJSONArray("rowHeights").put(0, -1);
        reject(invalid, "Negative dimension");
        invalid = new JSONObject(json);
        invalid.getJSONArray("sheets").getJSONObject(0).getJSONArray("merges").getJSONObject(0).put("endColumn", 3);
        reject(invalid, "Out-of-range merge");
        invalid = new JSONObject(json);
        invalid.getJSONArray("sheets").getJSONObject(0).getJSONArray("cells")
            .put(invalid.getJSONArray("sheets").getJSONObject(0).getJSONArray("cells").getJSONObject(0));
        reject(invalid, "Duplicate coordinate");
        invalid = new JSONObject(json).put("schemaVersion", 3);
        reject(invalid, "Unsupported schema");
        invalid = new JSONObject(json).put("sheets", new org.json.JSONArray());
        reject(invalid, "XLSX without sheets");
        invalid = new JSONObject(json).put("cellStyles", new org.json.JSONArray());
        reject(invalid, "XLSX without styles");
        for (String kind : new String[] {"DOCX", "PPTX"}) {
            JSONObject root = new JSONObject(json).put("kind", kind);
            root.put("sheets", new org.json.JSONArray()); root.put("cellStyles", new org.json.JSONArray());
            OfficeDocument legacy = DocumentDecoder.decode(root.toString());
            check(legacy.kind.name().equals(kind) && legacy.sheets.isEmpty() && legacy.cellStyles.isEmpty(), kind + " schema9 decode");
        }
    }

    private static void reject(JSONObject source, String label) throws Exception {
        try { DocumentDecoder.decode(source.toString()); throw new AssertionError(label + " accepted"); }
        catch (IOException expected) { }
    }

    private static void checkMergedViewport(Context context) throws Exception {
        SpreadsheetDocument.Sheet sheet = new SpreadsheetDocument.Sheet();
        sheet.rowHeights = new float[] {28, 0, 36, 30, 70};
        sheet.columnWidths = new float[] {80, 0, 100, 70, 90};
        SpreadsheetDocument.Cell anchor = cell(0, 0, "MERGED", 0);
        sheet.cells.add(anchor);
        sheet.cells.add(cell(1, 3, "HIDDEN ROW", 1));
        sheet.cells.add(cell(2, 2, "COVERED", 1));
        sheet.cells.add(cell(4, 1, "HIDDEN COLUMN", 1));
        SpreadsheetDocument.CellRange range = new SpreadsheetDocument.CellRange();
        range.endRow = 3; range.endColumn = 2; sheet.merges.add(range);
        SpreadsheetDocument.CellStyle merged = new SpreadsheetDocument.CellStyle();
        merged.fontSize = 13; merged.bold = true; merged.italic = true; merged.underline = true;
        merged.color = 0xff123f5a; merged.fill = 0xffffe49a; merged.alignment = 2;
        Arrays.fill(merged.borders, Color.BLUE);
        SpreadsheetDocument.CellStyle hidden = new SpreadsheetDocument.CellStyle(); hidden.fill = Color.RED;
        SheetRenderer renderer = new SheetRenderer();
        renderer.setSheet(sheet, Arrays.asList(merged, hidden));
        check(renderer.width == 382 && renderer.height == 184, "Dimensions exclude hidden rows and columns and include gutters");
        check(cache(renderer).isEmpty(), "Selecting sheet does not layout offscreen text");
        RectF viewport = new RectF(130, 60, 350, 180);
        Bitmap bitmap = render(renderer, viewport);
        try {
            assertColor(bitmap, 50, 24, merged.fill, 0, "Merged fill suppresses internal row grid after anchor leaves viewport");
            assertColor(bitmap, 10, 10, 0xfff3f5f7, 0, "Pinned header corner");
            assertColor(bitmap, 50, 2, 0xfff3f5f7, 0, "Pinned column header");
            assertColor(bitmap, 2, 30, 0xfff3f5f7, 0, "Pinned row header");
            assertColor(bitmap, 91, 30, Color.BLUE, 140, "Merged right border");
            check(!ink(bitmap, 43, 33, 90, 54).isEmpty(), "Merged anchor text remains visible");
            check(cache(renderer).size() == 1 && cache(renderer).containsKey(anchor), "Hidden and covered cells have no text layouts");
            if (context != null) {
                try (FileOutputStream output = new FileOutputStream(new File(context.getFilesDir(), "sheet-merged-scrolled.png"))) {
                    check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output), "Saved merged viewport screenshot");
                }
            }
        } finally { bitmap.recycle(); }
        SpreadsheetDocument.Sheet allHidden = new SpreadsheetDocument.Sheet();
        allHidden.rowHeights = new float[] {0}; allHidden.columnWidths = new float[] {0};
        renderer.setSheet(allHidden, Collections.singletonList(merged));
        check(renderer.width == SheetRenderer.HEADER_WIDTH && renderer.height == SheetRenderer.HEADER_HEIGHT, "All-hidden dimensions");
        bitmap = render(renderer, new RectF(0, 0, 160, 120)); bitmap.recycle();
        SpreadsheetDocument.Sheet hiddenMerge = new SpreadsheetDocument.Sheet();
        hiddenMerge.rowHeights = new float[] {30, 0, 30}; hiddenMerge.columnWidths = new float[] {100};
        hiddenMerge.cells.add(cell(1, 0, "HIDDEN", 0));
        SpreadsheetDocument.CellRange hiddenRange = new SpreadsheetDocument.CellRange();
        hiddenRange.startRow = hiddenRange.endRow = 1; hiddenMerge.merges.add(hiddenRange);
        Arrays.fill(hidden.borders, Color.RED);
        renderer.setSheet(hiddenMerge, Collections.singletonList(hidden));
        bitmap = render(renderer, new RectF(0, 0, 160, 120));
        try {
            int boundary = bitmap.getPixel(80, 49);
            check(Color.red(boundary) - Color.green(boundary) < 20, "Zero-height merged cell has no visible border");
        } finally { bitmap.recycle(); }
    }

    private static void checkText() throws Exception {
        SpreadsheetDocument.Sheet sheet = new SpreadsheetDocument.Sheet();
        sheet.rowHeights = new float[] {85, 85, 85, 85}; sheet.columnWidths = new float[] {120};
        List<SpreadsheetDocument.CellStyle> styles = new ArrayList<>();
        for (int i = 0; i < 4; i++) {
            SpreadsheetDocument.CellStyle style = new SpreadsheetDocument.CellStyle();
            style.fontSize = 12; style.color = Color.BLACK; style.verticalAlignment = OfficeDocument.VerticalAlignment.TOP;
            styles.add(style);
        }
        styles.get(1).wrap = true; styles.get(1).alignment = 1;
        styles.get(2).bold = true; styles.get(2).italic = true; styles.get(2).underline = true;
        styles.get(3).verticalAlignment = OfficeDocument.VerticalAlignment.BOTTOM;
        String words = "ONE TWO THREE FOUR FIVE SIX";
        sheet.cells.add(cell(0, 0, words, 0)); sheet.cells.add(cell(1, 0, words, 1));
        sheet.cells.add(cell(2, 0, "FIRST\nSECOND", 2)); sheet.cells.add(cell(3, 0, "123", 3));
        sheet.cells.get(3).numeric = true;
        SheetRenderer renderer = new SheetRenderer(); renderer.setSheet(sheet, styles);
        Bitmap bitmap = render(renderer, new RectF(0, 0, 190, 370));
        try {
            StaticLayout nowrap = (StaticLayout) cache(renderer).get(sheet.cells.get(0));
            StaticLayout wrap = (StaticLayout) cache(renderer).get(sheet.cells.get(1));
            StaticLayout multiline = (StaticLayout) cache(renderer).get(sheet.cells.get(2));
            check(nowrap.getLineCount() == 1 && nowrap.getWidth() > 116, "Non-wrapped text keeps natural width");
            check(wrap.getLineCount() > 1 && wrap.getWidth() == 116, "Wrapped text uses column width");
            check(multiline.getLineCount() == 2, "Explicit newline is retained without wrapping");
            check(multiline.getPaint().isUnderlineText() && multiline.getPaint().getTypeface().isBold()
                && multiline.getPaint().getTypeface().isItalic(), "Typeface and underline styles");
            check(ink(bitmap, 164, 22, 189, 100).isEmpty(), "Long text does not leak outside its cell");
            Rect numeric = ink(bitmap, 44, 277, 160, 359);
            check(!numeric.isEmpty() && numeric.left > 130 && numeric.bottom > 350, "Numeric general alignment is right and bottom");
        } finally { bitmap.recycle(); }
    }

    private static void checkCache() throws Exception {
        SpreadsheetDocument.Sheet sheet = new SpreadsheetDocument.Sheet();
        sheet.rowHeights = new float[10000]; Arrays.fill(sheet.rowHeights, 20);
        sheet.columnWidths = new float[100]; Arrays.fill(sheet.columnWidths, 60);
        for (int row = 0; row < 10000; row++) {
            sheet.cells.add(cell(row, 0, "R" + row, 0));
            sheet.cells.add(cell(row, 99, "OFFSCREEN" + row, 0));
        }
        SheetRenderer renderer = new SheetRenderer();
        List<SpreadsheetDocument.CellStyle> styles = Collections.singletonList(new SpreadsheetDocument.CellStyle());
        renderer.setSheet(sheet, styles);
        Bitmap bitmap = render(renderer, new RectF(0, 0, 240, 240)); bitmap.recycle();
        check(cache(renderer).size() > 0 && cache(renderer).size() <= 11, "Only visible rows and columns get layouts");
        for (Object key : cache(renderer).keySet()) check(((SpreadsheetDocument.Cell) key).column == 0, "Offscreen column is not laid out");
        Object firstLayout = cache(renderer).get(sheet.cells.get(0));
        bitmap = render(renderer, new RectF(0, 0, 240, 240)); bitmap.recycle();
        check(firstLayout == cache(renderer).get(sheet.cells.get(0)), "Stable cell reuses its cached layout");
        for (int row = 200; row < 9600; row += 200) {
            bitmap = render(renderer, new RectF(0, row * 20, 240, row * 20 + 240)); bitmap.recycle();
        }
        check(cache(renderer).size() <= 256 && cache(renderer).size() > 200, "Cache retains a bounded scrolling working set");
        check(!cache(renderer).containsKey(sheet.cells.get(0)), "Oldest layout is evicted");
        SpreadsheetDocument.Sheet large = new SpreadsheetDocument.Sheet();
        large.rowHeights = new float[] {60}; large.columnWidths = new float[] {180};
        char[] text = new char[256 * 1024 + 1]; Arrays.fill(text, 'W');
        large.cells.add(cell(0, 0, new String(text), 0));
        SpreadsheetDocument.CellStyle wrap = new SpreadsheetDocument.CellStyle(); wrap.wrap = true;
        renderer.setSheet(large, Collections.singletonList(wrap));
        check(cache(renderer).isEmpty(), "Sheet replacement discards all cached layouts");
        long started = android.os.SystemClock.uptimeMillis();
        bitmap = render(renderer, new RectF(0, 0, 240, 120)); bitmap.recycle();
        long elapsed = android.os.SystemClock.uptimeMillis() - started;
        StaticLayout preview = (StaticLayout) cache(renderer).get(large.cells.get(0));
        check(preview != null && preview.getText().length() <= 4096,
            "Long cell uses a bounded cached preview; first draw took " + elapsed + " ms");
        check(large.cells.get(0).text.length() == text.length, "Preview keeps the original cell text");
        bitmap = render(renderer, new RectF(0, 0, 240, 120)); bitmap.recycle();
        check(cache(renderer).get(large.cells.get(0)) == preview, "Long cell redraw reuses bounded layout");
        renderer.clear();
        check(renderer.width == 0 && renderer.height == 0 && cache(renderer).isEmpty(), "Clear releases dimensions and text layouts");
    }

    /**
     * 冻结窗格：带滚动偏移的视口下冻结首行/首列仍锁定在表头右侧/下侧，
     * 冻结交界线存在，跨冻结边界的合并单元格在四个象限各自裁剪绘制，
     * 高倍缩放（可用正文区不足）时按轴独立降级。
     */
    private static void checkFreezePanes() throws Exception {
        SpreadsheetDocument.Sheet sheet = new SpreadsheetDocument.Sheet();
        sheet.rowHeights = new float[] {30, 30, 30, 30};
        sheet.columnWidths = new float[] {80, 80, 80, 80};
        sheet.frozenRows = 1;
        sheet.frozenColumns = 1;
        // 四个象限各放一色单元格：交叉角红、冻结行绿、冻结列蓝、滚动区黄
        sheet.cells.add(cell(0, 0, "", 0));
        sheet.cells.add(cell(0, 1, "", 1));
        sheet.cells.add(cell(2, 0, "", 2));
        sheet.cells.add(cell(2, 1, "", 3));
        List<SpreadsheetDocument.CellStyle> styles = new ArrayList<>();
        for (int fill : new int[] {Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW}) {
            SpreadsheetDocument.CellStyle style = new SpreadsheetDocument.CellStyle();
            style.fill = fill;
            styles.add(style);
        }
        SheetRenderer renderer = new SheetRenderer();
        renderer.setSheet(sheet, styles);

        // 视口已向右滚动 60、向下滚动 40，视口 200x160
        RectF viewport = new RectF(60, 40, 260, 200);
        // 冻结几何：存在 core 前缀和可直接差值得到冻结区尺寸
        RectF planViewport = new RectF(viewport.left, viewport.top, viewport.right, viewport.bottom);
        SheetRenderer.FreezePlan plan = SheetRenderer.computePlan(sheet, renderer.layout.columns,
            renderer.layout.rows, renderer.width, renderer.height, planViewport);
        check(plan.effectiveRows == 1 && plan.effectiveColumns == 1, "Frozen row and column stay effective");
        check(plan.frozenDataWidth == 80 && plan.frozenDataHeight == 30, "Frozen size from core prefix sums");
        check(plan.frozenRight == 42 + 60 + 80 && plan.frozenBottom == 20 + 40 + 30, "Frozen boundary anchored to headers plus scroll");
        check(SheetRenderer.quadrants(plan).size() == 4, "Cross freeze splits body into four quadrants");

        Bitmap bitmap = render(renderer, viewport);
        try {
            // 交叉角：(0,0) 锁定在表头右下方，左右两侧都被裁剪
            assertColor(bitmap, 82, 35, Color.RED, 0, "Cross freeze corner cell stays locked");
            // 冻结行：(0,1) 只在水平方向随滚动移动，仍占据顶部条带
            assertColor(bitmap, 130, 35, Color.GREEN, 0, "Frozen row keeps its top band while scrolled horizontally");
            // 冻结列：(2,0) 只在垂直方向随滚动移动，仍占据左侧条带
            assertColor(bitmap, 82, 60, Color.BLUE, 0, "Frozen column keeps its left band while scrolled vertically");
            // 滚动区：(2,1) 双轴随滚动，且严格裁剪在冻结边界之外
            assertColor(bitmap, 130, 60, Color.YELLOW, 0, "Scrolling region content follows both axes outside frozen area");
            // 冻结交界线：竖线位于 x = frozenRight - viewport.left
            // 冻结交界线：文档坐标 frozenRight -> 屏幕 x = frozenRight - viewport.left
            int dividerX = Math.round(plan.frozenRight - viewport.left);
            check(hasColorNear(bitmap, dividerX, 60, 0xff9aa5b1, 70),
                "Freeze divider drawn along the frozen column boundary at screen x=" + dividerX);
            // 横向分割线：文档坐标 frozenBottom -> 屏幕 y = frozenBottom - viewport.top
            int dividerY = Math.round(plan.frozenBottom - viewport.top);
            check(hasColorNear(bitmap, 150, dividerY, 0xff9aa5b1, 70),
                "Freeze divider drawn along the frozen row boundary at screen y=" + dividerY);
        } finally { bitmap.recycle(); }

        // 未冻结时同样的滚动视口看不到第 0 行（说明上面的锁定确实来自冻结，而非视口巧合）
        SpreadsheetDocument.Sheet plain = new SpreadsheetDocument.Sheet();
        plain.rowHeights = new float[] {30, 30, 30, 30};
        plain.columnWidths = new float[] {80, 80, 80, 80};
        plain.cells.add(cell(0, 0, "", 0));
        plain.cells.add(cell(2, 0, "", 2));
        renderer.setSheet(plain, styles);
        bitmap = render(renderer, viewport);
        try {
            check(!hasColorNear(bitmap, 82, 35, Color.RED, 40), "Unfrozen sheet scrolls the first row out of view");
        } finally { bitmap.recycle(); }

        // 跨冻结边界的合并单元格：合并 0..2 行 × 0..2 列，四象限都应绘制到锚点填充
        SpreadsheetDocument.Sheet merged = new SpreadsheetDocument.Sheet();
        merged.rowHeights = new float[] {30, 30, 30, 30};
        merged.columnWidths = new float[] {80, 80, 80, 80};
        merged.frozenRows = 1; merged.frozenColumns = 1;
        merged.cells.add(cell(0, 0, "", 0));
        SpreadsheetDocument.CellRange range = new SpreadsheetDocument.CellRange();
        range.endRow = 2; range.endColumn = 2;
        merged.merges.add(range);
        renderer.setSheet(merged, styles);
        bitmap = render(renderer, viewport);
        try {
            assertColor(bitmap, 82, 35, Color.RED, 0, "Cross-boundary merge painted in the corner quadrant");
            assertColor(bitmap, 130, 35, Color.RED, 0, "Cross-boundary merge painted in the frozen row quadrant");
            assertColor(bitmap, 82, 60, Color.RED, 0, "Cross-boundary merge painted in the frozen column quadrant");
            assertColor(bitmap, 130, 60, Color.RED, 0, "Cross-boundary merge painted in the scrolling quadrant");
        } finally { bitmap.recycle(); }

        // 视口占比保护：视口高度 35 → 可用正文高 15，冻结区 30 > 15*0.75，行冻结降级而列冻结保留
        RectF shortViewport = new RectF(60, 40, 260, 75);
        SheetRenderer.FreezePlan degraded = SheetRenderer.computePlan(merged, renderer.layout.columns,
            renderer.layout.rows, renderer.width, renderer.height, shortViewport);
        check(degraded.effectiveRows == 0 && degraded.effectiveColumns == 1,
            "Frozen rows degrade independently when they exceed 75% of the available body height");
        check(degraded.frozenDataHeight == 0 && degraded.frozenDataWidth == 80,
            "Degraded axis reports zero frozen size while the other axis is unchanged");
        check(SheetRenderer.quadrants(degraded).size() == 2,
            "Degraded plan only keeps the still-frozen axis quadrants");
        bitmap = render(renderer, shortViewport);
        bitmap.recycle();

        // 验证 computeCurrentPlan 不受上一帧缓存 viewport 影响，且大表跨桶合并仅绘制可见桶后仍完整显示
        SheetRenderer.FreezePlan freshPlan = renderer.computeCurrentPlan(new RectF(60, 40, 260, 200));
        check(freshPlan.effectiveRows == 1 && freshPlan.effectiveColumns == 1,
            "computeCurrentPlan recomputes from the given viewport instead of reusing stale cached plan");
        SpreadsheetDocument.Sheet tallMerged = new SpreadsheetDocument.Sheet();
        tallMerged.rowHeights = new float[80];
        java.util.Arrays.fill(tallMerged.rowHeights, 20);
        tallMerged.columnWidths = new float[] {80, 80};
        tallMerged.frozenRows = 1;
        tallMerged.cells.add(cell(60, 1, "", 0));
        SpreadsheetDocument.CellRange spanRange = new SpreadsheetDocument.CellRange();
        spanRange.startRow = 60; spanRange.endRow = 70;
        spanRange.startColumn = 1; spanRange.endColumn = 1;
        tallMerged.merges.add(spanRange);
        renderer.setSheet(tallMerged, styles);
        bitmap = render(renderer, new RectF(0, 1300, 200, 1460));
        try {
            assertColor(bitmap, 130, 80, Color.RED, 0, "Multi-bucket merge overlapping scrolled visible rows still renders");
        } finally { bitmap.recycle(); }

        // 冻结选区绘制与屏幕包围框：滚动超出冻结格原始位置后，冻结角选区仍必须正常绘制与定位
        SpreadsheetDocument.Sheet selectionSheet = new SpreadsheetDocument.Sheet();
        selectionSheet.rowHeights = new float[] {30, 30, 30, 30};
        selectionSheet.columnWidths = new float[] {80, 80, 80, 80};
        selectionSheet.frozenRows = 1;
        selectionSheet.frozenColumns = 1;
        renderer.setSheet(selectionSheet, styles);
        renderer.setSelection(new SheetSelectionModel.SheetSelection(new SheetSelectionModel.CellCoord(0, 0)));
        RectF scrolledViewport = new RectF(100, 60, 300, 220);
        Bitmap selectionBitmap = Bitmap.createBitmap(200, 160, Bitmap.Config.ARGB_8888);
        Canvas selectionCanvas = new Canvas(selectionBitmap);
        selectionCanvas.drawColor(Color.WHITE);
        selectionCanvas.translate(-scrolledViewport.left, -scrolledViewport.top);
        renderer.draw(selectionCanvas, scrolledViewport);
        renderer.drawSelection(selectionCanvas, scrolledViewport, 1.5f);
        try {
            int frozenCornerPixel = selectionBitmap.getPixel(82, 35);
            check(Color.blue(frozenCornerPixel) > Color.red(frozenCornerPixel),
                "Frozen corner selection renders even when viewport scrolled past unshifted cell: "
                    + Integer.toHexString(frozenCornerPixel));
        } finally { selectionBitmap.recycle(); }

        // 屏幕包围框（scaled header 与冻结段保留）
        float[] scaledClamp = OfficePreviewView.computeSheetScreenSpan(
            0, 0, 42f, 122f, 0, 42f, 42f, 20f * 3f, 3f, 1080f);
        check(scaledClamp != null && Math.round(scaledClamp[0]) == 126 && Math.round(scaledClamp[1]) == 306,
            "Screen span clamps to scaled header width instead of unscaled 42px");
        float[] frozenPinned = OfficePreviewView.computeSheetScreenSpan(
            0, 0, 42f, 122f, 1, 42f, 122f, 800f, 2f, 1080f);
        check(frozenPinned != null && Math.round(frozenPinned[0]) == 84 && Math.round(frozenPinned[1]) == 244,
            "Frozen cell keeps visible screen span under large scroll");
        float[] hiddenBehindFrozen = OfficePreviewView.computeSheetScreenSpan(
            1, 1, 122f, 202f, 1, 42f, 122f, 200f, 1f, 1080f);
        check(hiddenBehindFrozen == null,
            "Scrollable cell tucked completely behind frozen pane yields null screen span");
    }

    /** 在给定坐标附近的小邻域内查找目标颜色（容忍抗锯齿与 1px 描边落点） */
    private static boolean hasColorNear(Bitmap bitmap, int x, int y, int expected, int tolerance) {
        for (int dy = -2; dy <= 2; dy++) {
            for (int dx = -2; dx <= 2; dx++) {
                int px = x + dx, py = y + dy;
                if (px < 0 || py < 0 || px >= bitmap.getWidth() || py >= bitmap.getHeight()) continue;
                int actual = bitmap.getPixel(px, py);
                if (Math.abs(Color.red(actual) - Color.red(expected)) <= tolerance
                    && Math.abs(Color.green(actual) - Color.green(expected)) <= tolerance
                    && Math.abs(Color.blue(actual) - Color.blue(expected)) <= tolerance) return true;
            }
        }
        return false;
    }

    private static SpreadsheetDocument.Cell cell(int row, int column, String text, int style) {
        SpreadsheetDocument.Cell cell = new SpreadsheetDocument.Cell();
        cell.row = row; cell.column = column; cell.text = text; cell.style = style;
        return cell;
    }

    private static Map<?, ?> cache(SheetRenderer renderer) throws Exception {
        Field field = SheetRenderer.class.getDeclaredField("layouts"); field.setAccessible(true);
        return (Map<?, ?>) field.get(renderer);
    }

    private static Bitmap render(SheetRenderer renderer, RectF viewport) {
        Bitmap bitmap = Bitmap.createBitmap((int) viewport.width(), (int) viewport.height(), Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap); canvas.drawColor(Color.WHITE);
        canvas.translate(-viewport.left, -viewport.top); renderer.draw(canvas, viewport);
        return bitmap;
    }

    private static Rect ink(Bitmap bitmap, int left, int top, int right, int bottom) {
        Rect bounds = new Rect(right, bottom, left, top);
        for (int y = top; y < bottom; y++) for (int x = left; x < right; x++) {
            int color = bitmap.getPixel(x, y);
            if (Color.red(color) < 100 && Color.green(color) < 130 && Color.blue(color) < 170) {
                bounds.left = Math.min(bounds.left, x); bounds.top = Math.min(bounds.top, y);
                bounds.right = Math.max(bounds.right, x + 1); bounds.bottom = Math.max(bounds.bottom, y + 1);
            }
        }
        return bounds;
    }

    private static void assertColor(Bitmap bitmap, int x, int y, int expected, int tolerance, String label) {
        int actual = bitmap.getPixel(x, y);
        check(Math.abs(Color.red(actual) - Color.red(expected)) <= tolerance
            && Math.abs(Color.green(actual) - Color.green(expected)) <= tolerance
            && Math.abs(Color.blue(actual) - Color.blue(expected)) <= tolerance,
            label + " actual=" + Integer.toHexString(actual));
    }

    private static void check(boolean condition, String label) {
        if (!condition) throw new AssertionError(label);
    }
}
