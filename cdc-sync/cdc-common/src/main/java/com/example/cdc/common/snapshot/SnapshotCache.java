package com.example.cdc.common.snapshot;

import java.util.Collections;
import java.util.Map;

/**
 * Immutable holder for the in-memory snapshots hydrated at worker startup by
 * {@code SnapshotHydrator}. Each map is keyed by the PG primary key of the
 * corresponding table and is intended for read-only access from the
 * transformers' hot path.
 *
 * <p>Only the maps consumed by L4-L6 transformers are modelled here:
 * {@code matriculaSocio}, {@code matriculaPromo}, {@code sedeUsuario},
 * {@code criterio}, {@code grupo}, plus the two reverse-lookup maps used to
 * translate {@code fk_tlv_jornada} and {@code fk_tlv_modelo_pedagogico} into
 * the Oracle foreign keys they replaced.
 */
public record SnapshotCache(
        Map<Long, Map<String, Object>> matriculaSocio,
        Map<Long, Map<String, Object>> matriculaPromo,
        Map<Long, SedeUsuarioRow> sedeUsuario,
        Map<Long, Map<String, Object>> criterio,
        Map<Long, Map<String, Object>> grupo,
        Map<String, Long> jornadaReverseMap,
        Map<String, Long> modeloPedagogicoReverseMap
) {

    /**
     * Canonical constructor — defensive copies keep the record immutable even
     * if callers hand in mutable maps.
     */
    public SnapshotCache {
        matriculaSocio = copyOf(matriculaSocio);
        matriculaPromo = copyOf(matriculaPromo);
        sedeUsuario = copyOf(sedeUsuario);
        criterio = copyOf(criterio);
        grupo = copyOf(grupo);
        jornadaReverseMap = copyOf(jornadaReverseMap);
        modeloPedagogicoReverseMap = copyOf(modeloPedagogicoReverseMap);
    }

    /**
     * Returns a cache with every map initialised to empty. Useful as a safe
     * fallback when hydration fails entirely so transformers can still be
     * constructed (they will log WARN + skip on the first cache miss).
     */
    public static SnapshotCache empty() {
        return new SnapshotCache(
                Map.of(),
                Map.of(),
                Map.of(),
                Map.of(),
                Map.of(),
                Map.of(),
                Map.of()
        );
    }

    /**
     * Composite representation of a {@code tsede_usuario} PG row. The Oracle
     * destination uses {@code (fk_tsede, fk_trol, fk_tusuario)} as its
     * composite primary key, so the snapshot keeps those three FK columns plus
     * {@code fk_tlv_jornada} (to resolve into {@code fk_tjornada} via
     * {@link #jornadaReverseMap}) and the {@code orden} column.
     */
    public record SedeUsuarioRow(
            Long fkSede,
            Long fkRol,
            Long fkUsuario,
            String fkLvJornada,
            Integer orden
    ) {}

    private static <K, V> Map<K, V> copyOf(Map<K, V> source) {
        if (source == null || source.isEmpty()) {
            return Collections.emptyMap();
        }
        return Map.copyOf(source);
    }
}
