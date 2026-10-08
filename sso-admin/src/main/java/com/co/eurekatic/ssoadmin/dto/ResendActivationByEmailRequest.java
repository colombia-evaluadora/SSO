package com.co.eurekatic.ssoadmin.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/** Cuerpo de {@code POST /internal/funcionario/reenviar-activacion}. */
public record ResendActivationByEmailRequest(@NotBlank @Size(max = 200) String correo) {}
