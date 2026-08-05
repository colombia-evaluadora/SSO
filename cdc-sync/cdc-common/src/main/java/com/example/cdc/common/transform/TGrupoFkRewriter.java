package com.example.cdc.common.transform;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.snapshot.SnapshotCache;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.*;

public class TGrupoFkRewriter {
    private static final Logger log = LoggerFactory.getLogger(TGrupoFkRewriter.class);

    private final SnapshotCache cache;

    public TGrupoFkRewriter(SnapshotCache cache) {
        this.cache = cache != null ? cache : SnapshotCache.empty();
    }

    public Map<String, Object> apply(CdcEvent event) {
        Map<String, Object> row = event.after();
        Map<String, Object> out = new LinkedHashMap<>();
        if (row != null) {
            for (Map.Entry<String, Object> e : row.entrySet()) {
                out.put(e.getKey().toUpperCase(), e.getValue());
            }
        }
        Object jornadaRaw = row != null ? row.get("fk_tlv_jornada") : null;
        String jornadaKey = jornadaRaw != null ? jornadaRaw.toString() : null;
        Long jornadaOracle = (jornadaKey != null) ? cache.jornadaReverseMap().get(jornadaKey) : null;
        if (jornadaKey != null && jornadaOracle == null) {
            log.warn("TGrupoFkRewriter jornada lookup miss for codigo='{}' — setting FK_TJORNADA=null",
                    jornadaKey);
        }
        out.put("FK_TJORNADA", jornadaOracle);

        Object modeloRaw = row != null ? row.get("fk_tlv_modelo_pedagogico") : null;
        String modeloKey = modeloRaw != null ? modeloRaw.toString() : null;
        Long modeloOracle = (modeloKey != null) ? cache.modeloPedagogicoReverseMap().get(modeloKey) : null;
        if (modeloKey != null && modeloOracle == null) {
            log.warn("TGrupoFkRewriter modeloPedagogico lookup miss for codigo='{}' — setting FK_TMODELO_PEDAGOGICO=null",
                    modeloKey);
        }
        out.put("FK_TMODELO_PEDAGOGICO", modeloOracle);

        out.remove("FK_TLV_JORNADA");
        out.remove("FK_TLV_MODELO_PEDAGOGICO");
        out.remove("FK_TPLAN");
        return out;
    }
}