package com.co.eurekatic.common.security;

import org.junit.jupiter.api.Test;
import org.springframework.security.crypto.argon2.Argon2PasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Cambio de parámetros Argon2id (m=19 MiB/t=2 → m=7 MiB/t=5): los hashes
 * viejos siguen verificando y se marcan para re-hashear en el login.
 */
class PasswordEncoderFactoryTest {

    private static final String PWD = "Contrasena-de-prueba-123";

    @Test
    void hashNuevoUsaLosParametrosVigentesYNoPideUpgrade() {
        PasswordEncoder enc = PasswordEncoderFactory.create();
        String hash = enc.encode(PWD);

        assertThat(hash).startsWith("{argon2}").contains("m=7168").contains("t=5");
        assertThat(enc.matches(PWD, hash)).isTrue();
        assertThat(enc.upgradeEncoding(hash)).isFalse();
    }

    @Test
    void hashArgon2ConParametrosViejosVerificaYPideUpgrade() {
        String viejo = "{argon2}" + new Argon2PasswordEncoder(16, 32, 1, 19 * 1024, 2).encode(PWD);
        PasswordEncoder enc = PasswordEncoderFactory.create();

        assertThat(enc.matches(PWD, viejo)).isTrue();
        assertThat(enc.upgradeEncoding(viejo)).isTrue();
    }
}
