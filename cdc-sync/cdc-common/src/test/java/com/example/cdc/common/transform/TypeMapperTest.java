package com.example.cdc.common.transform;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.event.Operation;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;

class TypeMapperTest {

    @Test
    void passes_through_values() {
        CdcEvent event = new CdcEvent(
                Operation.INSERT,
                null,
                Map.of("saldo", 100.50, "activo", true),
                new CdcEvent.Source("academico", "public", "clientes", 100L, 12345L, "false"),
                1712345678000L,
                "public.clientes",
                null,
                null
        );
        OperationContext ctx = new OperationContext("clientes", "CLIENTES", "ACADEMICO",
                "PK_CLIENTE", true, false, false);

        Optional<Map<String, Object>> result = new TypeMapper().apply(event, ctx);

        assertThat(result).isPresent();
        assertThat(result.get()).containsEntry("saldo", 100.50);
        assertThat(result.get()).containsEntry("activo", true);
    }
}