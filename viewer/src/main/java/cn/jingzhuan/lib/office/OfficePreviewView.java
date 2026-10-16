package cn.jingzhuan.lib.office;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.util.AttributeSet;
import android.view.GestureDetector;
import android.view.MotionEvent;
import android.view.ScaleGestureDetector;
import android.view.View;
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
    public interface Listener {
        void onLoaded(Info info);
        void onError(Exception error);
    }

    public interface OnPageChangeListener {
        void onPageChanged(int pageNumber, int pageCount);
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
    private int currentPage, notifiedPage, notifiedCount, pendingJumpPage;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
    private final OverScroller scroller;
    private final GestureDetector gestures;
    private final ScaleGestureDetector pinch;
    private float zoom = 1, offsetX, offsetY, contentWidth, contentHeight;
    private String status = "";

    public OfficePreviewView(Context context) { this(context, null); }
    public OfficePreviewView(Context context, AttributeSet attrs) {
        super(context, attrs);
        setBackgroundColor(0xffe9ecef);
        setContentDescription("Document preview");
        setFocusable(true);
        scroller = new OverScroller(context);
        gestures = new GestureDetector(context, new GestureDetector.SimpleOnGestureListener() {
            @Override public boolean onDown(MotionEvent event) { scroller.forceFinished(true); return true; }
            @Override public boolean onScroll(MotionEvent first, MotionEvent last, float dx, float dy) {
                if (!pinch.isInProgress()) { offsetX += dx; offsetY += dy; clampOffsets(); updateCurrentPage(); invalidate(); }
                return true;
            }
            @Override public boolean onSingleTapUp(MotionEvent event) { performClick(); return true; }
            @Override public boolean onDoubleTap(MotionEvent event) {
                setZoom(zoom > 1.1f ? 1 : 2, event.getX(), event.getY()); return true;
            }
            @Override public boolean onFling(MotionEvent a, MotionEvent b, float vx, float vy) {
                scroller.fling((int) offsetX, (int) offsetY, (int) -vx, (int) -vy, 0, maxX(), 0, maxY());
                postInvalidateOnAnimation(); return true;
            }
        });
        pinch = new ScaleGestureDetector(context, new ScaleGestureDetector.SimpleOnScaleGestureListener() {
            @Override public boolean onScale(ScaleGestureDetector detector) {
                setZoom(zoom * detector.getScaleFactor(), detector.getFocusX(), detector.getFocusY()); return true;
            }
        });
    }

    public void open(Uri uri, Listener listener) {
        requireMainThread();
        if (uri == null || listener == null) throw new IllegalArgumentException("URI and listener are required");
        cancel();
        releaseImages();
        document = null; renderer.clear(); sheetRenderer.clear(); currentPage = pendingJumpPage = 0; zoom = 1; offsetX = offsetY = 0;
        contentWidth = contentHeight = 0;
        status = "Loading..."; invalidate();
        final int token = generation;
        final Context app = getContext().getApplicationContext();
        pending = executor.submit(() -> {
            OfficePackage opened = null;
            try {
                opened = OfficePackage.open(app, uri);
                OfficeDocument loaded = opened.document;
                OfficePackage.checkCancelled();
                final OfficePackage source = opened;
                main.post(() -> {
                    if (token != generation) { closePackage(source); return; }
                    document = loaded; status = ""; currentPage = 1;
                    if (isSpreadsheet()) {
                        closePackage(source);
                        sheetRenderer.setSheet(loaded.sheets.get(0), loaded.cellStyles);
                        contentWidth = sheetRenderer.width; contentHeight = sheetRenderer.height;
                    } else {
                        images = new OfficeImages(source, this::invalidate, listener);
                        renderer.layout(loaded);
                        contentWidth = renderer.width; contentHeight = renderer.height;
                    }
                    clampOffsets(); invalidate();
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
                    status = "Unable to open document"; invalidate(); listener.onError(error);
                });
            } finally {
                if (opened != null) closePackage(opened);
            }
        });
        notifyPageChanged();
    }

    public void clear() {
        requireMainThread(); cancel(); releaseImages(); document = null; renderer.clear(); sheetRenderer.clear(); currentPage = pendingJumpPage = 0;
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

    public void jumpToPage(int pageNumber) {
        requireMainThread();
        if (pageNumber < 1 || pageNumber > getPageCount()) throw new IllegalArgumentException("Page number is outside the loaded document");
        if (isSpreadsheet()) { selectSheet(pageNumber); return; }
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
    }

    private void cancel() {
        generation++;
        if (pending != null) { pending.cancel(true); pending = null; }
        executor.getQueue().clear();
        if (document == null && "Loading...".equals(status)) { status = ""; invalidate(); }
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
    private float scale() { return baseScale() * zoom; }
    private float left() { return isSpreadsheet() ? 0 : Math.max(0, (getWidth() - contentWidth * scale()) / 2); }
    private float top() { return isSpreadsheet() ? 0 : 12 * getResources().getDisplayMetrics().density; }
    private int maxX() { return Math.max(0, Math.round(contentWidth * scale() - getWidth())); }
    private int maxY() { return Math.max(0, Math.round(contentHeight * scale() + 2 * top() - getHeight())); }
    private void clampOffsets() { offsetX = Math.max(0, Math.min(maxX(), offsetX)); offsetY = Math.max(0, Math.min(maxY(), offsetY)); }
    private void setZoom(float value, float focusX, float focusY) {
        if (Float.isNaN(value) || Float.isInfinite(value)) throw new IllegalArgumentException("Zoom must be finite");
        scroller.forceFinished(true);
        float oldScale = scale();
        float x = (focusX + offsetX - left()) / oldScale;
        float y = (focusY + offsetY - top()) / oldScale;
        zoom = Math.max(isSpreadsheet() ? 0.5f : 1, Math.min(4, value));
        offsetX = x * scale() - focusX + left();
        offsetY = y * scale() - focusY + top();
        clampOffsets(); updateCurrentPage(); invalidate();
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
            offsetX = scroller.getCurrX(); offsetY = scroller.getCurrY(); updateCurrentPage(); postInvalidateOnAnimation();
        }
    }
    @Override public boolean canScrollVertically(int direction) { return direction < 0 ? offsetY > 0 : offsetY < maxY(); }
    @Override public boolean canScrollHorizontally(int direction) { return direction < 0 ? offsetX > 0 : offsetX < maxX(); }
    @Override protected void onSizeChanged(int w, int h, int oldw, int oldh) {
        if (!applyPendingJump()) { clampOffsets(); updateCurrentPage(); }
    }

    @Override protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        if (document == null) {
            paint.setColor(0xff656b73); paint.setTextSize(16 * getResources().getDisplayMetrics().scaledDensity);
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
        canvas.restore();
    }
}
