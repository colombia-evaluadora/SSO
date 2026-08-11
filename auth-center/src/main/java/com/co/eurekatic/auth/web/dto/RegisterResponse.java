package com.co.eurekatic.auth.web.dto;

public record RegisterResponse(
    Long idUser,
    Long pkTusuario,
    Long pkFuncionario,
    String email
) {}
