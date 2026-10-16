package com.co.eurekatic.comms.chat;

import java.util.List;

/**
 * Formas JSON del chat, iguales a {@code src/features/comunicaciones/chat/api/types.ts}
 * del front (camelCase; las filas viajan en el sobre {@code {rows: [...]}}).
 */
public final class ChatDtos {

    private ChatDtos() { }

    public record Conversacion(long id, String nombre, String tipo, String categoria, int noLeidos,
                               boolean actividadAbierta, boolean esBot, int totalMiembros,
                               List<String> miembrosDestacados, String silenciadoHasta, boolean archivada,
                               String creadoPor, boolean esCreador, int menciones) { }

    public record Autor(long id, String nombre, boolean enLinea) { }

    /**
     * {@code archivoId}: pk_tarchivo en file-service (null en adjuntos viejos solo con nombre);
     * el front lo ve con un token de vista. {@code peso} en bytes.
     */
    public record Adjunto(String nombre, String formato, String eliminadoEn, Long archivoId, Long peso) { }

    /**
     * {@code usuarios}: ids de quienes reaccionaron. Extension al tipo del front
     * para que un evento difundido (igual para todos) permita calcular {@code mia}.
     */
    public record Reaccion(String emoji, int total, boolean mia, List<String> personas, List<Long> usuarios) { }

    public record Cita(long id, String autor, String texto, boolean eliminado) { }

    public record Mencion(String tipo, Long usuarioId, String nombre) { }

    public record Mensaje(long id, long conversacionId, Autor autor, boolean esPropio, String texto, String fecha,
                          Adjunto adjunto, boolean editado, boolean fijado, boolean sistema,
                          List<Reaccion> reacciones, Cita respuestaA, List<Mencion> menciones, boolean meMenciona,
                          VotacionRapida votacion) { }

    public record OpcionVotacion(int id, String etiqueta, int votos) { }

    /**
     * {@code miVoto} null en la forma neutra que se difunde por el socket: el
     * cliente conserva el suyo (un voto no se retira; editar la votacion cambia
     * {@code cierraEn} y reinicia los votos).
     */
    public record VotacionRapida(String pregunta, String tipo, int minutos, String cierraEn,
                                 List<OpcionVotacion> opciones, Integer miVoto) { }

    public record Borrador(long id, long conversacionId, String conversacionNombre, String texto, String estado,
                           String fecha) { }

    public record ArchivoCompartido(long id, long archivoId, long mensajeId, String nombre, String formato, Long peso,
                                    String compartidoPor, boolean esPropio, String fecha, long conversacionId,
                                    String conversacionNombre, boolean enMiCanal, boolean editable) { }

    public record Miembro(long id, String nombre, String rol, boolean enLinea, boolean bloqueado) { }

    public record Persona(long id, String nombre, String correo, String perfil) { }

    public record Politica(Object directos, List<String> mencionesMasivas, boolean pendienteDeAprobacion) { }

    public record Filas<T>(List<T> rows) {
        public static <T> Filas<T> de(T uno) {
            return new Filas<>(List.of(uno));
        }
    }
}
