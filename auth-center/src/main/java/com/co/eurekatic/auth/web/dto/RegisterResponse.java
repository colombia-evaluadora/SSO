package com.co.eurekatic.auth.web.dto;

/**
 * Respuesta de las altas de {@code /register/**}.
 *
 * <p>{@code invitacionEnviada}: el alta de funcionario sin contrasena deja la
 * cuenta en PENDING_ACTIVATION y manda {@code account-activation} al correo.
 * Es {@code true} solo si ese correo salio. {@code mensajeInvitacion} va
 * distinto de {@code null} solo cuando hacia falta invitar y no se pudo (fallo
 * del envio, o cuenta de baja que un administrador debe reactivar): el front
 * lo muestra como aviso. Con contrasena (contrato anterior) o cuando la
 * persona ya tenia una cuenta activa, ambos quedan en false / null.
 */
public record RegisterResponse(
    Long idUser,
    Long pkTusuario,
    Long pkFuncionario,
    String email,
    boolean invitacionEnviada,
    String mensajeInvitacion
) {
    public RegisterResponse(Long idUser, Long pkTusuario, Long pkFuncionario, String email) {
        this(idUser, pkTusuario, pkFuncionario, email, false, null);
    }
}
