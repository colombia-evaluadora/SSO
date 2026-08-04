package com.example.cdc.common.transform;

import com.example.cdc.common.event.CdcEvent;
import org.springframework.stereotype.Component;
import org.yaml.snakeyaml.Yaml;

import java.io.InputStream;
import java.util.HashMap;
import java.util.Map;
import java.util.Optional;

@Component
public class TlistaValorSplitter implements Transformer {

    private final Map<String, Map<String, String>> splits;

    public TlistaValorSplitter() {
        try (InputStream in = getClass().getResourceAsStream("/transforms/catalog-split.yaml")) {
            Map<String, Object> root = new Yaml().load(in);
            this.splits = (Map<String, Map<String, String>>) root.get("splits");
        } catch (Exception e) {
            throw new RuntimeException("Error cargando catalog-split.yaml", e);
        }
    }

    @Override
    public Optional<Map<String, Object>> apply(CdcEvent event, OperationContext ctx) {
        Map<String, Object> row = event.after() != null ? event.after() : event.before();
        if (row == null) return Optional.empty();

        String categoria = (String) row.get("categoria");
        Map<String, String> split = splits.get(categoria);
        if (split == null) {
            // Categoría no mapeada → omitir
            return Optional.empty();
        }

        Map<String, Object> result = new HashMap<>();
        result.put("ORACLE_TABLE", split.get("oracle_table"));
        result.put("PK_COLUMN", split.get("pk_column"));
        result.put("CODIGO_COLUMN", split.get("codigo_column"));
        // Por ahora copiamos todos los campos tal cual (la PK la genera Oracle IDENTITY)
        for (Map.Entry<String, Object> e : row.entrySet()) {
            result.put(e.getKey().toUpperCase(), e.getValue());
        }
        return Optional.of(result);
    }
}