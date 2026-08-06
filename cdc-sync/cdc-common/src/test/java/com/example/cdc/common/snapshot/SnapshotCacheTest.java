package com.example.cdc.common.snapshot;

import java.util.Map;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class SnapshotCacheTest {

    @Test
    void empty_cache_carries_tlista_valor_index_map() {
        SnapshotCache cache = SnapshotCache.empty();
        assertThat(cache.tlistaValorIndex()).isNotNull().isEmpty();
    }

    @Test
    void canonical_constructor_copies_tlista_valor_index_map() {
        Map<String, Long> jornada = Map.of("DIURNA", 1L, "NOCTURNA", 2L);
        Map<String, Long> modelo = Map.of("TRADICIONAL", 3L);
        SnapshotCache cache = new SnapshotCache(
            Map.of(), Map.of(), Map.of(), Map.of(), Map.of(),
            jornada, modelo,
            Map.of("JORNADA", jornada, "MODELO_PEDAGOGICO", modelo),
            Map.of());
        assertThat(cache.tlistaValorIndex())
            .containsEntry("JORNADA", jornada)
            .containsEntry("MODELO_PEDAGOGICO", modelo);
    }
}
