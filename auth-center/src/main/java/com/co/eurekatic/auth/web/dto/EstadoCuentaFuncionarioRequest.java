package com.co.eurekatic.auth.web.dto;

import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;

/** Cuerpo de {@code POST /register/{cval,pigse}/funcionario/estado-cuenta}. */
public record EstadoCuentaFuncionarioRequest(@NotNull @Size(max = 200) List<String> correos) {}
