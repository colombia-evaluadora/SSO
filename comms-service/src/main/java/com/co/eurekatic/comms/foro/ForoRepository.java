package com.co.eurekatic.comms.foro;

import com.co.eurekatic.comms.chat.ChatDtos.Autor;
import com.co.eurekatic.comms.foro.ForoDtos.Etiqueta;
import com.co.eurekatic.comms.foro.ForoDtos.Publicacion;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

/** SQL de los foros sobre el schema {@code comunicaciones} (V563). */
@Repository
public class ForoRepository {

    /** Orden del listado; los fijados van siempre primero. */
    public static final Map<String, String> ORDENES = Map.of(
            "ACTIVIDAD", "ultima_actividad DESC",
            "NUEVAS", "created_at DESC",
            "TOP", "(respuestas + reacciones) DESC, ultima_actividad DESC");

    private final JdbcClient jdbc;

    public ForoRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    // ── etiquetas ──────────────────────────────────────────────────────────

    public List<Etiqueta> etiquetas(long canal) {
        return jdbc.sql("""
                SELECT pk_tforo_etiqueta, nombre, color, solo_moderadores FROM comunicaciones.tforo_etiqueta
                 WHERE fk_tcanal = :c AND eliminado_en IS NULL ORDER BY lower(nombre)""")
                .param("c", canal).query((rs, n) -> etiqueta(rs)).list();
    }

    public record EtiquetaBase(long id, long canal, boolean soloModeradores) { }

    public Optional<EtiquetaBase> etiquetaBase(long id) {
        return jdbc.sql("""
                SELECT pk_tforo_etiqueta, fk_tcanal, solo_moderadores FROM comunicaciones.tforo_etiqueta
                 WHERE pk_tforo_etiqueta = :id AND eliminado_en IS NULL""")
                .param("id", id)
                .query((rs, n) -> new EtiquetaBase(rs.getLong(1), rs.getLong(2), rs.getBoolean(3))).optional();
    }

    public boolean existeEtiqueta(long canal, String nombre) {
        return jdbc.sql("""
                SELECT EXISTS (SELECT 1 FROM comunicaciones.tforo_etiqueta
                                WHERE fk_tcanal = :c AND lower(nombre) = lower(:n) AND eliminado_en IS NULL)""")
                .param("c", canal).param("n", nombre).query(Boolean.class).single();
    }

    public Etiqueta crearEtiqueta(long canal, String nombre, String color, boolean soloModeradores, long creador) {
        return jdbc.sql("""
                INSERT INTO comunicaciones.tforo_etiqueta (fk_tcanal, nombre, color, solo_moderadores, creado_por)
                VALUES (:c, :n, :color, :solo, :u)
                RETURNING pk_tforo_etiqueta, nombre, color, solo_moderadores""")
                .param("c", canal).param("n", nombre).param("color", color).param("solo", soloModeradores)
                .param("u", creador).query((rs, n) -> etiqueta(rs)).single();
    }

    public void eliminarEtiqueta(long id) {
        jdbc.sql("UPDATE comunicaciones.tforo_etiqueta SET eliminado_en = NOW() WHERE pk_tforo_etiqueta = :id")
                .param("id", id).update();
        jdbc.sql("DELETE FROM comunicaciones.thilo_etiqueta WHERE fk_tforo_etiqueta = :id").param("id", id).update();
    }

    public void reemplazarEtiquetas(long hilo, Collection<Long> etiquetas) {
        jdbc.sql("DELETE FROM comunicaciones.thilo_etiqueta WHERE fk_thilo = :h").param("h", hilo).update();
        for (Long e : etiquetas) {
            jdbc.sql("INSERT INTO comunicaciones.thilo_etiqueta (fk_thilo, fk_tforo_etiqueta) VALUES (:h, :e)")
                    .param("h", hilo).param("e", e).update();
        }
    }

    private static Etiqueta etiqueta(ResultSet rs) throws SQLException {
        return new Etiqueta(rs.getLong(1), rs.getString(2), rs.getString(3), rs.getBoolean(4));
    }

    // ── publicaciones ──────────────────────────────────────────────────────

    public record HiloBase(long id, long canal, long autor, long raiz, boolean cerrado, boolean resuelto) { }

    public Optional<HiloBase> hiloBase(long id) {
        return jdbc.sql("""
                SELECT pk_thilo, fk_tcanal, fk_autor, fk_tmensaje_raiz, cerrado, resuelto
                  FROM comunicaciones.thilo WHERE pk_thilo = :id AND eliminado_en IS NULL""")
                .param("id", id)
                .query((rs, n) -> new HiloBase(rs.getLong(1), rs.getLong(2), rs.getLong(3), rs.getLong(4),
                        rs.getBoolean(5), rs.getBoolean(6)))
                .optional();
    }

    public Optional<Long> hiloPorRaiz(long raiz) {
        return jdbc.sql("SELECT pk_thilo FROM comunicaciones.thilo WHERE fk_tmensaje_raiz = :m")
                .param("m", raiz).query(Long.class).optional();
    }

    /** Hilo al que pertenece un mensaje (cuerpo o respuesta). */
    public Optional<Long> hiloDeMensaje(long mensaje) {
        return jdbc.sql("""
                SELECT pk_thilo FROM comunicaciones.thilo WHERE fk_tmensaje_raiz = :m AND eliminado_en IS NULL
                UNION ALL
                SELECT hm.fk_thilo FROM comunicaciones.thilo_mensaje hm WHERE hm.fk_tmensaje = :m""")
                .param("m", mensaje).query(Long.class).list().stream().findFirst();
    }

    public long crearHilo(long canal, long raiz, long autor, String titulo, String texto) {
        return jdbc.sql("""
                INSERT INTO comunicaciones.thilo (fk_tcanal, fk_tmensaje_raiz, fk_autor, titulo, busqueda)
                VALUES (:c, :r, :a, :t, setweight(to_tsvector('spanish', :t), 'A')
                                      || setweight(to_tsvector('spanish', :x), 'B'))
                RETURNING pk_thilo""")
                .param("c", canal).param("r", raiz).param("a", autor).param("t", titulo).param("x", texto)
                .query(Long.class).single();
    }

    public void editarHilo(long hilo, String titulo, String texto) {
        jdbc.sql("""
                UPDATE comunicaciones.thilo
                   SET titulo = :t, modified_at = NOW(),
                       busqueda = setweight(to_tsvector('spanish', :t), 'A')
                                  || setweight(to_tsvector('spanish', :x), 'B')
                 WHERE pk_thilo = :h""")
                .param("t", titulo).param("x", texto).param("h", hilo).update();
    }

    /** {@code set} es SQL fijo del servicio, nunca texto del usuario. */
    public void actualizarHilo(long hilo, String set, Map<String, Object> params) {
        var q = jdbc.sql("UPDATE comunicaciones.thilo SET " + set + ", modified_at = NOW() WHERE pk_thilo = :h")
                .param("h", hilo);
        for (var e : params.entrySet()) q = q.param(e.getKey(), e.getValue());
        q.update();
    }

    public void eliminarHilo(long hilo, long por) {
        jdbc.sql("""
                UPDATE comunicaciones.thilo SET eliminado_en = NOW(), eliminado_por = :p
                 WHERE pk_thilo = :h AND eliminado_en IS NULL""")
                .param("p", por).param("h", hilo).update();
    }

    public void vincularRespuesta(long hilo, long mensaje) {
        jdbc.sql("INSERT INTO comunicaciones.thilo_mensaje (fk_tmensaje, fk_thilo) VALUES (:m, :h)")
                .param("m", mensaje).param("h", hilo).update();
        jdbc.sql("UPDATE comunicaciones.thilo SET ultima_actividad = NOW() WHERE pk_thilo = :h")
                .param("h", hilo).update();
    }

    /** La respuesta eliminada deja de ser la solucion. */
    public void olvidarSolucion(long mensaje) {
        jdbc.sql("""
                UPDATE comunicaciones.thilo SET fk_tmensaje_solucion = NULL WHERE fk_tmensaje_solucion = :m""")
                .param("m", mensaje).update();
    }

    public List<Long> idsRespuestas(long hilo, int limite) {
        return jdbc.sql("""
                SELECT hm.fk_tmensaje FROM comunicaciones.thilo_mensaje hm
                  JOIN comunicaciones.tmensaje m ON m.pk_tmensaje = hm.fk_tmensaje
                 WHERE hm.fk_thilo = :h AND m.eliminado_en IS NULL
                 ORDER BY hm.fk_tmensaje LIMIT :lim""")
                .param("h", hilo).param("lim", limite).query(Long.class).list();
    }

    // ── seguidores ─────────────────────────────────────────────────────────

    public void seguir(long hilo, long usuario, boolean seguir) {
        if (seguir) {
            jdbc.sql("""
                    INSERT INTO comunicaciones.thilo_seguidor (fk_thilo, fk_usuario) VALUES (:h, :u)
                    ON CONFLICT DO NOTHING""")
                    .param("h", hilo).param("u", usuario).update();
        } else {
            jdbc.sql("DELETE FROM comunicaciones.thilo_seguidor WHERE fk_thilo = :h AND fk_usuario = :u")
                    .param("h", hilo).param("u", usuario).update();
        }
    }

    /** Seguidores que siguen en el canal (quien salio o fue bloqueado no recibe avisos). */
    public Set<Long> seguidores(long hilo) {
        return new java.util.LinkedHashSet<>(jdbc.sql("""
                SELECT s.fk_usuario FROM comunicaciones.thilo_seguidor s
                  JOIN comunicaciones.thilo h ON h.pk_thilo = s.fk_thilo
                  JOIN comunicaciones.tcanal_miembro m ON m.fk_tcanal = h.fk_tcanal AND m.fk_usuario = s.fk_usuario
                 WHERE s.fk_thilo = :h AND m.salio_en IS NULL AND NOT m.bloqueado""")
                .param("h", hilo).query(Long.class).list());
    }

    // ── lectura ────────────────────────────────────────────────────────────

    private static final String SQL_PUBLICACIONES = """
            SELECT * FROM (
              SELECT h.pk_thilo, h.fk_tcanal, h.titulo, h.fk_autor,
                     COALESCE(NULLIF(a.full_name, ''), a.email) AS autor,
                     h.created_at, h.ultima_actividad, h.fijado, h.cerrado, h.resuelto, h.fk_tmensaje_solucion,
                     m.texto,
                     (SELECT COUNT(*) FROM comunicaciones.thilo_mensaje hm
                        JOIN comunicaciones.tmensaje x ON x.pk_tmensaje = hm.fk_tmensaje
                       WHERE hm.fk_thilo = h.pk_thilo AND x.eliminado_en IS NULL) AS respuestas,
                     (SELECT COUNT(*) FROM comunicaciones.tmensaje_reaccion r
                       WHERE r.fk_tmensaje = h.fk_tmensaje_raiz) AS reacciones,
                     EXISTS (SELECT 1 FROM comunicaciones.thilo_seguidor s
                              WHERE s.fk_thilo = h.pk_thilo AND s.fk_usuario = :visor) AS siguiendo,
                     COUNT(*) OVER () AS total
                FROM comunicaciones.thilo h
                JOIN public.users a ON a.id_user = h.fk_autor
                JOIN comunicaciones.tmensaje m ON m.pk_tmensaje = h.fk_tmensaje_raiz
               WHERE h.eliminado_en IS NULL AND %s
            ) t""";

    public record Filtro(String orden, Long etiqueta, String q, int pagina, int limite) { }

    public List<Publicacion> publicaciones(long canal, long visor, Filtro f, Set<Long> enLinea) {
        String where = """
                h.fk_tcanal = :canal
                AND (CAST(:etiqueta AS BIGINT) IS NULL OR EXISTS (
                     SELECT 1 FROM comunicaciones.thilo_etiqueta e
                      WHERE e.fk_thilo = h.pk_thilo AND e.fk_tforo_etiqueta = :etiqueta))
                AND (CAST(:q AS VARCHAR) IS NULL OR h.busqueda @@ websearch_to_tsquery('spanish', :q))""";
        String sql = SQL_PUBLICACIONES.formatted(where) + " ORDER BY fijado DESC, " + ORDENES.get(f.orden())
                + ", pk_thilo DESC LIMIT :lim OFFSET :off";
        List<Publicacion> filas = jdbc.sql(sql)
                .param("visor", visor).param("canal", canal).param("etiqueta", f.etiqueta()).param("q", f.q())
                .param("lim", f.limite()).param("off", f.pagina() * f.limite())
                .query((rs, n) -> publicacion(rs, visor, enLinea)).list();
        return conEtiquetas(filas);
    }

    public Optional<Publicacion> publicacion(long hilo, Long visor, Set<Long> enLinea) {
        long v = visor == null ? -1 : visor;
        List<Publicacion> filas = jdbc.sql(SQL_PUBLICACIONES.formatted("h.pk_thilo = :h"))
                .param("visor", v).param("h", hilo)
                .query((rs, n) -> publicacion(rs, visor, enLinea)).list();
        return conEtiquetas(filas).stream().findFirst();
    }

    private List<Publicacion> conEtiquetas(List<Publicacion> filas) {
        if (filas.isEmpty()) return filas;
        Map<Long, List<Etiqueta>> porHilo = new LinkedHashMap<>();
        jdbc.sql("""
                SELECT he.fk_thilo, e.pk_tforo_etiqueta, e.nombre, e.color, e.solo_moderadores
                  FROM comunicaciones.thilo_etiqueta he
                  JOIN comunicaciones.tforo_etiqueta e ON e.pk_tforo_etiqueta = he.fk_tforo_etiqueta
                 WHERE he.fk_thilo IN (:ids) AND e.eliminado_en IS NULL ORDER BY lower(e.nombre)""")
                .param("ids", filas.stream().map(Publicacion::id).toList())
                .query((rs, n) -> porHilo.computeIfAbsent(rs.getLong(1), k -> new ArrayList<>())
                        .add(new Etiqueta(rs.getLong(2), rs.getString(3), rs.getString(4), rs.getBoolean(5))))
                .list();
        return filas.stream().map(p -> new Publicacion(p.id(), p.foroId(), p.titulo(), p.autor(), p.esPropia(),
                p.fecha(), p.ultimaActividad(), p.respuestas(), p.reacciones(), p.fijada(), p.cerrada(),
                p.resuelta(), p.solucionId(), porHilo.getOrDefault(p.id(), List.of()), p.siguiendo(), p.extracto(),
                p.totalCount(), p.mensaje())).toList();
    }

    private static Publicacion publicacion(ResultSet rs, Long visor, Set<Long> enLinea) throws SQLException {
        long autor = rs.getLong("fk_autor");
        long solucion = rs.getLong("fk_tmensaje_solucion");
        Long solucionId = rs.wasNull() ? null : solucion;
        String texto = rs.getString("texto");
        return new Publicacion(rs.getLong("pk_thilo"), rs.getLong("fk_tcanal"), rs.getString("titulo"),
                new Autor(autor, rs.getString("autor"), enLinea.contains(autor)),
                visor != null && autor == visor, instante(rs, "created_at"), instante(rs, "ultima_actividad"),
                rs.getInt("respuestas"), rs.getInt("reacciones"), rs.getBoolean("fijado"), rs.getBoolean("cerrado"),
                rs.getBoolean("resuelto"), solucionId, List.of(), rs.getBoolean("siguiendo"),
                texto.length() > 200 ? texto.substring(0, 200) + "…" : texto, rs.getInt("total"), null);
    }

    private static String instante(ResultSet rs, String col) throws SQLException {
        return rs.getObject(col, OffsetDateTime.class).toInstant().toString();
    }
}
