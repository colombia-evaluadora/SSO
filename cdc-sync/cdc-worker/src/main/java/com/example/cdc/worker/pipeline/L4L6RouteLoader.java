package com.example.cdc.worker.pipeline;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.event.Operation;
import com.example.cdc.common.transform.OperationContext;
import com.example.cdc.common.transform.TCalendarioReverser;
import com.example.cdc.common.transform.TEstablecimientoFkCycleTransformer;
import com.example.cdc.common.transform.TGrupoFkRewriter;
import com.example.cdc.common.transform.TMatriculaConsolidator;
import com.example.cdc.common.transform.TPeriodoAcademicoConfigSplitter;
import com.example.cdc.common.transform.TSedeUsuarioPkTransformer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.yaml.snakeyaml.Yaml;

import java.io.InputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;

/**
 * Loads the L4 / L5 / L6 Phase 2 dispatch table from {@code l4l6_routes:} in
 * {@code transforms/table-routing.yaml} and exposes it as a
 * {@code Map<String, PhaseRoute>} injected into {@link OracleReverseStage}.
 *
 * <p>Previously the same dispatch lived in {@code OracleReverseStage.buildL4L6Routes()}
 * with a parallel set of entries inside the {@code routes:} block of the YAML
 * (mirrored documentation only). The two sources of truth could drift apart
 * without any compile-time signal. The loader makes the YAML the single
 * source: a developer adding a new L4-L6 table only edits the YAML.
 *
 * <p>Each Phase 2 transformer in {@code cdc-common} exposes a distinct
 * {@code apply()} signature, so the adapter lambdas that wrap one-arg
 * {@code apply(CdcEvent)} into a uniform {@code Function<CdcEvent, RouteResult>}
 * live here in {@link L4L6HandlerRegistry}, indexed by {@code handlerClass}.
 */
@Configuration
public class L4L6RouteLoader {

    private static final Logger log = LoggerFactory.getLogger(L4L6RouteLoader.class);

    /**
     * Loads {@code transforms/table-routing.yaml} from the classpath, finds
     * the top-level {@code l4l6_routes:} key, and materialises a
     * {@code Map<String, PhaseRoute>}. Missing or empty YAML falls back to
     * an empty map (degraded mode) so misconfiguration doesn't crash boot.
     */
    @Bean
    public Map<String, OracleReverseStage.PhaseRoute> l4l6Routes(
            TEstablecimientoFkCycleTransformer establecimientoCycle,
            TSedeUsuarioPkTransformer sedeUsuarioPk,
            TPeriodoAcademicoConfigSplitter periodoAcademicoSplitter,
            TGrupoFkRewriter grupoFkRewriter,
            TMatriculaConsolidator matriculaConsolidator,
            TCalendarioReverser calendarioReverser,
            @Value("${cdc.routing.path:transforms/table-routing.yaml}") String resourcePath,
            org.springframework.core.io.ResourceLoader resourceLoader) {

        L4L6HandlerRegistry registry = new L4L6HandlerRegistry(
            establecimientoCycle, sedeUsuarioPk, periodoAcademicoSplitter,
            grupoFkRewriter, matriculaConsolidator, calendarioReverser);

        Map<String, OracleReverseStage.PhaseRoute> out = new HashMap<>();
        try (InputStream in = resourceLoader.getResource("classpath:" + resourcePath).getInputStream()) {
            Map<String, Object> root = new Yaml().load(in);
            @SuppressWarnings("unchecked")
            Map<String, Map<String, String>> l4l6Routes =
                (Map<String, Map<String, String>>) root.get("l4l6_routes");
            if (l4l6Routes == null || l4l6Routes.isEmpty()) {
                log.warn("l4l6_routes block missing from {} — Phase 2 dispatch will be empty", resourcePath);
                return Map.of();
            }
            for (Map.Entry<String, Map<String, String>> entry : l4l6Routes.entrySet()) {
                String table = entry.getKey();
                Map<String, String> spec = entry.getValue();
                String handlerName = spec.get("handler");
                String oracleTable = spec.get("oracle_table");
                String pkColumn = spec.get("pk_column");
                Function<CdcEvent, OracleReverseStage.RouteResult> handler = registry.resolve(handlerName);
                if (handler == null) {
                    throw new IllegalStateException("Unknown l4l6 handler '" + handlerName
                        + "' for table '" + table + "' in " + resourcePath);
                }
                out.put(table, new OracleReverseStage.PhaseRoute(oracleTable, pkColumn, handler));
            }
            log.info("Loaded {} L4/L5/L6 routes from {}: {}", out.size(), resourcePath, out.keySet());
        } catch (Exception e) {
            log.error("Failed to load l4l6 routes from {}", resourcePath, e);
            return Map.of();
        }
        return Map.copyOf(out);
    }

    /**
     * Maps handler class names (the {@code handler:} key in the YAML) to a
     * unified {@code Function<CdcEvent, RouteResult>} adapter that wraps the
     * transformer's idiosyncratic {@code apply(...)} signature.
     *
     * <p>Adapter wrappers are intentionally declared with one
     * {@code Function} per public Phase 2 method instead of method-reference
     * lookup, so that any future signature changes surface as a compile
     * error rather than a runtime {@code NoSuchMethodException}.
     */
    static final class L4L6HandlerRegistry {
        private final TEstablecimientoFkCycleTransformer establecimientoCycle;
        private final TSedeUsuarioPkTransformer sedeUsuarioPk;
        private final TPeriodoAcademicoConfigSplitter periodoAcademicoSplitter;
        private final TGrupoFkRewriter grupoFkRewriter;
        private final TMatriculaConsolidator matriculaConsolidator;
        private final TCalendarioReverser calendarioReverser;

        L4L6HandlerRegistry(TEstablecimientoFkCycleTransformer establecimientoCycle,
                            TSedeUsuarioPkTransformer sedeUsuarioPk,
                            TPeriodoAcademicoConfigSplitter periodoAcademicoSplitter,
                            TGrupoFkRewriter grupoFkRewriter,
                            TMatriculaConsolidator matriculaConsolidator,
                            TCalendarioReverser calendarioReverser) {
            this.establecimientoCycle = establecimientoCycle;
            this.sedeUsuarioPk = sedeUsuarioPk;
            this.periodoAcademicoSplitter = periodoAcademicoSplitter;
            this.grupoFkRewriter = grupoFkRewriter;
            this.matriculaConsolidator = matriculaConsolidator;
            this.calendarioReverser = calendarioReverser;
        }

        Function<CdcEvent, OracleReverseStage.RouteResult> resolve(String handlerName) {
            switch (handlerName) {
                case "TEstablecimientoFkCycleTransformer":
                    return ev -> {
                        TEstablecimientoFkCycleTransformer.Decision d =
                            establecimientoCycle.apply(ev);
                        // L4 adapter: dispatch based on which PG table fed us.
                        // The Oracle table comes from the wrapping route; the
                        // handler is shared across testablecimiento/tsede/tarchivo.
                        if ("tarchivo".equals(ev.tableName())) {
                            return new OracleReverseStage.RouteResult(
                                List.of(), d.deferredUpdates());
                        }
                        String oracleTable = pickTestablecimientoOracleTable(ev.tableName());
                        return new OracleReverseStage.RouteResult(
                            List.of(new OracleReverseStage.Split(
                                oracleTable, "PK_" + stripPrefix(oracleTable), d.initialMerge())),
                            List.of());
                    };
                case "TSedeUsuarioPkTransformer":
                    return ev -> {
                        Map<String, Object> row = sedeUsuarioPk.apply(ev);
                        if (row == null || row.isEmpty()) return OracleReverseStage.RouteResult.empty();
                        return new OracleReverseStage.RouteResult(
                            List.of(new OracleReverseStage.Split(
                                "TSEDE_USUARIO", "(FK_TSEDE,FK_TROL,FK_TUSUARIO)", row)),
                            List.of());
                    };
                case "TPeriodoAcademicoConfigSplitter":
                    return ev -> {
                        List<TPeriodoAcademicoConfigSplitter.Split> raw =
                            periodoAcademicoSplitter.apply(ev);
                        List<OracleReverseStage.Split> out = new ArrayList<>(raw.size());
                        for (TPeriodoAcademicoConfigSplitter.Split s : raw) {
                            out.add(new OracleReverseStage.Split(
                                s.oracleTable(), s.pkColumn(), s.row()));
                        }
                        return new OracleReverseStage.RouteResult(out, List.of());
                    };
                case "TGrupoFkRewriter":
                    return ev -> {
                        Map<String, Object> row = grupoFkRewriter.apply(ev);
                        if (row == null || row.isEmpty()) return OracleReverseStage.RouteResult.empty();
                        return new OracleReverseStage.RouteResult(
                            List.of(new OracleReverseStage.Split("TGRUPO", "PK_TGRUPO", row)),
                            List.of());
                    };
                case "TMatriculaConsolidator":
                    return ev -> {
                        Map<String, Object> row = matriculaConsolidator.apply(ev, (CdcEvent.Context) null);
                        if (row == null || row.isEmpty()) return OracleReverseStage.RouteResult.empty();
                        return new OracleReverseStage.RouteResult(
                            List.of(new OracleReverseStage.Split("TMATRICULA", "PK_TMATRICULA", row)),
                            List.of());
                    };
                case "TCalendarioReverser":
                    return ev -> {
                        OperationContext ctx = new OperationContext(
                            "tcalendario", "TCALENDARIO", "ACADEMICO", "PK_TCALENDARIO",
                            ev.isInsert(), ev.isUpdate(), ev.isDelete());
                        var opt = calendarioReverser.apply(ev, ctx);
                        if (opt.isEmpty() || opt.get().isEmpty()) return OracleReverseStage.RouteResult.empty();
                        return new OracleReverseStage.RouteResult(
                            List.of(new OracleReverseStage.Split("TCALENDARIO", "PK_TCALENDARIO", opt.get())),
                            List.of());
                    };
                default:
                    return null;
            }
        }

        private static String pickTestablecimientoOracleTable(String pgTable) {
            switch (pgTable) {
                case "tsede": return "TSEDE";
                case "testablecimiento": return "TESTABLECIMIENTO";
                default: return pgTable.toUpperCase();
            }
        }

        private static String stripPrefix(String s) {
            return s.startsWith("PK_") ? s : "PK_" + s;
        }
    }
}
