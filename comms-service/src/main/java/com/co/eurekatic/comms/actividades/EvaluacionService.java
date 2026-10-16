package com.co.eurekatic.comms.actividades;

import com.co.eurekatic.comms.actividades.ActividadesDtos.CalificacionIn;
import com.co.eurekatic.comms.actividades.ActividadesDtos.EntregaEvaluacion;
import com.co.eurekatic.comms.actividades.ActividadesDtos.Evaluacion;
import com.co.eurekatic.comms.actividades.ActividadesDtos.EvaluacionIn;
import com.co.eurekatic.comms.actividades.ActividadesDtos.OpcionEvaluacion;
import com.co.eurekatic.comms.actividades.ActividadesDtos.OpcionEvaluacionIn;
import com.co.eurekatic.comms.actividades.ActividadesDtos.PreguntaEvaluacion;
import com.co.eurekatic.comms.actividades.ActividadesDtos.PreguntaEvaluacionIn;
import com.co.eurekatic.comms.actividades.ActividadesDtos.RespuestaEntrega;
import com.co.eurekatic.comms.actividades.ActividadesDtos.RespuestaIn;
import com.co.eurekatic.comms.chat.ApiError;
import com.co.eurekatic.comms.chat.ChatDtos.Conversacion;
import com.co.eurekatic.comms.security.Usuario;
import org.springframework.stereotype.Service;

import java.math.BigDecimal;
import java.sql.Array;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Evaluaciones en linea. Las preguntas con opciones se califican solas (la
 * multiple solo suma si marco exactamente las correctas, como
 * {@code lib/evaluacion.ts}); la redaccion la califica quien creo la
 * evaluacion. El estudiante nunca recibe las respuestas correctas y ve su nota
 * de inmediato o al cierre, segun MOSTRAR_RESULTADOS.
 */
@Service
public class EvaluacionService {

    private static final String SIN = "Este canal no tiene una evaluacion.";

    private final BaseActividades base;

    public EvaluacionService(BaseActividades base) {
        this.base = base;
    }

    public Conversacion crear(Usuario u, EvaluacionIn in) {
        base.exigirCreador(u, "EVALUACION", "evaluaciones");
        String nombre = in.nombre() == null ? "" : in.nombre().trim();
        List<PreguntaEvaluacionIn> preguntas = in.preguntas() == null ? List.of() : in.preguntas();
        if (nombre.isEmpty() || preguntas.isEmpty()) throw new ApiError(400, "Completa el nombre y agrega preguntas.");
        nombre = base.nombreValido(nombre, "el nombre de la evaluacion");
        BigDecimal suma = BigDecimal.ZERO;
        for (PreguntaEvaluacionIn p : preguntas) {
            if (p.tipo() == null || !EncuestaService.TIPOS.contains(p.tipo())) {
                throw new ApiError(400, "Tipo de pregunta desconocido.");
            }
            if (p.texto() == null || p.texto().isBlank()) throw new ApiError(400, "Escribe el texto de cada pregunta.");
            if (p.puntos() == null || p.puntos().signum() < 0) throw new ApiError(400, "Los puntos no pueden ser negativos.");
            if (!"REDACCION".equals(p.tipo())) {
                List<OpcionEvaluacionIn> ops = p.opciones() == null ? List.of() : p.opciones();
                if (ops.size() < 2) throw new ApiError(400, "Cada pregunta de opciones necesita al menos dos opciones.");
                long correctas = ops.stream().filter(o -> "S".equals(o.correcta())).count();
                if (correctas == 0) throw new ApiError(400, "Marca la respuesta correcta de cada pregunta.");
                if (!"MULTIPLE".equals(p.tipo()) && correctas > 1) {
                    throw new ApiError(400, "Las preguntas de una sola respuesta tienen una sola opcion correcta.");
                }
            }
            suma = suma.add(p.puntos());
        }
        BigDecimal total = in.puntajeTotal();
        if (total == null || total.signum() <= 0 || suma.compareTo(total) != 0) {
            throw new ApiError(400, "Las preguntas suman " + suma.stripTrailingZeros().toPlainString()
                    + " y el puntaje total es " + (total == null ? "0" : total.stripTrailingZeros().toPlainString()) + ".");
        }
        if (in.intentos() != null && in.intentos() <= 0) throw new ApiError(400, "Los intentos deben ser al menos 1.");
        if (in.tiempoLimiteMin() != null && in.tiempoLimiteMin() <= 0) throw new ApiError(400, "El tiempo limite no es valido.");
        OffsetDateTime inicio = BaseActividades.fecha(in.fechaInicio(), "inicio");
        OffsetDateTime cierre = BaseActividades.fecha(in.fechaCierre(), "cierre");
        BaseActividades.validarRango(inicio, cierre);
        Set<Long> participantes = base.filtrarPoblacion(u, in.participantes());
        if (participantes.isEmpty()) throw new ApiError(400, "Elige a los estudiantes que presentan la evaluacion.");
        String mostrar = "INMEDIATO".equals(in.mostrarResultados()) ? "INMEDIATO" : "AL_CIERRE";
        final String n = nombre;
        String descripcion = BaseActividades.recortar(in.descripcion(), 500);
        long canal = base.crearCanal(u, "EXAMEN", n, participantes, "📝 Evaluacion: " + n, false, id -> {
            base.jdbc.sql("""
                    INSERT INTO comunicaciones.tevaluacion (fk_tcanal, nombre, descripcion, fecha_inicio, fecha_cierre,
                        tiempo_limite_min, puntaje_total, intentos, mostrar_resultados)
                    VALUES (:c, :n, :d, :i, :f, :t, :p, :x, :m)""")
                    .param("c", id).param("n", n).param("d", descripcion).param("i", inicio).param("f", cierre)
                    .param("t", in.tiempoLimiteMin()).param("p", total).param("x", in.intentos()).param("m", mostrar)
                    .update();
            int orden = 0;
            for (PreguntaEvaluacionIn p : preguntas) {
                long pk = base.jdbc.sql("""
                        INSERT INTO comunicaciones.tevaluacion_pregunta (fk_tcanal, orden, tipo, texto, puntos)
                        VALUES (:c, :o, :t, :x, :p) RETURNING pk_tevaluacion_pregunta""")
                        .param("c", id).param("o", ++orden).param("t", p.tipo())
                        .param("x", BaseActividades.recortar(p.texto(), 1000)).param("p", p.puntos())
                        .query(Long.class).single();
                int oo = 0;
                for (OpcionEvaluacionIn o : "REDACCION".equals(p.tipo()) ? List.<OpcionEvaluacionIn>of() : p.opciones()) {
                    base.jdbc.sql("""
                            INSERT INTO comunicaciones.tevaluacion_opcion (fk_tevaluacion_pregunta, orden, texto, correcta)
                            VALUES (:p, :o, :t, :c)""")
                            .param("p", pk).param("o", ++oo).param("t", BaseActividades.recortar(o.texto(), 300))
                            .param("c", "S".equals(o.correcta())).update();
                }
            }
        });
        avisarAbiertas();
        return base.conversacion(canal, u);
    }

    private record Cabecera(String nombre, String descripcion, OffsetDateTime inicio, OffsetDateTime cierre,
                            Integer tiempo, BigDecimal total, Integer intentos, String mostrar, long creador) { }

    private Cabecera cabecera(Usuario u, long canal) {
        base.exigirMiembro(u, canal, SIN);
        return base.jdbc.sql("""
                SELECT e.nombre, e.descripcion, e.fecha_inicio, e.fecha_cierre, e.tiempo_limite_min, e.puntaje_total,
                       e.intentos, e.mostrar_resultados, c.creado_por
                  FROM comunicaciones.tevaluacion e JOIN comunicaciones.tcanal c ON c.pk_tcanal = e.fk_tcanal
                 WHERE e.fk_tcanal = :c""")
                .param("c", canal)
                .query((rs, n) -> new Cabecera(rs.getString(1), rs.getString(2),
                        rs.getObject(3, OffsetDateTime.class), rs.getObject(4, OffsetDateTime.class),
                        (Integer) rs.getObject(5), rs.getBigDecimal(6), (Integer) rs.getObject(7), rs.getString(8),
                        rs.getLong(9)))
                .optional().orElseThrow(() -> new ApiError(404, SIN));
    }

    private List<PreguntaEvaluacion> preguntas(long canal, boolean conCorrectas) {
        Map<Long, PreguntaEvaluacion> out = new LinkedHashMap<>();
        base.jdbc.sql("""
                SELECT p.pk_tevaluacion_pregunta, p.tipo, p.texto, p.puntos,
                       o.pk_tevaluacion_opcion, o.texto, o.correcta
                  FROM comunicaciones.tevaluacion_pregunta p
                  LEFT JOIN comunicaciones.tevaluacion_opcion o ON o.fk_tevaluacion_pregunta = p.pk_tevaluacion_pregunta
                 WHERE p.fk_tcanal = :c ORDER BY p.orden, o.orden""")
                .param("c", canal).query((rs, n) -> {
                    PreguntaEvaluacion p = out.computeIfAbsent(rs.getLong(1), id -> {
                        try {
                            return new PreguntaEvaluacion(id, rs.getString(2), rs.getString(3), rs.getBigDecimal(4),
                                    new ArrayList<>());
                        } catch (java.sql.SQLException e) {
                            throw new IllegalStateException(e);
                        }
                    });
                    long o = rs.getLong(5);
                    if (!rs.wasNull()) {
                        p.opciones().add(new OpcionEvaluacion(o, rs.getString(6), conCorrectas && rs.getBoolean(7)));
                    }
                    return 1;
                }).list();
        return new ArrayList<>(out.values());
    }

    public Evaluacion ver(Usuario u, long canal) {
        Cabecera c = cabecera(u, canal);
        if (c.creador() == u.id()) {
            return new Evaluacion(canal, c.nombre(), c.descripcion(), iso(c.inicio()), iso(c.cierre()), c.tiempo(),
                    c.total(), c.intentos(), c.mostrar(), preguntas(canal, true), base.creador(canal), true, 0, null,
                    false);
        }
        List<PreguntaEvaluacion> conCorrectas = preguntas(canal, true);
        List<EntregaEvaluacion> mias = entregas(canal, u.id());
        EntregaEvaluacion ultima = mias.isEmpty() ? null : mias.get(mias.size() - 1);
        boolean visible = "INMEDIATO".equals(c.mostrar())
                || "FINALIZADA".equals(BaseActividades.estado(c.inicio(), c.cierre(), false));
        BigDecimal nota = ultima != null && visible ? nota(conCorrectas, ultima) : null;
        return new Evaluacion(canal, c.nombre(), c.descripcion(), iso(c.inicio()), iso(c.cierre()), c.tiempo(),
                c.total(), c.intentos(), c.mostrar(), preguntas(canal, false), base.creador(canal), false, mias.size(),
                nota, ultima != null && "PENDIENTE".equals(ultima.estado()));
    }

    /** Misma nota que {@code notaEntrega} del front. */
    static BigDecimal nota(List<PreguntaEvaluacion> preguntas, EntregaEvaluacion e) {
        Map<Long, RespuestaEntrega> porPregunta = new HashMap<>();
        for (RespuestaEntrega r : e.respuestas()) porPregunta.put(r.preguntaId(), r);
        BigDecimal suma = BigDecimal.ZERO;
        for (PreguntaEvaluacion p : preguntas) {
            RespuestaEntrega r = porPregunta.get(p.id());
            if ("REDACCION".equals(p.tipo())) {
                if (r != null && r.puntos() != null) suma = suma.add(r.puntos());
            } else if (r != null) {
                Set<Long> correctas = new LinkedHashSet<>();
                for (OpcionEvaluacion o : p.opciones()) if (o.correcta()) correctas.add(o.id());
                if (correctas.equals(new LinkedHashSet<>(r.opcionIds()))) suma = suma.add(p.puntos());
            }
        }
        return suma;
    }

    /** Entregas del canal (todas o las de un usuario), en orden de envio. */
    private List<EntregaEvaluacion> entregas(long canal, Long usuario) {
        Map<Long, String[]> cab = new LinkedHashMap<>();
        Map<Long, List<RespuestaEntrega>> resp = new HashMap<>();
        base.jdbc.sql("""
                SELECT e.pk_tevaluacion_entrega, COALESCE(NULLIF(us.full_name, ''), us.email), e.estado,
                       r.fk_tevaluacion_pregunta, r.opciones, r.texto, r.puntos
                  FROM comunicaciones.tevaluacion_entrega e
                  JOIN public.users us ON us.id_user = e.fk_usuario
                  LEFT JOIN comunicaciones.tevaluacion_respuesta r ON r.fk_tevaluacion_entrega = e.pk_tevaluacion_entrega
                 WHERE e.fk_tcanal = :c AND (CAST(:u AS BIGINT) IS NULL OR e.fk_usuario = :u)
                 ORDER BY e.pk_tevaluacion_entrega, r.fk_tevaluacion_pregunta""")
                .param("c", canal).param("u", usuario).query((rs, n) -> {
                    long id = rs.getLong(1);
                    cab.putIfAbsent(id, new String[]{rs.getString(2), rs.getString(3)});
                    long p = rs.getLong(4);
                    if (!rs.wasNull()) {
                        Array a = rs.getArray(5);
                        List<Long> ops = a == null ? List.of() : List.of((Long[]) a.getArray());
                        resp.computeIfAbsent(id, k -> new ArrayList<>())
                                .add(new RespuestaEntrega(p, ops, rs.getString(6), rs.getBigDecimal(7)));
                    }
                    return 1;
                }).list();
        List<EntregaEvaluacion> out = new ArrayList<>();
        for (var e : cab.entrySet()) {
            out.add(new EntregaEvaluacion(e.getKey(), e.getValue()[0], e.getValue()[1],
                    resp.getOrDefault(e.getKey(), List.of())));
        }
        return out;
    }

    public List<EntregaEvaluacion> entregasDelCanal(Usuario u, long canal) {
        Cabecera c = cabecera(u, canal);
        if (c.creador() != u.id()) throw new ApiError(403, "Solo quien creo la evaluacion ve las entregas.");
        return entregas(canal, null);
    }

    public Evaluacion entregar(Usuario u, long canal, List<RespuestaIn> respuestas) {
        Cabecera c = cabecera(u, canal);
        if (c.creador() == u.id()) throw new ApiError(403, "Quien crea la evaluacion no la presenta.");
        if (!"ACTIVA".equals(BaseActividades.estado(c.inicio(), c.cierre(), false))) {
            throw new ApiError(409, "La evaluacion no esta abierta.");
        }
        List<PreguntaEvaluacion> preguntas = preguntas(canal, true);
        Map<Long, PreguntaEvaluacion> porId = new HashMap<>();
        for (PreguntaEvaluacion p : preguntas) porId.put(p.id(), p);
        List<Object[]> filas = new ArrayList<>();
        Set<Long> vistas = new LinkedHashSet<>();
        for (RespuestaIn r : respuestas == null ? List.<RespuestaIn>of() : respuestas) {
            PreguntaEvaluacion p = r.pregunta() == null ? null : porId.get(r.pregunta());
            if (p == null) throw new ApiError(400, "La pregunta no pertenece a esta evaluacion.");
            if (!vistas.add(p.id())) continue;
            Set<Long> elegidas = new LinkedHashSet<>(r.opciones() == null ? List.of() : r.opciones());
            Set<Long> validas = new LinkedHashSet<>();
            for (OpcionEvaluacion o : p.opciones()) validas.add(o.id());
            if (!validas.containsAll(elegidas)) throw new ApiError(400, "La opcion no pertenece a la pregunta.");
            boolean redaccion = "REDACCION".equals(p.tipo());
            filas.add(new Object[]{p.id(), redaccion ? "{}" : BaseActividades.arreglo(elegidas),
                    redaccion ? BaseActividades.recortar(r.texto(), 4000) : null});
        }
        boolean conRedaccion = preguntas.stream().anyMatch(p -> "REDACCION".equals(p.tipo()));
        base.tx.executeWithoutResult(s -> {
            base.chat.contextoAuditoria(u.sub());
            // Bloqueo por usuario: dos envios simultaneos no se saltan el limite de intentos.
            base.jdbc.sql("SELECT pg_advisory_xact_lock(:c, :u)").param("c", (int) canal).param("u", u.id().intValue())
                    .query((rs, n) -> 1).list();
            int usados = base.jdbc.sql("""
                    SELECT COUNT(*) FROM comunicaciones.tevaluacion_entrega WHERE fk_tcanal = :c AND fk_usuario = :u""")
                    .param("c", canal).param("u", u.id()).query(Integer.class).single();
            if (c.intentos() != null && usados >= c.intentos()) throw new ApiError(409, "Ya usaste todos tus intentos.");
            long entrega = base.jdbc.sql("""
                    INSERT INTO comunicaciones.tevaluacion_entrega (fk_tcanal, fk_usuario, estado)
                    VALUES (:c, :u, :e) RETURNING pk_tevaluacion_entrega""")
                    .param("c", canal).param("u", u.id()).param("e", conRedaccion ? "PENDIENTE" : "CALIFICADA")
                    .query(Long.class).single();
            for (Object[] f : filas) {
                base.jdbc.sql("""
                        INSERT INTO comunicaciones.tevaluacion_respuesta
                            (fk_tevaluacion_entrega, fk_tevaluacion_pregunta, opciones, texto)
                        VALUES (:e, :p, CAST(:o AS BIGINT[]), :t)""")
                        .param("e", entrega).param("p", f[0]).param("o", f[1]).param("t", f[2]).update();
            }
        });
        return ver(u, canal);
    }

    public EntregaEvaluacion calificar(Usuario u, long entrega, List<CalificacionIn> calificaciones) {
        Long canal = base.jdbc.sql("SELECT fk_tcanal FROM comunicaciones.tevaluacion_entrega WHERE pk_tevaluacion_entrega = :e")
                .param("e", entrega).query(Long.class).optional()
                .orElseThrow(() -> new ApiError(404, "La entrega no existe."));
        Cabecera c = cabecera(u, canal);
        if (c.creador() != u.id()) throw new ApiError(403, "Solo quien creo la evaluacion puede calificarla.");
        Map<Long, PreguntaEvaluacion> porId = new HashMap<>();
        for (PreguntaEvaluacion p : preguntas(canal, true)) porId.put(p.id(), p);
        base.tx.executeWithoutResult(s -> {
            base.chat.contextoAuditoria(u.sub());
            for (CalificacionIn k : calificaciones == null ? List.<CalificacionIn>of() : calificaciones) {
                PreguntaEvaluacion p = k.pregunta() == null ? null : porId.get(k.pregunta());
                if (p == null || !"REDACCION".equals(p.tipo())) {
                    throw new ApiError(400, "Solo se califican a mano las preguntas de redaccion.");
                }
                if (k.puntos() == null || k.puntos().signum() < 0 || k.puntos().compareTo(p.puntos()) > 0) {
                    throw new ApiError(400, "Los puntos deben estar entre 0 y " + p.puntos().stripTrailingZeros().toPlainString() + ".");
                }
                base.jdbc.sql("""
                        INSERT INTO comunicaciones.tevaluacion_respuesta
                            (fk_tevaluacion_entrega, fk_tevaluacion_pregunta, puntos) VALUES (:e, :p, :x)
                        ON CONFLICT (fk_tevaluacion_entrega, fk_tevaluacion_pregunta) DO UPDATE SET puntos = :x""")
                        .param("e", entrega).param("p", p.id()).param("x", k.puntos()).update();
            }
            base.jdbc.sql("""
                    UPDATE comunicaciones.tevaluacion_entrega
                       SET estado = 'CALIFICADA', calificada_por = :u, calificada_en = NOW()
                     WHERE pk_tevaluacion_entrega = :e""").param("u", u.id()).param("e", entrega).update();
        });
        return entregas(canal, null).stream().filter(x -> x.id() == entrega).findFirst()
                .orElseThrow(() -> new ApiError(404, "La entrega no existe."));
    }

    /** Evaluaciones que abrieron sin aviso: CHAT_EVALUACION a quienes la presentan. */
    public void avisarAbiertas() {
        base.tx.executeWithoutResult(s -> {
            var abiertas = base.jdbc.sql("""
                    UPDATE comunicaciones.tevaluacion SET notificado_en = NOW()
                     WHERE notificado_en IS NULL AND (fecha_inicio IS NULL OR fecha_inicio <= NOW())
                       AND (fecha_cierre IS NULL OR fecha_cierre > NOW())
                    RETURNING fk_tcanal, nombre""")
                    .query((rs, n) -> Map.entry(rs.getLong(1), rs.getString(2))).list();
            for (var e : abiertas) {
                base.avisar("CHAT_EVALUACION", base.destinatarios(e.getKey()), "Evaluacion abierta: " + e.getValue(),
                        "Entra al canal para presentarla.", e.getKey(), "evaluacion:" + e.getKey(),
                        base.creador(e.getKey()));
            }
        });
    }

    private static String iso(OffsetDateTime f) {
        return f == null ? null : f.toInstant().toString();
    }
}
