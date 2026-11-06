package cn.jingzhuan.lib.office;

import android.content.Context;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.Future;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * 轻量级 Office 文档元数据（格式、页数/幻灯片数/Sheet数、尺寸与告警信息）。
 * 支持无头（Headless）离线快速读取，无需初始化 UI 视图。
 */
public final class OfficeMetadata {

    public interface Callback {
        void onSuccess(OfficeMetadata metadata);
        void onError(Exception error);
    }

    public final String format;
    public final int pageCount;
    public final List<String> sheetNames;
    public final List<String> warnings;
    public final float width;
    public final float height;

    OfficeMetadata(String format, int pageCount, List<String> sheetNames, List<String> warnings, float width, float height) {
        this.format = format;
        this.pageCount = pageCount;
        this.sheetNames = sheetNames;
        this.warnings = warnings;
        this.width = width;
        this.height = height;
    }

    static OfficeMetadata fromDocument(OfficeDocument document) {
        if (document == null) throw new IllegalArgumentException("Document cannot be null");
        String format = document.kind.name();
        int pageCount = document.kind == OfficeDocument.Kind.XLSX ? document.sheets.size()
            : document.kind == OfficeDocument.Kind.PPTX ? document.pages.size() : 1;
        List<String> names = new ArrayList<>();
        for (SpreadsheetDocument.Sheet sheet : document.sheets) {
            names.add(sheet.name);
        }
        float docHeight = 0;
        if (document.kind == OfficeDocument.Kind.PPTX && !document.pages.isEmpty()) {
            docHeight = document.pages.get(0).height;
        }
        return new OfficeMetadata(
            format,
            pageCount,
            Collections.unmodifiableList(names),
            Collections.unmodifiableList(new ArrayList<>(document.warnings)),
            document.width,
            docHeight
        );
    }

    /**
     * 同步读取指定文档的元数据。
     * 严禁在主线程执行，必须在后台工作线程中调用。
     */
    public static OfficeMetadata read(Context context, Uri uri) throws IOException {
        if (context == null || uri == null) throw new IllegalArgumentException("Context and URI cannot be null");
        OfficePackage pkg = null;
        try {
            pkg = OfficePackage.open(context.getApplicationContext(), uri);
            return fromDocument(pkg.document);
        } finally {
            if (pkg != null) pkg.close();
        }
    }

    /** 有界线程池，防止并发批量请求导致过多线程 */
    private static final ThreadPoolExecutor ASYNC_EXECUTOR = new ThreadPoolExecutor(
        1, 2, 10L, TimeUnit.SECONDS,
        new LinkedBlockingQueue<>(64),
        runnable -> {
            Thread thread = new Thread(runnable, "jz-office-metadata");
            thread.setDaemon(true);
            return thread;
        },
        new ThreadPoolExecutor.DiscardOldestPolicy()
    );

    /**
     * 异步读取指定文档元数据，结果回调在主线程触发。
     */
    public static Future<?> readAsync(Context context, Uri uri, Callback callback) {
        if (context == null || uri == null || callback == null) {
            throw new IllegalArgumentException("Context, URI, and callback cannot be null");
        }
        Handler main = new Handler(Looper.getMainLooper());
        AtomicBoolean isCancelled = new AtomicBoolean(false);
        Future<?>[] futureHolder = new Future<?>[1];
        futureHolder[0] = ASYNC_EXECUTOR.submit(() -> {
            try {
                if (Thread.currentThread().isInterrupted() || isCancelled.get()) return;
                OfficeMetadata metadata = read(context, uri);
                if (Thread.currentThread().isInterrupted() || isCancelled.get()) return;
                main.post(() -> {
                    if (!isCancelled.get()) {
                        callback.onSuccess(metadata);
                    }
                });
            } catch (Exception error) {
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

    @Override
    public String toString() {
        return "OfficeMetadata{" +
            "format='" + format + '\'' +
            ", pageCount=" + pageCount +
            ", sheetNames=" + sheetNames +
            ", width=" + width +
            ", height=" + height +
            '}';
    }
}
