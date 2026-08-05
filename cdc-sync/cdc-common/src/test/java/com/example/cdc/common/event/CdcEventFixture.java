package com.example.cdc.common.event;

import java.util.Map;

/**
 * Test helpers for building {@link CdcEvent} instances used across the L4-L6
 * transformer test suites.
 *
 * <p>Only the three operations that drive the PG → Oracle reverse-sync are
 * exposed: {@code 'c'} (INSERT), {@code 'u'} (UPDATE) and {@code 'd'}
 * (DELETE). The Debezium snapshot read code {@code 'r'} and the logical
 * message code {@code 'm'} are intentionally absent — neither reaches the
 * transformer chain.
 *
 * <p>Defaults are tuned for terse, readable tests:
 * <ul>
 *   <li>{@code schema = "public"}</li>
 *   <li>{@code routingKey = "public.&lt;table&gt;"}</li>
 *   <li>{@code tsMs = 1_700_000_000_000L} (fixed epoch ms)</li>
 *   <li>{@code context} and {@code message} are {@code null}</li>
 *   <li>UPDATE events copy the {@code after} map into {@code before}</li>
 * </ul>
 *
 * Mirrors the patterns documented in the spec (section 6.3).
 */
public final class CdcEventFixture {

    private static final String DEFAULT_SCHEMA = "public";
    private static final String DEFAULT_DB = "postgres";
    private static final long DEFAULT_TS_MS = 1_700_000_000_000L;

    private CdcEventFixture() {
        // utility class
    }

    /**
     * Builds a Debezium {@code op='c'} (INSERT) event for {@code table} with
     * the supplied {@code after} row.
     */
    public static CdcEvent createInsert(String table, Map<String, Object> after) {
        return builder(table).after(after).buildInsert();
    }

    /**
     * Builds a Debezium {@code op='u'} (UPDATE) event with {@code before} and
     * {@code after} rows. When {@code before} is {@code null} the fixture
     * copies {@code after} so callers do not have to repeat the column set for
     * "no real change" updates.
     */
    public static CdcEvent createUpdate(String table, Map<String, Object> before, Map<String, Object> after) {
        return builder(table).before(before).after(after).buildUpdate();
    }

    /**
     * Builds a Debezium {@code op='d'} (DELETE) event. The fixture places the
     * deleted row in {@code before} (per Debezium semantics) and leaves
     * {@code after} {@code null}.
     */
    public static CdcEvent createDelete(String table, Map<String, Object> before) {
        return builder(table).before(before).buildDelete();
    }

    /**
     * Returns a fresh builder pre-populated with the defaults derived from
     * {@code table} (schema, routing key). Use this when a test needs to set
     * the context, message or source fields explicitly.
     */
    public static Builder builder(String table) {
        return new Builder(table);
    }

    /**
     * Mutable builder backing the {@code create*} helpers. Exposed so tests
     * can tweak individual fields without re-implementing the construction.
     */
    public static final class Builder {

        private final String table;
        private String db = DEFAULT_DB;
        private String schema = DEFAULT_SCHEMA;
        private Long tsMs = DEFAULT_TS_MS;
        private Long txId;
        private Long lsn;
        private String snapshot;
        private String routingKey;
        private CdcEvent.Context context;
        private CdcEvent.Message message;
        private Map<String, Object> before;
        private Map<String, Object> after;

        private Builder(String table) {
            if (table == null || table.isBlank()) {
                throw new IllegalArgumentException("table must be non-blank");
            }
            this.table = table;
            this.routingKey = DEFAULT_SCHEMA + "." + table;
        }

        public Builder schema(String schema) {
            this.schema = schema;
            return this;
        }

        public Builder db(String db) {
            this.db = db;
            return this;
        }

        public Builder tsMs(Long tsMs) {
            this.tsMs = tsMs;
            return this;
        }

        public Builder txId(Long txId) {
            this.txId = txId;
            return this;
        }

        public Builder lsn(Long lsn) {
            this.lsn = lsn;
            return this;
        }

        public Builder snapshot(String snapshot) {
            this.snapshot = snapshot;
            return this;
        }

        public Builder routingKey(String routingKey) {
            this.routingKey = routingKey;
            return this;
        }

        public Builder context(CdcEvent.Context context) {
            this.context = context;
            return this;
        }

        public Builder message(CdcEvent.Message message) {
            this.message = message;
            return this;
        }

        public Builder before(Map<String, Object> before) {
            this.before = before;
            return this;
        }

        public Builder after(Map<String, Object> after) {
            this.after = after;
            return this;
        }

        public CdcEvent buildInsert() {
            return new CdcEvent(
                    Operation.INSERT,
                    null,
                    after,
                    source(),
                    tsMs,
                    routingKey,
                    context,
                    message
            );
        }

        public CdcEvent buildUpdate() {
            Map<String, Object> beforeRow = (before != null) ? before : after;
            return new CdcEvent(
                    Operation.UPDATE,
                    beforeRow,
                    after,
                    source(),
                    tsMs,
                    routingKey,
                    context,
                    message
            );
        }

        public CdcEvent buildDelete() {
            return new CdcEvent(
                    Operation.DELETE,
                    before,
                    null,
                    source(),
                    tsMs,
                    routingKey,
                    context,
                    message
            );
        }

        private CdcEvent.Source source() {
            return new CdcEvent.Source(
                    db,
                    schema,
                    table,
                    txId,
                    lsn,
                    snapshot
            );
        }
    }
}
