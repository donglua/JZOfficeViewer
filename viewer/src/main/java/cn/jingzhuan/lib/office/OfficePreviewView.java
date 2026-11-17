package cn.jingzhuan.lib.office;

import android.animation.Animator;
import android.animation.AnimatorListenerAdapter;
import android.animation.ValueAnimator;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.graphics.Path;
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
import android.view.HapticFeedbackConstants;
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
    /** 文本选区相关读屏动作，沿用 0x7f11 段并接在翻页/缩放动作之后 */
    private static final int ACTION_SELECT_ALL = 0x7f110006;
    private static final int ACTION_COPY_SELECTION = 0x7f110007;
    private static final int ACTION_CLEAR_SELECTION = 0x7f110008;

    /** 触摸状态：空闲 */
    private static final int TOUCH_IDLE = 0;
    /** 触摸状态：拖拽起始手柄 */
    private static final int TOUCH_DRAG_START = 1;
    /** 触摸状态：拖拽结束手柄 */
    private static final int TOUCH_DRAG_END = 2;
    /** 触摸状态：长按选词后不抬手直接滑动扩选 */
    private static final int TOUCH_LONG_PRESS_DRAG = 3;

    /** 选区高亮填充色（半透明蓝） */
    private static final int SELECTION_COLOR = 0x551A73E8;
    /** 选区光标竖线与水滴手柄色 */
    private static final int SELECTION_HANDLE_COLOR = 0xff1A73E8;
    /** 复制成功后写入剪贴板的标签 */
    private static final String CLIPBOARD_LABEL = "JZOffice";
    /** 手柄热区命中半径（dp） */
    private static final float HANDLE_TOUCH_RADIUS_DP = 24f;
    /** 水滴手柄半径（dp），不随文档缩放变化 */
    private static final float HANDLE_RADIUS_DP = 10f;
    /** 手柄圆心相对光标底端的下移量（dp） */
    private static final float HANDLE_CENTER_OFFSET_DP = 14f;
    /** 拖拽手柄时触点 Y 的向上补偿量（dp），避免指腹遮挡正在对准的文字行 */
    private static final float DRAG_TOUCH_OFFSET_DP = 18f;
    /** 光标竖线宽度（dp） */
    private static final float CARET_WIDTH_DP = 2f;
    /** 边缘自动滚动热区宽度（dp） */
    private static final float AUTO_SCROLL_EDGE_DP = 36f;
    /** 边缘自动滚动每帧最大步长（dp） */
    private static final float AUTO_SCROLL_MAX_STEP_DP = 12f;

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
    private OfficePackage spreadsheetPackage;
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

    /** 全文档文本索引；打开文档后按需构建，生命周期结束时置空 */
    private TextSelectionModel.DocumentTextLayout textLayout;
    /** 当前选区；{@code null} 表示无选区 */
    private TextSelectionModel.TextSelection selection;
    /** 浮动操作气泡；惰性创建，销毁时释放 */
    private SelectionPopupMenu selectionMenu;
    /** 当前触摸状态，见 {@code TOUCH_*} 常量 */
    private int touchState = TOUCH_IDLE;
    /** 拖拽/长按扩选过程中的固定锚点 */
    private TextSelectionModel.TextPosition dragAnchor;
    /** 手势处理期间暂存的最新触点（边缘自动滚动的每一帧重新命中它） */
    private float dragTouchX, dragTouchY;
    /** 拖拽手柄时是否需要做防遮挡的纵向补偿 */
    private boolean dragOffsetTouch;
    /** 边缘自动滚动任务是否已排队 */
    private boolean autoScrollScheduled;
    /** 停止边缘自动滚动，供清理路径反复调用 */
    private final Runnable autoScrollTask = this::runAutoScroll;
    private final Paint selectionPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint caretPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Path handlePath = new Path();
    /** 块局部 → 文档坐标的临时矩阵，绘制高亮时逐块复用，避免每帧为每个块分配对象 */
    private final Matrix selectionMatrix = new Matrix();
    private final RectF selectionScreenBounds = new RectF();
    private final int handleTouchRadius, handleRadius, handleCenterOffset;
    private final float dragTouchOffset, caretWidth, autoScrollEdge, autoScrollMaxStep;

    public OfficePreviewView(Context context) { this(context, null); }
    public OfficePreviewView(Context context, AttributeSet attrs) {
        super(context, attrs);
        setBackgroundColor(0xffe9ecef);
        setContentDescription("文档预览区域");
        setFocusable(true);
        scroller = new OverScroller(context);
        float density = getResources().getDisplayMetrics().density;
        handleTouchRadius = Math.round(HANDLE_TOUCH_RADIUS_DP * density);
        handleRadius = Math.round(HANDLE_RADIUS_DP * density);
        handleCenterOffset = Math.round(HANDLE_CENTER_OFFSET_DP * density);
        dragTouchOffset = DRAG_TOUCH_OFFSET_DP * density;
        caretWidth = Math.max(1f, CARET_WIDTH_DP * density);
        autoScrollEdge = AUTO_SCROLL_EDGE_DP * density;
        autoScrollMaxStep = AUTO_SCROLL_MAX_STEP_DP * density;
        selectionPaint.setStyle(Paint.Style.FILL);
        selectionPaint.setColor(SELECTION_COLOR);
        caretPaint.setStyle(Paint.Style.FILL);
        caretPaint.setColor(SELECTION_HANDLE_COLOR);
        gestures = new GestureDetector(context, new GestureDetector.SimpleOnGestureListener() {
            @Override public boolean onDown(MotionEvent event) { scroller.forceFinished(true); settleZoom(); return true; }
            @Override public boolean onScroll(MotionEvent first, MotionEvent last, float dx, float dy) {
                // 选区拖拽期间滚动由选区状态机独占，这里必须让路
                if (touchState != TOUCH_IDLE) return true;
                if (!pinch.isInProgress()) {
                    float prevX = offsetX, prevY = offsetY;
                    offsetX += dx; offsetY += dy; clampOffsets();
                    if (offsetX == prevX && offsetY == prevY && getParent() != null) {
                        getParent().requestDisallowInterceptTouchEvent(false);
                    }
                    // 滚动过程中手柄与气泡会脱离选区，先隐去气泡，停稳后由 computeScroll 重新定位
                    dismissSelectionMenu();
                    updateCurrentPage(); invalidate();
                }
                return true;
            }
            @Override public boolean onSingleTapUp(MotionEvent event) {
                // 已有选区时本次点击用于退出选区态，因此不再触发常规点击回调
                if (!hasSelection()) performClick();
                return true;
            }
            /**
             * 单击清除选区。放在 onSingleTapConfirmed 而不是 onSingleTapUp：
             * 双击的第一下会先触发 onSingleTapUp，若在那里清除选区，双击缩放就会顺带丢掉选区，
             * 与“双击后刷新手柄与气泡位置”的约定冲突。
             */
            @Override public boolean onSingleTapConfirmed(MotionEvent event) {
                if (touchState != TOUCH_IDLE || !hasSelection()) return false;
                clearSelection();
                return true;
            }
            @Override public void onLongPress(MotionEvent event) {
                // 已经处于选区拖拽态时不再重新选词
                if (touchState == TOUCH_IDLE) startLongPressSelection(event);
            }
            @Override public boolean onDoubleTap(MotionEvent event) {
                if (touchState != TOUCH_IDLE) return true;
                // 双击缩放保留选区，缩放停稳后由 finishZoomChange 重贴手柄与气泡
                animateZoomTo(zoom > 1.1f ? 1 : 2, event.getX(), event.getY()); return true;
            }
            @Override public boolean onFling(MotionEvent a, MotionEvent b, float vx, float vy) {
                if (touchState != TOUCH_IDLE) return true;
                dismissSelectionMenu();
                scroller.fling((int) offsetX, (int) offsetY, (int) -vx, (int) -vy, 0, maxX(), 0, maxY());
                postInvalidateOnAnimation(); return true;
            }
        });
        pinch = new ScaleGestureDetector(context, new ScaleGestureDetector.SimpleOnScaleGestureListener() {
            /** 捏合从已夹的缩放起算，保证松手回弹与再次捏合都不残留越界量 */
            @Override public boolean onScaleBegin(ScaleGestureDetector detector) {
                settleZoom();
                // 缩放会改变手柄与气泡的屏幕位置，先在缩放期间隐去气泡，停稳后重定位
                dismissSelectionMenu();
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
        // 换文档时选区、气泡与文本索引全部失效
        releaseSelectionState();
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
                        releaseSpreadsheetPackage();
                        spreadsheetPackage = source;
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
        requireMainThread(); cancel(); clearSearch(); releaseSelectionState(); currentFilePath = null; releaseImages(); document = null; renderer.clear(); sheetRenderer.clear(); currentPage = pendingJumpPage = 0;
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
        // 切表后工作表排版完全更换，选区与文本索引必须作废
        clearSelection();
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
        // 显式翻页属于离散导航：先收掉选区与气泡，避免手柄停留在已离开的页面上
        clearSelection();
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
        if (document.kind != OfficeDocument.Kind.XLSX) {
            info.addAction(action(ACTION_SELECT_ALL, "全选文本"));
            if (hasSelection()) {
                info.addAction(action(ACTION_COPY_SELECTION, "复制选中文本"));
                info.addAction(action(ACTION_CLEAR_SELECTION, "清除选区"));
            }
        }
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
                case ACTION_SELECT_ALL:
                    if (selectAll()) {
                        announceForAccessibility("已全选文本");
                        return true;
                    }
                    return false;
                case ACTION_COPY_SELECTION:
                    if (copySelection()) {
                        announceForAccessibility("已复制到剪贴板");
                        return true;
                    }
                    return false;
                case ACTION_CLEAR_SELECTION:
                    if (!hasSelection()) return false;
                    clearSelection();
                    announceForAccessibility("已清除选区");
                    return true;
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
        releaseSpreadsheetPackage();
    }

    private void releaseSpreadsheetPackage() {
        if (spreadsheetPackage != null) {
            closePackage(spreadsheetPackage);
            spreadsheetPackage = null;
        }
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
        // 宿主销毁：停止边缘自动滚动、隐藏并释放气泡窗口，避免窗口泄漏
        stopAutoScroll();
        touchState = TOUCH_IDLE;
        dragAnchor = null;
        dismissSelectionMenu();
        releaseSelectionMenu();
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
        // 捏合进行中每一步都会走到这里：此时必须保持气泡隐藏，等松手停稳后再贴回选区
        if (hasSelection() && touchState == TOUCH_IDLE && !pinch.isInProgress()) {
            ensureVisiblePagesTextLayout(screenToDocY(0f), screenToDocY(getHeight()));
            showSelectionMenu();
        }
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
        // 捏合检测始终接收全部事件：单指时它不会进入缩放态，但保证双指接管的 onScaleEnd 不丢失
        pinch.onTouchEvent(event);
        if (handleSelectionTouch(event)) return true;
        gestures.onTouchEvent(event);
        return true;
    }

    /**
     * 选区手势优先通道。手柄拖拽与长按扩选状态完全接管触摸事件，
     * 其余情况下只做手柄命中试探，未命中则把事件交回原有滚动/缩放手势，保证零退化。
     *
     * @return 本次事件已被选区交互消费时返回 {@code true}
     */
    private boolean handleSelectionTouch(MotionEvent event) {
        switch (event.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                if (beginHandleDrag(event)) return true;
                return false;
            case MotionEvent.ACTION_POINTER_DOWN:
                // 第二根手指按下即视为缩放手势，放弃正在进行的选区拖拽
                if (touchState != TOUCH_IDLE) {
                    finishSelectionDrag(false);
                }
                return false;
            case MotionEvent.ACTION_MOVE:
                if (touchState == TOUCH_IDLE) return false;
                updateSelectionDrag(event.getX(), event.getY());
                return true;
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_CANCEL:
                if (touchState == TOUCH_IDLE) return false;
                finishSelectionDrag(true);
                return true;
            default:
                return touchState != TOUCH_IDLE;
        }
    }
    @Override public boolean performClick() { super.performClick(); return true; }
    @Override public void computeScroll() {
        if (scroller.computeScrollOffset()) {
            offsetX = scroller.getCurrX(); offsetY = scroller.getCurrY();
            clampOffsets();
            updateCurrentPage();
            postInvalidateOnAnimation();
        } else if (document != null) {
            // 滚动停稳后把气泡重新贴回选区，滚动/惯性过程中气泡保持隐藏
            if (hasSelection() && touchState == TOUCH_IDLE && selectionMenu != null
                && !selectionMenu.isShowing()) {
                showSelectionMenu();
            }
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
        float visibleRight = visibleLeft + getWidth() / scale();
        if (isSpreadsheet()) {
            sheetViewport.set(visibleLeft, visibleTop, visibleRight, visibleBottom);
            sheetRenderer.draw(canvas, sheetViewport);
        } else {
            images.request(renderer.visibleImages(visibleLeft, visibleTop, visibleRight, visibleBottom, currentPage - 1));
            renderer.draw(canvas, visibleTop, visibleBottom, images.bitmaps);
        }
        if (!searchMatches.isEmpty()) {
            drawSearchHighlights(canvas, visibleLeft, visibleTop, visibleRight, visibleBottom);
        }
        // 选区高亮在文档坐标系内绘制，与文字排版共用同一变换，保证“所见即所选”
        if (hasSelection() && textLayout != null) {
            ensureVisiblePagesTextLayout(visibleTop, visibleBottom);
            drawSelectionHighlights(canvas, textLayout, visibleLeft, visibleTop, visibleRight, visibleBottom);
        }
        canvas.restore();
        // 手柄与光标竖线在屏幕坐标系绘制，缩放 0.5x..4x 时保持稳定物理尺寸
        if (hasSelection() && textLayout != null) {
            drawSelectionHandles(canvas, textLayout);
        }
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

    // MARK: - 文本选区公开 API

    /**
     * 选中文档全部可选正文（DOCX / PPTX）。
     *
     * @return 选中成功返回 {@code true}；XLSX、未加载文档或无可选文本返回 {@code false}
     */
    public boolean selectAll() {
        requireMainThread();
        if (document == null || isSpreadsheet()) return false;
        TextSelectionModel.DocumentTextLayout layout = ensureTextLayout();
        if (layout == null || !layout.hasSelectableText()) return false;
        TextSelectionModel.TextSelection all = layout.allTextRange();
        if (all == null || all.isEmpty()) return false;
        settleZoom();
        scroller.forceFinished(true);
        stopAutoScroll();
        touchState = TOUCH_IDLE;
        dragAnchor = null;
        selection = all;
        invalidate();
        showSelectionMenu();
        refreshAccessibilityActions();
        return true;
    }

    /** 清除当前选区、手柄与浮动气泡；无选区时为空操作 */
    public void clearSelection() {
        requireMainThread();
        stopAutoScroll();
        touchState = TOUCH_IDLE;
        dragAnchor = null;
        boolean had = selection != null;
        selection = null;
        dismissSelectionMenu();
        if (had) {
            invalidate();
            refreshAccessibilityActions();
        }
    }

    /** 当前是否存在非空选区（仅反映状态，不触发任何重绘） */
    public boolean hasSelection() {
        requireMainThread();
        return selection != null && !selection.isEmpty();
    }

    /**
     * 返回当前选中的纯文本，跨段落与跨块以 {@code "\n"} 连接。
     *
     * @return 无选区或文本索引不可用时返回空串
     */
    public String getSelectedText() {
        requireMainThread();
        if (!hasSelection()) return "";
        TextSelectionModel.DocumentTextLayout layout = ensureTextLayout();
        if (layout == null) return "";
        String text = layout.selectedText(selection);
        return text == null ? "" : text;
    }

    /**
     * 把当前选中文本写入系统剪贴板，选区保持不变（浮动气泡的「复制」按钮另行清除选区）。
     *
     * @return 写入成功返回 {@code true}；无选区或剪贴板不可用时返回 {@code false}
     */
    public boolean copySelection() {
        requireMainThread();
        String text = getSelectedText();
        if (text.isEmpty()) return false;
        return writeToClipboard(text);
    }

    /** 写入系统剪贴板；剪贴板服务缺失时返回 {@code false} 而不抛异常 */
    private boolean writeToClipboard(String text) {
        if (text == null || text.isEmpty()) return false;
        try {
            Object service = getContext().getSystemService(Context.CLIPBOARD_SERVICE);
            if (!(service instanceof ClipboardManager)) return false;
            ((ClipboardManager) service).setPrimaryClip(ClipData.newPlainText(CLIPBOARD_LABEL, text));
            return true;
        } catch (RuntimeException error) {
            android.util.Log.w("JZOffice", "Unable to write selection to clipboard", error);
            return false;
        }
    }

    // MARK: - 文本索引构建

    /** 惰性构建全文档文本索引；XLSX 不参与自由划词，返回 {@code null} */
    private TextSelectionModel.DocumentTextLayout ensureTextLayout() {
        if (document == null || isSpreadsheet()) return null;
        if (textLayout == null) {
            textLayout = AndroidTextLayoutBuilder.build(document, renderer);
        }
        return textLayout;
    }

    /**
     * 补全当前可视 PPTX 页的行几何。
     *
     * <p>{@link OfficeRenderer#preparePages} 会回收视口外页面元素，行几何随之失效；
     * 绘制、命中与手柄计算前都先按可视范围把已排版页升级为完整布局，保证几何始终可用。
     */
    private void ensureVisiblePagesTextLayout(float visibleTop, float visibleBottom) {
        if (textLayout == null || document == null || document.kind != OfficeDocument.Kind.PPTX) return;
        for (int i = 0; i < renderer.pages.size(); i++) {
            OfficeRenderer.Page page = renderer.pages.get(i);
            if (!page.ready) continue;
            if (page.y + page.height < visibleTop - 1f || page.y > visibleBottom + 1f) continue;
            AndroidTextLayoutBuilder.ensurePageLayout(textLayout, i, document, renderer);
        }
    }

    /** 释放选区相关状态：停止自动滚动、隐藏气泡并丢弃文本索引 */
    private void releaseSelectionState() {
        stopAutoScroll();
        touchState = TOUCH_IDLE;
        dragAnchor = null;
        selection = null;
        dismissSelectionMenu();
        releaseSelectionMenu();
        textLayout = null;
    }

    // MARK: - 坐标转换

    /** 屏幕 X（宿主局部坐标）→ 文档 X */
    private float screenToDocX(float screenX) {
        float s = scale();
        return s > 0 ? (screenX + offsetX - left()) / s : 0f;
    }

    /** 屏幕 Y（宿主局部坐标）→ 文档 Y */
    private float screenToDocY(float screenY) {
        float s = scale();
        return s > 0 ? (screenY + offsetY - top()) / s : 0f;
    }

    /** 文档 X → 屏幕 X（宿主局部坐标） */
    private float docToScreenX(float docX) {
        return docX * scale() - offsetX + left();
    }

    /** 文档 Y → 屏幕 Y（宿主局部坐标） */
    private float docToScreenY(float docY) {
        return docY * scale() - offsetY + top();
    }

    // MARK: - 手势

    /**
     * 长按选词：命中有效文本位置即按词建立选区，并进入不抬手可直接扩选的状态。
     * 双指缩放过程中、XLSX 或未铺满布局时忽略。
     */
    private void startLongPressSelection(MotionEvent event) {
        if (document == null || isSpreadsheet() || pinch.isInProgress()) return;
        TextSelectionModel.DocumentTextLayout layout = ensureTextLayout();
        if (layout == null) return;
        ensureVisiblePagesTextLayout(screenToDocY(0f), screenToDocY(getHeight()));
        TextSelectionModel.TextPosition position = layout.hitTest(
            screenToDocX(event.getX()), screenToDocY(event.getY()));
        if (position == null) return;
        TextSelectionModel.TextSelection word = layout.wordRange(position);
        if (word == null || word.isEmpty()) return;
        scroller.forceFinished(true);
        settleZoom();
        selection = word;
        dragAnchor = word.anchor;
        dragTouchX = event.getX();
        dragTouchY = event.getY();
        dragOffsetTouch = false;
        touchState = TOUCH_LONG_PRESS_DRAG;
        dismissSelectionMenu();
        performHapticFeedback(HapticFeedbackConstants.LONG_PRESS);
        invalidate();
        refreshAccessibilityActions();
    }

    /**
     * ACTION_DOWN 手势拦截：选区手柄优先于滚动/缩放手势。
     *
     * @return 命中手柄并接管本次触摸时返回 {@code true}
     */
    private boolean beginHandleDrag(MotionEvent event) {
        if (!hasSelection()) return false;
        TextSelectionModel.DocumentTextLayout layout = ensureTextLayout();
        if (layout == null) return false;
        TextSelectionModel.SelectionHandles handles = layout.handleGeometry(selection);
        if (handles == null) return false;
        float startX = docToScreenX(handles.start.docX);
        float startY = docToScreenY(handles.start.docBottomY) + handleCenterOffset;
        float endX = docToScreenX(handles.end.docX);
        float endY = docToScreenY(handles.end.docBottomY) + handleCenterOffset;
        float x = event.getX(), y = event.getY();
        boolean onEnd = hitHandle(x, y, endX, endY);
        boolean onStart = hitHandle(x, y, startX, startY);
        if (!onStart && !onEnd) return false;
        // 手柄重叠时优先结束手柄，符合多数编辑器的手感
        touchState = onEnd ? TOUCH_DRAG_END : TOUCH_DRAG_START;
        // 拖起始手柄时锚点固定在选区末尾，拖动结束手柄时锚点固定在选区开头
        dragAnchor = onEnd ? selection.start() : selection.end();
        dragTouchX = x;
        dragTouchY = y;
        dragOffsetTouch = true;
        scroller.forceFinished(true);
        settleZoom();
        dismissSelectionMenu();
        if (getParent() != null) getParent().requestDisallowInterceptTouchEvent(true);
        return true;
    }

    /** 触点是否落在以 ({@code cx}, {@code cy}) 为圆心的手柄热区内 */
    private boolean hitHandle(float x, float y, float cx, float cy) {
        float dx = x - cx, dy = y - cy;
        return dx * dx + dy * dy <= (float) handleTouchRadius * handleTouchRadius;
    }

    /** 处于拖拽/长按扩选状态时按最新触点重算焦点，并在靠近边缘时启动自动滚动 */
    private void updateSelectionDrag(float x, float y) {
        dragTouchX = x;
        dragTouchY = y;
        applySelectionFocus(x, y);
        scheduleAutoScroll(x, y);
    }

    /**
     * 把屏幕触点（含防遮挡补偿）映射为焦点位置并刷新选区。
     *
     * <p>锚点始终固定为 {@link #dragAnchor}，焦点可以自由越过锚点，
     * {@link TextSelectionModel.TextSelection#start()} / {@code end()} 自动给出逻辑先后顺序。
     */
    private void applySelectionFocus(float x, float y) {
        TextSelectionModel.DocumentTextLayout layout = textLayout;
        if (layout == null || dragAnchor == null) return;
        float docX = screenToDocX(x);
        float docY = screenToDocY(dragOffsetTouch ? y - dragTouchOffset : y);
        TextSelectionModel.TextPosition focus = layout.hitTest(docX, docY);
        if (focus == null) return;
        selection = new TextSelectionModel.TextSelection(dragAnchor, focus);
        invalidate();
    }

    /**
     * 结束一次拖拽：清空折叠选区；非空时按 {@code showMenu} 决定是否重新弹出气泡。
     *
     * @param showMenu 抬起手指时为 {@code true}；让位给双指缩放等其它手势时传 {@code false}
     */
    private void finishSelectionDrag(boolean showMenu) {
        stopAutoScroll();
        boolean wasDragging = touchState != TOUCH_IDLE;
        touchState = TOUCH_IDLE;
        dragAnchor = null;
        dragOffsetTouch = false;
        if (!wasDragging) return;
        if (!hasSelection()) {
            selection = null;
            dismissSelectionMenu();
            invalidate();
            refreshAccessibilityActions();
            return;
        }
        invalidate();
        if (showMenu) showSelectionMenu();
        refreshAccessibilityActions();
    }

    // MARK: - 边缘自动滚动

    /** 触点进入四边热区且对应轴仍可滚动时排队一帧自动滚动 */
    private void scheduleAutoScroll(float x, float y) {
        if (autoScrollScheduled) return;
        if (autoScrollStepX(x) == 0 && autoScrollStepY(y) == 0) return;
        autoScrollScheduled = true;
        postOnAnimation(autoScrollTask);
    }

    /** 每帧滚动一小步并重新计算焦点，直到触点离开热区或无法继续滚动 */
    private void runAutoScroll() {
        autoScrollScheduled = false;
        if (touchState == TOUCH_IDLE) return;
        float stepX = autoScrollStepX(dragTouchX);
        float stepY = autoScrollStepY(dragTouchY);
        if (stepX == 0 && stepY == 0) return;
        offsetX += stepX;
        offsetY += stepY;
        clampOffsets();
        applySelectionFocus(dragTouchX, dragTouchY);
        postInvalidateOnAnimation();
        autoScrollScheduled = true;
        postOnAnimation(autoScrollTask);
    }

    /** 停止自动滚动；重复调用安全 */
    private void stopAutoScroll() {
        if (!autoScrollScheduled) return;
        autoScrollScheduled = false;
        removeCallbacks(autoScrollTask);
    }

    /** 横向自动滚动步长：热区内按接近边缘的距离线性递增 */
    private float autoScrollStepX(float x) {
        if (touchState == TOUCH_IDLE) return 0f;
        if (x < autoScrollEdge) return -edgeStep(autoScrollEdge - x) * (canScrollHorizontally(-1) ? 1f : 0f);
        if (x > getWidth() - autoScrollEdge) {
            return edgeStep(x - (getWidth() - autoScrollEdge)) * (canScrollHorizontally(1) ? 1f : 0f);
        }
        return 0f;
    }

    /** 纵向自动滚动步长，规则同 {@link #autoScrollStepX(float)} */
    private float autoScrollStepY(float y) {
        if (y < autoScrollEdge) return -edgeStep(autoScrollEdge - y) * (canScrollVertically(-1) ? 1f : 0f);
        if (y > getHeight() - autoScrollEdge) {
            return edgeStep(y - (getHeight() - autoScrollEdge)) * (canScrollVertically(1) ? 1f : 0f);
        }
        return 0f;
    }

    /** 由越界距离换算每帧步长，上限 {@link #autoScrollMaxStep} */
    private float edgeStep(float overshoot) {
        float ratio = Math.max(0f, Math.min(1f, overshoot / autoScrollEdge));
        return autoScrollMaxStep * ratio;
    }

    // MARK: - 浮动气泡

    /** 依据选区整体屏幕包围框展示浮动气泡；无可定位几何时隐藏 */
    private void showSelectionMenu() {
        if (!hasSelection()) { dismissSelectionMenu(); return; }
        // 未附着到窗口（或宿主正在销毁）时弹窗没有可用 token，直接跳过，避免 BadTokenException
        if (!isAttachedToWindow() || getWindowToken() == null) { dismissSelectionMenu(); return; }
        TextSelectionModel.DocumentTextLayout layout = ensureTextLayout();
        if (layout == null) { dismissSelectionMenu(); return; }
        if (!computeSelectionScreenBounds(layout, selection)) { dismissSelectionMenu(); return; }
        TextSelectionModel.TextSelection all = layout.allTextRange();
        boolean allSelected = all != null && all.start().equals(selection.start())
            && all.end().equals(selection.end());
        if (selectionMenu == null) {
            selectionMenu = new SelectionPopupMenu(this, new SelectionPopupMenu.ActionHandler() {
                @Override public void onCopy() {
                    // 气泡的「复制」写入剪贴板后立即退出选区态，与系统复制行为一致；
                    // 关闭窗口排在下一帧，避免在弹窗自身的点击分发过程中销毁窗口
                    if (copySelection()) announceForAccessibility("已复制到剪贴板");
                    post(OfficePreviewView.this::clearSelection);
                }
                @Override public void onSelectAll() {
                    selectAll();
                }
                @Override public void onVisibilityChanged() {
                    invalidate();
                }
            });
        }
        try {
            selectionMenu.show(selectionScreenBounds.left, selectionScreenBounds.top,
                selectionScreenBounds.right, selectionScreenBounds.bottom, allSelected);
        } catch (RuntimeException error) {
            // 窗口已不可用（Activity 正在销毁等）时安静失败，选区状态仍然保留
            android.util.Log.w("JZOffice", "Unable to show selection menu", error);
        }
    }

    /** 隐藏浮动气泡（不释放窗口资源） */
    private void dismissSelectionMenu() {
        if (selectionMenu != null) selectionMenu.dismiss();
    }

    /** 彻底释放浮动气泡窗口，避免宿主销毁后泄漏 */
    private void releaseSelectionMenu() {
        if (selectionMenu == null) return;
        selectionMenu.release();
        selectionMenu = null;
    }

    /**
     * 计算选区在屏幕坐标系下的外接矩形（与手柄绘制共用同一套文档到屏幕换算）。
     *
     * @return 选区无可用高亮或手柄几何时返回 {@code false}
     */
    private boolean computeSelectionScreenBounds(TextSelectionModel.DocumentTextLayout layout,
                                                 TextSelectionModel.TextSelection target) {
        float left = Float.MAX_VALUE, top = Float.MAX_VALUE;
        float right = -Float.MAX_VALUE, bottom = -Float.MAX_VALUE;
        float x = docToScreenX(0f), y = docToScreenY(0f), s = scale();
        for (TextSelectionModel.BlockHighlightRect rect : layout.blockSelectionRects(target)) {
            left = Math.min(left, x + rect.docBounds.left * s);
            top = Math.min(top, y + rect.docBounds.top * s);
            right = Math.max(right, x + rect.docBounds.right * s);
            bottom = Math.max(bottom, y + rect.docBounds.bottom * s);
        }
        TextSelectionModel.SelectionHandles handles = layout.handleGeometry(target);
        if (handles != null) {
            float caretTop = docToScreenY(handles.start.docTopY);
            left = Math.min(left, docToScreenX(handles.start.docX));
            right = Math.max(right, docToScreenX(handles.start.docX));
            top = Math.min(top, caretTop);
            bottom = Math.max(bottom, docToScreenY(handles.end.docBottomY));
        }
        if (right < left || bottom < top) return false;
        selectionScreenBounds.set(left, top, right, bottom);
        return true;
    }

    // MARK: - 选区绘制

    /** 在文档坐标系内绘制选区高亮（块局部矩形按块仿射矩阵精确贴合旋转文本框） */
    private void drawSelectionHighlights(Canvas canvas, TextSelectionModel.DocumentTextLayout layout,
                                         float visibleLeft, float visibleTop, float visibleRight, float visibleBottom) {
        List<TextSelectionModel.BlockHighlightRect> rects = layout.blockSelectionRects(selection);
        for (int i = 0; i < rects.size(); i++) {
            TextSelectionModel.BlockHighlightRect highlight = rects.get(i);
            TextSelectionModel.Rect bounds = highlight.docBounds;
            if (bounds.right < visibleLeft - 8f || bounds.left > visibleRight + 8f
                || bounds.bottom < visibleTop - 8f || bounds.top > visibleBottom + 8f) continue;
            float[] transform = highlight.transform;
            int save = canvas.save();
            selectionMatrix.setValues(new float[] {
                transform[0], transform[2], transform[4],
                transform[1], transform[3], transform[5],
                0f, 0f, 1f
            });
            canvas.concat(selectionMatrix);
            TextSelectionModel.Rect local = highlight.localRect;
            canvas.drawRect(local.left, local.top, local.right, local.bottom, selectionPaint);
            canvas.restoreToCount(save);
        }
    }

    /** 在屏幕坐标系绘制起止光标竖线与水滴手柄，固定物理尺寸不随缩放变形 */
    private void drawSelectionHandles(Canvas canvas, TextSelectionModel.DocumentTextLayout layout) {
        TextSelectionModel.SelectionHandles handles = layout.handleGeometry(selection);
        if (handles == null) return;
        drawCaret(canvas, docToScreenX(handles.start.docX),
            docToScreenY(handles.start.docTopY), docToScreenY(handles.start.docBottomY), false);
        drawCaret(canvas, docToScreenX(handles.end.docX),
            docToScreenY(handles.end.docTopY), docToScreenY(handles.end.docBottomY), true);
    }

    /** 单个光标竖线与水滴手柄；{@code rightSide} 为 {@code true} 时圆头朝右下，否则朝左下 */
    private void drawCaret(Canvas canvas, float x, float top, float bottom, boolean rightSide) {
        float clampedX = Math.max(caretWidth / 2f, Math.min(getWidth() - caretWidth / 2f, x));
        float startY = Math.min(top, bottom) + caretWidth / 2f;
        float endY = Math.max(top, bottom) - caretWidth / 2f;
        if (endY > startY) {
            canvas.drawRect(clampedX - caretWidth / 2f, startY, clampedX + caretWidth / 2f, endY, caretPaint);
        }
        // 水滴：以光标底端向下偏移为圆心，尖端指向光标底端
        float centerY = Math.max(top, bottom) + handleCenterOffset;
        canvas.save();
        canvas.translate(clampedX, centerY);
        canvas.scale(rightSide ? 1f : -1f, 1f);
        handlePath.reset();
        handlePath.addCircle(0f, 0f, handleRadius, Path.Direction.CW);
        handlePath.moveTo(0f, -handleCenterOffset);
        handlePath.lineTo(-handleRadius * 0.55f, -handleRadius * 0.2f);
        handlePath.lineTo(handleRadius * 0.55f, -handleRadius * 0.2f);
        handlePath.close();
        canvas.drawPath(handlePath, caretPaint);
        canvas.restore();
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
        SheetRenderer.FreezePlan plan = isSpreadsheet() && sheetRenderer.layout != null
            ? sheetRenderer.computeCurrentPlan(new RectF(offsetX / s, offsetY / s,
                (offsetX + getWidth()) / s, (offsetY + getHeight()) / s))
            : null;
        int clampX, clampY;
        if (plan != null && plan.hasFrozen()) {
            // 命中冻结侧时该轴保持当前滚动位置；否则把目标居中对齐到扣除冻结区后的可滚动视口
            boolean inFrozenColumn = plan.effectiveColumns > 0
                && targetRect.centerX() < SheetRenderer.HEADER_WIDTH + plan.frozenDataWidth;
            boolean inFrozenRow = plan.effectiveRows > 0
                && targetRect.centerY() < SheetRenderer.HEADER_HEIGHT + plan.frozenDataHeight;
            float centerX = ((SheetRenderer.HEADER_WIDTH + plan.frozenDataWidth) * s + getWidth()) / 2f;
            float centerY = ((SheetRenderer.HEADER_HEIGHT + plan.frozenDataHeight) * s + getHeight()) / 2f;
            clampX = inFrozenColumn
                ? Math.round(offsetX)
                : Math.max(0, Math.min(maxX(), Math.round(targetRect.centerX() * s - centerX)));
            clampY = inFrozenRow
                ? Math.round(offsetY)
                : Math.max(0, Math.min(maxY(), Math.round(targetRect.centerY() * s - centerY)));
        } else {
            clampX = Math.max(0, Math.min(maxX(), Math.round(targetRect.centerX() * s + left() - getWidth() / 2f)));
            clampY = Math.max(0, Math.min(maxY(), Math.round(targetRect.centerY() * s + top() - getHeight() / 2f)));
        }
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
                return blockHighlightRects(block, match.startChar, match.endChar, d.transform, pageOffsetY);
            }
            return Collections.emptyList();
        } else if (!d.source.paragraphs.isEmpty()) {
            if (match.paragraphIndex >= 0 && match.paragraphIndex < d.texts.size()
                && match.paragraphIndex < d.source.paragraphs.size()) {
                OfficeTextLayout.Block block = d.texts.get(match.paragraphIndex);
                return blockHighlightRects(block, match.startChar, match.endChar, d.transform, pageOffsetY);
            }
        }
        return Collections.emptyList();
    }

    private List<RectF> blockHighlightRects(OfficeTextLayout.Block b,
                                            int startChar, int endChar, Matrix transform, float pageOffsetY) {
        StaticLayout layout = b.layout;
        if (layout == null) return Collections.emptyList();
        CharSequence text = layout.getText();
        int totalLen = text.length();
        int s = Math.max(0, Math.min(totalLen, startChar));
        int e = Math.max(s, Math.min(totalLen, endChar));
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

    private void drawSearchHighlights(Canvas canvas, float visibleLeft, float visibleTop, float visibleRight, float visibleBottom) {
        if (searchMatches.isEmpty() || document == null) return;
        highlightPaint.setStyle(Paint.Style.FILL);
        highlightStrokePaint.setStyle(Paint.Style.STROKE);
        highlightStrokePaint.setColor(0xffe65100);
        highlightStrokePaint.setStrokeWidth(1.5f / scale());

        boolean isSheet = isSpreadsheet();
        SheetRenderer.FreezePlan plan = null;
        if (isSheet) {
            float bodyLeft = Math.max(SheetRenderer.HEADER_WIDTH, visibleLeft + SheetRenderer.HEADER_WIDTH);
            float bodyTop = Math.max(SheetRenderer.HEADER_HEIGHT, visibleTop + SheetRenderer.HEADER_HEIGHT);
            float bodyRight = Math.min(sheetRenderer.width, visibleRight);
            float bodyBottom = Math.min(sheetRenderer.height, visibleBottom);
            if (bodyRight <= bodyLeft || bodyBottom <= bodyTop) return;
            plan = sheetRenderer.layout != null
                ? sheetRenderer.currentPlan(new RectF(visibleLeft, visibleTop, visibleRight, visibleBottom))
                : null;
            canvas.save();
            canvas.clipRect(bodyLeft, bodyTop, bodyRight, bodyBottom);
        }

        try {
            for (int i = 0; i < searchMatches.size(); i++) {
                SearchMatch match = searchMatches.get(i);
                if (isSheet) {
                    if (match.pageIndex != (currentPage - 1)) continue;
                } else if (document.kind == OfficeDocument.Kind.PPTX) {
                    if (match.pageIndex < 0 || match.pageIndex >= renderer.pages.size()) continue;
                    OfficeRenderer.Page page = renderer.pages.get(match.pageIndex);
                    if (page.y + page.height < visibleTop - 20 || page.y > visibleBottom + 20) continue;
                } else if (document.kind == OfficeDocument.Kind.DOCX) {
                    if (!renderer.pages.isEmpty()) {
                        OfficeRenderer.Page page = renderer.pages.get(0);
                        if (match.elementIndex >= 0 && match.elementIndex < page.elements.size()) {
                            OfficeRenderer.Element d = page.elements.get(match.elementIndex);
                            if (d.bounds.bottom < visibleTop - 20 || d.bounds.top > visibleBottom + 20) continue;
                        }
                    }
                }

                boolean isCurrent = (i == currentMatchIndex);
                List<RectF> rects = computeHighlightRects(match);
                for (int r = 0; r < rects.size(); r++) {
                    RectF rect = rects.get(r);
                    if (plan != null && plan.hasFrozen()) {
                        // 冻结窗格下按象限裁剪：滚动区高亮绝不覆盖冻结区，冻结区高亮随未冻结轴滚动
                        drawHighlightByQuadrant(canvas, rect, plan, isCurrent);
                        continue;
                    }
                    drawHighlightRect(canvas, rect, isCurrent);
                }
            }
        } finally {
            if (isSheet) {
                canvas.restore();
            }
        }
    }

    /** 单个检索高亮矩形，选定当前命中配色 */
    private void drawHighlightRect(Canvas canvas, RectF rect, boolean isCurrent) {
        if (isCurrent) {
            highlightPaint.setColor(0xbfFFA000);
            canvas.drawRoundRect(rect, 2f, 2f, highlightPaint);
            canvas.drawRoundRect(rect, 2f, 2f, highlightStrokePaint);
        } else {
            highlightPaint.setColor(0x73FFEB3B);
            canvas.drawRoundRect(rect, 2f, 2f, highlightPaint);
        }
    }

    /**
     * 把文档坐标下的高亮矩形按冻结象限逐个平移并裁剪绘制。
     * 交叉角锁定双轴；冻结行/列只随未冻结轴滚动；滚动区随双轴滚动且严格裁剪在冻结区之外。
     */
    private void drawHighlightByQuadrant(Canvas canvas, RectF rect, SheetRenderer.FreezePlan plan, boolean isCurrent) {
        List<SheetRenderer.Quadrant> quadrants = SheetRenderer.quadrants(plan);
        RectF shifted = new RectF();
        for (int q = 0; q < quadrants.size(); q++) {
            SheetRenderer.Quadrant quadrant = quadrants.get(q);
            if (quadrant.isEmpty()) continue;
            shifted.set(rect);
            shifted.offset(quadrant.translateX, quadrant.translateY);
            if (shifted.right <= quadrant.clipLeft || shifted.left >= quadrant.clipRight
                || shifted.bottom <= quadrant.clipTop || shifted.top >= quadrant.clipBottom) continue;
            int save = canvas.save();
            canvas.clipRect(quadrant.clipLeft, quadrant.clipTop, quadrant.clipRight, quadrant.clipBottom);
            drawHighlightRect(canvas, shifted, isCurrent);
            canvas.restoreToCount(save);
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
