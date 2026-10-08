package com.co.eurekatic.auth.web.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/** Cuerpo de {@code POST /register/{cval,pigse}/funcionario/reenviar-activacion}. */
public record ReenviarActivacionFuncionarioRequest(@NotBlank @Size(max = 200) String correo) {}
