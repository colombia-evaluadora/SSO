package com.co.eurekatic.comms.actividades;

import com.co.eurekatic.comms.actividades.ActividadesDtos.Encuesta;
import com.co.eurekatic.comms.actividades.ActividadesDtos.EncuestaIn;
import com.co.eurekatic.comms.actividades.ActividadesDtos.OpcionEncuesta;
import com.co.eurekatic.comms.actividades.ActividadesDtos.PreguntaEncuesta;
import com.co.eurekatic.comms.actividades.ActividadesDtos.PreguntaEncuestaIn;
import com.co.eurekatic.comms.actividades.ActividadesDtos.RespuestaIn;
import com.co.eurekatic.comms.chat.ApiError;
import com.co.eurekatic.comms.chat.ChatDtos.Conversacion;
import com.co.eurekatic.comms.security.Usuario;
import org.springframework.stereotype.Service;

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Encuestas: preguntas de opcion unica, multiple, si/no y redaccion. Se
 * responde una sola vez (tencuesta_participante) y las respuestas se guardan
 * sin usuario (anonimas). Con resultados ADMIN solo el creador ve conteos.
 */
@Service
public class EncuestaService {

    static final Set<String> TIPOS = Set.of("MULTIPLE", "UNICA", "REDACCION", "SI_NO");
    static final List<String> SI_NO = List.of("Sí", "No");
    private static final String SIN = "Este canal no tiene una encuesta.";
    private static final int MAX_REDACCIONES = 50;

    private final BaseActividades base;

    public EncuestaService(BaseActividades base) {
        this.base = base;
    }

    public Conversacion crear(Usuario u, EncuestaIn in) {
        base.exigirCreador(u, "ENCUESTA", "encuestas");
        String nombre = base.nombreValido(in.nombre(), "el nombre de la encuesta");
        List<PreguntaEncuestaIn> preguntas = in.preguntas() == null ? List.of() : in.preguntas();
        if (preguntas.isEmpty()) throw new ApiError(400, "Agrega al menos una pregunta.");
        for (PreguntaEncuestaIn p : preguntas) {
            if (p.tipo() == null || !TIPOS.contains(p.tipo())) throw new ApiError(400, "Tipo de pregunta desconocido.");
            if (p.texto() == null || p.texto().isBlank()) throw new ApiError(400, "Escribe el texto de cada pregunta.");
            if (("MULTIPLE".equals(p.tipo()) || "UNICA".equals(p.tipo()))
                    && (p.opciones() == null || p.opciones().stream().filter(o -> o != null && !o.isBlank()).count() < 2)) {
                throw new ApiError(400, "Cada pregunta de opciones necesita al menos dos opciones.");
            }
        }
        String resultados = "ADMIN".equals(in.resultados()) ? "ADMIN" : "PUBLICOS";
        OffsetDateTime inicio = BaseActividades.fecha(in.fechaInicio(), "inicio");
        OffsetDateTime cierre = BaseActividades.fecha(in.fechaCierre(), "cierre");
        BaseActividades.validarRango(inicio, cierre);
        Set<Long> participantes = base.filtrarPoblacion(u, in.participantes());
        if (participantes.isEmpty()) throw new ApiError(400, "Elige a las personas que responden la encuesta.");
        String descripcion = BaseActividades.recortar(in.descripcion(), 500);
        long canal = base.crearCanal(u, "ENCUESTA", nombre, participantes, "📊 Encuesta: " + nombre, false, id -> {
            base.jdbc.sql("""
                    INSERT INTO comunicaciones.tencuesta (fk_tcanal, nombre, descripcion, fecha_inicio, fecha_cierre, resultados)
                    VALUES (:c, :n, :d, :i, :f, :r)""")
                    .param("c", id).param("n", nombre).param("d", descripcion).param("i", inicio).param("f", cierre)
                    .param("r", resultados).update();
            int orden = 0;
            for (PreguntaEncuestaIn p : preguntas) {
                long pk = base.jdbc.sql("""
                        INSERT INTO comunicaciones.tencuesta_pregunta (fk_tcanal, orden, tipo, texto)
                        VALUES (:c, :o, :t, :x) RETURNING pk_tencuesta_pregunta""")
                        .param("c", id).param("o", ++orden).param("t", p.tipo())
                        .param("x", BaseActividades.recortar(p.texto(), 500)).query(Long.class).single();
                List<String> opciones = switch (p.tipo()) {
                    case "SI_NO" -> SI_NO;
                    case "REDACCION" -> List.of();
                    default -> p.opciones().stream().filter(o -> o != null && !o.isBlank()).toList();
                };
                int oo = 0;
                for (String o : opciones) {
                    base.jdbc.sql("""
                            INSERT INTO comunicaciones.tencuesta_opcion (fk_tencuesta_pregunta, orden, texto)
                            VALUES (:p, :o, :t)""")
                            .param("p", pk).param("o", ++oo).param("t", BaseActividades.recortar(o, 200)).update();
                }
            }
        });
        avisarAbiertas();
        return base.conversacion(canal, u);
    }

    private record Cabecera(String nombre, String descripcion, OffsetDateTime inicio, OffsetDateTime cierre,
                            String resultados, long creador) { }

    private Cabecera cabecera(long canal) {
        return base.jdbc.sql("""
                SELECT e.nombre, e.descripcion, e.fecha_inicio, e.fecha_cierre, e.resultados, c.creado_por
                  FROM comunicaciones.tencuesta e JOIN comunicaciones.tcanal c ON c.pk_tcanal = e.fk_tcanal
                 WHERE e.fk_tcanal = :c""")
                .param("c", canal)
                .query((rs, n) -> new Cabecera(rs.getString(1), rs.getString(2),
                        rs.getObject(3, OffsetDateTime.class), rs.getObject(4, OffsetDateTime.class),
                        rs.getString(5), rs.getLong(6)))
                .optional().orElseThrow(() -> new ApiError(404, SIN));
    }

    public Encuesta ver(Usuario u, long canal) {
        base.exigirMiembro(u, canal, SIN);
        Cabecera c = cabecera(canal);
        boolean esCreador = c.creador() == u.id();
        boolean conResultados = esCreador || "PUBLICOS".equals(c.resultados());
        List<PreguntaEncuesta> preguntas = new ArrayList<>();
        var filas = base.jdbc.sql("""
                SELECT p.pk_tencuesta_pregunta, p.tipo, p.texto,
                       (SELECT COUNT(*) FROM comunicaciones.tencuesta_respuesta r
                         WHERE r.fk_tencuesta_pregunta = p.pk_tencuesta_pregunta) AS total
                  FROM comunicaciones.tencuesta_pregunta p WHERE p.fk_tcanal = :c ORDER BY p.orden""")
                .param("c", canal)
                .query((rs, n) -> new Object[]{rs.getLong(1), rs.getString(2), rs.getString(3), rs.getInt(4)}).list();
        for (Object[] f : filas) {
            long pk = (Long) f[0];
            List<OpcionEncuesta> opciones = base.jdbc.sql("""
                    SELECT o.pk_tencuesta_opcion, o.texto,
                           (SELECT COUNT(*) FROM comunicaciones.tencuesta_respuesta r
                             WHERE r.fk_tencuesta_pregunta = o.fk_tencuesta_pregunta
                               AND o.pk_tencuesta_opcion = ANY (r.opciones))
                      FROM comunicaciones.tencuesta_opcion o WHERE o.fk_tencuesta_pregunta = :p ORDER BY o.orden""")
                    .param("p", pk)
                    .query((rs, n) -> new OpcionEncuesta(rs.getLong(1), rs.getString(2),
                            conResultados ? rs.getInt(3) : 0)).list();
            List<String> textos = !conResultados || !"REDACCION".equals(f[1]) ? List.of() : base.jdbc.sql("""
                    SELECT texto FROM comunicaciones.tencuesta_respuesta
                     WHERE fk_tencuesta_pregunta = :p AND texto IS NOT NULL
                     ORDER BY pk_tencuesta_respuesta DESC LIMIT :lim""")
                    .param("p", pk).param("lim", MAX_REDACCIONES).query(String.class).list();
            preguntas.add(new PreguntaEncuesta(pk, (String) f[1], (String) f[2], opciones,
                    conResultados ? (Integer) f[3] : 0, textos));
        }
        int participantes = base.jdbc.sql("SELECT COUNT(*) FROM comunicaciones.tencuesta_participante WHERE fk_tcanal = :c")
                .param("c", canal).query(Integer.class).single();
        boolean yaRespondi = base.jdbc.sql("""
                SELECT EXISTS (SELECT 1 FROM comunicaciones.tencuesta_participante WHERE fk_tcanal = :c AND fk_usuario = :u)""")
                .param("c", canal).param("u", u.id()).query(Boolean.class).single();
        return new Encuesta(canal, c.nombre(), c.descripcion(), iso(c.inicio()), iso(c.cierre()), c.resultados(),
                preguntas, base.destinatarios(canal).size(), participantes, base.creador(canal), esCreador, yaRespondi);
    }

    public Encuesta responder(Usuario u, long canal, List<RespuestaIn> respuestas) {
        base.exigirMiembro(u, canal, SIN);
        Cabecera c = cabecera(canal);
        if (c.creador() == u.id()) throw new ApiError(403, "Quien crea la encuesta no la responde.");
        if (!"ACTIVA".equals(BaseActividades.estado(c.inicio(), c.cierre(), false))) {
            throw new ApiError(409, "La encuesta no esta abierta.");
        }
        // Preguntas y opciones validas de esta encuesta.
        Map<Long, String> tipos = new HashMap<>();
        Map<Long, Set<Long>> opcionesDe = new HashMap<>();
        base.jdbc.sql("""
                SELECT p.pk_tencuesta_pregunta, p.tipo, o.pk_tencuesta_opcion
                  FROM comunicaciones.tencuesta_pregunta p
                  LEFT JOIN comunicaciones.tencuesta_opcion o ON o.fk_tencuesta_pregunta = p.pk_tencuesta_pregunta
                 WHERE p.fk_tcanal = :c""")
                .param("c", canal).query((rs, n) -> {
                    long p = rs.getLong(1);
                    tipos.put(p, rs.getString(2));
                    long o = rs.getLong(3);
                    if (!rs.wasNull()) opcionesDe.computeIfAbsent(p, k -> new LinkedHashSet<>()).add(o);
                    return 1;
                }).list();
        List<Object[]> validas = new ArrayList<>();
        for (RespuestaIn r : respuestas == null ? List.<RespuestaIn>of() : respuestas) {
            String tipo = r.pregunta() == null ? null : tipos.get(r.pregunta());
            if (tipo == null) throw new ApiError(400, "La pregunta no pertenece a esta encuesta.");
            if ("REDACCION".equals(tipo)) {
                String t = BaseActividades.recortar(r.texto(), 2000);
                if (!t.isEmpty()) validas.add(new Object[]{r.pregunta(), "{}", t});
                continue;
            }
            Set<Long> elegidas = new LinkedHashSet<>(r.opciones() == null ? List.of() : r.opciones());
            if (elegidas.isEmpty()) continue;
            if (!opcionesDe.getOrDefault(r.pregunta(), Set.of()).containsAll(elegidas)) {
                throw new ApiError(400, "La opcion no pertenece a la pregunta.");
            }
            if (!"MULTIPLE".equals(tipo) && elegidas.size() > 1) {
                throw new ApiError(400, "Esta pregunta admite una sola opcion.");
            }
            validas.add(new Object[]{r.pregunta(), BaseActividades.arreglo(elegidas), null});
        }
        if (validas.isEmpty()) throw new ApiError(400, "Responde al menos una pregunta.");
        boolean ok = Boolean.TRUE.equals(base.tx.execute(s -> {
            base.chat.contextoAuditoria(u.sub());
            int n = base.jdbc.sql("""
                    INSERT INTO comunicaciones.tencuesta_participante (fk_tcanal, fk_usuario) VALUES (:c, :u)
                    ON CONFLICT DO NOTHING""").param("c", canal).param("u", u.id()).update();
            if (n == 0) return false;
            for (Object[] v : validas) {
                base.jdbc.sql("""
                        INSERT INTO comunicaciones.tencuesta_respuesta (fk_tencuesta_pregunta, opciones, texto)
                        VALUES (:p, CAST(:o AS BIGINT[]), :t)""")
                        .param("p", v[0]).param("o", v[1]).param("t", v[2]).update();
            }
            return true;
        }));
        if (!ok) throw new ApiError(409, "Ya respondiste esta encuesta.");
        return ver(u, canal);
    }

    /** Encuestas que abrieron y no se han avisado: CHAT_ENCUESTA a quienes faltan por responder. */
    public void avisarAbiertas() {
        base.tx.executeWithoutResult(s -> {
            var abiertas = base.jdbc.sql("""
                    UPDATE comunicaciones.tencuesta SET notificado_en = NOW()
                     WHERE notificado_en IS NULL AND (fecha_inicio IS NULL OR fecha_inicio <= NOW())
                       AND (fecha_cierre IS NULL OR fecha_cierre > NOW())
                    RETURNING fk_tcanal, nombre""")
                    .query((rs, n) -> Map.entry(rs.getLong(1), rs.getString(2))).list();
            for (var e : abiertas) {
                List<Long> faltan = base.jdbc.sql("""
                        SELECT m.fk_usuario FROM comunicaciones.tcanal_miembro m
                          JOIN comunicaciones.tcanal c ON c.pk_tcanal = m.fk_tcanal
                         WHERE m.fk_tcanal = :c AND m.salio_en IS NULL AND m.fk_usuario <> c.creado_por
                           AND NOT EXISTS (SELECT 1 FROM comunicaciones.tencuesta_participante p
                                            WHERE p.fk_tcanal = :c AND p.fk_usuario = m.fk_usuario)""")
                        .param("c", e.getKey()).query(Long.class).list();
                base.avisar("CHAT_ENCUESTA", faltan, "Encuesta abierta: " + e.getValue(),
                        "Entra al canal para responderla.", e.getKey(), "encuesta:" + e.getKey(),
                        base.creador(e.getKey()));
            }
        });
    }

    private static String iso(OffsetDateTime f) {
        return f == null ? null : f.toInstant().toString();
    }
}
