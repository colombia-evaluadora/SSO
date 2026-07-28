package com.co.eurekatic.common.security;

import org.springframework.security.crypto.argon2.Argon2PasswordEncoder;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.DelegatingPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;

import java.util.HashMap;
import java.util.Map;

/**
 * Builds the single {@link PasswordEncoder} every service in the SSO
 * shares. auth-center verifies with it at login, sso-admin hashes with
 * it on activation and password restore, query-service declares it for
 * its own basic-auth surface — if those three drifted apart, a hash
 * written by one would be unverifiable by another.
 *
 * <p><b>Argon2id.</b> New hashes use Argon2id, the algorithm OWASP
 * recommends first for password storage: unlike BCrypt it is
 * memory-hard, so a GPU or ASIC attacker can't trade cheap parallel
 * silicon for speed the way they can against BCrypt's 4 KiB working
 * set.
 *
 * <p><b>Existing BCrypt hashes keep working.</b> The returned encoder
 * is a {@link DelegatingPasswordEncoder}: it reads the {@code {id}}
 * prefix on the stored hash and routes to the matching delegate, so a
 * {@code {bcrypt}$2a$12$...} row from before the migration still
 * verifies. New hashes are written with the {@code {argon2}} prefix,
 * and {@code PasswordUpgradeService} in auth-center rewrites old rows
 * on the owner's next successful login. Nobody is locked out and
 * nobody has to reset a password.
 */
public final class PasswordEncoderFactory {

    /** Prefix {@link DelegatingPasswordEncoder} writes on new hashes. */
    public static final String ARGON2_ID = "argon2";
    public static final String BCRYPT_ID = "bcrypt";

    /*
     * Parámetros de OWASP Password Storage Cheat Sheet (2024) para
     * Argon2id: 19 MiB de memoria, 2 iteraciones, paralelismo 1.
     *
     * saltLength/hashLength 16/32 son los del propio estándar. El
     * coste está calibrado para ~50 ms por verificación en el
     * hardware del servidor: suficiente para que un ataque offline
     * sea caro, y bajo como para no convertir el endpoint de login
     * en un vector de agotamiento de memoria — cada verificación
     * concurrente reserva sus 19 MiB.
     */
    private static final int SALT_LENGTH = 16;
    private static final int HASH_LENGTH = 32;
    private static final int PARALLELISM = 1;
    private static final int MEMORY_KB = 19 * 1024;
    private static final int ITERATIONS = 2;

    private PasswordEncoderFactory() {
    }

    public static PasswordEncoder create() {
        Argon2PasswordEncoder argon = argon2id();
        Map<String, PasswordEncoder> delegates = new HashMap<>();
        delegates.put(ARGON2_ID, argon);
        // Sólo para LEER las filas anteriores a la migración.
        // Coste 12, el que usaba el encoder anterior — tiene
        // que coincidir o los hashes viejos no verificarían.
        delegates.put(BCRYPT_ID, new BCryptPasswordEncoder(12));

        DelegatingPasswordEncoder enc = new DelegatingPasswordEncoder(ARGON2_ID, delegates);
        // Spring Security 7 cambió `defaultPasswordEncoderForMatches` para que
        // sea null por defecto: si `extractId` devuelve algo no registrado
        // (p. ej. un id que no esté en el map), `matches()` cae en
        // `UnmappedIdPasswordEncoder.matchesNonNull`, que tira
        // `IllegalArgumentException("Given that there is no default password
        // encoder configured…")`. Spring Security 6 lo tenía como un
        // UnmappedIdPasswordEncoder que avisaba con NO_PASSWORD_ENCODER_MAPPED.
        // Para mantener el comportamiento "si no hay match exacto, intentar
        // Argon2id antes de tirar" (que es lo que el PasswordUpgradeService
        // necesita para re-hashear las filas viejas), fijamos Argon2id como
        // el fallback. Los hashes BCrypt siguen ruteando por su delegate
        // dedicado.
        enc.setDefaultPasswordEncoderForMatches(argon);
        return enc;
    }

    /**
     * El encoder Argon2id suelto, para el
     * {@code PasswordUpgradeService} y los tests que necesitan
     * comprobar el algoritmo concreto y no el delegante.
     */
    public static Argon2PasswordEncoder argon2id() {
        return new Argon2PasswordEncoder(
                SALT_LENGTH, HASH_LENGTH, PARALLELISM, MEMORY_KB, ITERATIONS);
    }
}
