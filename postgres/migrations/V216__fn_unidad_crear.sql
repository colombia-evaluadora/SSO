-- ===========================================================================
-- V216 — Planeador educativo: CRUD de la unidad tematica (crear / listar /
-- editar / eliminar soft) con sus contenidos, objetivos, referente
-- curricular y forma de calculo de nota
-- (CU-86e311xxp — G. Academico Back Planeador educativo).
--
-- Contexto (pantallas "Nueva unidad" / "Unidad tematica" del Planeador):
-- al crear/editar una unidad el docente captura, ademas de la
-- identificacion (nombre, asignatura, grado, autor):
--   * Objetivos especificos de la unidad    -> TUNIDAD_OBJETIVO  (uno por
--     fila, ORDEN = posicion en la lista).
--   * Contenidos / componentes de la unidad -> TUNIDAD_CONTENIDO (idem).
--   * Referente curricular al que se acoge (DBA / Propositos e
--     Imprescindibles / ...) -> TUNIDAD.FK_REFERENTE_CURRICULAR, opcional
--     (V212, rama CU-86e311xqh).
--   * "Forma en que se van a calcular las actividades dentro de la unidad"
--     (Promediar / Ponderar / Sumatoria de Actividades) ->
--     TUNIDAD.FK_TLV_CALCULO_DEFINITIVA, TLISTA_VALOR CATEGORIA=
--     'CALCULO_DEFINITIVA' (V73, rama CU-86e30a25v). OBLIGATORIO al crear.
--
-- La unidad YA NO esta atada a un periodo de evaluacion: V218
-- (CU-86e329pvq) elimino TUNIDAD.FK_TPERIODO_EVALUACION y recompuso el
-- UNIQUE UN_TUNIDAD_1 como (NOMBRE, FK_TASIGNATURA, FK_TGRADO). Tambien
-- hizo TACTIVIDAD.FK_TUNIDAD NULLABLE (la actividad ya no exige unidad) y
-- agrego TACTIVIDAD.FK_TASIGNATURA. Este archivo se escribe para ese estado.
--
-- Fechas de la unidad ("10/02/2025 – 28/02/2025" en el listado): se
-- DERIVAN de MIN(FECHA_INICIO) / MAX(FECHA_CIERRE) de las actividades
-- activas de la unidad; TUNIDAD no tiene fechas propias.
--
-- Depende de (se aplican antes por orden de version de Flyway):
--   * V22  — TUNIDAD, TUNIDAD_CONTENIDO, TUNIDAD_OBJETIVO, TACTIVIDAD,
--            TRUBRICA_UNIDAD, TCRITERIO_UNIDAD, TNIVEL_CRITERIO_UNIDAD,
--            TCRITERIO_EVALUACION, TESCALA_VALORACION.
--   * V73  — TUNIDAD.FK_TLV_CALCULO_DEFINITIVA + catalogo CALCULO_DEFINITIVA.
--   * V212 — TREFERENTE_CURRICULAR + TUNIDAD.FK_REFERENTE_CURRICULAR.
--   * V218 — TUNIDAD sin FK_TPERIODO_EVALUACION, UN_TUNIDAD_1 (NOMBRE,
--            FK_TASIGNATURA, FK_TGRADO), TACTIVIDAD.FK_TUNIDAD nullable.
--   * V29/V185/V213 — modelo de capability por menu (fn_assert_permiso_seccion).
--   * V239 — TUNIDAD.PONDERACION (peso % de la unidad dentro de su
--            (asignatura, grado)) + fn_unidad_ponderacion_intra_asignatura_asignada,
--            fn_asignatura_plan_vigente_por_grado,
--            fn_asignatura_plan_elemento_calculo y
--            fn_asignatura_plan_calculo_definitiva_modo, que usan
--            fn_unidad_crear / fn_unidad_actualizar via p_ponderacion.
--            DEPENDENCIA HACIA ADELANTE deliberada: V239 se aplica DESPUES que
--            este archivo, pero los cuerpos PL/pgSQL no se resuelven al
--            crearlos (check_function_bodies solo hace analisis sintactico en
--            plpgsql), asi que la migracion no falla; p_ponderacion
--            simplemente no es usable hasta que V239 corra. Se prefiere esto a
--            partir el CRUD de la unidad en dos archivos.
--
-- Nomenclatura/estilo: sigue V213 (fn_ con gate fn_assert_permiso_seccion,
-- validaciones 22023/23503/23505/P0002, PATCH parcial con COALESCE,
-- CREATED_BY = usuario solicitante, soft delete en cascada, listado
-- paginado con COUNT(*) OVER(), COMMENT ON FUNCTION) y V59/V113/V213 (seed
-- de TMENU/TROL_MENU via WHERE NOT EXISTS, sin ON CONFLICT — indice parcial).
--
-- AUTORIZACION: gate fn_assert_permiso_seccion(usuario, 'PLANEADOR',
-- <accion>), sin scope territorial (el alcance fino por asignatura/grupo se
-- valida en la capa de asignacion, fuera de esta migracion). Seed nuevo:
-- menu 'PLANEADOR' concedido a DOCENTE y SUPER_ADMINISTRADOR (4 permisos).
--
-- Fuera de alcance: el vinculo fino unidad <-> enunciado concreto del
-- referente (hoy la unidad se acoge al referente completo via
-- FK_REFERENTE_CURRICULAR) y el CRUD de actividades/rubricas de la unidad.
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- (A) TMENU — grupo top-level 'PLANEADOR'.
-- ---------------------------------------------------------------------------
INSERT INTO academico_test.tmenu (codigo, nombre, icono, visible, estado, url, fk_tmenu, orden, created_by)
SELECT 'PLANEADOR', 'Planeador', 'CalendarCheck-Icon', 'S', 'A',
       '/academico/planeador', NULL, 6::NUMERIC, 'V216_seed'
 WHERE NOT EXISTS (
     SELECT 1 FROM academico_test.tmenu m
      WHERE m.codigo = 'PLANEADOR' AND m.active = TRUE
 );

-- ---------------------------------------------------------------------------
-- (B) TROL_MENU — concede el menu a DOCENTE y SUPER_ADMINISTRADOR.
-- ---------------------------------------------------------------------------
INSERT INTO academico_test.trol_menu (fk_trol, fk_tmenu, orden_rol, active, created_by)
SELECT t.pk_trol, m.pk_tmenu, 1, TRUE, 'V216_seed'
  FROM academico_test.tmenu m
 CROSS JOIN academico_test.trol t
 WHERE t.codigo IN ('DOCENTE', 'SUPER_ADMINISTRADOR')
   AND t.active = TRUE
   AND m.codigo = 'PLANEADOR'
   AND m.active = TRUE
   AND NOT EXISTS (
       SELECT 1 FROM academico_test.trol_menu tm
        WHERE tm.fk_trol = t.pk_trol AND tm.fk_tmenu = m.pk_tmenu AND tm.active = TRUE
       );

-- ===========================================================================
-- fn_unidad_crear
-- ===========================================================================
-- Gana p_enunciados (BIGINT[]) y despues p_ponderacion (NUMERIC) al final:
-- cada uno cambia el numero de parametros, asi que CREATE OR REPLACE no
-- reemplaza las firmas viejas -- se anteponen los DROP FUNCTION IF EXISTS de
-- esas firmas, mismo patron que V100/V106/V109/V113.
DROP FUNCTION IF EXISTS academico_test.fn_unidad_crear(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, BIGINT, VARCHAR[], VARCHAR[]);
DROP FUNCTION IF EXISTS academico_test.fn_unidad_crear(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, BIGINT, VARCHAR[], VARCHAR[], BIGINT[]);
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_crear(
    p_pk_usuario_solicitante        BIGINT,
    p_nombre                        VARCHAR(250),
    p_fk_tasignatura                BIGINT,
    p_fk_tgrado                     BIGINT,
    p_fk_tfuncionario               BIGINT,
    p_fk_tlv_calculo_definitiva     BIGINT,
    p_descripcion                   VARCHAR(4000) DEFAULT NULL,
    p_fk_referente_curricular       BIGINT        DEFAULT NULL,
    -- Uno por elemento; el ORDEN se toma de la posicion en el array.
    -- Elementos NULL o en blanco se ignoran.
    p_objetivos                     VARCHAR[]     DEFAULT NULL,
    p_contenidos                    VARCHAR[]     DEFAULT NULL,
    -- PK_REFERENTE_ENUNCIADO (nivel 1, TREFERENTE_ENUNCIADO) del referente
    -- curricular (p_fk_referente_curricular) que aplican a esta unidad.
    -- Solo tiene sentido si se pasa p_fk_referente_curricular; cada uno se
    -- relaciona via fn_unidad_enunciado_relacionar (V136), que ya valida
    -- que el enunciado sea nivel 1 y comparta el nivel de ensenanza de la
    -- unidad (a traves del grado) -- no se duplica esa validacion aqui.
    p_enunciados                    BIGINT[]      DEFAULT NULL,
    -- Peso (%) de ESTA unidad dentro de su (asignatura, grado) —
    -- TUNIDAD.PONDERACION (V239). Opcional. Ver el bloque 2.c.
    p_ponderacion                   NUMERIC       DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_creado  BIGINT;
    v_pk_plan    BIGINT;
    v_elemento   VARCHAR;
    v_modo       VARCHAR;
    v_suma       NUMERIC(9,2);
BEGIN
    -- 0. Gate: capability CREAR sobre PLANEADOR (sin scope territorial).
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'CREAR'
    );

    -- 1. Obligatorios.
    IF NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'El nombre de la unidad es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_nombre no puede ser NULL ni vacio';
    END IF;
    IF p_fk_tasignatura IS NULL THEN
        RAISE EXCEPTION 'La asignatura (FK_TASIGNATURA) es obligatoria' USING ERRCODE = '22023';
    END IF;
    IF p_fk_tgrado IS NULL THEN
        RAISE EXCEPTION 'El grado (FK_TGRADO) es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_tfuncionario IS NULL THEN
        RAISE EXCEPTION 'El docente autor (FK_TFUNCIONARIO) es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_tlv_calculo_definitiva IS NULL THEN
        RAISE EXCEPTION 'La forma de calculo de la nota (FK_TLV_CALCULO_DEFINITIVA) es obligatoria'
            USING ERRCODE = '22023', HINT = 'Promediar / Ponderar / Sumatoria de Actividades';
    END IF;

    -- 2. FKs existen y estan activas.
    IF NOT EXISTS (SELECT 1 FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_tasignatura AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'FK_TASIGNATURA (%) no existe o no esta activa', p_fk_tasignatura USING ERRCODE = '23503';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_tgrado AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'FK_TGRADO (%) no existe o no esta activo', p_fk_tgrado USING ERRCODE = '23503';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM academico_test.TFUNCIONARIO WHERE PK_TFUNCIONARIO = p_fk_tfuncionario AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'FK_TFUNCIONARIO (%) no existe o no esta activo', p_fk_tfuncionario USING ERRCODE = '23503';
    END IF;

    -- 2.a Forma de calculo de la nota de la unidad (obligatoria).
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_tlv_calculo_definitiva
           AND CATEGORIA = 'CALCULO_DEFINITIVA'
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'FK_TLV_CALCULO_DEFINITIVA (%) no existe, no esta activo o no es de la categoria CALCULO_DEFINITIVA', p_fk_tlv_calculo_definitiva
            USING ERRCODE = '23503';
    END IF;

    -- 2.b Referente curricular al que se acoge la unidad (opcional).
    IF p_fk_referente_curricular IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR
         WHERE PK_REFERENTE_CURRICULAR = p_fk_referente_curricular
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'FK_REFERENTE_CURRICULAR (%) no existe o no esta activo', p_fk_referente_curricular
            USING ERRCODE = '23503';
    END IF;

    -- 2.c Peso (%) de la unidad dentro de su (asignatura, grado)
    --     — TUNIDAD.PONDERACION (V239). Mismo tratamiento que V223/V224 le dan
    --     a TACTIVIDAD.PONDERACION un nivel abajo: rango 0..100, "el modo de
    --     calculo manda si el campo aplica", y chequeo previo del 100% para
    --     dar un error claro ANTES de que salte el trigger
    --     tr_tunidad_ponderacion_asignatura.
    IF p_ponderacion IS NOT NULL THEN
        IF p_ponderacion < 0 OR p_ponderacion > 100 THEN
            RAISE EXCEPTION 'La ponderacion (%) debe estar entre 0 y 100', p_ponderacion
                USING ERRCODE = '22023';
        END IF;

        -- Quien decide si el peso de la UNIDAD aplica no es la unidad (su
        -- FK_TLV_CALCULO_DEFINITIVA gobierna a sus ACTIVIDADES), sino el PLAN
        -- de la asignatura para ese GRADO: solo si la definitiva se calcula
        -- por UNIDADES y esas unidades se combinan PONDERANDO/SUMANDO existe
        -- un peso de unidad que signifique algo (V239,
        -- fn_planilla_definitiva_proyectada).
        --
        -- TUNIDAD no tiene grupo, por eso se resuelve el plan por GRADO
        -- (fn_asignatura_plan_vigente_por_grado, V239) y no por grupo.
        --
        -- CRITERIO ANTE LO NO RESOLUBLE (consistente con el fallback (e) de
        -- V239): solo se rechaza cuando se puede AFIRMAR que el peso no
        -- aplica. Si no hay fila de TASIGNATURA_PLAN, o el plan no tiene
        -- elemento/modo configurado (helpers -> NULL), no hay con que validar
        -- y se PERMITE guardar el peso: es un dato de configuracion inocuo
        -- que la definitiva simplemente ignorara mientras el plan no lo
        -- habilite, y bloquear ahi impediria preparar la unidad antes de que
        -- coordinacion termine de configurar el plan.
        v_pk_plan := academico_test.fn_asignatura_plan_vigente_por_grado(
                         p_fk_tgrado, p_fk_tasignatura);
        IF v_pk_plan IS NOT NULL THEN
            v_elemento := academico_test.fn_asignatura_plan_elemento_calculo(v_pk_plan);
            v_modo     := academico_test.fn_asignatura_plan_calculo_definitiva_modo(v_pk_plan);

            IF v_elemento = 'ACTIVIDADES' THEN
                RAISE EXCEPTION 'La ponderacion de la unidad no aplica: el plan de la asignatura no calcula por unidades'
                    USING ERRCODE = '22023',
                          HINT = 'TASIGNATURA_PLAN.FK_TLV_ELEMENTO_CALCULO_DEF de esa asignatura combina ACTIVIDADES; el peso por actividad se captura en TACTIVIDAD.PONDERACION (V223)';
            END IF;
            IF v_modo = 'PROMEDIAR' THEN
                RAISE EXCEPTION 'La ponderacion de la unidad no aplica: el plan de la asignatura promedia sus unidades'
                    USING ERRCODE = '22023';
            END IF;
        END IF;

        -- Regla del 100% por (asignatura, grado). Sin excluir nada: la unidad
        -- todavia no existe.
        v_suma := academico_test.fn_unidad_ponderacion_intra_asignatura_asignada(
                      p_fk_tasignatura, p_fk_tgrado, NULL);
        IF v_suma + p_ponderacion > 100 THEN
            RAISE EXCEPTION
              'Las unidades de esa asignatura y grado ya tienen % %% ponderado; % %% adicionales pasarian de 100',
              v_suma, p_ponderacion
              USING ERRCODE = '23514';
        END IF;
    END IF;

    -- 3. Unicidad (NOMBRE, asignatura, grado) entre unidades activas —
    --    backstop del constraint UN_TUNIDAD_1 (V218).
    IF EXISTS (
        SELECT 1 FROM academico_test.TUNIDAD
         WHERE UPPER(TRIM(NOMBRE)) = UPPER(TRIM(p_nombre))
           AND FK_TASIGNATURA = p_fk_tasignatura
           AND FK_TGRADO = p_fk_tgrado
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'Ya existe una unidad activa "%" para esa asignatura y grado', p_nombre
            USING ERRCODE = '23505';
    END IF;

    -- 4. INSERT de la unidad.
    INSERT INTO academico_test.TUNIDAD (
        NOMBRE, FK_TASIGNATURA, FK_TGRADO, FK_TFUNCIONARIO,
        DESCRIPCION, FK_TLV_CALCULO_DEFINITIVA, FK_REFERENTE_CURRICULAR,
        PONDERACION, CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        TRIM(p_nombre), p_fk_tasignatura, p_fk_tgrado, p_fk_tfuncionario,
        NULLIF(TRIM(p_descripcion), ''), p_fk_tlv_calculo_definitiva, p_fk_referente_curricular,
        p_ponderacion, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TUNIDAD INTO v_id_creado;

    -- 5. Objetivos (opcional) — ORDEN por posicion, se ignoran los vacios.
    IF p_objetivos IS NOT NULL THEN
        INSERT INTO academico_test.TUNIDAD_OBJETIVO (FK_TUNIDAD, ORDEN, DESCRIPCION, CREATED_BY, CREATED_AT, ACTIVE)
        SELECT v_id_creado,
               ROW_NUMBER() OVER (ORDER BY o.pos),
               TRIM(o.txt),
               p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
          FROM unnest(p_objetivos) WITH ORDINALITY AS o(txt, pos)
         WHERE NULLIF(TRIM(o.txt), '') IS NOT NULL;
    END IF;

    -- 6. Contenidos / componentes (opcional) — misma regla.
    IF p_contenidos IS NOT NULL THEN
        INSERT INTO academico_test.TUNIDAD_CONTENIDO (FK_TUNIDAD, ORDEN, DESCRIPCION, CREATED_BY, CREATED_AT, ACTIVE)
        SELECT v_id_creado,
               ROW_NUMBER() OVER (ORDER BY c.pos),
               TRIM(c.txt),
               p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
          FROM unnest(p_contenidos) WITH ORDINALITY AS c(txt, pos)
         WHERE NULLIF(TRIM(c.txt), '') IS NOT NULL;
    END IF;

    -- 7. Enunciados del referente curricular que aplican a la unidad
    --    (opcional; TUNIDAD_ENUNCIADO, V136). Delega la validacion completa
    --    (nivel 1, mismo nivel de ensenanza) en fn_unidad_enunciado_relacionar
    --    -- si algun PK no cumple, la funcion revienta y aborta el CREATE
    --    completo (misma transaccion).
    IF p_enunciados IS NOT NULL THEN
        PERFORM academico_test.fn_unidad_enunciado_relacionar(
                    p_pk_usuario_solicitante, v_id_creado, e)
          FROM unnest(p_enunciados) AS e
         WHERE e IS NOT NULL;
    END IF;

    RETURN v_id_creado;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_crear(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, BIGINT, VARCHAR[], VARCHAR[], BIGINT[], NUMERIC)
    IS 'Crea una unidad tematica del Planeador (gate CREAR sobre PLANEADOR): inserta TUNIDAD (identificacion nombre/asignatura/grado/autor + DESCRIPCION + FK_TLV_CALCULO_DEFINITIVA [forma de calculo de la nota, catalogo CALCULO_DEFINITIVA, OBLIGATORIA, V73] + FK_REFERENTE_CURRICULAR [referente al que se acoge, opcional, V212]) y, si se pasan, sus objetivos (TUNIDAD_OBJETIVO), contenidos/componentes (TUNIDAD_CONTENIDO) con ORDEN por posicion del array, ignorando los vacios, y los enunciados del referente que aplican (p_enunciados, PKs de TREFERENTE_ENUNCIADO nivel 1, via fn_unidad_enunciado_relacionar V136 -- valida nivel 1 y mismo nivel de ensenanza que la unidad, aborta el CREATE si alguno no cumple). La unidad ya no depende de un periodo de evaluacion (V218). Valida existencia/estado de todas las FKs y unicidad (nombre, asignatura, grado) entre unidades activas. p_ponderacion (opcional) fija TUNIDAD.PONDERACION (V239): el peso (%) de esta unidad dentro de su (asignatura, grado), analogo a TACTIVIDAD.PONDERACION un nivel abajo. Se valida 0..100, la regla del 100% por (asignatura, grado) via fn_unidad_ponderacion_intra_asignatura_asignada (error claro antes del trigger tr_tunidad_ponderacion_asignatura) y que el campo APLIQUE segun el plan de la asignatura para ese grado (fn_asignatura_plan_vigente_por_grado + fn_asignatura_plan_elemento_calculo / _calculo_definitiva_modo, V239): se rechaza con 22023 si el plan calcula por ACTIVIDADES (el peso de unidad no significa nada) o si PROMEDIA sus unidades. Si el plan no se resuelve o no tiene elemento/modo configurados no hay con que validar y se PERMITE guardar el peso -- criterio consistente con el fallback de V239; la definitiva simplemente lo ignora hasta que el plan lo habilite. Retorna PK_TUNIDAD.';

-- ---------------------------------------------------------------------------
-- Indice de busqueda libre del listado de unidades.
--
-- Mismo patron que idx_tactividad_busqueda_trgm (V224) / la leccion de V112:
-- el texto de la expresion indexada debe coincidir CARACTER A CARACTER con
-- el del WHERE de fn_unidad_listar para que el planner pueda usar el GIN
-- trigram (por eso el predicado de p_search es un unico ILIKE sobre
-- COALESCE(NOMBRE,'') || ' ' || COALESCE(DESCRIPCION,''), no dos ILIKE con
-- OR). CREATE EXTENSION IF NOT EXISTS es seguro de repetir (V112/V224 ya la
-- crean; V216 se aplica antes que V224).
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX IF NOT EXISTS idx_tunidad_busqueda_trgm
    ON academico_test.TUNIDAD
 USING gin ((COALESCE(NOMBRE,'') || ' ' || COALESCE(DESCRIPCION,'')) gin_trgm_ops);

COMMENT ON INDEX academico_test.idx_tunidad_busqueda_trgm
    IS 'GIN trigram sobre NOMBRE+DESCRIPCION concatenados para que p_search (ILIKE %texto%) de fn_unidad_listar no haga Seq Scan. El texto de la expresion debe coincidir exacto con el del WHERE de esa funcion. V216.';

-- ===========================================================================
-- fn_unidad_listar — pagina con filtros/orden (pantalla "Unidad tematica").
--
-- Optimizacion (mismo patron CTE-base de fn_actividad_listar, V224): el CTE
-- "base" resuelve filtro + orden + LIMIT/OFFSET tocando SOLO TUNIDAD (mas el
-- join a TASIGNATURA/TGRADO que exige el ORDER BY por nombre de asignatura o
-- grado) y calcula total_count con COUNT(*) OVER(). Los joins de catalogo y
-- los conteos/fechas derivadas se aplican DESPUES, contra las <= p_limite
-- filas de la pagina -- antes se evaluaban 5 subconsultas correlacionadas
-- por CADA fila del universo, ANTES del LIMIT.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_listar(
    p_pk_usuario_solicitante      BIGINT,
    p_search                      VARCHAR   DEFAULT NULL,
    p_fk_tasignatura              BIGINT    DEFAULT NULL,
    p_fk_tgrado                   BIGINT    DEFAULT NULL,
    p_fk_tfuncionario             BIGINT    DEFAULT NULL,
    p_incluir_inactivos           BOOLEAN   DEFAULT FALSE,
    p_orden_por                   VARCHAR   DEFAULT 'nombre',
    p_orden_asc                   BOOLEAN   DEFAULT TRUE,
    p_limite                      INT       DEFAULT 20,
    p_offset                      INT       DEFAULT 0
)
RETURNS TABLE (
    pk_tunidad                  BIGINT,
    nombre                      VARCHAR,
    descripcion                 VARCHAR,
    fk_tasignatura              BIGINT,
    asignatura                  VARCHAR,
    fk_tarea                    BIGINT,
    area                        VARCHAR,
    fk_tgrado                   BIGINT,
    grado                       VARCHAR,
    fk_tfuncionario             BIGINT,
    docente                     VARCHAR,
    fk_tlv_calculo_definitiva   BIGINT,
    calculo_definitiva          VARCHAR,
    fk_referente_curricular     BIGINT,
    referente_curricular        VARCHAR,
    total_actividades           BIGINT,
    total_objetivos             BIGINT,
    total_contenidos            BIGINT,
    fecha_inicio                DATE,
    fecha_fin                   DATE,
    active                      BOOLEAN,
    total_count                 BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_key VARCHAR;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    -- Whitelist del criterio de orden (evita ramas muertas en el ORDER BY),
    -- mismo patron que fn_actividad_listar (V224).
    v_key := LOWER(TRIM(COALESCE(p_orden_por, 'nombre')));
    IF v_key NOT IN ('nombre', 'asignatura', 'grado') THEN
        v_key := 'nombre';
    END IF;

    RETURN QUERY
    WITH base AS (
        SELECT u.PK_TUNIDAD AS pk,
               COUNT(*) OVER() AS total
          FROM academico_test.TUNIDAD u
          JOIN academico_test.TASIGNATURA basig ON basig.PK_TASIGNATURA = u.FK_TASIGNATURA
          JOIN academico_test.TGRADO bgr        ON bgr.PK_TGRADO = u.FK_TGRADO
         WHERE (p_incluir_inactivos OR u.ACTIVE = TRUE)
           -- Texto libre: la expresion debe ser IDENTICA a la de
           -- idx_tunidad_busqueda_trgm para que el planner la use.
           AND (p_search IS NULL OR
                (COALESCE(u.NOMBRE,'') || ' ' || COALESCE(u.DESCRIPCION,''))
                    ILIKE '%' || p_search || '%')
           AND (p_fk_tasignatura  IS NULL OR u.FK_TASIGNATURA = p_fk_tasignatura)
           AND (p_fk_tgrado       IS NULL OR u.FK_TGRADO = p_fk_tgrado)
           AND (p_fk_tfuncionario IS NULL OR u.FK_TFUNCIONARIO = p_fk_tfuncionario)
         ORDER BY
           CASE WHEN     p_orden_asc AND v_key = 'nombre'     THEN u.NOMBRE     END ASC  NULLS LAST,
           CASE WHEN NOT p_orden_asc AND v_key = 'nombre'     THEN u.NOMBRE     END DESC NULLS LAST,
           CASE WHEN     p_orden_asc AND v_key = 'asignatura' THEN basig.NOMBRE END ASC  NULLS LAST,
           CASE WHEN NOT p_orden_asc AND v_key = 'asignatura' THEN basig.NOMBRE END DESC NULLS LAST,
           CASE WHEN     p_orden_asc AND v_key = 'grado'      THEN bgr.NOMBRE   END ASC  NULLS LAST,
           CASE WHEN NOT p_orden_asc AND v_key = 'grado'      THEN bgr.NOMBRE   END DESC NULLS LAST,
           u.PK_TUNIDAD
         LIMIT GREATEST(p_limite, 1)
        OFFSET GREATEST(p_offset, 0)
    )
    SELECT u.PK_TUNIDAD,
           u.NOMBRE,
           u.DESCRIPCION,
           u.FK_TASIGNATURA,
           asig.NOMBRE,
           asig.FK_TAREA,
           ar.NOMBRE,
           u.FK_TGRADO,
           gr.NOMBRE,
           u.FK_TFUNCIONARIO,
           NULLIF(TRIM(CONCAT_WS(' ', us.PRIMER_NOMBRE, us.SEGUNDO_NOMBRE, us.PRIMER_APELLIDO, us.SEGUNDO_APELLIDO)), '')::VARCHAR,
           u.FK_TLV_CALCULO_DEFINITIVA,
           lvc.NOMBRE,
           u.FK_REFERENTE_CURRICULAR,
           rc.NOMBRE,
           agg.total_actividades,
           (SELECT COUNT(*) FROM academico_test.TUNIDAD_OBJETIVO o  WHERE o.FK_TUNIDAD = u.PK_TUNIDAD AND o.ACTIVE = TRUE),
           (SELECT COUNT(*) FROM academico_test.TUNIDAD_CONTENIDO c WHERE c.FK_TUNIDAD = u.PK_TUNIDAD AND c.ACTIVE = TRUE),
           agg.fecha_inicio,
           agg.fecha_fin,
           u.ACTIVE,
           b.total
      FROM base b
      JOIN academico_test.TUNIDAD u              ON u.PK_TUNIDAD = b.pk
      JOIN academico_test.TASIGNATURA asig       ON asig.PK_TASIGNATURA = u.FK_TASIGNATURA
      LEFT JOIN academico_test.TAREA ar          ON ar.PK_TAREA = asig.FK_TAREA
      JOIN academico_test.TGRADO gr              ON gr.PK_TGRADO = u.FK_TGRADO
      LEFT JOIN academico_test.TFUNCIONARIO fu   ON fu.PK_TFUNCIONARIO = u.FK_TFUNCIONARIO
      LEFT JOIN academico_test.TUSUARIO us       ON us.PK_TUSUARIO = fu.FK_TUSUARIO
      LEFT JOIN academico_test.TLISTA_VALOR lvc  ON lvc.PK_LISTA_VALOR = u.FK_TLV_CALCULO_DEFINITIVA
      LEFT JOIN academico_test.TREFERENTE_CURRICULAR rc ON rc.PK_REFERENTE_CURRICULAR = u.FK_REFERENTE_CURRICULAR
      -- Un solo LATERAL sobre TACTIVIDAD: conteo + fechas derivadas en la
      -- misma pasada (antes eran 3 subconsultas correlacionadas distintas).
      LEFT JOIN LATERAL (
          SELECT COUNT(*)::BIGINT      AS total_actividades,
                 MIN(a.FECHA_INICIO)   AS fecha_inicio,
                 MAX(a.FECHA_CIERRE)   AS fecha_fin
            FROM academico_test.TACTIVIDAD a
           WHERE a.FK_TUNIDAD = u.PK_TUNIDAD AND a.ACTIVE = TRUE
      ) agg ON TRUE
     ORDER BY
       CASE WHEN     p_orden_asc AND v_key = 'nombre'     THEN u.NOMBRE    END ASC  NULLS LAST,
       CASE WHEN NOT p_orden_asc AND v_key = 'nombre'     THEN u.NOMBRE    END DESC NULLS LAST,
       CASE WHEN     p_orden_asc AND v_key = 'asignatura' THEN asig.NOMBRE END ASC  NULLS LAST,
       CASE WHEN NOT p_orden_asc AND v_key = 'asignatura' THEN asig.NOMBRE END DESC NULLS LAST,
       CASE WHEN     p_orden_asc AND v_key = 'grado'      THEN gr.NOMBRE   END ASC  NULLS LAST,
       CASE WHEN NOT p_orden_asc AND v_key = 'grado'      THEN gr.NOMBRE   END DESC NULLS LAST,
       u.PK_TUNIDAD;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_listar(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT)
    IS 'Pagina de TUNIDAD con filtros (search, asignatura, grado, docente) y orden (whitelist nombre|asignatura|grado; cualquier otro valor cae a nombre). p_search hace UN solo ILIKE sobre COALESCE(NOMBRE,'''')||'' ''||COALESCE(DESCRIPCION,''''), expresion identica a la de idx_tunidad_busqueda_trgm para que el GIN trigram se use (no dos ILIKE con OR). Optimizacion: un CTE base pagina tocando solo TUNIDAD+TASIGNATURA+TGRADO y los joins de catalogo, los conteos y el LATERAL de fechas derivadas corren unicamente contra las filas de la pagina (patron de fn_actividad_listar, V224). Devuelve nombres resueltos (asignatura, area via TASIGNATURA.FK_TAREA->TAREA -- la etiqueta "Comunicativa/Cognitiva/..." de las tarjetas), forma de calculo, referente curricular, conteos de actividades/objetivos/contenidos activos y las fechas DERIVADAS de la unidad (MIN FECHA_INICIO / MAX FECHA_CIERRE de sus actividades activas). La unidad ya no depende de un periodo de evaluacion (V218). total_count via COUNT(*) OVER(). Gate VER. p_incluir_inactivos=FALSE por defecto.';

-- ===========================================================================
-- fn_unidad_actualizar — PATCH parcial (cada parametro NULL preserva).
-- ===========================================================================
-- Gana p_ponderacion (NUMERIC) al final: cambia el numero de parametros, asi
-- que CREATE OR REPLACE no reemplaza la firma vieja (12 args) -- mismo patron
-- de DROP FUNCTION IF EXISTS que fn_unidad_crear.
DROP FUNCTION IF EXISTS academico_test.fn_unidad_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BOOLEAN, VARCHAR[], VARCHAR[]);
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_actualizar(
    p_pk_usuario_solicitante        BIGINT,
    p_pk_tunidad                    BIGINT,
    p_nombre                        VARCHAR(250)  DEFAULT NULL,
    p_descripcion                   VARCHAR(4000) DEFAULT NULL,
    p_fk_tasignatura                BIGINT        DEFAULT NULL,
    p_fk_tgrado                     BIGINT        DEFAULT NULL,
    p_fk_tfuncionario               BIGINT        DEFAULT NULL,
    p_fk_tlv_calculo_definitiva     BIGINT        DEFAULT NULL,
    p_fk_referente_curricular       BIGINT        DEFAULT NULL,
    -- NULL param no distingue "no tocar" de "quitar" el referente:
    -- p_limpiar_referente = TRUE fuerza FK_REFERENTE_CURRICULAR a NULL.
    p_limpiar_referente             BOOLEAN       DEFAULT FALSE,
    -- NULL = no tocar la lista; array (incl. vacio) = reemplazo completo:
    -- se desactivan los activos y se re-insertan los del array.
    p_objetivos                     VARCHAR[]     DEFAULT NULL,
    p_contenidos                    VARCHAR[]     DEFAULT NULL,
    -- Peso (%) de la unidad dentro de su (asignatura, grado), TUNIDAD.PONDERACION
    -- (V239). NULL = no tocar; p_limpiar_ponderacion = TRUE lo vuelve NULL
    -- (mismo par "valor / limpiar" que ya usa el referente curricular).
    p_ponderacion                   NUMERIC       DEFAULT NULL,
    p_limpiar_ponderacion           BOOLEAN       DEFAULT FALSE
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_actual     academico_test.TUNIDAD%ROWTYPE;
    v_nombre     VARCHAR(250);
    v_asig       BIGINT;
    v_grado      BIGINT;
    v_ponder     NUMERIC;
    v_pk_plan    BIGINT;
    v_elemento   VARCHAR;
    v_modo       VARCHAR;
    v_suma       NUMERIC(9,2);
BEGIN
    SELECT * INTO v_actual
      FROM academico_test.TUNIDAD
     WHERE PK_TUNIDAD = p_pk_tunidad;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la unidad tematica solicitada'
            USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );

    IF v_actual.ACTIVE = FALSE THEN
        RAISE EXCEPTION 'La unidad "%" esta inactiva (borrado logico); no se puede editar', v_actual.NOMBRE
            USING ERRCODE = '22023';
    END IF;

    IF p_nombre IS NOT NULL AND NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'El nombre de la unidad no puede quedar vacio' USING ERRCODE = '22023';
    END IF;

    -- FKs nuevas (solo si vienen) existen y estan activas.
    IF p_fk_tasignatura IS NOT NULL AND NOT EXISTS (SELECT 1 FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_tasignatura AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'FK_TASIGNATURA (%) no existe o no esta activa', p_fk_tasignatura USING ERRCODE = '23503';
    END IF;
    IF p_fk_tgrado IS NOT NULL AND NOT EXISTS (SELECT 1 FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_tgrado AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'FK_TGRADO (%) no existe o no esta activo', p_fk_tgrado USING ERRCODE = '23503';
    END IF;
    IF p_fk_tfuncionario IS NOT NULL AND NOT EXISTS (SELECT 1 FROM academico_test.TFUNCIONARIO WHERE PK_TFUNCIONARIO = p_fk_tfuncionario AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'FK_TFUNCIONARIO (%) no existe o no esta activo', p_fk_tfuncionario USING ERRCODE = '23503';
    END IF;
    IF p_fk_tlv_calculo_definitiva IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_tlv_calculo_definitiva AND CATEGORIA = 'CALCULO_DEFINITIVA' AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'FK_TLV_CALCULO_DEFINITIVA (%) no existe, no esta activo o no es de la categoria CALCULO_DEFINITIVA', p_fk_tlv_calculo_definitiva
            USING ERRCODE = '23503';
    END IF;
    IF NOT p_limpiar_referente AND p_fk_referente_curricular IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR WHERE PK_REFERENTE_CURRICULAR = p_fk_referente_curricular AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'FK_REFERENTE_CURRICULAR (%) no existe o no esta activo', p_fk_referente_curricular USING ERRCODE = '23503';
    END IF;

    -- Unicidad con los valores resultantes (NOMBRE, asignatura, grado).
    v_nombre := COALESCE(NULLIF(TRIM(p_nombre), ''), v_actual.NOMBRE);
    v_asig   := COALESCE(p_fk_tasignatura, v_actual.FK_TASIGNATURA);
    v_grado  := COALESCE(p_fk_tgrado, v_actual.FK_TGRADO);
    IF EXISTS (
        SELECT 1 FROM academico_test.TUNIDAD
         WHERE UPPER(TRIM(NOMBRE)) = UPPER(TRIM(v_nombre))
           AND FK_TASIGNATURA = v_asig
           AND FK_TGRADO = v_grado
           AND ACTIVE = TRUE
           AND PK_TUNIDAD <> p_pk_tunidad
    ) THEN
        RAISE EXCEPTION 'Ya existe otra unidad activa "%" para esa asignatura y grado', v_nombre
            USING ERRCODE = '23505';
    END IF;

    -- Peso (%) de la unidad dentro de su (asignatura, grado) — TUNIDAD.PONDERACION
    -- (V239). Se valida sobre los valores RESULTANTES del PATCH (v_asig /
    -- v_grado ya calculados arriba), mismo criterio que V224 aplica a
    -- ES_EVALUATIVA / unidad / instrumento: un PATCH que mueve la unidad de
    -- asignatura o de grado cambia el bucket contra el que se mide el 100%.
    v_ponder := CASE WHEN p_limpiar_ponderacion THEN NULL
                     ELSE COALESCE(p_ponderacion, v_actual.PONDERACION) END;

    IF v_ponder IS NOT NULL THEN
        IF v_ponder < 0 OR v_ponder > 100 THEN
            RAISE EXCEPTION 'La ponderacion (%) debe estar entre 0 y 100', v_ponder
                USING ERRCODE = '22023';
        END IF;

        -- Mismo gate por plan (y mismo criterio ante lo no resoluble) que
        -- fn_unidad_crear; ver el comentario extenso del bloque 2.c de esa
        -- funcion. Solo se evalua cuando el caller esta TOCANDO el campo:
        -- un PATCH de otra cosa no debe reventar por un peso heredado que
        -- dejo de aplicar al reconfigurarse el plan.
        IF p_ponderacion IS NOT NULL THEN
            v_pk_plan := academico_test.fn_asignatura_plan_vigente_por_grado(v_grado, v_asig);
            IF v_pk_plan IS NOT NULL THEN
                v_elemento := academico_test.fn_asignatura_plan_elemento_calculo(v_pk_plan);
                v_modo     := academico_test.fn_asignatura_plan_calculo_definitiva_modo(v_pk_plan);

                IF v_elemento = 'ACTIVIDADES' THEN
                    RAISE EXCEPTION 'La ponderacion de la unidad no aplica: el plan de la asignatura no calcula por unidades'
                        USING ERRCODE = '22023',
                              HINT = 'TASIGNATURA_PLAN.FK_TLV_ELEMENTO_CALCULO_DEF de esa asignatura combina ACTIVIDADES; el peso por actividad se captura en TACTIVIDAD.PONDERACION (V223)';
                END IF;
                IF v_modo = 'PROMEDIAR' THEN
                    RAISE EXCEPTION 'La ponderacion de la unidad no aplica: el plan de la asignatura promedia sus unidades'
                        USING ERRCODE = '22023';
                END IF;
            END IF;
        END IF;

        -- Regla del 100% sin contar el peso viejo de la fila que se toca.
        v_suma := academico_test.fn_unidad_ponderacion_intra_asignatura_asignada(
                      v_asig, v_grado, p_pk_tunidad);
        IF v_suma + v_ponder > 100 THEN
            RAISE EXCEPTION
              'Las unidades de esa asignatura y grado ya tienen % %% ponderado; % %% pasarian de 100',
              v_suma, v_ponder
              USING ERRCODE = '23514';
        END IF;
    END IF;

    UPDATE academico_test.TUNIDAD
       SET NOMBRE                    = v_nombre,
           DESCRIPCION               = CASE WHEN p_descripcion IS NULL THEN DESCRIPCION
                                            ELSE NULLIF(TRIM(p_descripcion), '') END,
           FK_TASIGNATURA            = v_asig,
           FK_TGRADO                 = v_grado,
           FK_TFUNCIONARIO           = COALESCE(p_fk_tfuncionario, FK_TFUNCIONARIO),
           FK_TLV_CALCULO_DEFINITIVA = COALESCE(p_fk_tlv_calculo_definitiva, FK_TLV_CALCULO_DEFINITIVA),
           FK_REFERENTE_CURRICULAR   = CASE WHEN p_limpiar_referente THEN NULL
                                            ELSE COALESCE(p_fk_referente_curricular, FK_REFERENTE_CURRICULAR) END,
           PONDERACION               = v_ponder,
           MODIFIED_BY               = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT               = CURRENT_TIMESTAMP
     WHERE PK_TUNIDAD = p_pk_tunidad;

    -- Objetivos: reemplazo completo solo si el caller mando el parametro.
    IF p_objetivos IS NOT NULL THEN
        UPDATE academico_test.TUNIDAD_OBJETIVO
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;

        INSERT INTO academico_test.TUNIDAD_OBJETIVO (FK_TUNIDAD, ORDEN, DESCRIPCION, CREATED_BY, CREATED_AT, ACTIVE)
        SELECT p_pk_tunidad, ROW_NUMBER() OVER (ORDER BY o.pos), TRIM(o.txt),
               p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
          FROM unnest(p_objetivos) WITH ORDINALITY AS o(txt, pos)
         WHERE NULLIF(TRIM(o.txt), '') IS NOT NULL;
    END IF;

    -- Contenidos: idem.
    IF p_contenidos IS NOT NULL THEN
        UPDATE academico_test.TUNIDAD_CONTENIDO
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;

        INSERT INTO academico_test.TUNIDAD_CONTENIDO (FK_TUNIDAD, ORDEN, DESCRIPCION, CREATED_BY, CREATED_AT, ACTIVE)
        SELECT p_pk_tunidad, ROW_NUMBER() OVER (ORDER BY c.pos), TRIM(c.txt),
               p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
          FROM unnest(p_contenidos) WITH ORDINALITY AS c(txt, pos)
         WHERE NULLIF(TRIM(c.txt), '') IS NOT NULL;
    END IF;

    RETURN p_pk_tunidad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BOOLEAN, VARCHAR[], VARCHAR[], NUMERIC, BOOLEAN)
    IS 'PATCH parcial de TUNIDAD (gate EDITAR): cada parametro NULL preserva el valor actual. p_limpiar_referente=TRUE fuerza FK_REFERENTE_CURRICULAR a NULL. p_objetivos / p_contenidos NULL = no tocar; cualquier array (incl. vacio) = reemplazo completo (desactiva los activos y re-inserta con ORDEN por posicion, ignora vacios). Revalida FKs y unicidad (nombre, asignatura, grado) -- la unidad ya no depende de un periodo de evaluacion (V218). p_ponderacion / p_limpiar_ponderacion editan TUNIDAD.PONDERACION (V239, peso % de la unidad dentro de su (asignatura, grado)): NULL = no tocar, p_limpiar_ponderacion=TRUE la vuelve NULL. Se valida contra los valores RESULTANTES del PATCH (un PATCH que mueve la unidad de asignatura o grado cambia el bucket del 100%): rango 0..100, regla del 100% via fn_unidad_ponderacion_intra_asignatura_asignada excluyendo el peso viejo de esta misma unidad, y -- solo cuando el caller esta tocando el campo -- que el peso APLIQUE segun el plan de la asignatura para ese grado (22023 si el plan calcula por ACTIVIDADES o promedia sus unidades; si el plan no se resuelve o no esta configurado se permite, mismo criterio que fn_unidad_crear). Retorna PK_TUNIDAD.';

-- ===========================================================================
-- fn_unidad_eliminar — soft delete en cascada.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_eliminar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tunidad               BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_active         BOOLEAN;
    v_nombre         VARCHAR;
    v_actividades    BIGINT := 0;
    v_objetivos      BIGINT := 0;
    v_contenidos     BIGINT := 0;
    v_criterios      BIGINT := 0;
BEGIN
    SELECT ACTIVE, NOMBRE INTO v_active, v_nombre
      FROM academico_test.TUNIDAD
     WHERE PK_TUNIDAD = p_pk_tunidad;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la unidad tematica solicitada'
            USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'ELIMINAR'
    );

    IF v_active = FALSE THEN
        RAISE EXCEPTION 'La unidad "%" ya se encuentra inactiva', v_nombre
            USING ERRCODE = '22023';
    END IF;

    -- Bloqueo: no se elimina una unidad que todavia tiene actividades activas
    -- vinculadas (TACTIVIDAD.FK_TUNIDAD es opcional desde V218, pero si hay
    -- actividades apuntando a esta unidad hay que soltarlas/eliminarlas antes).
    --
    -- El bloqueo se MANTIENE a proposito: borrar la unidad NO debe arrastrar
    -- en cascada las actividades sin que el usuario lo pida explicitamente
    -- (una actividad puede seguir viva desvinculada). Ya no es un callejon
    -- sin salida: fn_unidad_actividad_desvincular (V223) suelta la actividad
    -- y fn_actividad_eliminar (V224) la borra logicamente.
    SELECT COUNT(*) INTO v_actividades
      FROM academico_test.TACTIVIDAD
     WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;
    IF v_actividades > 0 THEN
        RAISE EXCEPTION 'La unidad "%" tiene % actividad(es) activa(s) vinculada(s); desvinculelas o eliminelas antes de eliminar la unidad', v_nombre, v_actividades
            USING ERRCODE = '23503',
                  HINT = 'Use fn_unidad_actividad_desvincular (V223) para soltar cada actividad, o fn_actividad_eliminar (V224) para borrarla logicamente, y reintente';
    END IF;

    -- 1. Niveles de criterio de la rubrica de la unidad.
    UPDATE academico_test.TNIVEL_CRITERIO_UNIDAD ncu
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TCRITERIO_UNIDAD cu
      JOIN academico_test.TRUBRICA_UNIDAD ru ON ru.PK_TRUBRICA_UNIDAD = cu.FK_TRUBRICA_UNIDAD
     WHERE ncu.FK_TCRITERIO_UNIDAD = cu.PK_TCRITERIO_UNIDAD
       AND ru.FK_TUNIDAD = p_pk_tunidad
       AND ncu.ACTIVE = TRUE;

    -- 2. Criterios de la rubrica de la unidad.
    UPDATE academico_test.TCRITERIO_UNIDAD cu
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TRUBRICA_UNIDAD ru
     WHERE cu.FK_TRUBRICA_UNIDAD = ru.PK_TRUBRICA_UNIDAD
       AND ru.FK_TUNIDAD = p_pk_tunidad
       AND cu.ACTIVE = TRUE;
    GET DIAGNOSTICS v_criterios = ROW_COUNT;

    -- 3. Rubrica de la unidad.
    UPDATE academico_test.TRUBRICA_UNIDAD
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;

    -- 4. Objetivos.
    UPDATE academico_test.TUNIDAD_OBJETIVO
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_objetivos = ROW_COUNT;

    -- 5. Contenidos.
    UPDATE academico_test.TUNIDAD_CONTENIDO
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_contenidos = ROW_COUNT;

    -- 6. La unidad.
    UPDATE academico_test.TUNIDAD
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TUNIDAD = p_pk_tunidad;

    RAISE NOTICE 'Soft delete TUNIDAD=% (autor: %): objetivos=%, contenidos=%, criterios_rubrica=%',
        p_pk_tunidad, p_pk_usuario_solicitante, v_objetivos, v_contenidos, v_criterios;

    RETURN p_pk_tunidad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_eliminar(BIGINT, BIGINT)
    IS 'Soft delete (ACTIVE=FALSE) de una TUNIDAD (gate ELIMINAR), en cascada: niveles -> criterios -> rubrica de la unidad, objetivos, contenidos y la unidad. Se BLOQUEA (23503) si la unidad todavia tiene actividades activas vinculadas (TACTIVIDAD.FK_TUNIDAD): NO se borran actividades en cascada desde la unidad sin que el usuario lo pida explicitamente. El HINT del error indica la salida: fn_unidad_actividad_desvincular (V223) para soltar cada actividad o fn_actividad_eliminar (V224) para borrarla logicamente. Retorna PK_TUNIDAD.';

-- ===========================================================================
-- fn_unidad_criterio_agregar — agrega un criterio a la rubrica de la unidad
-- con un indicador (descriptor) por cada valoracion de la ESCALA definida
-- en los criterios de evaluacion del periodo academico del GRADO de la unidad.
--
-- Resolucion de la escala (modal "Agregar criterio", niveles Bajo/Basico/
-- Alto/Superior -- en realidad los que traiga la escala). Como la unidad ya
-- no tiene FK_TPERIODO_EVALUACION (V218), el periodo academico se toma del
-- grado:
--   TUNIDAD.FK_TGRADO
--     -> TGRADO.FK_TPERIODO_ACADEMICO
--     -> TCRITERIO_EVALUACION (PK = ese periodo academico, 1:1)
--     -> FK_TESCALA -> TESCALA -> TESCALA_VALORACION (una fila por
--        valoracion: Bajo/Basico/Alto/Superior..., con ORDEN y limites).
--
-- El caller manda un indicador por valoracion via p_niveles JSONB
-- (mismo patron JSONB de V113/V198):
--   [ { "fkTescalaValoracion": <PK_TESCALA_VALORACION>,
--       "indicador": "texto del nivel",           -- obligatorio
--       "recomendacion": "texto opcional",
--       "tarea": "texto opcional" }, ... ]
-- Se exige exactamente una entrada por cada valoracion ACTIVA de la escala
-- (ni faltantes ni sobrantes ni duplicadas) -- respeta el UNIQUE
-- (FK_TCRITERIO_UNIDAD, FK_TESCALA_VALORACION) de V22 y el "*" de todos los
-- niveles del modal.
--
-- La rubrica de la unidad (TRUBRICA_UNIDAD, 1:1) se crea al vuelo la
-- primera vez (get-or-create; reactiva una inactiva si la hubiera).
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_criterio_agregar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tunidad               BIGINT,
    p_descripcion              VARCHAR(4000),
    p_niveles                  JSONB,
    p_publico                  VARCHAR(1) DEFAULT 'S',
    p_codigo                   VARCHAR(6) DEFAULT NULL,
    p_descriptor_prom          VARCHAR(1) DEFAULT 'N'
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_unidad_active   BOOLEAN;
    v_fk_tgrado       BIGINT;
    v_fk_tescala      BIGINT;
    v_pk_rubrica      BIGINT;
    v_pk_criterio     BIGINT;
    v_orden           NUMERIC(4);
    v_valoraciones    BIGINT;
    v_payload_total   BIGINT;
    v_payload_unicos  BIGINT;
BEGIN
    -- 0. Gate: capability EDITAR sobre PLANEADOR (se edita la unidad).
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );

    -- 1. Unidad existe y esta activa.
    SELECT ACTIVE, FK_TGRADO
      INTO v_unidad_active, v_fk_tgrado
      FROM academico_test.TUNIDAD
     WHERE PK_TUNIDAD = p_pk_tunidad;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la unidad tematica solicitada' USING ERRCODE = 'P0002';
    END IF;
    IF v_unidad_active = FALSE THEN
        RAISE EXCEPTION 'La unidad esta inactiva; no se le pueden agregar criterios' USING ERRCODE = '22023';
    END IF;

    -- 2. Datos del criterio.
    IF NULLIF(TRIM(p_descripcion), '') IS NULL THEN
        RAISE EXCEPTION 'El texto del criterio es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF UPPER(TRIM(COALESCE(p_publico, ''))) NOT IN ('S', 'N') THEN
        RAISE EXCEPTION 'PUBLICO invalido: % (use ''S'' o ''N'')', p_publico USING ERRCODE = '22023';
    END IF;
    IF p_descriptor_prom IS NOT NULL AND UPPER(TRIM(p_descriptor_prom)) NOT IN ('S', 'N') THEN
        RAISE EXCEPTION 'DESCRIPTOR_PROM invalido: % (use ''S'' o ''N'')', p_descriptor_prom USING ERRCODE = '22023';
    END IF;

    -- 3. Escala definida en los criterios de evaluacion del periodo academico
    --    del grado de la unidad.
    SELECT ce.FK_TESCALA
      INTO v_fk_tescala
      FROM academico_test.TGRADO g
      JOIN academico_test.TCRITERIO_EVALUACION ce
        ON ce.PK_TCRITERIO_EVALUACION = g.FK_TPERIODO_ACADEMICO
       AND ce.ACTIVE = TRUE
     WHERE g.PK_TGRADO = v_fk_tgrado;

    IF v_fk_tescala IS NULL THEN
        RAISE EXCEPTION 'El periodo academico del grado de la unidad no tiene una escala definida en sus criterios de evaluacion'
            USING ERRCODE = '22023',
                  HINT = 'Configure TCRITERIO_EVALUACION.FK_TESCALA para ese periodo academico antes de crear criterios de unidad';
    END IF;

    SELECT COUNT(*) INTO v_valoraciones
      FROM academico_test.TESCALA_VALORACION
     WHERE FK_TESCALA = v_fk_tescala AND ACTIVE = TRUE;
    IF v_valoraciones = 0 THEN
        RAISE EXCEPTION 'La escala (%) no tiene valoraciones activas', v_fk_tescala USING ERRCODE = '22023';
    END IF;

    -- 4. Validacion del payload de niveles.
    IF p_niveles IS NULL OR jsonb_typeof(p_niveles) <> 'array' OR jsonb_array_length(p_niveles) = 0 THEN
        RAISE EXCEPTION 'p_niveles debe ser un arreglo JSON no vacio con un indicador por valoracion de la escala'
            USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_niveles) e
         WHERE NULLIF(TRIM(e->>'indicador'), '') IS NULL
    ) THEN
        RAISE EXCEPTION 'Cada nivel del criterio requiere un indicador no vacio' USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_niveles) e
         WHERE (e->>'fkTescalaValoracion') IS NULL
            OR NOT EXISTS (
                SELECT 1 FROM academico_test.TESCALA_VALORACION ev
                 WHERE ev.PK_TESCALA_VALORACION = (e->>'fkTescalaValoracion')::BIGINT
                   AND ev.FK_TESCALA = v_fk_tescala
                   AND ev.ACTIVE = TRUE
            )
    ) THEN
        RAISE EXCEPTION 'Un nivel referencia una valoracion (fkTescalaValoracion) que no pertenece a la escala de evaluacion de la unidad'
            USING ERRCODE = '23503';
    END IF;

    SELECT COUNT(*), COUNT(DISTINCT (e->>'fkTescalaValoracion')::BIGINT)
      INTO v_payload_total, v_payload_unicos
      FROM jsonb_array_elements(p_niveles) e;

    IF v_payload_total <> v_payload_unicos THEN
        RAISE EXCEPTION 'El payload de niveles tiene valoraciones repetidas' USING ERRCODE = '22023';
    END IF;
    IF v_payload_unicos <> v_valoraciones THEN
        RAISE EXCEPTION 'Debe enviar exactamente un indicador por cada valoracion activa de la escala (esperados: %, recibidos: %)',
            v_valoraciones, v_payload_unicos
            USING ERRCODE = '22023';
    END IF;

    -- 5. Get-or-create de la rubrica de la unidad (1:1) — se DELEGA en
    --    fn_unidad_rubrica_asegurar en vez de repetir el INSERT/SELECT aqui.
    --
    --    DEPENDENCIA INTRA-RAMA: esa funcion se define en V222, que Flyway
    --    aplica DESPUES de este archivo. No importa: el cuerpo de una
    --    funcion plpgsql NO se resuelve en CREATE FUNCTION sino en tiempo de
    --    EJECUCION, asi que V216 aplica limpio y para cuando alguien llame a
    --    fn_unidad_criterio_agregar el historial completo (incluida V222) ya
    --    corrio. Mismo criterio ya usado entre V216/V222/V223/V224 y
    --    documentado en la cabecera de V227.
    v_pk_rubrica := academico_test.fn_unidad_rubrica_asegurar(
                        p_pk_usuario_solicitante, p_pk_tunidad);

    -- 6. Siguiente ORDEN dentro de la rubrica (UNIQUE FK_TRUBRICA_UNIDAD, ORDEN).
    SELECT COALESCE(MAX(ORDEN), 0) + 1 INTO v_orden
      FROM academico_test.TCRITERIO_UNIDAD
     WHERE FK_TRUBRICA_UNIDAD = v_pk_rubrica;

    -- 7. Criterio.
    INSERT INTO academico_test.TCRITERIO_UNIDAD (
        FK_TRUBRICA_UNIDAD, ORDEN, DESCRIPCION, PUBLICO, CODIGO, DESCRIPTOR_PROM,
        CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        v_pk_rubrica, v_orden, TRIM(p_descripcion), UPPER(TRIM(p_publico)),
        NULLIF(TRIM(p_codigo), ''), COALESCE(UPPER(TRIM(p_descriptor_prom)), 'N'),
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TCRITERIO_UNIDAD INTO v_pk_criterio;

    -- 8. Un nivel por valoracion de la escala.
    INSERT INTO academico_test.TNIVEL_CRITERIO_UNIDAD (
        FK_TCRITERIO_UNIDAD, INDICADOR, RECOMENDACION, TAREA, FK_TESCALA_VALORACION,
        CREATED_BY, CREATED_AT, ACTIVE
    )
    SELECT v_pk_criterio,
           TRIM(e->>'indicador'),
           NULLIF(TRIM(e->>'recomendacion'), ''),
           NULLIF(TRIM(e->>'tarea'), ''),
           (e->>'fkTescalaValoracion')::BIGINT,
           p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
      FROM jsonb_array_elements(p_niveles) e;

    RETURN v_pk_criterio;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_criterio_agregar(BIGINT, BIGINT, VARCHAR, JSONB, VARCHAR, VARCHAR, VARCHAR)
    IS 'Agrega un criterio (TCRITERIO_UNIDAD) a la rubrica de la unidad (TRUBRICA_UNIDAD, get-or-create delegado en fn_unidad_rubrica_asegurar de V222 -- dependencia intra-rama resuelta en ejecucion, ver nota en el cuerpo) con un indicador (TNIVEL_CRITERIO_UNIDAD) por cada valoracion de la escala definida en TCRITERIO_EVALUACION.FK_TESCALA del periodo academico del GRADO de la unidad (TGRADO.FK_TPERIODO_ACADEMICO -- la unidad ya no tiene FK_TPERIODO_EVALUACION, V218). p_niveles JSONB = [{fkTescalaValoracion, indicador, recomendacion?, tarea?}]; se exige exactamente una entrada por valoracion activa de la escala (sin faltantes/sobrantes/duplicados). Gate EDITAR sobre PLANEADOR. Retorna PK_TCRITERIO_UNIDAD.';

-- ===========================================================================
-- fn_unidad_actividades_listar — actividades vinculadas a una unidad y su
-- peso dentro de la unidad (pestaña "Actividades" del detalle de unidad:
-- ACTIVIDAD / TIPO / INSTRUMENTO / GRUPO / (%)).
--
-- La columna "(%)" de esa pestaña es PONDERACION (TACTIVIDAD.PONDERACION,
-- V223) -- el peso que el docente edita inline con
-- fn_unidad_actividad_ponderacion_set. INFLUENCIA (V22) es OTRA cosa (peso
-- para el promedio ponderado de TUNIDAD_NOTA) y se sigue devolviendo para no
-- romper el contrato de columnas ya publicado, pero NO es el "(%)" de la
-- pantalla ni el criterio de orden 'porcentaje'.
--
-- Gana la columna PONDERACION en el RETURNS TABLE: cambia el tipo de
-- retorno, asi que CREATE OR REPLACE no basta -- se antepone el
-- DROP FUNCTION IF EXISTS de la firma anterior (mismo patron que V216
-- fn_unidad_crear / V224 fn_actividad_crear).
-- ===========================================================================
DROP FUNCTION IF EXISTS academico_test.fn_unidad_actividades_listar(BIGINT, BIGINT, VARCHAR, BIGINT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT);
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_actividades_listar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tunidad               BIGINT,
    p_search                   VARCHAR   DEFAULT NULL,
    p_fk_tgrupo                BIGINT    DEFAULT NULL,
    p_incluir_inactivas        BOOLEAN   DEFAULT FALSE,
    p_orden_por                VARCHAR   DEFAULT 'actividad',
    p_orden_asc                BOOLEAN   DEFAULT TRUE,
    p_limite                   INT       DEFAULT 50,
    p_offset                   INT       DEFAULT 0
)
RETURNS TABLE (
    pk_tactividad                   BIGINT,
    titulo                          VARCHAR,
    fk_tasignatura                  BIGINT,
    asignatura                      VARCHAR,
    fk_tlv_tipo_actividad           BIGINT,
    tipo_actividad                  VARCHAR,
    fk_tlv_instrumento_evaluacion   BIGINT,
    instrumento_evaluacion          VARCHAR,
    fk_tgrupo                       BIGINT,
    grupo                           VARCHAR,
    fk_tlv_jerarquia                BIGINT,
    jerarquia                       VARCHAR,
    ponderacion                     NUMERIC,
    influencia                      NUMERIC,
    es_evaluativa                   VARCHAR,
    fecha_inicio                    DATE,
    fecha_cierre                    DATE,
    active                          BOOLEAN,
    total_count                     BIGINT
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    IF NOT EXISTS (SELECT 1 FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = p_pk_tunidad) THEN
        RAISE EXCEPTION 'No se encontro la unidad tematica solicitada' USING ERRCODE = 'P0002';
    END IF;

    RETURN QUERY
    SELECT a.PK_TACTIVIDAD,
           a.TITULO,
           a.FK_TASIGNATURA,
           asig.NOMBRE,
           a.FK_TLV_TIPO_ACTIVIDAD,
           lvt.NOMBRE,
           a.FK_TLV_INSTRUMENTO_EVALUACION,
           lvi.NOMBRE,
           a.FK_TGRUPO,
           g.NOMBRE,
           a.FK_TLV_JERARQUIA,
           lvj.NOMBRE,
           a.PONDERACION,
           a.INFLUENCIA,
           a.ES_EVALUATIVA::VARCHAR,
           a.FECHA_INICIO,
           a.FECHA_CIERRE,
           a.ACTIVE,
           COUNT(*) OVER()
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TASIGNATURA asig ON asig.PK_TASIGNATURA = a.FK_TASIGNATURA
      LEFT JOIN academico_test.TLISTA_VALOR lvt ON lvt.PK_LISTA_VALOR = a.FK_TLV_TIPO_ACTIVIDAD
      LEFT JOIN academico_test.TLISTA_VALOR lvi ON lvi.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
      LEFT JOIN academico_test.TLISTA_VALOR lvj ON lvj.PK_LISTA_VALOR = a.FK_TLV_JERARQUIA
      LEFT JOIN academico_test.TGRUPO g         ON g.PK_TGRUPO = a.FK_TGRUPO
     WHERE a.FK_TUNIDAD = p_pk_tunidad
       AND (p_incluir_inactivas OR a.ACTIVE = TRUE)
       AND (p_search IS NULL OR a.TITULO ILIKE '%' || p_search || '%')
       AND (p_fk_tgrupo IS NULL OR a.FK_TGRUPO = p_fk_tgrupo)
     ORDER BY
       CASE WHEN p_orden_asc THEN
           CASE LOWER(TRIM(COALESCE(p_orden_por, 'actividad')))
               WHEN 'actividad'   THEN a.TITULO
               WHEN 'tipo'         THEN lvt.NOMBRE
               WHEN 'instrumento'  THEN lvi.NOMBRE
               WHEN 'grupo'        THEN g.NOMBRE
               ELSE a.TITULO
           END
       END ASC,
       CASE WHEN p_orden_asc AND LOWER(TRIM(COALESCE(p_orden_por, 'actividad'))) = 'porcentaje'
            THEN a.PONDERACION END ASC,
       CASE WHEN NOT p_orden_asc THEN
           CASE LOWER(TRIM(COALESCE(p_orden_por, 'actividad')))
               WHEN 'actividad'   THEN a.TITULO
               WHEN 'tipo'         THEN lvt.NOMBRE
               WHEN 'instrumento'  THEN lvi.NOMBRE
               WHEN 'grupo'        THEN g.NOMBRE
               ELSE a.TITULO
           END
       END DESC,
       CASE WHEN NOT p_orden_asc AND LOWER(TRIM(COALESCE(p_orden_por, 'actividad'))) = 'porcentaje'
            THEN a.PONDERACION END DESC
     LIMIT GREATEST(p_limite, 1)
    OFFSET GREATEST(p_offset, 0);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_actividades_listar(BIGINT, BIGINT, VARCHAR, BIGINT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT)
    IS 'Lista las actividades (TACTIVIDAD) vinculadas a una unidad (FK_TUNIDAD, opcional desde V218) y su peso dentro de ella -- pestaña "Actividades" del detalle de unidad. La columna "(%)" de la pantalla es PONDERACION (TACTIVIDAD.PONDERACION, V223: lo que edita el docente con fn_unidad_actividad_ponderacion_set y lo que valida la regla del 100% por unidad+grupo); INFLUENCIA (V22, peso para el promedio ponderado de TUNIDAD_NOTA) se sigue devolviendo por compatibilidad pero NO es ese "(%)". El criterio de orden ''porcentaje'' ordena por PONDERACION. Devuelve tambien titulo, asignatura (TACTIVIDAD.FK_TASIGNATURA, propia de la actividad desde V218), tipo de actividad, instrumento de evaluacion, grupo y jerarquia resueltos, fechas y ES_EVALUATIVA. Filtros: search sobre TITULO, grupo, incluir_inactivas. Orden: actividad|tipo|instrumento|grupo|porcentaje. total_count via COUNT(*) OVER(). Gate VER sobre PLANEADOR.';

-- ===========================================================================
-- fn_unidad_buscar_por_pk — detalle de la unidad (pestaña "Informacion
-- general": Descripcion + Objetivos + Contenidos + metodo de calculo +
-- Grado + Asignatura + Inicio/Fin derivados + referente curricular).
-- Objetivos y contenidos se devuelven como arreglos JSONB ordenados
-- (mismo patron de agregacion que otros detalles del back).
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_buscar_por_pk(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tunidad               BIGINT
)
RETURNS TABLE (
    pk_tunidad                  BIGINT,
    nombre                      VARCHAR,
    descripcion                 VARCHAR,
    fk_tasignatura              BIGINT,
    asignatura                  VARCHAR,
    fk_tarea                    BIGINT,
    area                        VARCHAR,
    fk_tgrado                   BIGINT,
    grado                       VARCHAR,
    fk_tfuncionario             BIGINT,
    docente                     VARCHAR,
    fk_tlv_calculo_definitiva   BIGINT,
    calculo_definitiva          VARCHAR,
    fk_referente_curricular     BIGINT,
    referente_curricular        VARCHAR,
    total_actividades           BIGINT,
    fecha_inicio                DATE,
    fecha_fin                   DATE,
    objetivos                   JSONB,
    contenidos                  JSONB,
    campos_disponibles          JSONB,
    active                      BOOLEAN
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    RETURN QUERY
    SELECT u.PK_TUNIDAD,
           u.NOMBRE,
           u.DESCRIPCION,
           u.FK_TASIGNATURA,
           asig.NOMBRE,
           asig.FK_TAREA,
           ar.NOMBRE,
           u.FK_TGRADO,
           gr.NOMBRE,
           u.FK_TFUNCIONARIO,
           NULLIF(TRIM(CONCAT_WS(' ', us.PRIMER_NOMBRE, us.SEGUNDO_NOMBRE, us.PRIMER_APELLIDO, us.SEGUNDO_APELLIDO)), '')::VARCHAR,
           u.FK_TLV_CALCULO_DEFINITIVA,
           lvc.NOMBRE,
           u.FK_REFERENTE_CURRICULAR,
           rc.NOMBRE,
           (SELECT COUNT(*) FROM academico_test.TACTIVIDAD a WHERE a.FK_TUNIDAD = u.PK_TUNIDAD AND a.ACTIVE = TRUE),
           (SELECT MIN(a.FECHA_INICIO) FROM academico_test.TACTIVIDAD a WHERE a.FK_TUNIDAD = u.PK_TUNIDAD AND a.ACTIVE = TRUE),
           (SELECT MAX(a.FECHA_CIERRE) FROM academico_test.TACTIVIDAD a WHERE a.FK_TUNIDAD = u.PK_TUNIDAD AND a.ACTIVE = TRUE),
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object('pk', o.PK_TUNIDAD_OBJETIVO, 'orden', o.ORDEN, 'descripcion', o.DESCRIPCION)
                                ORDER BY o.ORDEN)
                 FROM academico_test.TUNIDAD_OBJETIVO o
                WHERE o.FK_TUNIDAD = u.PK_TUNIDAD AND o.ACTIVE = TRUE
           ), '[]'::jsonb),
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object('pk', c.PK_TUNIDAD_CONTENIDO, 'orden', c.ORDEN, 'descripcion', c.DESCRIPCION)
                                ORDER BY c.ORDEN)
                 FROM academico_test.TUNIDAD_CONTENIDO c
                WHERE c.FK_TUNIDAD = u.PK_TUNIDAD AND c.ACTIVE = TRUE
           ), '[]'::jsonb),
           -- Dependencia dinamica "referente -> rubrica" (V137), calculada
           -- solo para esta fila (detalle), no en un listado.
           academico_test.fn_unidad_campos_disponibles(p_pk_usuario_solicitante, u.PK_TUNIDAD),
           u.ACTIVE
      FROM academico_test.TUNIDAD u
      JOIN academico_test.TASIGNATURA asig       ON asig.PK_TASIGNATURA = u.FK_TASIGNATURA
      LEFT JOIN academico_test.TAREA ar          ON ar.PK_TAREA = asig.FK_TAREA
      JOIN academico_test.TGRADO gr              ON gr.PK_TGRADO = u.FK_TGRADO
      LEFT JOIN academico_test.TFUNCIONARIO fu   ON fu.PK_TFUNCIONARIO = u.FK_TFUNCIONARIO
      LEFT JOIN academico_test.TUSUARIO us       ON us.PK_TUSUARIO = fu.FK_TUSUARIO
      LEFT JOIN academico_test.TLISTA_VALOR lvc  ON lvc.PK_LISTA_VALOR = u.FK_TLV_CALCULO_DEFINITIVA
      LEFT JOIN academico_test.TREFERENTE_CURRICULAR rc ON rc.PK_REFERENTE_CURRICULAR = u.FK_REFERENTE_CURRICULAR
     WHERE u.PK_TUNIDAD = p_pk_tunidad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_buscar_por_pk(BIGINT, BIGINT)
    IS 'Detalle de una TUNIDAD (pestaña "Informacion general"): escalares + nombres resueltos (asignatura, area, grado, docente, forma de calculo, referente curricular), total de actividades activas, Inicio/Fin DERIVADOS (MIN FECHA_INICIO / MAX FECHA_CIERRE de sus actividades activas) y los arreglos JSONB ordenados objetivos [{pk,orden,descripcion}] y contenidos [{pk,orden,descripcion}]. campos_disponibles = fn_unidad_campos_disponibles (dependencia dinamica referente->rubrica, V137), calculado solo para esta fila (detalle), no en fn_unidad_listar. La unidad ya no depende de un periodo de evaluacion (V218). SETOF 0 o 1 fila (incluye inactivas). Gate VER.';

-- ===========================================================================
-- fn_unidad_objetivos_listar / fn_unidad_contenidos_listar — listas planas
-- para el editor de la unidad ("Nueva unidad" -> Objetivos / Contenidos).
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_objetivos_listar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tunidad               BIGINT
)
RETURNS TABLE (
    pk_tunidad_objetivo   BIGINT,
    orden                 NUMERIC,
    descripcion           VARCHAR
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    RETURN QUERY
    SELECT o.PK_TUNIDAD_OBJETIVO, o.ORDEN, o.DESCRIPCION
      FROM academico_test.TUNIDAD_OBJETIVO o
     WHERE o.FK_TUNIDAD = p_pk_tunidad AND o.ACTIVE = TRUE
     ORDER BY o.ORDEN;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_objetivos_listar(BIGINT, BIGINT)
    IS 'Objetivos ACTIVE de una unidad (TUNIDAD_OBJETIVO), ordenados por ORDEN. Gate VER sobre PLANEADOR.';

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_contenidos_listar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tunidad               BIGINT
)
RETURNS TABLE (
    pk_tunidad_contenido   BIGINT,
    orden                  NUMERIC,
    descripcion            VARCHAR
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    RETURN QUERY
    SELECT c.PK_TUNIDAD_CONTENIDO, c.ORDEN, c.DESCRIPCION
      FROM academico_test.TUNIDAD_CONTENIDO c
     WHERE c.FK_TUNIDAD = p_pk_tunidad AND c.ACTIVE = TRUE
     ORDER BY c.ORDEN;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_contenidos_listar(BIGINT, BIGINT)
    IS 'Contenidos/componentes ACTIVE de una unidad (TUNIDAD_CONTENIDO), ordenados por ORDEN. Gate VER sobre PLANEADOR.';

-- ===========================================================================
-- fn_unidad_etiqueta_por_grado — nombre con el que se muestra la "unidad".
--
-- El rotulo NO es fijo ("Unidad tematica"): lo define el referente
-- curricular vigente para el nivel educativo del grado. En
-- TREFERENTE_CURRICULAR (V212, rama CU-86e311xqh) el campo INSTRUMENTO es
-- justamente "el nombre con el que se visualizara la unidad" para ese
-- nivel (p.ej. "Unidad tematica", "Proyecto pedagogico", "Relatos
-- pedagogicos...").
--
-- Resolucion:
--   TGRADO.FK_TNIVEL_ENSENANZA
--     -> TREFERENTE_CURRICULAR rc  (mismo nivel educativo, ACTIVE, ESTADO='A'
--        y vigente por anio: ANIO_VIGENCIA_DESDE <= anio actual y
--        ANIO_VIGENCIA_HASTA NULL o >= anio actual)
--     -> rc.INSTRUMENTO
--
-- p_fk_tasignatura (opcional) desempata cuando hay varios referentes para
-- el nivel: se prefiere el que aplica a la asignatura (via
-- TREFERENTE_CURRICULAR_AREA -> TAREA_ASIGNATURA; sin filas = aplica a
-- todas, mismo criterio que V213). Si aun asi quedan varios, gana el de
-- vigencia mas reciente. Si no hay ninguno, cae a 'Unidad tematica'.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_etiqueta_por_grado(
    p_pk_usuario_solicitante   BIGINT,
    p_fk_tgrado                BIGINT,
    p_fk_tasignatura           BIGINT DEFAULT NULL
)
RETURNS VARCHAR
LANGUAGE plpgsql
AS $$
DECLARE
    v_fk_nivel     BIGINT;
    v_anio         INT := EXTRACT(YEAR FROM CURRENT_DATE)::INT;
    v_etiqueta     VARCHAR;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    SELECT g.FK_TNIVEL_ENSENANZA
      INTO v_fk_nivel
      FROM academico_test.TGRADO g
     WHERE g.PK_TGRADO = p_fk_tgrado AND g.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'FK_TGRADO (%) no existe o no esta activo', p_fk_tgrado USING ERRCODE = '23503';
    END IF;

    SELECT rc.INSTRUMENTO
      INTO v_etiqueta
      FROM academico_test.TREFERENTE_CURRICULAR rc
     WHERE rc.FK_TNIVEL_ENSENANZA = v_fk_nivel
       AND rc.ACTIVE = TRUE
       AND rc.ESTADO = 'A'
       AND rc.ANIO_VIGENCIA_DESDE <= v_anio
       AND (rc.ANIO_VIGENCIA_HASTA IS NULL OR rc.ANIO_VIGENCIA_HASTA >= v_anio)
       AND (
             p_fk_tasignatura IS NULL
             OR NOT EXISTS (
                 SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR_AREA a
                  WHERE a.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR AND a.ACTIVE = TRUE
             )
             OR EXISTS (
                 SELECT 1
                   FROM academico_test.TREFERENTE_CURRICULAR_AREA a
                   JOIN academico_test.TASIGNATURA s ON s.FK_TAREA_ASIGNATURA = a.FK_TAREA_ASIGNATURA
                  WHERE a.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                    AND a.ACTIVE = TRUE
                    AND s.PK_TASIGNATURA = p_fk_tasignatura
             )
           )
     ORDER BY
       -- primero los que aplican explicitamente a la asignatura pedida
       (CASE WHEN p_fk_tasignatura IS NOT NULL AND EXISTS (
                 SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR_AREA a
                   JOIN academico_test.TASIGNATURA s ON s.FK_TAREA_ASIGNATURA = a.FK_TAREA_ASIGNATURA
                  WHERE a.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                    AND a.ACTIVE = TRUE AND s.PK_TASIGNATURA = p_fk_tasignatura
             ) THEN 0 ELSE 1 END),
       rc.ANIO_VIGENCIA_DESDE DESC,
       rc.PK_REFERENTE_CURRICULAR DESC
     LIMIT 1;

    RETURN COALESCE(NULLIF(TRIM(v_etiqueta), ''), 'Unidad tematica');
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_etiqueta_por_grado(BIGINT, BIGINT, BIGINT)
    IS 'Devuelve UNICAMENTE el nombre con el que se muestra la "unidad" para un grado dado: TREFERENTE_CURRICULAR.INSTRUMENTO del referente curricular vigente (ACTIVE, ESTADO=''A'', vigente por anio) del nivel educativo del grado (TGRADO.FK_TNIVEL_ENSENANZA). p_fk_tasignatura (opcional) desempata por area (TREFERENTE_CURRICULAR_AREA; sin areas = aplica a todas). Si hay varios, gana el de vigencia mas reciente; si no hay ninguno, retorna ''Unidad tematica''. Gate VER sobre PLANEADOR. Depende de V212 (rama CU-86e311xqh).';
