package com.co.eurekatic.ssoadmin.dto;

/**
 * Estado de cuenta de un funcionario por correo. {@code estado} es el nombre
 * de {@code User.UserStatus} ({@code ACTIVE}, {@code PENDING_ACTIVATION},
 * {@code INACTIVE}) o {@link #NOT_FOUND} si no hay cuenta con ese correo.
 */
public record AccountStatusResponse(String correo, String estado) {
    public static final String NOT_FOUND = "NOT_FOUND";
}
