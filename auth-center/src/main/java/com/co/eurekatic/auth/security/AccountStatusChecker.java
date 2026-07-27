package com.co.eurekatic.auth.security;

import com.co.eurekatic.common.entity.User;
import org.springframework.security.authentication.AccountExpiredException;
import org.springframework.security.authentication.DisabledException;
import org.springframework.security.authentication.LockedException;
import org.springframework.security.core.userdetails.UserDetails;
import org.springframework.security.core.userdetails.UserDetailsChecker;

/**
 * Rechaza el login de cuentas que no están en condiciones de
 * autenticarse, con un motivo concreto en vez del genérico
 * "credenciales inválidas".
 *
 * <p><b>El problema que resuelve.</b> Spring Security enmascara a
 * propósito la {@code UsernameNotFoundException} como
 * {@code BadCredentialsException}
 * ({@code hideUserNotFoundExceptions=true}) para no revelar qué
 * correos existen. Como {@code AppUserDetailsService} usaba esa
 * excepción también para las cuentas deshabilitadas, a alguien a
 * quien le habían desactivado la cuenta se le decía que su
 * contraseña era incorrecta. Escribía la contraseña buena, veía
 * "credenciales inválidas", y acababa en soporte.
 *
 * <p>Al ser un {@code preAuthenticationChecks}, esto corre ANTES de
 * verificar la contraseña, igual que el rechazo anterior: una
 * cuenta desactivada no se autentica ni con la contraseña correcta.
 *
 * <p><b>Contrapartida aceptada.</b> Distinguir "inactiva" de
 * "credenciales inválidas" confirma a quien pregunta que ese correo
 * existe en el sistema — es enumeración de usuarios. Se asume
 * deliberadamente: el mensaje honesto le ahorra a la persona
 * afectada un ciclo de soporte, y el registro de altas del SSO no
 * es público. Si algún día hace falta cerrarlo, lo que hay que
 * hacer es devolver el mensaje genérico aquí, no volver a
 * {@code UsernameNotFoundException}.
 */
public class AccountStatusChecker implements UserDetailsChecker {

    @Override
    public void check(UserDetails user) {
        if (!user.isAccountNonLocked()) {
            throw new LockedException("La cuenta está bloqueada. Contacta al administrador.");
        }
        if (!user.isAccountNonExpired()) {
            throw new AccountExpiredException("La cuenta ha expirado. Contacta al administrador.");
        }
        if (!user.isEnabled()) {
            throw new DisabledException(disabledReason(user));
        }
    }

    /**
     * {@code User.isEnabled()} es {@code enabled && active}, y esas
     * dos banderas distinguen dos situaciones que para la persona
     * usuaria no se parecen en nada: una cuenta que un administrador
     * desactivó, y una que se creó pero nunca se activó desde el
     * correo. Decirle "activa tu cuenta" a quien se la acaban de
     * desactivar es tan inútil como decirle "credenciales
     * inválidas".
     */
    private static String disabledReason(UserDetails user) {
        if (user instanceof User u) {
            return switch (u.getStatus()) {
                case INACTIVE -> "Tu cuenta fue inactivada. Contacta al administrador.";
                case PENDING_ACTIVATION -> "Tu cuenta aún no ha sido activada. "
                        + "Revisa el correo de activación que te enviamos.";
                // Inalcanzable: isEnabled() sólo es false en los dos
                // estados de arriba. Se cubre para que añadir un
                // estado nuevo al enum sea un error de compilación
                // aquí y no un mensaje engañoso en producción.
                case ACTIVE -> "La cuenta no está disponible. Contacta al administrador.";
            };
        }
        return "La cuenta no está disponible. Contacta al administrador.";
    }
}
