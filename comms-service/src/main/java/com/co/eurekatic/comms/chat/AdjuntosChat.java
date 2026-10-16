package com.co.eurekatic.comms.chat;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;

import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * Adjunto real de un mensaje. El front no sube el binario aca: manda el mismo
 * POST de mensaje como multipart a {@code /files/eval-col/comunicaciones/...};
 * file-service lo guarda en S3, lo registra en TARCHIVO (inactivo) y reenvia el
 * JSON con {@code ADJUNTO = pk_tarchivo}. Aca se valida ese pk antes de
 * referenciarlo: que exista, que lo haya subido quien escribe, que no este ya en
 * otro mensaje, y el tipo y peso permitidos. Si se rechaza, file-service deja la
 * fila inactiva para su limpieza periodica.
 *
 * <p>Antivirus: no hay ClamAV en la plataforma (ni en file-service ni en el
 * compose); la defensa es la lista cerrada de extensiones, el tope de peso y que
 * file-service sirve el binario con su propio Content-Type desde otro path.
 */
@Component
public class AdjuntosChat {

    /** Extension → formato que pinta el front. */
    static final Map<String, String> EXTENSIONES = Map.ofEntries(
            Map.entry("pdf", "PDF"), Map.entry("doc", "WORD"), Map.entry("docx", "WORD"),
            Map.entry("xls", "OTRO"), Map.entry("xlsx", "OTRO"), Map.entry("ppt", "OTRO"),
            Map.entry("pptx", "OTRO"), Map.entry("txt", "OTRO"), Map.entry("csv", "OTRO"),
            Map.entry("jpg", "IMAGEN"), Map.entry("jpeg", "IMAGEN"), Map.entry("png", "IMAGEN"),
            Map.entry("gif", "IMAGEN"), Map.entry("webp", "IMAGEN"),
            Map.entry("mp4", "VIDEO"), Map.entry("webm", "VIDEO"), Map.entry("mov", "VIDEO"));

    private static final Pattern IDENTIFICADOR = Pattern.compile("[a-z_][a-z0-9_]*");

    private final JdbcClient jdbc;
    private final long maxBytes;

    public AdjuntosChat(JdbcClient jdbc, @Value("${comms.adjuntos.max-bytes:20971520}") long maxBytes) {
        this.jdbc = jdbc;
        this.maxBytes = maxBytes;
    }

    public record Archivo(long id, String nombre, String formato, long peso) { }

    /** Valida el pk que reenvio file-service y devuelve lo que se guarda en el mensaje. */
    public Archivo validar(long archivoId, String sub) {
        var ubicacion = jdbc.sql("""
                SELECT schema_name, table_name FROM public.file_reference_location WHERE pk_tarchivo = :pk""")
                .param("pk", archivoId).query((rs, n) -> new String[] {rs.getString(1), rs.getString(2)})
                .optional().orElse(new String[] {"academico_test", "tarchivo"});
        if (!IDENTIFICADOR.matcher(ubicacion[0]).matches() || !IDENTIFICADOR.matcher(ubicacion[1]).matches()) {
            throw new ApiError(400, "El archivo adjunto no es valido.");
        }
        var fila = jdbc.sql("SELECT nombre, peso, created_by FROM " + ubicacion[0] + "." + ubicacion[1]
                        + " WHERE pk_tarchivo = :pk")
                .param("pk", archivoId)
                .query((rs, n) -> new Object[] {rs.getString(1), rs.getLong(2), rs.getString(3)})
                .optional().orElseThrow(() -> new ApiError(400, "El archivo adjunto no existe."));
        String nombre = (String) fila[0];
        long peso = (Long) fila[1];
        String creador = (String) fila[2];
        if (creador == null || !creador.equalsIgnoreCase(sub)) {
            throw new ApiError(403, "Solo puedes adjuntar archivos que subiste tu.");
        }
        Boolean usado = jdbc.sql("SELECT EXISTS (SELECT 1 FROM comunicaciones.tmensaje WHERE fk_tarchivo = :pk)")
                .param("pk", archivoId).query(Boolean.class).single();
        if (Boolean.TRUE.equals(usado)) throw new ApiError(409, "Ese archivo ya esta adjunto a otro mensaje.");
        String formato = formatoDe(nombre);
        if (formato == null) {
            throw new ApiError(400, "Ese tipo de archivo no se puede adjuntar. Usa PDF, Word, Excel, PowerPoint,"
                    + " texto, imagen o video.");
        }
        if (peso > maxBytes) {
            throw new ApiError(400, "El archivo supera el maximo de " + (maxBytes / (1024 * 1024)) + " MB.");
        }
        return new Archivo(archivoId, nombre, formato, peso);
    }

    /** Formato por extension; null si no esta permitida. */
    static String formatoDe(String nombre) {
        if (nombre == null) return null;
        int punto = nombre.lastIndexOf('.');
        if (punto < 0 || punto == nombre.length() - 1) return null;
        return EXTENSIONES.get(nombre.substring(punto + 1).toLowerCase(Locale.ROOT));
    }
}
