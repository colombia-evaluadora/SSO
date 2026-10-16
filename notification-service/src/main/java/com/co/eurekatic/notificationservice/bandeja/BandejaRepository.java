package com.co.eurekatic.notificationservice.bandeja;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

/**
 * Acceso a {@code notificacion}. JDBC directo y no JPA: el servicio arranca con
 * {@code ddl-auto=validate} y estas tablas no necesitan entidades.
 */
@Repository
public class BandejaRepository {

    private static final ObjectMapper JSON = new ObjectMapper();
    private static final TypeReference<List<String>> LISTA = new TypeReference<>() { };

    private static final String COLUMNAS = """
            id, tipo, categoria, titulo, cuerpo_corto, deep_link, prioridad,
            creada_en, leida_en, actores::text AS actores, conteo""";

    private final JdbcClient jdbc;

    public BandejaRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    public record Filtros(String categoria, String tipo, Boolean leidas, String texto) { }

    public record Pagina(List<NotificacionFila> items, Cursor siguiente) { }

    public Pagina listar(String usuario, Filtros f, Cursor cursor, int limit) {
        StringBuilder sql = new StringBuilder("SELECT ").append(COLUMNAS).append("""
                 FROM notificacion
                WHERE usuario = :usuario
                  AND archivada_en IS NULL
                  AND (expira_en IS NULL OR expira_en > NOW())""");
        var spec = new java.util.LinkedHashMap<String, Object>();
        spec.put("usuario", usuario);
        if (f.categoria() != null) {
            sql.append(" AND categoria = :categoria");
            spec.put("categoria", f.categoria());
        }
        if (f.tipo() != null) {
            sql.append(" AND tipo = :tipo");
            spec.put("tipo", f.tipo());
        }
        if (Boolean.TRUE.equals(f.leidas())) sql.append(" AND leida_en IS NOT NULL");
        if (Boolean.FALSE.equals(f.leidas())) sql.append(" AND leida_en IS NULL");
        if (f.texto() != null) {
            sql.append(" AND (titulo ILIKE :texto OR cuerpo_corto ILIKE :texto)");
            spec.put("texto", "%" + f.texto().replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%");
        }
        if (cursor != null) {
            sql.append(" AND (creada_en, id) < (:cursorEn, :cursorId)");
            spec.put("cursorEn", cursor.creadaEn());
            spec.put("cursorId", cursor.id());
        }
        sql.append(" ORDER BY creada_en DESC, id DESC LIMIT :limite");
        spec.put("limite", limit + 1);

        List<Object[]> filas = jdbc.sql(sql.toString()).params(spec)
                .query((rs, n) -> new Object[] {mapear(rs), rs.getObject("creada_en", OffsetDateTime.class)})
                .list();
        boolean hayMas = filas.size() > limit;
        List<Object[]> pagina = hayMas ? filas.subList(0, limit) : filas;
        Cursor siguiente = null;
        if (hayMas) {
            Object[] ultima = pagina.get(pagina.size() - 1);
            siguiente = new Cursor((OffsetDateTime) ultima[1], ((NotificacionFila) ultima[0]).id());
        }
        return new Pagina(pagina.stream().map(o -> (NotificacionFila) o[0]).toList(), siguiente);
    }

    public Optional<NotificacionFila> buscar(String usuario, UUID id) {
        return jdbc.sql("SELECT " + COLUMNAS + " FROM notificacion WHERE usuario = :usuario AND id = :id")
                .param("usuario", usuario).param("id", id)
                .query((rs, n) -> mapear(rs)).optional();
    }

    public long contarNoLeidas(String usuario) {
        return jdbc.sql("""
                SELECT COUNT(*) FROM notificacion
                 WHERE usuario = :usuario AND leida_en IS NULL AND archivada_en IS NULL
                   AND (expira_en IS NULL OR expira_en > NOW())""")
                .param("usuario", usuario).query(Long.class).single();
    }

    /** @return false si la notificacion no existe o no es del usuario. */
    public boolean marcarLeida(String usuario, UUID id, boolean leida) {
        String set = leida ? "leida_en = COALESCE(leida_en, NOW())" : "leida_en = NULL";
        return jdbc.sql("UPDATE notificacion SET " + set + " WHERE usuario = :usuario AND id = :id")
                .param("usuario", usuario).param("id", id).update() == 1;
    }

    public int marcarTodasLeidas(String usuario, String categoria) {
        return jdbc.sql("""
                UPDATE notificacion SET leida_en = NOW()
                 WHERE usuario = :usuario AND leida_en IS NULL AND archivada_en IS NULL
                   AND (CAST(:categoria AS VARCHAR) IS NULL OR categoria = :categoria)""")
                .param("usuario", usuario).param("categoria", categoria).update();
    }

    public boolean archivar(String usuario, UUID id) {
        return jdbc.sql("""
                UPDATE notificacion SET archivada_en = COALESCE(archivada_en, NOW())
                 WHERE usuario = :usuario AND id = :id""")
                .param("usuario", usuario).param("id", id).update() == 1;
    }

    public record NuevaNotificacion(
            UUID id, String usuario, String app, TipoNotificacion tipo, String titulo, String cuerpo,
            String deepLink, Map<String, Object> datos, String agrupacionKey, String actor,
            String prioridad, String dedupeKey, OffsetDateTime expiraEn) { }

    /**
     * Agrupa en la entrada abierta con la misma clave si esta dentro de la
     * ventana del tipo (D-2.4); si no, inserta. Devuelve la fila resultante, o
     * vacio si el {@code dedupeKey} ya se habia entregado a este usuario.
     */
    public Optional<NotificacionFila> registrar(NuevaNotificacion n) {
        String datos = escribir(n.datos() == null ? Map.of() : n.datos());
        if (n.dedupeKey() != null && yaEntregado(n.usuario(), n.dedupeKey())) return Optional.empty();
        if (n.agrupacionKey() != null && n.tipo().ventanaAgrupacion() != null) {
            Optional<UUID> agrupada = jdbc.sql("""
                    UPDATE notificacion
                       SET conteo = conteo + 1,
                           actores = CASE
                               WHEN CAST(:actor AS TEXT) IS NULL OR jsonb_exists(actores, CAST(:actor AS TEXT))
                               THEN actores
                               ELSE jsonb_build_array(CAST(:actor AS TEXT)) || actores END,
                           claves_dedupe = CASE WHEN CAST(:dedupe AS TEXT) IS NULL THEN claves_dedupe
                               ELSE claves_dedupe || jsonb_build_array(CAST(:dedupe AS TEXT)) END,
                           titulo = :titulo, cuerpo_corto = :cuerpo, deep_link = :deepLink,
                           datos = CAST(:datos AS JSONB), creada_en = NOW()
                     WHERE usuario = :usuario AND agrupacion_key = :clave
                       AND leida_en IS NULL AND archivada_en IS NULL
                       AND creada_en > NOW() - CAST(:ventana AS INTERVAL)
                       AND (CAST(:dedupe AS TEXT) IS NULL
                            OR NOT jsonb_exists(claves_dedupe, CAST(:dedupe AS TEXT)))
                    RETURNING id""")
                    .param("actor", n.actor()).param("titulo", n.titulo()).param("cuerpo", n.cuerpo())
                    .param("deepLink", n.deepLink()).param("datos", datos).param("usuario", n.usuario())
                    .param("clave", n.agrupacionKey()).param("dedupe", n.dedupeKey())
                    .param("ventana", n.tipo().ventanaAgrupacion().toSeconds() + " seconds")
                    .query(UUID.class).optional();
            if (agrupada.isPresent()) return buscar(n.usuario(), agrupada.get());
            // Un duplicado concurrente espero el bloqueo de la fila y ya no casa:
            // ahora si ve la clave confirmada por el otro.
            if (n.dedupeKey() != null && yaEntregado(n.usuario(), n.dedupeKey())) return Optional.empty();
            // Fuera de ventana: la entrada vieja deja de ser "abierta" para que
            // la nueva pueda ocupar el indice unico de agrupacion.
            jdbc.sql("""
                    UPDATE notificacion SET agrupacion_key = NULL
                     WHERE usuario = :usuario AND agrupacion_key = :clave
                       AND leida_en IS NULL AND archivada_en IS NULL""")
                    .param("usuario", n.usuario()).param("clave", n.agrupacionKey()).update();
        }
        Optional<UUID> insertada = jdbc.sql("""
                INSERT INTO notificacion
                    (id, usuario, app, tipo, categoria, titulo, cuerpo_corto, deep_link, datos,
                     agrupacion_key, actores, prioridad, dedupe_key, expira_en)
                VALUES (:id, :usuario, :app, :tipo, :categoria, :titulo, :cuerpo, :deepLink,
                        CAST(:datos AS JSONB), :clave,
                        CASE WHEN CAST(:actor AS TEXT) IS NULL THEN '[]'::jsonb
                             ELSE jsonb_build_array(CAST(:actor AS TEXT)) END,
                        :prioridad, :dedupe, :expira)
                ON CONFLICT DO NOTHING
                RETURNING id""")
                .param("id", n.id()).param("usuario", n.usuario()).param("app", n.app())
                .param("tipo", n.tipo().tipo()).param("categoria", n.tipo().categoria())
                .param("titulo", n.titulo()).param("cuerpo", n.cuerpo()).param("deepLink", n.deepLink())
                .param("datos", datos)
                .param("clave", n.tipo().ventanaAgrupacion() == null ? null : n.agrupacionKey())
                .param("actor", n.actor()).param("prioridad", n.prioridad()).param("dedupe", n.dedupeKey())
                .param("expira", n.expiraEn())
                .query(UUID.class).optional();
        return insertada.flatMap(id -> buscar(n.usuario(), id));
    }

    private boolean yaEntregado(String usuario, String dedupeKey) {
        return jdbc.sql("""
                SELECT EXISTS (SELECT 1 FROM notificacion
                                WHERE usuario = :usuario
                                  AND (dedupe_key = :dedupe OR jsonb_exists(claves_dedupe, :dedupe)))""")
                .param("usuario", usuario).param("dedupe", dedupeKey).query(Boolean.class).single();
    }

    /** Retencion (PLAN §11.5): leidas tras {@code diasLeidas}, el resto tras {@code diasNoLeidas}. */
    public int purgar(int diasLeidas, int diasNoLeidas) {
        return jdbc.sql("""
                DELETE FROM notificacion
                 WHERE (leida_en IS NOT NULL AND creada_en < NOW() - make_interval(days => :leidas))
                    OR creada_en < NOW() - make_interval(days => :noLeidas)
                    OR (expira_en IS NOT NULL AND expira_en < NOW())""")
                .param("leidas", diasLeidas).param("noLeidas", diasNoLeidas).update();
    }

    private static NotificacionFila mapear(ResultSet rs) throws SQLException {
        int conteo = rs.getInt("conteo");
        return new NotificacionFila(
                rs.getObject("id", UUID.class),
                rs.getString("tipo"),
                rs.getString("categoria"),
                rs.getString("titulo"),
                rs.getString("cuerpo_corto"),
                rs.getString("deep_link"),
                rs.getString("prioridad"),
                iso(rs.getObject("creada_en", OffsetDateTime.class)),
                iso(rs.getObject("leida_en", OffsetDateTime.class)),
                leer(rs.getString("actores")),
                conteo);
    }

    private static String iso(OffsetDateTime t) {
        return t == null ? null : t.toInstant().toString();
    }

    private static List<String> leer(String json) {
        if (json == null) return List.of();
        try {
            return JSON.readValue(json, LISTA);
        } catch (JsonProcessingException e) {
            return List.of();
        }
    }

    private static String escribir(Map<String, Object> datos) {
        try {
            return JSON.writeValueAsString(datos);
        } catch (JsonProcessingException e) {
            throw new IllegalArgumentException("datos no serializables", e);
        }
    }
}
