-- ===========================================================================
-- V95.1 - role_query: el coordinador puede listar, ver y exportar las sedes
--         de su establecimiento (solo lectura).
--
--   POST /establecimientos/sedes/query   (q-msq9aw73-qjaksdbn)   <- la tabla
--   GET  /establecimientos/sedes/:ID     (q-msridyb1-23ev0r9f)
--   POST /establecimientos/sedes/reporte (eval-col-sedes-reporte-001)
--
-- Por que: V95 no ato CEVAL-COORDINADOR a estas queries y query-service
-- respondia 403 antes de llegar a Postgres. El alcance lo siguen decidiendo
-- los gates de fn_sed_* (menu SEDES_EDUCATIVAS VER + fn_usuario_sedes_lectura).
-- Depende de: V95 (crea las filas de public.query). Idempotente.
-- ===========================================================================

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.role r ON r.name = 'CEVAL-COORDINADOR'
 WHERE q.uuid IN ('q-msq9aw73-qjaksdbn',
                  'q-msridyb1-23ev0r9f',
                  'eval-col-sedes-reporte-001')
   AND NOT EXISTS (
       SELECT 1 FROM public.role_query rq
        WHERE rq.query_id = q.id_query AND rq.role_id = r.id_role
   );
