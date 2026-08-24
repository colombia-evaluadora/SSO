package com.co.eurekatic.ssoadmin.dto;

/**
 * Respuesta de {@code GET /forgotPassword}.
 *
 * <p><b>Advertencia de seguridad.</b> Devolver el token de reseteo en el
 * cuerpo HTTP permite que cualquiera que pueda llamar a este endpoint tome
 * control de una cuenta ajena: pide el reseteo con el correo de la victima,
 * lee el token de la respuesta y cambia la contrasena sin acceder jamas a ese
 * buzon. El diseno original lo entregaba SOLO por correo, y esa era la razon.
 *
 * <p>Se expone a pedido explicito del equipo, para que la pantalla de
 * confirmacion del front pueda mostrar el estado del enlace. Si eso es lo
 * unico que hace falta, la alternativa sin este riesgo es devolver
 * {@code maskedEmail} y {@code expiresIn} SIN el token.
 *
 * <p>El token viaja SIEMPRE, exista el correo o no (ver
 * {@code UserAdminService#forgotPassword}): si solo apareciera para correos
 * registrados, la respuesta delataria que direcciones estan dadas de alta.
 *
 * @param token     token de reseteo de un solo uso
 * @param expiresIn segundos de vida del token
 */
public record ForgotPasswordResponse(String token, long expiresIn) {
}
