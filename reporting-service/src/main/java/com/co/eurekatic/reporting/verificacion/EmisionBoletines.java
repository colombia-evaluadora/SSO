package com.co.eurekatic.reporting.verificacion;

import com.co.eurekatic.reporting.config.ReportingProperties;
import com.co.eurekatic.reporting.data.QueryServiceClient;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/**
 * Lado autenticado de la verificacion: registra cada boletin impreso y le
 * pone su QR, y revoca una emision.
 *
 * <p>La huella NO se calcula aqui sino en la base (fn_boletin_huella_interno):
 * la verificacion publica tiene que decir si el boletin cambio SIN el segundo
 * factor, y para eso no puede bajar los datos a este servicio. Con la regla
 * en un solo lugar, la huella de la emision y la de la verificacion salen
 * siempre de la misma normalizacion.
 */
@Component
public class EmisionBoletines {

    private static final Logger log = LoggerFactory.getLogger(EmisionBoletines.class);

    private final ReportingProperties props;
    private final QueryServiceClient queryService;

    public EmisionBoletines(ReportingProperties props, QueryServiceClient queryService) {
        this.props = props;
        this.queryService = queryService;
    }

    /**
     * Registra las emisiones del boletin que se esta imprimiendo y agrega a
     * cada fila {@code codigo_verificacion} y {@code url_verificacion}. Sin
     * URL base configurada devuelve las filas como estan: el boletin sale sin
     * QR. Un fallo del registro NO corta la generacion: queda en el log y el
     * boletin sale sin QR, igual que sin URL base. El QR es un anadido; no
     * puede dejar al colegio sin poder imprimir el boletin.
     */
    public List<Map<String, Object>> marcar(String nivel, Map<String, Object> filtros,
                                            List<Map<String, Object>> rows, String bearer) {
        ReportingProperties.Verificacion v = props.getVerificacion();
        if (v == null || !v.habilitada() || rows == null || rows.isEmpty()) {
            return rows;
        }
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("FK_TGRUPO", filtro(filtros, "FK_TGRUPO"));
        body.put("FK_TPERIODO_EVALUACION", filtro(filtros, "FK_TPERIODO_EVALUACION"));
        body.put("NIVEL", nivel);
        Object matriculas = filtro(filtros, "FK_TMATRICULAS");
        if (matriculas != null) {
            body.put("FK_TMATRICULAS", matriculas);
        }

        List<Map<String, Object>> registradas;
        try {
            registradas = queryService.postRows(
                    null, v.getRegistrarPath(), bearer, body, props.getMaxRows());
        } catch (RuntimeException e) {
            log.warn("Boletin {}: fallo el registro de emisiones, sale sin QR: {}",
                    nivel, e.getMessage(), e);
            return rows;
        }
        Map<String, String> codigos = new HashMap<>();
        for (Map<String, Object> r : registradas) {
            codigos.put(Objects.toString(r.get("clave"), ""), Objects.toString(r.get("codigo"), null));
        }
        VerificacionBoletin.marcar(rows, nivel, codigos, v.getBaseUrl());
        log.info("Boletin {}: {} emision(es) registradas", nivel, codigos.size());
        return rows;
    }

    /** Revoca la emision de un codigo con el token de quien lo pide. */
    public Map<String, Object> revocar(String codigo, String motivo, String bearer) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("CODIGO", codigo);
        body.put("MOTIVO", motivo);
        List<Map<String, Object>> r = queryService.postRows(
                null, props.getVerificacion().getRevocarPath(), bearer, body, 1);
        return r.isEmpty() ? Map.of("codigo", codigo, "estado", "REVOCADA") : r.get(0);
    }

    /** Los filtros llegan con la caja que mande el front: se buscan sin distinguirla. */
    static Object filtro(Map<String, Object> filtros, String nombre) {
        if (filtros == null) {
            return null;
        }
        for (Map.Entry<String, Object> e : filtros.entrySet()) {
            if (e.getKey() != null && e.getKey().equalsIgnoreCase(nombre)) {
                return e.getValue();
            }
        }
        return null;
    }
}
