package com.example.cdc.common.transform;

import com.example.cdc.common.event.CdcEvent;

import java.util.Map;
import java.util.Optional;

public interface Transformer {
    Optional<Map<String, Object>> apply(CdcEvent event, OperationContext ctx);
}