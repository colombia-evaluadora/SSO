package com.co.eurekatic.ssoadmin.dto;

/**
 * V-ente-admin — fila de {@code academico_test.TROL} para el selector
 * del bind. {@code codigo} es lo que {@code fn_sincronizar_rol_publico}
 * concatena con {@code CEVAL-}/{@code PIGSE-} para resolver el rol de
 * {@code public.role} a otorgar.
 */
public record TrolResponse(Long id, String codigo, String nombre) {}
