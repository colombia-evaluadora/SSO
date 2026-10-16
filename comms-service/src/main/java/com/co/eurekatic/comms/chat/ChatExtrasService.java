package com.co.eurekatic.comms.chat;

import com.co.eurekatic.comms.chat.ChatDtos.ArchivoCompartido;
import com.co.eurekatic.comms.chat.ChatDtos.Borrador;
import com.co.eurekatic.comms.chat.ChatDtos.Conversacion;
import com.co.eurekatic.comms.chat.ChatDtos.Mensaje;
import com.co.eurekatic.comms.chat.ChatDtos.Miembro;
import com.co.eurekatic.comms.security.Usuario;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionTemplate;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Set;

/**
 * Lo que el chat agrego sobre el MVP: borradores por canal, archivos
 * compartidos, duplicar canal y votacion rapida. Mismas reglas de membresia
 * y de tiempo real que {@link ChatService}, de quien reutiliza los chequeos.
 */
@Service
public class ChatExtrasService {

    static final Set<String> TIPOS_VOTACION = Set.of("SI_NO", "VERDADERO_FALSO");
    private static final int MAX_TEXTO = 4000;
    private static final int MAX_PREGUNTA = 300;

    private final ChatService chat;
    private final ChatRepository repo;
    private final ChatExtrasRepository extras;
    private final TransactionTemplate tx;

    public ChatExtrasService(ChatService chat, ChatRepository repo, ChatExtrasRepository extras, TransactionTemplate tx) {
        this.chat = chat;
        this.repo = repo;
        this.extras = extras;
        this.tx = tx;
    }

    // ── borradores ─────────────────────────────────────────────────────────

    public List<Borrador> borradores(Usuario u) {
        return extras.borradores(u.id());
    }

    /** Guarda lo que quedo escrito en el editor del canal; texto vacio lo descarta. */
    public List<Borrador> guardarBorrador(Usuario u, long canal, String texto) {
        chat.exigirMiembro(u, canal);
        String t = texto == null ? "" : texto.trim();
        if (t.length() > MAX_TEXTO) throw new ApiError(400, "El mensaje es demasiado largo.");
        if (t.isEmpty()) {
            chat.escribir(u, () -> extras.descartarBorradorDeCanal(canal, u.id()));
            return List.of();
        }
        Long id = tx.execute(s -> {
            repo.contextoAuditoria(u.sub());
            return extras.guardarBorrador(canal, u.id(), t);
        });
        return List.of(extras.borrador(id).orElseThrow());
    }

    public Borrador enviarBorrador(Usuario u, long id) {
        Borrador b = propio(u, id);
        if (!"BORRADOR".equals(b.estado())) throw new ApiError(409, "Ese mensaje ya se envio.");
        // enviar() marca el borrador como ENVIADO dentro de su transaccion.
        chat.enviar(u, b.conversacionId(), b.texto(), null, null, null);
        return extras.borrador(id).orElseThrow();
    }

    public Borrador eliminarBorrador(Usuario u, long id) {
        Borrador b = propio(u, id);
        chat.escribir(u, () -> extras.eliminarBorrador(id));
        return b;
    }

    private Borrador propio(Usuario u, long id) {
        long dueno = extras.duenoBorrador(id).orElseThrow(() -> new ApiError(404, "El borrador no existe."));
        if (dueno != u.id()) throw new ApiError(404, "El borrador no existe.");
        return extras.borrador(id).orElseThrow(() -> new ApiError(404, "El borrador no existe."));
    }

    // ── archivos ───────────────────────────────────────────────────────────

    public List<ArchivoCompartido> archivos(Usuario u) {
        return extras.archivos(u.id());
    }

    /** Quita el adjunto para todos; el mensaje conserva el aviso "Archivo eliminado". */
    public ArchivoCompartido eliminarArchivo(Usuario u, long archivoId) {
        ArchivoCompartido a = extras.archivo(archivoId, u.id())
                .orElseThrow(() -> new ApiError(404, "El archivo ya no existe."));
        if (!a.esPropio()) throw new ApiError(403, "Solo puedes eliminar archivos que compartiste tú.");
        chat.quitarAdjunto(u, a.mensajeId());
        return a;
    }

    // ── duplicar ───────────────────────────────────────────────────────────

    /** Copia del canal (nombre, categoria y miembros) administrada por quien la pide. */
    public Conversacion duplicar(Usuario u, long canal) {
        chat.exigirAdmin(u, canal);
        Conversacion original = repo.conversacion(canal, u.id())
                .orElseThrow(() -> new ApiError(404, "La conversacion no existe."));
        List<Long> miembros = chat.miembros(u, canal).stream()
                .filter(m -> !m.bloqueado() && m.id() != u.id()).map(Miembro::id).toList();
        return chat.crearCanal(u, nombreLibre(original.nombre(), u.establecimiento()), original.categoria(), miembros);
    }

    private String nombreLibre(String nombre, String establecimiento) {
        for (int i = 1; i < 100; i++) {
            String sufijo = i == 1 ? " (copia)" : " (copia " + i + ")";
            String base = nombre.length() + sufijo.length() > 100 ? nombre.substring(0, 100 - sufijo.length()) : nombre;
            if (!repo.existeNombre(base + sufijo, establecimiento, null)) return base + sufijo;
        }
        throw new ApiError(409, "Ya hay demasiadas copias de este canal.");
    }

    // ── votacion rapida ────────────────────────────────────────────────────

    public Mensaje crearVotacion(Usuario u, long canal, String pregunta, String tipo, Integer minutos) {
        chat.exigirAdmin(u, canal);
        String p = validarVotacion(pregunta, tipo, minutos);
        long id = tx.execute(s -> {
            repo.contextoAuditoria(u.sub());
            long nuevo = repo.insertarMensaje(canal, u.id(), "NORMAL", "", null, null, null, null);
            extras.crearVotacion(nuevo, p, tipo, minutos);
            repo.actualizarMiembro(canal, u.id(), "ultimo_leido_msg = :m", java.util.Map.of("m", nuevo));
            return nuevo;
        });
        chat.difundir(canal, "mensaje.creado", id);
        chat.refrescarListas(canal, repo.miembros(canal).keySet(), u.id());
        return chat.uno(id, u);
    }

    public Mensaje editarVotacion(Usuario u, long mensaje, String pregunta, String tipo, Integer minutos) {
        var m = chat.propio(u, mensaje, "Solo quien creo la votacion puede cambiarla.");
        abierta(mensaje);
        String p = validarVotacion(pregunta, tipo, minutos);
        chat.escribir(u, () -> extras.reemplazarVotacion(mensaje, p, tipo, minutos));
        chat.difundir(m.canal(), "mensaje.actualizado", mensaje);
        return chat.uno(mensaje, u);
    }

    public Mensaje votar(Usuario u, long mensaje, Integer opcion) {
        var m = chat.visible(u, mensaje);
        abierta(mensaje);
        if (opcion == null || opcion < 1 || opcion > 2) throw new ApiError(400, "Elige una opción.");
        boolean nuevo = Boolean.TRUE.equals(tx.execute(s -> extras.votar(mensaje, u.id(), opcion)));
        if (!nuevo) throw new ApiError(409, "Ya votaste.");
        chat.difundir(m.canal(), "mensaje.actualizado", mensaje);
        return chat.uno(mensaje, u);
    }

    private void abierta(long mensaje) {
        OffsetDateTime cierre = extras.cierreVotacion(mensaje)
                .orElseThrow(() -> new ApiError(404, "El mensaje ya no existe."));
        if (!cierre.isAfter(OffsetDateTime.now())) throw new ApiError(409, "La votación ya se cerró.");
    }

    private static String validarVotacion(String pregunta, String tipo, Integer minutos) {
        String p = pregunta == null ? "" : pregunta.trim();
        if (p.isEmpty()) throw new ApiError(400, "Escribe la pregunta.");
        if (p.length() > MAX_PREGUNTA) throw new ApiError(400, "La pregunta es demasiado larga.");
        if (tipo == null || !TIPOS_VOTACION.contains(tipo)) throw new ApiError(400, "Tipo de votación desconocido.");
        if (minutos == null || minutos < 1 || minutos > 1440) throw new ApiError(400, "Duración de la votación inválida.");
        return p;
    }
}
