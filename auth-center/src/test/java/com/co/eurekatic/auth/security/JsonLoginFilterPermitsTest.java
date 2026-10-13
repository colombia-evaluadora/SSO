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
        // heap de auth-center en compose: 896m x 75% = 672 MiB → 336/19 = 17
        assertThat(JsonLoginFilter.defaultLoginPermits(16, 672 * MIB)).isEqualTo(17);
    }

    @Test
    void nuncaMenosDeUnPermiso() {
        assertThat(JsonLoginFilter.defaultLoginPermits(1, 8 * MIB)).isEqualTo(1);
    }
}
