package com.example.cdc.capture;

import com.example.cdc.common.event.CdcEvent;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class AuditContextCacheTest {

    @Test
    void stores_and_retrieves_context_by_xid() {
        AuditContextCache cache = new AuditContextCache();
        CdcEvent.Context ctx = ctx("U-1", "postgres", "S-1", "F-1", "R-1", "E-1");

        cache.put(100L, ctx);

        assertThat(cache.take(100L)).isSameAs(ctx);
        // take() removes; second call returns null
        assertThat(cache.take(100L)).isNull();
    }

    @Test
    void returns_null_for_unknown_xid() {
        AuditContextCache cache = new AuditContextCache();
        assertThat(cache.take(42L)).isNull();
    }

    @Test
    void ignores_null_xid_or_context() {
        AuditContextCache cache = new AuditContextCache();
        cache.put(null, ctx("a", "b", "c", "d", "e", "f"));
        cache.put(123L, null);
        assertThat(cache.size()).isZero();
    }

    @Test
    void evicts_entry_older_than_ttl() throws Exception {
        AuditContextCache cache = new AuditContextCache(50L, 100);
        cache.put(1L, ctx("u", "d", "s", "f", "r", "e"));

        Thread.sleep(80L);

        assertThat(cache.take(1L)).isNull();
    }

    @Test
    void evicts_oldest_when_overflowing_max_entries() {
        AuditContextCache cache = new AuditContextCache(60_000L, 2);
        cache.put(1L, ctx("u1", "d", "s", "f", "r", "e"));
        cache.put(2L, ctx("u2", "d", "s", "f", "r", "e"));
        cache.put(3L, ctx("u3", "d", "s", "f", "r", "e"));

        // xid=1 is the oldest, must have been evicted
        assertThat(cache.take(1L)).isNull();
        assertThat(cache.take(2L)).isNotNull();
        assertThat(cache.take(3L)).isNotNull();
    }

    @Test
    void rejects_invalid_construction_args() {
        org.junit.jupiter.api.Assertions.assertThrows(
                IllegalArgumentException.class,
                () -> new AuditContextCache(0L, 100));
        org.junit.jupiter.api.Assertions.assertThrows(
                IllegalArgumentException.class,
                () -> new AuditContextCache(1000L, 0));
    }

    private static CdcEvent.Context ctx(String u, String d, String s, String f,
                                        String r, String e) {
        return new CdcEvent.Context(u, d, s, f, r, e, Map.of());
    }
}
