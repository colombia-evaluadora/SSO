package com.co.eurekatic.ssoadmin.service;

import org.junit.jupiter.api.Test;
import org.springframework.cloud.client.DefaultServiceInstance;
import org.springframework.cloud.client.ServiceInstance;
import org.springframework.cloud.client.discovery.DiscoveryClient;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * El notificador apuntaba a una URL fija
 * ({@code http://query-service:8080}) que no resolvía, así que toda
 * query guardada tardaba hasta 60s en estar viva — y aunque hubiera
 * resuelto, era una sola URL para un sistema multi-instancia.
 *
 * <p>Estos tests fijan lo que importa del descubrimiento. La
 * entrega HTTP en sí es best-effort por diseño y no se prueba
 * aquí: un fallo de red se traga a propósito.
 */
class PathRegistryNotifierTest {

    private static ServiceInstance instance(String serviceId, int port) {
        return new DefaultServiceInstance(
                serviceId + "-1", serviceId, "localhost", port, false);
    }

    @Test
    void discoversEveryQueryServiceInstanceRegardlessOfSuffix() {
        DiscoveryClient discovery = mock(DiscoveryClient.class);
        when(discovery.getServices()).thenReturn(List.of(
                "query-service-postgres",
                "query-service-eval-col",
                "sso-admin",
                "auth-center"));
        when(discovery.getInstances("query-service-postgres"))
                .thenReturn(List.of(instance("query-service-postgres", 8080)));
        when(discovery.getInstances("query-service-eval-col"))
                .thenReturn(List.of(instance("query-service-eval-col", 8084)));

        new PathRegistryNotifier(discovery, "tok").invalidate();

        // Se consultan las dos que sirven queries y ninguna más:
        // avisar a auth-center sería ruido, y no avisar a eval-col
        // era el bug.
        verify(discovery).getInstances("query-service-postgres");
        verify(discovery).getInstances("query-service-eval-col");
        verify(discovery, never()).getInstances("sso-admin");
        verify(discovery, never()).getInstances("auth-center");
    }

    /**
     * Sin token no se dispara ninguna petición: misma postura
     * fail-closed que InternalTokenFilter. Y sobre todo, no se
     * consulta Eureka — el trabajo se descarta antes.
     */
    @Test
    void skipsEntirelyWhenTheInternalTokenIsMissing() {
        DiscoveryClient discovery = mock(DiscoveryClient.class);

        new PathRegistryNotifier(discovery, "").invalidate();
        new PathRegistryNotifier(discovery, null).invalidate();

        verify(discovery, never()).getServices();
    }

    /**
     * Que no haya instancias registradas no puede romper el guardado
     * de una query: el refresco periódico es la red de seguridad.
     */
    @Test
    void doesNotThrowWhenNoInstanceIsRegistered() {
        DiscoveryClient discovery = mock(DiscoveryClient.class);
        when(discovery.getServices()).thenReturn(List.of("sso-admin"));

        assertThatCode(() -> new PathRegistryNotifier(discovery, "tok").invalidate())
                .doesNotThrowAnyException();
        verify(discovery, never()).getInstances(anyString());
    }
}
