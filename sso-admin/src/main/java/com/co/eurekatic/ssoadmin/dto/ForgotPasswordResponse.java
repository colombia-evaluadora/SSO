package com.co.eurekatic.ssoadmin.dto;

/**
 * Respuesta de {@code GET /forgotPassword}.
 *
 * <p><b>El token de reseteo NO viaja aqui.</b> Sale unicamente por correo,
 * dentro del enlace ({@code /admin/restore-password?token=...}), que es el
 * unico canal que prueba que quien pide el reseteo controla ese buzon.
 *
 * <p>Historia, para que no se vuelva a abrir: entre #67 y este cambio el
 * token si viajaba en el cuerpo, a pedido del equipo, porque la pantalla de
 * confirmacion necesitaba correo enmascarado y cuenta regresiva. El riesgo
 * quedo aceptado por escrito sobre una condicion explicita — que la respuesta
 * fuera identica existiera o no el correo — para que la sola presencia del
 * token no delatara que direcciones estaban registradas. Esa condicion se
 * perdio despues, al agregar el 404 para correos desconocidos, y la
 * combinacion (endpoint publico + oraculo de existencia + token en el cuerpo)
 * permitia apropiarse de cualquier cuenta conociendo solo el correo: pedir el
 * reseteo con la direccion de la victima, leer el token de la respuesta y
 * cambiar la contrasena sin tocar ese buzon.
 *
 * <p>Este record es la alternativa que el propio #67 dejo anotada: entrega lo
 * que la pantalla de confirmacion necesita ({@code maskedEmail} para
 * confirmar a donde se envio, {@code expiresIn} para la cuenta regresiva) sin
 * entregar la credencial. Con esto, el correo enmascarado ya no obliga a
 * llamar a {@code /resetTokenStatus} antes de abrir el correo.
 *
 * @param maskedEmail correo del destinatario enmascarado ({@code a****@dominio}),
 *                    para confirmar a donde se envio sin exponer la direccion
 * @param expiresIn   segundos de vida del enlace enviado por correo
 */
public record ForgotPasswordResponse(String maskedEmail, long expiresIn) {
}
