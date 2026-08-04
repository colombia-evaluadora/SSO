package com.example.cdc.common.transform;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.event.Operation;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;

class TlistaValorSplitterTest {

    @Test
    void routes_TPAIS_category_to_TPAIS_table() {
        CdcEvent event = new CdcEvent(
                Operation.INSERT,
                null,
                Map.of("categoria", "TPAIS", "valor", "CO", "nombre", "Colombia"),
                new CdcEvent.Source("academico", "public", "tlista_valor", 100L, 12345L, "false"),
                1712345678000L,
                "public.tlista_valor",
                null,
                null
        );
        OperationContext ctx = new OperationContext("tlista_valor", "AUTO_SPLIT", "ACADEMICO",
                "PK_LISTA_VALOR", true, false, false);

        Optional<Map<String, Object>> result = new TlistaValorSplitter().apply(event, ctx);

        assertThat(result).isPresent();
        assertThat(result.get()).containsEntry("ORACLE_TABLE", "TPAIS");
        assertThat(result.get()).containsEntry("VALOR", "CO");
    }

    @Test
    void returns_empty_for_unknown_category() {
        CdcEvent event = new CdcEvent(
                Operation.INSERT,
                null,
                Map.of("categoria", "UNKNOWN", "valor", "X"),
                new CdcEvent.Source("academico", "public", "tlista_valor", 100L, 12345L, "false"),
                1712345678000L,
                "public.tlista_valor",
                null,
                null
        );
        OperationContext ctx = new OperationContext("tlista_valor", "AUTO_SPLIT", "ACADEMICO",
                "PK_LISTA_VALOR", true, false, false);

        Optional<Map<String, Object>> result = new TlistaValorSplitter().apply(event, ctx);

        assertThat(result).isEmpty();
    }
}