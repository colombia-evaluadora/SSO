package com.co.eurekatic.auth.web.dto;

/**
 * Una fila de {@code POST /register/{cval,pigse}/funcionario/estado-cuenta}:
 * {@code estado} es ACTIVE | PENDING_ACTIVATION | INACTIVE | NOT_FOUND.
 */
public record EstadoCuentaFuncionarioResponse(String correo, String estado) {}
