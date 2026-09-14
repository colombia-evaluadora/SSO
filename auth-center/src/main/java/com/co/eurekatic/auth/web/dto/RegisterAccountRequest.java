package com.co.eurekatic.auth.web.dto;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.Positive;
import jakarta.validation.constraints.Size;

import java.util.List;

/**
 * Alta de una cuenta del SSO con los roles que se le asignan de entrada.
 *
 * <p>Sin contraseña a propósito: la deriva el servidor. Si viene
 * {@code establecimientoId}, se genera a partir del código DANE de ese
 * establecimiento; si no, se usa la contraseña por defecto del servidor.
 * Que la eligiera quien da el alta significaría que un tercero conoce la
 * credencial de otra persona.
 */
public record RegisterAccountRequest(
        @NotBlank @Email @Size(max = 200) String email,
        @NotBlank @Size(max = 200) String fullName,
        @NotEmpty List<@NotBlank @Size(max = 140) String> roleNames,
        @Positive Long establecimientoId
) {}
