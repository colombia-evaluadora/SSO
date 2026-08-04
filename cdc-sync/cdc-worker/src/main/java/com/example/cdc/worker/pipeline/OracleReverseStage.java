package com.example.cdc.worker.pipeline;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.routing.TableRouter;
import com.example.cdc.common.transform.OperationContext;
import com.example.cdc.common.transform.TMatriculaConsolidator;
import com.example.cdc.common.transform.TUsuarioDecomposer;
import com.example.cdc.common.transform.TlistaValorSplitter;
import com.example.cdc.common.transform.Transformer;
import com.example.cdc.worker.oracle.OracleJdbcWriter;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
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
     * All {@link Transformer} beans injected by Spring, keyed by their simple
     * class name. Used to honor the {@code transformers} list in
     * {@code table-routing.yaml} so that adding a new transformer in the YAML
     * actually changes the runtime behavior.
     */
    private final Map<String, Transformer> transformers;

    public OracleReverseStage(TableRouter router, OracleJdbcWriter writer,
                              NamedParameterJdbcTemplate jdbc,
                              TlistaValorSplitter splitter,
                              TUsuarioDecomposer decomposer,
                              TMatriculaConsolidator matriculaConsolidator,
                              List<Transformer> transformers) {
        this.router = router;
        this.writer = writer;
        this.jdbc = jdbc;
        this.splitter = splitter;
        this.decomposer = decomposer;
        this.matriculaConsolidator = matriculaConsolidator;
        // Spring autowires all Transformer beans; key them by simple class name
        // so the routing YAML's string identifiers resolve deterministically.
        this.transformers = new HashMap<>();
        for (Transformer t : transformers) {
            this.transformers.put(t.getClass().getSimpleName(), t);
        }
    }

    public String execute(CdcEvent event) throws Exception {
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

        // UPSERT keyed by FK_TO_PARENT (the parent PK is a stable natural key
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
}