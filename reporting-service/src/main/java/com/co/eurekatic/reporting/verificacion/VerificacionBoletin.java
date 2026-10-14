package com.co.eurekatic.reporting.verificacion;

import com.co.eurekatic.reporting.render.Fechas;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.format.DateTimeFormatter;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.regex.Pattern;

/**
 * Reglas puras de la verificacion del boletin por QR: formato del codigo y
 * del segundo factor, clave de cada boletin dentro de las filas y la URL que
 * va en el QR.
 */
public final class VerificacionBoletin {

    /** Mismo formato que valida la base (CHK_TBOLETIN_EMISION_CODIGO). */
    static final Pattern CODIGO = Pattern.compile("^[A-Za-z0-9_-]{22,32}$");
    static final Pattern ULTIMOS4 = Pattern.compile("^[0-9A-Za-z]{4}$");

    public static final String CAMPO_CODIGO = "codigo_verificacion";
    public static final String CAMPO_URL = "url_verificacion";
    public static final String PARAMETRO_MARCA = "MARCA_VERIFICACION";

    private static final DateTimeFormatter MARCA =
            DateTimeFormatter.ofPattern("dd/MM/yyyy HH:mm");

    private VerificacionBoletin() {}

    public static boolean codigoValido(String codigo) {
        return codigo != null && CODIGO.matcher(codigo).matches();
    }

    public static boolean ultimos4Validos(String ultimos4) {
        return ultimos4 != null && ULTIMOS4.matcher(ultimos4.trim()).matches();
    }

    /**
     * La clave que agrupa las filas de UN boletin, la misma que usa la
     * plantilla para empezar hoja y la que devuelve
     * fn_boletin_emision_registrar: la matricula, o documento|estudiante en
     * preescolar (sus filas no traen la matricula).
     */
    public static String clave(String nivel, Map<String, Object> fila) {
        if ("preescolar".equals(nivel)) {
            return Objects.toString(fila.get("documento"), "") + "|"
                    + Objects.toString(fila.get("estudiante"), "");
        }
        Object m = fila.get("matricula");
        if (m instanceof Number n) {
            return Long.toString(n.longValue());
        }
        return Objects.toString(m, "").trim();
    }

    /** URL del QR: la pagina publica del front seguida del codigo. */
    public static String url(String base, String codigo) {
        String b = base.endsWith("/") ? base.substring(0, base.length() - 1) : base;
        return b + "/" + codigo;
    }

    /** Pone codigo y URL en cada fila del boletin que tenga codigo. */
    public static void marcar(List<Map<String, Object>> filas, String nivel,
                              Map<String, String> codigosPorClave, String base) {
        for (Map<String, Object> fila : filas) {
            String codigo = codigosPorClave.get(clave(nivel, fila));
            if (codigo != null) {
                fila.put(CAMPO_CODIGO, codigo);
                fila.put(CAMPO_URL, url(base, codigo));
            }
        }
    }

    /** Texto de la marca de agua de la copia publica, en hora de Colombia. */
    public static String marcaDeAgua() {
        return "Copia de verificación — generada " + Fechas.ahora().format(MARCA);
    }

    /**
     * Digest del segundo factor para compararlo en tiempo constante
     * ({@link MessageDigest#isEqual}) contra el que ya se valido.
     */
    static byte[] digest(String valor) {
        try {
            return MessageDigest.getInstance("SHA-256")
                    .digest(valor.trim().toUpperCase(java.util.Locale.ROOT)
                            .getBytes(StandardCharsets.UTF_8));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }
}
