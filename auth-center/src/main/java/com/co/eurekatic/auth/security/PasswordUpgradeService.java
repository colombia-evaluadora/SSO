package com.co.eurekatic.auth.security;

import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.UserRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.security.core.userdetails.UserDetails;
import org.springframework.security.core.userdetails.UserDetailsPasswordService;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Reescribe a Argon2id los hashes BCrypt heredados, en el momento en
 * que su dueño hace login correctamente.
 *
 * <p><b>Cómo se dispara.</b> No lo llamamos nosotros:
 * {@code DaoAuthenticationProvider} invoca
 * {@link #updatePassword(UserDetails, String)} después de validar la
 * contraseña y sólo si
 * {@code PasswordEncoder.upgradeEncoding(hashGuardado)} devuelve
 * {@code true}. Con el {@code DelegatingPasswordEncoder} de
 * {@code PasswordEncoderFactory} eso ocurre exactamente cuando el
 * prefijo almacenado no es el algoritmo por defecto — es decir,
 * cuando la fila sigue en {@code {bcrypt}}.
 *
 * <p>Que sea el framework quien lo llame es lo que hace segura la
 * operación: en ese punto la contraseña en claro ya se verificó, y
 * Spring nos entrega el hash NUEVO ya calculado. Nunca vemos ni
 * guardamos el texto plano, y un login fallido no llega hasta aquí.
 *
 * <p>Consecuencia operativa: la base migra sola, al ritmo al que la
 * gente entra. Las cuentas que nunca vuelvan a entrar conservarán su
 * hash BCrypt indefinidamente — siguen siendo válidas, sólo que con
 * el algoritmo antiguo. Si algún día se quiere forzar el cierre de
 * la migración, la consulta
 * {@code SELECT email FROM users WHERE password LIKE '{bcrypt}%'}
 * da la lista exacta de cuentas pendientes.
 */
@Service
public class PasswordUpgradeService implements UserDetailsPasswordService {

    private static final Logger log = LoggerFactory.getLogger(PasswordUpgradeService.class);

    private final UserRepository userRepository;

    public PasswordUpgradeService(UserRepository userRepository) {
        this.userRepository = userRepository;
    }

    @Override
    @Transactional
    public UserDetails updatePassword(UserDetails user, String newPassword) {
        String email = user.getUsername();
        return userRepository.findByEmail(email)
                .map(entity -> persist(entity, newPassword))
                .orElseGet(() -> {
                    // La fila desapareció entre la autenticación y este
                    // punto (borrado concurrente). No es motivo para
                    // tumbar un login ya validado: se devuelve el
                    // UserDetails original y el hash se migrará en el
                    // siguiente intento, si es que la cuenta existe.
                    log.warn("No se pudo migrar el hash a Argon2id: el usuario ya no existe");
                    return user;
                });
    }

    private UserDetails persist(User entity, String newPassword) {
        entity.setPassword(newPassword);
        User saved = userRepository.save(entity);
        log.info("Hash de contraseña migrado a Argon2id para el usuario id={}", saved.getId());
        return saved;
    }
}
