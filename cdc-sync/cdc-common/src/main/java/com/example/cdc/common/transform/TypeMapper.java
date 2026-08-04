package com.example.cdc.common.transform;

import com.example.cdc.common.event.CdcEvent;
import org.springframework.stereotype.Component;

import java.util.HashMap;
import java.util.Map;
import java.util.Optional;

@Component
public class TypeMapper implements Transformer {

    @Override
    public Optional<Map<String, Object>> apply(CdcEvent event, OperationContext ctx) {
        // TypeMapper no transforma valores aquí — solo declara el tipo destino.
        // La conversión efectiva la hace OracleJdbcWriter al hacer bind().
        // Este transformer es un marker; podría usarse en el futuro para validación.
        Map<String, Object> in = event.after() != null ? event.after() : event.before();
        if (in == null) return Optional.of(Map.of());
        return Optional.of(new HashMap<>(in));
    }
}