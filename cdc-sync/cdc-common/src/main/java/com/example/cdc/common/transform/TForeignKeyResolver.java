package com.example.cdc.common.transform;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.snapshot.SnapshotCache;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Optional;

/**
 * Generic transformer that resolves every {@code FK_TLV_<X>} column on a CDC
 * row from its PG codigo to the corresponding Oracle numeric PK, using the
 * {@link SnapshotCache#tlistaValorIndex} ({@code categoria → codigo → PK})
 * hydrated at worker boot.
 *
 * <p>The mapping convention is:
 * <ul>
 *   <li>Column:   {@code FK_TLV_<X>}</li>
 *   <li>Categoria: {@code <X>} by default; overridden via the YAML
 *       {@code overrides:} map (see {@code transforms/fk-resolver.yaml}).</li>
 *   <li>Oracle output column: {@code FK_<X>}.</li>
 * </ul>
 *
 * <p>The two legacy narrow reverse maps ({@link SnapshotCache#jornadaReverseMap}
 * and {@link SnapshotCache#modeloPedagogicoReverseMap}) are NOT consulted —
 * those continue to back {@code TGrupoFkRewriter} via direct accessor. This
 * resolver and {@code TGrupoFkRewriter} are mutually exclusive at runtime:
 * a table with a custom resolver set up in the routing YAML runs only this
 * resolver, never both.
 *
 * <p>Misses (no PK in the cache for the codigo) emit a WARN with the codigo
 * and write {@code null} for the Oracle FK — never throw, never skip the
 * event. That preserves the existing fail-soft contract used by
 * {@code TGrupoFkRewriter}.
 */
public class TForeignKeyResolver implements Transformer {

    private static final Logger log = LoggerFactory.getLogger(TForeignKeyResolver.class);
    private static final String PREFIX = "FK_TLV_";

    private final SnapshotCache cache;
    private final Map<String, String> columnToCategoria;

    public TForeignKeyResolver() {
        this(SnapshotCache.empty(), Map.of());
    }

    public TForeignKeyResolver(SnapshotCache cache, Map<String, String> columnToCategoria) {
        this.cache = cache != null ? cache : SnapshotCache.empty();
        this.columnToCategoria = columnToCategoria != null ? columnToCategoria : Map.of();
    }

    @Override
    public Optional<Map<String, Object>> apply(CdcEvent event, OperationContext ctx) {
        Map<String, Object> row = event.after();
        if (row == null) return Optional.of(Map.of());

        Map<String, Object> out = new LinkedHashMap<>(row);

        for (String col : new ArrayList<>(out.keySet())) {
            String upper = col.toUpperCase();
            if (!upper.startsWith(PREFIX)) continue;
            String categoria = categoriaFor(upper);
            Object codigo = out.get(col);
            Long oraclePk = resolve(categoria, codigo);
            if (codigo != null && oraclePk == null) {
                log.warn("TForeignKeyResolver miss on {}='{}' (categoria={}); setting Oracle FK=null",
                    upper, codigo, categoria);
            }
            String oracleCol = "FK_" + categoria;
            out.put(oracleCol, oraclePk);
            out.remove(col);
        }
        return Optional.of(out);
    }

    private String categoriaFor(String upperColumn) {
        String override = columnToCategoria.get(upperColumn);
        if (override != null) return override;
        return upperColumn.substring(PREFIX.length());
    }

    private Long resolve(String categoria, Object codigo) {
        if (codigo == null) return null;
        Map<String, Long> byCodigo = cache.tlistaValorIndex().get(categoria);
        if (byCodigo == null) return null;
        // The Debezium payload can deliver BIGINT codigos as Long, Integer,
        // or numeric String — see Specification §8 type coercion. We accept
        // all three and String-normalise before the HashMap get so that
        // distinct types don't accidentally fork the lookup key.
        return byCodigo.get(codigo.toString());
    }
}
