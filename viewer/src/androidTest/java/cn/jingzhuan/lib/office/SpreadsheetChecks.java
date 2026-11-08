package cn.jingzhuan.lib.office;

import android.app.Instrumentation;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.net.Uri;
import android.os.SystemClock;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import cn.jingzhuan.lib.office.widget.OfficeSheetTabs;
import java.io.File;
import java.io.FileOutputStream;
import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

final class SpreadsheetChecks {
    private final Instrumentation instrumentation;
    private final OfficePreviewView view;
    private final File files;

    private SpreadsheetChecks(Instrumentation instrumentation, PreviewTestActivity activity) {
        this.instrumentation = instrumentation; view = activity.preview; files = activity.getFilesDir();
    }

    static String run(Instrumentation instrumentation, PreviewTestActivity activity) throws Exception {
        return new SpreadsheetChecks(instrumentation, activity).run();
    }

    private String run() throws Exception {
        List<String> pages = new ArrayList<>();
        int[] originalSize = new int[2];
        AtomicReference<OfficeSheetTabs> tabsRef = new AtomicReference<>();
        onMain(() -> {
            originalSize[0] = view.getLayoutParams().width; originalSize[1] = view.getLayoutParams().height;
            view.clear(); view.setOnPageChangeListener((page, count) -> pages.add(page + "/" + count));
            OfficeSheetTabs sheetTabs = new OfficeSheetTabs(view.getContext());
            sheetTabs.attachTo(view);
            check(sheetTabs.getVisibility() == View.GONE, "OfficeSheetTabs hidden when preview is empty");
            tabsRef.set(sheetTabs);
        });
        try {
            OfficePreviewView.Info info = load("sample.xlsx", "XLSX");
            check(info.sheetNames.equals(Arrays.asList("Overview", "Data")), "Workbook relationship order and names");
            onMain(() -> {
                check(view.getPageCount() == 2 && view.getCurrentPage() == 1, "Initial sheet page API");
                check(view.getSheetNames().equals(info.sheetNames), "Public sheet names");
                OfficeSheetTabs sheetTabs = tabsRef.get();
                LinearLayout tabsContainer = (LinearLayout) sheetTabs.getChildAt(0);
                check(sheetTabs.getVisibility() == View.VISIBLE && tabsContainer.getChildCount() == 2, "OfficeSheetTabs auto-populates on XLSX load");
                check(tabsContainer.getChildAt(0).isSelected() && !tabsContainer.getChildAt(1).isSelected(), "OfficeSheetTabs selects first tab initially");
            });
            capture("spreadsheet-portrait", 1080, 1600);
            capture("spreadsheet-landscape", 1800, 1000);
            onMain(() -> {
                layout(1080, 1600);
                view.setZoom(2);
                view.jumpToPage(1);
                check(offset("offsetX") == 0 && offset("offsetY") == 0, "Current-sheet jump resets zoom-induced pan");
                check(view.canScrollHorizontally(1) && view.canScrollVertically(1), "Large sheet scrolls in both directions");
                float x = offset("offsetX"), y = offset("offsetY");
                drag(500, 500, 80, 100);
                check(offset("offsetX") > x && offset("offsetY") > y, "Drag changes both offsets");
                check(view.getCurrentPage() == 1, "Grid scroll keeps the current sheet");
            });
            capture("spreadsheet-scrolled", 1080, 1600);
            onMain(() -> {
                int eventCount = pages.size();
                view.jumpToPage(1);
                check(offset("offsetX") == 0 && offset("offsetY") == 0, "Current-sheet jump resets drag pan");
                check(pages.size() == eventCount, "Current-sheet jump does not repeat page callback");
                view.selectSheet(2);
                check(view.getCurrentPage() == 2 && view.getZoom() == 2, "Switch sheet preserves zoom");
                LinearLayout tabsContainer = (LinearLayout) tabsRef.get().getChildAt(0);
                check(!tabsContainer.getChildAt(0).isSelected() && tabsContainer.getChildAt(1).isSelected(), "OfficeSheetTabs syncs active tab on selectSheet");
                check(!view.canScrollHorizontally(-1) && !view.canScrollVertically(-1), "Switch sheet resets pan");
                view.resetZoom();
                check(pages.contains("2/2"), "Sheet change callback");
            });
            capture("spreadsheet-second", 1080, 1600);
            onMain(() -> {
                view.jumpToPage(1);
                check(view.getCurrentPage() == 1, "Page API selects worksheet");
                try { view.selectSheet(3); throw new AssertionError("Invalid sheet accepted"); }
                catch (IllegalArgumentException expected) { }
                view.setZoom(0.5f);
                check(view.getZoom() == 0.5f, "Spreadsheet zooms out to half scale");
            });
            capture("spreadsheet-zoomed-out", 1080, 1600);
            AtomicInteger stale = new AtomicInteger();
            CountDownLatch done = new CountDownLatch(1);
            AtomicReference<String> format = new AtomicReference<>();
            onMain(() -> {
                view.open(uri("sample.xlsx"), new OfficePreviewView.Listener() {
                    public void onLoaded(OfficePreviewView.Info loaded) { stale.incrementAndGet(); }
                    public void onError(Exception error) { stale.incrementAndGet(); }
                });
                view.open(uri("sample.docx"), new OfficePreviewView.Listener() {
                    public void onLoaded(OfficePreviewView.Info loaded) { format.set(loaded.format); done.countDown(); }
                    public void onError(Exception error) { done.countDown(); }
                });
            });
            check(done.await(20, TimeUnit.SECONDS) && "DOCX".equals(format.get()) && stale.get() == 0, "XLSX replacement suppresses stale callbacks");
            onMain(() -> {
                check(view.getSheetNames().isEmpty(), "DOCX clears sheet list");
                check(tabsRef.get().getVisibility() == View.GONE, "OfficeSheetTabs hides automatically on DOCX load");
                tabsRef.get().detach();
                view.clear();
                check(view.getPageCount() == 0 && view.getCurrentPage() == 0 && view.getSheetNames().isEmpty(), "Clear resets workbook state");
            });
            return "PASS XLSX content URI + JNI, sheet order, switch/page callbacks, two-axis drag, zoom, replacement and clear\n"
                + "PASS XLSX portrait/landscape/second-sheet captures and styled merged-cell pixels\n";
        } finally {
            onMain(() -> {
                view.clear(); view.setOnPageChangeListener(null);
                ViewGroup.LayoutParams params = view.getLayoutParams();
                params.width = originalSize[0]; params.height = originalSize[1]; view.setLayoutParams(params); view.requestLayout();
            });
        }
    }

    private OfficePreviewView.Info load(String name, String kind) throws Exception {
        CountDownLatch done = new CountDownLatch(1);
        AtomicReference<OfficePreviewView.Info> info = new AtomicReference<>();
        AtomicReference<Exception> error = new AtomicReference<>();
        onMain(() -> view.open(uri(name), new OfficePreviewView.Listener() {
            public void onLoaded(OfficePreviewView.Info loaded) { info.set(loaded); done.countDown(); }
            public void onError(Exception failure) { error.set(failure); done.countDown(); }
        }));
        check(done.await(20, TimeUnit.SECONDS), "Workbook URI load timeout");
        if (error.get() != null) throw error.get();
        check(info.get() != null && kind.equals(info.get().format), "Workbook format detected from stream");
        return info.get();
    }

    private Uri uri(String name) { return Uri.parse("content://" + instrumentation.getTargetContext().getPackageName() + ".fixtures/" + name); }

    private void capture(String name, int width, int height) throws Exception {
        AtomicReference<Bitmap> image = new AtomicReference<>();
        onMain(() -> {
            layout(width, height);
            Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
            view.draw(new Canvas(bitmap)); image.set(bitmap);
        });
        Bitmap bitmap = image.get();
        try (FileOutputStream output = new FileOutputStream(new File(files, name + ".png"))) {
            if (!name.equals("spreadsheet-scrolled")) {
                int filled = 0;
                for (int y = 0; y < height; y += 4) for (int x = 0; x < width; x += 4) {
                    if (bitmap.getPixel(x, y) == 0xff24745c) filled++;
                }
                check(filled > 100, "Styled merged-cell background drawn: " + name);
            }
            check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output), "Save " + name);
        } finally { bitmap.recycle(); }
    }

    private void layout(int width, int height) {
        ViewGroup.LayoutParams params = view.getLayoutParams(); params.width = width; params.height = height; view.setLayoutParams(params);
        view.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY));
        view.layout(0, 0, width, height);
    }

    private float offset(String name) throws Exception {
        Field field = OfficePreviewView.class.getDeclaredField(name); field.setAccessible(true);
        return field.getFloat(view);
    }

    private void drag(float fromX, float fromY, float toX, float toY) {
        long down = SystemClock.uptimeMillis();
        for (int i = 0; i <= 6; i++) {
            int action = i == 0 ? MotionEvent.ACTION_DOWN : i == 6 ? MotionEvent.ACTION_CANCEL : MotionEvent.ACTION_MOVE;
            float fraction = Math.min(i, 5) / 5f;
            MotionEvent event = MotionEvent.obtain(down, down + i * 20, action, fromX + (toX - fromX) * fraction, fromY + (toY - fromY) * fraction, 0);
            try { view.dispatchTouchEvent(event); } finally { event.recycle(); }
        }
    }

    private interface CheckedRunnable { void run() throws Exception; }
    private void onMain(CheckedRunnable runnable) throws Exception {
        AtomicReference<Throwable> failure = new AtomicReference<>();
        instrumentation.runOnMainSync(() -> { try { runnable.run(); } catch (Exception | AssertionError error) { failure.set(error); } });
        if (failure.get() instanceof Exception) throw (Exception) failure.get();
        if (failure.get() instanceof AssertionError) throw (AssertionError) failure.get();
    }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
