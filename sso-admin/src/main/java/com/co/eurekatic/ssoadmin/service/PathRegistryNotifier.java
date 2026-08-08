package com.co.eurekatic.ssoadmin.service;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.cloud.client.ServiceInstance;
import org.springframework.cloud.client.discovery.DiscoveryClient;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.web.client.RestClient;

import java.util.List;
import java.util.Map;

/**
 * V33 — best-effort notifier that pushes a
 * "your path-registry is stale" signal to every
 * query-service instance when a catalog mutation lands.
 *
 * <p>Why not a fan-out via RabbitMQ: the only consumer
 * is query-service (a few instances behind Eureka), and
 * we don't have a guaranteed-delivery requirement — the
 * next periodic refresh (60s) catches anything the
 * invalidate call missed. HTTP fan-out from a single
 * service is the simplest tool that fits.
 *
 * <p>Failure mode is graceful: every call is wrapped in
 * try/catch with a WARN log. A failed invalidate call
 * is not an error to the user — the admin-ui save
 * succeeds, the change lands in Postgres, and the next
 * periodic refresh on each query-service picks it up.
 * This matters because we don't want a flaky
 * query-service to break the admin's create-query flow.
 *
 * <p>Los destinatarios se descubren por Eureka, no se
 * configuran: cada instancia se registra como
 * {@code query-service-<instanceName>} y el provisioner puede
 * crear más en cualquier momento, así que una URL fija en
 * configuración se quedaría desactualizada por diseño.
 */
@Component
public class PathRegistryNotifier {

    private static final Logger log = LoggerFactory.getLogger(PathRegistryNotifier.class);

    /**
     * Prefijo de los service-id que sirven queries. El
     * provisioner registra cada instancia como
     * {@code query-service-<instanceName>}, así que este prefijo
     * las cubre todas.
     */
    private static final String QUERY_SERVICE_PREFIX = "query-service";

    private final RestClient client;
    private final String internalToken;
    private final DiscoveryClient discovery;

    public PathRegistryNotifier(DiscoveryClient discovery,
                                @Value("${sso.internal.token:}") String internalToken) {
        this.discovery = discovery;
        this.internalToken = internalToken;
        this.client = RestClient.builder().build();
    }

    /**
     * Instancias a las que hay que avisar, descubiertas por Eureka.
     *
     * <p>Antes esto era una única URL fija
     * ({@code http://query-service:8080}) y tenía dos problemas a
     * la vez. Uno, que ese hostname no existe: las instancias se
     * llaman {@code query-service-postgres},
     * {@code query-service-eval-col}… así que cada invalidación
     * moría con "Temporary failure in name resolution" y toda
     * query guardada tardaba hasta 60s en estar viva. Y dos, que
     * aunque hubiera resuelto, era una sola URL para un sistema
     * multi-instancia: las demás nunca se habrían enterado.
     */
    private List<ServiceInstance> targets() {
        return discovery.getServices().stream()
                .filter(id -> id.toLowerCase(java.util.Locale.ROOT)
                        .startsWith(QUERY_SERVICE_PREFIX))
                .flatMap(id -> discovery.getInstances(id).stream())
                .toList();
    }

    /**
     * Ask the query-service to refresh its in-memory
     * path-registry NOW. Best-effort: a 4xx/5xx/network
     * error is logged at WARN and swallowed; the caller
     * (a successful catalog mutation) is not affected.
     */
    public void invalidate() {
        // Si hay transacción abierta, se espera al commit.
        //
        // Los llamantes (create/update/delete) son @Transactional y
        // llaman aquí antes de que la transacción cierre, así que
        // avisar en ese momento hace que query-service lea la base
        // ANTES del commit y recargue el estado viejo: el registro
        // se quedaba sin la fila recién guardada hasta el refresco
        // periódico, 60s después.
        //
        // Se veía en los logs como una invalidación "exitosa" que
        // reportaba el tamaño de antes — el peor tipo de fallo,
        // porque parece que funcionó. Antes de arreglar el
        // descubrimiento por Eureka esto quedaba tapado: la
        // notificación no llegaba nunca y el refresco periódico
        // acababa cubriéndolo.
        if (TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.registerSynchronization(
                    new TransactionSynchronization() {
                        @Override
                        public void afterCommit() {
                            doInvalidate();
                        }
                    });
            return;
        }
        doInvalidate();
    }

    private void doInvalidate() {
        if (internalToken == null || internalToken.isBlank()) {
            // Same fail-closed posture as InternalTokenFilter
            // in sso-admin: empty token means the operator
            // hasn't configured the secret. We log + skip
            // rather than firing requests without auth.
            log.warn("PathRegistryNotifier: sso.internal.token está vacío; "
                    + "se omite la invalidación. El path-registry se pondrá "
                    + "al día en el refresco periódico (60s).");
            return;
        }
        List<ServiceInstance> instances = targets();
        if (instances.isEmpty()) {
            log.warn("PathRegistryNotifier: Eureka no reporta ninguna instancia "
                    + "'{}*'. El path-registry se pondrá al día en el refresco "
                    + "periódico (60s).", QUERY_SERVICE_PREFIX);
            return;
        }
        // Se avisa a TODAS. Fallar en una no debe impedir avisar a
        // las demás, así que el try va dentro del bucle.
        for (ServiceInstance instance : instances) {
            String url = instance.getUri() + "/internal/path-registry/invalidate";
            try {
                @SuppressWarnings("unchecked")
                Map<String, Object> body = client.post()
                        .uri(url)
                        .header("X-Internal-Token", internalToken)
                        .retrieve()
                        .onStatus(s -> true, (req, res) -> { /* swallow all */ })
                        .body(Map.class);
                log.info("Path-registry invalidado en {} (size={})",
                        instance.getServiceId(), body == null ? "?" : body.get("size"));
            } catch (Exception e) {
                // Best-effort. El refresco periódico (60s) es la red
                // de seguridad. WARN y no ERROR: una instancia que
                // acaba de morir no debería encender alarmas.
                log.warn("Invalidación fallida en {} ({}), el refresco periódico "
                        + "lo recogerá: {}", instance.getServiceId(), url, e.getMessage());
            }
        }
    }
}
