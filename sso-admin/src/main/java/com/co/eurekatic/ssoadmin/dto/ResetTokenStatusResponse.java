package com.co.eurekatic.ssoadmin.dto;

/**
 * Estado de un enlace de reseteo, para la pantalla de confirmacion del front
 * ("te enviamos instrucciones" / "el enlace expiro").
 *
 * <p>Se responde lo ya resuelto, no los datos crudos: la UI no deberia tener
 * que decidir si un enlace sirve comparando fechas contra el reloj del
 * navegador, que puede estar corrido.
 *
 * <p><b>No revela nada que el portador del token no sepa ya.</b> El correo va
 * enmascarado y un token inexistente devuelve {@code invalid} sin
 * {@code maskedEmail}, asi que no sirve para averiguar direcciones ajenas:
 * hay que tener el token —que llega por correo— para obtener cualquier dato.
 *
 * @param status      {@code valid}, {@code expired} o {@code invalid}
 * @param expiresIn   segundos restantes; 0 si vencio o el token no existe
 * @param ttlSeconds  vida total del enlace, para decir "vence a los N minutos"
 * @param maskedEmail correo destino enmascarado; ausente si el token no existe
 * @param issuedAt    epoch ms en que se emitio; ausente si el token no existe
 */
public record ResetTokenStatusResponse(
        String status,
        long expiresIn,
        long ttlSeconds,
        String maskedEmail,
        Long issuedAt) {
}
