package com.co.eurekatic.files;

import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.support.GeneratedKeyHolder;
import org.springframework.jdbc.support.KeyHolder;
import org.springframework.stereotype.Repository;

/**
 * La única tabla que este servicio escribe: {@code TARCHIVO}.
 *
 * <p>El diseño de la tabla ya estaba pensado para S3 — guarda
 * {@code urls3}, no los bytes — así que aquí sólo se registra el
 * objeto que se acaba de subir.
 */
@Repository
public class ArchivoRepository {

    private final NamedParameterJdbcTemplate jdbc;
    private final String schema;

    public ArchivoRepository(NamedParameterJdbcTemplate jdbc,
                             @org.springframework.beans.factory.annotation.Value(
                                     "${files.schema:academico_test}") String schema) {
        this.jdbc = jdbc;
        this.schema = schema;
    }

    /**
     * Reserva la fila ANTES de subir a S3, con {@code active = false}.
     *
     * <p>El orden es deliberado. Si se subiera primero y el registro
     * fallara después, quedaría un objeto huérfano en el bucket: bytes
     * que nadie referencia, invisibles, que se pagan indefinidamente y
     * que sólo aparecen comparando el bucket entero contra la tabla —
     * con 408 000 objetos, esa reconciliación no es viable a mano.
     *
     * <p>Reservando primero, un fallo deja una fila inactiva: visible,
     * trazable y borrable con un {@code WHERE active = false AND
     * created_at < now() - interval '1 hour'}. Fallar dejando basura
     * visible siempre es preferible a dejarla invisible.
     *
     * <p>La columna {@code active} ya existía en el esquema; esto sólo
     * la usa para lo que sirve.
     */
    public long reservar(String nombre, long peso, String usuario) {
        return reservar(nombre, peso, usuario, null);
    }

    /**
     * Igual que {@link #reservar(String, long, String)}, pero además
     * guarda {@code etiqueta} — la clasificación declarada en el
     * catálogo ({@code FILE:perfilUsuario}, ver {@code ParamTypes.FILE})
     * cuando el campo la trae. Consistente con las filas históricas
     * migradas, que siempre tenían {@code etiqueta} poblada
     * ({@code perfilUsuario}, {@code escudo}, {@code firmaMecanica}...);
     * antes de esto, TODA fila nueva subida por file-service dejaba la
     * columna en {@code NULL}.
     */
    public long reservar(String nombre, long peso, String usuario, String etiqueta) {
        KeyHolder keys = new GeneratedKeyHolder();
        jdbc.update("""
                INSERT INTO %s.tarchivo (nombre, peso, etiqueta, fecha, created_by, created_at, active)
                VALUES (:nombre, :peso, :etiqueta, CURRENT_DATE, :usuario, CURRENT_TIMESTAMP, false)
                """.formatted(schema),
                new MapSqlParameterSource()
                        .addValue("nombre", nombre)
                        .addValue("peso", peso)
                        .addValue("etiqueta", etiqueta)
                        .addValue("usuario", usuario),
                keys, new String[] { "pk_tarchivo" });
        Number pk = keys.getKey();
        if (pk == null) {
            throw new IllegalStateException(
                    "El INSERT en tarchivo no devolvió pk_tarchivo");
        }
        return pk.longValue();
    }

    /**
     * Cierra la fila una vez el objeto está en S3.
     *
     * <p>Sigue en {@code active = false}: quien la activa es el
     * procedimiento del catálogo, porque es el único que sabe si la
     * operación de negocio completa tuvo éxito. Si el {@code CALL}
     * final falla, esta fila se queda inactiva y la recoge la limpieza.
     */
    public void registrarUrl(long pkTarchivo, String url) {
        jdbc.update("""
                UPDATE %s.tarchivo
                   SET urls3 = :url, modified_at = CURRENT_TIMESTAMP
                 WHERE pk_tarchivo = :pk
                """.formatted(schema),
                new MapSqlParameterSource()
                        .addValue("url", url)
                        .addValue("pk", pkTarchivo));
    }

    /**
     * Borra la reserva cuando la subida falla. Es best-effort: si esto
     * también falla, la fila queda inactiva y la limpieza periódica la
     * recoge igual. Por eso no propaga la excepción — enmascararía el
     * error real de la subida, que es el que le interesa al llamante.
     */
    public void descartar(long pkTarchivo) {
        try {
            jdbc.update("DELETE FROM %s.tarchivo WHERE pk_tarchivo = :pk AND active = false"
                            .formatted(schema),
                    new MapSqlParameterSource().addValue("pk", pkTarchivo));
        } catch (RuntimeException e) {
            // Silencio deliberado: ver javadoc.
        }
    }

    /**
     * Marca las filas como activas: la operación de negocio completa
     * terminó bien y el archivo ya "existe" de cara al resto del
     * sistema.
     *
     * <p>Quien llama a esto es {@code ReenvioController}, después de
     * que el catálogo devuelva 2xx. Es el único punto del flujo que
     * conoce las dos mitades: que los bytes están en S3 y que la
     * operación de negocio que los referencia tuvo éxito.
     *
     * <p>El diseño original dejaba esta activación al procedimiento
     * PL/pgSQL del catálogo. No funcionaba: las queries del catálogo
     * son INSERT/UPDATE sobre sus propias tablas y ninguna tocaba
     * TARCHIVO, así que toda fila subida se quedaba en
     * {@code active = false} — y por tanto indescargable, con un 404
     * que parecía "el archivo no existe" cuando los bytes estaban
     * perfectamente en el bucket. Además obligaba a recordar esta
     * regla en cada query nueva que aceptara un fichero, y olvidarla
     * fallaba en silencio.
     */
    public void activar(java.util.List<Long> pks) {
        if (pks == null || pks.isEmpty()) {
            return;
        }
        jdbc.update("""
                UPDATE %s.tarchivo
                   SET active = true, modified_at = CURRENT_TIMESTAMP
                 WHERE pk_tarchivo IN (:pks)
                """.formatted(schema),
                new MapSqlParameterSource().addValue("pks", pks));
    }

    /**
     * Busca la fila activa por id. Devuelve null si no existe o si la
     * fila está marcada inactiva (= reserva que nunca se cerró).
     *
     * <p>Descargar bytes de una fila inactiva es un agujero de auditoría:
     * una reserva huérfana podría tener un {@code urls3} apuntando a
     * cualquier cosa si alguien manipuló la BD. Sólo las filas cerradas
     * por el procedimiento del catálogo ({@code active = true}) son
     * archivos "reales" desde el punto de vista del negocio.
     */
    public java.util.Optional<Archivo> buscarActivo(long pkTarchivo) {
        var filas = jdbc.query("""
                SELECT pk_tarchivo, nombre, peso, urls3
                  FROM %s.tarchivo
                 WHERE pk_tarchivo = :pk AND active = true
                """.formatted(schema),
                new MapSqlParameterSource().addValue("pk", pkTarchivo),
                (rs, n) -> {
                    // peso es nullable en el esquema: getLong() devuelve
                    // 0 para NULL, que es indistinguible de un archivo
                    // vacío. Sólo importa para decidir si podemos poner
                    // Content-Length, así que lo normalizamos aquí.
                    long peso = rs.getLong("peso");
                    return new Archivo(
                            rs.getLong("pk_tarchivo"),
                            rs.getString("nombre"),
                            rs.wasNull() ? -1 : peso,
                            rs.getString("urls3"));
                });
        return filas.isEmpty() ? java.util.Optional.empty() : java.util.Optional.of(filas.get(0));
    }

    /**
     * V67 — igual que {@link #buscarActivo(long)}, pero buscando por
     * {@code urls3} exacto en vez de por pk. La usa {@code
     * DownloadController#publico} ({@code GET /files/public/**}): ese
     * endpoint recibe la CLAVE S3 en la ruta (no un id), y este chequeo
     * es lo que evita servir bytes de un objeto que ya no está en el
     * catálogo (fila borrada, o nunca cerrada) aunque el objeto siga
     * físicamente en el bucket.
     */
    public java.util.Optional<Archivo> buscarActivoPorClave(String urls3) {
        var filas = jdbc.query("""
                SELECT pk_tarchivo, nombre, peso, urls3
                  FROM %s.tarchivo
                 WHERE urls3 = :urls3 AND active = true
                """.formatted(schema),
                new MapSqlParameterSource().addValue("urls3", urls3),
                (rs, n) -> {
                    long peso = rs.getLong("peso");
                    return new Archivo(
                            rs.getLong("pk_tarchivo"),
                            rs.getString("nombre"),
                            rs.wasNull() ? -1 : peso,
                            rs.getString("urls3"));
                });
        return filas.isEmpty() ? java.util.Optional.empty() : java.util.Optional.of(filas.get(0));
    }

    /**
     * Proyección de las columnas que {@link DownloadController}
     * necesita.
     *
     * <p>No hay {@code mimetype}: TARCHIVO nunca lo guardó. El
     * content-type de la descarga se deriva de la extensión de la
     * clave S3 (ver {@code DownloadController#mediaTypeDe}).
     *
     * <p>{@code peso} vale -1 cuando la columna es NULL — pasa en
     * filas antiguas.
     */
    public record Archivo(long pkTarchivo, String nombre, long peso,
                          String urls3) {}
}
