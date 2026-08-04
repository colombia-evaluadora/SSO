package com.example.cdc.common.logging;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;

public class JsonLogger {

    private static final ObjectMapper mapper = new ObjectMapper();

    private final Logger slf4j;
    private final String servicio;

    public JsonLogger(Class<?> clazz, String servicio) {
        this.slf4j = LoggerFactory.getLogger(clazz);
        this.servicio = servicio;
    }

    public void info(String mensaje, Map<String, Object> contexto) {
        log("INFO", mensaje, contexto, null);
    }

    public void warn(String mensaje, Map<String, Object> contexto) {
        log("WARN", mensaje, contexto, null);
    }

    public void error(String mensaje, Throwable ex, Map<String, Object> contexto) {
        log("ERROR", mensaje, contexto, ex);
    }

    private void log(String nivel, String mensaje, Map<String, Object> contexto, Throwable ex) {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("ts", Instant.now().toString());
        row.put("nivel", nivel);
        row.put("servicio", servicio);
        row.put("logger", slf4j.getName());
        row.put("mensaje", mensaje);
        if (contexto != null) row.put("contexto", contexto.toString());
        if (ex != null) row.put("excepcion", ex.toString());
        try {
            String json = mapper.writeValueAsString(row);
            slf4j.info(json);
        } catch (Exception e) {
            slf4j.warn("Error serializando log JSON: {}", e.getMessage());
        }
    }
}
