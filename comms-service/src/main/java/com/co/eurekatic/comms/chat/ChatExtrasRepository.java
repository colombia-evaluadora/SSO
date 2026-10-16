package com.co.eurekatic.comms.chat;

import com.co.eurekatic.comms.chat.ChatDtos.ArchivoCompartido;
import com.co.eurekatic.comms.chat.ChatDtos.Borrador;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;

/** SQL de borradores, archivos compartidos y votaciones rapidas (V575, V560). */
@Repository
public class ChatExtrasRepository {

    private final JdbcClient jdbc;

    public ChatExtrasRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    // ── borradores ─────────────────────────────────────────────────────────

    private static final String SQL_BORRADOR = """
            SELECT b.pk_tborrador, b.fk_tcanal, b.texto, b.estado, b.modified_at, b.fk_usuario,
                   CASE WHEN c.tipo = 'DIRECTO'
                        THEN COALESCE((SELECT COALESCE(NULLIF(u.full_name, ''), u.email)
                                         FROM comunicaciones.tcanal_miembro m JOIN public.users u ON u.id_user = m.fk_usuario
                                        WHERE m.fk_tcanal = c.pk_tcanal AND m.fk_usuario <> b.fk_usuario LIMIT 1), c.nombre)
                        ELSE c.nombre END AS canal_nombre
              FROM comunicaciones.tborrador b
              JOIN comunicaciones.tcanal c ON c.pk_tcanal = b.fk_tcanal
             WHERE b.eliminado_en IS NULL AND c.eliminado_en IS NULL""";

    private static Borrador borrador(ResultSet rs) throws SQLException {
        return new Borrador(rs.getLong("pk_tborrador"), rs.getLong("fk_tcanal"), rs.getString("canal_nombre"),
                rs.getString("texto"), rs.getString("estado"),
                rs.getObject("modified_at", OffsetDateTime.class).toInstant().toString());
    }

    /** Borradores y enviados del usuario en canales donde sigue siendo miembro. */
    public List<Borrador> borradores(long usuario) {
        return jdbc.sql(SQL_BORRADOR + """
                 AND b.fk_usuario = :u
                 AND EXISTS (SELECT 1 FROM comunicaciones.tcanal_miembro m
                              WHERE m.fk_tcanal = b.fk_tcanal AND m.fk_usuario = :u AND m.salio_en IS NULL)
                ORDER BY b.modified_at DESC LIMIT 200""")
                .param("u", usuario).query((rs, n) -> borrador(rs)).list();
    }

    public Optional<Borrador> borrador(long id) {
        return jdbc.sql(SQL_BORRADOR + " AND b.pk_tborrador = :id").param("id", id)
                .query((rs, n) -> borrador(rs)).optional();
    }

    public Optional<Long> duenoBorrador(long id) {
        return jdbc.sql("SELECT fk_usuario FROM comunicaciones.tborrador WHERE pk_tborrador = :id AND eliminado_en IS NULL")
                .param("id", id).query(Long.class).optional();
    }

    /** Guarda (o reemplaza) el borrador vivo del canal; devuelve su id. */
    public long guardarBorrador(long canal, long usuario, String texto) {
        return jdbc.sql("""
                INSERT INTO comunicaciones.tborrador (fk_tcanal, fk_usuario, texto) VALUES (:c, :u, :t)
                ON CONFLICT (fk_tcanal, fk_usuario) WHERE estado = 'BORRADOR' AND eliminado_en IS NULL
                DO UPDATE SET texto = EXCLUDED.texto, modified_at = NOW()
                RETURNING pk_tborrador""")
                .param("c", canal).param("u", usuario).param("t", texto).query(Long.class).single();
    }

    /** Descarta el borrador vivo del canal (el editor quedo vacio). */
    public void descartarBorradorDeCanal(long canal, long usuario) {
        jdbc.sql("""
                UPDATE comunicaciones.tborrador SET eliminado_en = NOW()
                 WHERE fk_tcanal = :c AND fk_usuario = :u AND estado = 'BORRADOR' AND eliminado_en IS NULL""")
                .param("c", canal).param("u", usuario).update();
    }

    public void eliminarBorrador(long id) {
        jdbc.sql("UPDATE comunicaciones.tborrador SET eliminado_en = NOW() WHERE pk_tborrador = :id AND eliminado_en IS NULL")
                .param("id", id).update();
    }

    // ── archivos ───────────────────────────────────────────────────────────

    private static final String SQL_ARCHIVO = """
            SELECT m.fk_tarchivo, m.pk_tmensaje, m.adjunto_nombre, m.adjunto_formato, m.adjunto_peso, m.created_at,
                   m.fk_autor, COALESCE(NULLIF(a.full_name, ''), a.email) AS autor, c.pk_tcanal,
                   CASE WHEN c.tipo = 'DIRECTO'
                        THEN COALESCE((SELECT COALESCE(NULLIF(u.full_name, ''), u.email)
                                         FROM comunicaciones.tcanal_miembro t JOIN public.users u ON u.id_user = t.fk_usuario
                                        WHERE t.fk_tcanal = c.pk_tcanal AND t.fk_usuario <> :u LIMIT 1), c.nombre)
                        ELSE c.nombre END AS canal_nombre
              FROM comunicaciones.tmensaje m
              JOIN comunicaciones.tcanal c ON c.pk_tcanal = m.fk_tcanal
              JOIN comunicaciones.tcanal_miembro cm ON cm.fk_tcanal = m.fk_tcanal AND cm.fk_usuario = :u
              JOIN public.users a ON a.id_user = m.fk_autor
             WHERE m.fk_tarchivo IS NOT NULL AND m.eliminado_en IS NULL AND m.adjunto_eliminado_en IS NULL
               AND c.eliminado_en IS NULL AND cm.salio_en IS NULL AND NOT cm.bloqueado""";

    private static ArchivoCompartido archivo(ResultSet rs, long usuario) throws SQLException {
        long autor = rs.getLong("fk_autor");
        return new ArchivoCompartido(rs.getLong("fk_tarchivo"), rs.getLong("fk_tarchivo"), rs.getLong("pk_tmensaje"),
                rs.getString("adjunto_nombre"), rs.getString("adjunto_formato"),
                rs.getObject("adjunto_peso", Long.class), autor == usuario ? "Tú" : rs.getString("autor"),
                autor == usuario, rs.getObject("created_at", OffsetDateTime.class).toInstant().toString(),
                rs.getLong("pk_tcanal"), rs.getString("canal_nombre"), true, false);
    }

    /** Adjuntos vigentes de las conversaciones del usuario, del mas nuevo al mas viejo. */
    public List<ArchivoCompartido> archivos(long usuario) {
        return jdbc.sql(SQL_ARCHIVO + " ORDER BY m.pk_tmensaje DESC LIMIT 500").param("u", usuario)
                .query((rs, n) -> archivo(rs, usuario)).list();
    }

    public Optional<ArchivoCompartido> archivo(long archivoId, long usuario) {
        return jdbc.sql(SQL_ARCHIVO + " AND m.fk_tarchivo = :a").param("u", usuario).param("a", archivoId)
                .query((rs, n) -> archivo(rs, usuario)).optional();
    }

    // ── votaciones rapidas ─────────────────────────────────────────────────

    public void crearVotacion(long mensaje, String pregunta, String tipo, int minutos) {
        jdbc.sql("""
                INSERT INTO comunicaciones.tvotacion_rapida (fk_tmensaje, pregunta, tipo, minutos, cierra_en)
                VALUES (:m, :p, :t, :min, NOW() + make_interval(mins => :min))""")
                .param("m", mensaje).param("p", pregunta).param("t", tipo).param("min", minutos).update();
    }

    /** Cambiar la pregunta reinicia votos y tiempo. */
    public void reemplazarVotacion(long mensaje, String pregunta, String tipo, int minutos) {
        jdbc.sql("DELETE FROM comunicaciones.tvotacion_rapida_voto WHERE fk_tmensaje = :m").param("m", mensaje).update();
        jdbc.sql("""
                UPDATE comunicaciones.tvotacion_rapida
                   SET pregunta = :p, tipo = :t, minutos = :min, cierra_en = NOW() + make_interval(mins => :min)
                 WHERE fk_tmensaje = :m""")
                .param("m", mensaje).param("p", pregunta).param("t", tipo).param("min", minutos).update();
        jdbc.sql("UPDATE comunicaciones.tmensaje SET editado_en = NOW() WHERE pk_tmensaje = :m")
                .param("m", mensaje).update();
    }

    /** Cierre de la votacion; vacio si el mensaje no es una votacion. */
    public Optional<OffsetDateTime> cierreVotacion(long mensaje) {
        return jdbc.sql("SELECT cierra_en FROM comunicaciones.tvotacion_rapida WHERE fk_tmensaje = :m")
                .param("m", mensaje).query(OffsetDateTime.class).optional();
    }

    /** Registra el voto; false si la persona ya habia votado. */
    public boolean votar(long mensaje, long usuario, int opcion) {
        return jdbc.sql("""
                INSERT INTO comunicaciones.tvotacion_rapida_voto (fk_tmensaje, fk_usuario, opcion)
                VALUES (:m, :u, :o) ON CONFLICT DO NOTHING""")
                .param("m", mensaje).param("u", usuario).param("o", opcion).update() == 1;
    }
}
