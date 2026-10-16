package com.co.eurekatic.comms.actividades;

import com.co.eurekatic.comms.chat.ApiError;
import com.co.eurekatic.comms.chat.ChatDtos.Conversacion;
import com.co.eurekatic.comms.chat.ChatRepository;
import com.co.eurekatic.comms.chat.ChatRepository.Membresia;
import com.co.eurekatic.comms.chat.NotificadorChat;
import com.co.eurekatic.comms.chat.PoliticaChat;
import com.co.eurekatic.comms.realtime.RealtimeBus;
import com.co.eurekatic.comms.security.Usuario;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionTemplate;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.LongConsumer;

/**
 * Piezas comunes de las cuatro actividades: quien puede crearlas (matriz de
 * {@link ActividadesProperties}), a quien pueden llegar (la poblacion del
 * establecimiento, {@link DirectorioEscolar}), el alta del canal 1:1 con sus
 * miembros y los avisos al outbox.
 */
@Component
public class BaseActividades {

    static final ZoneId BOGOTA = ZoneId.of("America/Bogota");

    final ChatRepository chat;
    final DirectorioEscolar directorio;
    final PoliticaChat politica;
    final ActividadesProperties props;
    final NotificadorChat notificador;
    final RealtimeBus bus;
    final TransactionTemplate tx;
    final JdbcClient jdbc;

    public BaseActividades(ChatRepository chat, DirectorioEscolar directorio, PoliticaChat politica,
                           ActividadesProperties props, NotificadorChat notificador, RealtimeBus bus,
                           TransactionTemplate tx, JdbcClient jdbc) {
        this.chat = chat;
        this.directorio = directorio;
        this.politica = politica;
        this.props = props;
        this.notificador = notificador;
        this.bus = bus;
        this.tx = tx;
        this.jdbc = jdbc;
    }

    /** 403 si el perfil del usuario no crea esta actividad. Estudiantes y acudientes nunca. */
    void exigirCreador(Usuario u, String actividad, String nombreVisible) {
        String perfil = politica.perfil(u.roles());
        boolean menorOAcudiente = "ESTUDIANTE".equals(perfil) || "ACUDIENTE".equals(perfil);
        if (menorOAcudiente || !props.crean().getOrDefault(actividad, List.of()).contains(perfil)) {
            throw new ApiError(403, "Tu perfil no puede crear " + nombreVisible + ".");
        }
    }

    long establecimiento(Usuario u) {
        return directorio.establecimiento(u.id()).orElseThrow(() ->
                new ApiError(409, "No encontramos tu establecimiento educativo para elegir a los participantes."));
    }

    /** Solo ids de la poblacion del establecimiento (y sin el creador). */
    Set<Long> filtrarPoblacion(Usuario u, Collection<Long> ids) {
        Set<Long> out = new LinkedHashSet<>();
        if (ids == null || ids.isEmpty()) return out;
        Set<Long> poblacion = directorio.poblacion(establecimiento(u)).keySet();
        for (Long id : ids) {
            if (id == null || id.equals(u.id())) continue;
            if (!poblacion.contains(id)) throw new ApiError(400, "Hay participantes que no pertenecen a tu institucion.");
            out.add(id);
        }
        return out;
    }

    String nombreValido(String nombre, String campo) {
        String n = nombre == null ? "" : nombre.trim();
        if (n.isEmpty()) throw new ApiError(400, "Escribe " + campo + ".");
        if (n.length() > 100) throw new ApiError(400, "El nombre es demasiado largo (maximo 100 caracteres).");
        return n;
    }

    static String recortar(String s, int max) {
        String t = s == null ? "" : s.trim();
        return t.length() > max ? t.substring(0, max) : t;
    }

    /**
     * Crea el canal (categoria de la actividad), con el creador como ADMIN y los
     * miembros indicados; dentro de la misma transaccion corre {@code detalle}
     * (las filas propias de la actividad) y deja un mensaje de apertura.
     */
    long crearCanal(Usuario u, String categoria, String nombre, Collection<Long> miembros, String apertura,
                    boolean fijarApertura, LongConsumer detalle) {
        if (chat.existeNombre(nombre, u.establecimiento(), null)) {
            throw new ApiError(409, "Ya existe un canal llamado " + nombre + ".");
        }
        long canal = tx.execute(s -> {
            chat.contextoAuditoria(u.sub());
            long id = chat.crearCanal("CANAL", categoria, nombre, u.establecimiento(), null, u.id());
            chat.agregarMiembro(id, u.id(), "ADMIN");
            // ultimo_leido_msg = 0 para todos: el mensaje de apertura cuenta como no leido
            // y sirve de base para "vieron el canal" / confirmacion de lectura.
            for (Long m : miembros) chat.agregarMiembro(id, m, "MIEMBRO");
            detalle.accept(id);
            long msg = chat.insertarMensaje(id, u.id(), "NORMAL", apertura, null, null, null, null);
            if (fijarApertura) chat.fijar(msg, true);
            chat.actualizarMiembro(id, u.id(), "ultimo_leido_msg = :m", Map.of("m", msg));
            return id;
        });
        refrescarListas(canal, miembros);
        return canal;
    }

    /** La lista de conversaciones de los miembros conectados se actualiza en vivo. */
    void refrescarListas(long canal, Collection<Long> miembros) {
        if (miembros.isEmpty()) return;
        Map<Long, String> correos = chat.correos(miembros);
        for (Long m : miembros) {
            String sub = correos.get(m);
            if (sub == null) continue;
            chat.conversacion(canal, m).ifPresent(c ->
                    bus.publicar("user:" + Usuario.normalizar(sub), "conversacion.actualizada", c));
        }
    }

    Conversacion conversacion(long canal, Usuario u) {
        return chat.conversacion(canal, u.id()).orElseThrow(() -> new ApiError(404, "La conversacion no existe."));
    }

    Membresia exigirMiembro(Usuario u, long canal, String sinActividad) {
        Membresia m = chat.membresia(canal, u.id()).orElseThrow(() -> new ApiError(404, sinActividad));
        if (m.bloqueado()) throw new ApiError(403, "Te bloquearon en este canal.");
        return m;
    }

    /** Miembros activos del canal sin el creador: los destinatarios de la actividad. */
    List<Long> destinatarios(long canal) {
        return jdbc.sql("""
                SELECT m.fk_usuario FROM comunicaciones.tcanal_miembro m
                  JOIN comunicaciones.tcanal c ON c.pk_tcanal = m.fk_tcanal
                 WHERE m.fk_tcanal = :c AND m.salio_en IS NULL AND m.fk_usuario <> c.creado_por""")
                .param("c", canal).query(Long.class).list();
    }

    /** Destinatarios que ya abrieron el canal (leyeron el mensaje de apertura). */
    int vieron(long canal) {
        return jdbc.sql("""
                SELECT COUNT(*) FROM comunicaciones.tcanal_miembro m
                  JOIN comunicaciones.tcanal c ON c.pk_tcanal = m.fk_tcanal
                 WHERE m.fk_tcanal = :c AND m.salio_en IS NULL AND m.fk_usuario <> c.creado_por
                   AND m.ultimo_leido_msg >= COALESCE((SELECT MIN(pk_tmensaje) FROM comunicaciones.tmensaje
                                                        WHERE fk_tcanal = :c), 0)
                   AND m.ultimo_leido_msg > 0""")
                .param("c", canal).query(Integer.class).single();
    }

    String creador(long canal) {
        return jdbc.sql("""
                SELECT COALESCE(NULLIF(u.full_name, ''), u.email) FROM comunicaciones.tcanal c
                  JOIN public.users u ON u.id_user = c.creado_por WHERE c.pk_tcanal = :c""")
                .param("c", canal).query(String.class).optional().orElse("");
    }

    void avisar(String tipo, Collection<Long> usuarios, String titulo, String cuerpo, long canal, String dedupe,
                String actor) {
        if (usuarios.isEmpty()) return;
        List<String> correos = new ArrayList<>(chat.correos(usuarios).values());
        notificador.enviar(tipo, correos, titulo, cuerpo, "/app/comunicaciones/chat?canal=" + canal,
                Map.of("canal", canal), dedupe, null, actor);
    }

    /** Literal de arreglo de Postgres ({@code CAST(:x AS BIGINT[])}): JdbcClient expande los arreglos Java. */
    static String arreglo(Collection<Long> ids) {
        StringBuilder sb = new StringBuilder("{");
        for (Long id : ids) {
            if (sb.length() > 1) sb.append(',');
            sb.append(id);
        }
        return sb.append('}').toString();
    }

    // ── fechas ─────────────────────────────────────────────────────────────

    /** ISO con zona ({@code toISOString}) o local ({@code yyyy-MM-ddTHH:mm}, hora de Colombia). */
    static OffsetDateTime fecha(String valor, String campo) {
        if (valor == null || valor.isBlank()) return null;
        try {
            return OffsetDateTime.parse(valor);
        } catch (DateTimeParseException e) {
            try {
                return LocalDateTime.parse(valor).atZone(BOGOTA).toOffsetDateTime();
            } catch (DateTimeParseException e2) {
                throw new ApiError(400, "La fecha de " + campo + " no es valida.");
            }
        }
    }

    static void validarRango(OffsetDateTime inicio, OffsetDateTime cierre) {
        if (cierre != null && inicio != null && !cierre.isAfter(inicio)) {
            throw new ApiError(400, "La fecha de cierre debe ser posterior a la de inicio.");
        }
        if (cierre != null && !cierre.toInstant().isAfter(Instant.now())) {
            throw new ApiError(400, "La fecha de cierre ya paso.");
        }
    }

    static String iso(ResultSet rs, String col) throws SQLException {
        OffsetDateTime f = rs.getObject(col, OffsetDateTime.class);
        return f == null ? null : f.withOffsetSameInstant(ZoneOffset.UTC).toInstant().toString();
    }

    /** Mismo calculo que {@code estadoEleccion} del front. */
    static String estado(OffsetDateTime inicio, OffsetDateTime cierre, boolean cerradaManualmente) {
        Instant ahora = Instant.now();
        if (cerradaManualmente) return "FINALIZADA";
        if (inicio != null && inicio.toInstant().isAfter(ahora)) return "PROGRAMADA";
        if (cierre != null && !cierre.toInstant().isAfter(ahora)) return "FINALIZADA";
        return "ACTIVA";
    }
}
