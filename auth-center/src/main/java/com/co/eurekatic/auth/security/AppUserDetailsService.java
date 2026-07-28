package com.co.eurekatic.auth.security;

import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.UserRepository;
import org.springframework.security.core.userdetails.UserDetails;
import org.springframework.security.core.userdetails.UserDetailsService;
import org.springframework.security.core.userdetails.UsernameNotFoundException;
import org.springframework.stereotype.Service;

/**
 * Bridges the {@code common} User entity to Spring Security's
 * {@link UserDetailsService} contract. Returns the {@code User} entity
 * directly because it already implements {@code UserDetails} (see
 * {@code common.entity.User}).
 */
@Service
public class AppUserDetailsService implements UserDetailsService {

    private final UserRepository userRepository;

    public AppUserDetailsService(UserRepository userRepository) {
        this.userRepository = userRepository;
    }

    @Override
    public UserDetails loadUserByUsername(String email) throws UsernameNotFoundException {
        // The parameter is named "username" only because the
        // UserDetailsService interface mandates that name. We treat
        // it as an email (the unique login identifier since the
        // V12 migration).
        // El rechazo de cuentas deshabilitadas ya NO se hace aquí.
        // Lanzar UsernameNotFoundException para una cuenta inactiva
        // hacía que DaoAuthenticationProvider la enmascarase como
        // BadCredentialsException (hideUserNotFoundExceptions=true),
        // y el usuario veía "credenciales inválidas" cuando su
        // contraseña era correcta y lo que pasaba era que le habían
        // desactivado la cuenta.
        //
        // Ahora devolvemos la entidad y es AccountStatusChecker
        // (registrado como preAuthenticationChecks) quien rechaza,
        // con un mensaje que distingue "inactivada" de "sin activar".
        // Sigue ocurriendo ANTES de comprobar la contraseña, así que
        // una cuenta deshabilitada no puede autenticarse aunque la
        // contraseña sea válida.
        return userRepository.findByEmail(email)
                .orElseThrow(() -> new UsernameNotFoundException("No se encontró el usuario: " + email));
    }
}
