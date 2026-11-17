package cn.jingzhuan.lib.office;

import android.content.ClipboardManager;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.net.Uri;
import android.os.SystemClock;
import android.view.MotionEvent;
import android.view.ViewConfiguration;
import android.view.accessibility.AccessibilityNodeInfo;
import java.lang.reflect.Field;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/**
 * 设备端文本选区契约验证：公开 API、长按选词与手柄拖拽、浮动气泡复制、
 * 无障碍全选/复制/清除动作，以及 XLSX 不支持划词的边界。
 *
 * <p>运行方式：{@code am instrument -w -e suite selection}，全部通过时输出
 * {@code ALL SELECTION CHECKS PASSED}。
 */
final class TextSelectionChecks {
    /** 选区高亮变化像素的判定下限：全选覆盖全部正文行，差异远大于该值 */
    private static final int MIN_HIGHLIGHT_PIXELS = 1000;

    private TextSelectionChecks() { }

    static String run(OfficeInstrumentation instrumentation, PreviewTestActivity activity) throws Exception {
        StringBuilder results = new StringBuilder();
        OfficePreviewView view = activity.preview;
        docx(instrumentation, activity, view);
        multilineWrapping(instrumentation);
        longPressAndDrag(instrumentation, activity, view);
        pptx(instrumentation, activity, view);
        spreadsheet(instrumentation, activity, view);
        instrumentation.runOnMainSync(() -> { view.clear(); view.requestLayout(); });
        results.append("PASS selection state machine, handles, clipboard and accessibility actions\n");
        return results.toString();
    }

    // ------------------------------------------------------------------
    // DOCX：公开 API、剪贴板、无障碍动作与高亮绘制
    // ------------------------------------------------------------------

    private static void docx(OfficeInstrumentation instrumentation, PreviewTestActivity activity,
                             OfficePreviewView view) throws Exception {
        open(instrumentation, view, "sample.docx", "DOCX");
        instrumentation.runOnMainChecked(() -> view.layout(0, 0, 1080, 1600));

        // 1. 未选中时的默认态
        boolean hasSelection = read(instrumentation, view::hasSelection);
        String selected = read(instrumentation, view::getSelectedText);
        instrumentation.check(!hasSelection && "".equals(selected),
            "Fresh DOCX has no selection and empty text");
        instrumentation.check(!read(instrumentation, view::copySelection),
            "Copy without a selection is refused");

        // 2. 全选：文本完整、跨段换行、不引入空段落占位空格
        instrumentation.check(read(instrumentation, view::selectAll), "DOCX select-all succeeds");
        instrumentation.check(read(instrumentation, view::hasSelection), "Select-all leaves a selection");
        String all = read(instrumentation, view::getSelectedText);
        // 测试固件 sample.docx 由 core/tests/support/docx.rs 生成，正文含标题、表格、页眉与页脚
        instrumentation.check(all.contains("中文 Office") && all.contains("English regular")
            && all.contains("Plain paragraph with"), "Selected text covers the document body");
        instrumentation.check(all.contains("Language") && all.contains("Greeting")
            && all.contains("Hello 你好") && all.contains("中文"),
            "Selected text includes table cells as independent blocks");
        instrumentation.check(all.contains("示例文档") && all.contains("页脚"),
            "Selected text covers header and footer flow text");
        instrumentation.check(all.contains("\n") && !all.startsWith("\n") && !all.endsWith("\n"),
            "Cross-paragraph selection joins with newlines and trims block edges");
        instrumentation.check(!hasPlaceholderOnlyLine(all),
            "Selected text carries no blank-paragraph placeholder spaces");
        instrumentation.check(countLines(all) >= 6, "Select-all spans every text paragraph: " + countLines(all));

        // 3. 高亮确实参与绘制（全选前后逐像素比对）
        int changed = read(instrumentation, () -> highlightPixels(view, 1080, 1600));
        instrumentation.check(changed > MIN_HIGHLIGHT_PIXELS,
            "Selection highlight changes rendered pixels: " + changed);

        // 4. 剪贴板写入与选区保留
        instrumentation.check(read(instrumentation, view::copySelection), "DOCX copy succeeds");
        instrumentation.check(all.equals(clipboard(instrumentation, activity)),
            "Clipboard holds exactly the selected text");
        instrumentation.check(read(instrumentation, view::hasSelection),
            "Programmatic copy keeps the selection");

        // 5. 清除
        instrumentation.runOnMainChecked(view::clearSelection);
        instrumentation.check(!read(instrumentation, view::hasSelection)
            && "".equals(read(instrumentation, view::getSelectedText)), "Clear selection resets state");

        // 6. 无障碍动作
        accessibilityActions(instrumentation, activity, view);
    }

    /** 多行自动折行段落：验证非末行行尾高亮宽度不退化，且行中点命中不短路到行尾 */
    private static void multilineWrapping(OfficeInstrumentation instrumentation) {
        OfficeDocument doc = new OfficeDocument();
        doc.kind = OfficeDocument.Kind.DOCX;
        doc.width = 240f;
        doc.marginLeft = 20f;
        doc.marginRight = 20f;
        OfficeDocument.Element element = new OfficeDocument.Element();
        element.type = OfficeDocument.Type.TEXT;
        OfficeDocument.Paragraph para = new OfficeDocument.Paragraph();
        OfficeDocument.Run run = new OfficeDocument.Run();
        run.text = "Alpha Beta Gamma Delta Epsilon Zeta Eta Theta Iota Kappa Lambda";
        run.size = 14f;
        para.runs.add(run);
        element.paragraphs.add(para);
        doc.blocks.add(element);

        OfficeRenderer renderer = new OfficeRenderer();
        renderer.layout(doc);
        TextSelectionModel.DocumentTextLayout layout = AndroidTextLayoutBuilder.build(doc, renderer);
        instrumentation.check(layout.blockCount() == 1, "Multiline fixture builds single block");
        TextSelectionModel.TextBlockLayout block = layout.blocks().get(0);
        instrumentation.check(block.lines().size() >= 2,
            "Multiline paragraph wraps into multiple lines: " + block.lines().size());

        TextSelectionModel.TextSelection all = layout.allTextRange();
        List<TextSelectionModel.Rect> rects = layout.selectionRects(all);
        instrumentation.check(rects.size() >= 2, "Multiline select-all yields multiple highlight rects");
        TextSelectionModel.Rect firstLineRect = rects.get(0);
        instrumentation.check(firstLineRect.width() > 40f,
            "First line highlight width must span wrapped line instead of collapsing: " + firstLineRect.width());

        TextSelectionModel.LineMetrics firstLine = block.lines().get(0);
        float midX = block.bounds().left + (firstLine.left() + firstLine.right()) * 0.5f;
        float midY = block.bounds().top + (firstLine.top() + firstLine.bottom()) * 0.5f;
        TextSelectionModel.TextPosition midHit = layout.hitTest(midX, midY);
        instrumentation.check(midHit != null
                && midHit.charIndex > firstLine.charStart()
                && midHit.charIndex < firstLine.charEnd(),
            "Middle hit on wrapped first line does not short-circuit to lineEnd: " + midHit);
    }

    /** 无障碍动作 ID 与文案：全选文本 / 复制选中文本 / 清除选区 */
    private static void accessibilityActions(OfficeInstrumentation instrumentation,
                                             PreviewTestActivity activity, OfficePreviewView view) throws Exception {
        int selectAll = actionId("ACTION_SELECT_ALL");
        int copy = actionId("ACTION_COPY_SELECTION");
        int clear = actionId("ACTION_CLEAR_SELECTION");
        instrumentation.check(hasAction(instrumentation, view, selectAll, "全选文本"),
            "Select-all action is exposed for DOCX");
        instrumentation.check(!hasAction(instrumentation, view, copy, "复制选中文本")
            && !hasAction(instrumentation, view, clear, "清除选区"),
            "Copy and clear actions require an active selection");
        instrumentation.check(read(instrumentation, () -> view.performAccessibilityAction(selectAll, null)),
            "Accessibility action handled: ACTION_SELECT_ALL");
        instrumentation.check(read(instrumentation, view::hasSelection),
            "Select-all action creates a selection");
        instrumentation.check(hasAction(instrumentation, view, copy, "复制选中文本")
            && hasAction(instrumentation, view, clear, "清除选区"),
            "Copy and clear actions appear once a selection exists");
        instrumentation.check(read(instrumentation, () -> view.performAccessibilityAction(copy, null)),
            "Accessibility action handled: ACTION_COPY_SELECTION");
        String selected = read(instrumentation, view::getSelectedText);
        instrumentation.check(selected.equals(clipboard(instrumentation, activity)),
            "Accessibility copy writes the selection to the clipboard");
        instrumentation.check(read(instrumentation, () -> view.performAccessibilityAction(clear, null)),
            "Accessibility action handled: ACTION_CLEAR_SELECTION");
        instrumentation.check(!read(instrumentation, view::hasSelection),
            "Clear action removes the selection");
        instrumentation.check(!read(instrumentation, () -> view.performAccessibilityAction(clear, null)),
            "Clear action is refused when nothing is selected");
    }

    // ------------------------------------------------------------------
    // 手势：真实长按选词、拖拽扩选与单击清除
    // ------------------------------------------------------------------

    private static void longPressAndDrag(OfficeInstrumentation instrumentation,
                                         PreviewTestActivity activity, OfficePreviewView view) throws Exception {
        instrumentation.runOnMainChecked(() -> view.clearSelection());
        // 用文本索引反查真实文字位置，避免依赖固定屏幕比例而落在空白处
        float[] point = read(instrumentation, () -> screenPointInText(view, "Plain"));
        float x = point[0], y = point[1];
        instrumentation.check(x >= 0 && y >= 0, "Located a text position for long press: " + x + "," + y);

        // 1. 长按：ACTION_DOWN 后必须真实等待超过系统长按超时，长按消息才能投递
        long down = SystemClock.uptimeMillis();
        feed(instrumentation, view, down, down, MotionEvent.ACTION_DOWN, x, y);
        SystemClock.sleep(ViewConfiguration.getLongPressTimeout() + 150L);
        instrumentation.check(read(instrumentation, view::hasSelection),
            "Long press selects the word under the finger");
        String word = read(instrumentation, view::getSelectedText);
        instrumentation.check(!word.isEmpty() && countLines(word) == 1,
            "Long press selects a single-line word range: " + word);

        // 2. 不抬手向右拖拽扩选
        for (int step = 1; step <= 3; step++) {
            feed(instrumentation, view, down, down + step * 40L, MotionEvent.ACTION_MOVE,
                x + step * 90f, y);
        }
        String dragged = read(instrumentation, view::getSelectedText);
        instrumentation.check(!dragged.isEmpty() && !dragged.equals(word),
            "Dragging past the long press extends the selection: " + dragged);

        // 3. 抬手后选区保留
        feed(instrumentation, view, down, down + 200L, MotionEvent.ACTION_UP, x + 270f, y);
        instrumentation.check(read(instrumentation, view::hasSelection),
            "Selection survives release");

        // 4. 单击文档外缘清除选区（远离手柄热区，避免误命中拖拽）
        float clearX = read(instrumentation, () -> view.getWidth() - 8f);
        float clearY = read(instrumentation, () -> view.getHeight() - 8f);
        long tap = SystemClock.uptimeMillis();
        feed(instrumentation, view, tap, tap, MotionEvent.ACTION_DOWN, clearX, clearY);
        feed(instrumentation, view, tap, tap + 40L, MotionEvent.ACTION_UP, clearX, clearY);
        // 单击清除延迟到 onSingleTapConfirmed，必须等过双击判定窗口再断言
        SystemClock.sleep(ViewConfiguration.getDoubleTapTimeout() + 200L);
        instrumentation.check(!read(instrumentation, view::hasSelection),
            "Single tap clears an existing selection");

        // 5. 手柄拖拽：全选后拖起始手柄（位于文档顶部，首屏可见）向下，从锚点末端收窄选区
        instrumentation.runOnMainChecked(view::selectAll);
        float[] handle = read(instrumentation, () -> selectionHandleScreenPoint(view, "start"));
        instrumentation.check(handle[0] >= 0 && handle[1] >= 0,
            "Start handle geometry is available after select-all: " + handle[0] + "," + handle[1]);
        int beforeDrag = read(instrumentation, () -> view.getSelectedText().length());
        long dragTime = SystemClock.uptimeMillis();
        feed(instrumentation, view, dragTime, dragTime, MotionEvent.ACTION_DOWN, handle[0], handle[1]);
        // 拖动幅度取视口高度的三分之一，确保焦点确实落到后续段落，而不是停在同一个词里
        float travel = read(instrumentation, () -> view.getHeight() / 3f);
        for (int step = 1; step <= 5; step++) {
            feed(instrumentation, view, dragTime, dragTime + step * 40L, MotionEvent.ACTION_MOVE,
                handle[0], handle[1] + travel * step / 5f);
        }
        feed(instrumentation, view, dragTime, dragTime + 260L, MotionEvent.ACTION_UP,
            handle[0], handle[1] + travel);
        int afterDrag = read(instrumentation, () -> view.getSelectedText().length());
        instrumentation.check(read(instrumentation, view::hasSelection) && afterDrag < beforeDrag,
            "Dragging the start handle shrinks the selection: " + beforeDrag + " -> " + afterDrag);
        instrumentation.runOnMainChecked(view::clearSelection);

        // 6. 单指拖拽滚动与双击缩放零退化
        instrumentation.runOnMainChecked(() -> view.layout(0, 0, 1080, 400));
        float before = read(instrumentation, () -> offsetY(view));
        long drag = SystemClock.uptimeMillis();
        feed(instrumentation, view, drag, drag, MotionEvent.ACTION_DOWN, 400, 360);
        for (int step = 1; step <= 8; step++) {
            feed(instrumentation, view, drag, drag + step * 16L, MotionEvent.ACTION_MOVE, 400, 360 - step * 40);
        }
        feed(instrumentation, view, drag, drag + 160L, MotionEvent.ACTION_UP, 400, 40);
        instrumentation.check(read(instrumentation, () -> offsetY(view)) > before,
            "Single-finger drag still scrolls the document");
        // 拖拽滚动不得顺带产生选区
        instrumentation.check(!read(instrumentation, view::hasSelection),
            "Plain drag does not create a selection");
        instrumentation.runOnMainChecked(() -> { view.layout(0, 0, 1080, 1600); view.resetZoom(); });
    }

    // ------------------------------------------------------------------
    // PPTX：跨页全选、复制、当前页长按选词与翻页清选区
    // ------------------------------------------------------------------

    private static void pptx(OfficeInstrumentation instrumentation, PreviewTestActivity activity,
                             OfficePreviewView view) throws Exception {
        open(instrumentation, view, "sample.pptx", "PPTX");
        instrumentation.runOnMainChecked(() -> view.layout(0, 0, 1080, 1600));

        instrumentation.check(read(instrumentation, view::selectAll), "PPTX select-all succeeds");
        String all = read(instrumentation, view::getSelectedText);
        // 测试固件 sample.pptx 两页：第 1 页标题与表格来自 slide2.xml（sldIdLst 中排首位），
        // 第 2 页标题来自 slide1.xml，因此阅读顺序为 "First 中文" 在前、"Second English" 在后
        instrumentation.check(all.contains("First 中文") && all.contains("Hello 你好"),
            "Select-all covers the first slide and its table cells");
        instrumentation.check(all.contains("Second English"), "Select-all covers the second slide");
        instrumentation.check(all.indexOf("First 中文") < all.indexOf("Second English"),
            "Select-all concatenates slides in presentation order");
        instrumentation.check(read(instrumentation, view::copySelection)
            && all.equals(clipboard(instrumentation, activity)), "PPTX copy writes the whole deck text");

        // 翻页属于离散导航：选区与手柄必须随页面离开而收起
        instrumentation.runOnMainChecked(() -> view.jumpToPage(2));
        instrumentation.check(!read(instrumentation, view::hasSelection),
            "Jumping to another slide clears the selection");
        instrumentation.runOnMainChecked(() -> view.jumpToPage(1));

        // 当前幻灯片上长按选词
        instrumentation.runOnMainChecked(() -> view.clearSelection());
        float x = read(instrumentation, () -> view.getWidth() / 2f);
        float y = read(instrumentation, () -> view.getHeight() / 4f);
        long down = SystemClock.uptimeMillis();
        feed(instrumentation, view, down, down, MotionEvent.ACTION_DOWN, x, y);
        SystemClock.sleep(ViewConfiguration.getLongPressTimeout() + 150L);
        instrumentation.check(read(instrumentation, view::hasSelection),
            "Long press selects slide text");
        feed(instrumentation, view, down, down + 120L, MotionEvent.ACTION_UP, x, y);
        instrumentation.check(read(instrumentation, view::hasSelection),
            "Slide selection survives release");
        instrumentation.runOnMainChecked(view::clearSelection);
    }

    // ------------------------------------------------------------------
    // XLSX：不支持自由划词的边界
    // ------------------------------------------------------------------

    private static void spreadsheet(OfficeInstrumentation instrumentation, PreviewTestActivity activity,
                                    OfficePreviewView view) throws Exception {
        open(instrumentation, view, "sample.xlsx", "XLSX");
        instrumentation.runOnMainChecked(() -> view.layout(0, 0, 1080, 1600));
        instrumentation.check(!read(instrumentation, view::selectAll), "XLSX select-all is refused");
        instrumentation.check(!read(instrumentation, view::hasSelection), "XLSX has no selection");
        instrumentation.check(!read(instrumentation, view::copySelection), "XLSX copy is refused");
        instrumentation.check(!hasAction(instrumentation, view, actionId("ACTION_SELECT_ALL"), "全选文本"),
            "Spreadsheet exposes no select-all action");

        float x = read(instrumentation, () -> view.getWidth() / 2f);
        float y = read(instrumentation, () -> view.getHeight() / 3f);
        long down = SystemClock.uptimeMillis();
        feed(instrumentation, view, down, down, MotionEvent.ACTION_DOWN, x, y);
        SystemClock.sleep(ViewConfiguration.getLongPressTimeout() + 150L);
        feed(instrumentation, view, down, down + 150L, MotionEvent.ACTION_UP, x, y);
        instrumentation.check(!read(instrumentation, view::hasSelection),
            "Long press never starts a selection in a spreadsheet");
    }

    // ------------------------------------------------------------------
    // 辅助
    // ------------------------------------------------------------------

    private static void open(OfficeInstrumentation instrumentation, OfficePreviewView view,
                             String name, String format) throws Exception {
        CountDownLatch latch = new CountDownLatch(1);
        AtomicReference<String> detected = new AtomicReference<>();
        AtomicReference<Exception> failure = new AtomicReference<>();
        Uri source = Uri.parse("content://" + instrumentation.getTargetContext().getPackageName() + ".fixtures/" + name);
        instrumentation.runOnMainSync(() -> view.open(source, new OfficePreviewView.Listener() {
            @Override public void onLoaded(OfficePreviewView.Info info) { detected.set(info.format); latch.countDown(); }
            @Override public void onError(Exception error) { failure.set(error); latch.countDown(); }
        }));
        instrumentation.check(latch.await(20, TimeUnit.SECONDS) && failure.get() == null, "Opens fixture: " + name);
        instrumentation.check(format.equals(detected.get()), "Format detected: " + format);
        instrumentation.check(!read(instrumentation, view::hasSelection),
            "Opening a document starts without a selection: " + name);
    }

    /** 派发一次触摸事件；{@code time} 严格按真实时间轴推进才能命中长按判定 */
    private static void feed(final OfficeInstrumentation instrumentation, final OfficePreviewView view,
                             final long downTime, final long eventTime, final int action,
                             final float x, final float y) throws Exception {
        instrumentation.runOnMainSync(() -> {
            MotionEvent event = MotionEvent.obtain(downTime, eventTime, action, x, y, 0);
            try { view.dispatchTouchEvent(event); } finally { event.recycle(); }
        });
    }

    /**
     * 借视图自身的文本索引与坐标换算，定位某段文字在屏幕上的中心点。
     * 直接读私有 {@code textLayout} 与缩放/偏移字段，避免测试硬编码排版结果。
     */
    private static float[] screenPointInText(OfficePreviewView view, String needle) throws Exception {
        TextSelectionModel.DocumentTextLayout layout = textLayout(view);
        if (layout == null) return new float[] {-1f, -1f};
        for (TextSelectionModel.TextBlockLayout block : layout.blocks()) {
            int index = block.fullText().indexOf(needle);
            if (index < 0) continue;
            TextSelectionModel.TextSelection range = new TextSelectionModel.TextSelection(
                new TextSelectionModel.TextPosition(block.blockIndex, index),
                new TextSelectionModel.TextPosition(block.blockIndex, index + needle.length()));
            TextSelectionModel.SelectionHandles handles = layout.handleGeometry(range);
            if (handles == null) continue;
            float x = docToScreenX(view, (handles.start.docX + handles.end.docX) / 2f);
            float y = docToScreenY(view, (handles.start.docTopY + handles.start.docBottomY) / 2f);
            if (x >= 0 && y >= 0 && x <= view.getWidth() && y <= view.getHeight()) return new float[] {x, y};
        }
        return new float[] {-1f, -1f};
    }

    /** 取起始/结束手柄的水滴圆心屏幕坐标 */
    private static float[] selectionHandleScreenPoint(OfficePreviewView view, String which) throws Exception {
        TextSelectionModel.TextSelection selection = selection(view);
        TextSelectionModel.DocumentTextLayout layout = textLayout(view);
        if (selection == null || layout == null) return new float[] {-1f, -1f};
        TextSelectionModel.SelectionHandles handles = layout.handleGeometry(selection);
        if (handles == null) return new float[] {-1f, -1f};
        TextSelectionModel.HandlePoint point = "end".equals(which) ? handles.end : handles.start;
        Field offset = OfficePreviewView.class.getDeclaredField("handleCenterOffset");
        offset.setAccessible(true);
        int centerOffset = offset.getInt(view);
        return new float[] {docToScreenX(view, point.docX),
            docToScreenY(view, point.docBottomY) + centerOffset};
    }

    private static TextSelectionModel.TextSelection selection(OfficePreviewView view) throws Exception {
        Field declared = OfficePreviewView.class.getDeclaredField("selection");
        declared.setAccessible(true);
        return (TextSelectionModel.TextSelection) declared.get(view);
    }

    private static void restoreSelection(OfficePreviewView view,
                                         TextSelectionModel.TextSelection value) throws Exception {
        Field declared = OfficePreviewView.class.getDeclaredField("selection");
        declared.setAccessible(true);
        declared.set(view, value);
        view.invalidate();
    }

    private static TextSelectionModel.DocumentTextLayout textLayout(OfficePreviewView view) throws Exception {
        Field declared = OfficePreviewView.class.getDeclaredField("textLayout");
        declared.setAccessible(true);
        return (TextSelectionModel.DocumentTextLayout) declared.get(view);
    }

    /** 文档坐标 → 屏幕坐标，复用与视图内部一致的换算规则 */
    private static float docToScreenX(OfficePreviewView view, float docX) throws Exception {
        return docX * scale(view) - offset(view, "offsetX") + left(view);
    }

    private static float docToScreenY(OfficePreviewView view, float docY) throws Exception {
        return docY * scale(view) - offset(view, "offsetY") + top(view);
    }

    private static float scale(OfficePreviewView view) throws Exception {
        java.lang.reflect.Method method = OfficePreviewView.class.getDeclaredMethod("scale");
        method.setAccessible(true);
        return (Float) method.invoke(view);
    }

    private static float left(OfficePreviewView view) throws Exception {
        java.lang.reflect.Method method = OfficePreviewView.class.getDeclaredMethod("left");
        method.setAccessible(true);
        return (Float) method.invoke(view);
    }

    private static float top(OfficePreviewView view) throws Exception {
        java.lang.reflect.Method method = OfficePreviewView.class.getDeclaredMethod("top");
        method.setAccessible(true);
        return (Float) method.invoke(view);
    }

    private static float offset(OfficePreviewView view, String field) throws Exception {
        Field declared = OfficePreviewView.class.getDeclaredField(field);
        declared.setAccessible(true);
        return declared.getFloat(view);
    }

    /**
     * 全选高亮前后逐像素比对，返回采样的差异像素数。
     *
     * <p>比对需要临时清除选区，因此先快照选区字段再恢复，调用方的选区状态不受影响。
     */
    private static int highlightPixels(OfficePreviewView view, int width, int height) throws Exception {
        Bitmap withSelection = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
        Bitmap withoutSelection = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
        TextSelectionModel.TextSelection snapshot = selection(view);
        try {
            view.draw(new Canvas(withSelection));
            view.clearSelection();
            view.draw(new Canvas(withoutSelection));
            restoreSelection(view, snapshot);
            int changed = 0;
            for (int y = 0; y < height; y += 2) {
                for (int x = 0; x < width; x += 2) {
                    if (withSelection.getPixel(x, y) != withoutSelection.getPixel(x, y)) changed++;
                }
            }
            return changed;
        } finally {
            withSelection.recycle();
            withoutSelection.recycle();
        }
    }

    private static String clipboard(OfficeInstrumentation instrumentation, PreviewTestActivity activity) throws Exception {
        AtomicReference<String> text = new AtomicReference<>("");
        instrumentation.runOnMainSync(() -> {
            Object service = activity.getSystemService(Context.CLIPBOARD_SERVICE);
            if (!(service instanceof ClipboardManager)) return;
            ClipboardManager manager = (ClipboardManager) service;
            if (manager.hasPrimaryClip() && manager.getPrimaryClip() != null
                && manager.getPrimaryClip().getItemCount() > 0) {
                CharSequence value = manager.getPrimaryClip().getItemAt(0).coerceToText(activity);
                text.set(value == null ? "" : value.toString());
            }
        });
        return text.get();
    }

    /** 是否存在整行只有空格的行（空段落占位符不应进入选区文本） */
    private static boolean hasPlaceholderOnlyLine(String text) {
        for (String line : text.split("\n", -1)) {
            if (!line.isEmpty() && line.trim().isEmpty()) return true;
        }
        return false;
    }

    private static int countLines(String text) {
        return text.split("\n", -1).length;
    }

    private static boolean hasAction(OfficeInstrumentation instrumentation, OfficePreviewView view,
                                     int id, String label) throws Exception {
        return read(instrumentation, () -> hasActionOnMain(view, id, label));
    }

    private static boolean hasActionOnMain(OfficePreviewView view, int id, String label) {
        List<AccessibilityNodeInfo.AccessibilityAction> actions = view.createAccessibilityNodeInfo().getActionList();
        for (int i = 0; i < actions.size(); i++) {
            AccessibilityNodeInfo.AccessibilityAction action = actions.get(i);
            if (action.getId() == id && action.getLabel() != null
                && label.contentEquals(action.getLabel())) return true;
        }
        return false;
    }

    /** 读取 {@link OfficePreviewView} 的私有动作 ID 常量，重命名时本检查立刻失败 */
    private static int actionId(String field) throws Exception {
        Field declared = OfficePreviewView.class.getDeclaredField(field);
        declared.setAccessible(true);
        return declared.getInt(null);
    }

    private static float offsetY(OfficePreviewView view) throws Exception {
        Field declared = OfficePreviewView.class.getDeclaredField("offsetY");
        declared.setAccessible(true);
        return declared.getFloat(view);
    }

    private interface Supplier<T> { T get() throws Exception; }

    private static <T> T read(OfficeInstrumentation instrumentation, Supplier<T> supplier) throws Exception {
        AtomicReference<T> value = new AtomicReference<>();
        AtomicReference<Throwable> failure = new AtomicReference<>();
        instrumentation.runOnMainSync(() -> {
            try { value.set(supplier.get()); } catch (Throwable error) { failure.set(error); }
        });
        if (failure.get() instanceof Exception) throw (Exception) failure.get();
        if (failure.get() instanceof AssertionError) throw (AssertionError) failure.get();
        if (failure.get() instanceof Error) throw (Error) failure.get();
        return value.get();
    }
}
