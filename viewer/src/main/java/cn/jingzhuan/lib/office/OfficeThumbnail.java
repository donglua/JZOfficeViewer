package cn.jingzhuan.lib.office;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.RectF;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import java.io.IOException;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.Future;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * 轻量级 Office 文档封面/缩略图生成器。
 * 支持脱离 UI 视图，在后台工作线程离屏渲染第一页/第一张幻灯片生成 Bitmap。
 */
public final class OfficeThumbnail {

    public interface Callback {
        void onSuccess(Bitmap thumbnail);
        void onError(Exception error);
    }

    /** 有界线程池，防止并发批量请求解码导致内存激增 OOM */
    private static final ThreadPoolExecutor ASYNC_EXECUTOR = new ThreadPoolExecutor(
        1, 2, 10L, TimeUnit.SECONDS,
        new LinkedBlockingQueue<>(64),
        runnable -> {
            Thread thread = new Thread(runnable, "jz-office-thumbnail");
            thread.setDaemon(true);
            return thread;
        },
        new ThreadPoolExecutor.DiscardOldestPolicy()
    );

    private OfficeThumbnail() { }

    /**
     * 同步解码并离屏渲染文档首页为指定最大边界的缩略图 Bitmap（保持宽高比）。
     * 严禁在主线程调用。
     *
     * @param context 上下文
     * @param uri 文档 URI
     * @param maxTargetWidth 缩略图最大宽度（像素，必须 > 0）
     * @param maxTargetHeight 缩略图最大高度（像素，必须 > 0）
     * @return 渲染完成的 Bitmap（调用方负责在不用时 recycle）
     * @throws IOException 当文档损坏、解析失败或 OOM 时抛出
     */
    public static Bitmap decode(Context context, Uri uri, int maxTargetWidth, int maxTargetHeight) throws IOException {
        if (context == null || uri == null) throw new IllegalArgumentException("Context and URI cannot be null");
        if (maxTargetWidth <= 0 || maxTargetHeight <= 0) {
            throw new IllegalArgumentException("Target width and height must be positive, got " + maxTargetWidth + "x" + maxTargetHeight);
        }

        OfficeCache.Entry cache = null;
        OfficePackage pkg = null;
        try {
            cache = OfficePackage.materialize(context.getApplicationContext(), uri);
            // 封面只取首页：走首屏解析，避免为一张缩略图承担整篇文档的解析成本
            OfficeDocument document = DocumentDecoder.decode(NativeCore.parseFirstViewport(cache.getFile().getAbsolutePath()));
            pkg = new OfficePackage(cache, document);
            if (document.kind == OfficeDocument.Kind.PPTX) {
                return renderPptxThumbnail(pkg, document, maxTargetWidth, maxTargetHeight);
            } else if (document.kind == OfficeDocument.Kind.DOCX) {
                return renderDocxThumbnail(pkg, document, maxTargetWidth, maxTargetHeight);
            } else if (document.kind == OfficeDocument.Kind.XLSX) {
                return renderXlsxThumbnail(document, maxTargetWidth, maxTargetHeight);
            } else {
                throw new IOException("Unsupported document format: " + document.kind);
            }
        } catch (OutOfMemoryError oom) {
            throw new IOException("Not enough memory to render thumbnail", oom);
        } finally {
            if (pkg != null) pkg.close();
            else if (cache != null) cache.close();
        }
    }

    private static Bitmap renderPptxThumbnail(OfficePackage pkg, OfficeDocument doc, int maxW, int maxH) throws IOException {
        if (doc.pages.isEmpty()) throw new IOException("Presentation has no slides");
        OfficeDocument.Page firstPage = doc.pages.get(0);
        float slideW = firstPage.width > 0 ? firstPage.width : 720;
        float slideH = firstPage.height > 0 ? firstPage.height : 405;

        float scale = Math.min((float) maxW / slideW, (float) maxH / slideH);
        int outW = Math.max(1, Math.round(slideW * scale));
        int outH = Math.max(1, Math.round(slideH * scale));

        Bitmap bitmap = Bitmap.createBitmap(outW, outH, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        canvas.scale(scale, scale);

        OfficeRenderer renderer = new OfficeRenderer();
        renderer.layout(doc);

        Set<String> needed = renderer.visibleImages(0, 0, slideW, slideH, 0);
        Map<String, Bitmap> decodedImages = new HashMap<>();
        long pixelBudget = (long) outW * outH * 4L;
        try {
            for (String part : needed) {
                OfficePackage.Image img = pkg.image(part, pixelBudget);
                if (img != null && img.bitmap != null) {
                    decodedImages.put(part, img.bitmap);
                }
            }
            renderer.draw(canvas, 0, slideH, decodedImages);
        } finally {
            for (Bitmap img : decodedImages.values()) {
                if (img != null && !img.isRecycled()) img.recycle();
            }
        }
        return bitmap;
    }

    private static Bitmap renderDocxThumbnail(OfficePackage pkg, OfficeDocument doc, int maxW, int maxH) throws IOException {
        float docW = doc.width > 0 ? doc.width : 595;
        // DOCX 单页 A4 比例高度约为宽度的 1.414 倍，取第一屏视口高度
        float docH = docW * 1.414f;

        OfficeRenderer renderer = new OfficeRenderer();
        // 只为第一屏排版：正文块越过视口底部后不再测量，封面像素不受影响
        renderer.layout(doc, docH);
        if (renderer.width > 0) docW = renderer.width;

        float scale = Math.min((float) maxW / docW, (float) maxH / docH);
        int outW = Math.max(1, Math.round(docW * scale));
        int outH = Math.max(1, Math.round(docH * scale));

        Bitmap bitmap = Bitmap.createBitmap(outW, outH, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        canvas.drawColor(0xffffffff);
        canvas.scale(scale, scale);

        Set<String> needed = renderer.visibleImages(0, 0, docW, docH, -1);
        Map<String, Bitmap> decodedImages = new HashMap<>();
        long pixelBudget = (long) outW * outH * 4L;
        try {
            for (String part : needed) {
                OfficePackage.Image img = pkg.image(part, pixelBudget);
                if (img != null && img.bitmap != null) {
                    decodedImages.put(part, img.bitmap);
                }
            }
            renderer.draw(canvas, 0, docH, decodedImages);
        } finally {
            for (Bitmap img : decodedImages.values()) {
                if (img != null && !img.isRecycled()) img.recycle();
            }
        }
        return bitmap;
    }

    private static Bitmap renderXlsxThumbnail(OfficeDocument doc, int maxW, int maxH) throws IOException {
        if (doc.sheets.isEmpty()) throw new IOException("Spreadsheet has no sheets");
        SpreadsheetDocument.Sheet sheet = doc.sheets.get(0);
        SheetLayout sheetLayout = new SheetLayout(sheet, SheetRenderer.HEADER_WIDTH, SheetRenderer.HEADER_HEIGHT);
        SheetRenderer sheetRenderer = new SheetRenderer();
        sheetRenderer.setSheet(sheet, doc.cellStyles, sheetLayout);

        float previewW = Math.min(sheetRenderer.width, 800f);
        float previewH = Math.min(sheetRenderer.height, 600f);
        if (previewW <= 0) previewW = 400;
        if (previewH <= 0) previewH = 300;

        float scale = Math.min((float) maxW / previewW, (float) maxH / previewH);
        int outW = Math.max(1, Math.round(previewW * scale));
        int outH = Math.max(1, Math.round(previewH * scale));

        Bitmap bitmap = Bitmap.createBitmap(outW, outH, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        canvas.drawColor(0xffffffff);
        canvas.scale(scale, scale);

        sheetRenderer.draw(canvas, new RectF(0, 0, previewW, previewH));
        return bitmap;
    }

    /**
     * 异步解码并离屏渲染文档封面，结果回调在主线程触发。
     * 若任务取消，将确保解码产出的 Bitmap 被立即释放，杜绝内存泄漏。
     */
    public static Future<?> load(Context context, Uri uri, int maxTargetWidth, int maxTargetHeight, Callback callback) {
        if (context == null || uri == null || callback == null) {
            throw new IllegalArgumentException("Context, URI, and callback cannot be null");
        }
        Handler main = new Handler(Looper.getMainLooper());
        AtomicBoolean isCancelled = new AtomicBoolean(false);
        Future<?>[] futureHolder = new Future<?>[1];
        futureHolder[0] = ASYNC_EXECUTOR.submit(() -> {
            Bitmap bitmap = null;
            try {
                if (Thread.currentThread().isInterrupted() || isCancelled.get()) return;
                bitmap = decode(context, uri, maxTargetWidth, maxTargetHeight);
                if (Thread.currentThread().isInterrupted() || isCancelled.get()) {
                    if (bitmap != null && !bitmap.isRecycled()) bitmap.recycle();
                    return;
                }
                final Bitmap result = bitmap;
                main.post(() -> {
                    if (isCancelled.get()) {
                        if (result != null && !result.isRecycled()) result.recycle();
                        return;
                    }
                    callback.onSuccess(result);
                });
            } catch (Exception error) {
                if (bitmap != null && !bitmap.isRecycled()) bitmap.recycle();
                if (Thread.currentThread().isInterrupted() || isCancelled.get()) return;
                main.post(() -> {
                    if (!isCancelled.get()) {
                        callback.onError(error);
                    }
                });
            }
        });
        return new Future<Void>() {
            @Override public boolean cancel(boolean mayInterruptIfRunning) {
                isCancelled.set(true);
                return futureHolder[0].cancel(mayInterruptIfRunning);
            }
            @Override public boolean isCancelled() { return isCancelled.get() || futureHolder[0].isCancelled(); }
            @Override public boolean isDone() { return futureHolder[0].isDone(); }
            @Override public Void get() throws InterruptedException, java.util.concurrent.ExecutionException { futureHolder[0].get(); return null; }
            @Override public Void get(long timeout, TimeUnit unit) throws InterruptedException, java.util.concurrent.ExecutionException, java.util.concurrent.TimeoutException { futureHolder[0].get(timeout, unit); return null; }
        };
    }
}
