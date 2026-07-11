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
        super(action + " requires status " + required + ", but user is " + actual);
    }
}
