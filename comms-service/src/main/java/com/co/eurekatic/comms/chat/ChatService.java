package com.co.eurekatic.comms.chat;

import com.co.eurekatic.comms.chat.ChatDtos.Conversacion;
import com.co.eurekatic.comms.chat.ChatDtos.Mencion;
import com.co.eurekatic.comms.chat.ChatDtos.Mensaje;
import com.co.eurekatic.comms.chat.ChatDtos.Miembro;
import com.co.eurekatic.comms.chat.ChatDtos.Persona;
import com.co.eurekatic.comms.chat.ChatRepository.Membresia;
import com.co.eurekatic.comms.chat.ChatRepository.MensajeBase;
import com.co.eurekatic.comms.realtime.PresenciaService;
import com.co.eurekatic.comms.realtime.RealtimeBus;
import com.co.eurekatic.comms.security.Usuario;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionTemplate;

import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * Reglas del chat. Cada escritura: validar → escribir en una transaccion (con
 * contexto de auditoria) → tras el commit, eventos de tiempo real y de
 * notificacion. Topicos: {@code canal:<id>} ({@code mensaje.creado|actualizado|eliminado},
 * efimero {@code escribiendo}) y {@code user:<sub>} ({@code conversacion.actualizada}).
 */
@Service
public class ChatService {

    static final Set<String> CATEGORIAS = Set.of("GENERAL", "VOTACION", "ENCUESTA", "EXAMEN", "ANUNCIO");
    private static final int MAX_TEXTO = 4000;

    private final ChatRepository repo;
    private final PoliticaChat politica;
    private final RealtimeBus bus;
    private final PresenciaService presencia;
    private final NotificadorChat notificador;
    private final TransactionTemplate tx;
    private final AdjuntosChat adjuntos;

    public ChatService(ChatRepository repo, PoliticaChat politica, RealtimeBus bus, PresenciaService presencia,
                       NotificadorChat notificador, TransactionTemplate tx, AdjuntosChat adjuntos) {
        this.adjuntos = adjuntos;
        this.repo = repo;
        this.politica = politica;
        this.bus = bus;
        this.presencia = presencia;
        this.notificador = notificador;
        this.tx = tx;
    }

    // ── lectura ────────────────────────────────────────────────────────────

    public List<Conversacion> conversaciones(Usuario u) {
        return repo.conversaciones(u.id());
    }

    /** Tope de una pagina de {@code /personas}. */
    static final int PERSONAS_MAX = 100;

    /** El super administrador busca en todos los colegios (alcance, no politica de DM). */
    static final String SUPER_ADMIN = "CEVAL-SUPER_ADMINISTRADOR";

    public List<Persona> personas(Usuario u, String q, Integer limite, Integer desde) {
        int lim = limite == null || limite < 1 ? 50 : Math.min(limite, PERSONAS_MAX);
        int off = desde == null || desde < 0 ? 0 : desde;
        boolean todos = u.roles() != null && u.roles().contains(SUPER_ADMIN);
        String perfil = politica.perfil(u.roles());
        return repo.personas(u.id(), u.establecimiento(), todos, q, lim, off).stream()
                .map(p -> new Persona(p.id(), p.nombre(), p.correo(), politica.perfil(p.roles())))
                // Quien no se puede escribir ni sumar a un canal no se ofrece (D: politica de menores).
                .filter(p -> !"PROHIBIDO".equals(politica.reglaDirecto(perfil, p.perfil()))
                        || politica.puedeCrearCanal(perfil))
                .toList();
    }

    public List<Miembro> miembros(Usuario u, long canal) {
        Membresia m = exigirMiembro(u, canal);
        var filas = repo.miembrosDetalle(canal);
        Set<Long> online = presencia.enLinea(filas.stream().map(ChatRepository.MiembroFila::id).toList());
        return filas.stream()
                .filter(f -> !"DIRECTO".equals(m.tipoCanal()) || f.id() != u.id())
                .map(f -> new Miembro(f.id(), f.nombre(), "ADMIN".equals(f.rol()) ? "Administrador" : "Miembro",
                        online.contains(f.id()), f.bloqueado()))
                .toList();
    }

    public List<Mensaje> mensajes(Usuario u, long canal, Long antes, Integer limite) {
        exigirMiembro(u, canal);
        int lim = limite == null ? 200 : Math.clamp(limite, 1, 500);
        List<Long> ids = repo.idsMensajes(canal, antes, lim);
        return repo.mensajes(ids, u.id(), presencia.enLinea(repo.miembros(canal).keySet()));
    }

    // ── canales ────────────────────────────────────────────────────────────

    public Conversacion crearCanal(Usuario u, String nombre, String categoria, List<Long> miembros) {
        String n = nombre == null ? "" : nombre.trim();
        if (n.isEmpty()) throw new ApiError(400, "Escribe un nombre para el canal.");
        if (n.length() > 100) throw new ApiError(400, "El nombre del canal es demasiado largo.");
        if (!politica.puedeCrearCanal(politica.perfil(u.roles()))) {
            throw new ApiError(403, "Tu perfil no puede crear canales.");
        }
        String cat = categoria == null ? "GENERAL" : categoria;
        if (!CATEGORIAS.contains(cat)) throw new ApiError(400, "Categoria de canal desconocida.");
        if (repo.existeNombre(n, u.establecimiento(), null)) {
            throw new ApiError(409, "Ya existe un canal llamado " + n + ".");
        }
        Set<Long> invitados = permitidos(u, miembros);
        long canal = tx.execute(s -> {
            repo.contextoAuditoria(u.sub());
            long id = repo.crearCanal("CANAL", cat, n, u.establecimiento(), null, u.id());
            repo.agregarMiembro(id, u.id(), "ADMIN");
            for (Long m : invitados) {
                repo.agregarMiembro(id, m, "MIEMBRO");
                aviso(id, m, n);
            }
            return id;
        });
        notificarInvitados(u, canal, n, invitados);
        return conversacion(canal, u);
    }

    public Conversacion directo(Usuario u, Long persona) {
        if (persona == null || persona == u.id()) throw new ApiError(400, "Elige a la persona.");
        var p = repo.persona(persona).orElseThrow(() -> new ApiError(404, "La persona no existe."));
        if ("PROHIBIDO".equals(politica.reglaDirecto(politica.perfil(u.roles()), politica.perfil(p.roles())))) {
            throw new ApiError(403, "La politica de la institucion no permite este mensaje directo.");
        }
        String clave = Math.min(u.id(), persona) + ":" + Math.max(u.id(), persona);
        long canal = tx.execute(s -> {
            repo.contextoAuditoria(u.sub());
            long id = repo.directoExistente(clave).orElseGet(() ->
                    repo.crearCanal("DIRECTO", "GENERAL", "Directo", null, clave, u.id()));
            repo.agregarMiembro(id, u.id(), "MIEMBRO");
            repo.agregarMiembro(id, persona, "MIEMBRO");
            return id;
        });
        return conversacion(canal, u);
    }

    public Conversacion renombrar(Usuario u, long canal, String nombre) {
        exigirAdmin(u, canal);
        String n = nombre == null ? "" : nombre.trim();
        if (n.isEmpty()) throw new ApiError(400, "Escribe un nombre para el canal.");
        if (repo.existeNombre(n, u.establecimiento(), canal)) {
            throw new ApiError(409, "Ya existe un canal llamado " + n + ".");
        }
        escribir(u, () -> repo.renombrar(canal, n));
        return conversacion(canal, u);
    }

    public Conversacion eliminar(Usuario u, long canal) {
        Conversacion antes = conversacion(canal, u);
        exigirAdmin(u, canal);
        escribir(u, () -> repo.eliminarCanal(canal));
        return antes;
    }

    public Conversacion salir(Usuario u, long canal) {
        Conversacion antes = conversacion(canal, u);
        escribir(u, () -> repo.salir(canal, u.id()));
        return antes;
    }

    public Conversacion silenciar(Usuario u, long canal, String duracion) {
        exigirMiembro(u, canal);
        Instant hasta = switch (duracion == null ? "" : duracion) {
            case "8H" -> Instant.now().plus(8, ChronoUnit.HOURS);
            case "1S" -> Instant.now().plus(7, ChronoUnit.DAYS);
            case "SIEMPRE" -> Instant.parse("9999-12-31T00:00:00Z");
            default -> throw new ApiError(400, "Duracion de silencio invalida.");
        };
        return actualizarMiembro(u, canal, "silenciado_hasta = :h",
                Map.of("h", java.time.OffsetDateTime.ofInstant(hasta, java.time.ZoneOffset.UTC)));
    }

    public Conversacion leido(Usuario u, long canal) {
        return actualizarMiembro(u, canal, """
                ultimo_leido_msg = COALESCE((SELECT MAX(pk_tmensaje) FROM comunicaciones.tmensaje
                                              WHERE fk_tcanal = :canal), 0),
                marcado_no_leido = FALSE, menciones_pendientes = 0""", Map.of());
    }

    public Conversacion noLeido(Usuario u, long canal) {
        return actualizarMiembro(u, canal, "marcado_no_leido = TRUE", Map.of());
    }

    public Conversacion archivar(Usuario u, long canal, boolean archivar) {
        return actualizarMiembro(u, canal, "archivado = :a", Map.of("a", archivar));
    }

    // ── miembros ───────────────────────────────────────────────────────────

    public List<Miembro> agregarMiembros(Usuario u, long canal, List<Long> nuevos) {
        exigirAdmin(u, canal);
        Map<Long, String> actuales = repo.miembros(canal);
        Set<Long> invitados = permitidos(u, nuevos);
        invitados.removeAll(actuales.keySet());
        String nombre = conversacion(canal, u).nombre();
        tx.executeWithoutResult(s -> {
            repo.contextoAuditoria(u.sub());
            for (Long m : invitados) {
                repo.agregarMiembro(canal, m, "MIEMBRO");
                aviso(canal, m, nombre);
            }
        });
        notificarInvitados(u, canal, nombre, invitados);
        return miembros(u, canal);
    }

    public Miembro bloquear(Usuario u, long canal, long miembro, boolean bloqueado) {
        exigirAdmin(u, canal);
        if (miembro == u.id()) throw new ApiError(400, "No puedes bloquearte a ti mismo.");
        boolean ok = Boolean.TRUE.equals(tx.execute(s -> {
            repo.contextoAuditoria(u.sub());
            return repo.bloquear(canal, miembro, bloqueado);
        }));
        if (!ok) throw new ApiError(404, "La persona ya no esta en el canal.");
        return miembroDe(u, canal, miembro);
    }

    public Miembro quitarMiembro(Usuario u, long canal, long miembro) {
        exigirAdmin(u, canal);
        Miembro m = miembroDe(u, canal, miembro);
        boolean ok = Boolean.TRUE.equals(tx.execute(s -> {
            repo.contextoAuditoria(u.sub());
            return repo.salir(canal, miembro);
        }));
        if (!ok) throw new ApiError(404, "La persona ya no esta en el canal.");
        return m;
    }

    // ── mensajes ───────────────────────────────────────────────────────────

    /**
     * {@code archivoId}: pk_tarchivo que reenvio file-service (campo multipart
     * {@code ADJUNTO}); nombre y formato salen de TARCHIVO, no del cliente.
     */
    public Mensaje enviar(Usuario u, long canal, String texto, Long archivoId, Long respuesta, UUID clientId) {
        Membresia mem = exigirMiembro(u, canal);
        var previo = repo.mensajePorClientId(u.id(), clientId);
        if (previo.isPresent()) return uno(previo.get(), u);
        String t = texto == null ? "" : texto.trim();
        if (t.length() > MAX_TEXTO) throw new ApiError(400, "El mensaje es demasiado largo.");
        if (t.isEmpty() && archivoId == null) throw new ApiError(400, "Escribe un mensaje o adjunta un archivo.");
        AdjuntosChat.Archivo adj = archivoId == null ? null : adjuntos.validar(archivoId, u.sub());
        MensajeBase original = null;
        if (respuesta != null) {
            original = repo.mensajeBase(respuesta).filter(m -> m.canal() == canal && !m.eliminado())
                    .orElseThrow(() -> new ApiError(404, "El mensaje al que respondes ya no existe."));
        }
        Map<Long, String> miembros = repo.miembros(canal);
        List<Mencion> menciones = Menciones.extraer(t, miembros, politica.mencionMasiva(politica.perfil(u.roles())));
        long id = tx.execute(s -> {
            repo.contextoAuditoria(u.sub());
            long nuevo = repo.insertarMensaje(canal, u.id(), "NORMAL", t, adj == null ? null : adj.nombre(),
                    adj == null ? null : adj.formato(), adj == null ? null : adj.id(), adj == null ? null : adj.peso(),
                    respuesta, clientId);
            // El borrador de este canal queda como enviado (pestaña "Enviados").
            repo.marcarBorradorEnviado(canal, u.id(), nuevo, t);
            repo.guardarMenciones(nuevo, menciones);
            repo.sumarMenciones(canal, mencionados(menciones, miembros.keySet(), u.id()));
            repo.actualizarMiembro(canal, u.id(), "ultimo_leido_msg = :m, marcado_no_leido = FALSE",
                    Map.of("m", nuevo));
            return nuevo;
        });
        difundir(canal, "mensaje.creado", id);
        refrescarListas(canal, miembros.keySet(), u.id());
        notificarMensaje(u, canal, mem, id, t.isEmpty() && adj != null ? "Adjunto: " + adj.nombre() : t, menciones,
                miembros, original);
        return uno(id, u);
    }

    public Mensaje editar(Usuario u, long id, String texto) {
        MensajeBase m = propio(u, id, "Solo puedes editar tus mensajes.");
        String t = texto == null ? "" : texto.trim();
        if (t.isEmpty() && m.adjunto() == null) throw new ApiError(400, "El mensaje no puede quedar vacio.");
        if (t.length() > MAX_TEXTO) throw new ApiError(400, "El mensaje es demasiado largo.");
        // Editar no vuelve a notificar (como Discord): solo se recalculan las menciones.
        List<Mencion> menciones = Menciones.extraer(t, repo.miembros(m.canal()),
                politica.mencionMasiva(politica.perfil(u.roles())));
        escribir(u, () -> {
            repo.editarTexto(id, t);
            repo.guardarMenciones(id, menciones);
        });
        difundir(m.canal(), "mensaje.actualizado", id);
        return uno(id, u);
    }

    public Mensaje eliminarMensaje(Usuario u, long id) {
        MensajeBase m = propio(u, id, "Solo puedes eliminar tus mensajes.");
        Mensaje antes = uno(id, u);
        List<Long> citan = repo.respuestasA(id);
        escribir(u, () -> repo.eliminarMensaje(id, u.id()));
        bus.publicar("canal:" + m.canal(), "mensaje.eliminado", Map.of("id", id, "conversacionId", m.canal()));
        for (Long r : citan) difundir(m.canal(), "mensaje.actualizado", r);
        return antes;
    }

    public Mensaje quitarAdjunto(Usuario u, long id) {
        MensajeBase m = propio(u, id, "Solo puedes quitar archivos de tus mensajes.");
        if (m.adjunto() == null) throw new ApiError(404, "El mensaje ya no existe.");
        escribir(u, () -> repo.quitarAdjunto(id));
        difundir(m.canal(), "mensaje.actualizado", id);
        return uno(id, u);
    }

    public Mensaje fijar(Usuario u, long id, boolean fijado) {
        MensajeBase m = visible(u, id);
        escribir(u, () -> repo.fijar(id, fijado));
        difundir(m.canal(), "mensaje.actualizado", id);
        return uno(id, u);
    }

    public Mensaje reaccionar(Usuario u, long id, String emoji) {
        String e = emoji == null ? "" : emoji.trim();
        if (e.isEmpty() || e.length() > 32) throw new ApiError(400, "Elige un emoji.");
        MensajeBase m = visible(u, id);
        boolean puesta = Boolean.TRUE.equals(tx.execute(s -> repo.alternarReaccion(id, u.id(), e)));
        difundir(m.canal(), "mensaje.actualizado", id);
        if (puesta && m.autor() != u.id()) {
            var correo = repo.correos(List.of(m.autor())).get(m.autor());
            if (correo != null) {
                notificador.enviar("CHAT_REACCION", List.of(correo), u.nombre() + " reacciono a tu mensaje",
                        e, deepLink(m.canal(), id), Map.of("canal", m.canal(), "mensaje", id),
                        "reaccion:" + id + ":" + u.id() + ":" + e, "reaccion:" + id, u.nombre());
            }
        }
        return uno(id, u);
    }

    // ── internos ───────────────────────────────────────────────────────────

    Membresia exigirMiembro(Usuario u, long canal) {
        Membresia m = repo.membresia(canal, u.id())
                .orElseThrow(() -> new ApiError(404, "La conversacion no existe."));
        if (m.bloqueado()) throw new ApiError(403, "Te bloquearon en este canal.");
        return m;
    }

    void exigirAdmin(Usuario u, long canal) {
        Membresia m = exigirMiembro(u, canal);
        if ("DIRECTO".equals(m.tipoCanal())) throw new ApiError(400, "Un mensaje directo no se administra.");
        if (!"ADMIN".equals(m.rol())) throw new ApiError(403, "Solo quien administra el canal puede hacerlo.");
    }

    MensajeBase visible(Usuario u, long id) {
        MensajeBase m = repo.mensajeBase(id).filter(x -> !x.eliminado())
                .orElseThrow(() -> new ApiError(404, "El mensaje ya no existe."));
        exigirMiembro(u, m.canal());
        return m;
    }

    MensajeBase propio(Usuario u, long id, String msg) {
        MensajeBase m = visible(u, id);
        if (m.autor() != u.id()) throw new ApiError(403, msg);
        return m;
    }

    private Conversacion conversacion(long canal, Usuario u) {
        return repo.conversacion(canal, u.id()).orElseThrow(() -> new ApiError(404, "La conversacion no existe."));
    }

    private Conversacion actualizarMiembro(Usuario u, long canal, String set, Map<String, Object> params) {
        exigirMiembro(u, canal);
        escribir(u, () -> repo.actualizarMiembro(canal, u.id(), set, params));
        Conversacion c = conversacion(canal, u);
        // Las demas sesiones del usuario ven el cambio (leido, silencio, archivo).
        bus.publicar("user:" + u.sub(), "conversacion.actualizada", c);
        return c;
    }

    private Miembro miembroDe(Usuario u, long canal, long miembro) {
        return miembros(u, canal).stream().filter(m -> m.id() == miembro).findFirst()
                .orElseThrow(() -> new ApiError(404, "La persona ya no esta en el canal."));
    }

    Mensaje uno(long id, Usuario u) {
        return repo.mensajes(List.of(id), u.id(), Set.of()).stream().findFirst()
                .orElseThrow(() -> new ApiError(404, "El mensaje ya no existe."));
    }

    void escribir(Usuario u, Runnable r) {
        tx.executeWithoutResult(s -> {
            repo.contextoAuditoria(u.sub());
            r.run();
        });
    }

    /** Solo personas que existen y que la politica deja sumar. */
    private Set<Long> permitidos(Usuario u, List<Long> ids) {
        Set<Long> out = new LinkedHashSet<>();
        if (ids == null) return out;
        for (Long id : ids) {
            if (id == null || id == u.id()) continue;
            repo.persona(id).ifPresent(p -> out.add(p.id()));
        }
        return out;
    }

    private void aviso(long canal, long miembro, String nombreCanal) {
        repo.persona(miembro).ifPresent(p -> repo.insertarMensaje(canal, miembro, "SISTEMA",
                p.nombre() + " se ha unido a " + nombreCanal, null, null, null, null));
    }

    /** Mensaje difundido en forma neutra (sin {@code esPropio}/{@code mia}: el cliente los calcula). */
    void difundir(long canal, String evento, long id) {
        repo.mensajes(List.of(id), null, Set.of()).stream().findFirst()
                .ifPresent(m -> bus.publicar("canal:" + canal, evento, m));
    }

    /** Contadores de no leidos en la lista: solo a miembros conectados (los demas leen por REST). */
    void refrescarListas(long canal, Set<Long> miembros, long autor) {
        Set<Long> online = presencia.enLinea(miembros);
        online.remove(autor);
        if (online.isEmpty()) return;
        Map<Long, String> correos = repo.correos(online);
        for (Long m : online) {
            String sub = correos.get(m);
            if (sub == null) continue;
            repo.conversacion(canal, m).ifPresent(c ->
                    bus.publicar("user:" + Usuario.normalizar(sub), "conversacion.actualizada", c));
        }
    }

    private static Set<Long> mencionados(List<Mencion> menciones, Set<Long> miembros, long autor) {
        Set<Long> out = new LinkedHashSet<>();
        for (Mencion m : menciones) {
            if ("USUARIO".equals(m.tipo())) out.add(m.usuarioId());
            else out.addAll(miembros);
        }
        out.remove(autor);
        return out;
    }

    private void notificarMensaje(Usuario u, long canal, Membresia mem, long id, String texto, List<Mencion> menciones,
                                  Map<Long, String> miembros, MensajeBase original) {
        String link = deepLink(canal, id);
        String resumen = texto.length() > 140 ? texto.substring(0, 140) + "…" : texto;
        Set<Long> silenciados = silenciados(canal);
        Set<Long> yaAvisados = new LinkedHashSet<>();
        Set<Long> mencionados = mencionados(menciones, miembros.keySet(), u.id());
        mencionados.removeAll(silenciados);
        enviarA(mencionados, "CHAT_MENCION", u.nombre() + " te menciono", resumen, link, canal, id,
                "mencion:" + id, null, u.nombre());
        yaAvisados.addAll(mencionados);
        if (original != null && original.autor() != u.id() && !yaAvisados.contains(original.autor())
                && !silenciados.contains(original.autor())) {
            enviarA(Set.of(original.autor()), "CHAT_RESPUESTA", u.nombre() + " respondio tu mensaje", resumen, link,
                    canal, id, "respuesta:" + id, "respuesta:" + original.id(), u.nombre());
            yaAvisados.add(original.autor());
        }
        if ("DIRECTO".equals(mem.tipoCanal())) {
            Set<Long> otros = new LinkedHashSet<>(miembros.keySet());
            otros.remove(u.id());
            otros.removeAll(yaAvisados);
            otros.removeAll(silenciados);
            enviarA(otros, "CHAT_DIRECTO", "Mensaje de " + u.nombre(), resumen, link, canal, id,
                    "directo:" + id, "directo:" + canal, u.nombre());
        }
    }

    private void notificarInvitados(Usuario u, long canal, String nombre, Set<Long> invitados) {
        // Sin tipo propio en el catalogo de notificaciones: se avisa en vivo por la lista.
        refrescarListas(canal, invitados, u.id());
    }

    private void enviarA(Set<Long> usuarios, String tipo, String titulo, String cuerpo, String link, long canal,
                         long mensaje, String dedupe, String agrupacion, String actor) {
        if (usuarios.isEmpty()) return;
        List<String> correos = new ArrayList<>(repo.correos(usuarios).values());
        notificador.enviar(tipo, correos, titulo, cuerpo, link, Map.of("canal", canal, "mensaje", mensaje),
                dedupe, agrupacion, actor);
    }

    private Set<Long> silenciados(long canal) {
        Set<Long> out = new LinkedHashSet<>();
        for (var f : repo.miembrosDetalle(canal)) {
            if (f.silenciadoHasta() != null && f.silenciadoHasta().toInstant().isAfter(Instant.now())) out.add(f.id());
        }
        return out;
    }

    static String deepLink(long canal, long mensaje) {
        return "/app/comunicaciones/chat?canal=" + canal + "&mensaje=" + mensaje;
    }
}
