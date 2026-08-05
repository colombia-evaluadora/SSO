package com.example.cdc.common.snapshot;

import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * Unit tests for {@link HttpS3BlobFetcher}. A tiny {@link HttpServer} on a
 * free loopback port drives every branch: success, non-2xx, body cap (declared
 * via Content-Length), body cap (streaming with no Content-Length), timeout,
 * invalid input and constructor argument validation.
 */
class HttpS3BlobFetcherTest {

    private HttpServer server;
    private int port;

    @BeforeEach
    void start() throws IOException {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        port = server.getAddress().getPort();
        server.start();
    }

    @AfterEach
    void stop() {
        if (server != null) {
            server.stop(0);
        }
    }

    @Test
    void fetches_body_for_2xx_response() throws Exception {
        byte[] payload = "hello-s3-blob".getBytes(StandardCharsets.UTF_8);
        server.createContext("/ok", exchange -> {
            exchange.sendResponseHeaders(200, payload.length);
            try (OutputStream out = exchange.getResponseBody()) {
                out.write(payload);
            }
        });

        HttpS3BlobFetcher fetcher = new HttpS3BlobFetcher(5_000, 1_024L * 1_024L);
        try (InputStream in = fetcher.fetchBlob(url("/ok"))) {
            byte[] read = in.readAllBytes();
            assertThat(read).isEqualTo(payload);
        }
    }

    @Test
    void rejects_non_2xx_with_s3_fetch_exception() {
        server.createContext("/missing", exchange -> {
            byte[] body = "nope".getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().add("Content-Type", "text/plain");
            exchange.sendResponseHeaders(404, body.length);
            try (OutputStream out = exchange.getResponseBody()) {
                out.write(body);
            }
        });

        HttpS3BlobFetcher fetcher = new HttpS3BlobFetcher(5_000, 1_024L);
        assertThatThrownBy(() -> fetcher.fetchBlob(url("/missing")))
                .isInstanceOf(S3BlobFetcher.S3FetchException.class)
                .hasMessageContaining("404");
    }

    @Test
    void rejects_over_cap_declared_via_content_length() {
        byte[] payload = new byte[2_048];
        server.createContext("/big", exchange -> {
            exchange.getResponseHeaders().add("Content-Type", "application/octet-stream");
            exchange.sendResponseHeaders(200, payload.length);
            try (OutputStream out = exchange.getResponseBody()) {
                out.write(payload);
            }
        });

        HttpS3BlobFetcher fetcher = new HttpS3BlobFetcher(5_000, 1_024L);
        assertThatThrownBy(() -> fetcher.fetchBlob(url("/big")))
                .isInstanceOf(S3BlobFetcher.S3FetchException.class)
                .hasMessageContaining("exceeds size cap");
    }

    @Test
    void rejects_over_cap_when_streaming_without_content_length() throws Exception {
        AtomicInteger writes = new AtomicInteger();
        byte[] chunk = new byte[256];
        server.createContext("/chunked", exchange -> {
            exchange.getResponseHeaders().add("Content-Type", "application/octet-stream");
            // Length 0 -> HttpServer uses chunked transfer encoding.
            exchange.sendResponseHeaders(200, 0);
            try (OutputStream out = exchange.getResponseBody()) {
                for (int i = 0; i < 32; i++) {
                    out.write(chunk);
                    writes.incrementAndGet();
                    out.flush();
                }
            }
        });

        HttpS3BlobFetcher fetcher = new HttpS3BlobFetcher(5_000, 1_024L);
        assertThatThrownBy(() -> {
            try (InputStream in = fetcher.fetchBlob(url("/chunked"))) {
                in.readAllBytes();
            }
        })
                .isInstanceOf(HttpS3BlobFetcher.SizeCapExceededException.class)
                .hasMessageContaining("exceeds size cap");

        // The fetcher MUST raise SizeCapExceededException when the cap is
        // crossed (asserted above). We deliberately do NOT assert that the
        // server stops writing — HttpServer's executor may keep the response
        // pipeline warm while in-flight bytes drain. What matters is that the
        // caller never observes more than `maxBytes` bytes; that guarantee is
        // enforced by BoundedInputStream and is exactly what triggered the
        // exception above.
        assertThat(writes.get()).isGreaterThan(0);
    }

    @Test
    void times_out_when_server_hangs() {
        server.createContext("/slow", exchange -> {
            try {
                Thread.sleep(2_000);
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
            }
            byte[] body = "late".getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(200, body.length);
            try (OutputStream out = exchange.getResponseBody()) {
                out.write(body);
            }
        });

        HttpS3BlobFetcher fetcher = new HttpS3BlobFetcher(200, 1_024L);
        assertThatThrownBy(() -> fetcher.fetchBlob(url("/slow")))
                .isInstanceOf(S3BlobFetcher.S3FetchException.class)
                .hasMessageContaining("Timeout");
    }

    @Test
    void rejects_blank_url() {
        HttpS3BlobFetcher fetcher = new HttpS3BlobFetcher(1_000, 1_024L);
        assertThatThrownBy(() -> fetcher.fetchBlob(""))
                .isInstanceOf(S3BlobFetcher.S3FetchException.class);
        assertThatThrownBy(() -> fetcher.fetchBlob(null))
                .isInstanceOf(S3BlobFetcher.S3FetchException.class);
    }

    @Test
    void rejects_invalid_url() {
        HttpS3BlobFetcher fetcher = new HttpS3BlobFetcher(1_000, 1_024L);
        assertThatThrownBy(() -> fetcher.fetchBlob("not a url"))
                .isInstanceOf(S3BlobFetcher.S3FetchException.class);
    }

    @Test
    void rejects_non_positive_arguments_in_constructor() {
        assertThatThrownBy(() -> new HttpS3BlobFetcher(0, 100))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new HttpS3BlobFetcher(100, 0))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new HttpS3BlobFetcher(-1, 100))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new HttpS3BlobFetcher(100, -1))
                .isInstanceOf(IllegalArgumentException.class);
    }

    private String url(String path) {
        return "http://127.0.0.1:" + port + path;
    }
}
