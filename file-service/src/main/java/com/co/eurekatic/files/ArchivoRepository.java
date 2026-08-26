package com.co.eurekatic.files;

import com.co.eurekatic.common.audit.AuditContext;
import com.co.eurekatic.common.audit.AuditContextExtractor;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

/**
 * La tabla de siempre que este servicio escribe es {@code TARCHIVO} —
 * pero desde V143 no es la única posible: una {@code query} del catálogo
 * puede declarar {@code file_storage_schema}/{@code file_storage_table}
 * (ver {@code FileDestinationAccessService.Destino}) y pedir que SU
 * referencia quede en otra tabla, siempre que tenga el mismo formato de
 * columnas que {@code academico_test.tarchivo} (exigido por
 * {@code fn_validar_tabla_archivo} al guardar la query).
 *
 * <p>El diseño de la tabla ya estaba pensado para S3 — guarda
 * {@code urls3}, no los bytes — así que aquí sólo se registra el
 * objeto que se acaba de subir.
 *
 * <p><b>¿Cómo sabe {@code buscarActivo(pk)} en qué tabla mirar, si el
 * llamante sólo tiene el id?</b> {@code public.file_reference_location}
 * (V143) es el registro global de "este pk vive en esta tabla" — se
 * escribe en el mismo INSERT que {@link #reservar} y se consulta en
 * cada operación posterior. {@code pk_tarchivo} sigue siendo único sin
 * importar la tabla porque todas comparten la misma secuencia,
 * {@code public.seq_pk_tarchivo}.
 */
@Repository
public class ArchivoRepository {

    private static final Pattern IDENTIFICADOR = Pattern.compile("[a-zA-Z_][a-zA-Z0-9_]*");
    private static final String TABLA_DEFAULT = "tarchivo";

    private final NamedParameterJdbcTemplate jdbc;
    private final String schema;

    public ArchivoRepository(NamedParameterJdbcTemplate jdbc,
                             @org.springframework.beans.factory.annotation.Value(
                                     "${files.schema:academico_test}") String schema) {
        this.jdbc = jdbc;
        this.schema = schema;
    }

    /**
     * Fija las GUCs de sesión que {@code academico_test.fn_audit_ctx()}
     * (V26) lee, para que el INSERT/UPDATE/DELETE que sigue en el mismo
     * método quede atribuido — hoy llega vacío porque nadie las fija.
     * {@code @Transactional} en cada método público de esta clase
     * garantiza que este {@code set_config} y la escritura real comparten
     * conexión — sin eso, el pool podría entregar una conexión distinta
     * para cada llamada JDBC y la GUC nunca llegaría al trigger.
     *
     * <p>Una tabla de destino distinta a {@code academico_test.tarchivo}
     * (V143) puede no tener ese trigger — esta llamada sigue fijando las
     * GUCs igual, simplemente no las consume nadie en ese caso. No es un
     * error: la auditoría de esa tabla es responsabilidad de quien la
     * declaró como destino, no de este repositorio.
     *
     * @param usuario correo del caller (ya humano-legible — a diferencia
     *                de auth-center/sso-admin, no hace falta resolver un
     *                nombre vía {@code fn_resolver_actor}, así que se usa
     *                tal cual para {@code app.user_id}).
     * @param idUser  {@code public.users.id_user} del caller (claim
     *                {@code uid} del JWT), o {@code null} para tokens
     *                legado sin ese claim. Se puentea a
     *                {@code academico_test.TUSUARIO.PK_TUSUARIO} — mismo
     *                espacio de ID que necesita {@code app.user_pk}.
     */
    private void applyAuditContext(String usuario, Long idUser, String etiqueta) {
        Long pkTusuario = idUser == null ? null
                : jdbc.getJdbcOperations().queryForObject(
                        "SELECT public.fn_get_academico_usuario_id(?)", Long.class, idUser);
        Optional<AuditContext> ctx = AuditContextExtractor.fromCurrentRequest(Map.of());

        // V-audit-ctx-4 (sesiones reales): sesion_id/familia viajan
        // en el header X-Authenticated-Family-Id que api-gateway
        // forwardea. Lo leemos directamente del request (mismo
        // patrón que AuditContextExtractor) en vez de propagarlo por
        // cada signature de ReenvioController -- el costo de un
        // header lookup por escritura es cero, y centraliza la
        // captura de la familia en este único punto.
        String familyId = currentFamilyHeader();

        Map<String, Object> contexto = new LinkedHashMap<>();
        if (familyId != null && !familyId.isBlank()) {
            contexto.put("sesion_id", familyId);
            contexto.put("familia", familyId);
        }

        jdbc.getJdbcOperations().queryForList(
                "SELECT set_config('app.user_id', ?, true), "
                        + "set_config('app.user_pk', ?, true), "
                        + "set_config('app.etiqueta', ?, true), "
                        + "set_config('app.request_id', ?, true), "
                        + "set_config('app.http_method', ?, true), "
                        + "set_config('app.client_ip', ?, true), "
                        + "set_config('app.user_agent', ?, true), "
                        + "set_config('app.contexto', ?, true)",
                usuario,
                pkTusuario == null ? null : pkTusuario.toString(),
                etiqueta,
                ctx.map(AuditContext::requestId).orElse(null),
                ctx.map(AuditContext::httpMethod).orElse("PATCH"),
                ctx.map(AuditContext::clientIp).orElse(null),
                ctx.map(AuditContext::userAgent).orElse(null),
                contexto.isEmpty() ? null : writeJson(contexto));
    }

    private static String currentFamilyHeader() {
        if (!(RequestContextHolder.getRequestAttributes() instanceof ServletRequestAttributes sra)) {
            return null;
        }
        String v = sra.getRequest().getHeader("X-Authenticated-Family-Id");
        return (v == null || v.isBlank()) ? null : v;
    }

    private static String writeJson(Map<String, Object> map) {
        try {
            return new com.fasterxml.jackson.databind.ObjectMapper().writeValueAsString(map);
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * {@code override} viene de {@code query.file_storage_schema} —
     * dato de catálogo, no de un request — pero de todas formas se
     * valida como identificador SQL antes de interpolarlo en un
     * {@code .formatted(...)}: {@code fn_validar_tabla_archivo} (V143)
     * ya lo exige al guardar la query, esto es sólo la segunda puerta
     * de este lado.
     */
    private String schemaDe(String override) {
        String valor = (override == null || override.isBlank()) ? this.schema : override;
        validarIdentificador(valor, "schema");
        return valor;
    }

    private String tablaDe(String override) {
        String valor = (override == null || override.isBlank()) ? TABLA_DEFAULT : override;
        validarIdentificador(valor, "tabla");
        return valor;
    }

    private static void validarIdentificador(String valor, String queEs) {
        if (!IDENTIFICADOR.matcher(valor).matches()) {
            throw new IllegalStateException(
                    "file_storage: " + queEs + " '" + valor + "' no es un identificador SQL válido");
        }
    }

    /** Dónde vive un {@code pk_tarchivo} ya reservado — ver {@code public.file_reference_location}. */
    private record Ubicacion(String schema, String tabla) {}

    private Ubicacion ubicacionDe(long pkTarchivo) {
        var filas = jdbc.query(
                "SELECT schema_name, table_name FROM public.file_reference_location WHERE pk_tarchivo = :pk",
                new MapSqlParameterSource().addValue("pk", pkTarchivo),
                (rs, n) -> new Ubicacion(rs.getString("schema_name"), rs.getString("table_name")));
        return filas.isEmpty() ? null : filas.get(0);
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
    public long reservar(String nombre, long peso, String usuario, Long idUser) {
        return reservar(nombre, peso, usuario, idUser, null);
    }

    /**
     * Igual que {@link #reservar(String, long, String, Long)}, pero
     * además guarda {@code etiqueta} — la clasificación declarada en el
     * catálogo ({@code FILE:perfilUsuario}, ver {@code ParamTypes.FILE})
     * cuando el campo la trae. Consistente con las filas históricas
     * migradas, que siempre tenían {@code etiqueta} poblada
     * ({@code perfilUsuario}, {@code escudo}, {@code firmaMecanica}...);
     * antes de esto, TODA fila nueva subida por file-service dejaba la
     * columna en {@code NULL}.
     */
    public long reservar(String nombre, long peso, String usuario, Long idUser, String etiqueta) {
        return reservar(nombre, peso, usuario, idUser, etiqueta, null, null);
    }

    /**
     * V143 — igual que el overload de 5 argumentos, pero además permite
     * indicar en qué {@code schemaDestino.tablaDestino} debe quedar la
     * fila, en vez de siempre {@code files.schema.tarchivo}. Viene de
     * {@code query.file_storage_schema}/{@code file_storage_table} — ver
     * {@code FileDestinationAccessService.Destino}. {@code null} en
     * cualquiera de los dos = el default de siempre.
     *
     * <p>El pk se reserva EXPLÍCITAMENTE de {@code public.seq_pk_tarchivo}
     * (en vez de dejar que la tabla lo genere) porque esa secuencia es
     * COMPARTIDA por todas las tablas de destino posibles — es lo que
     * mantiene {@code pk_tarchivo} único sin importar en cuál terminó la
     * fila, y lo que {@code public.file_reference_location} necesita
     * para no repetir ids entre tablas.
     */
    @Transactional
    public long reservar(String nombre, long peso, String usuario, Long idUser, String etiqueta,
                         String schemaDestino, String tablaDestino) {
        String schemaResuelto = schemaDe(schemaDestino);
        String tablaResuelta = tablaDe(tablaDestino);

        applyAuditContext(usuario, idUser, "Subida de archivo " + nombre);

        Long pk = jdbc.getJdbcOperations().queryForObject(
                "SELECT nextval('public.seq_pk_tarchivo')", Long.class);

        jdbc.update("""
                INSERT INTO %s.%s (pk_tarchivo, nombre, peso, etiqueta, fecha, created_by, created_at, active)
                VALUES (:pk, :nombre, :peso, :etiqueta, CURRENT_DATE, :usuario, CURRENT_TIMESTAMP, false)
                """.formatted(schemaResuelto, tablaResuelta),
                new MapSqlParameterSource()
                        .addValue("pk", pk)
                        .addValue("nombre", nombre)
                        .addValue("peso", peso)
                        .addValue("etiqueta", etiqueta)
                        .addValue("usuario", usuario));

        jdbc.update("""
                INSERT INTO public.file_reference_location (pk_tarchivo, schema_name, table_name)
                VALUES (:pk, :schema, :tabla)
                """,
                new MapSqlParameterSource()
                        .addValue("pk", pk)
                        .addValue("schema", schemaResuelto)
                        .addValue("tabla", tablaResuelta));

        return pk;
    }

    /**
     * Cierra la fila una vez el objeto está en S3.
     *
     * <p>Sigue en {@code active = false}: quien la activa es el
     * procedimiento del catálogo, porque es el único que sabe si la
     * operación de negocio completa tuvo éxito. Si el {@code CALL}
     * final falla, esta fila se queda inactiva y la recoge la limpieza.
     */
    @Transactional
    public void registrarUrl(long pkTarchivo, String url, String usuario, Long idUser) {
        applyAuditContext(usuario, idUser, "Cierre de subida pk_tarchivo=" + pkTarchivo);
        Ubicacion u = ubicacionDe(pkTarchivo);
        if (u == null) {
            throw new IllegalStateException(
                    "pk_tarchivo=" + pkTarchivo + " no tiene ubicación registrada en "
                            + "file_reference_location -- ¿se reservó con este repositorio?");
        }
        jdbc.update("""
                UPDATE %s.%s
                   SET urls3 = :url, modified_at = CURRENT_TIMESTAMP
                 WHERE pk_tarchivo = :pk
                """.formatted(u.schema(), u.tabla()),
                new MapSqlParameterSource()
                        .addValue("url", url)
                        .addValue("pk", pkTarchivo));
        jdbc.update(
                "UPDATE public.file_reference_location SET urls3 = :url WHERE pk_tarchivo = :pk",
                new MapSqlParameterSource().addValue("url", url).addValue("pk", pkTarchivo));
    }

    /**
     * Borra la reserva cuando la subida falla. Es best-effort: si esto
     * también falla, la fila queda inactiva y la limpieza periódica la
     * recoge igual. Por eso no propaga la excepción — enmascararía el
     * error real de la subida, que es el que le interesa al llamante.
     */
    @Transactional
    public void descartar(long pkTarchivo, String usuario, Long idUser) {
        try {
            applyAuditContext(usuario, idUser, "Rollback de subida pk_tarchivo=" + pkTarchivo);
            Ubicacion u = ubicacionDe(pkTarchivo);
            if (u == null) {
                return;
            }
            jdbc.update("DELETE FROM %s.%s WHERE pk_tarchivo = :pk AND active = false"
                            .formatted(u.schema(), u.tabla()),
                    new MapSqlParameterSource().addValue("pk", pkTarchivo));
            jdbc.update(
                    "DELETE FROM public.file_reference_location WHERE pk_tarchivo = :pk",
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
     *
     * <p>V143 — {@code pks} puede repartirse entre varias tablas de
     * destino (aunque en la práctica todos los ficheros de un mismo
     * multipart van a la misma, porque comparten destino de query); se
     * agrupan por {@code schema.tabla} y se emite un {@code UPDATE} por
     * grupo.
     */
    @Transactional
    public void activar(List<Long> pks, String usuario, Long idUser) {
        if (pks == null || pks.isEmpty()) {
            return;
        }
        applyAuditContext(usuario, idUser, "Activación de " + pks.size() + " archivo(s)");

        record UbicacionPk(long pk, String schema, String tabla) {}
        List<UbicacionPk> filas = jdbc.query("""
                SELECT pk_tarchivo, schema_name, table_name
                  FROM public.file_reference_location
                 WHERE pk_tarchivo IN (:pks)
                """,
                new MapSqlParameterSource().addValue("pks", pks),
                (rs, n) -> new UbicacionPk(rs.getLong("pk_tarchivo"),
                        rs.getString("schema_name"), rs.getString("table_name")));

        Map<String, List<Long>> pksPorTabla = filas.stream().collect(Collectors.groupingBy(
                f -> f.schema() + "." + f.tabla(),
                Collectors.mapping(UbicacionPk::pk, Collectors.toList())));

        pksPorTabla.forEach((tablaCalificada, pksDeEsaTabla) -> jdbc.update("""
                UPDATE %s
                   SET active = true, modified_at = CURRENT_TIMESTAMP
                 WHERE pk_tarchivo IN (:pks)
                """.formatted(tablaCalificada),
                new MapSqlParameterSource().addValue("pks", pksDeEsaTabla)));
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
    public Optional<Archivo> buscarActivo(long pkTarchivo) {
        Ubicacion u = ubicacionDe(pkTarchivo);
        if (u == null) {
            return Optional.empty();
        }
        var filas = jdbc.query("""
                SELECT pk_tarchivo, nombre, peso, urls3
                  FROM %s.%s
                 WHERE pk_tarchivo = :pk AND active = true
                """.formatted(u.schema(), u.tabla()),
                new MapSqlParameterSource().addValue("pk", pkTarchivo),
                ArchivoRepository::mapearArchivo);
        return filas.isEmpty() ? Optional.empty() : Optional.of(filas.get(0));
    }

    /**
     * V67 — igual que {@link #buscarActivo(long)}, pero buscando por
     * {@code urls3} exacto en vez de por pk. La usa {@code
     * DownloadController#publico} ({@code GET /files/public/**}): ese
     * endpoint recibe la CLAVE S3 en la ruta (no un id), y este chequeo
     * es lo que evita servir bytes de un objeto que ya no está en el
     * catálogo (fila borrada, o nunca cerrada) aunque el objeto siga
     * físicamente en el bucket.
     *
     * <p>V143 — la búsqueda arranca en {@code file_reference_location}
     * (que mantiene {@code urls3} espejado desde {@link #registrarUrl})
     * para encontrar en qué tabla mirar, sin importar cuál sea.
     */
    public Optional<Archivo> buscarActivoPorClave(String urls3) {
        record UbicacionUrl(long pk, String schema, String tabla) {}
        var candidatos = jdbc.query("""
                SELECT pk_tarchivo, schema_name, table_name
                  FROM public.file_reference_location
                 WHERE urls3 = :urls3
                """,
                new MapSqlParameterSource().addValue("urls3", urls3),
                (rs, n) -> new UbicacionUrl(rs.getLong("pk_tarchivo"),
                        rs.getString("schema_name"), rs.getString("table_name")));
        if (candidatos.isEmpty()) {
            return Optional.empty();
        }
        var u = candidatos.get(0);
        var filas = jdbc.query("""
                SELECT pk_tarchivo, nombre, peso, urls3
                  FROM %s.%s
                 WHERE pk_tarchivo = :pk AND active = true
                """.formatted(u.schema(), u.tabla()),
                new MapSqlParameterSource().addValue("pk", u.pk()),
                ArchivoRepository::mapearArchivo);
        return filas.isEmpty() ? Optional.empty() : Optional.of(filas.get(0));
    }

    private static Archivo mapearArchivo(java.sql.ResultSet rs, int n) throws java.sql.SQLException {
        // peso es nullable en el esquema: getLong() devuelve 0 para
        // NULL, que es indistinguible de un archivo vacío. Sólo importa
        // para decidir si podemos poner Content-Length, así que lo
        // normalizamos aquí.
        long peso = rs.getLong("peso");
        return new Archivo(
                rs.getLong("pk_tarchivo"),
                rs.getString("nombre"),
                rs.wasNull() ? -1 : peso,
                rs.getString("urls3"));
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
