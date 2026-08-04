package com.example.cdc.common.transform;

import ch.qos.logback.classic.Logger;
import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.core.read.ListAppender;
import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.event.Operation;
import org.junit.jupiter.api.Test;
import org.slf4j.LoggerFactory;

import java.util.HashMap;
import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;

class TActividadFlattenerTest {

    @Test
    void flattens_pivot_fk_to_inline_fk_tactividad_and_fk_tmatricula() {
        Map<Long, TActividadFlattener.ParentFks> cache = new HashMap<>();
        cache.put(500L, new TActividadFlattener.ParentFks(42L, 7L));

        TActividadFlattener flattener = new TActividadFlattener(cache);

        Map<String, Object> after = Map.of(
                "pk_tactividad_nota", 9001L,
                "fk_tactividad_estudiante", 500L,
                "nota", 4.5
        );
        CdcEvent event = new CdcEvent(
                Operation.INSERT,
                null,
                after,
                new CdcEvent.Source("academico", "public", "tactividad_nota", 100L, 12345L, "false"),
                1712345678000L,
                "public.tactividad_nota",
                null,
                null
        );
        OperationContext ctx = new OperationContext("tactividad_nota", "TACTIVIDAD_NOTA", "ACADEMICO",
                "PK_TACTIVIDAD_NOTA", true, false, false);

        Optional<Map<String, Object>> result = flattener.apply(event, ctx);

        assertThat(result).isPresent();
        Map<String, Object> row = result.get();
        assertThat(row).containsEntry("PK_TACTIVIDAD_NOTA", 9001L);
        assertThat(row).containsEntry("FK_TACTIVIDAD", 42L);
        assertThat(row).containsEntry("FK_TMATRICULA", 7L);
        assertThat(row).containsEntry("NOTA", 4.5);
        assertThat(row).doesNotContainKey("FK_TACTIVIDAD_ESTUDIANTE");
    }

    @Test
    void returns_empty_when_parent_fk_missing_in_cache() {
        TActividadFlattener flattener = new TActividadFlattener(Map.of());

        CdcEvent event = new CdcEvent(
                Operation.INSERT,
                null,
                Map.of("pk_tactividad_nota", 9001L, "fk_tactividad_estudiante", 999L),
                new CdcEvent.Source("academico", "public", "tactividad_nota", 100L, 12345L, "false"),
                1712345678000L,
                "public.tactividad_nota",
                null,
                null
        );
        OperationContext ctx = new OperationContext("tactividad_nota", "TACTIVIDAD_NOTA", "ACADEMICO",
                "PK_TACTIVIDAD_NOTA", true, false, false);

        Optional<Map<String, Object>> result = flattener.apply(event, ctx);

        assertThat(result).isEmpty();
    }

    @Test
    void warns_only_once_when_parent_cache_is_empty() {
        TActividadFlattener flattener = new TActividadFlattener(Map.of());
        Logger logger = (Logger) LoggerFactory.getLogger(TActividadFlattener.class);
        ListAppender<ILoggingEvent> appender = new ListAppender<>();
        appender.start();
        logger.addAppender(appender);

        try {
            CdcEvent event = new CdcEvent(
                    Operation.INSERT,
                    null,
                    Map.of("pk_tactividad_nota", 9001L, "fk_tactividad_estudiante", 999L),
                    new CdcEvent.Source("academico", "public", "tactividad_nota", 100L, 12345L, "false"),
                    1712345678000L,
                    "public.tactividad_nota",
                    null,
                    null
            );
            OperationContext ctx = new OperationContext("tactividad_nota", "TACTIVIDAD_NOTA", "ACADEMICO",
                    "PK_TACTIVIDAD_NOTA", true, false, false);

            flattener.apply(event, ctx);
            flattener.apply(event, ctx);

            assertThat(appender.list)
                    .filteredOn(logEvent -> logEvent.getLevel() == ch.qos.logback.classic.Level.WARN)
                    .extracting(ILoggingEvent::getFormattedMessage)
                    .containsExactly("TActividadFlattener parentCache is empty — tactividad_estudiante events will be skipped. "
                            + "This should be hydrated by a future wiring task.");
        } finally {
            logger.detachAppender(appender);
            appender.stop();
        }
    }

    @Test
    void returns_empty_when_row_is_null() {
        TActividadFlattener flattener = new TActividadFlattener(Map.of());

        CdcEvent event = new CdcEvent(
                Operation.DELETE,
                Map.of("pk_tactividad_nota", 9001L),
                null,
                new CdcEvent.Source("academico", "public", "tactividad_nota", 100L, 12345L, "false"),
                1712345678000L,
                "public.tactividad_nota",
                null,
                null
        );
        OperationContext ctx = new OperationContext("tactividad_nota", "TACTIVIDAD_NOTA", "ACADEMICO",
                "PK_TACTIVIDAD_NOTA", false, false, true);

        Optional<Map<String, Object>> result = flattener.apply(event, ctx);

        assertThat(result).isEmpty();
    }
}
