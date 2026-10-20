package cn.jingzhuan.lib.office;

import android.app.Activity;
import android.app.Instrumentation;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.net.Uri;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.os.SystemClock;
import android.view.MotionEvent;
import android.view.View;
import java.io.File;
import java.io.FileOutputStream;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

public final class OfficeInstrumentation extends Instrumentation {
    private PreviewTestActivity activity;
    private final StringBuilder results = new StringBuilder();
    private boolean layoutOnly, limitsOnly, imagesOnly, xlsxOnly, demoOnly, pptxOnly, pathsOnly, tablesOnly, backgroundsOnly;
    private boolean demoSamplesOnly, sheetLayoutOnly, pptxGeometryOnly, pptxLayoutOnly, imageCacheOnly;
    private boolean compatibilityOnly, xlsxTextOnly, accessibilityOnly;

    @Override public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        compatibilityOnly = arguments != null && "compatibility".equals(arguments.getString("suite"));
        xlsxTextOnly = arguments != null && "xlsx-text".equals(arguments.getString("suite"));
        accessibilityOnly = arguments != null && "accessibility".equals(arguments.getString("suite"));
        layoutOnly = arguments != null && "layout".equals(arguments.getString("suite"));
        limitsOnly = arguments != null && "limits".equals(arguments.getString("suite"));
        imagesOnly = arguments != null && "images".equals(arguments.getString("suite"));
        imageCacheOnly = arguments != null && "image-cache".equals(arguments.getString("suite"));
        xlsxOnly = arguments != null && "xlsx".equals(arguments.getString("suite"));
        xlsxTextOnly = arguments != null && "xlsx-text".equals(arguments.getString("suite"));
        demoOnly = arguments != null && "demo-xlsx".equals(arguments.getString("suite"));
        demoSamplesOnly = arguments != null && "demo-samples".equals(arguments.getString("suite"));
        sheetLayoutOnly = arguments != null && "sheet-layout".equals(arguments.getString("suite"));
        pptxOnly = arguments != null && "pptx".equals(arguments.getString("suite"));
        pptxGeometryOnly = arguments != null && "pptx-geometry".equals(arguments.getString("suite"));
        pptxLayoutOnly = arguments != null && "pptx-layout".equals(arguments.getString("suite"));
        pathsOnly = arguments != null && "paths".equals(arguments.getString("suite"));
        tablesOnly = arguments != null && "tables".equals(arguments.getString("suite"));
        backgroundsOnly = arguments != null && "backgrounds".equals(arguments.getString("suite"));
        start();
    }
    @Override public void onStart() {
        Bundle output = new Bundle();
        try {
            if (sheetLayoutOnly) {
                results.append(SheetLayoutChecks.run());
                results.append(SheetLayoutBenchmark.run("SheetLayout", sheet -> SheetLayoutBenchmark.prepareLayout(sheet,
                    SheetRenderer.HEADER_WIDTH, SheetRenderer.HEADER_HEIGHT)));
                runOnMainChecked(() -> results.append(SheetRenderingChecks.run(getTargetContext())));
                SheetRenderer renderer = new SheetRenderer();
                java.util.List<SpreadsheetDocument.CellStyle> styles = java.util.Collections.singletonList(new SpreadsheetDocument.CellStyle());
                AtomicLong elapsed = new AtomicLong();
                results.append(SheetLayoutBenchmark.run("SheetRenderer.setSheet on main thread", sheet -> {
                    runOnMainSync(() -> {
                        long start = System.nanoTime();
                        renderer.setSheet(sheet, styles);
                        elapsed.set(System.nanoTime() - start);
                    });
                    return elapsed.get();
                }));
                runOnMainSync(renderer::clear);
                output.putString("stream", "\n" + results + "ALL SHEET LAYOUT CHECKS PASSED\n");
                finish(Activity.RESULT_OK, output);
                return;
            }
            if (demoSamplesOnly) {
                results.append(DemoSampleChecks.run(this));
                output.putString("stream", "\n" + results + "ALL DEMO SAMPLE CHECKS PASSED\n");
                finish(Activity.RESULT_OK, output);
                return;
            }
            if (pptxGeometryOnly) {
                results.append(PptxRenderingChecks.runGeometry(this));
                results.append(PptxPathChecks.run(this));
                results.append(PptxTableChecks.run(this));
                results.append(PptxBackgroundChecks.run(this));
                output.putString("stream", "\n" + results + "ALL PPTX GEOMETRY CHECKS PASSED\n");
                finish(Activity.RESULT_OK, output);
                return;
            }
            if (backgroundsOnly) {
                results.append(PptxBackgroundChecks.run(this));
                output.putString("stream", "\n" + results + "ALL BACKGROUND CHECKS PASSED\n");
                finish(Activity.RESULT_OK, output);
                return;
            }
            if (tablesOnly) {
                results.append(PptxTableChecks.run(this));
                output.putString("stream", "\n" + results + "ALL TABLE CHECKS PASSED\n");
                finish(Activity.RESULT_OK, output);
                return;
            }
            if (pathsOnly) {
                results.append(PptxPathChecks.run(this));
                output.putString("stream", "\n" + results + "ALL PATH CHECKS PASSED\n");
                finish(Activity.RESULT_OK, output);
                return;
            }
            if (demoOnly) {
                results.append(DemoSpreadsheetChecks.run(this));
                output.putString("stream", "\n" + results + "ALL DEMO XLSX CHECKS PASSED\n");
                finish(Activity.RESULT_OK, output);
                return;
            }
            if (!layoutOnly && !imagesOnly && !imageCacheOnly && !xlsxOnly && !xlsxTextOnly && !pptxOnly && !pptxLayoutOnly && !compatibilityOnly && !accessibilityOnly) {
                results.append(PackageOpeningChecks.run(getTargetContext()));
                results.append(PackageLimitChecks.run(getTargetContext()));
            }
            if (limitsOnly) {
                output.putString("stream", "\n" + results + "ALL LIMIT CHECKS PASSED\n");
                finish(Activity.RESULT_OK, output);
                return;
            }
            ActivityMonitor monitor = addMonitor(PreviewTestActivity.class.getName(), null, false);
            String component = getTargetContext().getPackageName() + "/" + PreviewTestActivity.class.getName();
            try (ParcelFileDescriptor command = getUiAutomation().executeShellCommand("am start -n " + component);
                 ParcelFileDescriptor.AutoCloseInputStream stream = new ParcelFileDescriptor.AutoCloseInputStream(command)) {
                byte[] buffer = new byte[1024];
                while (stream.read(buffer) != -1) { }
            }
            activity = (PreviewTestActivity) waitForMonitorWithTimeout(monitor, 10000);
            removeMonitor(monitor);
            check(activity != null, "Test activity starts");
            if (xlsxTextOnly) {
                runOnMainChecked(() -> results.append(SheetRenderingChecks.run(getTargetContext())));
                results.append(LongCellChecks.run(this, activity));
                runOnMainSync(() -> activity.finish());
                output.putString("stream", "\n" + results + "ALL XLSX TEXT CHECKS PASSED\n");
                finish(Activity.RESULT_OK, output);
                return;
            }
            if (accessibilityOnly) {
                results.append(AccessibilityChecks.run(this, activity));
                runOnMainSync(() -> activity.finish());
                output.putString("stream", "\n" + results + "ALL ACCESSIBILITY CHECKS PASSED\n");
                finish(Activity.RESULT_OK, output);
                return;
            }
            if (compatibilityOnly) {
                results.append(CompatibilityChecks.run(this, activity));
                runOnMainSync(() -> activity.finish());
                output.putString("stream", "\n" + results + "ALL COMPATIBILITY CHECKS PASSED\n");
                finish(Activity.RESULT_OK, output);
                return;
            }
            if (pptxLayoutOnly || pptxOnly) results.append(PptxLayoutChecks.run(this, activity));
            if (pptxLayoutOnly) {
                runOnMainSync(() -> activity.finish());
                output.putString("stream", "\n" + results + "ALL PPTX LAYOUT CHECKS PASSED\n");
                finish(Activity.RESULT_OK, output);
                return;
            }
            if (pptxOnly) {
                results.append(PptxCompatibilityChecks.run(this, activity));
                results.append(PptxPathChecks.run(this));
                results.append(PptxTableChecks.run(this));
                results.append(PptxBackgroundChecks.run(this));
                results.append(PptxChartChecks.run(this, activity));
                results.append(PptxColorChecks.run(this, activity));
                runOnMainSync(() -> activity.finish());
                output.putString("stream", "\n" + results + "ALL PPTX CHECKS PASSED\n");
                finish(Activity.RESULT_OK, output);
                return;
            }
            if (!layoutOnly && !imagesOnly && !imageCacheOnly) {
                results.append(SheetLayoutChecks.run());
                runOnMainChecked(() -> results.append(SheetRenderingChecks.run(getTargetContext())));
                results.append(SpreadsheetChecks.run(this, activity));
                results.append(LongCellChecks.run(this, activity));
            }
            if (xlsxOnly) {
                runOnMainSync(() -> activity.finish());
                output.putString("stream", "\n" + results + "ALL XLSX CHECKS PASSED\n");
                finish(Activity.RESULT_OK, output);
                return;
            }
            if (!layoutOnly) results.append(ImageCacheChecks.run(this, activity));
            if (imageCacheOnly) {
                runOnMainSync(() -> activity.finish());
                output.putString("stream", "\n" + results + "ALL IMAGE CACHE CHECKS PASSED\n");
                finish(Activity.RESULT_OK, output);
                return;
            }
            if (!layoutOnly) {
                results.append(ImageQualityChecks.run(this, activity));
                results.append(ImageMemoryChecks.run(this, activity));
            }
            if (imagesOnly) {
                runOnMainSync(() -> activity.finish());
                output.putString("stream", "\n" + results + "ALL IMAGE CHECKS PASSED\n");
                finish(Activity.RESULT_OK, output);
                return;
            }
            runOnMainChecked(() -> results.append(RenderingChecks.run(getTargetContext())));
            captureLayoutFixtures();
            pageNavigation();
            if (layoutOnly) {
                runOnMainSync(() -> activity.finish());
                output.putString("stream", "\n" + results + "ALL LAYOUT CHECKS PASSED\n");
                finish(Activity.RESULT_OK, output);
                return;
            }
            load("sample.docx", "DOCX");
            captureScreen("screen-docx");
            capture("docx-portrait", 1080, 1600);
            capture("docx-landscape", 1800, 1000);
            load("sample.pptx", "PPTX");
            captureScreen("screen-pptx");
            doubleTap();
            check(activity.preview.getZoom() == 2, "Double tap changes zoom");
            captureScreen("screen-pptx-zoom");
            runOnMainSync(() -> activity.preview.resetZoom());
            capture("pptx-portrait", 1080, 1600);
            capture("pptx-landscape", 1800, 1000);
            runOnMainSync(() -> activity.preview.setZoom(2));
            check(activity.preview.getZoom() == 2, "Zoom changes scale");
            capture("pptx-zoom", 1080, 1600);
            expectError("broken");
            expectError("missing");
            rapidReplacement();
            runOnMainSync(() -> activity.preview.clear());
            awaitCacheCleanup();
            File[] cache = new File(getTargetContext().getCacheDir(), "office-preview").listFiles();
            check(cache != null && cache.length == 0, "Temporary document files removed");
            runOnMainSync(() -> activity.finish());
            output.putString("stream", "\n" + results + "ALL CHECKS PASSED\n");
            finish(Activity.RESULT_OK, output);
        } catch (Exception | AssertionError failure) {
            output.putString("stream", "\n" + results + "FAILED: " + android.util.Log.getStackTraceString(failure));
            finish(Activity.RESULT_CANCELED, output);
        }
    }

    private Uri uri(String name) { return Uri.parse("content://" + getTargetContext().getPackageName() + ".fixtures/" + name); }

    private void captureLayoutFixtures() throws Exception {
        File docx = LayoutFixtures.docx(getTargetContext().getCacheDir());
        File pptx = LayoutFixtures.pptx(getTargetContext().getCacheDir());
        try {
            load(Uri.fromFile(docx), "DOCX");
            captureScreen("screen-layout-docx");
            load(Uri.fromFile(pptx), "PPTX");
            captureScreen("screen-layout-pptx");
            runOnMainChecked(() -> { activity.preview.setZoom(3); activity.preview.jumpToPage(2); });
            captureScreen("screen-layout-pptx-page2");
        } finally { docx.delete(); pptx.delete(); }
    }

    private void pageNavigation() throws Exception {
        java.util.List<String> events = new java.util.ArrayList<>();
        runOnMainChecked(() -> {
            OfficePreviewView view = activity.preview;
            view.clear();
            view.setOnPageChangeListener((page, count) -> events.add(page + "/" + count));
            check(events.equals(java.util.Collections.singletonList("0/0")), "Empty page state delivered on listener registration");
            try { view.jumpToPage(1); throw new AssertionError("Empty jump accepted"); }
            catch (IllegalArgumentException expected) { }
        });
        load("sample.pptx", "PPTX");
        runOnMainChecked(() -> {
            OfficePreviewView view = activity.preview;
            view.layout(0, 0, 0, 0);
            view.jumpToPage(2);
            check(view.getCurrentPage() == 2, "Jump before layout stores requested page");
            view.layout(0, 0, 1080, 900);
            check(view.getCurrentPage() == 2, "First layout applies requested page");
        });
        runOnMainChecked(() -> {
            OfficePreviewView view = activity.preview;
            view.layout(0, 0, 1080, 900);
            view.jumpToPage(1);
            check(view.getPageCount() == 2 && view.getCurrentPage() == 1, "One-based loaded page state");
            int before = events.size();
            view.jumpToPage(2);
            check(events.size() == before + 1 && events.get(before).equals("2/2"), "Jump to last page notifies once");
            view.jumpToPage(2);
            check(events.size() == before + 1, "Unchanged page does not repeat callback");
            view.setZoom(2);
            view.jumpToPage(1);
            check(view.getCurrentPage() == 1 && view.getZoom() == 2, "Jump preserves zoom");
            long time = SystemClock.uptimeMillis();
            float x = 400, y = 800;
            MotionEvent down = MotionEvent.obtain(time, time, MotionEvent.ACTION_DOWN, x, y, 0);
            view.dispatchTouchEvent(down); down.recycle();
            for (int i = 1; i <= 8; i++) {
                MotionEvent move = MotionEvent.obtain(time, time + i * 100, MotionEvent.ACTION_MOVE, x, y - i * 150, 0);
                view.dispatchTouchEvent(move); move.recycle();
            }
            MotionEvent cancel = MotionEvent.obtain(time, time + 900, MotionEvent.ACTION_CANCEL, x, -400, 0);
            view.dispatchTouchEvent(cancel); cancel.recycle();
            check(view.getCurrentPage() == 2 && events.get(events.size() - 1).equals("2/2"), "Dragging updates current page");
            view.resetZoom();
            view.layout(0, 0, 1080, 4000);
            view.jumpToPage(2);
            check(view.getCurrentPage() == 2, "Jump target wins when both pages fully visible");
            int previous = events.size();
            for (int invalid : new int[] {0, 3}) {
                try { view.jumpToPage(invalid); throw new AssertionError("Invalid page accepted"); }
                catch (IllegalArgumentException expected) { }
            }
            check(events.size() == previous, "Invalid jump preserves state");
        });
        load("sample.docx", "DOCX");
        runOnMainChecked(() -> {
            OfficePreviewView view = activity.preview;
            check(view.getPageCount() == 1 && view.getCurrentPage() == 1, "DOCX remains one continuous page");
            view.clear();
            check(events.get(events.size() - 1).equals("0/0"), "Clear resets page event");
            view.setOnPageChangeListener(null);
        });
        expectError("broken");
        runOnMainChecked(() -> check(activity.preview.getCurrentPage() == 0 && activity.preview.getPageCount() == 0, "Failed load has no current page"));
        runOnMainSync(() -> activity.preview.requestLayout());
    }

    interface CheckedRunnable { void run() throws Exception; }

    void runOnMainChecked(CheckedRunnable operation) throws Exception {
        AtomicReference<Throwable> failure = new AtomicReference<>();
        runOnMainSync(() -> {
            try { operation.run(); } catch (Exception | AssertionError error) { failure.set(error); }
        });
        if (failure.get() instanceof Exception) throw (Exception) failure.get();
        if (failure.get() instanceof AssertionError) throw (AssertionError) failure.get();
    }

    void load(String name, String format) throws Exception {
        load(uri(name), format);
    }

    private void load(Uri source, String format) throws Exception {
        CountDownLatch latch = new CountDownLatch(1);
        AtomicReference<OfficePreviewView.Info> loaded = new AtomicReference<>();
        AtomicReference<Exception> failed = new AtomicReference<>();
        runOnMainSync(() -> activity.preview.open(source, new OfficePreviewView.Listener() {
            public void onLoaded(OfficePreviewView.Info info) { loaded.set(info); latch.countDown(); }
            public void onError(Exception error) { failed.set(error); latch.countDown(); }
        }));
        check(latch.await(20, TimeUnit.SECONDS), "URI load finishes: " + source.getLastPathSegment());
        if (failed.get() != null) throw failed.get();
        check(loaded.get() != null && format.equals(loaded.get().format), "Format detected from " + source.getScheme() + " URI: " + format);
        if (format.equals("PPTX")) check(loaded.get().pageCount == 2, "Both slides loaded");
        awaitImages();
        if (failed.get() != null) throw failed.get();
    }

    private void awaitImages() throws Exception {
        long deadline = SystemClock.uptimeMillis() + 10000;
        AtomicReference<Boolean> ready = new AtomicReference<>(false);
        while (SystemClock.uptimeMillis() < deadline) {
            runOnMainChecked(() -> {
                activity.preview.draw(new Canvas());
                java.lang.reflect.Field field = OfficePreviewView.class.getDeclaredField("images");
                field.setAccessible(true);
                OfficeImages images = (OfficeImages) field.get(activity.preview);
                ready.set(images != null && !images.loading && images.bitmaps.keySet().containsAll(images.wanted));
            });
            if (ready.get()) return;
            SystemClock.sleep(20);
        }
        throw new AssertionError("Visible images did not finish loading");
    }

    private void awaitCacheCleanup() throws Exception {
        long deadline = SystemClock.uptimeMillis() + 10000;
        while (SystemClock.uptimeMillis() < deadline) {
            File[] files = new File(getTargetContext().getCacheDir(), "office-preview").listFiles();
            if (files != null && files.length == 0) return;
            SystemClock.sleep(20);
        }
        throw new AssertionError("Temporary documents were not removed");
    }

    private void expectError(String name) throws Exception {
        CountDownLatch latch = new CountDownLatch(1);
        AtomicReference<Exception> error = new AtomicReference<>();
        runOnMainSync(() -> activity.preview.open(uri(name), new OfficePreviewView.Listener() {
            public void onLoaded(OfficePreviewView.Info info) { latch.countDown(); }
            public void onError(Exception failure) { error.set(failure); latch.countDown(); }
        }));
        check(latch.await(10, TimeUnit.SECONDS) && error.get() != null, "Error callback: " + name);
    }

    private void rapidReplacement() throws Exception {
        CountDownLatch latch = new CountDownLatch(1);
        AtomicInteger stale = new AtomicInteger();
        AtomicReference<String> format = new AtomicReference<>();
        runOnMainSync(() -> {
            activity.preview.open(uri("sample.docx"), new OfficePreviewView.Listener() {
                public void onLoaded(OfficePreviewView.Info info) { stale.incrementAndGet(); }
                public void onError(Exception error) { stale.incrementAndGet(); }
            });
            activity.preview.open(uri("sample.pptx"), new OfficePreviewView.Listener() {
                public void onLoaded(OfficePreviewView.Info info) { format.set(info.format); latch.countDown(); }
                public void onError(Exception error) { latch.countDown(); }
            });
        });
        check(latch.await(20, TimeUnit.SECONDS) && "PPTX".equals(format.get()) && stale.get() == 0, "Replacing URI suppresses stale callbacks");
    }

    private void capture(String name, int width, int height) throws Exception {
        AtomicReference<Bitmap> ref = new AtomicReference<>();
        runOnMainSync(() -> {
            OfficePreviewView view = activity.preview;
            view.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY));
            view.layout(0, 0, width, height);
        });
        awaitImages();
        runOnMainSync(() -> {
            OfficePreviewView view = activity.preview;
            Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
            view.draw(new Canvas(bitmap)); ref.set(bitmap);
        });
        Bitmap bitmap = ref.get();
        int ink = 0;
        for (int y = 0; y < height; y += 4) for (int x = 0; x < width; x += 4) {
            int color = bitmap.getPixel(x, y);
            if (color != 0xffe9ecef && color != 0xffffffff && (color & 0x00ffffff) < 0x00c0c0c0) ink++;
        }
        check(ink > 100, "Rendered content pixels: " + name + " (" + ink + ")");
        try (FileOutputStream output = new FileOutputStream(new File(getTargetContext().getFilesDir(), name + ".png"))) {
            check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output), "Capture saved: " + name);
        }
        bitmap.recycle();
    }

    void captureScreen(String name) throws Exception {
        awaitImages();
        CountDownLatch drawn = new CountDownLatch(1);
        AtomicInteger expectedPaper = new AtomicInteger(0xffffffff);
        runOnMainChecked(() -> {
            OfficePreviewView view = activity.preview;
            java.lang.reflect.Field documentField = OfficePreviewView.class.getDeclaredField("document");
            documentField.setAccessible(true);
            OfficeDocument document = (OfficeDocument) documentField.get(view);
            if (document != null && document.kind == OfficeDocument.Kind.PPTX) {
                expectedPaper.set(document.pages.get(view.getCurrentPage() - 1).background);
            }
            view.getViewTreeObserver().addOnDrawListener(new android.view.ViewTreeObserver.OnDrawListener() {
                @Override public void onDraw() {
                    view.post(() -> {
                        view.getViewTreeObserver().removeOnDrawListener(this);
                        view.postOnAnimation(drawn::countDown);
                    });
                }
            });
            view.requestLayout(); view.invalidate();
        });
        check(drawn.await(5, TimeUnit.SECONDS), "Window rendered document: " + name);
        waitForIdleSync();
        getUiAutomation().waitForIdle(100, 3000);
        Bitmap bitmap = null;
        int paper = 0;
        long deadline = SystemClock.uptimeMillis() + 3000;
        do {
            if (bitmap != null) bitmap.recycle();
            bitmap = getUiAutomation().takeScreenshot();
            check(bitmap != null, "Window screenshot available: " + name);
            paper = ScreenshotColorChecks.countPaper(bitmap, expectedPaper.get());
            if (paper > 100) break;
            SystemClock.sleep(50);
        } while (SystemClock.uptimeMillis() < deadline);
        try (FileOutputStream output = new FileOutputStream(new File(getTargetContext().getFilesDir(), name + ".png"))) {
            check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output), "Window capture saved: " + name);
        }
        bitmap.recycle();
        check(paper > 100, "Window contains document paper: " + name
            + " (expected #" + Integer.toHexString(expectedPaper.get()) + ", samples=" + paper + ")");
    }

    private void doubleTap() {
        int[] location = new int[2];
        StringBuilder events = new StringBuilder();
        runOnMainSync(() -> {
            activity.preview.getLocationOnScreen(location);
            activity.preview.setOnTouchListener((view, event) -> {
                events.append(event.getActionMasked()).append('@').append(event.getEventTime())
                    .append('(').append(event.getX()).append(',').append(event.getY()).append(") ");
                return false;
            });
        });
        float x = location[0] + activity.preview.getWidth() / 2f;
        float y = location[1] + activity.preview.getHeight() / 3f;
        for (int tap = 0; tap < 2; tap++) {
            long down = SystemClock.uptimeMillis();
            MotionEvent press = MotionEvent.obtain(down, down, MotionEvent.ACTION_DOWN, x, y, 0);
            sendPointerSync(press); press.recycle();
            SystemClock.sleep(30);
            MotionEvent release = MotionEvent.obtain(down, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, x, y, 0);
            sendPointerSync(release); release.recycle();
            SystemClock.sleep(60);
        }
        waitForIdleSync();
        runOnMainSync(() -> {
            results.append("TOUCH ").append(events).append("zoom=").append(activity.preview.getZoom()).append('\n');
            activity.preview.setOnTouchListener(null);
        });
    }

    void check(boolean passed, String description) {
        if (!passed) throw new AssertionError(description);
        results.append("PASS ").append(description).append('\n');
    }
}
