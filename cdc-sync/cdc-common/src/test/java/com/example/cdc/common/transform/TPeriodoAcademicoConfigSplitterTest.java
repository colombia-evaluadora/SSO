package com.example.cdc.common.transform;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.event.CdcEventFixture;
import com.example.cdc.common.snapshot.SnapshotCache;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class TPeriodoAcademicoConfigSplitterTest {
    private TPeriodoAcademicoConfigSplitter tx;
    private SnapshotCache cacheWithCriterio;
    private SnapshotCache cacheEmpty;

    @BeforeEach
    void setUp() {
        cacheWithCriterio = new SnapshotCache(Map.of(), Map.of(), Map.of(),
                Map.of(100L, Map.of("MINIMA", 3.0, "MAXIMA", 5.0)),
                Map.of(), Map.of(), Map.of(), Map.of(), Map.of());
        cacheEmpty = SnapshotCache.empty();
        tx = new TPeriodoAcademicoConfigSplitter(cacheWithCriterio);
    }

    @Test
    void emitsConfigAndPeriodoWhenCriterioExists() {
        CdcEvent ev = CdcEventFixture.createInsert("tperiodo_academico",
                Map.of("pk_periodo_academico", 100, "nombre", "2026-1",
                        "fecha_limite_matricula", "2026-01-31",
                        "hora_inicio", "07:00", "hora_fin", "15:00",
                        "bloques_por_defecto", 6, "fk_tlv_jornada", "COMPLETA"));
        List<TPeriodoAcademicoConfigSplitter.Split> splits = tx.apply(ev);
        assertThat(splits).hasSize(2);
        TPeriodoAcademicoConfigSplitter.Split config = splits.get(0);
        TPeriodoAcademicoConfigSplitter.Split periodo = splits.get(1);
        assertThat(config.oracleTable()).isEqualTo("TPERIODO_ACADEMICO_CONFIG");
        assertThat(config.row()).containsEntry("HORA_INICIO", "07:00");
        assertThat(periodo.oracleTable()).isEqualTo("TPERIODO_ACADEMICO");
        assertThat(periodo.row()).containsEntry("FECHA_LIMITE", "2026-01-31");
    }

    @Test
    void emitsOnlyPeriodoWhenCriterioMissing() {
        TPeriodoAcademicoConfigSplitter t = new TPeriodoAcademicoConfigSplitter(cacheEmpty);
        CdcEvent ev = CdcEventFixture.createInsert("tperiodo_academico",
                Map.of("pk_periodo_academico", 200, "nombre", "2026-2"));
        List<TPeriodoAcademicoConfigSplitter.Split> splits = t.apply(ev);
        assertThat(splits).hasSize(1);
        assertThat(splits.get(0).oracleTable()).isEqualTo("TPERIODO_ACADEMICO");
    }

    @Test
    void criterioEvaluacionEmitsConfigUpsert() {
        CdcEvent ev = CdcEventFixture.createInsert("tcriterio_evaluacion",
                Map.of("pk_criterio", 1, "fk_periodo_academico", 100, "minima", 3.0));
        List<TPeriodoAcademicoConfigSplitter.Split> splits = tx.apply(ev);
        assertThat(splits).hasSize(1);
        assertThat(splits.get(0).oracleTable()).isEqualTo("TPERIODO_ACADEMICO_CONFIG");
        assertThat(splits.get(0).pkColumn()).isEqualTo("FK_TPERIODO_ACADEMICO");
    }

    @Test
    void renamesFechaLimiteMatriculaAndJornadaFk() {
        CdcEvent ev = CdcEventFixture.createInsert("tperiodo_academico",
                Map.of("pk_periodo_academico", 200, "fecha_limite_matricula", "2026-02-01",
                        "fk_tlv_jornada", "JORNADA_X"));
        TPeriodoAcademicoConfigSplitter t = new TPeriodoAcademicoConfigSplitter(cacheEmpty);
        List<TPeriodoAcademicoConfigSplitter.Split> splits = t.apply(ev);
        assertThat(splits.get(0).row()).containsEntry("FECHA_LIMITE", "2026-02-01")
                .containsEntry("FK_TJORNADA", "JORNADA_X");
    }
}