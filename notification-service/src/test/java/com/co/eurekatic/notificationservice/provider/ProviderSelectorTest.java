package com.co.eurekatic.notificationservice.provider;

import com.co.eurekatic.notificationservice.domain.Channel;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.lang.reflect.Field;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Pure-function tests for {@link ProviderSelector}. No
 * Spring, no Mockito — we just feed rows in and check the
 * ordering of the output.
 */
class ProviderSelectorTest {

    private final ProviderSelector selector = new ProviderSelector();

    @Test
    @DisplayName("PRIORITY: ascending priority, ties broken by provider_key")
    void priorityOrdering() {
        List<ProviderConfigRow> rows = List.of(
                row(Channel.EMAIL, "c", 3, 1, Policy.PRIORITY),
                row(Channel.EMAIL, "a", 1, 1, Policy.PRIORITY),
                row(Channel.EMAIL, "b", 2, 1, Policy.PRIORITY),
                row(Channel.EMAIL, "d", 1, 1, Policy.PRIORITY)
        );

        List<ProviderConfigRow> ordered = selector.order(rows);

        assertThat(ordered.stream().map(ProviderConfigRow::providerKey).collect(Collectors.toList()))
                .containsExactly("a", "d", "b", "c");
    }

    @Test
    @DisplayName("WEIGHTED: every row returned exactly once, but order is weight-driven")
    void weightedOrdering() {
        List<ProviderConfigRow> rows = List.of(
                row(Channel.EMAIL, "a", 99, 1, Policy.WEIGHTED),
                row(Channel.EMAIL, "b", 99, 1, Policy.WEIGHTED),
                row(Channel.EMAIL, "c", 99, 1, Policy.WEIGHTED),
                row(Channel.EMAIL, "d", 99, 5, Policy.WEIGHTED)
        );

        List<ProviderConfigRow> ordered = selector.order(rows);

        // Same set, no duplicates.
        assertThat(ordered).hasSize(4);
        assertThat(ordered.stream().map(ProviderConfigRow::providerKey))
                .containsExactlyInAnyOrder("a", "b", "c", "d");
        // The weighted candidate (d, weight 5) is over-represented across
        // many runs — assert it's chosen first more often than by chance.
        int firstPickD = 0;
        for (int i = 0; i < 200; i++) {
            List<ProviderConfigRow> pick = selector.order(rows);
            if (pick.get(0).providerKey().equals("d")) firstPickD++;
        }
        assertThat(firstPickD).isGreaterThan(60);
    }

    @Test
    @DisplayName("Empty input → empty output")
    void emptyInput() {
        assertThat(selector.order(List.of())).isEmpty();
    }

    // ---- helpers -------------------------------------------------

    private static ProviderConfigRow row(Channel channel, String key, int priority,
                                          int weight, Policy policy) {
        ProviderConfigRow r = new ProviderConfigRow();
        try {
            set(r, "channel", channel);
            set(r, "providerKey", key);
            set(r, "impl", "FAKE");
            set(r, "enabled", true);
            set(r, "priority", priority);
            set(r, "weight", weight);
            set(r, "policy", policy);
            set(r, "settings", new HashMap<String, Object>(Map.of()));
            set(r, "updatedAt", java.time.Instant.now());
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
        return r;
    }

    private static void set(Object target, String field, Object value) throws Exception {
        Field f = target.getClass().getDeclaredField(field);
        f.setAccessible(true);
        f.set(target, value);
    }
}