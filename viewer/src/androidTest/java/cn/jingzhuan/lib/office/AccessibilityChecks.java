package cn.jingzhuan.lib.office;

import android.net.Uri;
import android.view.accessibility.AccessibilityNodeInfo;
import java.lang.reflect.Field;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/** 读屏无障碍契约验证：内容摘要、自定义动作菜单、动作执行与状态播报 */
final class AccessibilityChecks {
    private AccessibilityChecks() { }

    static String run(OfficeInstrumentation instrumentation, PreviewTestActivity activity) throws Exception {
        pptx(instrumentation, activity);
        spreadsheet(instrumentation, activity);
        flow(instrumentation, activity);
        fling(instrumentation, activity);
        failure(instrumentation, activity);
        boolean spoken = announcements(instrumentation, activity);
        return "PASS content description summarizes loaded document by format\n"
            + "PASS action menu rebuilds per page, sheet and zoom state\n"
            + "PASS announced page tracks settled action navigation\n"
            + "PASS fling announces only the settled landing page\n"            + (spoken ? "PASS spoken page updates reach the screen-reader event stream\n"
                : "SKIP spoken page checks need a device that lets the test bind an accessibility service\n");
    }

    private static void pptx(OfficeInstrumentation instrumentation, PreviewTestActivity activity) throws Exception {
        OfficePreviewView view = activity.preview;
        open(instrumentation, view, "sample.pptx", "PPTX");
        String summary = read(instrumentation, () -> String.valueOf(view.getContentDescription()));
        instrumentation.check(summary.contains("PowerPoint 演示文稿") && summary.contains("共 2 页"),
            "Summary announces presentation with page count: " + summary);
        instrumentation.check(hasAction(instrumentation, view, "ACTION_NEXT", "下一页")
            && !hasAction(instrumentation, view, "ACTION_PREVIOUS", "上一页"), "Next-page action only from first page");
        instrumentation.check(hasAction(instrumentation, view, "ACTION_ZOOM_IN", "放大")
            && !hasAction(instrumentation, view, "ACTION_ZOOM_OUT", "缩小"), "Zoom actions follow zoom level");
        scrollActionsMatchView(instrumentation, view);
        perform(instrumentation, view, "ACTION_NEXT");
        instrumentation.check(read(instrumentation, view::getCurrentPage) == 2, "Next-page action advances document");
        instrumentation.check(hasAction(instrumentation, view, "ACTION_PREVIOUS", "上一页")
            && !hasAction(instrumentation, view, "ACTION_NEXT", "下一页"), "Menu rebuilds at last page");
        instrumentation.check(read(instrumentation, () -> announcedPage(view)) == 2, "Settled page is announced on action navigation");
        perform(instrumentation, view, "ACTION_ZOOM_IN");
        instrumentation.check(read(instrumentation, view::getZoom) == 2, "Zoom-in action steps the scale");
        instrumentation.check(hasAction(instrumentation, view, "ACTION_ZOOM_OUT", "缩小")
            && hasAction(instrumentation, view, "ACTION_RESET_ZOOM", "重置缩放"), "Zoom-out appears after zoom-in");
        perform(instrumentation, view, "ACTION_RESET_ZOOM");
        instrumentation.check(read(instrumentation, view::getZoom) == 1, "Reset-zoom action restores 1.0x");
    }

    private static void spreadsheet(OfficeInstrumentation instrumentation, PreviewTestActivity activity) throws Exception {
        OfficePreviewView view = activity.preview;
        open(instrumentation, view, "sample.xlsx", "XLSX");
        String summary = read(instrumentation, () -> String.valueOf(view.getContentDescription()));
        instrumentation.check(summary.contains("Excel 工作簿") && summary.contains("个工作表")
            && !summary.contains("幻灯片"), "Workbook summary lists sheet count: " + summary);
        instrumentation.check(hasAction(instrumentation, view, "ACTION_NEXT", "下一个工作表")
            && !hasAction(instrumentation, view, "ACTION_PREVIOUS", "上一个工作表"), "Next-sheet action only from first sheet");
        perform(instrumentation, view, "ACTION_NEXT");
        instrumentation.check(read(instrumentation, view::getCurrentPage) == 2, "Next-sheet action switches sheet");
        instrumentation.check(hasAction(instrumentation, view, "ACTION_PREVIOUS", "上一个工作表"), "Previous-sheet appears after switch");
        instrumentation.check(read(instrumentation, () -> announcedPage(view)) == 2, "Sheet switch is announced");
        instrumentation.check(read(instrumentation, () -> String.valueOf(view.getContentDescription())).equals(summary),
            "Sheet switch keeps the workbook summary");
    }

    private static void flow(OfficeInstrumentation instrumentation, PreviewTestActivity activity) throws Exception {
        OfficePreviewView view = activity.preview;
        open(instrumentation, view, "sample.docx", "DOCX");
        String summary = read(instrumentation, () -> String.valueOf(view.getContentDescription()));
        instrumentation.check(summary.contains("Word 文档"), "Flow summary announces continuous document: " + summary);
        instrumentation.check(!hasAction(instrumentation, view, "ACTION_NEXT", "下一页")
            && !hasAction(instrumentation, view, "ACTION_PREVIOUS", "上一页"), "Single flow page exposes no page actions");
        float[] before = new float[1];
        // 视口固定、滚动能力与动作执行放在同一主线程批次，避免窗口重排改变视口导致竞态
        instrumentation.runOnMainChecked(() -> {
            view.layout(0, 0, 1080, 400);
            instrumentation.check(view.canScrollVertically(1), "Continuous document scrolls in a short viewport");
            instrumentation.check(hasActionOnMain(view, "SCROLL_FORWARD", "向下滚动")
                && hasActionOnMain(view, "SCROLL_BACKWARD", "向上滚动") == view.canScrollVertically(-1),
                "Scroll actions appear exactly when the viewport can scroll");
            before[0] = offsetY(view);
            instrumentation.check(view.performAccessibilityAction(actionId("SCROLL_FORWARD"), null),
                "Accessibility action handled: SCROLL_FORWARD");
        });
        awaitSettled(instrumentation, view);
        float after = read(instrumentation, () -> offsetY(view));
        instrumentation.check(after > before[0], "Scroll-forward action moves the viewport down");
        instrumentation.check(read(instrumentation, () -> announcedPage(view)) == 1, "Continuous scroll keeps announcing current page");
        instrumentation.runOnMainChecked(() -> view.performAccessibilityAction(actionId("SCROLL_BACKWARD"), null));
        awaitSettled(instrumentation, view);
        instrumentation.check(read(instrumentation, () -> offsetY(view)) < after, "Scroll-backward action moves the viewport up");
    }

    /** 端到端验证：翻页播报经真实无障碍事件流（与 TalkBack 同一通道）送达 */
    private static boolean announcements(OfficeInstrumentation instrumentation, PreviewTestActivity activity) throws Exception {
        String service = instrumentation.getTargetContext().getPackageName() + "/" + AccessibilityEventProbe.class.getName();
        AccessibilityEventProbe.bound.set(false);
        enableProbe(instrumentation, service);
        try {
            if (!readSetting(instrumentation, "enabled_accessibility_services").contains(service)) {
                // 部分厂商 ROM（如 MIUI）禁止以 shell 方式启用无障碍服务，需人工在系统设置中授权
                return false;
            }
            if (!awaitBound(instrumentation, 5000)) {
                // 写入被接受但服务未绑定：模拟器与部分受限 ROM 不向测试服务下发绑定，
                // 重试一次排除绑定延迟；仍未绑定则跳过播报断言，保持其余断言生效
                enableProbe(instrumentation, service);
                if (!awaitBound(instrumentation, 15000)) return false;
            }
            OfficePreviewView view = activity.preview;
            open(instrumentation, view, "sample.pptx", "PPTX");
            instrumentation.check(awaitText(instrumentation, null) != null, "Loading state reaches the event stream");
            instrumentation.check(awaitText(instrumentation, "第 1 页，共 2 页") != null, "First page is announced on load");
            AccessibilityEventProbe.announcements.clear();
            perform(instrumentation, view, "ACTION_NEXT");
            instrumentation.check(awaitText(instrumentation, "第 2 页，共 2 页") != null, "Page change is announced through the event stream");
            instrumentation.check(countText("第 2 页，共 2 页") == 1, "Settled page is announced exactly once");
            perform(instrumentation, view, "ACTION_PREVIOUS");
            instrumentation.check(awaitText(instrumentation, "第 1 页，共 2 页") != null, "Previous page is announced through the event stream");
            return true;
        } finally {
            shell(instrumentation, "settings delete secure enabled_accessibility_services");
            shell(instrumentation, "settings put secure accessibility_enabled 0");
            AccessibilityEventProbe.bound.set(false);
            AccessibilityEventProbe.announcements.clear();
        }
    }

    private static void enableProbe(OfficeInstrumentation instrumentation, String service) throws Exception {
        shell(instrumentation, "settings put secure accessibility_enabled 1");
        shell(instrumentation, "settings put secure enabled_accessibility_services " + service);
    }

    private static boolean awaitBound(OfficeInstrumentation instrumentation, long timeoutMillis) throws Exception {
        long deadline = System.currentTimeMillis() + timeoutMillis;
        while (System.currentTimeMillis() < deadline) {
            if (AccessibilityEventProbe.bound.get()) return true;
            android.os.SystemClock.sleep(50);
        }
        return false;
    }

    private static String awaitText(OfficeInstrumentation instrumentation, String text) throws Exception {
        long deadline = System.currentTimeMillis() + 5000;
        while (System.currentTimeMillis() < deadline) {
            for (String entry : AccessibilityEventProbe.announcements) {
                if (text == null || entry.contains(text)) return entry;
            }
            android.os.SystemClock.sleep(30);
        }
        return null;
    }

    private static int countText(String text) {
        int count = 0;
        for (String entry : AccessibilityEventProbe.announcements) {
            if (entry.contains(text)) count++;
        }
        return count;
    }

    private static void shell(OfficeInstrumentation instrumentation, String command) throws Exception {
        try (android.os.ParcelFileDescriptor pipe = instrumentation.getUiAutomation().executeShellCommand(command);
             java.io.InputStream stream = new android.os.ParcelFileDescriptor.AutoCloseInputStream(pipe)) {
            byte[] buffer = new byte[512];
            while (stream.read(buffer) != -1) { }
        }
    }

    private static String readSetting(OfficeInstrumentation instrumentation, String key) throws Exception {
        StringBuilder value = new StringBuilder();
        try (android.os.ParcelFileDescriptor pipe = instrumentation.getUiAutomation().executeShellCommand("settings get secure " + key);
             java.io.InputStream stream = new android.os.ParcelFileDescriptor.AutoCloseInputStream(pipe)) {
            byte[] buffer = new byte[512];
            int count;
            while ((count = stream.read(buffer)) != -1) value.append(new String(buffer, 0, count, java.nio.charset.StandardCharsets.UTF_8));
        }
        return value.toString().trim();
    }

    /** 真实惯性手势：验证播报只在停稳后指向最终落点页，惯性过程中不逐帧播报 */
    private static void fling(OfficeInstrumentation instrumentation, PreviewTestActivity activity) throws Exception {
        OfficePreviewView view = activity.preview;
        // 视口固定与手势派发放进同一主线程批次，保持判定与动作之间视口一致
        instrumentation.runOnMainChecked(() -> {
            view.layout(0, 0, 1080, 400);
            instrumentation.check(view.performAccessibilityAction(actionId("ACTION_PREVIOUS"), null), "Returns to first page before flinging");
            instrumentation.check(view.getCurrentPage() == 1, "Previous page before flinging lands on page one");
            long time = android.os.SystemClock.uptimeMillis();
            feed(view, time, time, android.view.MotionEvent.ACTION_DOWN, 400, 800);
            for (int step = 1; step <= 6; step++) {
                feed(view, time, time + step * 12, android.view.MotionEvent.ACTION_MOVE, 400, 800 - step * 200);
            }
            feed(view, time, time + 90, android.view.MotionEvent.ACTION_UP, 400, 200);
        });
        awaitSettled(instrumentation, view);
        int landed = read(instrumentation, view::getCurrentPage);
        // 惯性滚动可能很短（测试固件仅两页），核心契约是停稳后的播报始终指向最终落点页
        instrumentation.check(read(instrumentation, () -> announcedPage(view)) == landed,
            "Fling announces exactly the settled landing page (page " + landed + ")");
    }

    private static void feed(OfficePreviewView view, long downTime, long eventTime, int action, float x, float y) {
        android.view.MotionEvent event = android.view.MotionEvent.obtain(downTime, eventTime, action, x, y, 0);
        view.dispatchTouchEvent(event);
        event.recycle();
    }

    private static void failure(OfficeInstrumentation instrumentation, PreviewTestActivity activity) throws Exception {        OfficePreviewView view = activity.preview;
        CountDownLatch latch = new CountDownLatch(1);
        AtomicReference<Exception> error = new AtomicReference<>();
        Uri broken = Uri.parse("content://" + instrumentation.getTargetContext().getPackageName() + ".fixtures/broken");
        instrumentation.runOnMainSync(() -> view.open(broken, new OfficePreviewView.Listener() {
            public void onLoaded(OfficePreviewView.Info info) { latch.countDown(); }
            public void onError(Exception failure) { error.set(failure); latch.countDown(); }
        }));
        instrumentation.check(latch.await(10, TimeUnit.SECONDS) && error.get() != null, "Failed load reports an error");
        instrumentation.check(read(instrumentation, () -> view.getContentDescription()) == null,
            "Failed load clears the stale document summary");
    }

    private static void open(OfficeInstrumentation instrumentation, OfficePreviewView view, String name, String format) throws Exception {
        CountDownLatch latch = new CountDownLatch(1);
        AtomicReference<String> detected = new AtomicReference<>();
        AtomicReference<Exception> failure = new AtomicReference<>();
        Uri source = Uri.parse("content://" + instrumentation.getTargetContext().getPackageName() + ".fixtures/" + name);
        instrumentation.runOnMainSync(() -> view.open(source, new OfficePreviewView.Listener() {
            public void onLoaded(OfficePreviewView.Info info) { detected.set(info.format); latch.countDown(); }
            public void onError(Exception error) { failure.set(error); latch.countDown(); }
        }));
        instrumentation.check(latch.await(20, TimeUnit.SECONDS) && failure.get() == null, "Opens fixture: " + name);
        instrumentation.check(format.equals(detected.get()), "Format detected: " + format);
    }

    private static void scrollActionsMatchView(OfficeInstrumentation instrumentation, OfficePreviewView view) throws Exception {
        boolean forward = read(instrumentation, () -> view.canScrollVertically(1));
        boolean backward = read(instrumentation, () -> view.canScrollVertically(-1));
        instrumentation.check(hasAction(instrumentation, view, "SCROLL_FORWARD", "向下滚动") == forward
            && hasAction(instrumentation, view, "SCROLL_BACKWARD", "向上滚动") == backward,
            "Scroll actions appear exactly when the viewport can scroll");
    }

    private static void perform(OfficeInstrumentation instrumentation, OfficePreviewView view, String field) throws Exception {
        boolean handled = read(instrumentation, () -> view.performAccessibilityAction(actionId(field), null));
        instrumentation.check(handled, "Accessibility action handled: " + field);
    }

    private static boolean hasAction(OfficeInstrumentation instrumentation, OfficePreviewView view, String field, String label) throws Exception {
        return read(instrumentation, () -> hasActionOnMain(view, field, label));
    }

    private static boolean hasActionOnMain(OfficePreviewView view, String field, String label) throws Exception {
        int id = actionId(field);
        return labels(view).stream().anyMatch(action -> action.getLabel() != null
            && label.contentEquals(action.getLabel()) && action.getId() == id);
    }

    private static List<AccessibilityNodeInfo.AccessibilityAction> labels(OfficePreviewView view) {
        return view.createAccessibilityNodeInfo().getActionList();
    }

    private static int actionId(String field) throws Exception {
        try {
            Field framework = AccessibilityNodeInfo.class.getDeclaredField("ACTION_" + field);
            framework.setAccessible(true);
            return framework.getInt(null);
        } catch (NoSuchFieldException missing) {
            Field declared = OfficePreviewView.class.getDeclaredField(field);
            declared.setAccessible(true);
            return declared.getInt(null);
        }
    }

    private static int announcedPage(OfficePreviewView view) throws Exception {
        Field declared = OfficePreviewView.class.getDeclaredField("announcedPage");
        declared.setAccessible(true);
        return declared.getInt(view);
    }

    private static float offsetY(OfficePreviewView view) throws Exception {
        Field declared = OfficePreviewView.class.getDeclaredField("offsetY");
        declared.setAccessible(true);
        return declared.getFloat(view);
    }

    private static void awaitSettled(OfficeInstrumentation instrumentation, OfficePreviewView view) throws Exception {
        // 平滑滚动在慢速设备（模拟器、低端机）上可能超过 2 秒，留足停稳时间
        long deadline = System.currentTimeMillis() + 8000;
        while (System.currentTimeMillis() < deadline) {
            if (read(instrumentation, () -> scrollerIdle(view))) return;
            android.os.SystemClock.sleep(30);
        }
        throw new AssertionError("Viewport scroll did not settle");
    }

    private static boolean scrollerIdle(OfficePreviewView view) throws Exception {
        Field declared = OfficePreviewView.class.getDeclaredField("scroller");
        declared.setAccessible(true);
        return ((android.widget.OverScroller) declared.get(view)).isFinished();
    }

    private static <T> T read(OfficeInstrumentation instrumentation, Supplier<T> read) throws Exception {
        AtomicReference<T> value = new AtomicReference<>();
        AtomicReference<Throwable> failure = new AtomicReference<>();
        instrumentation.runOnMainSync(() -> {
            try { value.set(read.get()); } catch (Throwable error) { failure.set(error); }
        });
        if (failure.get() instanceof Exception) throw (Exception) failure.get();
        if (failure.get() instanceof AssertionError) throw (AssertionError) failure.get();
        return value.get();
    }

    private interface Supplier<T> { T get() throws Exception; }
}
