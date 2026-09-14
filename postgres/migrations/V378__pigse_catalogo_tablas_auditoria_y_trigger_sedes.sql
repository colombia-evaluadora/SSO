-- ============================================================================
-- V378 — "Por tablas" en Auditoría (PIGSE) mostraba "Sin tablas para
-- mostrar" incluso habiendo tablas reales con datos: la fila de catálogo
-- de /audit-tables/query armaba la lista con
-- `SELECT DISTINCT tabla FROM auditoria.audit_log WHERE tabla LIKE 'pigse.%'`
-- -- es decir, una tabla SOLO aparecía si YA tenía al menos una operación
-- auditada alguna vez. Una tabla recién creada (o una a la que nunca se le
-- conectó el trigger de auditoría) simplemente no existía para esta
-- pantalla, sin importar cuántas filas tuviera.
--
-- Encontrado revisando esto: pigse.TSEDE / pigse.TSEDE_USUARIO (V370,
-- el motor de sedes de esta misma sesión) NUNCA tuvieron el trigger
-- trg_audit_ctx instalado -- a diferencia de testablecimiento/tfuncionario/
-- etc., que sí lo tienen desde que se crearon. Con eso, crear/editar/
-- eliminar una sede JAMÁS iba a producir una fila en audit_log, sin
-- importar este fix de catálogo. Se corrige acá con el mismo patrón
-- idempotente ya usado en V261 (DO block sobre pg_tables + NOT EXISTS
-- contra pg_trigger, para no fallar si ya se aplicó a mano).
--
-- El catálogo de /audit-tables/query (fila de audit-clickhouse-pigse) deja
-- de derivar la lista de audit_log y pasa a enumerar EXPLÍCITAMENTE las
-- tablas reales de dominio de pigse que tienen el trigger de auditoría
-- (las 9 que ya lo tenían + tsede/tsede_usuario, agregadas acá) -- cada
-- una con su nombre visible y su ícono, en vez del nombre algorítmico
-- ("TSede" -> "Sede" adivinado a partir del nombre de columna) y el
-- ícono fijo 'Table-Icon' que además no resuelve a ningún ícono real del
-- front (getNavIcon no tiene un export "TableIcon" -- todas las tarjetas
-- caían al ícono genérico de interrogación sin que nadie lo notara).
--
-- El slug se sigue derivando con la MISMA fórmula algorítmica de antes
-- (no se toca): /audit-tables/:SLUG/operations/query reconstruye el
-- nombre de tabla A PARTIR del slug con esa fórmula a la inversa, así
-- que cambiar cómo se arma el slug rompería esa pantalla. Solo se
-- reemplaza qué tablas se listan (todas las reales, no solo las que ya
-- tuvieron actividad) y de dónde sale el nombre/ícono visible (catálogo
-- fijo en vez de adivinado).
--
-- Alcance: solo la fila de audit-clickhouse-pigse (18 tablas del schema
-- pigse son pocas y se pudieron catalogar a mano). academico_test tiene
-- 163 tablas -- CEVAL se deja con la derivación algorítmica existente
-- por ahora; si hace falta el mismo tratamiento ahí, es un trabajo
-- aparte (catalogar 163 nombres/íconos a mano no es proporcional a lo
-- reportado hoy).
-- ============================================================================

DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT t.schemaname, t.tablename
          FROM pg_tables t
         WHERE t.schemaname = 'pigse'
           AND t.tablename IN ('tsede', 'tsede_usuario')
           AND NOT EXISTS (
               SELECT 1
                 FROM pg_trigger tg
                 JOIN pg_class c     ON c.oid = tg.tgrelid
                 JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = t.schemaname
                  AND c.relname = t.tablename
                  AND tg.tgname = 'trg_audit_ctx'
                  AND NOT tg.tgisinternal
           )
         ORDER BY t.tablename
    LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_audit_ctx BEFORE INSERT OR UPDATE OR DELETE ON %I.%I
             FOR EACH STATEMENT EXECUTE FUNCTION academico_test.fn_audit_ctx()',
            r.schemaname, r.tablename
        );
        RAISE NOTICE 'trg_audit_ctx instalado en %.%', r.schemaname, r.tablename;
    END LOOP;
END $$;

UPDATE public.query q
   SET query = $Q$WITH raw AS (
    SELECT arrayJoin([
        ('pigse.tdocumento_institucional', 'Documentos Institucionales', 'FileTextIcon'),
        ('pigse.tdocumento_institucional_hist', 'Historial de Documentos Institucionales', 'ClockCountdownIcon'),
        ('pigse.tente', 'Entes Territoriales', 'BankIcon'),
        ('pigse.tente_establecimiento', 'Entes - Establecimientos', 'BuildingsIcon'),
        ('pigse.tente_usuario', 'Usuarios de Ente Territorial', 'UsersIcon'),
        ('pigse.testablecimiento', 'Establecimientos Educativos', 'BuildingsIcon'),
        ('pigse.testablecimiento_usuario', 'Usuarios de Establecimiento', 'UsersIcon'),
        ('pigse.tfuncionario', 'Funcionarios', 'IdentificationCardIcon'),
        ('pigse.tusuario', 'Usuarios', 'UserIcon'),
        ('pigse.tsede', 'Sedes Educativas', 'HouseLineIcon'),
        ('pigse.tsede_usuario', 'Usuarios de Sede', 'UsersIcon')
    ]) AS fila
),
catalogo AS (
    SELECT
        tupleElement(fila, 1) AS tabla_real,
        concat('t', arrayStringConcat(arrayMap(w -> concat(upper(substring(w,1,1)), lower(substring(w,2))), splitByChar('_', substring(tupleElement(fila, 1), length('pigse.') + 2))), '')) AS slug,
        tupleElement(fila, 2) AS name,
        tupleElement(fila, 3) AS icon
    FROM raw
)
SELECT
    c.slug,
    c.name,
    c.icon,
    countIf(a.tabla = c.tabla_real AND toDate(a.ts) = today() AND a.operacion != 'r') AS operationsToday,
    count() OVER() AS totalCount
FROM catalogo c
LEFT JOIN auditoria.audit_log a ON a.tabla = c.tabla_real
WHERE coalesce(:BODY.FILTERS.NAME, '') = '' OR positionCaseInsensitive(c.name, :BODY.FILTERS.NAME) > 0
GROUP BY c.slug, c.name, c.icon
ORDER BY c.name
LIMIT :BODY.PAGESIZE OFFSET :BODY.PAGEOFFSET;
$Q$
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid = 'audit-clickhouse-pigse'
   AND q.path_template = '/audit-tables/query';

DO $$
DECLARE
    v_trg_count INT;
    v_query_ok BOOLEAN;
BEGIN
    SELECT count(*) INTO v_trg_count
      FROM pg_trigger tg
      JOIN pg_class c ON c.oid = tg.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'pigse'
       AND c.relname IN ('tsede', 'tsede_usuario')
       AND tg.tgname = 'trg_audit_ctx'
       AND NOT tg.tgisinternal;

    SELECT (q.query ILIKE '%Sedes Educativas%' AND q.query ILIKE '%tupleElement%') INTO v_query_ok
      FROM public.query q JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid = 'audit-clickhouse-pigse' AND q.path_template = '/audit-tables/query';

    IF v_trg_count != 2 THEN
        RAISE EXCEPTION 'V378: se esperaban 2 triggers trg_audit_ctx (tsede, tsede_usuario), se encontraron %', v_trg_count;
    END IF;

    IF NOT coalesce(v_query_ok, false) THEN
        RAISE EXCEPTION 'V378: /audit-tables/query de audit-clickhouse-pigse no se actualizo';
    END IF;

    RAISE NOTICE 'V378 OK: trg_audit_ctx en tsede/tsede_usuario, catalogo de /audit-tables/query (pigse) con 11 tablas reales y nombre/icono fijo.';
END $$;
