package com.co.eurekatic.ssoadmin.dto;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;

/**
 * Request body for {@code PUT /updateAccount}. The lookup
 * key is now {@code id} (the user's numeric PK). Email was
 * the lookup key under the old "username" identifier, but
 * email is mutable so it's not stable across the lifetime of
 * a user. The numeric id is.
 *
 * <p>All other fields are optional. {@code null} fields are
 * left unchanged. {@code roleNames}, when present, REPLACES
 * the user's current role set (additive/remove on a
 * per-role basis isn't supported through this endpoint).
 */
public record UpdateAccountRequest(
        @NotNull Long id,
        @Size(max = 200) String fullName,
        @Email @Size(max = 200) String email,
        Boolean active,
        Boolean ldap,
        /** If non-null, replaces the user's role set. */
        List<@NotBlank String> roleNames
) {}
