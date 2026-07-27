package com.co.eurekatic.ssoadmin.exception;

import com.co.eurekatic.common.entity.User.UserStatus;

/**
 * Thrown when a user-lifecycle action is attempted against a
 * user whose current {@link UserStatus} doesn't allow it — e.g.
 * resending an activation email for an already-ACTIVE user, or
 * deactivating a user that's already INACTIVE. Mapped to HTTP
 * 409 Conflict by {@link GlobalExceptionHandler}.
 */
public class InvalidUserStateException extends RuntimeException {
    public InvalidUserStateException(String action, UserStatus actual, UserStatus required) {
        super(action + " requiere que el usuario esté en estado " + label(required)
                + ", pero está en estado " + label(actual));
    }

    /**
     * Etiqueta legible del estado. El nombre del enum viaja en
     * otros campos del API (contrato), así que aquí sólo se
     * traduce el texto que ve la persona usuaria.
     */
    private static String label(UserStatus status) {
        return switch (status) {
            case PENDING_ACTIVATION -> "PENDIENTE DE ACTIVACIÓN";
            case ACTIVE             -> "ACTIVO";
            case INACTIVE           -> "INACTIVO";
        };
    }
}
