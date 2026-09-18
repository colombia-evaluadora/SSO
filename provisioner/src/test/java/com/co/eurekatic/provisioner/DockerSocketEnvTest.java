package com.co.eurekatic.provisioner;

import org.junit.jupiter.api.Test;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Cubre el env que hereda cada query-service spawneado. No habla con
 * Docker: {@link DockerSocket#buildEnv} es puro (props + request →
 * lista de {@code KEY=value}), así que se afirma directamente.
 *
 * <p>Lo que importa aquí es el interruptor de telemetría: los tres
 * flags {@code MANAGEMENT_*_EXPORT_ENABLED} tienen que viajar SIEMPRE
 * y con el valor de {@code docker.telemetry-enabled}. Si faltan, el
 * contenedor nuevo cae al default de Spring Boot (export de logs
 * encendido) y reintenta contra un Alloy que no existe.
 */
class DockerSocketEnvTest {

    private static ProvisionRequest request() {
        return new ProvisionRequest("eval-col", "postgres",
                "jdbc:postgresql://postgres:5432/db", "user", "secret", 5);
    }

    @Test
    void telemetriaApagadaPorDefecto_propagaLosTresFlagsEnFalse() {
        ProvisionerProperties props = new ProvisionerProperties();

        List<String> env = new DockerSocket(props).buildEnv(request());

        assertThat(env).contains(
                "MANAGEMENT_TRACING_EXPORT_ENABLED=false",
                "MANAGEMENT_OTLP_METRICS_EXPORT_ENABLED=false",
                "MANAGEMENT_LOGGING_EXPORT_OTLP_ENABLED=false",
                "OTEL_EXPORTER_OTLP_ENDPOINT=http://alloy:4318");
    }

    @Test
    void telemetriaEncendida_propagaLosTresFlagsEnTrue() {
        ProvisionerProperties props = new ProvisionerProperties();
        props.setTelemetryEnabled(true);
        props.setOtlpEndpoint("http://otel-collector:4318");

        List<String> env = new DockerSocket(props).buildEnv(request());

        assertThat(env).contains(
                "MANAGEMENT_TRACING_EXPORT_ENABLED=true",
                "MANAGEMENT_OTLP_METRICS_EXPORT_ENABLED=true",
                "MANAGEMENT_LOGGING_EXPORT_OTLP_ENABLED=true",
                "OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318");
    }
}
