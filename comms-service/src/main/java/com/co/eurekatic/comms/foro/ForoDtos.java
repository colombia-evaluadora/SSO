package com.co.eurekatic.comms.foro;

import com.co.eurekatic.comms.chat.ChatDtos.Autor;
import com.co.eurekatic.comms.chat.ChatDtos.Mensaje;

import java.util.List;

/**
 * Formas JSON de los foros, iguales a {@code src/features/comunicaciones/foros/api/types.ts}
 * del front (camelCase, en el sobre {@code {rows}}). El cuerpo y las respuestas
 * reutilizan {@link Mensaje} del chat: reacciones, menciones y adjuntos iguales.
 */
public final class ForoDtos {

    private ForoDtos() { }

    public record Etiqueta(long id, String nombre, String color, boolean soloModeradores) { }

    /** Cabecera del foro con lo que el usuario puede hacer en el. */
    public record Foro(long id, String nombre, int totalMiembros, List<Etiqueta> etiquetas,
                       boolean puedePublicar, boolean puedeResponder, boolean puedeModerar) { }

    /**
     * {@code mensaje}: el cuerpo, solo en el detalle. {@code totalCount} se repite en
     * cada fila del listado (paginacion 0-based). {@code esPropia} y {@code siguiendo}
     * van en false en los eventos difundidos: el cliente los conserva o calcula.
     */
    public record Publicacion(long id, long foroId, String titulo, Autor autor, boolean esPropia, String fecha,
                              String ultimaActividad, int respuestas, int reacciones, boolean fijada,
                              boolean cerrada, boolean resuelta, Long solucionId, List<Etiqueta> etiquetas,
                              boolean siguiendo, String extracto, int totalCount, Mensaje mensaje) { }

    /** Evento {@code respuesta.creada|actualizada} del topico {@code foro:<id>}. */
    public record RespuestaEvento(long publicacionId, Mensaje mensaje) { }
}
