package com.example.cdc.worker.pipeline;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.routing.TableRouter;
import com.example.cdc.common.transform.OperationContext;
import com.example.cdc.common.transform.TEstablecimientoFkCycleTransformer;
import com.example.cdc.common.transform.TGrupoFkRewriter;
import com.example.cdc.common.transform.TMatriculaConsolidator;
import com.example.cdc.common.transform.TPeriodoAcademicoConfigSplitter;
import com.example.cdc.common.transform.TSedeUsuarioPkTransformer;
import com.example.cdc.common.transform.TUsuarioDecomposer;
import com.example.cdc.common.transform.TlistaValorSplitter;
import com.example.cdc.common.transform.Transformer;
import com.example.cdc.worker.oracle.OracleJdbcWriter;
import org.springframework.core.env.Environment;
import com.example.cdc.worker.transform.TArchivoBlobDropper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;

import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.function.Function;
import java.util.stream.Collectors;

@Component
public class OracleReverseStage {

    private static final Logger log = LoggerFactory.getLogger(OracleReverseStage.class);

    private final TableRouter router;
    private final OracleJdbcWriter writer;
    private final NamedParameterJdbcTemplate jdbc;
    private final TlistaValorSplitter splitter;
    private final TUsuarioDecomposer decomposer;
    private final TMatriculaConsolidator matriculaConsolidator;

    /**
     * Phase 2 transformers (L4-L6 retrocompatibilidad plan). Each is injected
     * here only so its stateful apply() can be reached from the
     * {@link #l4l6Routes} adapter layer below; the legacy transformer-chain
     * machinery on the upper branch does not see these beans.
     */
    private final TEstablecimientoFkCycleTransformer establecimientoCycle;
    private final TSedeUsuarioPkTransformer sedeUsuarioPk;
    private final TPeriodoAcademicoConfigSplitter periodoAcademicoSplitter;
    private final TGrupoFkRewriter grupoFkRewriter;
    private final TArchivoBlobDropper archivoBlobDropper;
    private final TCalendarioReverser calendarioReverser;

    /**
     * Spring {@code Environment} used to consult per-table skip flags
     * ({@code cdc.tables.<source>.enabled}) so that tables whose PG→Oracle
     * schema divergence is unresolved (e.g. {@code tactividad}, where PG has 36
     * columns and Oracle has 20) are WARN-skipped without consuming retry
     * budget on every event. Without this gate, events for a divergent table
     * ping-pong through five retries and end up in the DLQ, masking the real
     * flow for tables that DO have a reverse-sync bridge.
     */
    private final Environment env;

    /**
     * All {@link Transformer} beans injected by Spring, keyed by their simple
     * class name. Used to honor the {@code transformers} list in
     * {@code table-routing.yaml} so that adding a new transformer in the YAML
     * actually changes the runtime behavior. Phase 2 transformers that take a
     * non-Transformer signature (e.g. {@link TGrupoFkRewriter}) live exclusively
     * in {@link #l4l6Routes} and never enter this map.
     */
    private final Map<String, Transformer> transformers;

    /**
     * Adapter layer for the Phase 2 transformers. Each entry maps a PG source
     * table to the handler that turns its event into a {@link RouteResult}
     * (zero or more {@link Split}s to MERGE plus any deferred FK updates to
     * apply after the initial writes — see {@link TEstablecimientoFkCycleTransformer}'s
     * TESTABLECIMIENTO / TARCHIVO cycle).
     *
     * <p>Built once in the constructor.
     */
    private final Map<String, PhaseRoute> l4l6Routes;

    public OracleReverseStage(TableRouter router, OracleJdbcWriter writer,
                              NamedParameterJdbcTemplate jdbc,
                              TlistaValorSplitter splitter,
                              TUsuarioDecomposer decomposer,
                              TMatriculaConsolidator matriculaConsolidator,
                              TEstablecimientoFkCycleTransformer establecimientoCycle,
                              TSedeUsuarioPkTransformer sedeUsuarioPk,
                              TPeriodoAcademicoConfigSplitter periodoAcademicoSplitter,
                              TGrupoFkRewriter grupoFkRewriter,
                              TArchivoBlobDropper archivoBlobDropper,
                              TCalendarioReverser calendarioReverser,
                              Environment env,
                              List<Transformer> transformers,
                              Map<String, PhaseRoute> l4l6Routes) {
        this.router = router;
        this.writer = writer;
        this.jdbc = jdbc;
        this.splitter = splitter;
        this.decomposer = decomposer;
        this.matriculaConsolidator = matriculaConsolidator;
        this.establecimientoCycle = establecimientoCycle;
        this.sedeUsuarioPk = sedeUsuarioPk;
        this.periodoAcademicoSplitter = periodoAcademicoSplitter;
        this.grupoFkRewriter = grupoFkRewriter;
        this.archivoBlobDropper = archivoBlobDropper;
        this.calendarioReverser = calendarioReverser;
        this.env = env;
        // Spring autowires all Transformer beans; key them by simple class name
        // so the routing YAML's string identifiers resolve deterministically.
        this.transformers = new HashMap<>();
        for (Transformer t : transformers) {
            this.transformers.put(t.getClass().getSimpleName(), t);
        }
        // L4/L5/L6 dispatch table is loaded from `l4l6_routes:` in
        // table-routing.yaml by {@link L4L6RouteLoader}; that YAML block is
        // the single source of truth for which Phase 2 tables get a handler.
        this.l4l6Routes = l4l6Routes != null ? l4l6Routes : Map.of();
    }

    public String execute(CdcEvent event) throws Exception {
        // Per-table skip gate. Consults cdc.tables.<source>.enabled and
        // returns early with a WARN log when the operator has explicitly
        // turned a table off (typically because the PG schema has fields
        // whose Oracle destinations don't exist yet — see V22 cleanup,
        // L7+ tables that are out of scope, or per-table debug toggles).
        // Without this, every event for an off-table would still be
        // routed through a transformer (or the default chain) and fail at
        // the Oracle JDBC layer, burning five retries + DLQ budget per event.
        if (!isTableEnabled(event.tableName())) {
            log.warn("Tabla '{}' deshabilitada via cdc.tables.{}.enabled=false; saltando Oracle merge/delete",
                    event.tableName(), event.tableName());
            return null;
        }

        // Phase 3 dispatch: tables handled by the Phase 2 transformers
        // (L4-L6 retrocompatibilidad) get a dedicated adapter path because
        // those transformers do NOT implement the Transformer interface —
        // they expose ad-hoc apply() signatures (Map<String,Object>,
        // List<Split>, Decision, void) that the legacy chain machinery
        // cannot walk.
        PhaseRoute l4l6Route = l4l6Routes.get(event.tableName());
        if (l4l6Route != null) {
            return executeL4L6(event, l4l6Route);
        }

        Optional<TableRouter.RoutingDecision> decisionOpt = router.route(event.tableName());
        if (decisionOpt.isEmpty()) {
            log.debug("Tabla {} sin routing a Oracle, skip", event.tableName());
            return null;
        }

        TableRouter.RoutingDecision decision = decisionOpt.get();

        // Known limitation: AUTO_SPLIT, AUTO_DECOMPOSE, and TMATRICULA use
        // dedicated reverse paths and therefore bypass the transformer chain
        // declared in table-routing.yaml. A future refactor must thread that
        // chain through these three paths before their route-specific logic.

        // AUTO_SPLIT: el splitter redirige a N tablas Oracle (catálogos eliminados → TLISTA_VALOR)
        if (decision.oracleTable().equals("AUTO_SPLIT")) {
            return executeAutoSplit(event);
        }

        // AUTO_DECOMPOSE: el decomposer redirige TUSUARIO a la tabla hija
        // Oracle (TESTUDIANTE / TFUNCIONARIO / TPADRE) según tipo_usuario.
        if (decision.oracleTable().equals("AUTO_DECOMPOSE")) {
            return executeAutoDecompose(event);
        }

        // Otros AUTO_* aún no implementados
        if (decision.oracleTable().startsWith("AUTO_")) {
            log.debug("Reverse-transform {} aún no implementado, skip", decision.oracleTable());
            return null;
        }

        if ("TMATRICULA".equals(decision.oracleTable())) {
            return executeMatricula(event, decision);
        }

        OperationContext ctx = new OperationContext(
                event.tableName(),
                decision.oracleTable(),
                decision.oracleSchema(),
                decision.pkColumn(),
                event.isInsert(),
                event.isUpdate(),
                event.isDelete()
        );

        // Ejecutar DELETE primero (sin transformer chain — para evitar que un
        // transformer que retorne Optional.empty() suprima deletes; el short-circuit
        // del chain aplica solo a merge/insert).
        if (event.isDelete()) {
            Object pk = event.before() != null ? event.before().get(decision.pkColumn().toLowerCase()) : null;
            if (pk != null) {
                writer.delete(decision.oracleTable(), decision.pkColumn(), pk);
            }
            return decision.oracleTable();
        }

        // Aplicar transformer chain — recorre los transformers declarados en
        // el YAML de routing (table-routing.yaml), en orden.
        Map<String, Object> current = new HashMap<>(event.after() != null ? event.after() : Map.of());
        current = applyTransformers(event, ctx, decision, current);
        if (current == null) {
            return null;
        }

        Object pk = current.get(decision.pkColumn());
        if (pk == null) {
            throw new RuntimeException("PK no encontrada en fila Oracle: " + decision.oracleTable());
        }
        writer.merge(decision.oracleTable(), decision.pkColumn(), current);
        return decision.oracleTable();
    }

    /**
     * Walk the transformer chain declared in the routing YAML for the
     * current table. Each step produces an updated {@link Map} that becomes
     * the {@code after} field of a re-wrapped {@link CdcEvent} so downstream
     * transformers see the transformed row.
     */
    private Map<String, Object> applyTransformers(CdcEvent event, OperationContext ctx,
                                                  TableRouter.RoutingDecision decision,
                                                  Map<String, Object> initial) {
        List<String> chain = decision.transformerClasses();
        if (chain == null || chain.isEmpty()) {
            return initial;
        }
        Map<String, Object> current = initial;
        for (String name : chain) {
            Transformer t = transformers.get(name);
            if (t == null) {
                log.warn("Transformer '{}' declarado en routing YAML pero no está registrado como bean; se omite", name);
                continue;
            }
            CdcEvent wrapped = new CdcEvent(
                    event.op(), event.before(), current, event.source(),
                    event.tsMs(), event.routingKey(), event.context(), event.message());
            Optional<Map<String, Object>> transformed = t.apply(wrapped, ctx);
            if (transformed.isEmpty()) {
                return null;
            }
            current = transformed.get();
        }
        return current;
    }

    private String executeAutoSplit(CdcEvent event) {
        Optional<Map<String, Object>> splitOpt = splitter.apply(event, null);
        if (splitOpt.isEmpty()) return null;
        Map<String, Object> splitRow = splitOpt.get();
        String oracleTable = (String) splitRow.remove("ORACLE_TABLE");
        String pkColumn = (String) splitRow.remove("PK_COLUMN");
        String codigoColumn = (String) splitRow.remove("CODIGO_COLUMN");
        if (codigoColumn == null || codigoColumn.isBlank()) {
            codigoColumn = "CODIGO"; // fallback default
        }
        // pkColumn y codigo_column ya están en uppercase por el renamer

        Object valor = splitRow.get("VALOR");

        // DELETE: lookup by CODIGO column and delete via writer.delete so we
        // route through the same metrics path as MERGE/INSERT.
        if (event.isDelete()) {
            Integer pkOracle = lookupOraclePkByCodigo(oracleTable, pkColumn, codigoColumn, valor);
            if (pkOracle != null) {
                writer.delete(oracleTable, pkColumn, pkOracle);
            } else {
                log.debug("DELETE en tlista_valor sin fila Oracle para {}={}", codigoColumn, valor);
            }
            return oracleTable;
        }

        // Buscar PK existente en Oracle por codigo_column. Usamos query(...)
        // con ResultSetExtractor porque queryForObject lanza
        // EmptyResultDataAccessException si no hay fila, lo que haría
        // inalcanzable la rama de INSERT.
        Integer pkOracle = lookupOraclePkByCodigo(oracleTable, pkColumn, codigoColumn, valor);

        if (pkOracle == null) {
            // INSERT (PK la genera IDENTITY)
            // Necesitamos un INSERT directo, no MERGE
            jdbc.update(buildInsertSql(oracleTable, splitRow), new MapSqlParameterSource(splitRow));
        } else {
            splitRow.put(pkColumn, pkOracle);
            writer.merge(oracleTable, pkColumn, splitRow);
        }
        return oracleTable;
    }

    /**
     * Look up the existing Oracle PK by the codigo (or equivalent unique) column.
     * Returns {@code null} when no row matches instead of throwing
     * {@code EmptyResultDataAccessException} (which {@code queryForObject} does
     * on no row, making any subsequent null check dead code).
     */
    private Integer lookupOraclePkByCodigo(String oracleTable, String pkColumn,
                                          String codigoColumn, Object codigo) {
        if (codigo == null) return null;
        try {
            return jdbc.query(
                    String.format("SELECT %s FROM %s WHERE %s = :codigo",
                            pkColumn, oracleTable, codigoColumn),
                    new MapSqlParameterSource("codigo", codigo),
                    rs -> rs.next() ? rs.getInt(1) : null
            );
        } catch (org.springframework.dao.EmptyResultDataAccessException e) {
            return null;
        }
    }

    private String buildInsertSql(String table, Map<String, Object> row) {
        String cols = String.join(", ", row.keySet());
        String vals = row.keySet().stream().map(k -> ":" + k).collect(Collectors.joining(", "));
        return String.format("INSERT INTO %s (%s) VALUES (%s)", table, cols, vals);
    }

    private String executeAutoDecompose(CdcEvent event) {
        Optional<Map<String, Object>> decOpt = decomposer.apply(event, null);
        if (decOpt.isEmpty()) return null;
        Map<String, Object> decRow = decOpt.get();
        // Rename PK_TUSUARIO → FK_TUSUARIO so the MERGE projection matches
        // the ON column (which references FK_TUSUARIO). The decomposer emits
        // PK_TUSUARIO because that's the parent's natural key in PG, but the
        // child Oracle table stores it as a foreign key column. Without this
        // rename, the MERGE US(src) projection does not include the column
        // the ON clause expects, and Oracle raises ORA-38104.
        if (decRow.containsKey("PK_TUSUARIO")) {
            decRow.put("FK_TUSUARIO", decRow.remove("PK_TUSUARIO"));
        }
        String oracleTable = (String) decRow.remove("ORACLE_TABLE");
        String pkColumn = (String) decRow.remove("PK_COLUMN");
        String fkToParent = (String) decRow.remove("FK_TO_PARENT");
        if (fkToParent == null || fkToParent.isBlank()) {
            fkToParent = "FK_TUSUARIO"; // fallback default
        }

        // FK_TUSUARIO es el FK hacia el padre Oracle (TUSUARIO) y a su vez
        // la clave natural con la que identificamos la fila hija Oracle
        // (TESTUDIANTE / TFUNCIONARIO / TPADRE) para UPSERT y DELETE.
        Object pkTusuario = decRow.get("FK_TUSUARIO");
        if (pkTusuario == null && !event.isDelete()) {
            throw new RuntimeException("FK_TUSUARIO no encontrada para decomposición: " + oracleTable);
        }
        if (pkTusuario == null && event.isDelete()) {
            pkTusuario = event.before() != null ? event.before().get("pk_tusuario") : null;
            if (pkTusuario == null) return oracleTable;
        }

        // DELETE: keyed by FK_TO_PARENT since the child PK is IDENTITY-generated
        // and not known at delete time.
        if (event.isDelete()) {
            jdbc.update(
                    String.format("DELETE FROM %s WHERE %s = :%s", oracleTable, fkToParent, fkToParent),
                    new MapSqlParameterSource(fkToParent, pkTusuario)
            );
            return oracleTable;
        }

        // UPSERT keyed on FK_TO_PARENT (the parent PK is a stable natural key
        // from PG → Oracle). On INSERT Oracle IDENTITY generates the child PK.
        mergeChildByForeignKey(oracleTable, pkColumn, fkToParent, decRow);
        return oracleTable;
    }

    /**
     * Oracle UPSERT keyed on a non-PK column (FK to the parent) since the
     * child's own PK is generated by an IDENTITY sequence at INSERT time.
     * If a row already exists for the FK value, non-PK fields are updated;
     * if not, a new row is inserted and IDENTITY supplies the child PK.
     */
    private void mergeChildByForeignKey(String oracleTable, String pkColumn, String fkColumn,
                                        Map<String, Object> decRow) {
        List<String> cols = new java.util.ArrayList<>(decRow.keySet());
        // Exclude both PK and FK from UPDATE SET:
        //  - PK is IDENTITY-generated, never updated.
        //  - FK is the natural key used for the MERGE ON clause; updating it
        //    would break the predicate and trigger ORA-38104 on the next MERGE.
        String updateSet = cols.stream()
                .filter(c -> !c.equals(pkColumn) && !c.equals(fkColumn))
                .map(c -> "tab." + c + " = src." + c)
                .collect(Collectors.joining(", "));

        String srcCols = cols.stream()
                .map(c -> ":" + c + " AS " + c)
                .collect(Collectors.joining(", "));

        String sql = String.format("""
            MERGE INTO %s tab
            USING (SELECT %s FROM DUAL) src
            ON (tab.%s = src.%s)
            WHEN MATCHED THEN UPDATE SET %s
            WHEN NOT MATCHED THEN INSERT (%s) VALUES (%s)
            """,
            oracleTable,
            srcCols,
            fkColumn, fkColumn,
            updateSet,
            String.join(", ", cols),
            cols.stream().map(c -> "src." + c).collect(Collectors.joining(", "))
        );

        MapSqlParameterSource params = new MapSqlParameterSource();
        for (Map.Entry<String, Object> e : decRow.entrySet()) {
            params.addValue(e.getKey(), e.getValue());
        }

        jdbc.update(sql, params);
    }

    private String executeMatricula(CdcEvent event, TableRouter.RoutingDecision decision) {
        OperationContext ctx = new OperationContext(
                event.tableName(),
                decision.oracleTable(),
                decision.oracleSchema(),
                decision.pkColumn(),
                event.isInsert(),
                event.isUpdate(),
                event.isDelete()
        );

        if (event.isDelete()) {
            Object pk = event.before() != null ? event.before().get("pk_tmatricula") : null;
            if (pk != null) {
                writer.delete(decision.oracleTable(), decision.pkColumn(), pk);
            }
            return decision.oracleTable();
        }

        Optional<Map<String, Object>> consolidatedOpt = matriculaConsolidator.apply(event, ctx);
        if (consolidatedOpt.isEmpty()) return null;
        Map<String, Object> row = consolidatedOpt.get();

        Object pk = row.get(decision.pkColumn());
        if (pk == null) {
            throw new RuntimeException("PK no encontrada en fila Oracle: " + decision.oracleTable());
        }
        writer.merge(decision.oracleTable(), decision.pkColumn(), row);
        return decision.oracleTable();
    }

    // ─────────────────────────────────────────────────────────────────────
    // Phase 3 L4-L6 dispatch — adapter layer over the Phase 2 transformers
    // ─────────────────────────────────────────────────────────────────────

    /**
     * Build the source-table → adapter map for the Phase 2 transformers.
     * Each handler converts the transformer's idiosyncratic output
     * (Map / List<Split> / Decision / void) into a uniform {@link RouteResult}
     * that {@link #executeL4L6} can iterate and write.
     *
     * <p>The transformer instances are captured by reference, so the
     * stateful {@link TEstablecimientoFkCycleTransformer} maintains its
     * pending-FKs queue across the whole worker lifetime (Spring beans are
     * singletons by default).
     */
    /**
     * Deprecated: L4/L5/L6 dispatch is now loaded from the
     * {@code l4l6_routes:} block of {@code transforms/table-routing.yaml}
     * by {@link L4L6RouteLoader} at bean construction time and injected
     * into this class's last constructor parameter.
     *
     * <p>This method is kept (returning an empty map) for any pre-existing
     * test or builder that doesn't go through Spring; production wiring
     * always uses the constructor + YAML loader path.
     */
    @Deprecated
    private Map<String, PhaseRoute> buildL4L6Routes() {
        return Map.of();
    }

    /**
     * Old Phase 2 handler adapters (wrapMatricula, wrapPeriodoSplits) used to
     * live here; they were extracted into {@link L4L6RouteLoader} when the
     * dispatch table moved to YAML. Each adapter is now resolved by handler
     * class name from the loader's {@link L4L6RouteLoader.L4L6HandlerRegistry}.
     */

    /**
     * Apply the {@link PhaseRoute} for an L4-L6 table: dispatch DELETE first
     * (the Phase 2 transformers do not all handle Operation.DELETE),
     * otherwise emit each Split via {@link OracleJdbcWriter#merge} and
     * translate any {@link TEstablecimientoFkCycleTransformer.DeferredUpdate}
     * returned by the cycle transformer into follow-up UPDATEs on
     * TESTABLECIMIENTO.
     */
    private String executeL4L6(CdcEvent event, PhaseRoute route) {
        if (event.isDelete()) {
            return executeL4L6Delete(event, route);
        }

        RouteResult result = route.handler().apply(event);
        String lastTable = route.oracleTable();

        for (Split split : result.splits()) {
            if (split.row() == null || split.row().isEmpty()) {
                // Transformer returned an empty result — log at trace level
                // (the transformer itself usually already WARN-ed).
                continue;
            }
            writer.merge(split.oracleTable(), split.pkColumn(), split.row());
            lastTable = split.oracleTable();
        }

        // Deferred FK updates from the TARCHIVO/TESTABLECIMIENTO cycle.
        // Each one fixes the FK_TARCHIVO column on a previously-merged
        // TESTABLECIMIENTO row once the referenced TARCHIVO is now in place.
        for (TEstablecimientoFkCycleTransformer.DeferredUpdate du : result.deferredUpdates()) {
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("PK_TESTABLECIMIENTO", du.pkEstablecimiento());
            row.put("FK_TARCHIVO", du.fkArchivo());
            writer.merge("TESTABLECIMIENTO", "PK_TESTABLECIMIENTO", row);
            lastTable = "TESTABLECIMIENTO";
        }

        return lastTable;
    }

    /**
     * DELETE handling for L4-L6 tables. The Phase 2 transformers do not all
     * cope with {@code Operation.DELETE} (TPeriodoAcademicoConfigSplitter
     * dereferences {@code event.after()} which is null on DELETE;
     * TGrupoFkRewriter returns an empty map; TSedeUsuarioPkTransformer
     * returns an empty map). The dispatcher therefore routes DELETEs
     * directly through {@link OracleJdbcWriter#delete} using the
     * route's declared {@code pkColumn}, with two carve-outs:
     * <ul>
     *   <li>{@code tarchivo} — the BLOB dropper performs its own DELETE
     *       via the writer, so we delegate to it (it is idempotent for
     *       re-deliveries).</li>
     *   <li>Composite-PK tables — {@code OracleJdbcWriter.delete} only
     *       supports single-column WHERE clauses. We log WARN + skip until
     *       a composite-PK delete overload lands on the writer.</li>
     * </ul>
     */
    private String executeL4L6Delete(CdcEvent event, PhaseRoute route) {
        String pgTable = event.tableName();
        String oracleTable = route.oracleTable();
        String pkColumn = route.pkColumn();

        if ("tarchivo".equals(pgTable)) {
            // TArchivoBlobDropper is idempotent for re-deliveries and is the
            // canonical DELETE path for BLOBs — let it do its job.
            archivoBlobDropper.apply(event);
            return "TARCHIVO";
        }

        if (pkColumn.startsWith("(") && pkColumn.endsWith(")")) {
            log.warn("DELETE on {} with composite PK {} not yet supported by OracleJdbcWriter; skipping",
                    pgTable, pkColumn);
            return oracleTable;
        }

        Object pk = event.before() != null ? event.before().get(pkColumn.toLowerCase()) : null;
        if (pk != null) {
            writer.delete(oracleTable, pkColumn, pk);
        } else {
            log.warn("DELETE on {} without before.{} to resolve the Oracle PK; skipping",
                    pgTable, pkColumn.toLowerCase());
        }
        return oracleTable;
    }

    /**
     * Route entry for one of the L4-L6 tables. The handler accepts the
     * CDC event and returns the rows to write plus any deferred FK
     * updates that {@link #executeL4L6} must apply after the initial merges.
     */
    public record PhaseRoute(
            String oracleTable,
            String pkColumn,
            Function<CdcEvent, RouteResult> handler) {
    }

    /**
     * Adapter-layer output: zero or more splits to MERGE, plus zero or more
     * deferred FK updates to apply in declaration order after the initial
     * merges have completed. Used only inside {@link OracleReverseStage}.
     */
    public record RouteResult(
            List<Split> splits,
            List<TEstablecimientoFkCycleTransformer.DeferredUpdate> deferredUpdates) {
        static RouteResult empty() {
            return new RouteResult(List.of(), List.of());
        }
    }

    /**
     * Local view of one Oracle row write — destructured from each
     * transformer so the dispatcher can iterate uniformly. The
     * {@link TPeriodoAcademicoConfigSplitter.Split} record has the same
     * shape, but the conversion keeps a single representation live inside
     * this stage.
     */
    public record Split(
            String oracleTable,
            String pkColumn,
            Map<String, Object> row) {
    }

    /**
     * Reads {@code cdc.tables.<lower-case source table name>.enabled} from
     * the {@link Environment}. When the flag is absent the table is treated
     * as enabled (default-on), so existing deploys that pre-date this gate
     * are unaffected. Recognises both {@code false} (skip) and unset (run).
     *
     * <p>The toggle consults the <em>PG source</em> table name (e.g.
     * {@code tactividad}), not the Oracle destination (e.g.
     * {@code TACTIVIDAD}), because operators turn tables off at the source
     * of the event (the data they want to drop from the sync), not at the
     * destination.
     */
    private boolean isTableEnabled(String sourceTable) {
        if (sourceTable == null || sourceTable.isEmpty()) return true;
        Boolean enabled = env.getProperty(
                "cdc.tables." + sourceTable.toLowerCase() + ".enabled",
                Boolean.class);
        return enabled == null || enabled;
    }
}
