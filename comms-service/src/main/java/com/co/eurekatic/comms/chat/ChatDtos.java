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

    public record Adjunto(String nombre, String formato, String eliminadoEn) { }

    /**
     * {@code usuarios}: ids de quienes reaccionaron. Extension al tipo del front
     * para que un evento difundido (igual para todos) permita calcular {@code mia}.
     */
    public record Reaccion(String emoji, int total, boolean mia, List<String> personas, List<Long> usuarios) { }

    public record Cita(long id, String autor, String texto, boolean eliminado) { }

    public record Mencion(String tipo, Long usuarioId, String nombre) { }

    public record Mensaje(long id, long conversacionId, Autor autor, boolean esPropio, String texto, String fecha,
                          Adjunto adjunto, boolean editado, boolean fijado, boolean sistema,
                          List<Reaccion> reacciones, Cita respuestaA, List<Mencion> menciones, boolean meMenciona) { }

    public record Miembro(long id, String nombre, String rol, boolean enLinea, boolean bloqueado) { }

    public record Persona(long id, String nombre, String correo, String perfil) { }

    public record Politica(Object directos, List<String> mencionesMasivas, boolean pendienteDeAprobacion) { }

    public record Filas<T>(List<T> rows) {
        public static <T> Filas<T> de(T uno) {
            return new Filas<>(List.of(uno));
        }
    }
}
