package com.co.eurekatic.auth.security;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

/** Tamaño por defecto del semáforo de login: por CPU, acotado por heap. */
class JsonLoginFilterPermitsTest {

    private static final long MIB = 1024L * 1024;

    @Test
    void conHeapHolgadoMandaLaCpu() {
        assertThat(JsonLoginFilter.defaultLoginPermits(4, 4096 * MIB)).isEqualTo(8);
    }

    @Test
    void conMuchosNucleosYPocoHeapMandaLaMemoria() {
        // 128 MiB de heap → la mitad entre el bloque Argon2 (7 MiB) = 9 < 2x16
        assertThat(JsonLoginFilter.defaultLoginPermits(16, 128 * MIB)).isEqualTo(9);
    }

    @Test
    void nuncaMenosDeUnPermiso() {
        assertThat(JsonLoginFilter.defaultLoginPermits(1, 8 * MIB)).isEqualTo(1);
    }
}
