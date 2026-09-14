package com.co.eurekatic.gateway.security;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * La regla que mantiene {@code /internal/**} fuera del alcance del borde.
 * Se prueba sola porque el matcher tiene que reconocer el segmento a
 * cualquier profundidad — los prefijos que reenvian toda la superficie de
 * un servicio ({@code /qs/**}, {@code /api/qs/**}) son justamente los que
 * lo esconden.
 */
class GatewaySecurityConfigTest {

    @Test
    void detectaElSegmentoInternalACualquierProfundidad() {
        assertThat(GatewaySecurityConfig.hasInternalSegment("/internal")).isTrue();
        assertThat(GatewaySecurityConfig.hasInternalSegment("/internal/")).isTrue();
        assertThat(GatewaySecurityConfig.hasInternalSegment("/internal/whoami")).isTrue();
        assertThat(GatewaySecurityConfig.hasInternalSegment("/qs/internal/whoami")).isTrue();
        assertThat(GatewaySecurityConfig.hasInternalSegment("/api/qs/internal/whoami")).isTrue();
        assertThat(GatewaySecurityConfig.hasInternalSegment(
                "/api/sso-admin/internal/gateway/routes")).isTrue();
    }

    @Test
    void noBloqueaRutasQueSoloContienenLaPalabra() {
        assertThat(GatewaySecurityConfig.hasInternalSegment("/internals")).isFalse();
        assertThat(GatewaySecurityConfig.hasInternalSegment("/x/internalize")).isFalse();
        assertThat(GatewaySecurityConfig.hasInternalSegment("/my-internal")).isFalse();
        assertThat(GatewaySecurityConfig.hasInternalSegment("/")).isFalse();
        assertThat(GatewaySecurityConfig.hasInternalSegment("/api/qs/query")).isFalse();
    }
}
