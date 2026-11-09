package cn.jingzhuan.lib.office;

import android.animation.Animator;
import android.animation.AnimatorListenerAdapter;
import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.graphics.RectF;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.Parcel;
import android.os.Parcelable;
import android.text.StaticLayout;
import android.util.AttributeSet;
import android.util.TypedValue;
import android.view.GestureDetector;
import android.view.MotionEvent;
import android.view.ScaleGestureDetector;
import android.view.View;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.animation.DecelerateInterpolator;
import android.widget.OverScroller;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.Future;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

public final class OfficePreviewView extends View {
    /** 读屏自定义动作 ID：取 0x7f11 段，与框架标准动作（均小于 0x01000000）互不冲突 */
    private static final int ACTION_PREVIOUS = 0x7f110001;
    private static final int ACTION_NEXT = 0x7f110002;
    private static final int ACTION_ZOOM_IN = 0x7f110003;
    private static final int ACTION_ZOOM_OUT = 0x7f110004;
    private static final int ACTION_RESET_ZOOM = 0x7f110005;

    /** 缩放上限；下限见 {@link #minZoom()}，读屏动作菜单复用同一组边界 */
    private static final float MAX_ZOOM = 4f;
    /** 越界容许幅度：超出上限时最多再多显示 0.4 倍缩放 */
    private static final float OVERFLOW_ABOVE = 0.4f;
    /** 越界容许幅度：跌破下限时最多再多缩 0.1 倍，避免页面缩得过小 */
    private static final float OVERFLOW_BELOW = 0.1f;
    /** 缩放补间与越界回弹时长；系统关闭动画时长缩放时由框架退化为瞬时 */
    private static final long ZOOM_ANIMATION_MS = 220;

    public interface Listener {
        void onLoaded(Info info);
        void onError(Exception error);
    }

    public interface OnPageChangeListener {
        void onPageChanged(int pageNumber, int pageCount);
    }

    public interface SearchListener {
        void onSearchResults(String query, int matchCount);
        void onCurrentMatchChanged(int currentIndex, int matchCount, SearchMatch match);
    }

    public interface SearchCallback {
        void onResult(List<SearchMatch> matches);
        void onError(Exception error);
    }

    public static final class SearchMatch {
        public final int pageIndex;
        public final int elementIndex;
        public final int paragraphIndex;
        public final int row;
        public final int column;
        public final int startChar;
        public final int endChar;
        public final String snippet;

        SearchMatch(OfficeDocument.SearchMatch internal) {
            this.pageIndex = internal.pageIndex;
            this.elementIndex = internal.elementIndex;
            this.paragraphIndex = internal.paragraphIndex;
            this.row = internal.row;
            this.column = internal.column;
            this.startChar = internal.startChar;
            this.endChar = internal.endChar;
            this.snippet = internal.snippet != null ? internal.snippet : "";
        }

        public SearchMatch(int pageIndex, int elementIndex, int paragraphIndex,
                           int row, int column, int startChar, int endChar, String snippet) {
            this.pageIndex = pageIndex;
            this.elementIndex = elementIndex;
            this.paragraphIndex = paragraphIndex;
            this.row = row;
            this.column = column;
            this.startChar = startChar;
            this.endChar = endChar;
            this.snippet = snippet != null ? snippet : "";
        }
    }

    public static final class Info {
        public final String format;
        public final int pageCount;
        /** Snapshot at onLoaded; PPTX overflow checks cover only slides laid out so far. */
        public final List<String> warnings;
        public final List<String> sheetNames;
        private Info(OfficeDocument document) {
            format = document.kind.name();
            pageCount = document.kind == OfficeDocument.Kind.XLSX ? document.sheets.size()
                : document.kind == OfficeDocument.Kind.PPTX ? document.pages.size() : 1;
            warnings = Collections.unmodifiableList(new ArrayList<>(document.warnings));
            sheetNames = names(document);
        }
    }

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ThreadPoolExecutor executor = new ThreadPoolExecutor(0, 1, 5, TimeUnit.SECONDS,
        new LinkedBlockingQueue<>(), runnable -> {
            Thread thread = new Thread(runnable, "jz-office-open");
            thread.setDaemon(true);
            return thread;
        });
    private Future<?> pending;
    private int generation;
    private OfficeDocument document;
    private OfficeImages images;
    private final OfficeRenderer renderer = new OfficeRenderer();
    private final SheetRenderer sheetRenderer = new SheetRenderer();
    private final RectF sheetViewport = new RectF();
    private OnPageChangeListener pageListener;
    private final List<OnPageChangeListener> pageListeners = new ArrayList<>();
    private int currentPage, notifiedPage, notifiedCount, pendingJumpPage, announcedPage;
    private boolean hasRestoredState;
    private int restoredPage;
    private float restoredZoom = 1, restoredDocX, restoredDocY;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
    private final OverScroller scroller;
    private final GestureDetector gestures;
    private final ScaleGestureDetector pinch;
    private float zoom = 1, offsetX, offsetY, contentWidth, contentHeight;
    /** 捏合过程中累积的原始缩放，允许越界；抵抗量由它与已夹值的差算出，避免回缩时出现滞回 */
    private float rawZoom = 1;
    /** 仅供绘制的临时越界量，非捏合时为 0；实际缩放是 zoom + zoomOverflow */
    private float zoomOverflow;
    private ValueAnimator zoomAnimator;
    private String status = "";
    private String currentFilePath;
    private final List<SearchMatch> searchMatches = new ArrayList<>();
    private int currentMatchIndex = -1;
    private boolean isSearching;
    private String lastSearchQuery = "";
    private RectF targetHighlightRect;
    private Future<?> searchPending;
    private final List<SearchListener> searchListeners = new ArrayList<>();
    private final Paint highlightPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint highlightStrokePaint = new Paint(Paint.ANTI_ALIAS_FLAG);

    public OfficePreviewView(Context context) { this(context, null); }
    public OfficePreviewView(Context context, AttributeSet attrs) {
        super(context, attrs);
        setBackgroundColor(0xffe9ecef);
        setContentDescription("文档预览区域");
        setFocusable(true);
        scroller = new OverScroller(context);
        gestures = new GestureDetector(context, new GestureDetector.SimpleOnGestureListener() {
            @Override public boolean onDown(MotionEvent event) { scroller.forceFinished(true); settleZoom(); return true; }
            @Override public boolean onScroll(MotionEvent first, MotionEvent last, float dx, float dy) {
                if (!pinch.isInProgress()) {
                    float prevX = offsetX, prevY = offsetY;
                    offsetX += dx; offsetY += dy; clampOffsets();
                    if (offsetX == prevX && offsetY == prevY && getParent() != null) {
                        getParent().requestDisallowInterceptTouchEvent(false);
                    }
                    updateCurrentPage(); invalidate();
                }
                return true;
            }
            @Override public boolean onSingleTapUp(MotionEvent event) { performClick(); return true; }
            @Override public boolean onDoubleTap(MotionEvent event) {
                animateZoomTo(zoom > 1.1f ? 1 : 2, event.getX(), event.getY()); return true;
            }
            @Override public boolean onFling(MotionEvent a, MotionEvent b, float vx, float vy) {
                scroller.fling((int) offsetX, (int) offsetY, (int) -vx, (int) -vy, 0, maxX(), 0, maxY());
                postInvalidateOnAnimation(); return true;
            }
        });
        pinch = new ScaleGestureDetector(context, new ScaleGestureDetector.SimpleOnScaleGestureListener() {
            /** 捏合从已夹的缩放起算，保证松手回弹与再次捏合都不残留越界量 */
            @Override public boolean onScaleBegin(ScaleGestureDetector detector) {
                settleZoom();
                return true;
            }
            @Override public boolean onScale(ScaleGestureDetector detector) {
                float factor = detector.getScaleFactor();
                if (Float.isNaN(factor) || Float.isInfinite(factor)) return true;
                rawZoom *= factor;
                float settled = clampZoom(rawZoom);
                float excess = rawZoom - settled;
                float overflow = rubberBand(excess, excess > 0 ? OVERFLOW_ABOVE : OVERFLOW_BELOW);
                applyDisplayZoom(settled, overflow, detector.getFocusX(), detector.getFocusY());
                finishZoomChange();
                return true;
            }
            /** 松手时若仍在越界区，用一段减速动画弹回已夹的缩放值 */
            @Override public void onScaleEnd(ScaleGestureDetector detector) {
                rawZoom = zoom;
                if (zoomOverflow != 0) animateZoomOverflow(detector.getFocusX(), detector.getFocusY());
            }
        });
    }

    public void open(Uri uri, Listener listener) {
        requireMainThread();
        if (uri == null || listener == null) throw new IllegalArgumentException("URI and listener are required");
        cancel();
        releaseImages();
        document = null; renderer.clear(); sheetRenderer.clear(); currentPage = pendingJumpPage = 0;
        zoom = 1; rawZoom = 1; zoomOverflow = 0; offsetX = offsetY = 0;
        contentWidth = contentHeight = 0;
        status = "Loading..."; invalidate();
        announceForAccessibility("正在打开文档");
        announcedPage = 0;
        final int token = generation;
        final Context app = getContext().getApplicationContext();
        pending = executor.submit(() -> {
            OfficePackage opened = null;
            try {
                opened = OfficePackage.open(app, uri);
                OfficeDocument loaded = opened.document;
                OfficePackage.checkCancelled();
                final String filePath = opened.file.getAbsolutePath();
                final SheetLayout preparedSheet;
                final OfficeRenderer preparedRenderer;
                if (loaded.kind == OfficeDocument.Kind.XLSX) {
                    closePackage(opened);
                    opened = null;
                    preparedSheet = new SheetLayout(loaded.sheets.get(0), SheetRenderer.HEADER_WIDTH, SheetRenderer.HEADER_HEIGHT);
                    preparedRenderer = null;
                } else {
                    preparedSheet = null;
                    preparedRenderer = new OfficeRenderer();
                    preparedRenderer.layout(loaded);
                }
                OfficePackage.checkCancelled();
                final OfficePackage source = opened;
                main.post(() -> {
                    if (token != generation) { if (source != null) closePackage(source); return; }
                    currentFilePath = filePath;
                    clearSearch();
                    document = loaded; status = ""; currentPage = 1;
                    if (isSpreadsheet()) {
                        if (hasRestoredState && restoredPage > 1 && restoredPage <= loaded.sheets.size()) {
                            sheetRenderer.setSheet(loaded.sheets.get(restoredPage - 1), loaded.cellStyles);
                            currentPage = restoredPage;
                        } else {
                            sheetRenderer.setSheet(loaded.sheets.get(0), loaded.cellStyles, preparedSheet);
                        }
                        contentWidth = sheetRenderer.width; contentHeight = sheetRenderer.height;
                    } else {
                        images = new OfficeImages(source, this::invalidate, listener);
                        renderer.adopt(preparedRenderer);
                        contentWidth = renderer.width; contentHeight = renderer.height;
                        if (hasRestoredState && restoredPage >= 1 && restoredPage <= renderer.pages.size()) {
                            currentPage = restoredPage;
                        }
                    }
                    if (!applyRestoredState()) clampOffsets();
                    invalidate();
                    setContentDescription(describeDocument(loaded));
                    listener.onLoaded(new Info(loaded));
                    if (token == generation) updateCurrentPage();
                });
                opened = null;
            } catch (IOException | RuntimeException | LinkageError | OutOfMemoryError failure) {
                Exception error = failure instanceof Exception ? (Exception) failure
                    : failure instanceof OutOfMemoryError ? new IOException("Not enough memory to open document", failure)
                    : new IOException("Native core is unavailable for this device ABI", failure);
                main.post(() -> {
                    if (token != generation) return;
                    status = "Unable to open document"; invalidate();
                    setContentDescription(null);
                    String reason = error.getMessage();
                    announceForAccessibility(reason == null || reason.isEmpty() ? "无法打开文档" : "无法打开文档：" + reason);
                    listener.onError(error);
                });
            } finally {
                if (opened != null) closePackage(opened);
            }
        });
        notifyPageChanged();
    }

    public void clear() {
        requireMainThread(); cancel(); clearSearch(); currentFilePath = null; releaseImages(); document = null; renderer.clear(); sheetRenderer.clear(); currentPage = pendingJumpPage = 0;
        hasRestoredState = false; announcedPage = 0;
        setContentDescription(null);
        contentWidth = contentHeight = offsetX = offsetY = 0;
        status = ""; invalidate(); notifyPageChanged();
    }

    public void resetZoom() { requireMainThread(); setZoom(1, getWidth() / 2f, getHeight() / 2f); }

    public void setZoom(float value) { requireMainThread(); setZoom(value, getWidth() / 2f, getHeight() / 2f); }

    public float getZoom() { return zoom; }

    public int getPageCount() { return isSpreadsheet() ? document.sheets.size() : renderer.pages.size(); }

    public int getCurrentPage() { return currentPage; }

    public List<String> getSheetNames() { return document == null ? Collections.emptyList() : names(document); }

    public void selectSheet(int sheetNumber) {
        requireMainThread();
        if (!isSpreadsheet() || sheetNumber < 1 || sheetNumber > document.sheets.size()) throw new IllegalArgumentException("Sheet number is outside the loaded workbook");
        settleZoom();
        scroller.forceFinished(true);
        if (sheetNumber != currentPage) {
            sheetRenderer.setSheet(document.sheets.get(sheetNumber - 1), document.cellStyles);
            contentWidth = sheetRenderer.width; contentHeight = sheetRenderer.height;
        }
        currentPage = sheetNumber; pendingJumpPage = 0; offsetX = offsetY = 0;
        invalidate(); notifyPageChanged();
    }

    private boolean isSpreadsheet() { return document != null && document.kind == OfficeDocument.Kind.XLSX; }

    private static List<String> names(OfficeDocument document) {
        List<String> names = new ArrayList<>();
        for (SpreadsheetDocument.Sheet sheet : document.sheets) names.add(sheet.name);
        return Collections.unmodifiableList(names);
    }

    public void setOnPageChangeListener(OnPageChangeListener listener) {
        requireMainThread(); pageListener = listener;
        notifiedPage = currentPage; notifiedCount = getPageCount();
        if (listener != null) listener.onPageChanged(currentPage, getPageCount());
    }

    public void addOnPageChangeListener(OnPageChangeListener listener) {
        requireMainThread();
        if (listener != null && !pageListeners.contains(listener)) {
            pageListeners.add(listener);
            listener.onPageChanged(currentPage, getPageCount());
        }
    }

    public void removeOnPageChangeListener(OnPageChangeListener listener) {
        requireMainThread();
        pageListeners.remove(listener);
    }

    public void jumpToPage(int pageNumber) {
        requireMainThread();
        if (pageNumber < 1 || pageNumber > getPageCount()) throw new IllegalArgumentException("Page number is outside the loaded document");
        if (isSpreadsheet()) { selectSheet(pageNumber); return; }
        settleZoom();
        scroller.forceFinished(true);
        currentPage = pageNumber;
        if (getWidth() == 0 || getHeight() == 0) {
            pendingJumpPage = pageNumber; notifyPageChanged(); invalidate(); return;
        }
        scrollToPage(pageNumber); pendingJumpPage = 0; updateCurrentPage(); invalidate();
    }

    private void scrollToPage(int pageNumber) {
        offsetX = 0; offsetY = renderer.pages.get(pageNumber - 1).y * scale(); clampOffsets();
    }

    private boolean applyPendingJump() {
        if (pendingJumpPage == 0 || getWidth() == 0 || getHeight() == 0 || pendingJumpPage > getPageCount()) return false;
        scrollToPage(pendingJumpPage); pendingJumpPage = 0; updateCurrentPage(); return true;
    }

    private void updateCurrentPage() {
        if (isSpreadsheet()) { notifyPageChanged(); return; }
        if (renderer.pages.isEmpty()) currentPage = 0;
        else if (getWidth() > 0 && getHeight() > 0) {
            float visibleTop = (offsetY - top()) / scale();
            float visibleBottom = visibleTop + getHeight() / scale();
            int bestPage = Math.max(1, currentPage);
            float bestVisible = -1;
            for (int i = 0; i < renderer.pages.size(); i++) {
                OfficeRenderer.Page page = renderer.pages.get(i);
                float visible = Math.max(0, Math.min(visibleBottom, page.y + page.height) - Math.max(visibleTop, page.y));
                if (visible > bestVisible + 0.01f || (Math.abs(visible - bestVisible) <= 0.01f && i + 1 == currentPage)) {
                    bestVisible = visible; bestPage = i + 1;
                }
            }
            currentPage = bestPage;
        }
        notifyPageChanged();
    }

    private void notifyPageChanged() {
        int count = getPageCount();
        if (notifiedPage == currentPage && notifiedCount == count) return;
        notifiedPage = currentPage; notifiedCount = count;
        if (pageListener != null) pageListener.onPageChanged(currentPage, count);
        if (!pageListeners.isEmpty()) {
            List<OnPageChangeListener> copy = new ArrayList<>(pageListeners);
            for (int i = 0; i < copy.size(); i++) {
                copy.get(i).onPageChanged(currentPage, count);
            }
        }
        announcePageIfSettled();
    }

    /** 向读屏软件播报当前页码；惯性滚动期间保持静默，避免连续翻页时反复打断 */
    private void announcePageIfSettled() {
        if (document == null || announcedPage == currentPage || !scroller.isFinished()) return;
        announcedPage = currentPage;
        refreshAccessibilityActions();
        if (isSpreadsheet()) {
            List<String> sheetNames = names(document);
            announceForAccessibility("工作表 " + sheetNames.get(currentPage - 1) + "，第 " + currentPage + " 个，共 " + sheetNames.size() + " 个工作表");
        } else {
            announceForAccessibility("第 " + currentPage + " 页，共 " + renderer.pages.size() + " 页");
        }
    }

    /** 按当前状态重建读屏动作菜单（翻页/切表/缩放/滚动入口）；读屏不可用时为空操作 */
    @Override public void onInitializeAccessibilityNodeInfo(AccessibilityNodeInfo info) {
        super.onInitializeAccessibilityNodeInfo(info);
        if (document == null) return;
        int total = getPageCount();
        if (isSpreadsheet()) {
            if (currentPage > 1) info.addAction(action(ACTION_PREVIOUS, "上一个工作表"));
            if (currentPage < total) info.addAction(action(ACTION_NEXT, "下一个工作表"));
        } else if (total > 1) {
            if (currentPage > 1) info.addAction(action(ACTION_PREVIOUS, "上一页"));
            if (currentPage < total) info.addAction(action(ACTION_NEXT, "下一页"));
        }
        if (zoom < MAX_ZOOM) info.addAction(action(ACTION_ZOOM_IN, "放大"));
        if (zoom > minZoom()) info.addAction(action(ACTION_ZOOM_OUT, "缩小"));
        if (zoom > 1.001f) info.addAction(action(ACTION_RESET_ZOOM, "重置缩放"));
        if (canScrollVertically(1)) info.addAction(action(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD, "向下滚动"));
        if (canScrollVertically(-1)) info.addAction(action(AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD, "向上滚动"));
    }

    private static AccessibilityNodeInfo.AccessibilityAction action(int id, CharSequence label) {
        return new AccessibilityNodeInfo.AccessibilityAction(id, label);
    }

    @Override public boolean performAccessibilityAction(int action, Bundle arguments) {
        if (document != null) {
            switch (action) {
                case ACTION_PREVIOUS: jumpToPage(Math.max(1, currentPage - 1)); return true;
                case ACTION_NEXT: jumpToPage(Math.min(getPageCount(), currentPage + 1)); return true;
                case ACTION_ZOOM_IN: animateZoomTo(zoom + 1, getWidth() / 2f, getHeight() / 2f); return true;
                case ACTION_ZOOM_OUT: animateZoomTo(zoom - 1, getWidth() / 2f, getHeight() / 2f); return true;
                case ACTION_RESET_ZOOM: animateZoomTo(1, getWidth() / 2f, getHeight() / 2f); return true;
                case AccessibilityNodeInfo.ACTION_SCROLL_FORWARD: scrollViewport(1); return true;
                case AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD: scrollViewport(-1); return true;
            }
        }
        return super.performAccessibilityAction(action, arguments);
    }

    /** 经 OverScroller 平滑滚动一个视口，滚动结束后复用翻页播报 */
    private void scrollViewport(int direction) {
        if (!canScrollVertically(direction)) return;
        int targetY = direction > 0
            ? Math.min(maxY(), Math.round(offsetY + getHeight() * 0.8f))
            : Math.max(0, Math.round(offsetY - getHeight() * 0.8f));
        int dy = targetY - Math.round(offsetY);
        if (dy == 0) return;
        scroller.forceFinished(true);
        scroller.startScroll((int) offsetX, (int) offsetY, 0, dy, 250);
        postInvalidateOnAnimation();
    }

    private void refreshAccessibilityActions() {
        sendAccessibilityEvent(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED);
    }

    /** 生成供读屏软件读取的文档摘要，替代仅指向自身的占位描述 */
    private static String describeDocument(OfficeDocument document) {
        if (document.kind == OfficeDocument.Kind.XLSX) {
            List<String> sheetNames = names(document);
            StringBuilder sheets = new StringBuilder();
            for (int i = 0; i < Math.min(sheetNames.size(), 3); i++) {
                if (sheets.length() > 0) sheets.append('、');
                sheets.append(sheetNames.get(i));
            }
            if (sheetNames.size() > 3) sheets.append("等");
            return "Excel 工作簿，含 " + sheetNames.size() + " 个工作表：" + sheets;
        }
        return document.kind == OfficeDocument.Kind.PPTX
            ? "PowerPoint 演示文稿，共 " + document.pages.size() + " 页"
            : "Word 文档，单页连续滚动";
    }

    private void cancel() {
        generation++;
        if (pending != null) { pending.cancel(true); pending = null; }
        if (searchPending != null) { searchPending.cancel(true); searchPending = null; }
        executor.getQueue().clear();
        if (document == null && "Loading...".equals(status)) { status = ""; invalidate(); }
        settleZoom();
        scroller.forceFinished(true);
    }

    private void releaseImages() {
        if (images != null) { images.close(); images = null; }
    }

    private static void closePackage(OfficePackage source) {
        try { source.close(); }
        catch (IOException error) { android.util.Log.w("JZOffice", "Unable to close document", error); }
    }

    @Override protected void onAttachedToWindow() {
        super.onAttachedToWindow();
        if (images != null) { images.resume(); invalidate(); }
    }

    @Override protected void onDetachedFromWindow() {
        cancel();
        if (images != null) images.suspend();
        super.onDetachedFromWindow();
    }

    private static void requireMainThread() {
        if (Looper.myLooper() != Looper.getMainLooper()) throw new IllegalStateException("Use the main thread");
    }

    private float baseScale() {
        if (isSpreadsheet()) return getResources().getDisplayMetrics().density;
        return contentWidth > 0 ? Math.max(1, getWidth() - 24 * getResources().getDisplayMetrics().density) / contentWidth : 1;
    }
    private float minZoom() { return isSpreadsheet() ? 0.5f : 1; }
    private float clampZoom(float value) { return Math.max(minZoom(), Math.min(MAX_ZOOM, value)); }
    /** 实际绘制用的缩放：正常状态下等于 zoom，越界回弹期间临时带一个偏移量 */
    private float displayZoom() { return zoom + zoomOverflow; }
    private float scale() { return baseScale() * displayZoom(); }
    private float left() { return isSpreadsheet() ? 0 : Math.max(0, (getWidth() - contentWidth * scale()) / 2); }
    private float top() { return isSpreadsheet() ? 0 : 12 * getResources().getDisplayMetrics().density; }
    private int maxX() { return Math.max(0, Math.round(contentWidth * scale() - getWidth())); }
    private int maxY() { return Math.max(0, Math.round(contentHeight * scale() + 2 * top() - getHeight())); }
    private void clampOffsets() { offsetX = Math.max(0, Math.min(maxX(), offsetX)); offsetY = Math.max(0, Math.min(maxY(), offsetY)); }

    /**
     * 越界抵抗：把超出边界的原始量压成逐次收敛的显示量，越推越难推，但永不越过 limit。
     * 负向（跌破下限）与正向（超出上限）各自给一个 limit，缩小时的表现比放大更保守。
     */
    private static float rubberBand(float excess, float limit) {
        if (excess == 0) return 0;
        return limit * excess / (limit + Math.abs(excess));
    }

    /** 以焦点位置为锚点套用一次缩放变更，不动逻辑状态以外的任何东西，供手势与动画共用 */
    private void applyDisplayZoom(float newZoom, float overflow, float focusX, float focusY) {
        float previousScale = scale();
        float x = 0, y = 0;
        if (previousScale > 0) {
            x = (focusX + offsetX - left()) / previousScale;
            y = (focusY + offsetY - top()) / previousScale;
        }
        zoom = newZoom; zoomOverflow = overflow;
        if (previousScale > 0) {
            offsetX = x * scale() - focusX + left();
            offsetY = y * scale() - focusY + top();
        }
        clampOffsets();
    }

    /** 一次缩放变更的收尾：翻页判定、重绘与读屏动作刷新 */
    private void finishZoomChange() {
        updateCurrentPage(); invalidate();
        refreshAccessibilityActions();
    }

    /** 立即把缩放设到目标值，取消进行中的动画与越界量 */
    private void setZoom(float value, float focusX, float focusY) {
        if (Float.isNaN(value) || Float.isInfinite(value)) throw new IllegalArgumentException("Zoom must be finite");
        cancelZoomAnimation();
        scroller.forceFinished(true);
        applyDisplayZoom(clampZoom(value), 0, focusX, focusY);
        rawZoom = zoom;
        finishZoomChange();
    }

    /**
     * 带减速动画的缩放跳转，用于双击与读屏动作。
     * 逻辑缩放立即落到目标值，只有显示值在动画中追赶，因此 getZoom 与状态保存始终取终态。
     */
    private void animateZoomTo(float value, float focusX, float focusY) {
        if (Float.isNaN(value) || Float.isInfinite(value)) throw new IllegalArgumentException("Zoom must be finite");
        float target = clampZoom(value);
        float from = displayZoom();
        if (Math.abs(target - from) < 0.001f) { setZoom(target, focusX, focusY); return; }
        cancelZoomAnimation();
        scroller.forceFinished(true);
        zoom = target;
        rawZoom = target;
        zoomOverflow = from - target;
        startZoomAnimator(focusX, focusY);
    }

    /** 捏合松手后的越界回弹：逻辑缩放不变，只把显示缩放平滑收回 */
    private void animateZoomOverflow(float focusX, float focusY) {
        cancelZoomAnimation();
        startZoomAnimator(focusX, focusY);
    }

    private void startZoomAnimator(float focusX, float focusY) {
        ValueAnimator animator = ValueAnimator.ofFloat(zoomOverflow, 0);
        animator.setDuration(ZOOM_ANIMATION_MS);
        animator.setInterpolator(new DecelerateInterpolator());
        animator.addUpdateListener(animation -> {
            applyDisplayZoom(zoom, (Float) animation.getAnimatedValue(), focusX, focusY);
            invalidate();
        });
        animator.addListener(new AnimatorListenerAdapter() {
            @Override public void onAnimationEnd(Animator animation) {
                // 已被新动画或手势取代时不做收尾，避免覆盖新状态
                if (zoomAnimator != animation) return;
                zoomAnimator = null;
                applyDisplayZoom(zoom, 0, focusX, focusY);
                finishZoomChange();
            }
        });
        zoomAnimator = animator;
        animator.start();
    }

    private void cancelZoomAnimation() {
        if (zoomAnimator == null) return;
        ValueAnimator animator = zoomAnimator;
        zoomAnimator = null;
        animator.cancel();
    }

    /** 取消缩放动画并把显示缩放收回逻辑缩放值，供新手势或状态切换接管 */
    private void settleZoom() {
        if (zoomAnimator != null || zoomOverflow != 0) {
            cancelZoomAnimation();
            zoomOverflow = 0;
            rawZoom = zoom;
            applyDisplayZoom(zoom, 0, getWidth() / 2f, getHeight() / 2f);
            finishZoomChange();
        } else {
            rawZoom = zoom;
        }
    }

    @Override public boolean onTouchEvent(MotionEvent event) {
        if (document == null) return super.onTouchEvent(event);
        if (getParent() != null) getParent().requestDisallowInterceptTouchEvent(true);
        pinch.onTouchEvent(event); gestures.onTouchEvent(event);
        return true;
    }
    @Override public boolean performClick() { super.performClick(); return true; }
    @Override public void computeScroll() {
        if (scroller.computeScrollOffset()) {
            offsetX = scroller.getCurrX(); offsetY = scroller.getCurrY();
            clampOffsets();
            updateCurrentPage();
            postInvalidateOnAnimation();
        } else if (document != null) {
            announcePageIfSettled();
        }
    }
    @Override public boolean canScrollVertically(int direction) { return direction < 0 ? offsetY > 0 : offsetY < maxY(); }
    @Override public boolean canScrollHorizontally(int direction) { return direction < 0 ? offsetX > 0 : offsetX < maxX(); }
    @Override protected void onSizeChanged(int w, int h, int oldw, int oldh) {
        if (!applyRestoredState() && !applyPendingJump()) { clampOffsets(); updateCurrentPage(); }
    }

    private boolean applyRestoredState() {
        if (!hasRestoredState || document == null || getWidth() == 0 || getHeight() == 0) return false;
        hasRestoredState = false;
        if (isSpreadsheet()) {
            if (restoredPage >= 1 && restoredPage <= document.sheets.size() && currentPage != restoredPage) {
                sheetRenderer.setSheet(document.sheets.get(restoredPage - 1), document.cellStyles);
                contentWidth = sheetRenderer.width; contentHeight = sheetRenderer.height;
                currentPage = restoredPage;
            }
        } else if (restoredPage >= 1 && restoredPage <= renderer.pages.size()) {
            currentPage = restoredPage;
        }
        zoom = clampZoom(restoredZoom); rawZoom = zoom; zoomOverflow = 0;
        float s = scale();
        offsetX = restoredDocX * s;
        offsetY = restoredDocY * s;
        clampOffsets();
        updateCurrentPage();
        invalidate();
        return true;
    }

    @Override protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        if (document == null) {
            paint.setColor(0xff656b73);
            paint.setTextSize(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 16, getResources().getDisplayMetrics()));
            paint.setStyle(Paint.Style.FILL);
            canvas.drawText(status, Math.max(16, (getWidth() - paint.measureText(status)) / 2), getHeight() / 2f, paint);
            return;
        }
        canvas.save(); canvas.translate(left() - offsetX, top() - offsetY); canvas.scale(scale(), scale());
        float visibleTop = (offsetY - top()) / scale(), visibleBottom = visibleTop + getHeight() / scale();
        float visibleLeft = (offsetX - left()) / scale();
        if (isSpreadsheet()) {
            sheetViewport.set(visibleLeft, visibleTop, visibleLeft + getWidth() / scale(), visibleBottom);
            sheetRenderer.draw(canvas, sheetViewport);
        } else {
            images.request(renderer.visibleImages(visibleLeft, visibleTop, visibleLeft + getWidth() / scale(), visibleBottom, currentPage - 1));
            renderer.draw(canvas, visibleTop, visibleBottom, images.bitmaps);
        }
        if (!searchMatches.isEmpty()) {
            drawSearchHighlights(canvas);
        }
        canvas.restore();
    }

    @Override protected Parcelable onSaveInstanceState() {
        Parcelable superState = super.onSaveInstanceState();
        if (document == null) return superState;
        float s = scale();
        SavedState saved = new SavedState(superState);
        saved.hasState = true;
        saved.page = currentPage;
        saved.zoom = zoom;
        saved.docX = s > 0 ? offsetX / s : 0;
        saved.docY = s > 0 ? offsetY / s : 0;
        return saved;
    }

    @Override protected void onRestoreInstanceState(Parcelable state) {
        if (!(state instanceof SavedState)) {
            super.onRestoreInstanceState(state);
            return;
        }
        SavedState saved = (SavedState) state;
        super.onRestoreInstanceState(saved.getSuperState());
        if (saved.hasState) {
            hasRestoredState = true;
            restoredPage = saved.page;
            restoredZoom = saved.zoom;
            restoredDocX = saved.docX;
            restoredDocY = saved.docY;
            applyRestoredState();
        }
    }

    // MARK: - 全文检索控制器 API 与高亮绘制

    public void search(String query) {
        search(query, null);
    }

    public void search(String query, SearchCallback callback) {
        requireMainThread();
        if (searchPending != null) {
            searchPending.cancel(true);
            searchPending = null;
        }
        final String trimmed = query != null ? query.trim() : "";
        lastSearchQuery = trimmed;
        if (trimmed.isEmpty() || currentFilePath == null || document == null) {
            searchMatches.clear();
            currentMatchIndex = -1;
            isSearching = false;
            targetHighlightRect = null;
            invalidate();
            notifySearchResults(trimmed, 0);
            notifySearchMatchChanged();
            if (callback != null) callback.onResult(Collections.emptyList());
            return;
        }

        isSearching = true;
        final String path = currentFilePath;
        final int token = generation;
        searchPending = executor.submit(() -> {
            try {
                String json = NativeCore.search(path, trimmed);
                final List<OfficeDocument.SearchMatch> internalMatches = DocumentDecoder.decodeSearchMatches(json);
                final List<SearchMatch> matches = new ArrayList<>(internalMatches.size());
                for (OfficeDocument.SearchMatch m : internalMatches) {
                    matches.add(new SearchMatch(m));
                }
                main.post(() -> {
                    if (token != generation) return;
                    isSearching = false;
                    searchMatches.clear();
                    searchMatches.addAll(matches);
                    currentMatchIndex = matches.isEmpty() ? -1 : 0;
                    updateTargetForCurrentMatch();
                    notifySearchResults(trimmed, matches.size());
                    if (callback != null) callback.onResult(matches);
                });
            } catch (Exception e) {
                main.post(() -> {
                    if (token != generation) return;
                    isSearching = false;
                    searchMatches.clear();
                    currentMatchIndex = -1;
                    targetHighlightRect = null;
                    invalidate();
                    notifySearchResults(trimmed, 0);
                    notifySearchMatchChanged();
                    if (callback != null) callback.onError(e);
                });
            }
        });
    }

    public boolean findNext() {
        requireMainThread();
        if (searchMatches.isEmpty()) return false;
        currentMatchIndex = (currentMatchIndex + 1) % searchMatches.size();
        updateTargetForCurrentMatch();
        return true;
    }

    public boolean findPrevious() {
        requireMainThread();
        if (searchMatches.isEmpty()) return false;
        currentMatchIndex = (currentMatchIndex - 1 + searchMatches.size()) % searchMatches.size();
        updateTargetForCurrentMatch();
        return true;
    }

    public void clearSearch() {
        requireMainThread();
        if (searchPending != null) {
            searchPending.cancel(true);
            searchPending = null;
        }
        lastSearchQuery = "";
        searchMatches.clear();
        currentMatchIndex = -1;
        isSearching = false;
        targetHighlightRect = null;
        invalidate();
        notifySearchResults("", 0);
        notifySearchMatchChanged();
    }

    public List<SearchMatch> getSearchMatches() {
        return Collections.unmodifiableList(new ArrayList<>(searchMatches));
    }

    public int getCurrentMatchIndex() {
        return currentMatchIndex;
    }

    public boolean isSearching() {
        return isSearching;
    }

    public void setSearchListener(SearchListener listener) {
        requireMainThread();
        searchListeners.clear();
        if (listener != null) searchListeners.add(listener);
    }

    public void addSearchListener(SearchListener listener) {
        requireMainThread();
        if (listener != null && !searchListeners.contains(listener)) {
            searchListeners.add(listener);
        }
    }

    public void removeSearchListener(SearchListener listener) {
        requireMainThread();
        searchListeners.remove(listener);
    }

    private void notifySearchResults(String query, int count) {
        if (!searchListeners.isEmpty()) {
            List<SearchListener> copy = new ArrayList<>(searchListeners);
            for (int i = 0; i < copy.size(); i++) {
                copy.get(i).onSearchResults(query, count);
            }
        }
    }

    private void notifySearchMatchChanged() {
        if (!searchListeners.isEmpty()) {
            SearchMatch current = (currentMatchIndex >= 0 && currentMatchIndex < searchMatches.size())
                ? searchMatches.get(currentMatchIndex) : null;
            List<SearchListener> copy = new ArrayList<>(searchListeners);
            for (int i = 0; i < copy.size(); i++) {
                copy.get(i).onCurrentMatchChanged(currentMatchIndex, searchMatches.size(), current);
            }
        }
    }

    private void updateTargetForCurrentMatch() {
        if (currentMatchIndex < 0 || currentMatchIndex >= searchMatches.size() || document == null) {
            targetHighlightRect = null;
            invalidate();
            notifySearchMatchChanged();
            return;
        }
        SearchMatch match = searchMatches.get(currentMatchIndex);
        if (document.kind == OfficeDocument.Kind.PPTX && match.pageIndex + 1 != currentPage) {
            jumpToPage(match.pageIndex + 1);
        } else if (document.kind == OfficeDocument.Kind.XLSX && match.pageIndex + 1 != currentPage) {
            selectSheet(match.pageIndex + 1);
        }

        List<RectF> rects = computeHighlightRects(match);
        if (!rects.isEmpty()) {
            RectF union = new RectF(rects.get(0));
            for (int i = 1; i < rects.size(); i++) {
                union.union(rects.get(i));
            }
            targetHighlightRect = union;
            scrollToHighlight(union);
        } else {
            targetHighlightRect = null;
        }
        invalidate();
        notifySearchMatchChanged();
    }

    public void scrollToHighlight(RectF targetRect) {
        if (targetRect == null || getWidth() == 0 || getHeight() == 0) return;
        settleZoom();
        scroller.forceFinished(true);
        float s = scale();
        float targetX = targetRect.centerX() * s + left() - getWidth() / 2f;
        float targetY = targetRect.centerY() * s + top() - getHeight() / 2f;
        int clampX = Math.max(0, Math.min(maxX(), Math.round(targetX)));
        int clampY = Math.max(0, Math.min(maxY(), Math.round(targetY)));
        int dx = clampX - Math.round(offsetX);
        int dy = clampY - Math.round(offsetY);
        if (dx != 0 || dy != 0) {
            scroller.startScroll((int) offsetX, (int) offsetY, dx, dy, 250);
            postInvalidateOnAnimation();
        }
    }

    List<RectF> computeHighlightRects(SearchMatch match) {
        if (document == null || match == null) return Collections.emptyList();
        if (document.kind == OfficeDocument.Kind.DOCX) {
            if (renderer.pages.isEmpty()) return Collections.emptyList();
            OfficeRenderer.Page page = renderer.pages.get(0);
            if (match.elementIndex < 0 || match.elementIndex >= page.elements.size()) return Collections.emptyList();
            OfficeRenderer.Element d = page.elements.get(match.elementIndex);
            return elementHighlightRects(d, match, 0);
        } else if (document.kind == OfficeDocument.Kind.PPTX) {
            if (match.pageIndex < 0 || match.pageIndex >= renderer.pages.size()) return Collections.emptyList();
            OfficeRenderer.Page page = renderer.pages.get(match.pageIndex);
            if (match.elementIndex < 0 || match.elementIndex >= page.elements.size()) return Collections.emptyList();
            OfficeRenderer.Element d = page.elements.get(match.elementIndex);
            return elementHighlightRects(d, match, page.y);
        } else if (document.kind == OfficeDocument.Kind.XLSX) {
            if (match.pageIndex < 0 || match.pageIndex >= document.sheets.size()) return Collections.emptyList();
            SpreadsheetDocument.Sheet sheet = document.sheets.get(match.pageIndex);
            SheetLayout layout = (match.pageIndex == currentPage - 1 && sheetRenderer.layout != null)
                ? sheetRenderer.layout
                : new SheetLayout(sheet, SheetRenderer.HEADER_WIDTH, SheetRenderer.HEADER_HEIGHT);
            int r = match.row >= 0 ? match.row : 0;
            int c = match.column >= 0 ? match.column : 0;
            if (r < 0 || r >= layout.rows.offsets.length - 1 || c < 0 || c >= layout.columns.offsets.length - 1) {
                return Collections.emptyList();
            }
            if (sheet.geometry != null && sheet.geometry.mergeRects != null) {
                for (SpreadsheetDocument.MergeRect m : sheet.geometry.mergeRects) {
                    if (m.anchor == match.elementIndex) {
                        return Collections.singletonList(new RectF(
                            m.left + SheetRenderer.HEADER_WIDTH,
                            m.top + SheetRenderer.HEADER_HEIGHT,
                            m.right + SheetRenderer.HEADER_WIDTH,
                            m.bottom + SheetRenderer.HEADER_HEIGHT
                        ));
                    }
                }
            }
            float x1 = layout.columns.offsets[c];
            float x2 = layout.columns.offsets[c + 1];
            float y1 = layout.rows.offsets[r];
            float y2 = layout.rows.offsets[r + 1];
            return Collections.singletonList(new RectF(x1, y1, x2, y2));
        }
        return Collections.emptyList();
    }

    List<RectF> elementHighlightRects(OfficeRenderer.Element d, SearchMatch match, float pageOffsetY) {
        if (d.source.type == OfficeDocument.Type.TABLE) {
            int targetBlockIndex = 0;
            boolean found = false;
            int targetR = match.row >= 0 ? match.row : 0;
            int targetC = match.column >= 0 ? match.column : 0;
            int cols = 0;
            for (List<List<OfficeDocument.Paragraph>> row : d.source.rows) {
                cols = Math.max(cols, row.size());
            }
            for (int r = 0; r < d.source.rows.size(); r++) {
                List<List<OfficeDocument.Paragraph>> row = d.source.rows.get(r);
                for (int c = 0; c < cols; c++) {
                    SpreadsheetDocument.CellRange m = OfficeRenderer.findMerge(d.source.merges, r, c);
                    if (m != null && (m.startRow != r || m.startColumn != c)) {
                        continue;
                    }
                    List<OfficeDocument.Paragraph> cell = c < row.size() ? row.get(c) : Collections.emptyList();
                    if (r == targetR && c == targetC) {
                        targetBlockIndex += match.paragraphIndex;
                        found = true;
                        break;
                    }
                    if (!cell.isEmpty()) {
                        targetBlockIndex += cell.size();
                    }
                }
                if (found) break;
            }
            if (found && targetBlockIndex >= 0 && targetBlockIndex < d.texts.size()
                && targetR < d.source.rows.size() && targetC < d.source.rows.get(targetR).size()
                && match.paragraphIndex < d.source.rows.get(targetR).get(targetC).size()) {
                OfficeTextLayout.Block block = d.texts.get(targetBlockIndex);
                OfficeDocument.Paragraph para = d.source.rows.get(targetR).get(targetC).get(match.paragraphIndex);
                return blockHighlightRects(block, para, match.startChar, match.endChar, d.transform, pageOffsetY);
            }
            return Collections.emptyList();
        } else if (!d.source.paragraphs.isEmpty()) {
            if (match.paragraphIndex >= 0 && match.paragraphIndex < d.texts.size()
                && match.paragraphIndex < d.source.paragraphs.size()) {
                OfficeTextLayout.Block block = d.texts.get(match.paragraphIndex);
                OfficeDocument.Paragraph para = d.source.paragraphs.get(match.paragraphIndex);
                return blockHighlightRects(block, para, match.startChar, match.endChar, d.transform, pageOffsetY);
            }
        }
        return Collections.emptyList();
    }

    private List<RectF> blockHighlightRects(OfficeTextLayout.Block b, OfficeDocument.Paragraph para,
                                            int startChar, int endChar, Matrix transform, float pageOffsetY) {
        StaticLayout layout = b.layout;
        if (layout == null) return Collections.emptyList();
        int bulletLen = para.bullet != null ? para.bullet.length() : 0;
        CharSequence text = layout.getText();
        int totalLen = text.length();
        int s = Math.max(0, Math.min(totalLen, startChar + bulletLen));
        int e = Math.max(s, Math.min(totalLen, endChar + bulletLen));
        if (s >= e) return Collections.emptyList();

        int startLine = layout.getLineForOffset(s);
        int endLine = layout.getLineForOffset(e);

        List<RectF> rects = new ArrayList<>();
        for (int line = startLine; line <= endLine; line++) {
            int lineStart = layout.getLineStart(line);
            int lineEnd = layout.getLineEnd(line);
            int selStart = Math.max(s, lineStart);
            int selEnd = Math.min(e, lineEnd);
            if (selStart < selEnd) {
                float x1 = layout.getPrimaryHorizontal(selStart);
                float x2 = layout.getPrimaryHorizontal(selEnd);
                float left = Math.min(x1, x2);
                float right = Math.max(x1, x2);
                if (right - left < 2f) right = left + 2f;
                float top = layout.getLineTop(line);
                float bottom = layout.getLineBottom(line);
                RectF r = new RectF(b.x + left, b.y + top, b.x + right, b.y + bottom);
                transform.mapRect(r);
                r.offset(0, pageOffsetY);
                rects.add(r);
            }
        }
        return rects;
    }

    private void drawSearchHighlights(Canvas canvas) {
        if (searchMatches.isEmpty()) return;
        highlightPaint.setStyle(Paint.Style.FILL);
        highlightStrokePaint.setStyle(Paint.Style.STROKE);
        highlightStrokePaint.setColor(0xffe65100);
        highlightStrokePaint.setStrokeWidth(1.5f / scale());

        for (int i = 0; i < searchMatches.size(); i++) {
            SearchMatch match = searchMatches.get(i);
            if (isSpreadsheet() && match.pageIndex != (currentPage - 1)) {
                continue;
            }
            boolean isCurrent = (i == currentMatchIndex);
            List<RectF> rects = computeHighlightRects(match);
            for (int r = 0; r < rects.size(); r++) {
                RectF rect = rects.get(r);
                if (isCurrent) {
                    highlightPaint.setColor(0xbfFFA000);
                    canvas.drawRoundRect(rect, 2f, 2f, highlightPaint);
                    canvas.drawRoundRect(rect, 2f, 2f, highlightStrokePaint);
                } else {
                    highlightPaint.setColor(0x73FFEB3B);
                    canvas.drawRoundRect(rect, 2f, 2f, highlightPaint);
                }
            }
        }
    }

    private static final class SavedState extends BaseSavedState {
        boolean hasState;
        int page;
        float zoom = 1;
        float docX;
        float docY;

        SavedState(Parcelable superState) { super(superState); }

        private SavedState(Parcel in) {
            super(in);
            hasState = in.readByte() != 0;
            page = in.readInt();
            zoom = in.readFloat();
            docX = in.readFloat();
            docY = in.readFloat();
        }

        @Override public void writeToParcel(Parcel out, int flags) {
            super.writeToParcel(out, flags);
            out.writeByte((byte) (hasState ? 1 : 0));
            out.writeInt(page);
            out.writeFloat(zoom);
            out.writeFloat(docX);
            out.writeFloat(docY);
        }

        public static final Creator<SavedState> CREATOR = new Creator<SavedState>() {
            @Override public SavedState createFromParcel(Parcel in) { return new SavedState(in); }
            @Override public SavedState[] newArray(int size) { return new SavedState[size]; }
        };
    }
}
