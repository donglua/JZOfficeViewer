package cn.jingzhuan.lib.office;

import static cn.jingzhuan.lib.office.PptxRenderingChecks.check;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.RectF;
import android.net.Uri;
import android.os.SystemClock;
import android.text.StaticLayout;
import android.view.MotionEvent;
import java.io.File;
import java.io.FileOutputStream;
import java.lang.reflect.Field;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

final class LongCellChecks {
    private static final String WARNING = "Long spreadsheet cell text is truncated in the preview";

    private LongCellChecks() { }

    static String run(OfficeInstrumentation instrumentation, PreviewTestActivity activity) throws Exception {
        File source = fixture(activity);
        StringBuilder results = new StringBuilder();
        try {
            try (OfficePackage document = OfficePackage.open(activity, Uri.fromFile(source))) {
                check(document.document.warnings.contains(WARNING), "JNI model reports long-cell preview limit");
                check(java.util.Collections.frequency(document.document.warnings, WARNING) == 1,
                    "Long-cell warning is deduplicated");
                for (int i = 0; i < 6; i++) {
                    String cellText = document.document.sheets.get(0).cells.get(i).text;
                    check(cellText.length() == 4096 && cellText.endsWith("\u2026"),
                        "Inline/shared/cached formula cell text is bounded in core: " + i);
                }
                instrumentation.runOnMainChecked(() -> {
                    SheetRenderer renderer = new SheetRenderer();
                    renderer.setSheet(document.document.sheets.get(0), document.document.cellStyles);
                    Bitmap bitmap = Bitmap.createBitmap(320, 480, Bitmap.Config.ARGB_8888);
                    try {
                        long start = SystemClock.uptimeMillis();
                        renderer.draw(new Canvas(bitmap), new RectF(0, 0, 320, 480));
                        long elapsed = SystemClock.uptimeMillis() - start;
                        check(elapsed < 2000, "Six long cells draw within 2 seconds: " + elapsed + " ms");
                        check(SheetTextChecks.layouts(renderer).size() == 6, "Every long-cell source and wrap mode was drawn");
                        for (Object value : SheetTextChecks.layouts(renderer).values()) {
                            check(((StaticLayout) value).getText().length() <= 4096, "JNI cells use bounded layout input");
                        }
                        save(activity, bitmap, "xlsx-long-cells-canvas");
                        results.append("PASS six 262145-character inline/shared/cached-formula cells; first draw=")
                            .append(elapsed).append(" ms\n");
                    } finally { bitmap.recycle(); renderer.clear(); }
                });
            }
            CountDownLatch loaded = new CountDownLatch(1);
            AtomicReference<OfficePreviewView.Info> info = new AtomicReference<>();
            AtomicReference<Exception> error = new AtomicReference<>();
            instrumentation.runOnMainChecked(() -> activity.preview.open(Uri.fromFile(source), new OfficePreviewView.Listener() {
                @Override public void onLoaded(OfficePreviewView.Info value) { info.set(value); loaded.countDown(); }
                @Override public void onError(Exception value) { error.set(value); loaded.countDown(); }
            }));
            check(loaded.await(10, TimeUnit.SECONDS), "Long-cell XLSX URI load completes");
            if (error.get() != null) throw error.get();
            check(info.get() != null && "XLSX".equals(info.get().format) && info.get().warnings.contains(WARNING),
                "Public load callback exposes preview truncation warning");
            instrumentation.runOnMainChecked(() -> {
                OfficePreviewView view = activity.preview;
                Bitmap bitmap = Bitmap.createBitmap(view.getWidth(), view.getHeight(), Bitmap.Config.ARGB_8888);
                try {
                    long start = SystemClock.uptimeMillis();
                    view.draw(new Canvas(bitmap));
                    check(SystemClock.uptimeMillis() - start < 2000, "Real preview draw returns within 2 seconds");
                    save(activity, bitmap, "xlsx-long-cells-window");
                    view.setZoom(2);
                    long down = SystemClock.uptimeMillis();
                    for (int i = 0; i <= 6; i++) {
                        int action = i == 0 ? MotionEvent.ACTION_DOWN : i == 6 ? MotionEvent.ACTION_CANCEL : MotionEvent.ACTION_MOVE;
                        MotionEvent event = MotionEvent.obtain(down, down + i * 20, action, 500, 1000 - Math.min(i, 5) * 120, 0);
                        try { view.dispatchTouchEvent(event); } finally { event.recycle(); }
                    }
                    check(view.canScrollVertically(-1), "Long-cell preview responds to drag");
                    view.draw(new Canvas(bitmap));
                    view.jumpToPage(1);
                    check(!view.canScrollVertically(-1), "Return to sheet top resets scroll");
                    view.resetZoom(); view.draw(new Canvas(bitmap));
                    Field field = OfficePreviewView.class.getDeclaredField("sheetRenderer"); field.setAccessible(true);
                    for (Object value : SheetTextChecks.layouts((SheetRenderer) field.get(view)).values()) {
                        check(((StaticLayout) value).getText().length() <= 4096, "Scroll and return retain bounded layouts");
                    }
                } finally { bitmap.recycle(); }
            });
            instrumentation.waitForIdleSync();
            instrumentation.getUiAutomation().waitForIdle(100, 3000);
            Bitmap screenshot = instrumentation.getUiAutomation().takeScreenshot();
            check(screenshot != null, "Long-cell preview window screenshot is available");
            try { save(activity, screenshot, "screen-xlsx-long-cells"); }
            finally { screenshot.recycle(); }
            results.append("PASS long-cell XLSX URI/JNI, warning callback, draw, zoom, drag and return\n");
            return results.toString();
        } finally {
            instrumentation.runOnMainSync(activity.preview::clear);
            source.delete();
        }
    }

    private static File fixture(PreviewTestActivity activity) throws Exception {
        String text = SheetTextChecks.repeat('W', 262145);
        StringBuilder rows = new StringBuilder();
        for (int i = 0; i < 6; i++) {
            String value = i < 2 ? " t=\"inlineStr\"><is><t>" + text + "</t></is>"
                : i < 4 ? " t=\"s\"><v>0</v>" : " t=\"str\"><f>\"cached\"</f><v>" + text + "</v>";
            rows.append("<row r=\"").append(i + 1).append("\" ht=\"60\"><c r=\"A").append(i + 1)
                .append("\" s=\"").append(i % 2).append("\"").append(value).append("</c></row>");
        }
        rows.append("<row r=\"60\"><c r=\"A60\" t=\"inlineStr\"><is><t>END</t></is></c></row>");
        return CompatibilityChecks.document(activity, "long-cells", "xl/workbook.xml", new String[][] {
            {"xl/workbook.xml", "<workbook xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
                + "<sheets><sheet name=\"Long text\" sheetId=\"1\" r:id=\"sheet\"/></sheets></workbook>"},
            {"xl/_rels/workbook.xml.rels", CompatibilityChecks.relationships("sheet", "worksheet", "worksheets/sheet.xml",
                "style", "styles", "styles.xml", "strings", "sharedStrings", "sharedStrings.xml")},
            {"xl/styles.xml", "<styleSheet><fonts><font><sz val=\"11\"/></font></fonts><cellXfs>"
                + "<xf fontId=\"0\"><alignment wrapText=\"0\"/></xf>"
                + "<xf fontId=\"0\"><alignment wrapText=\"1\"/></xf></cellXfs></styleSheet>"},
            {"xl/sharedStrings.xml", "<sst><si><t>" + text + "</t></si></sst>"},
            {"xl/worksheets/sheet.xml", "<worksheet><sheetFormatPr defaultColWidth=\"32\" defaultRowHeight=\"60\"/>"
                + "<sheetData>" + rows + "</sheetData></worksheet>"}
        });
    }

    private static void save(PreviewTestActivity activity, Bitmap bitmap, String name) throws Exception {
        try (FileOutputStream out = new FileOutputStream(new File(activity.getFilesDir(), name + ".png"))) {
            check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, out), "Saved " + name);
        }
    }
}
