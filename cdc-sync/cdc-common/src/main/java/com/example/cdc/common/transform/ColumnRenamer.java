package com.example.cdc.common.transform;

import com.example.cdc.common.event.CdcEvent;
import org.springframework.stereotype.Component;

import java.util.HashMap;
import java.util.Map;
import java.util.Optional;

@Component
public class ColumnRenamer implements Transformer {

    @Override
    public Optional<Map<String, Object>> apply(CdcEvent event, OperationContext ctx) {
        Map<String, Object> in = event.isInsert() || event.isUpdate() || event.isSnapshot()
                ? event.after()
                : event.before();
        if (in == null) return Optional.of(Map.of());

        Map<String, Object> out = new HashMap<>();
        for (Map.Entry<String, Object> e : in.entrySet()) {
            out.put(e.getKey().toUpperCase(), e.getValue());
        }
        return Optional.of(out);
    }
}