package com.example.cdc.common.transform;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.event.Operation;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;

class ColumnRenamerTest {

    @Test
    void renames_lowercase_columns_to_uppercase() {
        CdcEvent event = new CdcEvent(
                Operation.INSERT,
                null,
                Map.of("pk_cliente", 1, "nombre", "Alice"),
                new CdcEvent.Source("academico", "public", "clientes", 100L, 12345L, "false"),
                1712345678000L,
                "public.clientes",
                null,
                null
        );
        OperationContext ctx = new OperationContext("clientes", "CLIENTES", "ACADEMICO",
                "PK_CLIENTE", true, false, false);

        Optional<Map<String, Object>> result = new ColumnRenamer().apply(event, ctx);

        assertThat(result).isPresent();
        assertThat(result.get()).containsEntry("PK_CLIENTE", 1);
        assertThat(result.get()).containsEntry("NOMBRE", "Alice");
    }
}
