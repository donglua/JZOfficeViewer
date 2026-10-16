package cn.jingzhuan.lib.office.online;

import java.net.MalformedURLException;
import java.net.URL;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

public final class RemoteOfficeRequest {
    public static final long DEFAULT_MAX_BYTES = 128L * 1024 * 1024;
    public static final int DEFAULT_CONNECT_TIMEOUT_MILLIS = 15000;
    public static final int DEFAULT_READ_TIMEOUT_MILLIS = 30000;
    public static final int DEFAULT_TOTAL_TIMEOUT_MILLIS = 60000;

    private final URL url;
    private final Map<String, String> headers;
    private final String displayName;
    private final long maxBytes;
    private final int connectTimeoutMillis;
    private final int readTimeoutMillis;
    private final int totalTimeoutMillis;
    private final boolean blockPrivateRedirect;

    public RemoteOfficeRequest(String url) {
        this(new Builder(url));
    }

    private RemoteOfficeRequest(Builder builder) {
        url = parseUrl(builder.url);
        headers = Collections.unmodifiableMap(new LinkedHashMap<>(builder.headers));
        displayName = builder.displayName;
        maxBytes = builder.maxBytes;
        connectTimeoutMillis = builder.connectTimeoutMillis;
        readTimeoutMillis = builder.readTimeoutMillis;
        totalTimeoutMillis = builder.totalTimeoutMillis;
        blockPrivateRedirect = builder.blockPrivateRedirect;
    }

    public URL getUrl() { return url; }
    /** Caller headers are sent only to the original origin; the downloader forces identity encoding. */
    public Map<String, String> getHeaders() { return headers; }
    public String getDisplayName() { return displayName; }
    public long getMaxBytes() { return maxBytes; }
    public int getConnectTimeoutMillis() { return connectTimeoutMillis; }
    public int getReadTimeoutMillis() { return readTimeoutMillis; }
    public int getTotalTimeoutMillis() { return totalTimeoutMillis; }
    public boolean isBlockPrivateRedirect() { return blockPrivateRedirect; }

    public static Builder builder(String url) { return new Builder(url); }

    public static final class Builder {
        private final String url;
        private final Map<String, String> headers = new LinkedHashMap<>();
        private String displayName;
        private long maxBytes = DEFAULT_MAX_BYTES;
        private int connectTimeoutMillis = DEFAULT_CONNECT_TIMEOUT_MILLIS;
        private int readTimeoutMillis = DEFAULT_READ_TIMEOUT_MILLIS;
        private int totalTimeoutMillis = DEFAULT_TOTAL_TIMEOUT_MILLIS;
        private boolean blockPrivateRedirect;

        public Builder(String url) {
            if (url == null || url.trim().isEmpty()) throw new IllegalArgumentException("URL is required");
            this.url = url;
        }

        public Builder header(String name, String value) {
            validateHeader(name, value);
            headers.put(name, value);
            return this;
        }

        public Builder displayName(String displayName) {
            this.displayName = displayName == null || displayName.trim().isEmpty() ? null : displayName.trim();
            return this;
        }

        public Builder maxBytes(long maxBytes) {
            if (maxBytes <= 0 || maxBytes > DEFAULT_MAX_BYTES) {
                throw new IllegalArgumentException("maxBytes must be between 1 and " + DEFAULT_MAX_BYTES);
            }
            this.maxBytes = maxBytes;
            return this;
        }

        public Builder connectTimeoutMillis(int timeoutMillis) {
            if (timeoutMillis <= 0) throw new IllegalArgumentException("connect timeout must be positive");
            connectTimeoutMillis = timeoutMillis;
            return this;
        }

        public Builder readTimeoutMillis(int timeoutMillis) {
            if (timeoutMillis <= 0) throw new IllegalArgumentException("read timeout must be positive");
            readTimeoutMillis = timeoutMillis;
            return this;
        }

        public Builder totalTimeoutMillis(int timeoutMillis) {
            if (timeoutMillis < 0) throw new IllegalArgumentException("total timeout must not be negative");
            totalTimeoutMillis = timeoutMillis;
            return this;
        }

        public Builder blockPrivateRedirect(boolean block) {
            blockPrivateRedirect = block;
            return this;
        }

        public RemoteOfficeRequest build() { return new RemoteOfficeRequest(this); }
    }

    static URL parseUrl(String value) {
        try {
            URL parsed = new URL(value.trim());
            String protocol = parsed.getProtocol();
            if (!"http".equals(protocol) && !"https".equals(protocol)) {
                throw new IllegalArgumentException("Only HTTP and HTTPS URLs are supported");
            }
            if (parsed.getHost() == null || parsed.getHost().trim().isEmpty()) {
                throw new IllegalArgumentException("URL must have a host");
            }
            return parsed;
        } catch (MalformedURLException error) {
            throw new IllegalArgumentException("Invalid URL", error);
        }
    }

    private static void validateHeader(String name, String value) {
        if (name == null || name.trim().isEmpty()) throw new IllegalArgumentException("Header name is required");
        if (value == null) throw new IllegalArgumentException("Header value is required");
        if (containsLineBreak(name) || containsLineBreak(value)) throw new IllegalArgumentException("Headers must not contain line breaks");
    }

    private static boolean containsLineBreak(String value) {
        return value.indexOf('\r') >= 0 || value.indexOf('\n') >= 0;
    }
}
