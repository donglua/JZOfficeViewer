package cn.jingzhuan.lib.office;

import static cn.jingzhuan.lib.office.PptxRenderingChecks.check;
import static cn.jingzhuan.lib.office.PptxRenderingChecks.color;
import static cn.jingzhuan.lib.office.PptxRenderingChecks.near;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.RectF;
import android.net.Uri;
import java.io.IOException;
import java.io.File;
import java.io.FileOutputStream;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

final class PptxTableChecks {
    private static final int BACKGROUND = 0xff191d20;
    private static final int HEADER_FILL = 0x333d8f8a;

    private PptxTableChecks() { }

    static String run(OfficeInstrumentation instrumentation) throws Exception {
        Context context = instrumentation.getTargetContext();
        decoderCellFills(context);
        instrumentation.runOnMainChecked(() -> {
            capturePptx(context);
            emptyDocxCellFillsStayTransparent();
            mergedTableHighlightSkipsCoveredCells(context);
            bulletParagraphHighlightOffsets(context);
        });
        return "PASS PPTX table cell fills, transparent body cells and DOCX empty cellFills compatibility\n"
            + "SCREENSHOTS pptx-table-synthetic.png\n";
    }

    private static void capturePptx(Context context) throws Exception {
        OfficeDocument document = new OfficeDocument();
        document.kind = OfficeDocument.Kind.PPTX;
        document.width = 320;
        OfficeDocument.Page page = new OfficeDocument.Page();
        page.width = 320;
        page.height = 220;
        page.background = BACKGROUND;
        document.pages.add(page);

        int[][] alphaTable = new int[][] {
            {HEADER_FILL, HEADER_FILL, HEADER_FILL},
            {0x00ffffff, 0x00ffffff, 0x00ffffff},
            {0x00ffffff, 0x00ffffff, 0x00ffffff},
            {0x00ffffff, 0x00ffffff, 0x00ffffff},
            {0x00ffffff, 0x00ffffff, 0x00ffffff}
        };
        page.elements.add(table(10, 10, 300, 100, alphaTable));

        int[][] colorTable = new int[][] {
            {Color.RED, Color.GREEN},
            {Color.BLUE, Color.YELLOW}
        };
        page.elements.add(table(10, 130, 120, 60, colorTable));

        OfficeRenderer renderer = new OfficeRenderer();
        renderer.layout(document);
        OfficeRenderer.Page rendered = renderer.pages.get(0);
        Bitmap bitmap = Bitmap.createBitmap(Math.round(rendered.width), Math.round(rendered.height), Bitmap.Config.ARGB_8888);
        try {
            renderer.draw(new Canvas(bitmap), 0, rendered.height, Collections.emptyMap());
            nearColor(bitmap, 60, 20, blendOver(HEADER_FILL, BACKGROUND), 2, "Header alpha fill blends over dark slide");
            color(bitmap, 60, 40, BACKGROUND, "Transparent body cell preserves dark slide background");
            color(bitmap, 40, 145, Color.RED, "First row first column fill");
            color(bitmap, 100, 145, Color.GREEN, "First row second column fill");
            color(bitmap, 40, 160, Color.BLUE, "Second row first column fill");
            color(bitmap, 100, 160, Color.YELLOW, "Second row second column fill");
            File file = new File(context.getFilesDir(), "pptx-table-synthetic.png");
            try (FileOutputStream output = new FileOutputStream(file)) {
                check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output), "Saved " + file.getName());
            }
        } finally {
            bitmap.recycle();
        }
    }

    private static void decoderCellFills(Context context) throws Exception {
        Uri uri = Uri.parse("content://" + context.getPackageName() + ".fixtures/sample.pptx");
        try (OfficePackage source = OfficePackage.open(context, uri)) {
            JSONObject root = new JSONObject(NativeCore.parse(source.file.getAbsolutePath()));
            JSONObject table = firstTable(root);
            JSONArray rows = table.getJSONArray("rows");
            JSONArray fills = fillsFor(rows);
            table.put("cellFills", fills);
            OfficeDocument decoded = DocumentDecoder.decode(root.toString());
            OfficeDocument.Element decodedTable = firstTable(decoded);
            check(!decodedTable.cellFills.isEmpty(), "Decoder reads injected table cellFills");
            check(decodedTable.cellFills.get(0).get(0) == HEADER_FILL, "Decoder preserves header fill color");
            if (decodedTable.cellFills.size() > 1) {
                check(decodedTable.cellFills.get(1).get(0) == 0x00ffffff, "Decoder preserves transparent body fill");
            }

            JSONObject badColumns = new JSONObject(root.toString());
            JSONArray badColumnFills = new JSONArray(fills.toString());
            badColumnFills.getJSONArray(0).put(HEADER_FILL);
            firstTable(badColumns).put("cellFills", badColumnFills);
            reject(badColumns, "Mismatched table fill columns rejected");

            JSONObject badRows = new JSONObject(root.toString());
            JSONArray badRowFills = new JSONArray(fills.toString());
            badRowFills.put(new JSONArray());
            firstTable(badRows).put("cellFills", badRowFills);
            reject(badRows, "Mismatched table fill rows rejected");
        }
    }

    private static void emptyDocxCellFillsStayTransparent() {
        OfficeDocument document = new OfficeDocument();
        document.kind = OfficeDocument.Kind.DOCX;
        document.width = 200;
        document.marginLeft = 32;
        document.marginRight = 32;
        document.blocks.add(table(0, 0, 120, 40, null));
        OfficeRenderer renderer = new OfficeRenderer();
        renderer.layout(document);
        float[] origin = {0, 0};
        renderer.pages.get(0).elements.get(0).transform.mapPoints(origin);
        near(origin[0], 32, 0.001f, "DOCX layout still adds its horizontal margin");
        near(origin[1], 32, 0.001f, "DOCX layout still adds its vertical margin");
        Bitmap bitmap = Bitmap.createBitmap(200, 120, Bitmap.Config.ARGB_8888);
        try {
            renderer.draw(new Canvas(bitmap), 0, renderer.height, Collections.emptyMap());
            color(bitmap, 50, 45, Color.WHITE, "DOCX table with empty cellFills keeps transparent cells");
        } finally {
            bitmap.recycle();
        }
    }

    private static OfficeDocument.Element table(float x, float y, float width, float height, int[][] fills) {
        OfficeDocument.Element table = new OfficeDocument.Element();
        table.type = OfficeDocument.Type.TABLE;
        table.x = x;
        table.y = y;
        table.transform = new float[] {1, 0, 0, 1, x, y};
        table.width = width;
        table.height = height;
        int rows = fills == null ? 1 : fills.length;
        int columns = fills == null ? 1 : fills[0].length;
        for (int column = 0; column < columns; column++) table.columnWidths.add(1f);
        for (int row = 0; row < rows; row++) {
            List<List<OfficeDocument.Paragraph>> cells = new ArrayList<>();
            List<Integer> cellFills = new ArrayList<>();
            for (int column = 0; column < columns; column++) {
                cells.add(Collections.emptyList());
                if (fills != null) cellFills.add(fills[row][column]);
            }
            table.rows.add(cells);
            if (fills != null) table.cellFills.add(cellFills);
        }
        return table;
    }

    private static JSONArray fillsFor(JSONArray rows) throws Exception {
        JSONArray fills = new JSONArray();
        for (int row = 0; row < rows.length(); row++) {
            JSONArray cells = rows.getJSONArray(row);
            JSONArray rowFills = new JSONArray();
            for (int column = 0; column < cells.length(); column++) {
                rowFills.put(row == 0 ? HEADER_FILL : 0x00ffffff);
            }
            fills.put(rowFills);
        }
        return fills;
    }

    private static JSONObject firstTable(JSONObject root) throws Exception {
        JSONArray pages = root.getJSONArray("pages");
        for (int page = 0; page < pages.length(); page++) {
            JSONArray elements = pages.getJSONObject(page).getJSONArray("elements");
            for (int i = 0; i < elements.length(); i++) {
                JSONObject element = elements.getJSONObject(i);
                if ("TABLE".equals(element.getString("type"))) return element;
            }
        }
        throw new AssertionError("Missing sample PPTX table element");
    }

    private static OfficeDocument.Element firstTable(OfficeDocument document) {
        for (OfficeDocument.Page page : document.pages) {
            for (OfficeDocument.Element element : page.elements) {
                if (element.type == OfficeDocument.Type.TABLE) return element;
            }
        }
        throw new AssertionError("Missing decoded PPTX table element");
    }

    private static void reject(JSONObject root, String label) throws Exception {
        try {
            DocumentDecoder.decode(root.toString());
        } catch (IOException expected) {
            check("Invalid core display model".equals(expected.getMessage()), label);
            return;
        }
        throw new AssertionError(label + " accepted");
    }

    private static int blendOver(int source, int destination) {
        int alpha = Color.alpha(source);
        int inverse = 255 - alpha;
        return Color.rgb(
            (Color.red(source) * alpha + Color.red(destination) * inverse + 127) / 255,
            (Color.green(source) * alpha + Color.green(destination) * inverse + 127) / 255,
            (Color.blue(source) * alpha + Color.blue(destination) * inverse + 127) / 255);
    }

    private static void nearColor(Bitmap bitmap, int x, int y, int expected, int tolerance, String label) {
        int actual = bitmap.getPixel(x, y);
        check(Color.alpha(actual) == 255
            && Math.abs(Color.red(actual) - Color.red(expected)) <= tolerance
            && Math.abs(Color.green(actual) - Color.green(expected)) <= tolerance
            && Math.abs(Color.blue(actual) - Color.blue(expected)) <= tolerance,
            label + " at " + x + "," + y + " expected #" + Integer.toHexString(expected)
                + " actual #" + Integer.toHexString(actual));
    }

    private static void mergedTableHighlightSkipsCoveredCells(Context context) {
        OfficeDocument document = new OfficeDocument();
        document.kind = OfficeDocument.Kind.PPTX;
        document.width = 400;
        OfficeDocument.Page page = new OfficeDocument.Page();
        page.width = 400;
        page.height = 300;
        document.pages.add(page);

        OfficeDocument.Element table = new OfficeDocument.Element();
        table.type = OfficeDocument.Type.TABLE;
        table.x = 10;
        table.y = 10;
        table.width = 300;
        table.height = 100;
        table.transform = new float[] {1, 0, 0, 1, 10, 10};
        table.columnWidths.add(100f);
        table.columnWidths.add(100f);
        table.columnWidths.add(100f);

        // Row 0:
        // Col 0: "Merged Header" (merges 0,0 -> 0,1)
        // Col 1: "Covered Row0Col1" (covered cell with dummy paragraph)
        // Col 2: "Col2"
        // Row 1:
        // Col 0: "Row1Col0"
        // Col 1: "TargetCell"
        // Col 2: "LastCell"
        List<OfficeDocument.Paragraph> p00 = makeParagraph("Merged Header");
        List<OfficeDocument.Paragraph> p01 = makeParagraph("Covered Row0Col1");
        List<OfficeDocument.Paragraph> p02 = makeParagraph("Col2");
        List<OfficeDocument.Paragraph> p10 = makeParagraph("Row1Col0");
        List<OfficeDocument.Paragraph> p11 = makeParagraph("TargetCell");
        List<OfficeDocument.Paragraph> p12 = makeParagraph("LastCell");

        List<List<OfficeDocument.Paragraph>> row0 = new ArrayList<>();
        row0.add(p00);
        row0.add(p01);
        row0.add(p02);
        List<List<OfficeDocument.Paragraph>> row1 = new ArrayList<>();
        row1.add(p10);
        row1.add(p11);
        row1.add(p12);
        table.rows.add(row0);
        table.rows.add(row1);

        SpreadsheetDocument.CellRange merge = new SpreadsheetDocument.CellRange();
        merge.startRow = 0;
        merge.startColumn = 0;
        merge.endRow = 0;
        merge.endColumn = 1;
        table.merges.add(merge);
        page.elements.add(table);

        OfficeRenderer renderer = new OfficeRenderer();
        renderer.layout(document);
        OfficeRenderer.Element renderedTable = renderer.pages.get(0).elements.get(0);
        check(renderedTable.texts.size() == 5, "Renderer skips covered table cell, texts.size == 5");

        OfficePreviewView previewView = new OfficePreviewView(context);

        // Covered cell (0, 1) should return empty highlight rects because it has no layout block
        OfficePreviewView.SearchMatch coveredMatch = new OfficePreviewView.SearchMatch(
            0, 0, 0, 0, 1, 0, 7, "Covered"
        );
        List<RectF> coveredRects = previewView.elementHighlightRects(renderedTable, coveredMatch, 0);
        check(coveredRects.isEmpty(), "Covered cell should not have highlight rects");

        // LastCell is at row 1, col 2, paragraphIndex 0.
        // Before fix: targetBlockIndex becomes 5 (due to covered cell not skipped), which is >= texts.size() (5),
        // causing lastRects to be empty!
        OfficePreviewView.SearchMatch lastMatch = new OfficePreviewView.SearchMatch(
            0, 0, 0, 1, 2, 0, 4, "Last"
        );
        List<RectF> lastRects = previewView.elementHighlightRects(renderedTable, lastMatch, 0);
        check(!lastRects.isEmpty(), "Highlight rects should not be empty for last cell in table");

        // TargetCell is at row 1, col 1, paragraphIndex 0 (x coordinate around 10 + 100 = 110)
        // Before fix: targetBlockIndex wrongly points to block index 4 (LastCell), so its rect.left would be ~210 instead of ~110
        OfficePreviewView.SearchMatch targetMatch = new OfficePreviewView.SearchMatch(
            0, 0, 0, 1, 1, 0, 6, "Target"
        );
        List<RectF> targetRects = previewView.elementHighlightRects(renderedTable, targetMatch, 0);
        check(!targetRects.isEmpty(), "Highlight rects should not be empty for TargetCell");
        check(targetRects.get(0).left < 150f, "TargetCell highlight x should be in column 1 (left < 150)");
    }

    private static void bulletParagraphHighlightOffsets(Context context) {
        OfficeDocument document = new OfficeDocument();
        document.kind = OfficeDocument.Kind.PPTX;
        document.width = 400;
        OfficeDocument.Page page = new OfficeDocument.Page();
        page.width = 400;

        OfficeDocument.Element box = new OfficeDocument.Element();
        box.type = OfficeDocument.Type.TEXT;
        box.x = 20;
        box.y = 20;
        box.width = 300;
        box.height = 100;
        box.transform = new float[] {1, 0, 0, 1, 20, 20};

        OfficeDocument.Paragraph para = new OfficeDocument.Paragraph();
        para.bullet = "1. ";
        OfficeDocument.Run run = new OfficeDocument.Run();
        run.size = 14;
        run.text = "Hi";
        para.runs.add(run);
        box.paragraphs.add(para);

        page.elements.add(box);
        document.pages.add(page);

        OfficeRenderer renderer = new OfficeRenderer();
        renderer.layout(document);
        OfficeRenderer.Element renderedBox = renderer.pages.get(0).elements.get(0);

        OfficePreviewView previewView = new OfficePreviewView(context);

        // In core search, rendered text is "1. Hi".
        // Match for "Hi" is startChar=3, endChar=5.
        // If bulletLen (3) is erroneously added again, the range becomes [6, 5] (clamped to [5, 5]),
        // which makes highlight rects empty!
        OfficePreviewView.SearchMatch hiMatch = new OfficePreviewView.SearchMatch(
            0, 0, 0, -1, -1, 3, 5, "Hi"
        );
        List<RectF> hiRects = previewView.elementHighlightRects(renderedBox, hiMatch, 0);
        check(!hiRects.isEmpty(), "Highlight rects for run text in bullet paragraph should not be empty");

        // Match for bullet "1." is startChar=0, endChar=2.
        OfficePreviewView.SearchMatch bulletMatch = new OfficePreviewView.SearchMatch(
            0, 0, 0, -1, -1, 0, 2, "1."
        );
        List<RectF> bulletRects = previewView.elementHighlightRects(renderedBox, bulletMatch, 0);
        check(!bulletRects.isEmpty(), "Highlight rects for bullet text should not be empty");
        check(bulletRects.get(0).right <= hiRects.get(0).left + 1f,
            "Bullet highlight should precede run text highlight horizontally");
    }

    private static List<OfficeDocument.Paragraph> makeParagraph(String text) {
        OfficeDocument.Paragraph paragraph = new OfficeDocument.Paragraph();
        OfficeDocument.Run run = new OfficeDocument.Run();
        run.size = 12;
        run.text = text;
        paragraph.runs.add(run);
        return Collections.singletonList(paragraph);
    }
}
