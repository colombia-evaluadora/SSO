package com.example.cdc.capture;

import org.springframework.boot.actuate.health.Health;
import org.springframework.boot.actuate.health.HealthIndicator;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

@Component
public class PgSlotHealthIndicator implements HealthIndicator {

    private static final long LAG_THRESHOLD_BYTES = 1_000_000_000L;  // 1 GB

    private final JdbcTemplate jdbc;

    public PgSlotHealthIndicator(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    @Override
    public Health health() {
        try {
            var slot = jdbc.queryForMap(
                "SELECT slot_name, active, " +
                "  pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS lag_bytes " +
                "FROM pg_replication_slots WHERE slot_name = 'cdc_slot'"
            );

            boolean active = (Boolean) slot.get("active");
            long lagBytes = ((Number) slot.get("lag_bytes")).longValue();

            Health.Builder builder = active ? Health.up() : Health.down();
            builder.withDetail("slot_name", slot.get("slot_name"));
            builder.withDetail("active", active);
            builder.withDetail("lag_bytes", lagBytes);

            if (lagBytes > LAG_THRESHOLD_BYTES) {
                builder.status("DOWN").withDetail("reason", "WAL lag exceeds 1 GB");
            }
            return builder.build();
        } catch (Exception e) {
            return Health.down(e).build();
        }
    }
}