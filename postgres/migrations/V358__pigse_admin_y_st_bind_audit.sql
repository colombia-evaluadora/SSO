-- ============================================================================
-- V358 — vincula las 9 filas de catálogo de auditoría del microservicio
--        PIGSE (V356) a los roles PIGSE-ADMINISTRADOR y
--        PIGSE-SECRETARIA_TERRITORIAL.
--
-- POR QUE ESTOS DOS ROLES
--   Mismo criterio que V87 usó para CEVAL-SUPER_ADMINISTRADOR: el
--   histórico de auditoría (quién mutó qué, desde qué IP, en qué
--   sesión) es información sensible -- a quién más dárselo es una
--   decisión de negocio. V149 ya emparejó PIGSE-ADMINISTRADOR con
--   PIGSE-SECRETARIA_TERRITORIAL para los endpoints de monitoreo /
--   cumplimiento (V149 L129), y la consulta de auditoría encaja
--   exactamente en esa lectura: ambos perfiles necesitan ver qué
--   hicieron los demás usuarios de su esquema, no operar sobre los
--   datos.
--
--   Otros roles PIGSE (RECTOR, JEFE_*, AUXILIAR_ADMINISTRATIVO,
--   RESPONSABLE_CARGUE) son de operación, no de fiscalización -- no
--   entran acá. Si más adelante se decide dar acceso a un rol nuevo
--   o a un rol existente, se agrega otra INSERT siguiendo este
--   mismo patrón sin tocar V358.
--
-- QUE NO SE NECESITA TOCAR
--   - public.query: V356 ya duplicó las 9 queries (1.1, 1.2, 1.3,
--     1.4, 1.6 + 2.2, 2.3, 2.4, 2.5) contra el microservicio
--     audit-clickhouse-pigse. La identidad de cada query (su
--     id_query) se preserva al cruzar el INSERT de role_query: lo
--     que se inserta acá son (role_id, query_id) cruzados contra
--     esas filas que ya existen.
--   - public.microservice: V356 creó audit-clickhouse-pigse, V357
--     renombró audit-clickhouse -> audit-clickhouse-cval. El
--     serviceid que esta migración referencia es estable.
--
-- IDEMPOTENCIA
--   ON CONFLICT DO NOTHING cubre re-ejecuciones. La UNIQUE de
--   role_query (role_id, query_id) es lo que se respeta (mismo
--   patrón que V87).
-- ============================================================================

INSERT INTO public.role_query (role_id, query_id)
SELECT
    r.id_role,
    q.id_query
FROM public.query q
CROSS JOIN public.role r
WHERE q.microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse-pigse')
  AND r.name IN ('PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Verificación: las 9 queries del microservicio PIGSE deben estar
-- vinculadas a AMBOS roles (18 filas totales). Cero huerfanas.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_admin   BIGINT;
    v_st      BIGINT;
    v_total_q BIGINT;
    v_orphan  BIGINT;
BEGIN
    SELECT count(*) INTO v_total_q
      FROM public.query
     WHERE microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse-pigse');

    SELECT count(*) INTO v_admin
      FROM public.role_query rq
      JOIN public.role r ON r.id_role = rq.role_id
     WHERE r.name = 'PIGSE-ADMINISTRADOR'
       AND rq.query_id IN (SELECT id_query FROM public.query
                           WHERE microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse-pigse'));

    SELECT count(*) INTO v_st
      FROM public.role_query rq
      JOIN public.role r ON r.id_role = rq.role_id
     WHERE r.name = 'PIGSE-SECRETARIA_TERRITORIAL'
       AND rq.query_id IN (SELECT id_query FROM public.query
                           WHERE microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse-pigse'));

    SELECT count(*) INTO v_orphan
      FROM public.query q
      LEFT JOIN public.role_query rq ON rq.query_id = q.id_query
      LEFT JOIN public.role r ON r.id_role = rq.role_id AND r.name IN ('PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL')
     WHERE q.microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse-pigse')
       AND rq.id_role_query IS NULL;

    RAISE NOTICE 'V358 queries del microservicio PIGSE: total=% binds_admin=% binds_st=%', v_total_q, v_admin, v_st;

    IF v_orphan > 0 THEN
        RAISE EXCEPTION 'V358 fallo: % queries del microservicio PIGSE sin bind para PIGSE-ADMINISTRADOR ni PIGSE-SECRETARIA_TERRITORIAL', v_orphan;
    END IF;
    IF v_admin != v_total_q OR v_st != v_total_q THEN
        RAISE EXCEPTION 'V358 fallo: bindings incompletos (admin=%/st=% vs esperado % cada uno)', v_admin, v_st, v_total_q;
    END IF;

    RAISE NOTICE 'V358 OK: % queries bindadas a ambos roles', v_total_q;
END $$;
