package com.example.cdc.common.snapshot;

import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.http.HttpResponse.BodyHandlers;
import java.time.Duration;

/**
 * {@link S3BlobFetcher} implementation backed by the JDK
 * {@link java.net.http.HttpClient}. It enforces two limits negotiated at
 * construction time:
 *
 * <ul>
 *   <li><b>Request timeout</b> — applied to the whole HTTP exchange via
 *       {@link HttpClient.Builder#timeout(Duration)}. When the deadline elapses
 *       the client raises {@link java.net.http.HttpTimeoutException} which we
 *       translate to {@link S3FetchException} (per spec 3.6: WARN + skip on
 *       timeout).</li>
 *   <li><b>Payload size cap</b> — checked up-front against the response
 *       {@code Content-Length} header when present (a synchronous
 *       {@link S3FetchException} is raised), and re-enforced while streaming
 *       via {@link BoundedInputStream} so servers that omit
 *       {@code Content-Length} (or lie about it) cannot push more bytes than
 *       the caller agreed to absorb. The stream-level violation is signalled
 *       as an {@link SizeCapExceededException} (an {@link IOException}
 *       subtype) raised from the next {@code read}.</li>
 * </ul>
 *
 * <p>The returned {@link InputStream} is a stream over the response body; the
 * caller owns it and must close it. The stream is bounded — once the cap is
 * exceeded the underlying connection is closed and an IOException is raised
 * from {@code read}. Callers that wrap the read in try-with-resources get
 * normal cleanup; the transformer treats both {@link S3FetchException} and
 * any {@link IOException} from the stream as a fetch failure (WARN + skip per
 * spec 3.6).
 */
public class HttpS3BlobFetcher implements S3BlobFetcher {

    private final HttpClient client;
    private final int timeoutMs;
    private final long maxBytes;

    /**
     * Builds a fetcher with the supplied limits. A dedicated {@link HttpClient}
     * is created per instance so different beans can be tuned independently
     * (e.g. one per environment).
     *
     * @param timeoutMs request timeout in milliseconds applied to the whole
     *                  exchange. Must be positive.
     * @param maxBytes  hard ceiling on the number of bytes the fetcher will
     *                  deliver before failing. Must be positive.
     */
    public HttpS3BlobFetcher(int timeoutMs, long maxBytes) {
        if (timeoutMs <= 0) {
            throw new IllegalArgumentException("timeoutMs must be positive: " + timeoutMs);
        }
        if (maxBytes <= 0) {
            throw new IllegalArgumentException("maxBytes must be positive: " + maxBytes);
        }
        this.timeoutMs = timeoutMs;
        this.maxBytes = maxBytes;
        this.client = HttpClient.newBuilder()
                .connectTimeout(Duration.ofMillis(timeoutMs))
                .build();
    }

    @Override
    public InputStream fetchBlob(String urlS3) throws S3FetchException {
        if (urlS3 == null || urlS3.isBlank()) {
            throw new S3FetchException("urlS3 must not be blank");
        }

        HttpRequest request;
        try {
            request = HttpRequest.newBuilder(URI.create(urlS3))
                    .timeout(Duration.ofMillis(timeoutMs))
                    .GET()
                    .build();
        } catch (IllegalArgumentException e) {
            throw new S3FetchException("Invalid urlS3: " + urlS3, e);
        }

        HttpResponse<InputStream> response;
        try {
            response = client.send(request, BodyHandlers.ofInputStream());
        } catch (java.net.http.HttpTimeoutException e) {
            throw new S3FetchException("Timeout fetching " + urlS3 + " after " + timeoutMs + "ms", e);
        } catch (IOException e) {
            throw new S3FetchException("I/O error fetching " + urlS3, e);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new S3FetchException("Interrupted while fetching " + urlS3, e);
        }

        int status = response.statusCode();
        if (status / 100 != 2) {
            // Drain & close the body so the underlying connection can be reused.
            try (InputStream body = response.body()) {
                body.readAllBytes();
            } catch (IOException ignored) {
                // best effort; the status code already conveys the failure
            }
            throw new S3FetchException("HTTP " + status + " fetching " + urlS3);
        }

        // Up-front check when the server advertises a length we already know
        // will overflow the cap. Avoids buffering a multi-hundred-MB body just
        // to throw at byte N+1.
        String declaredLength = response.headers().firstValue("Content-Length").orElse(null);
        if (declaredLength != null) {
            long declared;
            try {
                declared = Long.parseLong(declaredLength.trim());
            } catch (NumberFormatException nfe) {
                declared = -1; // unparseable: fall back to stream cap
            }
            if (declared > maxBytes) {
                try (InputStream body = response.body()) {
                    body.readAllBytes();
                } catch (IOException ignored) {
                    // best effort
                }
                throw new S3FetchException(
                        "Payload exceeds size cap (declared=" + declared + " bytes, cap=" + maxBytes + ")");
            }
        }

        return new BoundedInputStream(response.body(), maxBytes);
    }

    /**
     * Streams up to {@code maxBytes} bytes from the underlying response body.
     * If the cap is exceeded the stream is closed (which aborts the underlying
     * HTTP connection) and an {@link SizeCapExceededException} is raised from
     * the next {@code read}. This is an {@link IOException} subclass so it
     * surfaces naturally from the {@link InputStream} contract.
     */
    private static final class BoundedInputStream extends FilterInputStream {

        private final long maxBytes;
        private long count;

        BoundedInputStream(InputStream in, long maxBytes) {
            super(in);
            this.maxBytes = maxBytes;
        }

        @Override
        public int read() throws IOException {
            int b = in.read();
            if (b >= 0) {
                count++;
                if (count > maxBytes) {
                    close();
                    throw new SizeCapExceededException(maxBytes, count);
                }
            }
            return b;
        }

        @Override
        public int read(byte[] buf, int off, int len) throws IOException {
            int n = in.read(buf, off, len);
            if (n > 0) {
                count += n;
                if (count > maxBytes) {
                    close();
                    throw new SizeCapExceededException(maxBytes, count);
                }
            }
            return n;
        }

        @Override
        public long skip(long n) throws IOException {
            long skipped = in.skip(n);
            try {
                count = Math.addExact(count, skipped);
            } catch (ArithmeticException overflow) {
                count = maxBytes + 1;
            }
            if (count > maxBytes) {
                close();
                throw new SizeCapExceededException(maxBytes, count);
            }
            return skipped;
        }
    }

    /**
     * Raised when the payload would exceed the configured size cap. Modeled as
     * an {@link IOException} so it can surface naturally from the bounded
     * stream's {@code read} methods; the transformer treats it identically to
     * {@link S3FetchException} (WARN + skip).
     */
    public static final class SizeCapExceededException extends IOException {

        private static final long serialVersionUID = 1L;

        SizeCapExceededException(long maxBytes, long observedBytes) {
            super("Payload exceeds size cap (observed=" + observedBytes + " bytes, cap=" + maxBytes + " bytes)");
        }
    }
}
