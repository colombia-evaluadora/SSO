package com.co.eurekatic.ssoadmin.dto;

import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;

/** Cuerpo de {@code POST /internal/funcionario/estado-cuenta}. */
public record AccountStatusRequest(@NotNull @Size(max = 200) List<String> correos) {}
