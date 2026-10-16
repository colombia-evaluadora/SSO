package com.co.eurekatic.notificationservice.push;

import com.fasterxml.jackson.annotation.JsonProperty;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.OffsetDateTime;
import java.util.List;

@Repository
public class PushSuscripcionRepository {

    /** Fila publica ({@code PushSuscripcionRow} del front): sin las claves de cifrado. */
    public record SuscripcionRow(
            @JsonProperty("id") long id,
            @JsonProperty("endpoint") String endpoint,
            @JsonProperty("user_agent") String userAgent,
            @JsonProperty("plataforma") String plataforma,
            @JsonProperty("creada_en") String creadaEn,
            @JsonProperty("ultimo_uso") String ultimoUso) { }

    /** Lo necesario para enviar. */
    public record Destino(long id, String endpoint, String p256dh, String auth) { }

    private static final String PUBLICAS = "id, endpoint, user_agent, plataforma, creada_en, ultimo_uso";

    private final JdbcClient jdbc;

    public PushSuscripcionRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    public List<SuscripcionRow> listar(String usuario) {
        return jdbc.sql("SELECT " + PUBLICAS + " FROM push_suscripcion"
                        + " WHERE usuario = :usuario AND invalida_en IS NULL ORDER BY creada_en DESC")
                .param("usuario", usuario).query((rs, n) -> fila(rs)).list();
    }

    /** Alta o reasignacion por endpoint (D-4.4): el navegador ahora es de este usuario. */
    public SuscripcionRow guardar(String usuario, String endpoint, String p256dh, String auth,
                                  String userAgent, String plataforma) {
        return jdbc.sql("""
                INSERT INTO push_suscripcion (usuario, endpoint, p256dh, auth, user_agent, plataforma)
                VALUES (:usuario, :endpoint, :p256dh, :auth, :ua, :plataforma)
                ON CONFLICT (endpoint) DO UPDATE
                   SET usuario = EXCLUDED.usuario, p256dh = EXCLUDED.p256dh, auth = EXCLUDED.auth,
                       user_agent = EXCLUDED.user_agent, plataforma = EXCLUDED.plataforma,
                       creada_en = CASE WHEN push_suscripcion.usuario = EXCLUDED.usuario
                                        THEN push_suscripcion.creada_en ELSE NOW() END,
                       invalida_en = NULL
                RETURNING """ + " " + PUBLICAS)
                .param("usuario", usuario).param("endpoint", endpoint).param("p256dh", p256dh)
                .param("auth", auth).param("ua", userAgent).param("plataforma", plataforma)
                .query((rs, n) -> fila(rs)).single();
    }

    public boolean borrarPorEndpoint(String usuario, String endpoint) {
        return jdbc.sql("DELETE FROM push_suscripcion WHERE usuario = :usuario AND endpoint = :endpoint")
                .param("usuario", usuario).param("endpoint", endpoint).update() > 0;
    }

    public boolean borrar(String usuario, long id) {
        return jdbc.sql("DELETE FROM push_suscripcion WHERE usuario = :usuario AND id = :id")
                .param("usuario", usuario).param("id", id).update() > 0;
    }

    public List<Destino> destinos(String usuario) {
        return jdbc.sql("""
                SELECT id, endpoint, p256dh, auth FROM push_suscripcion
                 WHERE usuario = :usuario AND invalida_en IS NULL""")
                .param("usuario", usuario)
                .query((rs, n) -> new Destino(rs.getLong("id"), rs.getString("endpoint"),
                        rs.getString("p256dh"), rs.getString("auth")))
                .list();
    }

    public void marcarUso(long id) {
        jdbc.sql("UPDATE push_suscripcion SET ultimo_uso = NOW() WHERE id = :id").param("id", id).update();
    }

    /** 404/410 del push service: nunca se reintenta (D-4.3). */
    public void invalidar(long id) {
        jdbc.sql("UPDATE push_suscripcion SET invalida_en = NOW() WHERE id = :id AND invalida_en IS NULL")
                .param("id", id).update();
    }

    private static SuscripcionRow fila(ResultSet rs) throws SQLException {
        return new SuscripcionRow(rs.getLong("id"), rs.getString("endpoint"), rs.getString("user_agent"),
                rs.getString("plataforma"), iso(rs.getObject("creada_en", OffsetDateTime.class)),
                iso(rs.getObject("ultimo_uso", OffsetDateTime.class)));
    }

    private static String iso(OffsetDateTime t) {
        return t == null ? null : t.toInstant().toString();
    }
}
