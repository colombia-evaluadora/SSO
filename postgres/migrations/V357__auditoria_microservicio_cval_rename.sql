-- ============================================================================
-- V357 — rename audit-clickhouse -> audit-clickhouse-cval.
--
-- POR QUE
--   V356 dejó la fila existente con serviceid = 'audit-clickhouse' (no
--   la renombró, ver "QUE NO HACE" en V356). Eso deja el catálogo
--   asimétrico: pigse tiene sufijo (-pigse) pero CEVAL no (-ch en el
--   requesturi, serviceid suelto). El operador pidió nombres
--   simétricos: audit-clickhouse-cval y audit-clickhouse-pigse. Mismo
--   patrón, mismo sufijo de app.
--
-- QUE RENOMBRA
--   1. serviceid:    'audit-clickhouse'         -> 'audit-clickhouse-cval'
--   2. instancename: 'audit-clickhouse'         -> 'audit-clickhouse-cval'
--      El provisioner deriva el nombre del contenedor de instanceName
--      (eurekaServiceId en InternalGatewayController toma
--      instanceName || dialect). Con el cambio, el contenedor nuevo
--      se llamará `query-service-audit-clickhouse-cval` y se registrará
--      en Eureka con ese id -- las rutas dinámicas del gateway
--      (CatalogRoutesRefresher) las emitirán bajo el nuevo id.
--   3. requesturi:   '/api/audit-ch/**'         -> '/api/audit-cval/**'
--      Para simetría con '/api/audit-pigse/**' (la requesturi de
--      audit-clickhouse-pigse creada en V356).
--   4. description:  reescrita para llamarlo "Colombia Evaluadora" en
--      vez del genérico "Auditoría de solo lectura".
--
-- QUE PASA CON id_microservice
--   NO cambia. V356 amarró las 8 queries de CEVAL al id_microservice
--   de la fila original; ese id se mantiene, así que las queries
--   siguen apuntando al row renombrado sin necesidad de UPDATE masivo.
--   La verificación al final cuenta queries por serviceid para
--   confirmar.
--
-- QUE PASA CON EL CONTENEDOR VIEJO
--   El provisioner sidecar crea un contenedor NUEVO al ver el
--   instanceName cambiado (query-service-audit-clickhouse-cval). El
--   contenedor VIEJO query-service-audit-clickhouse queda corriendo
--   hasta que un operador lo pare -- el provisioner no garbage-collecta
--   instancias cuyo instanceName desapareció del catálogo. En este
--   ambiente eso es manual:
--     docker stop query-service-audit-clickhouse
--     docker rm   query-service-audit-clickhouse
--   antes de mergear a main, o después del primer deploy que aplique
--   V357 (los ambientes nuevos jamás tendrán el viejo).
--
-- QUE PASA CON EL FRONT
--   El front CEVAL pasa de llamar '/api/audit-ch/...' a '/api/audit-cval/...'.
--   Es un cambio de proxy/VITE_API_PROXY_TARGET: no del cliente (la
--   query-service nunca expone ese prefijo al cliente, lo StripPrefix
--   el gateway antes de forwardear). Verificar el dev-server local
--   con `grep -R '/api/audit-ch' src/`.
-- ============================================================================

UPDATE public.microservice
   SET serviceid     = 'audit-clickhouse-cval',
       instancename  = 'audit-clickhouse-cval',
       description   = 'Auditoría Colombia Evaluadora de solo lectura (ClickHouse) — gemelo de audit-clickhouse-pigse con esquema academico_test.* hardcodeado en cada WHERE. Provisioner sidecar levanta query-service-audit-clickhouse-cval enrutado bajo /api/audit-cval/**',
       requesturi    = '/api/audit-cval/**'
 WHERE serviceid = 'audit-clickhouse';

-- ---------------------------------------------------------------------------
-- Verificación: las 8 queries de CEVAL (las que V356 ató a
-- id_microservice del row original) deben seguir resueltas bajo
-- serviceid='audit-clickhouse-cval' ahora.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_cval       BIGINT;
    v_pigse      BIGINT;
    v_orphan     BIGINT;
BEGIN
    SELECT count(*) FILTER (WHERE m.serviceid = 'audit-clickhouse-cval'),
           count(*) FILTER (WHERE m.serviceid = 'audit-clickhouse-pigse')
      INTO v_cval, v_pigse
      FROM public.query q
      JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE q.path_template LIKE '/audit-%'
        OR q.path_template LIKE '/audits/%';

    RAISE NOTICE 'V357 queries por microservicio: cval=% pigse=% (esperado 8 y 8)', v_cval, v_pigse;

    SELECT count(*) INTO v_orphan
      FROM public.query q
      JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE (q.path_template LIKE '/audit-%' OR q.path_template LIKE '/audits/%')
       AND m.serviceid NOT IN ('audit-clickhouse-cval', 'audit-clickhouse-pigse');

    IF v_orphan > 0 THEN
        RAISE EXCEPTION 'V357 fallo: % queries de auditoria quedaron en un microservicio distinto a cval/pigse', v_orphan;
    ELSE
        RAISE NOTICE 'V357 OK: ninguna query de auditoria huérfana';
    END IF;
END $$;
