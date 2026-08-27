package com.co.eurekatic.ssoadmin.dto;

import jakarta.validation.constraints.NotNull;

/**
 * V-ente-admin — da de alta un usuario de Ente Territorial
 * (academico_test.TENTE_USUARIO), espejo del bind por sede que ya
 * existe para establecimientos. Ver
 * {@code academico_test.fn_ente_usuario_crear} (V150): la llamada
 * otorga automáticamente CEVAL-&lt;codigo&gt; y PIGSE-&lt;codigo&gt;
 * en {@code role_users} (fn_sincronizar_rol_publico), sin que este
 * endpoint tenga que saber nada de esos catálogos.
 *
 * <p>{@code tlvEstado}/{@code predeterminado} son opcionales — la
 * función los defaultea a {@code "ACTIVO"}/{@code 0}, igual que el
 * resto de los flujos de bind de este módulo.
 */
public record EnteUsuarioRequest(
        @NotNull Long fkTente,
        @NotNull Long fkRol,
        @NotNull Long fkUsuario,
        String tlvEstado,
        Integer predeterminado
) {}
