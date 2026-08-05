package com.example.cdc.common.transform;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.event.CdcEventFixture;
import com.example.cdc.common.event.Operation;
import com.example.cdc.common.snapshot.SnapshotCache;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;

class TMatriculaConsolidatorTest {

    private static final CdcEvent.Context NULL_CTX = null;

    @Test
    void consolidates_matricula_with_promotion_and_socioeconomic_snapshots() {
        SnapshotCache cache = new SnapshotCache(
                Map.of(101L, Map.of(
                        "proviene_sector_privado", "S",
                        "seguridad_social_eps", "EPS Familiar")),
                Map.of(101L, Map.of(
                        "justificacion_rendimiento_academico", "Rendimiento sobresaliente",
                        "fk_tgrupo_promovido", 81L)),
                Map.of(), Map.of(), Map.of(), Map.of(), Map.of());
        TMatriculaConsolidator consolidator = new TMatriculaConsolidator(cache);

        CdcEvent event = new CdcEvent(
                Operation.UPDATE,
                Map.of("pk_tmatricula", 101L),
                Map.of(
                        "pk_tmatricula", 101L,
                        "fk_testudiante", 33L,
                        "promocion_anticipada", "S"),
                new CdcEvent.Source("academico", "public", "tmatricula", 100L, 12345L, "false"),
                1712345678000L,
                "public.tmatricula",
                null,
                null);

        Map<String, Object> result = consolidator.apply(event, NULL_CTX);

        assertThat(result)
                .containsEntry("pk_tmatricula", 101L)
                .containsEntry("fk_testudiante", 33L)
                .containsEntry("proviene_sector_privado", "S")
                .containsEntry("seguridad_social_eps", "EPS Familiar")
                .containsEntry("justificacion_rendimiento_academico", "Rendimiento sobresaliente")
                .containsEntry("fk_tgrupo_promovido", 81L);
    }

    @Test
    void consolidatesSocioSnapshotOnMatriculaEvent() {
        SnapshotCache cache = new SnapshotCache(
                Map.of(42L, Map.of("ESTRATO", 3, "INGRESOS", 1500)),
                Map.of(), Map.of(), Map.of(), Map.of(), Map.of(), Map.of()
        );
        TMatriculaConsolidator cons = new TMatriculaConsolidator(cache);
        CdcEvent ev = CdcEventFixture.createInsert("tmatricula",
                Map.of("pk_tmatricula", 42, "fk_tlv_tipo_matricula", "Matricula", "estado", "A"));

        Map<String, Object> result = cons.apply(ev, NULL_CTX);

        assertThat(result).containsEntry("ESTRATO", 3).containsEntry("INGRESOS", 1500);
    }

    @Test
    void consolidatesPromoSnapshotOnlyWhenFlagged() {
        SnapshotCache cache = new SnapshotCache(
                Map.of(),
                Map.of(42L, Map.of("PROMO_ANTICIPADA", "S", "MOTIVO", "X")),
                Map.of(), Map.of(), Map.of(), Map.of(), Map.of());
        TMatriculaConsolidator cons = new TMatriculaConsolidator(cache);
        CdcEvent ev = CdcEventFixture.createInsert("tmatricula",
                Map.of("pk_tmatricula", 42, "promocion_anticipada", "S"));

        Map<String, Object> result = cons.apply(ev, NULL_CTX);

        assertThat(result).containsEntry("PROMO_ANTICIPADA", "S");
    }

    @Test
    void handlesSnapshotMissGracefully() {
        TMatriculaConsolidator cons = new TMatriculaConsolidator(SnapshotCache.empty());
        CdcEvent ev = CdcEventFixture.createInsert("tmatricula",
                Map.of("pk_tmatricula", 999, "fk_tlv_tipo_matricula", "Matricula"));

        Map<String, Object> result = cons.apply(ev, NULL_CTX);

        assertThat(result).containsKey("pk_tmatricula");
    }

    @Test
    void discriminatesInscripcionType() {
        TMatriculaConsolidator cons = new TMatriculaConsolidator(SnapshotCache.empty());
        CdcEvent ev = CdcEventFixture.createInsert("tinscripcion",
                Map.of("pk_tinscripcion", 1, "fk_tmatricula", 100, "fk_tlv_tipo_matricula", "Inscripcion"));

        Map<String, Object> result = cons.apply(ev, NULL_CTX);

        assertThat(result).containsEntry("fk_tlv_tipo_matricula", "Inscripcion");
    }

    @Test
    void handlesBothSnapshotsTogether() {
        SnapshotCache cache = new SnapshotCache(
                Map.of(1L, Map.of("ESTRATO", 2)),
                Map.of(1L, Map.of("PROMO_ANTICIPADA", "S")),
                Map.of(), Map.of(), Map.of(), Map.of(), Map.of());
        TMatriculaConsolidator cons = new TMatriculaConsolidator(cache);
        CdcEvent ev = CdcEventFixture.createInsert("tmatricula",
                Map.of("pk_tmatricula", 1, "fk_tlv_tipo_matricula", "Matricula", "promocion_anticipada", "S"));

        Map<String, Object> result = cons.apply(ev, NULL_CTX);

        assertThat(result).containsEntry("ESTRATO", 2).containsEntry("PROMO_ANTICIPADA", "S");
    }

    @Test
    void usesBeforeWhenDelete() {
        SnapshotCache cache = new SnapshotCache(
                Map.of(),
                Map.of(),
                Map.of(), Map.of(), Map.of(), Map.of(), Map.of());
        TMatriculaConsolidator cons = new TMatriculaConsolidator(cache);
        CdcEvent ev = CdcEventFixture.createDelete("tmatricula",
                Map.of("pk_tmatricula", 7, "fk_tlv_tipo_matricula", "Matricula"));

        Map<String, Object> result = cons.apply(ev, NULL_CTX);

        assertThat(result).containsEntry("pk_tmatricula", 7);
    }

    @Test
    void transformerInterfaceShimWrapsResult() {
        SnapshotCache cache = new SnapshotCache(
                Map.of(),
                Map.of(),
                Map.of(), Map.of(), Map.of(), Map.of(), Map.of());
        TMatriculaConsolidator cons = new TMatriculaConsolidator(cache);
        CdcEvent ev = CdcEventFixture.createInsert("tmatricula",
                Map.of("pk_tmatricula", 11, "fk_tlv_tipo_matricula", "Matricula"));
        OperationContext ctx = new OperationContext(
                "tmatricula", "TMATRICULA", "ACADEMICO", "PK_TMATRICULA",
                true, false, false);

        Optional<Map<String, Object>> result = cons.apply(ev, ctx);

        assertThat(result).isPresent();
        assertThat(result.get()).containsEntry("pk_tmatricula", 11);
    }
}
