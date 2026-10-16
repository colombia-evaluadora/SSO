package com.co.eurekatic.comms.foro;

import com.co.eurekatic.comms.chat.AdjuntosChat;
import com.co.eurekatic.comms.chat.ApiError;
import com.co.eurekatic.comms.chat.ChatDtos.Mencion;
import com.co.eurekatic.comms.chat.ChatDtos.Mensaje;
import com.co.eurekatic.comms.chat.ChatRepository;
import com.co.eurekatic.comms.chat.ChatRepository.Membresia;
import com.co.eurekatic.comms.chat.ChatRepository.MensajeBase;
import com.co.eurekatic.comms.chat.Menciones;
import com.co.eurekatic.comms.chat.NotificadorChat;
import com.co.eurekatic.comms.chat.PoliticaChat;
import com.co.eurekatic.comms.foro.ForoDtos.Etiqueta;
import com.co.eurekatic.comms.foro.ForoDtos.Foro;
import com.co.eurekatic.comms.foro.ForoDtos.Publicacion;
import com.co.eurekatic.comms.foro.ForoDtos.RespuestaEvento;
import com.co.eurekatic.comms.foro.ForoRepository.Filtro;
import com.co.eurekatic.comms.foro.ForoRepository.HiloBase;
import com.co.eurekatic.comms.realtime.PresenciaService;
import com.co.eurekatic.comms.realtime.RealtimeBus;
import com.co.eurekatic.comms.security.Usuario;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionTemplate;

import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * Foros estilo Discord sobre un canal {@code FORO} (V560/V585). Cada publicacion es
 * un hilo con titulo, etiquetas y estados fijada/cerrada/resuelta; su cuerpo y sus
 * respuestas son mensajes del chat. Quien publica, responde o modera lo decide
 * {@link PoliticaChat} (configurable por institucion por los menores); el
 * administrador del canal modera siempre.
 *
 * <p>Tiempo real en {@code foro:<id>}: {@code publicacion.creada|actualizada|eliminada}
 * y {@code respuesta.creada|actualizada|eliminada}. Reacciones y ediciones de una
 * respuesta usan los endpoints del chat y llegan por {@code canal:<id>}.
 * Notificaciones: {@code FORO_MENCION} y {@code FORO_RESPUESTA} (seguidores).
 */
@Service
public class ForoService {

    static final Set<String> COLORES = Set.of("BLUE", "GREEN", "YELLOW", "RED", "PURPLE", "ORANGE", "NAVY");
    private static final int MAX_TEXTO = 4000;
    private static final int MAX_TITULO = 150;
    private static final int MAX_ETIQUETAS = 5;
    private static final int LIMITE_DEFECTO = 30;

    private final ForoRepository repo;
    private final ChatRepository chat;
    private final PoliticaChat politica;
    private final RealtimeBus bus;
    private final PresenciaService presencia;
    private final NotificadorChat notificador;
    private final TransactionTemplate tx;
    private final AdjuntosChat adjuntos;

    public ForoService(ForoRepository repo, ChatRepository chat, PoliticaChat politica, RealtimeBus bus,
                       PresenciaService presencia, NotificadorChat notificador, TransactionTemplate tx,
                       AdjuntosChat adjuntos) {
        this.adjuntos = adjuntos;
        this.repo = repo;
        this.chat = chat;
        this.politica = politica;
        this.bus = bus;
        this.presencia = presencia;
        this.notificador = notificador;
        this.tx = tx;
    }

    // ── foro y etiquetas ───────────────────────────────────────────────────

    public Foro foro(Usuario u, long canal) {
        Membresia m = exigirForo(u, canal);
        String perfil = politica.perfil(u.roles());
        var conv = chat.conversacion(canal, u.id()).orElseThrow(() -> new ApiError(404, "El foro no existe."));
        return new Foro(canal, conv.nombre(), conv.totalMiembros(), repo.etiquetas(canal),
                politica.puedePublicarEnForo(perfil), politica.puedeResponderEnForo(perfil), esModerador(u, m));
    }

    public Etiqueta crearEtiqueta(Usuario u, long canal, String nombre, String color, boolean soloModeradores) {
        exigirModerador(u, exigirForo(u, canal));
        String n = nombre == null ? "" : nombre.trim();
        if (n.isEmpty() || n.length() > 40) throw new ApiError(400, "Escribe un nombre de etiqueta de hasta 40 caracteres.");
        String c = color == null ? "BLUE" : color;
        if (!COLORES.contains(c)) throw new ApiError(400, "Color de etiqueta desconocido.");
        if (repo.existeEtiqueta(canal, n)) throw new ApiError(409, "Ya existe la etiqueta " + n + ".");
        Etiqueta e = tx.execute(s -> {
            chat.contextoAuditoria(u.sub());
            return repo.crearEtiqueta(canal, n, c, soloModeradores, u.id());
        });
        bus.publicar(topico(canal), "foro.actualizado", Map.of("id", canal));
        return e;
    }

    public Etiqueta eliminarEtiqueta(Usuario u, long id) {
        var base = repo.etiquetaBase(id).orElseThrow(() -> new ApiError(404, "La etiqueta ya no existe."));
        exigirModerador(u, exigirForo(u, base.canal()));
        Etiqueta e = repo.etiquetas(base.canal()).stream().filter(x -> x.id() == id).findFirst()
                .orElseThrow(() -> new ApiError(404, "La etiqueta ya no existe."));
        escribir(u, () -> repo.eliminarEtiqueta(id));
        bus.publicar(topico(base.canal()), "foro.actualizado", Map.of("id", base.canal()));
        return e;
    }

    // ── publicaciones: lectura ─────────────────────────────────────────────

    public List<Publicacion> publicaciones(Usuario u, long canal, String orden, Long etiqueta, String q,
                                           Integer pagina, Integer limite) {
        exigirForo(u, canal);
        String o = orden == null || orden.isBlank() ? "ACTIVIDAD" : orden.toUpperCase();
        if (!ForoRepository.ORDENES.containsKey(o)) throw new ApiError(400, "Orden desconocido.");
        String busca = q == null || q.isBlank() ? null : q.trim();
        int lim = limite == null ? LIMITE_DEFECTO : Math.clamp(limite, 1, 100);
        int pag = pagina == null ? 0 : Math.max(0, pagina);
        return repo.publicaciones(canal, u.id(), new Filtro(o, etiqueta, busca, pag, lim),
                presencia.enLinea(chat.miembros(canal).keySet()));
    }

    public Publicacion publicacion(Usuario u, long id) {
        HiloBase h = hilo(id);
        exigirForo(u, h.canal());
        return detalle(h, u.id());
    }

    public List<Mensaje> respuestas(Usuario u, long id) {
        HiloBase h = hilo(id);
        exigirForo(u, h.canal());
        return chat.mensajes(repo.idsRespuestas(id, 1000), u.id(), presencia.enLinea(chat.miembros(h.canal()).keySet()));
    }

    // ── publicaciones: escritura ───────────────────────────────────────────

    /**
     * {@code archivoId}: pk_tarchivo que reenvio file-service (campo multipart
     * {@code ADJUNTO}); nombre, formato y peso salen de TARCHIVO como en el chat.
     */
    public Publicacion publicar(Usuario u, long canal, String titulo, String texto, List<Long> etiquetas,
                                Long archivoId, UUID clientId) {
        Membresia m = exigirForo(u, canal);
        if (!politica.puedePublicarEnForo(politica.perfil(u.roles()))) {
            throw new ApiError(403, "Tu perfil no puede abrir publicaciones en los foros.");
        }
        var previo = chat.mensajePorClientId(u.id(), clientId).flatMap(repo::hiloPorRaiz);
        if (previo.isPresent()) return detalle(hilo(previo.get()), u.id());
        String ti = titulo(titulo);
        String t = texto(texto, archivoId != null);
        Set<Long> tags = etiquetasValidas(u, m, canal, etiquetas);
        AdjuntosChat.Archivo adj = archivoId == null ? null : adjuntos.validar(archivoId, u.sub());
        Map<Long, String> miembros = chat.miembros(canal);
        List<Mencion> menciones = Menciones.extraer(t, miembros, politica.mencionMasiva(politica.perfil(u.roles())));
        long hilo = tx.execute(s -> {
            chat.contextoAuditoria(u.sub());
            long raiz = insertar(canal, u.id(), t, adj, null, clientId);
            chat.guardarMenciones(raiz, menciones);
            long h = repo.crearHilo(canal, raiz, u.id(), ti, t);
            repo.reemplazarEtiquetas(h, tags);
            repo.seguir(h, u.id(), true);
            return h;
        });
        Publicacion p = detalle(hilo(hilo), u.id());
        bus.publicar(topico(canal), "publicacion.creada", neutra(hilo));
        notificarMenciones(u, canal, hilo, p.mensaje().id(), ti, cuerpoAviso(t, adj), menciones, miembros, Set.of());
        return p;
    }

    public Publicacion editar(Usuario u, long id, String titulo, String texto) {
        HiloBase h = hilo(id);
        Membresia m = exigirForo(u, h.canal());
        if (h.autor() != u.id()) throw new ApiError(403, "Solo quien publico puede editar la publicacion.");
        if (h.cerrado() && !esModerador(u, m)) throw new ApiError(409, "La publicacion esta cerrada.");
        MensajeBase raiz = chat.mensajeBase(h.raiz()).orElseThrow(() -> new ApiError(404, "La publicacion ya no existe."));
        String ti = titulo(titulo);
        String t = texto(texto, raiz.adjunto() != null && !raiz.adjunto().isBlank());
        List<Mencion> menciones = Menciones.extraer(t, chat.miembros(h.canal()),
                politica.mencionMasiva(politica.perfil(u.roles())));
        escribir(u, () -> {
            chat.editarTexto(h.raiz(), t);
            chat.guardarMenciones(h.raiz(), menciones);
            repo.editarHilo(id, ti, t);
        });
        return actualizada(h, u);
    }

    public Publicacion etiquetar(Usuario u, long id, List<Long> etiquetas) {
        HiloBase h = hilo(id);
        Membresia m = exigirForo(u, h.canal());
        if (h.autor() != u.id() && !esModerador(u, m)) {
            throw new ApiError(403, "Solo quien publico o un moderador cambia las etiquetas.");
        }
        Set<Long> tags = etiquetasValidas(u, m, h.canal(), etiquetas);
        escribir(u, () -> repo.reemplazarEtiquetas(id, tags));
        return actualizada(h, u);
    }

    public Publicacion fijar(Usuario u, long id, boolean fijada) {
        HiloBase h = hilo(id);
        exigirModerador(u, exigirForo(u, h.canal()));
        escribir(u, () -> repo.actualizarHilo(id, "fijado = :f", Map.of("f", fijada)));
        return actualizada(h, u);
    }

    public Publicacion cerrar(Usuario u, long id, boolean cerrada) {
        HiloBase h = hilo(id);
        exigirModerador(u, exigirForo(u, h.canal()));
        escribir(u, () -> repo.actualizarHilo(id, "cerrado = :c, cerrado_por = CASE WHEN :c THEN CAST(:u AS BIGINT) END",
                Map.of("c", cerrada, "u", u.id())));
        return actualizada(h, u);
    }

    /** Preguntas y respuestas: lo marca quien publico o un moderador, con o sin la respuesta que resolvio. */
    public Publicacion resolver(Usuario u, long id, boolean resuelta, Long solucion) {
        HiloBase h = hilo(id);
        Membresia m = exigirForo(u, h.canal());
        if (h.autor() != u.id() && !esModerador(u, m)) {
            throw new ApiError(403, "Solo quien publico o un moderador marca la publicacion como resuelta.");
        }
        Long sol = resuelta ? solucion : null;
        if (sol != null && !repo.hiloDeMensaje(sol).filter(x -> x == id).isPresent() || sol != null && sol == h.raiz()) {
            throw new ApiError(400, "La solucion debe ser una respuesta de esta publicacion.");
        }
        Map<String, Object> p = new java.util.HashMap<>();
        p.put("r", resuelta);
        p.put("s", sol);
        p.put("u", u.id());
        escribir(u, () -> repo.actualizarHilo(id, """
                resuelto = :r, fk_tmensaje_solucion = CAST(:s AS BIGINT),
                resuelto_por = CASE WHEN :r THEN CAST(:u AS BIGINT) END""", p));
        return actualizada(h, u);
    }

    public Publicacion seguir(Usuario u, long id, boolean seguir) {
        HiloBase h = hilo(id);
        exigirForo(u, h.canal());
        tx.executeWithoutResult(s -> repo.seguir(id, u.id(), seguir));
        return detalle(h, u.id());
    }

    public Publicacion eliminar(Usuario u, long id) {
        HiloBase h = hilo(id);
        Membresia m = exigirForo(u, h.canal());
        if (h.autor() != u.id() && !esModerador(u, m)) {
            throw new ApiError(403, "Solo quien publico o un moderador elimina la publicacion.");
        }
        Publicacion antes = detalle(h, u.id());
        escribir(u, () -> {
            repo.eliminarHilo(id, u.id());
            chat.eliminarMensaje(h.raiz(), u.id());
        });
        bus.publicar(topico(h.canal()), "publicacion.eliminada", Map.of("id", id, "foroId", h.canal()));
        return antes;
    }

    // ── respuestas ─────────────────────────────────────────────────────────

    public Mensaje responder(Usuario u, long id, String texto, Long archivoId, Long respuesta, UUID clientId) {
        HiloBase h = hilo(id);
        Membresia m = exigirForo(u, h.canal());
        if (!politica.puedeResponderEnForo(politica.perfil(u.roles()))) {
            throw new ApiError(403, "Tu perfil no puede responder en los foros.");
        }
        if (h.cerrado() && !esModerador(u, m)) throw new ApiError(409, "La publicacion esta cerrada.");
        var previo = chat.mensajePorClientId(u.id(), clientId);
        if (previo.isPresent()) return uno(previo.get(), u);
        String t = texto(texto, archivoId != null);
        MensajeBase original = null;
        if (respuesta != null) {
            original = chat.mensajeBase(respuesta).filter(x -> !x.eliminado())
                    .filter(x -> repo.hiloDeMensaje(x.id()).filter(hh -> hh == id).isPresent())
                    .orElseThrow(() -> new ApiError(404, "El mensaje al que respondes ya no existe."));
        }
        AdjuntosChat.Archivo adj = archivoId == null ? null : adjuntos.validar(archivoId, u.sub());
        Map<Long, String> miembros = chat.miembros(h.canal());
        List<Mencion> menciones = Menciones.extraer(t, miembros, politica.mencionMasiva(politica.perfil(u.roles())));
        long nuevo = tx.execute(s -> {
            chat.contextoAuditoria(u.sub());
            long msg = insertar(h.canal(), u.id(), t, adj, respuesta, clientId);
            chat.guardarMenciones(msg, menciones);
            repo.vincularRespuesta(id, msg);
            repo.seguir(id, u.id(), true);
            chat.actualizarMiembro(h.canal(), u.id(), "ultimo_leido_msg = :m, marcado_no_leido = FALSE",
                    Map.of("m", msg));
            return msg;
        });
        difundirRespuesta(h, "respuesta.creada", nuevo);
        bus.publicar(topico(h.canal()), "publicacion.actualizada", neutra(id));
        String titulo = detalle(h, null).titulo();
        String aviso = cuerpoAviso(t, adj);
        Set<Long> avisados = notificarMenciones(u, h.canal(), id, nuevo, titulo, aviso, menciones, miembros, Set.of());
        notificarSeguidores(u, h, nuevo, titulo, aviso, original, avisados);
        return uno(nuevo, u);
    }

    /**
     * Quita el archivo del cuerpo o de una respuesta con las mismas reglas que
     * eliminar ese mensaje: su autor o la moderacion del foro (en el chat, solo el
     * autor). El binario deja de verse en file-service ({@code adjunto_eliminado_en}).
     */
    public Mensaje quitarAdjunto(Usuario u, long mensaje) {
        long id = repo.hiloDeMensaje(mensaje).orElseThrow(() -> new ApiError(404, "El mensaje ya no existe."));
        HiloBase h = hilo(id);
        Membresia m = exigirForo(u, h.canal());
        MensajeBase base = chat.mensajeBase(mensaje).filter(x -> !x.eliminado())
                .orElseThrow(() -> new ApiError(404, "El mensaje ya no existe."));
        if (base.autor() != u.id() && !esModerador(u, m)) {
            throw new ApiError(403, "Solo quien lo escribio o un moderador quita el archivo.");
        }
        if (base.adjunto() == null) throw new ApiError(404, "El mensaje no tiene archivo.");
        escribir(u, () -> chat.quitarAdjunto(mensaje));
        if (mensaje == h.raiz()) {
            bus.publicar(topico(h.canal()), "publicacion.actualizada", neutra(id));
        } else {
            difundirRespuesta(h, "respuesta.actualizada", mensaje);
        }
        return uno(mensaje, u);
    }

    /** Quien la escribio o un moderador (en el chat solo el autor). */
    public Mensaje eliminarRespuesta(Usuario u, long mensaje) {
        long id = repo.hiloDeMensaje(mensaje).orElseThrow(() -> new ApiError(404, "El mensaje ya no existe."));
        HiloBase h = hilo(id);
        if (mensaje == h.raiz()) throw new ApiError(400, "Para quitar el cuerpo elimina la publicacion.");
        Membresia m = exigirForo(u, h.canal());
        MensajeBase base = chat.mensajeBase(mensaje).filter(x -> !x.eliminado())
                .orElseThrow(() -> new ApiError(404, "El mensaje ya no existe."));
        if (base.autor() != u.id() && !esModerador(u, m)) {
            throw new ApiError(403, "Solo quien respondio o un moderador elimina la respuesta.");
        }
        Mensaje antes = uno(mensaje, u);
        List<Long> citan = chat.respuestasA(mensaje);
        escribir(u, () -> {
            chat.eliminarMensaje(mensaje, u.id());
            repo.olvidarSolucion(mensaje);
        });
        bus.publicar(topico(h.canal()), "respuesta.eliminada", Map.of("id", mensaje, "publicacionId", id));
        for (Long r : citan) difundirRespuesta(h, "respuesta.actualizada", r);
        bus.publicar(topico(h.canal()), "publicacion.actualizada", neutra(id));
        return antes;
    }

    // ── internos ───────────────────────────────────────────────────────────

    static String topico(long canal) {
        return "foro:" + canal;
    }

    static String deepLink(long canal, long hilo, Long mensaje) {
        return "/app/comunicaciones/foros?foro=" + canal + "&publicacion=" + hilo
                + (mensaje == null ? "" : "&mensaje=" + mensaje);
    }

    private Membresia exigirForo(Usuario u, long canal) {
        Membresia m = chat.membresia(canal, u.id()).filter(x -> "FORO".equals(x.tipoCanal()))
                .orElseThrow(() -> new ApiError(404, "El foro no existe."));
        if (m.bloqueado()) throw new ApiError(403, "Te bloquearon en este foro.");
        return m;
    }

    private boolean esModerador(Usuario u, Membresia m) {
        return "ADMIN".equals(m.rol()) || politica.moderaForos(politica.perfil(u.roles()));
    }

    private void exigirModerador(Usuario u, Membresia m) {
        if (!esModerador(u, m)) throw new ApiError(403, "Solo la moderacion del foro puede hacerlo.");
    }

    private HiloBase hilo(long id) {
        return repo.hiloBase(id).orElseThrow(() -> new ApiError(404, "La publicacion ya no existe."));
    }

    private Publicacion detalle(HiloBase h, Long visor) {
        Set<Long> online = presencia.enLinea(Set.of(h.autor()));
        Publicacion p = repo.publicacion(h.id(), visor, online)
                .orElseThrow(() -> new ApiError(404, "La publicacion ya no existe."));
        Mensaje raiz = chat.mensajes(List.of(h.raiz()), visor, online).stream().findFirst().orElse(null);
        return new Publicacion(p.id(), p.foroId(), p.titulo(), p.autor(), p.esPropia(), p.fecha(),
                p.ultimaActividad(), p.respuestas(), p.reacciones(), p.fijada(), p.cerrada(), p.resuelta(),
                p.solucionId(), p.etiquetas(), p.siguiendo(), p.extracto(), 1, raiz);
    }

    /** Forma difundida: sin {@code esPropia}/{@code siguiendo} del que escribio. */
    private Publicacion neutra(long hilo) {
        return detalle(hilo(hilo), null);
    }

    private Publicacion actualizada(HiloBase h, Usuario u) {
        bus.publicar(topico(h.canal()), "publicacion.actualizada", neutra(h.id()));
        return detalle(h, u.id());
    }

    private void difundirRespuesta(HiloBase h, String evento, long mensaje) {
        chat.mensajes(List.of(mensaje), null, Set.of()).stream().findFirst()
                .ifPresent(x -> bus.publicar(topico(h.canal()), evento, new RespuestaEvento(h.id(), x)));
    }

    private Mensaje uno(long id, Usuario u) {
        return chat.mensajes(List.of(id), u.id(), Set.of()).stream().findFirst()
                .orElseThrow(() -> new ApiError(404, "El mensaje ya no existe."));
    }

    private void escribir(Usuario u, Runnable r) {
        tx.executeWithoutResult(s -> {
            chat.contextoAuditoria(u.sub());
            r.run();
        });
    }

    private static String titulo(String titulo) {
        String t = titulo == null ? "" : titulo.trim();
        if (t.isEmpty()) throw new ApiError(400, "Escribe un titulo para la publicacion.");
        if (t.length() > MAX_TITULO) throw new ApiError(400, "El titulo es demasiado largo.");
        return t;
    }

    private static String texto(String texto, boolean conAdjunto) {
        String t = texto == null ? "" : texto.trim();
        if (t.length() > MAX_TEXTO) throw new ApiError(400, "El mensaje es demasiado largo.");
        if (t.isEmpty() && !conAdjunto) throw new ApiError(400, "Escribe un mensaje o adjunta un archivo.");
        return t;
    }

    private long insertar(long canal, long autor, String texto, AdjuntosChat.Archivo adj, Long respuesta,
                          UUID clientId) {
        return chat.insertarMensaje(canal, autor, "NORMAL", texto, adj == null ? null : adj.nombre(),
                adj == null ? null : adj.formato(), adj == null ? null : adj.id(), adj == null ? null : adj.peso(),
                respuesta, clientId);
    }

    /** Un mensaje solo con archivo avisa con su nombre, como el chat. */
    private static String cuerpoAviso(String texto, AdjuntosChat.Archivo adj) {
        return texto.isEmpty() && adj != null ? "Adjunto: " + adj.nombre() : texto;
    }

    /** Etiquetas del mismo foro; las "solo moderadores" solo las pone la moderacion. */
    private Set<Long> etiquetasValidas(Usuario u, Membresia m, long canal, List<Long> ids) {
        Set<Long> out = new LinkedHashSet<>();
        if (ids == null) return out;
        boolean moderador = esModerador(u, m);
        for (Long id : ids) {
            if (id == null) continue;
            var e = repo.etiquetaBase(id).filter(x -> x.canal() == canal)
                    .orElseThrow(() -> new ApiError(400, "Una etiqueta no pertenece a este foro."));
            if (e.soloModeradores() && !moderador) {
                throw new ApiError(403, "Esa etiqueta solo la pone la moderacion del foro.");
            }
            out.add(id);
        }
        if (out.size() > MAX_ETIQUETAS) throw new ApiError(400, "Usa como maximo " + MAX_ETIQUETAS + " etiquetas.");
        return out;
    }

    private Set<Long> silenciados(long canal) {
        Set<Long> out = new LinkedHashSet<>();
        for (var f : chat.miembrosDetalle(canal)) {
            if (f.silenciadoHasta() != null && f.silenciadoHasta().toInstant().isAfter(Instant.now())) out.add(f.id());
        }
        return out;
    }

    /** {@code FORO_MENCION}; devuelve a quienes aviso. */
    private Set<Long> notificarMenciones(Usuario u, long canal, long hilo, long mensaje, String titulo, String texto,
                                         List<Mencion> menciones, Map<Long, String> miembros, Set<Long> excluir) {
        Set<Long> destino = new LinkedHashSet<>();
        for (Mencion x : menciones) {
            if ("USUARIO".equals(x.tipo())) destino.add(x.usuarioId());
            else destino.addAll(miembros.keySet());
        }
        destino.remove(u.id());
        destino.removeAll(excluir);
        destino.removeAll(silenciados(canal));
        enviar(destino, "FORO_MENCION", u.nombre() + " te menciono en «" + corto(titulo, 80) + "»", texto, canal,
                hilo, mensaje, "foro-mencion:" + mensaje, null, u.nombre());
        return destino;
    }

    /** {@code FORO_RESPUESTA}: seguidores y el autor del mensaje citado, menos los ya mencionados. */
    private void notificarSeguidores(Usuario u, HiloBase h, long mensaje, String titulo, String texto,
                                     MensajeBase original, Set<Long> yaAvisados) {
        Set<Long> destino = repo.seguidores(h.id());
        if (original != null) destino.add(original.autor());
        destino.remove(u.id());
        destino.removeAll(yaAvisados);
        destino.removeAll(silenciados(h.canal()));
        destino.retainAll(chat.miembros(h.canal()).keySet());
        enviar(destino, "FORO_RESPUESTA", u.nombre() + " respondio en «" + corto(titulo, 80) + "»", texto,
                h.canal(), h.id(), mensaje, "foro-respuesta:" + mensaje, "foro-respuesta:" + h.id(), u.nombre());
    }

    private void enviar(Set<Long> usuarios, String tipo, String titulo, String texto, long canal, long hilo,
                        long mensaje, String dedupe, String agrupacion, String actor) {
        if (usuarios.isEmpty()) return;
        List<String> correos = new ArrayList<>(chat.correos(usuarios).values());
        notificador.enviar(tipo, correos, titulo, corto(texto, 140), deepLink(canal, hilo, mensaje),
                Map.of("foro", canal, "publicacion", hilo, "mensaje", mensaje), dedupe, agrupacion, actor);
    }

    private static String corto(String t, int max) {
        return t.length() > max ? t.substring(0, max) + "…" : t;
    }
}
