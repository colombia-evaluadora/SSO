package com.example.cdc.common.transform;

import com.example.cdc.common.event.CdcEvent;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.util.HashMap;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Flatten TACTIVIDAD_NOTA PG (pivote FK_TACTIVIDAD_ESTUDIANTE) back to Oracle
 * inline FK_TACTIVIDAD + FK_TMATRICULA.
 *
 * <p>Reverse of {@code actividad_pivot.py} (migration phase 1): where phase 1
 * pivoted the Oracle monolito TACTIVIDAD_NOTA into a PG pair
 * (TACTIVIDAD_ESTUDIANTE + TACTIVIDAD_NOTA), this flattener reconstructs the
 * Oracle shape by looking up the parent row in the
 * {@code (pk_tactividad_estudiante) -> (fk_tactividad, fk_tmatricula)} cache.
 *
 * <p>MVP: cache is mutable (a ConcurrentHashMap is used as the backing store)
 * so the wiring layer can hydrate it post-construction via
 * {@link #setParentCache(Map)} without needing re-instantiation. A later task
 * will wire this cache from a snapshot of TACTIVIDAD_ESTUDIANTE on startup.
 */
@Component
public class TActividadFlattener implements Transformer {

    private static final Logger log = LoggerFactory.getLogger(TActividadFlattener.class);

    private final Map<Long, ParentFks> parentCache;
    private final AtomicBoolean warnedOnce = new AtomicBoolean(false);

    public TActividadFlattener() {
        this(new ConcurrentHashMap<>());
    }

    public TActividadFlattener(Map<Long, ParentFks> parentCache) {
        // Wrap any externally-supplied cache in a ConcurrentHashMap so subsequent
        // puts from the wiring layer don't trip "Immutable map" exceptions.
        this.parentCache = new ConcurrentHashMap<>(
                parentCache == null ? Map.of() : parentCache);
    }

    /**
     * Replace the cache atomically. Intended for the wiring layer to populate
     * the flattener once the parent (TACTIVIDAD_ESTUDIANTE) snapshot is loaded.
     */
    public void setParentCache(Map<Long, ParentFks> cache) {
        parentCache.clear();
        if (cache != null) parentCache.putAll(cache);
    }

    /** Read-only view of the current cache for diagnostics and tests. */
    public Map<Long, ParentFks> getParentCache() {
        return Map.copyOf(parentCache);
    }

    /** Parent FK pair looked up by {@code pk_tactividad_estudiante}. */
    public record ParentFks(Long fkTactividad, Long fkTmatricula) {}

    @Override
    public Optional<Map<String, Object>> apply(CdcEvent event, OperationContext ctx) {
        Map<String, Object> row = event.after() != null ? event.after() : event.before();
        if (row == null) return Optional.empty();

        Object pkParentObj = row.get("fk_tactividad_estudiante");
        if (pkParentObj == null) return Optional.empty();

        Long pkParent = toLong(pkParentObj);
        if (pkParent == null) return Optional.empty();

        ParentFks parent = parentCache.get(pkParent);
        if (parent == null) {
            if (parentCache.isEmpty() && warnedOnce.compareAndSet(false, true)) {
                log.warn("TActividadFlattener parentCache is empty — tactividad_estudiante events will be skipped. "
                        + "This should be hydrated by a future wiring task.");
            }
            return Optional.empty();
        }

        Map<String, Object> out = new HashMap<>();
        for (Map.Entry<String, Object> e : row.entrySet()) {
            out.put(e.getKey().toUpperCase(), e.getValue());
        }
        if (parent.fkTactividad() != null) {
            out.put("FK_TACTIVIDAD", parent.fkTactividad());
        }
        if (parent.fkTmatricula() != null) {
            out.put("FK_TMATRICULA", parent.fkTmatricula());
        }
        out.remove("FK_TACTIVIDAD_ESTUDIANTE");
        return Optional.of(out);
    }

    private static Long toLong(Object v) {
        if (v instanceof Number n) return n.longValue();
        if (v instanceof String s) {
            try { return Long.parseLong(s); } catch (NumberFormatException ignored) { return null; }
        }
        return null;
    }
}
