package com.example.cdc.capture;

import com.example.cdc.common.event.CdcEvent;

import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.locks.ReentrantLock;

/**
 * Thread-safe bounded cache that correlates {@code audit_ctx} logical messages
 * emitted by the BEFORE STATEMENT trigger with the row-change events of the
 * same PostgreSQL transaction.
 *
 * <p>Debezium pgoutput emits logical messages <em>before</em> the row events
 * of the same statement (the trigger fires once per statement, ahead of any
 * DML). Both share the same {@code source.txId}, so we key on txId.
 *
 * <p>The cache caps size and TTL to prevent unbounded memory growth in
 * pathological cases (large transactions, failed batches, dropped events).
 */
public class AuditContextCache {

    /** Default TTL: 5 minutes. Most DML transactions commit in &lt;1s; 5min is generous. */
    public static final long DEFAULT_TTL_MS = 5L * 60_000L;

    /** Default max entries: 4096. */
    public static final int DEFAULT_MAX_ENTRIES = 4096;

    private final long ttlMs;
    private final int maxEntries;

    private final ReentrantLock lock = new ReentrantLock();
    /** txId -> Context, ordered by insertion time. */
    private final LinkedHashMap<Long, Entry> map = new LinkedHashMap<>(64, 0.75f, false);

    public AuditContextCache() {
        this(DEFAULT_TTL_MS, DEFAULT_MAX_ENTRIES);
    }

    public AuditContextCache(long ttlMs, int maxEntries) {
        if (ttlMs <= 0) throw new IllegalArgumentException("ttlMs must be > 0");
        if (maxEntries <= 0) throw new IllegalArgumentException("maxEntries must be > 0");
        this.ttlMs = ttlMs;
        this.maxEntries = maxEntries;
    }

    /**
     * Store a context under the given txId, evicting expired and overflow
     * entries as needed.
     */
    public void put(Long txId, CdcEvent.Context context) {
        if (txId == null || context == null) return;
        long now = System.currentTimeMillis();
        lock.lock();
        try {
            map.put(txId, new Entry(context, now));
            evictExpired(now);
            evictOverflow();
        } finally {
            lock.unlock();
        }
    }

    /**
     * Lookup and remove the context for the given txId. Removed-on-read keeps
     * the cache lean; subsequent reads for the same xid (unlikely) get null.
     */
    public CdcEvent.Context take(Long txId) {
        if (txId == null) return null;
        long now = System.currentTimeMillis();
        lock.lock();
        try {
            Entry entry = map.get(txId);
            if (entry == null) return null;
            if (now - entry.insertedAtMs > ttlMs) {
                map.remove(txId);
                return null;
            }
            map.remove(txId);
            return entry.context;
        } finally {
            lock.unlock();
        }
    }

    /**
     * Drop all entries whose age exceeds the TTL. Called opportunistically
     * during {@link #put(Object, CdcEvent.Context)} so the cache does not need
     * a background sweeper.
     */
    private void evictExpired(long now) {
        Iterator<Map.Entry<Long, Entry>> it = map.entrySet().iterator();
        while (it.hasNext()) {
            Map.Entry<Long, Entry> e = it.next();
            if (now - e.getValue().insertedAtMs > ttlMs) {
                it.remove();
            } else {
                // LinkedHashMap iteration order = insertion order. Since TTL
                // eviction only fires on put(), entries inserted later are
                // also fresher on average, so once we hit a fresh entry we can
                // stop.
                break;
            }
        }
    }

    /**
     * If we're over the cap, drop the oldest entries (insertion order). Each
     * eviction is a missed correlation but the row can still be processed with
     * an empty {@link CdcEvent.Context}.
     */
    private void evictOverflow() {
        if (map.size() <= maxEntries) return;
        Iterator<Long> it = map.keySet().iterator();
        while (map.size() > maxEntries && it.hasNext()) {
            it.next();
            it.remove();
        }
    }

    /** Visible for diagnostics / tests. */
    public int size() {
        lock.lock();
        try { return map.size(); } finally { lock.unlock(); }
    }

    private record Entry(CdcEvent.Context context, long insertedAtMs) {}
}
