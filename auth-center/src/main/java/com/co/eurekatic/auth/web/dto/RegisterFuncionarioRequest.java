package com.co.eurekatic.auth.web.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;

public record RegisterFuncionarioRequest(
    @NotNull @Valid RegisterUsuarioRequest usuario,
    @NotNull @Positive Long fkTmunicipioExpedicion
) {}
