package com.co.eurekatic.ssoadmin.dto;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * Cuerpo de {@code POST /funcionario/reactivar-por-cambio-de-correo}.
 *
 * <p>Se piden AMBOS correos a proposito: el servicio solo reactiva si el
 * cambio ya ocurrio de verdad (la cuenta existe con {@code correoNuevo} y ya
 * no existe ninguna con {@code correoAnterior}). Asi el endpoint no sirve
 * para mandar a PENDING_ACTIVATION una cuenta ajena cualquiera.
 */
public record EmailChangeReactivationRequest(
        @NotBlank @Email @Size(max = 200) String correoAnterior,
        @NotBlank @Email @Size(max = 200) String correoNuevo
) {}
