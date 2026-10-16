package com.co.eurekatic.notificationservice.preferencias;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.sql.Array;
import java.sql.SQLException;
import java.time.LocalTime;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.stream.Collectors;

@Repository
public class PreferenciasRepository {

    public record Excepcion(String tipo, Boolean push, Boolean email, OffsetDateTime silenciadoHasta) { }

    public record Horario(boolean activo, LocalTime desde, LocalTime hasta, List<Integer> dias, String zona) { }

    private final JdbcClient jdbc;

    public PreferenciasRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    public Map<String, Excepcion> excepciones(String usuario) {
        return jdbc.sql("""
                SELECT tipo, push, email, silenciado_hasta
                  FROM notificacion_preferencia WHERE usuario = :usuario""")
                .param("usuario", usuario)
                .query((rs, n) -> new Excepcion(
                        rs.getString("tipo"),
                        (Boolean) rs.getObject("push"),
                        (Boolean) rs.getObject("email"),
                        rs.getObject("silenciado_hasta", OffsetDateTime.class)))
                .list().stream().collect(Collectors.toMap(Excepcion::tipo, e -> e));
    }

    public Optional<Excepcion> excepcion(String usuario, String tipo) {
        return jdbc.sql("""
                SELECT tipo, push, email, silenciado_hasta
                  FROM notificacion_preferencia WHERE usuario = :usuario AND tipo = :tipo""")
                .param("usuario", usuario).param("tipo", tipo)
                .query((rs, n) -> new Excepcion(
                        rs.getString("tipo"),
                        (Boolean) rs.getObject("push"),
                        (Boolean) rs.getObject("email"),
                        rs.getObject("silenciado_hasta", OffsetDateTime.class)))
                .optional();
    }

    /** {@code push}/{@code email} null = igual al defecto; si todo queda null la fila se borra (D-3.2). */
    public void guardarExcepcion(String usuario, String tipo, Boolean push, Boolean email) {
        jdbc.sql("""
                INSERT INTO notificacion_preferencia (usuario, tipo, push, email)
                VALUES (:usuario, :tipo, :push, :email)
                ON CONFLICT (usuario, tipo) DO UPDATE
                   SET push = EXCLUDED.push, email = EXCLUDED.email, actualizada_en = NOW()""")
                .param("usuario", usuario).param("tipo", tipo).param("push", push).param("email", email)
                .update();
        jdbc.sql("""
                DELETE FROM notificacion_preferencia
                 WHERE usuario = :usuario AND tipo = :tipo
                   AND push IS NULL AND email IS NULL AND silenciado_hasta IS NULL""")
                .param("usuario", usuario).param("tipo", tipo).update();
    }

    public Optional<Horario> horario(String usuario) {
        return jdbc.sql("""
                SELECT activo, desde, hasta, dias, zona
                  FROM notificacion_horario_silencioso WHERE usuario = :usuario""")
                .param("usuario", usuario)
                .query((rs, n) -> new Horario(
                        rs.getBoolean("activo"),
                        rs.getObject("desde", LocalTime.class),
                        rs.getObject("hasta", LocalTime.class),
                        dias(rs.getArray("dias")),
                        rs.getString("zona")))
                .optional();
    }

    public void guardarHorario(String usuario, Horario h) {
        String dias = h.dias().stream().map(String::valueOf).collect(Collectors.joining(",", "{", "}"));
        jdbc.sql("""
                INSERT INTO notificacion_horario_silencioso (usuario, activo, desde, hasta, dias, zona)
                VALUES (:usuario, :activo, :desde, :hasta, CAST(:dias AS SMALLINT[]), :zona)
                ON CONFLICT (usuario) DO UPDATE
                   SET activo = EXCLUDED.activo, desde = EXCLUDED.desde, hasta = EXCLUDED.hasta,
                       dias = EXCLUDED.dias, zona = EXCLUDED.zona, actualizada_en = NOW()""")
                .param("usuario", usuario).param("activo", h.activo()).param("desde", h.desde())
                .param("hasta", h.hasta()).param("dias", dias).param("zona", h.zona())
                .update();
    }

    private static List<Integer> dias(Array array) throws SQLException {
        List<Integer> out = new ArrayList<>();
        if (array == null) return out;
        for (Object o : (Object[]) array.getArray()) {
            if (o instanceof Number n) out.add(n.intValue());
        }
        return out;
    }
}
