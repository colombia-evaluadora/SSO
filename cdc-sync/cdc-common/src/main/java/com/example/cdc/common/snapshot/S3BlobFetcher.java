package com.example.cdc.common.snapshot;

import java.io.InputStream;

/**
 * Strategy for downloading binary content referenced by the PG {@code tarchivo}
 * row's {@code urls3} column. Implementations are responsible for enforcing
 * timeouts and size caps (see {@code HttpS3BlobFetcher}); callers must treat
 * the returned stream as caller-closed.
 *
 * <p>Throws {@link S3FetchException} on any non-recoverable failure (HTTP
 * non-2xx, I/O error, timeout, payload over the configured ceiling). The
 * transformer maps this to WARN + skip per the spec error-handling matrix.
 */
public interface S3BlobFetcher {

    /**
     * Opens a stream over the contents pointed to by {@code urlS3}. The
     * caller owns the returned stream and must close it.
     *
     * @param urlS3 S3 (or pre-signed HTTP) URL to fetch.
     * @return open {@link InputStream} positioned at byte 0.
     * @throws S3FetchException when the fetch cannot be completed.
     */
    InputStream fetchBlob(String urlS3) throws S3FetchException;

    /**
     * Raised when {@link S3BlobFetcher#fetchBlob(String)} cannot deliver the
     * blob. The transformer catches it, logs WARN + skip and increments the
     * {@code cdc.archivo.fetch_error} metric.
     */
    class S3FetchException extends Exception {

        private static final long serialVersionUID = 1L;

        public S3FetchException(String message) {
            super(message);
        }

        public S3FetchException(String message, Throwable cause) {
            super(message, cause);
        }
    }
}
