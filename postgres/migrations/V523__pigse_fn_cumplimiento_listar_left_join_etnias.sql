-- V521 reescribió pigse.fn_documentos_listar para que el tipo no aplicable
-- (PEI/PMI vs PEC/PFI, según ETNIAS) directamente NO aparezca en el
-- resultado -- antes devolvía una fila con status NO_APLICA.
--
-- pigse.fn_cumplimiento_listar (V261, nunca tocada por V521) sigue
-- exigiendo, vía tres JOIN LATERAL (no LEFT), que fn_documentos_listar
-- devuelva SIEMPRE una fila con id='PEI', una con id='PEC' Y una con
-- id='PMI' para el mismo establecimiento. Desde V521 eso ya no pasa nunca
-- (todo establecimiento tiene ETNIAS='S' o 'N', nunca ambos PEI/PEC ni
-- ambos PMI/PFI a la vez) -- el three-way join no matchea para NINGÚN
-- establecimiento y "Monitoreo y cumplimiento institucional" quedó con la
-- tabla de detalle vacía, aunque las tarjetas de arriba (que salen de
-- fn_cumplimiento_metricas, sí corregida en V521) siguen mostrando bien.
--
-- Fix: LEFT JOIN LATERAL en vez de JOIN LATERAL (un establecimiento puede
-- no tener fila para un tipo dado), con COALESCE a 'NO_APLICA' cuando no
-- hay fila -- mismo resultado visual que antes de V521. Se agrega además
-- la columna "pfi" (antes no existía en este RETURNS TABLE) para que el
-- global progress cuente PEC+PFI en vez de seguir ignorando PFI, y para
-- que el front tenga el dato disponible cuando se actualice para
-- mostrarlo (pendiente, feature de monitoreo aparte).
DROP FUNCTION IF EXISTS pigse.fn_cumplimiento_listar();

CREATE FUNCTION pigse.fn_cumplimiento_listar()
RETURNS TABLE(
    id BIGINT, "establishmentName" TEXT, pei JSONB, pec JSONB, pmi JSONB, pfi JSONB,
    "globalProgress" INTEGER
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        te.PK_ESTABLECIMIENTO AS id,
        te.NOMBRE AS "establishmentName",
        jsonb_build_object('status', COALESCE(d_pei.status, 'NO_APLICA'), 'fileName', d_pei."fileName",
                            'archivoId', d_pei."archivoId", 'downloadUrl', d_pei."downloadUrl") AS pei,
        jsonb_build_object('status', COALESCE(d_pec.status, 'NO_APLICA'), 'fileName', d_pec."fileName",
                            'archivoId', d_pec."archivoId", 'downloadUrl', d_pec."downloadUrl") AS pec,
        jsonb_build_object('status', COALESCE(d_pmi.status, 'NO_APLICA'), 'fileName', d_pmi."fileName",
                            'archivoId', d_pmi."archivoId", 'downloadUrl', d_pmi."downloadUrl") AS pmi,
        jsonb_build_object('status', COALESCE(d_pfi.status, 'NO_APLICA'), 'fileName', d_pfi."fileName",
                            'archivoId', d_pfi."archivoId", 'downloadUrl', d_pfi."downloadUrl") AS pfi,
        CASE
            WHEN (CASE WHEN COALESCE(d_pei.status, 'NO_APLICA') <> 'NO_APLICA' THEN 1 ELSE 0 END
                  + CASE WHEN COALESCE(d_pec.status, 'NO_APLICA') <> 'NO_APLICA' THEN 1 ELSE 0 END
                  + CASE WHEN COALESCE(d_pmi.status, 'NO_APLICA') <> 'NO_APLICA' THEN 1 ELSE 0 END
                  + CASE WHEN COALESCE(d_pfi.status, 'NO_APLICA') <> 'NO_APLICA' THEN 1 ELSE 0 END) = 0 THEN 0
            ELSE round(
                100.0 * (
                    CASE WHEN d_pei.status = 'COMPLETO' THEN 1 ELSE 0 END
                    + CASE WHEN d_pec.status = 'COMPLETO' THEN 1 ELSE 0 END
                    + CASE WHEN d_pmi.status = 'COMPLETO' THEN 1 ELSE 0 END
                    + CASE WHEN d_pfi.status = 'COMPLETO' THEN 1 ELSE 0 END
                ) / (
                    CASE WHEN COALESCE(d_pei.status, 'NO_APLICA') <> 'NO_APLICA' THEN 1 ELSE 0 END
                    + CASE WHEN COALESCE(d_pec.status, 'NO_APLICA') <> 'NO_APLICA' THEN 1 ELSE 0 END
                    + CASE WHEN COALESCE(d_pmi.status, 'NO_APLICA') <> 'NO_APLICA' THEN 1 ELSE 0 END
                    + CASE WHEN COALESCE(d_pfi.status, 'NO_APLICA') <> 'NO_APLICA' THEN 1 ELSE 0 END
                )
            )
        END AS "globalProgress"
      FROM pigse.testablecimiento te
      LEFT JOIN LATERAL (
              SELECT * FROM pigse.fn_documentos_listar(te.PK_ESTABLECIMIENTO) WHERE id = 'PEI'
          ) d_pei ON true
      LEFT JOIN LATERAL (
              SELECT * FROM pigse.fn_documentos_listar(te.PK_ESTABLECIMIENTO) WHERE id = 'PEC'
          ) d_pec ON true
      LEFT JOIN LATERAL (
              SELECT * FROM pigse.fn_documentos_listar(te.PK_ESTABLECIMIENTO) WHERE id = 'PMI'
          ) d_pmi ON true
      LEFT JOIN LATERAL (
              SELECT * FROM pigse.fn_documentos_listar(te.PK_ESTABLECIMIENTO) WHERE id = 'PFI'
          ) d_pfi ON true
     WHERE te.ACTIVE
     ORDER BY te.NOMBRE;
$$;

COMMENT ON FUNCTION pigse.fn_cumplimiento_listar() IS
    'V523: LEFT JOIN LATERAL (antes JOIN) -- desde V521 fn_documentos_listar no devuelve fila para el tipo no aplicable (ETNIAS), el INNER JOIN de tres vías dejaba la tabla siempre vacía. Agrega columna "pfi" y el global progress ahora cuenta PEC+PFI o PEI+PMI según aplique.';

-- fn_cumplimiento_listar_paginado (misma migración, sin cambios de firma:
-- sigue haciendo `SELECT * FROM pigse.fn_cumplimiento_listar()` y
-- `to_jsonb(p) - 'rn'`, así que la columna "pfi" nueva viaja sola en el
-- JSON de cada fila sin tocar esa función.
