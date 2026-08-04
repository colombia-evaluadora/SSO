package com.example.cdc.worker.pipeline;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.event.Operation;
import com.example.cdc.common.routing.TableRouter;
import com.example.cdc.common.transform.OperationContext;
import com.example.cdc.common.transform.TMatriculaConsolidator;
import com.example.cdc.common.transform.TUsuarioDecomposer;
import com.example.cdc.common.transform.TlistaValorSplitter;
import com.example.cdc.common.transform.Transformer;
import com.example.cdc.worker.oracle.OracleJdbcWriter;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class OracleReverseStageTest {

    @Test
    void skips_event_when_transformer_returns_empty() throws Exception {
        TableRouter router = mock(TableRouter.class);
        OracleJdbcWriter writer = mock(OracleJdbcWriter.class);
        NamedParameterJdbcTemplate jdbc = mock(NamedParameterJdbcTemplate.class);
        TableRouter.RoutingDecision decision = new TableRouter.RoutingDecision(
                "CLIENTES", "ACADEMICO", "PK_CLIENTE", List.of("DroppingTransformer"));
        when(router.route("clientes")).thenReturn(Optional.of(decision));
        OracleReverseStage stage = new OracleReverseStage(
                router,
                writer,
                jdbc,
                mock(TlistaValorSplitter.class),
                mock(TUsuarioDecomposer.class),
                mock(TMatriculaConsolidator.class),
                List.of(new DroppingTransformer()));
        CdcEvent event = new CdcEvent(
                Operation.INSERT,
                null,
                Map.of("pk_cliente", 7L),
                new CdcEvent.Source("academico", "public", "clientes", 100L, 12345L, "false"),
                1712345678000L,
                "public.clientes",
                null,
                null);

        String result = stage.execute(event);

        assertThat(result).isNull();
        verifyNoInteractions(writer, jdbc);
    }

    private static final class DroppingTransformer implements Transformer {
        @Override
        public Optional<Map<String, Object>> apply(CdcEvent event, OperationContext ctx) {
            return Optional.empty();
        }
    }
}
