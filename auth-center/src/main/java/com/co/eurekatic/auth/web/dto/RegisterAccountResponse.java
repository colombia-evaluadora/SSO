package com.co.eurekatic.auth.web.dto;

import java.util.List;

/**
 * @param passwordTemporal true si la cuenta quedó con una contraseña derivada
 *        por el servidor y hay que cambiarla. False cuando se reutilizó una
 *        cuenta que ya existía, cuya contraseña no se toca.
 * @param passwordOrigen   {@code DANE} si se derivó del código del
 *        establecimiento, {@code DEFAULT} si se usó la del servidor,
 *        {@code NINGUNO} si la cuenta ya existía.
 */
public record RegisterAccountResponse(
        Long idUser,
        String email,
        List<String> roleNames,
        boolean passwordTemporal,
        String passwordOrigen
) {}
