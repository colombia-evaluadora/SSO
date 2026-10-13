package com.co.eurekatic.provisioner;

import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

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
    void sinVariablesDeTuning_noInventaNingunDefault() {
        List<String> env = new DockerSocket(new ProvisionerProperties(), Map.of())
                .buildEnv(request());

        assertThat(env).noneMatch(e -> e.startsWith("QUERY_BULKHEAD_MAX_CONCURRENT=")
                || e.startsWith("QUERY_MAX_ROWS=")
                || e.startsWith("OTEL_TRACING_SAMPLE_RATE=")
                || e.startsWith("JAVA_TOOL_OPTIONS="));
    }

    @Test
    void variablesDefinidasEnElProvisioner_seReenvian_yLasVaciasNo() {
        Map<String, String> procEnv = Map.of(
                "QUERY_BULKHEAD_MAX_CONCURRENT", "20",
                "QUERY_MAX_ROWS", "10000",
                "OTEL_TRACING_SAMPLE_RATE", "0.1",
                "JAVA_TOOL_OPTIONS", "-Xss512k",
                "QUERY_TIMEOUT_SECONDS", "");

        List<String> env = new DockerSocket(new ProvisionerProperties(), procEnv)
                .buildEnv(request());

        assertThat(env).contains(
                "QUERY_BULKHEAD_MAX_CONCURRENT=20",
                "QUERY_MAX_ROWS=10000",
                "OTEL_TRACING_SAMPLE_RATE=0.1",
                "JAVA_TOOL_OPTIONS=-Xss512k");
        assertThat(env).noneMatch(e -> e.startsWith("QUERY_TIMEOUT_SECONDS="));
    }

    @Test
    void hostConfig_limitaMemoriaYRotaLogs_cpuSoloSiSeConfigura() {
        ProvisionerProperties props = new ProvisionerProperties();
        Map<String, Object> host = new DockerSocket(props, Map.of()).buildHostConfig();

        assertThat(host).containsEntry("Memory", 768L * 1024 * 1024)
                .containsEntry("MemoryReservation", 256L * 1024 * 1024)
                .doesNotContainKey("NanoCpus");
        assertThat(host.get("LogConfig")).isEqualTo(Map.of(
                "Type", "json-file",
                "Config", Map.of("max-size", "20m", "max-file", "5")));

        props.setQueryCpus("1.5");
        assertThat(new DockerSocket(props, Map.of()).buildHostConfig())
                .containsEntry("NanoCpus", 1_500_000_000L);
    }

    @Test
    void parseBytes_aceptaSufijosYTolerasBasura() {
        assertThat(DockerSocket.parseBytes("1g")).isEqualTo(1024L * 1024 * 1024);
        assertThat(DockerSocket.parseBytes("256mb")).isEqualTo(256L * 1024 * 1024);
        assertThat(DockerSocket.parseBytes("2048")).isEqualTo(2048L);
        assertThat(DockerSocket.parseBytes("")).isZero();
        assertThat(DockerSocket.parseBytes("abc")).isZero();
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
