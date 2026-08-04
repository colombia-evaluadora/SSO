package com.example.cdc.common.transform;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.event.Operation;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;

class TMatriculaConsolidatorTest {

    @Test
    void consolidates_matricula_with_promotion_and_socioeconomic_snapshots() {
        Map<Long, Map<String, Object>> snapshotCache = Map.of(
                701L, Map.of(
                        "justificacion_rendimiento_academico", "Rendimiento sobresaliente",
                        "fk_tgrupo_promovido", 81L
                ),
                702L, Map.of(
                        "proviene_sector_privado", "S",
                        "seguridad_social_eps", "EPS Familiar"
                )
        );
        TMatriculaConsolidator consolidator = new TMatriculaConsolidator(snapshotCache);
        CdcEvent event = new CdcEvent(
                Operation.UPDATE,
                Map.of("pk_tmatricula", 101L),
                Map.of(
                        "pk_tmatricula", 101L,
                        "fk_testudiante", 33L,
                        "fk_tmatricula_promocion", 701L,
                        "fk_tmatricula_socioeconomico", 702L
                ),
                new CdcEvent.Source("academico", "public", "tmatricula", 100L, 12345L, "false"),
                1712345678000L,
                "public.tmatricula",
                null,
                null
        );
        OperationContext ctx = new OperationContext(
                "tmatricula", "TMATRICULA", "ACADEMICO", "PK_TMATRICULA",
                false, true, false
        );

        Optional<Map<String, Object>> result = consolidator.apply(event, ctx);

        assertThat(result).isPresent();
        assertThat(result.get())
                .containsEntry("PK_TMATRICULA", 101L)
                .containsEntry("FK_TESTUDIANTE", 33L)
                .containsEntry("JUSTIFICACION_RENDIMIENTO_ACADEMICO", "Rendimiento sobresaliente")
                .containsEntry("FK_TGRUPO_PROMOVIDO", 81L)
                .containsEntry("PROVIENE_SECTOR_PRIVADO", "S")
                .containsEntry("SEGURIDAD_SOCIAL_EPS", "EPS Familiar");
    }
}
