import cn.jingzhuan.lib.office.online.HttpUrlConnectionOfficeDownloader;
import cn.jingzhuan.lib.office.online.RemoteOfficeDownloader;
import cn.jingzhuan.lib.office.online.RemoteOfficeRequest;
import cn.jingzhuan.lib.office.OfficeCache;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpsConfigurator;
import com.sun.net.httpserver.HttpsServer;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.InterruptedIOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.KeyStore;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.stream.Stream;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSocketFactory;
import javax.net.ssl.TrustManagerFactory;

public final class RemoteDownloaderChecks implements AutoCloseable {
    private static final byte[] BODY = "local office document bytes".getBytes(StandardCharsets.UTF_8);
    private final HttpUrlConnectionOfficeDownloader downloader = new HttpUrlConnectionOfficeDownloader();
    private final ExecutorService executor = Executors.newCachedThreadPool(action -> {
        Thread thread = new Thread(action, "remote-downloader-check");
        thread.setDaemon(true);
        return thread;
    });
    private final List<Throwable> serverFailures = new CopyOnWriteArrayList<>();
    private final Path directory = Files.createTempDirectory(Paths.get("/tmp"), "remote-downloader-checks-");
    private final HttpServer origin = startServer();
    private final HttpServer otherOrigin = startServer();
    private int endpointCount;
    private int outputCount;
    private int passed;

    private RemoteDownloaderChecks() throws IOException {}

    public static void main(String[] args) throws Exception {
        try (RemoteDownloaderChecks checks = new RemoteDownloaderChecks()) {
            checks.run();
            if (!checks.serverFailures.isEmpty()) throw new AssertionError("Local server failed", checks.serverFailures.get(0));
            System.out.println("PASS " + checks.passed + " remote downloader integration checks");
        }
    }

    private void run() throws Exception {
        for (String format : new String[] {"docx", "pptx", "xlsx"}) {
            check("sample " + format + " download and active cache clear", () -> {
                byte[] sample = Files.readAllBytes(Paths.get("demo/src/main/assets/samples/sample." + format));
                String url = endpoint(origin, exchange -> body(exchange, sample, sample.length));
                File cacheRoot = directory.resolve("sample-cache").toFile();
                File downloaded;
                try (OfficeCache.Entry entry = OfficeCache.create(cacheRoot)) {
                    downloaded = entry.getFile();
                    RemoteOfficeDownloader.Result result = download(request(url), downloaded, (bytes, total) -> {}, new TestCancellation());
                    equal((long) sample.length, result.getBytesRead(), "sample size");
                    require(Arrays.equals(sample, Files.readAllBytes(downloaded.toPath())), "sample content changed");
                    equal(1, OfficeCache.clear(cacheRoot).skippedFiles, "active sample must survive cleanup");
                    try (java.util.zip.ZipFile zip = new java.util.zip.ZipFile(downloaded)) {
                        require(zip.getEntry("[Content_Types].xml") != null, "downloaded sample is an OOXML package");
                    }
                }
                require(!downloaded.exists(), "closed sample remains in cache");
            });
        }
        check("HTTP 200 body, type, progress, headers and identity override", () -> {
            String url = endpoint(origin, exchange -> {
                equal("test-token", exchange.getRequestHeaders().getFirst("Authorization"), "authorization");
                equal("caller", exchange.getRequestHeaders().getFirst("X-Document-Test"), "custom header");
                equal("identity", exchange.getRequestHeaders().getFirst("Accept-Encoding"), "encoding");
                exchange.getResponseHeaders().set("Content-Type", "application/octet-stream");
                body(exchange, BODY, BODY.length);
            });
            File output = output();
            List<long[]> progress = new ArrayList<>();
            TestCancellation cancellation = new TestCancellation();
            RemoteOfficeDownloader.Result result = download(request(url).header("Authorization", "test-token")
                .header("X-Document-Test", "caller").header("Accept-Encoding", "gzip"), output,
                (bytes, total) -> progress.add(new long[]{bytes, total}), cancellation);
            require(Arrays.equals(BODY, Files.readAllBytes(output.toPath())), "body changed");
            equal((long) BODY.length, result.getBytesRead(), "result length");
            equal("application/octet-stream", result.getContentType(), "content type");
            equal(0L, progress.get(0)[0], "initial progress");
            equal((long) BODY.length, progress.get(progress.size() - 1)[0], "final progress");
            long previous = -1;
            for (long[] value : progress) {
                require(value[0] >= previous, "progress went backwards");
                equal((long) BODY.length, value[1], "progress total");
                previous = value[0];
            }
            equal(1, cancellation.registrations, "connection registrations");
        });

        for (int status : new int[]{301, 302, 303, 307, 308}) {
            check("same-origin redirect " + status + " retains headers", () -> {
                String target = endpoint(origin, exchange -> {
                    equal("test-token", exchange.getRequestHeaders().getFirst("Authorization"), "redirect authorization");
                    equal("identity", exchange.getRequestHeaders().getFirst("Accept-Encoding"), "redirect encoding");
                    body(exchange, BODY, BODY.length);
                });
                String start = endpoint(origin, exchange -> redirect(exchange, status, new java.net.URL(target).getPath()));
                TestCancellation cancellation = new TestCancellation();
                download(request(start).header("Authorization", "test-token"), output(), (bytes, total) -> {}, cancellation);
                equal(2, cancellation.registrations, "redirect connection registrations");
            });
        }

        check("cross-origin redirect strips caller headers", () -> {
            String target = endpoint(otherOrigin, exchange -> {
                require(exchange.getRequestHeaders().getFirst("Authorization") == null, "authorization leaked");
                require(exchange.getRequestHeaders().getFirst("Cookie") == null, "cookie leaked");
                require(exchange.getRequestHeaders().getFirst("X-Document-Test") == null, "custom header leaked");
                equal("identity", exchange.getRequestHeaders().getFirst("Accept-Encoding"), "cross-origin encoding");
                body(exchange, BODY, BODY.length);
            });
            String start = endpoint(origin, exchange -> redirect(exchange, 302, target));
            download(request(start).header("Authorization", "test-token").header("Cookie", "document=test")
                .header("X-Document-Test", "caller"));
        });

        check("redirect limit", () -> {
            String loop = endpoint(origin, exchange -> redirect(exchange, 302, exchange.getRequestURI().toString()));
            fails(request(loop), "Too many redirects");
        });
        check("redirect without Location", () -> fails(request(endpoint(origin, exchange -> {
            exchange.sendResponseHeaders(302, -1);
            exchange.close();
        })), "missing Location"));
        check("redirect to unsupported scheme", () -> fails(request(endpoint(origin,
            exchange -> redirect(exchange, 302, "file:///tmp/document.docx"))), "Invalid redirect URL"));

        for (int status : new int[]{201, 204, 206, 304, 400, 401, 404, 500}) {
            check("reject HTTP " + status, () -> fails(request(endpoint(origin, exchange -> {
                exchange.sendResponseHeaders(status, -1);
                exchange.close();
            })), "HTTP " + status));
        }

        check("empty fixed-length body", () -> fails(request(endpoint(origin,
            exchange -> body(exchange, new byte[0], -1))), "empty"));
        check("empty chunked body", () -> fails(request(endpoint(origin,
            exchange -> body(exchange, new byte[0], 0))), "empty"));
        check("truncated declared body", () -> {
            HttpServer truncated = startServer();
            try {
                fails(request(endpoint(truncated, exchange -> {
                    exchange.sendResponseHeaders(200, BODY.length + 100);
                    exchange.getResponseBody().write(BODY);
                    exchange.getResponseBody().flush();
                    truncated.stop(0);
                })), "truncated");
            } finally {
                truncated.stop(0);
            }
        });
        check("known length exceeds limit", () -> fails(request(endpoint(origin,
            exchange -> body(exchange, BODY, BODY.length))).maxBytes(BODY.length - 1), "download limit"));
        check("unknown length exceeds limit before writing excess bytes", () -> {
            File output = output();
            fails(request(endpoint(origin, exchange -> body(exchange, new byte[8192], 0))).maxBytes(1024),
                output, "download limit");
            require(output.length() <= 1024, "wrote beyond maxBytes");
        });
        check("unknown length at exact limit succeeds", () -> {
            String url = endpoint(origin, exchange -> body(exchange, BODY, 0));
            List<Long> totals = new ArrayList<>();
            RemoteOfficeDownloader.Result result = download(request(url).maxBytes(BODY.length), output(),
                (bytes, total) -> totals.add(total), new TestCancellation());
            equal((long) BODY.length, result.getBytesRead(), "chunked length");
            for (long total : totals) equal(-1L, total, "unknown progress total");
        });
        check("known length at exact limit succeeds", () -> download(request(endpoint(origin,
            exchange -> body(exchange, BODY, BODY.length))).maxBytes(BODY.length)));

        disposition("filename* takes precedence after filename", "attachment; filename=plain.docx; filename*=UTF-8''report+2026%20Q1.docx", "report+2026 Q1.docx");
        disposition("filename* takes precedence before filename", "attachment; filename*=UTF-8''first.docx; filename=last.docx", "first.docx");
        disposition("extended filename language and UTF-8", "attachment; filename=plain.docx; filename*=UTF-8'en'%E6%96%87%E6%A1%A3.docx", "\u6587\u6863.docx");
        disposition("extended filename ISO-8859-1", "attachment; filename*=ISO-8859-1''caf%E9.docx", "caf\u00e9.docx");
        disposition("ordinary quoted filename preserves plus and semicolon", "attachment; filename=\"report+Q1;draft.docx\"", "report+Q1;draft.docx");
        disposition("ordinary filename preserves percent escapes", "attachment; filename=report%20Q1.docx", "report%20Q1.docx");
        disposition("quoted filename unescapes quotes", "attachment; filename=\"report\\\"Q1.docx\"", "report\"Q1.docx");
        disposition("invalid extended escaping falls back", "attachment; filename*=UTF-8''bad%ZZ.docx; filename=good.docx", "good.docx");
        disposition("unknown extended charset falls back", "attachment; filename=good.docx; filename*=NO-SUCH-CHARSET''bad.docx", "good.docx");
        disposition("traversal filename is sanitized to basename", "attachment; filename=../../safe.docx", "safe.docx");
        disposition("backslash traversal filename is sanitized to basename", "attachment; filename=\"..\\\\..\\\\safe.docx\"", "safe.docx");
        disposition("traversal with only dots falls back to ordinary filename", "attachment; filename*=UTF-8''..%2F..%2F; filename=fallback.docx", "fallback.docx");
        disposition("control characters in filename are stripped", "attachment; filename=\"doc\0\u0007name.docx\"", "docname.docx");
        check("explicit display name wins", () -> {
            String url = endpoint(origin, exchange -> {
                exchange.getResponseHeaders().set("Content-Disposition", "attachment; filename*=UTF-8''server.docx");
                body(exchange, BODY, BODY.length);
            });
            equal("chosen.docx", download(request(url).displayName("chosen.docx")).getDisplayName(), "explicit name");
        });
        check("URL fallback preserves literal plus and decodes escapes", () -> {
            String url = endpoint(origin, exchange -> body(exchange, BODY, BODY.length)) + "/report+Q1%20draft.docx?ignored=other";
            equal("report+Q1 draft.docx", download(request(url)).getDisplayName(), "URL filename");
        });
        check("redirect to loopback blocked when private redirect blocked", () -> {
            String target = endpoint(origin, exchange -> body(exchange, BODY, BODY.length));
            String redirectUrl = endpoint(otherOrigin, exchange -> redirect(exchange, 302, target));
            fails(request(redirectUrl).blockPrivateRedirect(true), "private or loopback address");
        });
        check("total timeout limits slow connection", () -> {
            String url = endpoint(origin, exchange -> {
                exchange.sendResponseHeaders(200, 1024);
                try {
                    exchange.getResponseBody().write(new byte[100]);
                    exchange.getResponseBody().flush();
                    Thread.sleep(600);
                    exchange.getResponseBody().write(new byte[100]);
                    exchange.getResponseBody().flush();
                } catch (InterruptedException | IOException ignored) {
                } finally {
                    exchange.close();
                }
            });
            fails(request(url).totalTimeoutMillis(250), "timed out");
        });
        check("negative total timeout rejected", () -> {
            try {
                request("http://127.0.0.1/doc.docx").totalTimeoutMillis(-1);
                throw new AssertionError("Accepted negative total timeout");
            } catch (IllegalArgumentException expected) {}
        });

        check("invalid URLs rejected before network", () -> {
            for (String value : new String[]{null, "", "  ", "file:///tmp/document", "ftp://localhost/document", "http:/document", "http:///document", "https://", "not a URL"}) {
                try {
                    new RemoteOfficeRequest(value);
                    throw new AssertionError("Accepted invalid URL: " + value);
                } catch (IllegalArgumentException expected) {}
            }
        });
        check("maxBytes cannot exceed the 128 MiB viewer cap", () -> {
            String url = "http://127.0.0.1/document.docx";
            equal(RemoteOfficeRequest.DEFAULT_MAX_BYTES, new RemoteOfficeRequest(url).getMaxBytes(), "default limit");
            equal(1L, request(url).maxBytes(1).build().getMaxBytes(), "minimum limit");
            equal(RemoteOfficeRequest.DEFAULT_MAX_BYTES,
                request(url).maxBytes(RemoteOfficeRequest.DEFAULT_MAX_BYTES).build().getMaxBytes(), "maximum limit");
            for (long value : new long[]{0, -1, RemoteOfficeRequest.DEFAULT_MAX_BYTES + 1, Long.MAX_VALUE}) {
                try {
                    request(url).maxBytes(value).build();
                    throw new AssertionError("Accepted unsupported maxBytes: " + value);
                } catch (IllegalArgumentException expected) {}
            }
        });
        check("pre-cancelled request never connects", () -> {
            AtomicInteger hits = new AtomicInteger();
            String url = endpoint(origin, exchange -> {
                hits.incrementAndGet();
                body(exchange, BODY, BODY.length);
            });
            TestCancellation cancellation = new TestCancellation();
            cancellation.cancel();
            expectCancelled(() -> download(request(url), output(), (bytes, total) -> {}, cancellation));
            equal(0, cancellation.registrations, "pre-cancelled registrations");
            equal(0, hits.get(), "pre-cancelled connections");
        });
        check("cancellation during registration prevents connection", () -> {
            AtomicInteger hits = new AtomicInteger();
            String url = endpoint(origin, exchange -> {
                hits.incrementAndGet();
                body(exchange, BODY, BODY.length);
            });
            TestCancellation cancellation = new TestCancellation();
            cancellation.cancelOnRegistration = true;
            expectCancelled(() -> download(request(url), output(), (bytes, total) -> {}, cancellation));
            require(cancellation.actionStarted.await(2, TimeUnit.SECONDS), "late registration action not invoked");
            equal(0, hits.get(), "registration race connected");
        });
        check("cancellation after last progress cannot return success", () -> {
            TestCancellation cancellation = new TestCancellation();
            String url = endpoint(origin, exchange -> body(exchange, BODY, 0));
            expectCancelled(() -> download(request(url), output(), (bytes, total) -> {
                if (bytes > 0) cancellation.cancel();
            }, cancellation));
        });
        check("cancel stalled response headers", () -> stalledCancellation(false));
        check("cancel stalled redirected body uses current connection", () -> stalledCancellation(true));
        check("HTTPS downgrade rejected before HTTP target", this::httpsDowngrade);
    }

    private void disposition(String name, String header, String expectedName) throws Exception {
        check(name, () -> {
            String url = endpoint(origin, exchange -> {
                exchange.getResponseHeaders().set("Content-Disposition", header);
                body(exchange, BODY, BODY.length);
            });
            equal(expectedName, download(request(url)).getDisplayName(), "disposition filename");
        });
    }

    private void stalledCancellation(boolean afterRedirect) throws Exception {
        CountDownLatch stalled = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        String target = endpoint(origin, exchange -> {
            try {
                if (afterRedirect) {
                    byte[] prefix = new byte[256 * 1024];
                    exchange.sendResponseHeaders(200, prefix.length + 100);
                    exchange.getResponseBody().write(prefix);
                    exchange.getResponseBody().flush();
                } else {
                    stalled.countDown();
                }
                if (!release.await(6, TimeUnit.SECONDS)) throw new AssertionError("stalled handler never released");
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                throw new IOException(error);
            } finally {
                exchange.close();
            }
        });
        String url = afterRedirect ? endpoint(origin, exchange -> redirect(exchange, 302, target)) : target;
        TestCancellation cancellation = new TestCancellation();
        File output = output();
        Future<RemoteOfficeDownloader.Result> running = executor.submit(() -> download(request(url).readTimeoutMillis(1000), output,
            (bytes, total) -> { if (bytes >= 256 * 1024) stalled.countDown(); }, cancellation));
        try {
            require(stalled.await(3, TimeUnit.SECONDS), "download never reached stalled read");
            Thread.sleep(50);
            long started = System.nanoTime();
            cancellation.cancel();
            require(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started) < 250, "cancel blocked caller");
            require(cancellation.actionStarted.await(2, TimeUnit.SECONDS), "disconnect action was not dispatched");
            try {
                running.get(3, TimeUnit.SECONDS);
                throw new AssertionError("Cancelled download returned success");
            } catch (ExecutionException error) {
                require(error.getCause() instanceof InterruptedIOException, "wrong cancellation error: " + error.getCause());
            }
            equal(afterRedirect ? 2 : 1, cancellation.registrations, "active connection registrations");
            equal(cancellation.registrations, cancellation.invokedRegistration, "disconnect used obsolete connection");
            require(!cancellation.hasAction(), "cancelled action retained");
            System.out.println("  cancellation finished in " + TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started) + " ms (read timeout 1000 ms)");
        } finally {
            release.countDown();
            running.cancel(true);
        }
    }

    private void httpsDowngrade() throws Exception {
        Path keyStoreFile = directory.resolve("loopback.p12");
        Path keytoolLog = directory.resolve("keytool.log");
        String keytool = Paths.get(System.getProperty("java.home"), "bin", "keytool").toString();
        Process process = new ProcessBuilder(keytool, "-genkeypair", "-alias", "loopback", "-keyalg", "RSA",
            "-storetype", "PKCS12", "-keystore", keyStoreFile.toString(), "-storepass", "local-test-only",
            "-dname", "CN=localhost", "-ext", "SAN=IP:127.0.0.1", "-validity", "1", "-noprompt")
            .redirectErrorStream(true).redirectOutput(keytoolLog.toFile()).start();
        if (!process.waitFor(20, TimeUnit.SECONDS)) {
            process.destroyForcibly();
            throw new AssertionError("keytool timed out");
        }
        require(process.exitValue() == 0, "keytool failed: " + new String(Files.readAllBytes(keytoolLog), StandardCharsets.UTF_8));
        KeyStore keys = KeyStore.getInstance("PKCS12");
        try (InputStream input = Files.newInputStream(keyStoreFile)) { keys.load(input, "local-test-only".toCharArray()); }
        KeyManagerFactory keyManagers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        keyManagers.init(keys, "local-test-only".toCharArray());
        TrustManagerFactory trust = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        trust.init(keys);
        SSLContext context = SSLContext.getInstance("TLS");
        context.init(keyManagers.getKeyManagers(), trust.getTrustManagers(), null);
        HttpsServer secure = HttpsServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        secure.setHttpsConfigurator(new HttpsConfigurator(context));
        secure.setExecutor(executor);
        secure.start();
        SSLSocketFactory original = HttpsURLConnection.getDefaultSSLSocketFactory();
        try {
            HttpsURLConnection.setDefaultSSLSocketFactory(context.getSocketFactory());
            AtomicInteger hits = new AtomicInteger();
            String insecure = endpoint(origin, exchange -> {
                hits.incrementAndGet();
                body(exchange, BODY, BODY.length);
            });
            String secureUrl = endpoint(secure, exchange -> redirect(exchange, 302, insecure));
            fails(request(secureUrl), "HTTPS to HTTP");
            equal(0, hits.get(), "downgrade contacted HTTP target");
        } finally {
            HttpsURLConnection.setDefaultSSLSocketFactory(original);
            secure.stop(0);
        }
    }

    private HttpServer startServer() throws IOException {
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.setExecutor(executor);
        server.start();
        return server;
    }

    private String endpoint(HttpServer server, HttpHandler handler) {
        String path = "/check-" + ++endpointCount;
        server.createContext(path, exchange -> {
            try {
                handler.handle(exchange);
            } catch (AssertionError error) {
                serverFailures.add(error);
                exchange.sendResponseHeaders(500, -1);
                exchange.close();
            }
        });
        return (server instanceof HttpsServer ? "https" : "http") + "://127.0.0.1:" + server.getAddress().getPort() + path;
    }

    private static void body(HttpExchange exchange, byte[] bytes, long declaredLength) throws IOException {
        try {
            exchange.sendResponseHeaders(200, declaredLength);
            if (bytes.length > 0) exchange.getResponseBody().write(bytes);
        } finally {
            exchange.close();
        }
    }

    private static void redirect(HttpExchange exchange, int status, String location) throws IOException {
        exchange.getResponseHeaders().set("Location", location);
        exchange.sendResponseHeaders(status, -1);
        exchange.close();
    }

    private static RemoteOfficeRequest.Builder request(String url) {
        return RemoteOfficeRequest.builder(url).connectTimeoutMillis(2000).readTimeoutMillis(2000);
    }

    private File output() { return directory.resolve("download-" + ++outputCount + "/document.tmp").toFile(); }

    private RemoteOfficeDownloader.Result download(RemoteOfficeRequest.Builder request) throws IOException {
        return download(request, output(), (bytes, total) -> {}, new TestCancellation());
    }

    private RemoteOfficeDownloader.Result download(RemoteOfficeRequest.Builder request, File output,
            RemoteOfficeDownloader.Progress progress, TestCancellation cancellation) throws IOException {
        try {
            return downloader.download(request.build(), output, progress, cancellation);
        } finally {
            require(!cancellation.hasAction(), "download retained cancellation action");
        }
    }

    private void fails(RemoteOfficeRequest.Builder request, String message) throws IOException { fails(request, output(), message); }

    private void fails(RemoteOfficeRequest.Builder request, File output, String message) throws IOException {
        try {
            download(request, output, (bytes, total) -> {}, new TestCancellation());
            throw new AssertionError("Expected failure containing: " + message);
        } catch (IOException error) {
            require(error.getMessage() != null && error.getMessage().contains(message), "unexpected error: " + error);
        }
    }

    private static void expectCancelled(Check action) throws Exception {
        try {
            action.run();
            throw new AssertionError("Cancelled request succeeded");
        } catch (InterruptedIOException error) {
            equal("Download cancelled", error.getMessage(), "cancellation reason");
        }
    }

    private void check(String name, Check action) throws Exception {
        action.run();
        passed++;
        System.out.println("PASS " + name);
    }

    private static void equal(Object expected, Object actual, String label) {
        require(expected.equals(actual), label + ": expected " + expected + ", actual " + actual);
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    @Override public void close() throws IOException {
        origin.stop(0);
        otherOrigin.stop(0);
        executor.shutdownNow();
        try (Stream<Path> files = Files.walk(directory)) {
            for (Path path : (Iterable<Path>) files.sorted(Comparator.reverseOrder())::iterator) Files.deleteIfExists(path);
        }
    }

    private interface Check { void run() throws Exception; }

    private final class TestCancellation implements RemoteOfficeDownloader.Cancellation {
        private volatile boolean cancelled;
        private Runnable action;
        private int registrations;
        private volatile int invokedRegistration;
        private boolean cancelOnRegistration;
        private final CountDownLatch actionStarted = new CountDownLatch(1);

        @Override public boolean isCancelled() { return cancelled; }

        @Override public void onCancel(Runnable next) {
            boolean dispatch;
            int registration;
            synchronized (this) {
                action = next;
                if (next != null) {
                    registrations++;
                    if (cancelOnRegistration) cancelled = true;
                }
                dispatch = cancelled && next != null;
                registration = registrations;
            }
            if (dispatch) dispatch(next, registration);
        }

        private void cancel() {
            Runnable current;
            int registration;
            synchronized (this) {
                if (cancelled) return;
                cancelled = true;
                current = action;
                registration = registrations;
            }
            if (current != null) dispatch(current, registration);
        }

        private void dispatch(Runnable current, int registration) {
            executor.execute(() -> {
                invokedRegistration = registration;
                actionStarted.countDown();
                current.run();
            });
        }

        private synchronized boolean hasAction() { return action != null; }
    }
}
