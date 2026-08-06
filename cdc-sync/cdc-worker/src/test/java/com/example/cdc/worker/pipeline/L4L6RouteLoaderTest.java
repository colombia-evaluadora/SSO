package com.example.cdc.worker.pipeline;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.event.Operation;
import com.example.cdc.common.transform.TCalendarioReverser;
import com.example.cdc.common.transform.TEstablecimientoFkCycleTransformer;
import com.example.cdc.common.transform.TGrupoFkRewriter;
import com.example.cdc.common.transform.TMatriculaConsolidator;
import com.example.cdc.common.transform.TPeriodoAcademicoConfigSplitter;
import com.example.cdc.common.transform.TSedeUsuarioPkTransformer;
import org.junit.jupiter.api.Test;
import org.springframework.core.io.ByteArrayResource;
import org.springframework.core.io.DefaultResourceLoader;
import org.springframework.core.io.ResourceLoader;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class L4L6RouteLoaderTest {

    @Test
    void loads_routes_from_yaml_and_resolves_handlers() throws Exception {
        L4L6RouteLoader loader = new L4L6RouteLoader();
        ResourceLoader rl = new DefaultResourceLoader();
        String yaml = """
            l4l6_routes:
              testablecimiento:
                handler: TEstablecimientoFkCycleTransformer
                oracle_table: TESTABLECIMIENTO
                pk_column: PK_TESTABLECIMIENTO
              tgrupo:
                handler: TGrupoFkRewriter
                oracle_table: TGRUPO
                pk_column: PK_TGRUPO
            """;
        Map<String, OracleReverseStage.PhaseRoute> routes = loader.l4l6Routes(
            tEstablishment(), tSede(), tPeriodo(), tGrupo(), tMatricula(), tCalendario(),
            "transforms/table-routing.yaml", yamlResource(rl, yaml));

        assertThat(routes).containsOnlyKeys("testablecimiento", "tgrupo");
        assertThat(routes.get("testablecimiento").oracleTable()).isEqualTo("TESTABLECIMIENTO");
        assertThat(routes.get("testablecimiento").pkColumn()).isEqualTo("PK_TESTABLECIMIENTO");
        assertThat(routes.get("tgrupo").oracleTable()).isEqualTo("TGRUPO");
    }

    @Test
    void unknown_handler_in_yaml_fails_fast() {
        L4L6RouteLoader loader = new L4L6RouteLoader();
        ResourceLoader rl = new DefaultResourceLoader();
        String yaml = """
            l4l6_routes:
              tfoo:
                handler: TUnknownHandler
                oracle_table: TFOO
                pk_column: PK_TFOO
            """;
        assertThatThrownBy(() -> loader.l4l6Routes(
            tEstablishment(), tSede(), tPeriodo(), tGrupo(), tMatricula(), tCalendario(),
            "transforms/table-routing.yaml", yamlResource(rl, yaml)))
            .hasMessageContaining("Unknown l4l6 handler 'TUnknownHandler'");
    }

    @Test
    void empty_l4l6_routes_block_yields_empty_map_no_throw() throws Exception {
        L4L6RouteLoader loader = new L4L6RouteLoader();
        ResourceLoader rl = new DefaultResourceLoader();
        String yaml = "routes:\n  clientes:\n    oracle_table: CLIENTES\n";
        Map<String, OracleReverseStage.PhaseRoute> routes = loader.l4l6Routes(
            tEstablishment(), tSede(), tPeriodo(), tGrupo(), tMatricula(), tCalendario(),
            "transforms/table-routing.yaml", yamlResource(rl, yaml));
        assertThat(routes).isEmpty();
    }

    private static ResourceLoader yamlResource(ResourceLoader delegate, String yaml) {
        return new ResourceLoader() {
            @Override
            public org.springframework.core.io.Resource getResource(String location) {
                return new ByteArrayResource(yaml.getBytes(StandardCharsets.UTF_8));
            }
            @Override
            public ClassLoader getClassLoader() {
                return delegate.getClassLoader();
            }
        };
    }

    private static TEstablecimientoFkCycleTransformer tEstablishment() { return mock(TEstablecimientoFkCycleTransformer.class); }
    private static TSedeUsuarioPkTransformer tSede() { return mock(TSedeUsuarioPkTransformer.class); }
    private static TPeriodoAcademicoConfigSplitter tPeriodo() { return mock(TPeriodoAcademicoConfigSplitter.class); }
    private static TGrupoFkRewriter tGrupo() { return mock(TGrupoFkRewriter.class); }
    private static TMatriculaConsolidator tMatricula() { return mock(TMatriculaConsolidator.class); }
    private static TCalendarioReverser tCalendario() { return mock(TCalendarioReverser.class); }

    private static <T> T mock(Class<T> klass) {
        return org.mockito.Mockito.mock(klass);
    }
}
