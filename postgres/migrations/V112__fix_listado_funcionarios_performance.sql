-- ===========================================================================
-- V112 — Fix de performance del listado de funcionarios (>10s -> <100ms).
--
-- Contexto y evidencia completa: docs/funcionarios-listado-performance-analysis.md
-- (medido con EXPLAIN ANALYZE contra el servidor de test, 2026-08-18).
--
-- ---------------------------------------------------------------------------
-- 0. Nota de drift (por que este archivo recrea 3 funciones "sin cambios")
-- ---------------------------------------------------------------------------
-- fn_usu_empleados_listar / fn_usu_empleados_contar en el servidor NO
-- coincidian con V51__employee_module.sql: alguien aplico ahi un
-- CREATE OR REPLACE FUNCTION manual que agrego el gate de establecimiento
-- (parametro p_pk_usuario_solicitante + CTE funcionarios_ee) usando
-- fn_puede_afectar_establecimiento y fn_resolver_establecimiento_unico —
-- ninguna de las 4 aparecia en ningun .sql de este repo ni de
-- db-migrations. flyway_schema_history en el servidor confirma que la
-- migracion aplicada mas alta es V64; nada mas adelante toca estas
-- funciones tampoco.
--
-- Por eso este archivo:
--   (a) captura fn_puede_afectar_establecimiento y
--       fn_resolver_establecimiento_unico tal cual estan en el servidor
--       (CREATE OR REPLACE, sin cambios de logica) para que el schema sea
--       reproducible desde cero via `flyway migrate`;
--   (b) captura fn_usu_empleados_contar con el mismo gate, aplicando SOLO
--       el ajuste de busqueda del punto 2 (no tenia el problema de
--       performance: ~36ms medido, no toca los CTEs problematicos);
--   (c) reescribe fn_usu_empleados_listar con el fix de performance real
--       (punto 1) + el mismo ajuste de busqueda (punto 2).
--
-- Todo con CREATE OR REPLACE FUNCTION / IF NOT EXISTS: re-ejecutable sin
-- riesgo, igual que el resto de las migraciones de este modulo.
--
-- ---------------------------------------------------------------------------
-- 1. Causa raiz (fn_usu_empleados_listar): agregados que no dependen de la
--    pagina pedida
-- ---------------------------------------------------------------------------
-- La version anterior calculaba sedes/estados_permisos/jornada en dos CTEs
-- (`agregados` con GROUP BY, `jornada_pick` con DISTINCT ON) evaluados
-- sobre TODO TSEDE_USUARIO activo — 126 704 usuarios distintos en el
-- servidor de test — y despues los unia a `base` (los <=1 599 funcionarios
-- que en verdad pueden salir en el resultado) via LEFT JOIN normal. Un
-- LEFT JOIN contra un subquery con GROUP BY no permite que el planner
-- empuje el filtro de `base` hacia adentro, asi que Postgres tenia que
-- materializar el agregado completo (con 2 subqueries correlacionadas por
-- grupo, una de ellas con Seq Scan repetido 126 704 veces) ANTES de poder
-- filtrar. Medido aislado: 11.5s, 1.78M buffer hits, para <=100 filas de
-- output final. Por eso el tiempo era el mismo con o sin filtros: ninguno
-- de esos dos CTEs referenciaba p_search/p_roles/p_campus_id.
--
-- roles_agg (el tercer agregado) YA estaba bien escrito en la version
-- vieja: subquery correlacionada directo en el SELECT final, que Postgres
-- evalua perezosamente solo para las filas que sobreviven ORDER BY+LIMIT.
-- El fix de abajo aplica ese mismo patron a sedes_agg/estados_agg (via
-- subquery correlacionada) y a jornada (via LEFT JOIN LATERAL ... LIMIT 1,
-- que necesita una sola fila por regla de negocio: PREDETERMINADO=1 si
-- existe, si no ORDEN minimo).
--
-- Validado en vivo (transaccion de prueba con ROLLBACK, ver el .md):
-- 10 599ms -> 83ms para la misma llamada (superadmin, sin filtros,
-- pagina 0/10). Los SubPlan de sedes_agg/estados_agg pasan de
-- loops=126704 a loops=10.
--
-- ---------------------------------------------------------------------------
-- 2. Ajuste secundario: busqueda por p_search sin pg_trgm
-- ---------------------------------------------------------------------------
-- El filtro de texto libre comparaba 4 expresiones ILIKE '%...%' distintas
-- (nombre+segundo_nombre, apellido+segundo_apellido, nombre+apellido,
-- identificacion) contra TUSUARIO (150K filas) sin ningun indice que
-- soporte wildcard-al-inicio -> Seq Scan. El servidor solo tenia
-- pg_trgm disponible (contrib) pero no instalado.
--
-- Unificamos las 4 comparaciones en una sola expresion (concatenacion con
-- COALESCE de los 5 campos) y creamos UN indice GIN trigram sobre esa
-- misma expresion — el planner solo puede usar un indice de expresion si
-- el texto de la expresion en el WHERE coincide con el de la definicion
-- del indice, por eso el mismo bloque de texto se repite tal cual en el
-- indice y en cada funcion. Es un ensanchamiento estrictamente igual o
-- mayor que el matching anterior (nunca deja de matchear algo que antes
-- matcheaba: los COALESCE solo agregan los casos donde el campo era NULL).
-- Validado en vivo: Bitmap Index Scan sobre el nuevo indice, 8ms.
--
-- ---------------------------------------------------------------------------
-- 3. Indice compuesto nuevo en TSEDE_USUARIO
-- ---------------------------------------------------------------------------
-- (FK_TUSUARIO, PREDETERMINADO DESC, ORDEN, PK_TSEDE_USUARIO) WHERE
-- ACTIVE=TRUE — sirve tres propositos con un solo indice:
--   * lookups puntuales "FK_TUSUARIO=x AND ACTIVE=TRUE" (prefijo
--     izquierdo) que ahora corren por fila en vez de por CTE agregado;
--   * los 4 EXISTS de base (roles/campus/work_schedules/statuses) sobre
--     TSEDE_USUARIO, mismo prefijo;
--   * el LEFT JOIN LATERAL de jornada: el ORDER BY que antes forzaba un
--     sort externo de 130K filas en jornada_pick ahora es exactamente el
--     orden del indice tras el prefijo FK_TUSUARIO, asi que sale con
--     Index Scan + LIMIT 1 sin sort.
-- No se toca/borra idx_tsede_usuario6 (FK_TUSUARIO sin partial) — sigue
-- sirviendo a queries que necesiten incluir inactivos.
--
-- ANALYZE al final (no VACUUM: Flyway OSS envuelve cada script en una
-- transaccion y VACUUM no puede correr dentro de una — si se quiere
-- recuperar el ~12% de tuplas muertas de TSEDE_USUARIO, correr manual:
-- `VACUUM ANALYZE academico_test.tsede_usuario;` fuera de Flyway).
-- ===========================================================================

SET search_path TO academico_test, public;


-- ===========================================================================
--  Extension + indices de soporte
-- ===========================================================================

CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Punto 3: lookups por FK_TUSUARIO activo + pick de jornada sin sort.
CREATE INDEX IF NOT EXISTS idx_tsede_usuario_fk_tusuario_activo
    ON academico_test.TSEDE_USUARIO (FK_TUSUARIO, PREDETERMINADO DESC, ORDEN, PK_TSEDE_USUARIO)
 WHERE ACTIVE = TRUE;

COMMENT ON INDEX academico_test.idx_tsede_usuario_fk_tusuario_activo
    IS 'Soporta (a) lookups puntuales FK_TUSUARIO+ACTIVE de fn_usu_empleados_listar/contar (sedes_agg, estados_agg, roles_agg, EXISTS de roles/campus/work_schedules), y (b) el pick de jornada (LEFT JOIN LATERAL ... ORDER BY PREDETERMINADO DESC, ORDEN, PK_TSEDE_USUARIO LIMIT 1) sin sort externo. V112.';

-- Punto 2: indice de expresion para busqueda libre. El texto de la
-- expresion DEBE coincidir caracter a caracter con el usado en el WHERE
-- de fn_usu_empleados_listar/fn_usu_empleados_contar para que el planner
-- lo use.
CREATE INDEX IF NOT EXISTS idx_tusuario_busqueda_trgm
    ON academico_test.TUSUARIO
 USING gin (
    (COALESCE(PRIMER_NOMBRE,'') || ' ' || COALESCE(SEGUNDO_NOMBRE,'') || ' ' ||
     COALESCE(PRIMER_APELLIDO,'') || ' ' || COALESCE(SEGUNDO_APELLIDO,'') || ' ' ||
     COALESCE(IDENTIFICACION,''))
    gin_trgm_ops
 );

COMMENT ON INDEX academico_test.idx_tusuario_busqueda_trgm
    IS 'GIN trigram sobre nombres+apellidos+identificacion concatenados, para que p_search (ILIKE %texto%) de fn_usu_empleados_listar/contar deje de hacer Seq Scan sobre TUSUARIO. El texto de la expresion debe coincidir exacto con el del WHERE de esas funciones. V112.';


-- ===========================================================================
--  Baseline: funciones de permiso de establecimiento (sin cambios de
--  logica — capturadas tal cual estaban en el servidor, ver punto 0).
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_puede_afectar_establecimiento(p_pk_usuario BIGINT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT CASE
             WHEN p_pk_usuario IS NULL THEN FALSE
             ELSE EXISTS (
                 SELECT 1
                   FROM academico_test.TSEDE_USUARIO
                  WHERE FK_TUSUARIO = p_pk_usuario
                    AND FK_TROL     IN (1, 2, 3)
                    AND ACTIVE       = TRUE
             )
           END;
$$;

COMMENT ON FUNCTION academico_test.fn_puede_afectar_establecimiento(BIGINT)
    IS 'TRUE si el usuario tiene un TSEDE_USUARIO activo con FK_TROL IN (1,2,3) (roles de superadmin/nivel alto): ve todos los establecimientos, no solo el suyo. Baseline capturado del servidor en V112 (no existia en ninguna migracion previa del repo — ver nota de drift en el header de este archivo). Sin cambios de logica.';


CREATE OR REPLACE FUNCTION academico_test.fn_resolver_establecimiento_unico(p_pk_usuario BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT x.PK_ESTABLECIMIENTO
      FROM (
          SELECT ee.PK_ESTABLECIMIENTO, COUNT(*) OVER () AS n
            FROM (
                SELECT e.PK_ESTABLECIMIENTO
                  FROM academico_test.TESTABLECIMIENTO e
                  JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
                 WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario
                UNION
                SELECT e.PK_ESTABLECIMIENTO
                  FROM academico_test.TESTABLECIMIENTO e
                  JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
                 WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario
                UNION
                SELECT DISTINCT s.FK_TESTABLECIMIENTO
                  FROM academico_test.TSEDE_USUARIO su
                  JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
                 WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 8
                   AND su.FK_TUSUARIO = p_pk_usuario
            ) ee
      ) x
     WHERE x.n = 1;
$$;

COMMENT ON FUNCTION academico_test.fn_resolver_establecimiento_unico(BIGINT)
    IS 'Resuelve el establecimiento del usuario cuando es inequivoco: rector o secretaria de un establecimiento, o vinculado (FK_TROL=8) a exactamente una sede cuyo establecimiento coincide. Si el usuario esta ligado a mas de un establecimiento por esas vias, retorna NULL (ambiguo -> el caller trata esto como "sin permiso" salvo que sea superadmin). Baseline capturado del servidor en V112 (no existia en ninguna migracion previa del repo). Sin cambios de logica.';


-- ===========================================================================
--  fn_usu_empleados_contar — baseline + ajuste de busqueda (punto 2).
--  No tenia el problema de performance de fn_usu_empleados_listar (~36ms
--  medido en el servidor sin filtros); se toca solo para que el filtro de
--  busqueda use el mismo indice de expresion que la version corregida del
--  listado, y para que el total (pageCount/totalCount) no se desalinee si
--  el catalogo de funcionarios crece.
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_usu_empleados_contar(
    p_pk_usuario_solicitante BIGINT,
    p_search         VARCHAR    DEFAULT NULL,
    p_roles          BIGINT[]   DEFAULT NULL,
    p_work_schedules BIGINT[]   DEFAULT NULL,
    p_statuses       VARCHAR[]  DEFAULT NULL,
    p_campus_id      BIGINT     DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_total BIGINT;
    v_es_super BOOLEAN := academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante);
    v_fk_establecimiento BIGINT := academico_test.fn_resolver_establecimiento_unico(p_pk_usuario_solicitante);
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT v_es_super AND v_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    IF v_es_super THEN
        SELECT COUNT(DISTINCT f.PK_TFUNCIONARIO)
          INTO v_total
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TUSUARIO      u ON u.PK_TUSUARIO = f.FK_TUSUARIO
         WHERE f.ACTIVE = TRUE
           AND (NULLIF(TRIM(p_search), '') IS NULL
                OR (COALESCE(u.PRIMER_NOMBRE,'') || ' ' || COALESCE(u.SEGUNDO_NOMBRE,'') || ' ' ||
                    COALESCE(u.PRIMER_APELLIDO,'') || ' ' || COALESCE(u.SEGUNDO_APELLIDO,'') || ' ' ||
                    COALESCE(u.IDENTIFICACION,'')) ILIKE '%' || p_search || '%'
                OR EXISTS (
                    SELECT 1 FROM academico_test.TSEDE_USUARIO su2
                      JOIN academico_test.TSEDE  s ON s.PK_TSEDE = su2.FK_TSEDE
                      JOIN academico_test.TROL   r ON r.PK_TROL  = su2.FK_TROL
                     WHERE su2.FK_TUSUARIO = u.PK_TUSUARIO
                       AND su2.ACTIVE      = TRUE
                       AND (s.NOMBRE ILIKE '%' || p_search || '%'
                            OR r.NOMBRE ILIKE '%' || p_search || '%')
                  )
            )
           AND (p_statuses IS NULL OR CARDINALITY(p_statuses) = 0
                OR u.ESTADO = ANY(
                    SELECT CASE
                             WHEN x = 'ACTIVE'    THEN 'A'
                             WHEN x = 'SUSPENDED' THEN 'I'
                           END
                      FROM unnest(p_statuses) AS x
                     WHERE x IN ('ACTIVE','SUSPENDED')
                ))
           AND (p_campus_id IS NULL OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su3
                 WHERE su3.FK_TUSUARIO = u.PK_TUSUARIO
                   AND su3.ACTIVE      = TRUE
                   AND su3.FK_TSEDE    = p_campus_id
           ))
           AND (p_roles IS NULL OR CARDINALITY(p_roles) = 0 OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su4
                 WHERE su4.FK_TUSUARIO = u.PK_TUSUARIO
                   AND su4.ACTIVE      = TRUE
                   AND su4.FK_TROL     = ANY(p_roles)
           ))
           AND (p_work_schedules IS NULL OR CARDINALITY(p_work_schedules) = 0 OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su5
                 WHERE su5.FK_TUSUARIO    = u.PK_TUSUARIO
                   AND su5.ACTIVE         = TRUE
                   AND su5.FK_TLV_JORNADA = ANY(p_work_schedules)
           ));
        RETURN v_total;
    END IF;

    WITH funcionarios_ee AS (
        SELECT e.FK_TFUNCIONARIO_RECTOR AS pk_tfuncionario
          FROM academico_test.TESTABLECIMIENTO e
         WHERE e.PK_ESTABLECIMIENTO = v_fk_establecimiento AND e.ACTIVE = TRUE
           AND e.FK_TFUNCIONARIO_RECTOR IS NOT NULL
        UNION
        SELECT e.FK_TFUNCIONARIO_SECRETARIA
          FROM academico_test.TESTABLECIMIENTO e
         WHERE e.PK_ESTABLECIMIENTO = v_fk_establecimiento AND e.ACTIVE = TRUE
           AND e.FK_TFUNCIONARIO_SECRETARIA IS NOT NULL
        UNION
        SELECT f2.PK_TFUNCIONARIO
          FROM academico_test.TFUNCIONARIO f2
         WHERE f2.FK_ESTABLECIMIENTO = v_fk_establecimiento AND f2.ACTIVE = TRUE
        UNION
        SELECT f3.PK_TFUNCIONARIO
          FROM academico_test.TFUNCIONARIO f3
          JOIN academico_test.TSEDE_USUARIO su ON su.FK_TUSUARIO = f3.FK_TUSUARIO AND su.ACTIVE = TRUE
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
         WHERE s.FK_TESTABLECIMIENTO = v_fk_establecimiento AND f3.ACTIVE = TRUE
    )
    SELECT COUNT(DISTINCT f.PK_TFUNCIONARIO)
      INTO v_total
      FROM academico_test.TFUNCIONARIO f
      JOIN funcionarios_ee fee ON fee.pk_tfuncionario = f.PK_TFUNCIONARIO
      JOIN academico_test.TUSUARIO      u ON u.PK_TUSUARIO = f.FK_TUSUARIO
     WHERE f.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_search), '') IS NULL
            OR (COALESCE(u.PRIMER_NOMBRE,'') || ' ' || COALESCE(u.SEGUNDO_NOMBRE,'') || ' ' ||
                COALESCE(u.PRIMER_APELLIDO,'') || ' ' || COALESCE(u.SEGUNDO_APELLIDO,'') || ' ' ||
                COALESCE(u.IDENTIFICACION,'')) ILIKE '%' || p_search || '%'
            OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su2
                  JOIN academico_test.TSEDE  s ON s.PK_TSEDE = su2.FK_TSEDE
                  JOIN academico_test.TROL   r ON r.PK_TROL  = su2.FK_TROL
                 WHERE su2.FK_TUSUARIO = u.PK_TUSUARIO
                   AND su2.ACTIVE      = TRUE
                   AND (s.NOMBRE ILIKE '%' || p_search || '%'
                        OR r.NOMBRE ILIKE '%' || p_search || '%')
              )
        )
        AND (p_statuses IS NULL OR CARDINALITY(p_statuses) = 0
             OR u.ESTADO = ANY(
                 SELECT CASE
                          WHEN x = 'ACTIVE'    THEN 'A'
                          WHEN x = 'SUSPENDED' THEN 'I'
                        END
                   FROM unnest(p_statuses) AS x
                  WHERE x IN ('ACTIVE','SUSPENDED')
             ))
        AND (p_campus_id IS NULL OR EXISTS (
             SELECT 1 FROM academico_test.TSEDE_USUARIO su3
              WHERE su3.FK_TUSUARIO = u.PK_TUSUARIO
                AND su3.ACTIVE      = TRUE
                AND su3.FK_TSEDE    = p_campus_id
        ))
        AND (p_roles IS NULL OR CARDINALITY(p_roles) = 0 OR EXISTS (
             SELECT 1 FROM academico_test.TSEDE_USUARIO su4
              WHERE su4.FK_TUSUARIO = u.PK_TUSUARIO
                AND su4.ACTIVE      = TRUE
                AND su4.FK_TROL     = ANY(p_roles)
        ))
        AND (p_work_schedules IS NULL OR CARDINALITY(p_work_schedules) = 0 OR EXISTS (
             SELECT 1 FROM academico_test.TSEDE_USUARIO su5
              WHERE su5.FK_TUSUARIO    = u.PK_TUSUARIO
                AND su5.ACTIVE         = TRUE
                AND su5.FK_TLV_JORNADA = ANY(p_work_schedules)
        ));

    RETURN v_total;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_usu_empleados_contar(
    BIGINT, VARCHAR, BIGINT[], BIGINT[], VARCHAR[], BIGINT
)
    IS 'Cuenta funcionarios activos visibles para p_pk_usuario_solicitante (todos si es superadmin via fn_puede_afectar_establecimiento; acotado a su establecimiento via fn_resolver_establecimiento_unico + CTE funcionarios_ee si no), aplicando los mismos filtros que fn_usu_empleados_listar (search, roles, work_schedules, statuses, campus_id). search: ILIKE parcial sobre nombres+apellidos+identificacion concatenados (indexable via idx_tusuario_busqueda_trgm, V112) y sobre nombres de sede/rol ligados via TSEDE_USUARIO activos. statuses: array de ACTIVE/SUSPENDED mapeado a TUSUARIO.ESTADO (A/I). Usar junto con fn_usu_empleados_listar para armar { rows, pageCount, totalCount }. V112: alineado el filtro de busqueda con el indice trigram nuevo (mismo criterio de match, ahora indexable); sin cambios de comportamiento.';


-- ===========================================================================
--  fn_usu_empleados_listar — FIX de performance (punto 1) + ajuste de
--  busqueda (punto 2). Mismo contrato/firma/output que la version del
--  servidor: ningun cambio requerido en Java/gateway.
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_usu_empleados_listar(
    p_pk_usuario_solicitante BIGINT,
    p_search         VARCHAR    DEFAULT NULL,
    p_roles          BIGINT[]   DEFAULT NULL,
    p_work_schedules BIGINT[]   DEFAULT NULL,
    p_statuses       VARCHAR[]  DEFAULT NULL,
    p_campus_id      BIGINT     DEFAULT NULL,
    p_sort_campo     VARCHAR    DEFAULT NULL,
    p_sort_desc      BOOLEAN    DEFAULT FALSE,
    p_page_index     INT        DEFAULT 0,
    p_page_size      INT        DEFAULT 10
)
RETURNS TABLE (
    pk_empleado        BIGINT,
    numero_documento   VARCHAR,
    primer_nombre      VARCHAR,
    segundo_nombre     VARCHAR,
    primer_apellido    VARCHAR,
    segundo_apellido   VARCHAR,
    nombre_completo    VARCHAR,
    fk_estado          VARCHAR,
    estado_label       VARCHAR,
    jornada_id         BIGINT,
    jornada_nombre     VARCHAR,
    roles              JSONB,
    sedes              JSONB,
    estados_permisos   JSONB
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_page_size  INT := LEAST(CASE WHEN p_page_size > 0 THEN p_page_size ELSE 10 END, 100);
    v_page_index INT := GREATEST(COALESCE(p_page_index, 0), 0);
    v_es_super   BOOLEAN := academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante);
    v_fk_establecimiento BIGINT := academico_test.fn_resolver_establecimiento_unico(p_pk_usuario_solicitante);
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT v_es_super AND v_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    WITH funcionarios_ee AS (
        SELECT e.FK_TFUNCIONARIO_RECTOR AS pk_tfuncionario
          FROM academico_test.TESTABLECIMIENTO e
         WHERE e.PK_ESTABLECIMIENTO = v_fk_establecimiento AND e.ACTIVE = TRUE
           AND e.FK_TFUNCIONARIO_RECTOR IS NOT NULL
        UNION
        SELECT e.FK_TFUNCIONARIO_SECRETARIA
          FROM academico_test.TESTABLECIMIENTO e
         WHERE e.PK_ESTABLECIMIENTO = v_fk_establecimiento AND e.ACTIVE = TRUE
           AND e.FK_TFUNCIONARIO_SECRETARIA IS NOT NULL
        UNION
        SELECT f2.PK_TFUNCIONARIO
          FROM academico_test.TFUNCIONARIO f2
         WHERE f2.FK_ESTABLECIMIENTO = v_fk_establecimiento AND f2.ACTIVE = TRUE
        UNION
        SELECT f3.PK_TFUNCIONARIO
          FROM academico_test.TFUNCIONARIO f3
          JOIN academico_test.TSEDE_USUARIO su ON su.FK_TUSUARIO = f3.FK_TUSUARIO AND su.ACTIVE = TRUE
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
         WHERE s.FK_TESTABLECIMIENTO = v_fk_establecimiento AND f3.ACTIVE = TRUE
    ),
    -- Funcionarios visibles que matchean search/estado/roles/campus/jornada.
    -- A lo sumo el total de funcionarios activos del sistema (o del
    -- establecimiento si no es superadmin) — nunca el universo de
    -- TSEDE_USUARIO. sedes_agg/estados_agg/roles_agg/jornada YA NO se
    -- calculan aqui: se resuelven mas abajo, por fila, despues de
    -- ORDER BY + LIMIT (punto 1 del header).
    base AS (
        SELECT DISTINCT f.PK_TFUNCIONARIO, u.PK_TUSUARIO, u.IDENTIFICACION,
               u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
               u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO,
               u.ESTADO
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TUSUARIO      u ON u.PK_TUSUARIO = f.FK_TUSUARIO
         WHERE f.ACTIVE = TRUE
           AND (v_es_super OR f.PK_TFUNCIONARIO IN (SELECT pk_tfuncionario FROM funcionarios_ee))
           AND (NULLIF(TRIM(p_search), '') IS NULL
                OR (COALESCE(u.PRIMER_NOMBRE,'') || ' ' || COALESCE(u.SEGUNDO_NOMBRE,'') || ' ' ||
                    COALESCE(u.PRIMER_APELLIDO,'') || ' ' || COALESCE(u.SEGUNDO_APELLIDO,'') || ' ' ||
                    COALESCE(u.IDENTIFICACION,'')) ILIKE '%' || p_search || '%'
                OR EXISTS (
                    SELECT 1 FROM academico_test.TSEDE_USUARIO su2
                      JOIN academico_test.TSEDE  s ON s.PK_TSEDE = su2.FK_TSEDE
                      JOIN academico_test.TROL   r ON r.PK_TROL  = su2.FK_TROL
                     WHERE su2.FK_TUSUARIO = u.PK_TUSUARIO
                       AND su2.ACTIVE      = TRUE
                       AND (s.NOMBRE ILIKE '%' || p_search || '%'
                            OR r.NOMBRE ILIKE '%' || p_search || '%')
                  )
           )
           AND (p_statuses IS NULL OR CARDINALITY(p_statuses) = 0
                OR u.ESTADO = ANY(
                    SELECT CASE
                             WHEN x = 'ACTIVE'    THEN 'A'
                             WHEN x = 'SUSPENDED' THEN 'I'
                           END
                      FROM unnest(p_statuses) AS x
                     WHERE x IN ('ACTIVE','SUSPENDED')
                ))
           AND (p_campus_id IS NULL OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su3
                 WHERE su3.FK_TUSUARIO = u.PK_TUSUARIO
                   AND su3.ACTIVE      = TRUE
                   AND su3.FK_TSEDE    = p_campus_id
           ))
           AND (p_roles IS NULL OR CARDINALITY(p_roles) = 0 OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su4
                 WHERE su4.FK_TUSUARIO = u.PK_TUSUARIO
                   AND su4.ACTIVE      = TRUE
                   AND su4.FK_TROL     = ANY(p_roles)
           ))
           AND (p_work_schedules IS NULL OR CARDINALITY(p_work_schedules) = 0 OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su5
                 WHERE su5.FK_TUSUARIO    = u.PK_TUSUARIO
                   AND su5.ACTIVE         = TRUE
                   AND su5.FK_TLV_JORNADA = ANY(p_work_schedules)
           ))
    )
    SELECT b.PK_TFUNCIONARIO,
           b.IDENTIFICACION,
           b.PRIMER_NOMBRE,
           b.SEGUNDO_NOMBRE,
           b.PRIMER_APELLIDO,
           b.SEGUNDO_APELLIDO,
           TRIM(COALESCE(b.PRIMER_NOMBRE,'') || ' ' || COALESCE(b.SEGUNDO_NOMBRE,'')
                || ' ' || COALESCE(b.PRIMER_APELLIDO,'') || ' ' || COALESCE(b.SEGUNDO_APELLIDO,''))::VARCHAR AS nombre_completo,
           b.ESTADO::VARCHAR AS fk_estado,
           (CASE b.ESTADO
                WHEN 'A' THEN 'ACTIVE'
                WHEN 'I' THEN 'SUSPENDED'
                ELSE NULL
           END)::VARCHAR      AS estado_label,
           jp.jornada_id,
           jp.jornada_nombre,
           -- roles_agg: ya era una subquery correlacionada (patron correcto,
           -- sin cambios). Se evalua solo para las filas que sobreviven
           -- ORDER BY + LIMIT, igual que sedes_agg/estados_agg de abajo.
           COALESCE(
               (SELECT jsonb_agg(DISTINCT role_obj ORDER BY role_obj)
                  FROM (
                      SELECT jsonb_build_object('id', r.PK_TROL, 'nombre', r.NOMBRE) AS role_obj
                        FROM academico_test.TSEDE_USUARIO su_r
                        JOIN academico_test.TROL          r ON r.PK_TROL = su_r.FK_TROL
                       WHERE su_r.FK_TUSUARIO = b.PK_TUSUARIO
                         AND su_r.ACTIVE      = TRUE
                      UNION
                      SELECT jsonb_build_object('id', 7, 'nombre', 'Rector')
                       WHERE EXISTS (
                           SELECT 1 FROM academico_test.TESTABLECIMIENTO e
                            WHERE e.FK_TFUNCIONARIO_RECTOR = b.PK_TFUNCIONARIO AND e.ACTIVE = TRUE
                       )
                      UNION
                      SELECT jsonb_build_object('id', 17, 'nombre', 'Secretaria')
                       WHERE EXISTS (
                           SELECT 1 FROM academico_test.TESTABLECIMIENTO e
                            WHERE e.FK_TFUNCIONARIO_SECRETARIA = b.PK_TFUNCIONARIO AND e.ACTIVE = TRUE
                       )
                  ) roles_union),
               '[]'::jsonb
           )                             AS roles_agg,
           -- sedes_agg / estados_agg: FIX V112. Antes venian de un CTE
           -- `agregados` con GROUP BY sobre TODO TSEDE_USUARIO activo
           -- (126 704 usuarios en el servidor de test), unido con LEFT
           -- JOIN normal -> Postgres no podia empujar el filtro de `base`
           -- adentro y tenia que materializar el agregado completo antes
           -- de filtrar (11.5s medidos, aislado). Ahora son subqueries
           -- correlacionadas directas contra b.PK_TUSUARIO, exactamente
           -- el mismo patron que roles_agg de arriba: Postgres las evalua
           -- perezosamente solo para las <=v_page_size filas finales.
           COALESCE(
               (SELECT jsonb_agg(DISTINCT jsonb_build_object('id', s.PK_TSEDE, 'nombre', s.NOMBRE)
                                  ORDER BY jsonb_build_object('id', s.PK_TSEDE, 'nombre', s.NOMBRE))
                  FROM academico_test.TSEDE_USUARIO su_s
                  JOIN academico_test.TSEDE         s ON s.PK_TSEDE = su_s.FK_TSEDE
                 WHERE su_s.FK_TUSUARIO = b.PK_TUSUARIO AND su_s.ACTIVE = TRUE),
               '[]'::jsonb
           )                             AS sedes_agg,
           COALESCE(
               (SELECT jsonb_agg(DISTINCT su_e.TLV_ESTADO ORDER BY su_e.TLV_ESTADO)
                  FROM academico_test.TSEDE_USUARIO su_e
                 WHERE su_e.FK_TUSUARIO = b.PK_TUSUARIO AND su_e.ACTIVE = TRUE),
               '[]'::jsonb
           )                             AS estados_agg
      FROM base b
      -- jornada: FIX V112. Antes CTE `jornada_pick` con DISTINCT ON sobre
      -- TODO TSEDE_USUARIO activo (mismo problema de alcance que
      -- `agregados`, aunque con costo propio menor: ~165ms aislado por el
      -- sort de 130K filas). LATERAL + LIMIT 1 aplica exactamente la
      -- misma regla (PREDETERMINADO=1 si existe, si no ORDEN minimo) pero
      -- solo para las filas de `base`, y usa
      -- idx_tsede_usuario_fk_tusuario_activo (V112) para resolver el
      -- ORDER BY sin sort.
      LEFT JOIN LATERAL (
            SELECT su.FK_TLV_JORNADA AS jornada_id, tlv.NOMBRE AS jornada_nombre
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TLISTA_VALOR  tlv ON tlv.PK_LISTA_VALOR = su.FK_TLV_JORNADA
             WHERE su.FK_TUSUARIO = b.PK_TUSUARIO AND su.ACTIVE = TRUE
             ORDER BY su.PREDETERMINADO DESC, su.ORDEN ASC, su.PK_TSEDE_USUARIO ASC
             LIMIT 1
      ) jp ON TRUE
     ORDER BY
        CASE WHEN p_sort_campo = 'name'      AND NOT p_sort_desc
             THEN TRIM(COALESCE(b.PRIMER_NOMBRE,'') || ' ' || COALESCE(b.SEGUNDO_NOMBRE,'')
                       || ' ' || COALESCE(b.PRIMER_APELLIDO,'') || ' ' || COALESCE(b.SEGUNDO_APELLIDO,''))
        END ASC,
        CASE WHEN p_sort_campo = 'name'      AND     p_sort_desc
             THEN TRIM(COALESCE(b.PRIMER_NOMBRE,'') || ' ' || COALESCE(b.SEGUNDO_NOMBRE,'')
                       || ' ' || COALESCE(b.PRIMER_APELLIDO,'') || ' ' || COALESCE(b.SEGUNDO_APELLIDO,''))
        END DESC,
        CASE WHEN p_sort_campo = 'document'  AND NOT p_sort_desc THEN b.IDENTIFICACION END ASC,
        CASE WHEN p_sort_campo = 'document'  AND     p_sort_desc THEN b.IDENTIFICACION END DESC,
        CASE WHEN p_sort_campo = 'status'    AND NOT p_sort_desc THEN b.ESTADO END ASC,
        CASE WHEN p_sort_campo = 'status'    AND     p_sort_desc THEN b.ESTADO END DESC,
        b.PRIMER_NOMBRE  ASC,
        b.PRIMER_APELLIDO ASC,
        b.PK_TFUNCIONARIO ASC
     LIMIT v_page_size
    OFFSET v_page_index * v_page_size;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_usu_empleados_listar(
    BIGINT, VARCHAR, BIGINT[], BIGINT[], VARCHAR[], BIGINT,
    VARCHAR, BOOLEAN, INT, INT
)
    IS 'Lista funcionarios visibles para p_pk_usuario_solicitante (todos si es superadmin via fn_puede_afectar_establecimiento; acotado a su establecimiento via fn_resolver_establecimiento_unico + CTE funcionarios_ee si no), paginados segun los mismos filtros que fn_usu_empleados_contar. Fila aplanada: id, documento, nombres, apellidos, nombre completo, estado (A/I) y label (ACTIVE/SUSPENDED), jornada (TSEDE_USUARIO activo con PREDETERMINADO=1 si existe, si no el de menor ORDEN, NULL si no hay permiso), roles/sedes/estados_permisos como JSONB array. p_sort_campo/p_sort_desc = sorting[0] resuelto (name/document/status). p_page_index base 0; p_page_size acotado a (0,100]. No calcula totalCount/pageCount: usar junto con fn_usu_empleados_contar. V112: sedes_agg/estados_agg/jornada dejaron de calcularse en CTEs con GROUP BY/DISTINCT ON sobre TODO TSEDE_USUARIO activo (O(usuarios del sistema), ~11.5s medidos con 126K usuarios) y pasaron a subqueries/LATERAL correlacionadas por fila (O(page_size), ~80ms medidos) — mismo contrato y mismo output, ver docs/funcionarios-listado-performance-analysis.md. Tambien se unifico el filtro p_search en una sola expresion indexable via idx_tusuario_busqueda_trgm.';


-- ===========================================================================
--  Refresco de estadisticas (transaction-safe; VACUUM no puede correr
--  dentro de la transaccion que envuelve este script en Flyway OSS — ver
--  nota del header).
-- ===========================================================================

ANALYZE academico_test.TSEDE_USUARIO;
ANALYZE academico_test.TUSUARIO;
ANALYZE academico_test.TFUNCIONARIO;
