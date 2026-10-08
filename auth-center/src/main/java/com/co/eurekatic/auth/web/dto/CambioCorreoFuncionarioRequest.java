package com.co.eurekatic.auth.web.dto;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/** Cuerpo de {@code POST /register/{cval,pigse}/funcionario/reactivar-por-cambio-de-correo}. */
public record CambioCorreoFuncionarioRequest(
        @NotBlank @Email @Size(max = 200) String correoAnterior,
        @NotBlank @Email @Size(max = 200) String correoNuevo
) {}
