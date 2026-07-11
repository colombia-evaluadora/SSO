package com.co.eurekatic.notificationservice.provider;

import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.concurrent.ThreadLocalRandom;

/**
 * Pure-function ordering of {@link ProviderConfigRow}s by
 * the row's declared {@link Policy}.
 *
 * <ul>
 *   <li>{@link Policy#PRIORITY} — ascending {@code priority}
 *       value, ties broken by {@code provider_key} for
 *       determinism. This is the spec default.</li>
 *   <li>{@link Policy#WEIGHTED} — weighted random
 *       permutation: pick a row by weight, append, remove
 *       from the pool, repeat. {@code priority} is ignored
 *       (it's only relevant as a tie-breaker fallback when
 *       every weight is 0).</li>
 * </ul>
 *
 * <p>The output of {@link #order(List)} is consumed once per
 * {@link ProviderRegistry#refresh()} and stored in the live
 * roster — the orchestrators iterate it as-is, so the same
 * order is used for every message until the next refresh.
 */
@Component
public class ProviderSelector {

    public List<ProviderConfigRow> order(List<ProviderConfigRow> rows) {
        if (rows.isEmpty()) return List.of();
        Policy policy = rows.get(0).policy();
        return switch (policy) {
            case PRIORITY -> rows.stream()
                    .sorted(Comparator
                            .comparingInt(ProviderConfigRow::priority)
                            .thenComparing(ProviderConfigRow::providerKey))
                    .toList();
            case WEIGHTED -> weightedOrder(rows);
        };
    }

    private List<ProviderConfigRow> weightedOrder(List<ProviderConfigRow> rows) {
        List<ProviderConfigRow> pool = new ArrayList<>(rows);
        List<ProviderConfigRow> result = new ArrayList<>(pool.size());
        while (!pool.isEmpty()) {
            int totalWeight = pool.stream().mapToInt(ProviderConfigRow::weight).sum();
            if (totalWeight <= 0) {
                result.addAll(pool);
                break;
            }
            int pick = ThreadLocalRandom.current().nextInt(totalWeight);
            int cursor = 0;
            for (int i = 0; i < pool.size(); i++) {
                cursor += pool.get(i).weight();
                if (pick < cursor) {
                    result.add(pool.remove(i));
                    break;
                }
            }
        }
        return result;
    }
}