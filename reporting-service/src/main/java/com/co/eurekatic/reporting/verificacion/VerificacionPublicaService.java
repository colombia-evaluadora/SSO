package com.co.eurekatic.reporting.verificacion;

import com.co.eurekatic.reporting.config.ReportingProperties;
import com.co.eurekatic.reporting.data.QueryServiceClient;
import com.co.eurekatic.reporting.web.ReportService;
import com.github.benmanes.caffeine.cache.Cache;
import com.github.benmanes.caffeine.cache.Caffeine;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.web.server.ResponseStatusException;

import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/**
 * Lado publico de la verificacion del boletin. Sin token de usuario: todo va
 * por /public/service del query-service con funciones que solo aceptan el
 * codigo del QR (y los 4 ultimos digitos del documento para los datos).
 *
 * <ul>
 *   <li>El ESTADO no lleva nada del estudiante: estado, fechas,
 *       establecimiento, sede y periodo.</li>
 *   <li>El PDF exige el segundo factor, y la base es la que lo compara: sin
 *       los digitos correctos la funcion no devuelve ni una fila.</li>
 * </ul>
 */
@Service
public class VerificacionPublicaService {

    static final String NO_VALIDO = "NO_VALIDO";
    /** Un solo mensaje para todo fallo del segundo factor: no dice que fallo. */
    static final String FACTOR_INCORRECTO = "No fue posible verificar los datos ingresados.";

    private final ReportingProperties props;
    private final QueryServiceClient queryService;
    private final ReportService reportes;
    private final LimitesVerificacion limites;
    /** PDF ya generado por codigo, con el digest del factor que lo abrio. */
    private final Cache<String, PdfVerificado> pdfs;

    record PdfVerificado(byte[] pdf, byte[] factor) {}

    public VerificacionPublicaService(ReportingProperties props, QueryServiceClient queryService,
                                      ReportService reportes, LimitesVerificacion limites) {
        this.props = props;
        this.queryService = queryService;
        this.reportes = reportes;
        this.limites = limites;
        this.pdfs = Caffeine.newBuilder()
                .expireAfterWrite(props.getVerificacion().getPdfCacheTtl())
                .maximumSize(200)
                .build();
    }

    /** El estado publico de un codigo. Inexistente, revocado o mal formado: NO_VALIDO. */
    public Map<String, Object> estado(String codigo) {
        Map<String, Object> fila = consultar(codigo);
        Map<String, Object> out = new LinkedHashMap<>();
        if (fila == null) {
            out.put("estado", NO_VALIDO);
            return out;
        }
        out.put("estado", Objects.toString(fila.get("estado"), NO_VALIDO));
        out.put("emitidoEn", fila.get("emitido_en"));
        if (fila.get("actualizado_en") != null) {
            out.put("actualizadoEn", fila.get("actualizado_en"));
        }
        out.put("institucion", fila.get("institucion"));
        out.put("sede", fila.get("sede"));
        out.put("periodo", periodo(fila));
        return out;
    }

    /**
     * El boletin ACTUAL del codigo en PDF con marca de agua, si los 4 digitos
     * coinciden. 404 si el codigo no es valido o hoy no hay datos; 403 con un
     * mensaje generico si el factor no coincide; 429 tras 5 fallos.
     */
    public byte[] pdf(String codigo, String ultimos4) {
        if (!VerificacionBoletin.codigoValido(codigo)) {
            throw noValido();
        }
        limites.exigirIntentosDisponibles(codigo);
        if (!VerificacionBoletin.ultimos4Validos(ultimos4)) {
            limites.registrarFallo(codigo);
            throw new ResponseStatusException(HttpStatus.FORBIDDEN, FACTOR_INCORRECTO);
        }
        byte[] factor = VerificacionBoletin.digest(ultimos4);
        PdfVerificado previo = pdfs.getIfPresent(codigo);
        if (previo != null && MessageDigest.isEqual(previo.factor(), factor)) {
            return previo.pdf();
        }

        Map<String, Object> estado = consultar(codigo);
        if (estado == null) {
            throw noValido();
        }
        Map<String, Object> params = new LinkedHashMap<>();
        params.put("BODY.CODIGO", codigo);
        params.put("BODY.ULTIMOS4", ultimos4.trim());
        List<Map<String, Object>> filas = queryService.publicRows(
                null, props.getVerificacion().getDatosUuid(), params, props.getMaxRows());
        if (filas.isEmpty()) {
            throw noValido();
        }
        if (!Boolean.TRUE.equals(filas.get(0).get("factor_ok"))) {
            limites.registrarFallo(codigo);
            throw new ResponseStatusException(HttpStatus.FORBIDDEN, FACTOR_INCORRECTO);
        }
        limites.limpiarFallos(codigo);

        List<Map<String, Object>> datos = filasDelBoletin(filas);
        if (datos.isEmpty()) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND,
                    "El boletin no esta disponible en este momento.");
        }
        String nivel = Objects.toString(estado.get("nivel"), "");
        String variante = variante(nivel);
        VerificacionBoletin.marcar(datos, nivel,
                Map.of(VerificacionBoletin.clave(nivel, datos.get(0)), codigo),
                props.getVerificacion().getBaseUrl());
        byte[] pdf = reportes.renderBoletin(variante, datos,
                Map.of(VerificacionBoletin.PARAMETRO_MARCA, VerificacionBoletin.marcaDeAgua()));
        pdfs.put(codigo, new PdfVerificado(pdf, factor));
        return pdf;
    }

    /** Una revocacion deja de servir el PDF ya cacheado en esta instancia. */
    public void olvidar(String codigo) {
        pdfs.invalidate(codigo);
    }

    private Map<String, Object> consultar(String codigo) {
        if (!VerificacionBoletin.codigoValido(codigo)) {
            return null;
        }
        List<Map<String, Object>> r = queryService.publicRows(
                null, props.getVerificacion().getConsultarUuid(),
                Map.of("BODY.CODIGO", codigo), 2);
        return r.isEmpty() ? null : r.get(0);
    }

    /** Las filas jsonb de fn_boletin_verificacion_datos, en su orden. */
    @SuppressWarnings("unchecked")
    static List<Map<String, Object>> filasDelBoletin(List<Map<String, Object>> filas) {
        List<Map<String, Object>> out = new ArrayList<>(filas.size());
        for (Map<String, Object> f : filas) {
            if (f.get("fila") instanceof Map<?, ?> m) {
                out.add(new LinkedHashMap<>((Map<String, Object>) m));
            }
        }
        return out;
    }

    private String variante(String nivel) {
        ReportingProperties.Report boletin = props.getReports().get(props.getVerificacion().getReporte());
        String v = boletin == null || boletin.getVariants() == null ? null : boletin.getVariants().get(nivel);
        if (v == null) {
            throw new IllegalStateException("Nivel de boletin sin variante configurada: " + nivel);
        }
        return v;
    }

    private static String periodo(Map<String, Object> fila) {
        Object p = fila.get("periodo");
        Object a = fila.get("anio");
        if (p == null) {
            return a == null ? null : a.toString();
        }
        return a == null ? p.toString() : p + " " + a;
    }

    private static ResponseStatusException noValido() {
        return new ResponseStatusException(HttpStatus.NOT_FOUND, "Codigo de verificacion no valido.");
    }
}
