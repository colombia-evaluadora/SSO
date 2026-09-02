-- ===========================================================================
-- V224 — Planeador educativo: actividades (crear / editar / listar)
-- (CU-86e311xxp — G. Academico Back Planeador educativo).
--
-- Modulos de este archivo:
--   (1) Seed de TLISTA_VALOR         — los 8 catalogos que la pantalla
--                                       "Nueva actividad" usa y que NO
--                                       existen en el servidor.
--   (2) Indices de soporte           — todo el filtrado del listado y del
--                                       tablero entra por indice.
--   (3) Helpers reutilizables        — fn_actividad_lv_assert,
--                                       fn_actividad_estado,
--                                       fn_actividad_material_reemplazar,
--                                       fn_actividad_adaptacion_reemplazar,
--                                       fn_actividad_estudiantes_asignar.
--   (4) Escritura                    — fn_actividad_crear / _actualizar.
--   (5) Lectura optimizada           — fn_actividad_listar,
--                                       fn_actividad_buscar_por_pk,
--                                       fn_actividad_resumen_estados,
--                                       fn_actividad_calendario.
--
-- -------------------------------------------------------------------------
-- CATALOGOS: verificado contra el servidor de test (172.233.184.248,
-- sso_db, Flyway en V217) antes de escribir este archivo:
--
--   YA EXISTEN (del dump base, no se tocan):
--     TIPO_ACTIVIDAD           11 valores (Quiz, Tarea, Trabajo en clase,
--                              Participacion, Exposicion, ... , Otro)
--     TIPO_JERARQUIA_ACTIVIDAD  2 valores (Actividad=439, Criterio=440)
--                              OJO: la categoria se llama
--                              TIPO_JERARQUIA_ACTIVIDAD, no
--                              "JERARQUIA_ACTIVIDAD" como sugiere el
--                              comentario de TACTIVIDAD.FK_TLV_JERARQUIA
--                              en V22.
--     TIPO_CALCULO              4 valores (Promediado, Ponderado,
--                              Sumatoria, Nota Directa)
--
--   NO EXISTIAN — se seedean aqui (bloque 1). V22 creo las columnas
--   FK_TLV_MODALIDAD / _INSTRUMENTO_EVALUACION / _TIPO_EVIDENCIA en
--   TACTIVIDAD, FK_TLV_TIPO_RECURSO en TACTIVIDAD_MATERIAL y
--   FK_TLV_TIPO_ADAPTACION / _FORMATO_ADAPTACION / _APLICA_A en
--   TACTIVIDAD_ADAPTACION, pero nunca seedeo sus catalogos: sin esto los
--   selects de la pantalla salen vacios y no se puede crear ninguna
--   actividad con instrumento/modalidad/adaptaciones.
--     MODALIDAD, INSTRUMENTO_EVALUACION, TIPO_EVIDENCIA,
--     TIPO_RECURSO, TIPO_ADAPTACION, FORMATO_ADAPTACION, APLICA_A
--
--   NO se seedea METODO_VALORACION: V22 creo
--   TACTIVIDAD.FK_TLV_METODO_VALORACION pero NINGUN campo del formulario
--   "Nueva actividad" (secciones Identificacion / Programacion / Evaluacion
--   / Adaptaciones / Seguimiento del figma) le corresponde — la seccion
--   Evaluacion solo tiene ¿Es evaluativa? (ES_EVALUATIVA), Instrumento
--   (FK_TLV_INSTRUMENTO_EVALUACION) y Ponderacion (PONDERACION). La columna
--   queda como parametro OPCIONAL de fn_actividad_crear/_actualizar por si
--   otro flujo la usa; cuando el negocio defina su lista se agrega el seed
--   y el campo en la UI.
--
--   Procedencia de los valores seedeados:
--     * INSTRUMENTO_EVALUACION, TIPO_ADAPTACION, FORMATO_ADAPTACION:
--       EXACTOS del figma (capturas de "Nueva actividad").
--     * MODALIDAD ("Mixta" confirmada en el figma de detalle): comentario
--       de V22 (Presencial / Virtual / Mixta).
--     * TIPO_RECURSO: etiquetas del figma del bloque "Materiales de apoyo"
--       ("Recurso 1 - Fuente" -> Tipo / URL / Sitio web).
--     * TIPO_EVIDENCIA: del figma solo se confirma el valor "Archivo"
--       (bloque Seguimiento); el resto (Enlace / Texto / Otro) es una lista
--       MINIMA propuesta, alineada con las banderas REQUIERE_ARCHIVO /
--       REQUIERE_TEXTO de V22. PENDIENTE de confirmar con negocio.
--     * APLICA_A: derivado del requisito "la adaptacion aplica a ciertos
--       estudiantes de ese grupo" -> TODO_EL_GRUPO / ESTUDIANTES_SELECCIONADOS.
--   Cambiar cualquiera de estas listas es un seed nuevo: el codigo solo
--   depende de la CATEGORIA (y, en adaptaciones, de los VALOR ARCHIVO /
--   ENLACE / BIBLIOTECA y ESTUDIANTES_SELECCIONADOS), nunca de los PK.
--
--   NO se puede reutilizar ningun catalogo existente en su lugar
--   (verificado en el servidor): TIPO_FUENTE son placeholders "Tipo 1/2/3",
--   TIPO_ARCHIVO son documentos de matricula/funcionario, y
--   TIPO_DISCAPACIDAD es el atributo del estudiante
--   (TESTUDIANTE.FK_TDISCAPACIDAD -> TDISCAPACIDAD), otro eje distinto del
--   tipo de adaptacion de una actividad.
--
-- -------------------------------------------------------------------------
-- ESTADO DE LA ACTIVIDAD (derivado, no es columna)
--
--   Las tarjetas del Planeador (Pendientes por evaluar / En evaluacion
--   vigentes / Finalizadas / Vencidas > 2 dias) NO salen de una columna de
--   estado: se derivan de FECHA_INICIO / FECHA_CIERRE / FECHA_CALIFICADO.
--   fn_actividad_estado centraliza esa derivacion (IMMUTABLE, recibe el
--   "hoy" por parametro para poder serlo) y la usan por igual el listado,
--   el detalle, el calendario y el resumen — una sola definicion.
--
-- Reutiliza lo ya construido en esta rama en vez de duplicarlo:
--   * fn_assert_permiso_seccion(usuario,'PLANEADOR',accion) — gate (V216).
--   * fn_unidad_actividad_vincular / _ponderacion_set / _desvincular (V223)
--     desde fn_actividad_actualizar (ahi el gate coincide, EDITAR), para
--     que la regla del 100% viva en UN solo lugar.
--   * trigger tr_tactividad_ponderacion_unidad (V223) — en
--     fn_actividad_crear el INSERT lleva FK_TUNIDAD/PONDERACION directo y
--     el trigger valida el 100%; no se re-implementa la suma en ningun lado.
--
-- Depende de (orden de version de Flyway):
--   * V22  — TACTIVIDAD, TACTIVIDAD_MATERIAL, TACTIVIDAD_ADAPTACION,
--            TACTIVIDAD_ESTUDIANTE, TACTIVIDAD_NOTA, TMATRICULA, TGRUPO,
--            TASIGNATURA, TAREA, TLISTA_VALOR, TARCHIVO.
--   * V112 — extension pg_trgm (se re-asegura aqui, idempotente).
--   * V218 — TACTIVIDAD.FK_TASIGNATURA (NOT NULL), FK_TUNIDAD nullable.
--   * V223 — TACTIVIDAD.PONDERACION + trigger del 100% + fn_unidad_actividad_*.
--   * V216 — menu 'PLANEADOR'; V29/V185/V213 — fn_assert_permiso_seccion.
--
-- Nota de rendimiento (honesta): los filtros del listado entran por indice
-- (es la parte cara); el ORDER BY se arma con CASE tipados, asi que el
-- ordenamiento final SI hace un sort — sobre las filas ya filtradas, no
-- sobre la tabla. No se uso SQL dinamico para ganar el Index Scan ordenado
-- porque el volumen esperado por (asignatura + ventana de fechas) es de
-- decenas/cientos de filas y no compensa el riesgo.
--
-- Estilo: V213/V216 (gate, 22023/23503/23505/P0002, PATCH con COALESCE,
-- agregacion JSONB, COMMENT ON FUNCTION), V120/V212 (seed idempotente con
-- WHERE NOT EXISTS sobre la UNIQUE (CATEGORIA, VALOR)) y V112 (indice de
-- expresion GIN trigram cuyo texto debe coincidir caracter a caracter con
-- el WHERE).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ===========================================================================
-- (1) SEED DE TLISTA_VALOR — catalogos faltantes de la pantalla de actividad
-- ===========================================================================
INSERT INTO academico_test.tlista_valor (categoria, nombre, valor, created_by)
SELECT v.categoria, v.nombre, v.valor, 'V224_seed'
  FROM (VALUES
    -- Programacion
    ('MODALIDAD'::VARCHAR,              'Presencial'::VARCHAR,                'PRESENCIAL'::VARCHAR),
    ('MODALIDAD',                       'Virtual',                            'VIRTUAL'),
    ('MODALIDAD',                       'Mixta',                              'MIXTA'),
    -- Evaluacion (valores exactos del figma)
    ('INSTRUMENTO_EVALUACION',          'Rúbrica',                            'RUBRICA'),
    ('INSTRUMENTO_EVALUACION',          'Lista de cotejo',                    'LISTA_COTEJO'),
    ('INSTRUMENTO_EVALUACION',          'Escala de valoración',               'ESCALA_VALORACION'),
    ('INSTRUMENTO_EVALUACION',          'Otro (personalizado)',               'OTRO'),
    -- Seguimiento
    ('TIPO_EVIDENCIA',                  'Archivo',                            'ARCHIVO'),
    ('TIPO_EVIDENCIA',                  'Enlace',                             'ENLACE'),
    ('TIPO_EVIDENCIA',                  'Texto',                              'TEXTO'),
    ('TIPO_EVIDENCIA',                  'Otro',                               'OTRO'),
    -- Materiales de apoyo (TACTIVIDAD_MATERIAL: URL XOR ARCHIVO).
    -- Etiquetas del figma ("Recurso 1 - Fuente" -> Tipo / URL / Sitio web).
    ('TIPO_RECURSO',                    'URL / Sitio web',                    'URL'),
    ('TIPO_RECURSO',                    'Archivo',                            'ARCHIVO'),
    -- Adaptaciones curriculares (TACTIVIDAD_ADAPTACION) — valores exactos
    -- del figma "¿Que tipo de adaptacion requiere esta actividad?".
    ('TIPO_ADAPTACION',                 'Discapacidad visual',                             'DISCAPACIDAD_VISUAL'),
    ('TIPO_ADAPTACION',                 'Discapacidad auditiva',                           'DISCAPACIDAD_AUDITIVA'),
    ('TIPO_ADAPTACION',                 'Dificultades cognitivas',                         'DIFICULTADES_COGNITIVAS'),
    ('TIPO_ADAPTACION',                 'Estilo de aprendizaje (visual, kinestésico, auditivo)', 'ESTILO_APRENDIZAJE'),
    ('TIPO_ADAPTACION',                 'Modalidad (virtual, asincrónica, presencial)',    'MODALIDAD'),
    ('TIPO_ADAPTACION',                 'Nivel de desempeño (refuerzo, ampliación)',       'NIVEL_DESEMPENO'),
    ('TIPO_ADAPTACION',                 'Otro',                                            'OTRO'),
    -- FORMATO_ADAPTACION = de donde sale la plantilla modificada del
    -- instrumento, cuando USA_VERSION_MODIFICADA = 'S' (figma: "¿Se usara
    -- una version modificada del instrumento de evaluacion?" ->
    -- No | Si, Adjuntar plantilla (archivo|enlace|biblioteca)).
    ('FORMATO_ADAPTACION',              'Archivo',                            'ARCHIVO'),
    ('FORMATO_ADAPTACION',              'Enlace',                             'ENLACE'),
    ('FORMATO_ADAPTACION',              'Biblioteca',                         'BIBLIOTECA'),
    -- APLICA_A = alcance de la adaptacion dentro del grupo. Cuando es
    -- ESTUDIANTES_SELECCIONADOS, el detalle de a QUE estudiantes aplica vive
    -- en TACTIVIDAD_ADAPTACION_ESTUDIANTE (bloque 2), no en este catalogo.
    ('APLICA_A',                        'Todo el grupo',                      'TODO_EL_GRUPO'),
    ('APLICA_A',                        'Estudiantes seleccionados',          'ESTUDIANTES_SELECCIONADOS')
  ) AS v(categoria, nombre, valor)
 WHERE NOT EXISTS (
     SELECT 1 FROM academico_test.tlista_valor lv
      WHERE lv.categoria = v.categoria AND lv.valor = v.valor
 );

-- ===========================================================================
-- (2) TACTIVIDAD_ADAPTACION_ESTUDIANTE — a que estudiantes del grupo aplica
--     una adaptacion curricular.
--
-- "¿A quien se aplica esta adaptacion?" no es un enum estudiante/grupo: una
-- adaptacion aplica a CIERTOS estudiantes del grupo. TACTIVIDAD_ADAPTACION
-- (V22) solo tiene FK_TLV_APLICA_A, que alcanza para el ALCANCE
-- (TODO_EL_GRUPO / ESTUDIANTES_SELECCIONADOS) pero no puede guardar una
-- lista. Se agrega el pivote.
--
-- Apunta a TACTIVIDAD_ESTUDIANTE (no a TMATRICULA) por consistencia con el
-- resto de satelites por estudiante de V22 — TACTIVIDAD_NOTA,
-- TACTIVIDAD_SOPORTE, TACTIVIDAD_RUBRICA_EVALUACION,
-- TACTIVIDAD_COTEJO_EVALUACION y TACTIVIDAD_ESCALA_EVALUACION cuelgan todos
-- de FK_TACTIVIDAD_ESTUDIANTE. Ademas garantiza por construccion que el
-- estudiante este asignado a ESA actividad.
-- ===========================================================================

CREATE TABLE IF NOT EXISTS TACTIVIDAD_ADAPTACION_ESTUDIANTE (
  PK_TACTIVIDAD_ADAPTACION_ESTUDIANTE BIGINT GENERATED BY DEFAULT AS IDENTITY NOT NULL,
  FK_TACTIVIDAD_ADAPTACION BIGINT NOT NULL,
  FK_TACTIVIDAD_ESTUDIANTE BIGINT NOT NULL,
  CREATED_BY VARCHAR(120) NOT NULL,
  CREATED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
  MODIFIED_BY VARCHAR(120),
  MODIFIED_AT TIMESTAMP,
  ACTIVE BOOLEAN DEFAULT TRUE NOT NULL,
  CONSTRAINT PK_TAC_ADAPTACION_ESTUDIANTE PRIMARY KEY (PK_TACTIVIDAD_ADAPTACION_ESTUDIANTE),
  CONSTRAINT FK_TAC_ADAPT_EST_1 FOREIGN KEY (FK_TACTIVIDAD_ADAPTACION)
    REFERENCES TACTIVIDAD_ADAPTACION (PK_TACTIVIDAD_ADAPTACION) ON DELETE CASCADE,
  CONSTRAINT FK_TAC_ADAPT_EST_2 FOREIGN KEY (FK_TACTIVIDAD_ESTUDIANTE)
    REFERENCES TACTIVIDAD_ESTUDIANTE (PK_TACTIVIDAD_ESTUDIANTE) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS IDX_TAC_ADAPT_EST_1
    ON TACTIVIDAD_ADAPTACION_ESTUDIANTE (FK_TACTIVIDAD_ADAPTACION) WHERE ACTIVE = TRUE;
CREATE INDEX IF NOT EXISTS IDX_TAC_ADAPT_EST_2
    ON TACTIVIDAD_ADAPTACION_ESTUDIANTE (FK_TACTIVIDAD_ESTUDIANTE) WHERE ACTIVE = TRUE;

-- Unicidad solo entre filas vivas (patron V65/V212): el mismo par puede
-- reinsertarse tras un borrado logico sin chocar con la fila inactiva.
CREATE UNIQUE INDEX IF NOT EXISTS U_TAC_ADAPTACION_ESTUDIANTE_1
    ON TACTIVIDAD_ADAPTACION_ESTUDIANTE (FK_TACTIVIDAD_ADAPTACION, FK_TACTIVIDAD_ESTUDIANTE)
 WHERE ACTIVE = TRUE;

COMMENT ON COLUMN TACTIVIDAD_ADAPTACION_ESTUDIANTE.FK_TACTIVIDAD_ADAPTACION IS 'Adaptacion curricular. ON DELETE CASCADE';
COMMENT ON COLUMN TACTIVIDAD_ADAPTACION_ESTUDIANTE.FK_TACTIVIDAD_ESTUDIANTE IS 'Asignacion actividad-estudiante a la que aplica la adaptacion (garantiza que el estudiante este asignado a esa actividad)';
COMMENT ON TABLE TACTIVIDAD_ADAPTACION_ESTUDIANTE IS 'Estudiantes concretos del grupo a los que aplica una adaptacion curricular. Solo tiene filas cuando TACTIVIDAD_ADAPTACION.FK_TLV_APLICA_A = ESTUDIANTES_SELECCIONADOS; con TODO_EL_GRUPO va vacia. V224.';

COMMENT ON COLUMN TACTIVIDAD_ADAPTACION.FK_TLV_APLICA_A IS 'Alcance de la adaptacion dentro del grupo. TLISTA_VALOR CATEGORIA=''APLICA_A'': TODO_EL_GRUPO o ESTUDIANTES_SELECCIONADOS. En el segundo caso, los estudiantes concretos van en TACTIVIDAD_ADAPTACION_ESTUDIANTE (V224).';

-- TACTIVIDAD_ADAPTACION.URL — la opcion "Si, Adjuntar plantilla (enlace)"
-- del figma necesita guardar una URL; V22 solo dejo FK_TARCHIVO, que cubre
-- las opciones (archivo) y (biblioteca) pero no (enlace).
ALTER TABLE TACTIVIDAD_ADAPTACION ADD COLUMN IF NOT EXISTS URL VARCHAR(4000);

COMMENT ON COLUMN TACTIVIDAD_ADAPTACION.URL IS 'Enlace a la plantilla modificada del instrumento cuando FK_TLV_FORMATO_ADAPTACION = ENLACE. Para ARCHIVO/BIBLIOTECA se usa FK_TARCHIVO. V224.';

COMMENT ON COLUMN TACTIVIDAD_ADAPTACION.USA_VERSION_MODIFICADA IS 'Indica si se usa una version modificada del instrumento de evaluacion (S/N). Si es ''S'', FK_TLV_FORMATO_ADAPTACION dice de donde sale la plantilla (ARCHIVO/BIBLIOTECA -> FK_TARCHIVO; ENLACE -> URL). CHECK IN (S,N).';

-- ===========================================================================
-- (2) INDICES DE SOPORTE
-- ===========================================================================

CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Busqueda libre del Planeador ("Buscar por nombre, nivel educativo o
-- instrumento"). El texto de la expresion DEBE coincidir caracter a
-- caracter con el del WHERE de fn_actividad_listar para que el planner
-- pueda usar el indice (leccion de V112).
CREATE INDEX IF NOT EXISTS idx_tactividad_busqueda_trgm
    ON academico_test.TACTIVIDAD
 USING gin ((COALESCE(TITULO,'') || ' ' || COALESCE(DESCRIPCION,'')) gin_trgm_ops);

COMMENT ON INDEX academico_test.idx_tactividad_busqueda_trgm
    IS 'GIN trigram sobre TITULO+DESCRIPCION concatenados para que p_search (ILIKE %texto%) de fn_actividad_listar no haga Seq Scan. El texto de la expresion debe coincidir exacto con el del WHERE de esa funcion. V224.';

-- Filtro mas comun del listado: asignatura + ventana de fechas, solo vivas.
-- PK al final para permitir Index Only Scan en el CTE de paginado.
CREATE INDEX IF NOT EXISTS idx_tactividad_asignatura_fechas
    ON academico_test.TACTIVIDAD (FK_TASIGNATURA, FECHA_INICIO, FECHA_CIERRE, PK_TACTIVIDAD)
 WHERE ACTIVE = TRUE;

COMMENT ON INDEX academico_test.idx_tactividad_asignatura_fechas
    IS 'Listado de actividades por asignatura acotado por ventana de fechas (fn_actividad_listar, fn_actividad_calendario). Parcial WHERE ACTIVE para no indexar el historico borrado logicamente. V224.';

-- Calendario / tablero por grupo.
CREATE INDEX IF NOT EXISTS idx_tactividad_grupo_fechas
    ON academico_test.TACTIVIDAD (FK_TGRUPO, FECHA_INICIO, FECHA_CIERRE, PK_TACTIVIDAD)
 WHERE ACTIVE = TRUE;

COMMENT ON INDEX academico_test.idx_tactividad_grupo_fechas
    IS 'Grilla mensual y filtros por grupo (fn_actividad_calendario, fn_actividad_listar). V224.';

-- Tablero: "Pendientes por evaluar" y "Vencidas > N dias" solo miran
-- actividades vivas SIN calificar -> indice parcial que ya deja fuera la
-- mayoria de las filas irrelevantes.
CREATE INDEX IF NOT EXISTS idx_tactividad_sin_calificar
    ON academico_test.TACTIVIDAD (FECHA_CIERRE, FK_TASIGNATURA, FK_TGRUPO)
 WHERE ACTIVE = TRUE AND FECHA_CALIFICADO IS NULL;

COMMENT ON INDEX academico_test.idx_tactividad_sin_calificar
    IS 'Soporta los contadores "Pendientes por evaluar" y "Vencidas (> N dias)" de fn_actividad_resumen_estados: parcial sobre las actividades vivas aun sin FECHA_CALIFICADO. V224.';

-- Progreso de evaluacion: el LATERAL entra por FK_TACTIVIDAD.
-- IDX_TACTIVIDAD_ESTUDIANTE_1 (V22) lo cubre; esta variante parcial + PK
-- permite resolver el conteo sin tocar el heap.
CREATE INDEX IF NOT EXISTS idx_tactividad_estudiante_actividad_activo
    ON academico_test.TACTIVIDAD_ESTUDIANTE (FK_TACTIVIDAD, PK_TACTIVIDAD_ESTUDIANTE)
 WHERE ACTIVE = TRUE;

COMMENT ON INDEX academico_test.idx_tactividad_estudiante_actividad_activo
    IS 'Conteo asignados/evaluados por actividad (LATERAL de fn_actividad_listar y fn_actividad_buscar_por_pk). V224.';

-- ===========================================================================
-- (3) HELPERS REUTILIZABLES
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- fn_actividad_lv_assert — valida una FK a TLISTA_VALOR.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_lv_assert(
    p_fk         BIGINT,
    p_categoria  VARCHAR,
    p_etiqueta   VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_categoria_existe BOOLEAN;
BEGIN
    IF p_fk IS NULL THEN
        RETURN;                     -- opcional: el caller ya exigio si aplica
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION '% (%) no existe en TLISTA_VALOR o no esta activo', p_etiqueta, p_fk
            USING ERRCODE = '23503';
    END IF;

    -- La categoria se exige solo si esta seedeada. Tras el bloque (1) de
    -- esta misma migracion todas las categorias usadas aqui existen, asi
    -- que en la practica el chequeo es siempre estricto; el guard queda
    -- como red de seguridad para entornos donde el seed sea no-op.
    SELECT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE CATEGORIA = p_categoria AND ACTIVE = TRUE
    ) INTO v_categoria_existe;

    IF v_categoria_existe AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk AND CATEGORIA = p_categoria AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION '% (%) no pertenece a la categoria % de TLISTA_VALOR', p_etiqueta, p_fk, p_categoria
            USING ERRCODE = '23503';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_lv_assert(BIGINT, VARCHAR, VARCHAR)
    IS 'Valida una FK a TLISTA_VALOR: NULL pasa (opcional), si viene debe existir y estar ACTIVE, y debe ser de p_categoria (se exige solo si esa categoria esta seedeada; tras el seed de V224 siempre lo esta). Lanza 23503 con p_etiqueta en el mensaje. V224.';

-- ---------------------------------------------------------------------------
-- fn_actividad_estado — derivacion unica del estado de una actividad.
-- IMMUTABLE: "hoy" entra por parametro, no se lee CURRENT_DATE adentro.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_estado(
    p_fecha_inicio      DATE,
    p_fecha_cierre      DATE,
    p_fecha_calificado  DATE,
    p_hoy               DATE,
    p_dias_gracia       INT DEFAULT 2
)
RETURNS VARCHAR
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT CASE
        WHEN p_fecha_calificado IS NOT NULL                                  THEN 'FINALIZADA'
        WHEN p_fecha_inicio IS NULL AND p_fecha_cierre IS NULL               THEN 'SIN_PROGRAMAR'
        WHEN p_fecha_cierre IS NOT NULL
         AND p_hoy > p_fecha_cierre + COALESCE(p_dias_gracia, 2)             THEN 'VENCIDA'
        WHEN p_fecha_cierre IS NOT NULL AND p_hoy > p_fecha_cierre           THEN 'PENDIENTE_POR_EVALUAR'
        WHEN p_fecha_inicio IS NOT NULL AND p_hoy < p_fecha_inicio           THEN 'PROGRAMADA'
        ELSE 'EN_EVALUACION'
    END::VARCHAR;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_estado(DATE, DATE, DATE, DATE, INT)
    IS 'Estado DERIVADO de una actividad (no hay columna de estado), en este orden: FINALIZADA (tiene FECHA_CALIFICADO) > SIN_PROGRAMAR (sin fechas) > VENCIDA (cierre + p_dias_gracia < hoy, sin calificar) > PENDIENTE_POR_EVALUAR (cierre pasado, dentro de la gracia) > PROGRAMADA (aun no inicia) > EN_EVALUACION (vigente). IMMUTABLE: recibe el "hoy" por parametro. Unica definicion, usada por listar / detalle / calendario / resumen. V224.';

-- ---------------------------------------------------------------------------
-- fn_actividad_material_reemplazar — materiales de apoyo.
-- p_materiales JSONB = [{tipoRecurso, url?, fkTarchivo?, descripcion?}]
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_material_reemplazar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    p_materiales               JSONB
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_insertados INT := 0;
BEGIN
    IF p_materiales IS NULL THEN
        RETURN 0;                          -- NULL = no tocar la lista
    END IF;
    IF jsonb_typeof(p_materiales) <> 'array' THEN
        RAISE EXCEPTION 'p_materiales debe ser un arreglo JSON' USING ERRCODE = '22023';
    END IF;

    -- Cada elemento debe traer EXACTAMENTE uno de url / fkTarchivo
    -- (mismo criterio que el CHECK CK_TACTIVIDAD_MATERIAL_RECURSO de V22).
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_materiales) e
         WHERE (NULLIF(TRIM(e->>'url'), '') IS NULL) = ((e->>'fkTarchivo') IS NULL)
    ) THEN
        RAISE EXCEPTION 'Cada material debe traer url O fkTarchivo (exactamente uno)'
            USING ERRCODE = '22023';
    END IF;
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_materiales) e
         WHERE (e->>'tipoRecurso') IS NULL
    ) THEN
        RAISE EXCEPTION 'Cada material requiere tipoRecurso (FK a TLISTA_VALOR, categoria TIPO_RECURSO)'
            USING ERRCODE = '22023';
    END IF;

    PERFORM academico_test.fn_actividad_lv_assert(
                (e->>'tipoRecurso')::BIGINT, 'TIPO_RECURSO', 'tipoRecurso')
       FROM jsonb_array_elements(p_materiales) e;

    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_materiales) e
         WHERE (e->>'fkTarchivo') IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM academico_test.TARCHIVO t
                            WHERE t.PK_TARCHIVO = (e->>'fkTarchivo')::BIGINT)
    ) THEN
        RAISE EXCEPTION 'Uno o mas fkTarchivo no existen en TARCHIVO' USING ERRCODE = '23503';
    END IF;

    UPDATE academico_test.TACTIVIDAD_MATERIAL
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;

    INSERT INTO academico_test.TACTIVIDAD_MATERIAL (
        FK_TACTIVIDAD, ORDEN, FK_TLV_TIPO_RECURSO, URL, FK_TARCHIVO, DESCRIPCION,
        CREATED_BY, CREATED_AT, ACTIVE
    )
    SELECT p_pk_tactividad,
           e.pos,
           (e.j->>'tipoRecurso')::BIGINT,
           NULLIF(TRIM(e.j->>'url'), ''),
           (e.j->>'fkTarchivo')::BIGINT,
           NULLIF(TRIM(e.j->>'descripcion'), ''),
           p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
      FROM (SELECT elem AS j, ord AS pos
              FROM jsonb_array_elements(p_materiales) WITH ORDINALITY AS t(elem, ord)) e;

    GET DIAGNOSTICS v_insertados = ROW_COUNT;
    RETURN v_insertados;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_material_reemplazar(BIGINT, BIGINT, JSONB)
    IS 'Reemplazo completo de los materiales de apoyo de una actividad (TACTIVIDAD_MATERIAL): desactiva los ACTIVE y re-inserta los del array con ORDEN por posicion. p_materiales NULL = no tocar; array vacio = dejarla sin materiales. Cada elemento {tipoRecurso, url|fkTarchivo, descripcion?} debe traer exactamente uno de url/fkTarchivo (CHECK de V22). Helper de fn_actividad_crear/_actualizar. Retorna cuantos quedaron. V224.';

-- ---------------------------------------------------------------------------
-- fn_actividad_adaptacion_reemplazar — adaptaciones curriculares.
--
-- p_adaptaciones JSONB = [{
--     tipoAdaptacion,                     -- obligatorio (TIPO_ADAPTACION)
--     descripcion,                        -- obligatorio, max 500 (figma)
--     usaVersionModificada,               -- 'S' | 'N' (default 'N')
--     formatoAdaptacion,                  -- si 'S': ARCHIVO|ENLACE|BIBLIOTECA
--     fkTarchivo,                         -- si ARCHIVO o BIBLIOTECA
--     url,                                -- si ENLACE
--     aplicaA,                            -- APLICA_A (alcance en el grupo)
--     estudiantes: [pk_tmatricula, ...]   -- si aplicaA = ESTUDIANTES_SELECCIONADOS
-- }]
--
-- Requiere que los estudiantes ya esten asignados a la actividad
-- (TACTIVIDAD_ESTUDIANTE): por eso fn_actividad_crear/_actualizar llaman
-- PRIMERO a fn_actividad_estudiantes_asignar y despues a esta.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_adaptacion_reemplazar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    p_adaptaciones             JSONB
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_elem        JSONB;
    v_pk_adapt    BIGINT;
    v_formato_val VARCHAR;
    v_aplica_val  VARCHAR;
    v_usa         VARCHAR(1);
    v_insertadas  INT := 0;
BEGIN
    IF p_adaptaciones IS NULL THEN
        RETURN 0;                          -- NULL = no tocar la lista
    END IF;
    IF jsonb_typeof(p_adaptaciones) <> 'array' THEN
        RAISE EXCEPTION 'p_adaptaciones debe ser un arreglo JSON' USING ERRCODE = '22023';
    END IF;

    -- Soft delete de las actuales (el pivote de estudiantes cae con ellas).
    UPDATE academico_test.TACTIVIDAD_ADAPTACION_ESTUDIANTE ae
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TACTIVIDAD_ADAPTACION ad
     WHERE ae.FK_TACTIVIDAD_ADAPTACION = ad.PK_TACTIVIDAD_ADAPTACION
       AND ad.FK_TACTIVIDAD = p_pk_tactividad
       AND ae.ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_ADAPTACION
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;

    FOR v_elem IN SELECT * FROM jsonb_array_elements(p_adaptaciones) LOOP
        -- 1. Obligatorios.
        IF (v_elem->>'tipoAdaptacion') IS NULL
           OR NULLIF(TRIM(v_elem->>'descripcion'), '') IS NULL THEN
            RAISE EXCEPTION 'Cada adaptacion requiere tipoAdaptacion y descripcion'
                USING ERRCODE = '22023';
        END IF;
        IF LENGTH(TRIM(v_elem->>'descripcion')) > 500 THEN
            RAISE EXCEPTION 'La descripcion de la adaptacion no puede pasar de 500 caracteres'
                USING ERRCODE = '22023';
        END IF;

        v_usa := UPPER(TRIM(COALESCE(v_elem->>'usaVersionModificada', 'N')));
        IF v_usa NOT IN ('S','N') THEN
            RAISE EXCEPTION 'usaVersionModificada solo acepta ''S'' o ''N''' USING ERRCODE = '22023';
        END IF;

        -- 2. Catalogos.
        PERFORM academico_test.fn_actividad_lv_assert((v_elem->>'tipoAdaptacion')::BIGINT,    'TIPO_ADAPTACION',    'tipoAdaptacion');
        PERFORM academico_test.fn_actividad_lv_assert((v_elem->>'formatoAdaptacion')::BIGINT, 'FORMATO_ADAPTACION', 'formatoAdaptacion');
        PERFORM academico_test.fn_actividad_lv_assert((v_elem->>'aplicaA')::BIGINT,           'APLICA_A',           'aplicaA');

        SELECT VALOR INTO v_formato_val FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = (v_elem->>'formatoAdaptacion')::BIGINT;
        SELECT VALOR INTO v_aplica_val  FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = (v_elem->>'aplicaA')::BIGINT;

        -- 3. Version modificada: el formato manda que se exige.
        IF v_usa = 'S' THEN
            IF v_formato_val IS NULL THEN
                RAISE EXCEPTION 'Con usaVersionModificada = ''S'' se debe indicar formatoAdaptacion (ARCHIVO, ENLACE o BIBLIOTECA)'
                    USING ERRCODE = '22023';
            END IF;
            IF v_formato_val IN ('ARCHIVO','BIBLIOTECA') AND (v_elem->>'fkTarchivo') IS NULL THEN
                RAISE EXCEPTION 'formatoAdaptacion = % exige fkTarchivo', v_formato_val USING ERRCODE = '22023';
            END IF;
            IF v_formato_val = 'ENLACE' AND NULLIF(TRIM(v_elem->>'url'), '') IS NULL THEN
                RAISE EXCEPTION 'formatoAdaptacion = ENLACE exige url' USING ERRCODE = '22023';
            END IF;
        ELSIF (v_elem->>'formatoAdaptacion') IS NOT NULL THEN
            RAISE EXCEPTION 'formatoAdaptacion solo aplica cuando usaVersionModificada = ''S'''
                USING ERRCODE = '22023';
        END IF;

        IF (v_elem->>'fkTarchivo') IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM academico_test.TARCHIVO t
             WHERE t.PK_TARCHIVO = (v_elem->>'fkTarchivo')::BIGINT
        ) THEN
            RAISE EXCEPTION 'fkTarchivo (%) no existe en TARCHIVO', (v_elem->>'fkTarchivo') USING ERRCODE = '23503';
        END IF;

        -- 4. Alcance.
        IF v_aplica_val = 'ESTUDIANTES_SELECCIONADOS'
           AND (v_elem->'estudiantes' IS NULL
                OR jsonb_typeof(v_elem->'estudiantes') <> 'array'
                OR jsonb_array_length(v_elem->'estudiantes') = 0) THEN
            RAISE EXCEPTION 'aplicaA = ESTUDIANTES_SELECCIONADOS exige la lista "estudiantes" (matriculas) no vacia'
                USING ERRCODE = '22023';
        END IF;
        IF v_aplica_val IS DISTINCT FROM 'ESTUDIANTES_SELECCIONADOS'
           AND jsonb_typeof(v_elem->'estudiantes') = 'array'
           AND jsonb_array_length(v_elem->'estudiantes') > 0 THEN
            RAISE EXCEPTION 'Solo se puede enviar "estudiantes" cuando aplicaA = ESTUDIANTES_SELECCIONADOS'
                USING ERRCODE = '22023';
        END IF;

        -- 5. INSERT de la adaptacion.
        INSERT INTO academico_test.TACTIVIDAD_ADAPTACION (
            FK_TACTIVIDAD, FK_TLV_TIPO_ADAPTACION, DESCRIPCION, USA_VERSION_MODIFICADA,
            FK_TARCHIVO, URL, FK_TLV_FORMATO_ADAPTACION, FK_TLV_APLICA_A,
            CREATED_BY, CREATED_AT, ACTIVE
        ) VALUES (
            p_pk_tactividad,
            (v_elem->>'tipoAdaptacion')::BIGINT,
            TRIM(v_elem->>'descripcion'),
            v_usa,
            (v_elem->>'fkTarchivo')::BIGINT,
            NULLIF(TRIM(v_elem->>'url'), ''),
            (v_elem->>'formatoAdaptacion')::BIGINT,
            (v_elem->>'aplicaA')::BIGINT,
            p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
        )
        RETURNING PK_TACTIVIDAD_ADAPTACION INTO v_pk_adapt;

        -- 6. Estudiantes concretos del grupo a los que aplica.
        IF v_aplica_val = 'ESTUDIANTES_SELECCIONADOS' THEN
            IF EXISTS (
                SELECT 1 FROM jsonb_array_elements_text(v_elem->'estudiantes') mid
                 WHERE NOT EXISTS (
                     SELECT 1 FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
                      WHERE ae.FK_TACTIVIDAD = p_pk_tactividad
                        AND ae.FK_TMATRICULA = mid::BIGINT
                        AND ae.ACTIVE = TRUE
                 )
            ) THEN
                RAISE EXCEPTION 'Una o mas matriculas de la adaptacion no estan asignadas a esta actividad; asigne primero los estudiantes'
                    USING ERRCODE = '23503';
            END IF;

            INSERT INTO academico_test.TACTIVIDAD_ADAPTACION_ESTUDIANTE (
                FK_TACTIVIDAD_ADAPTACION, FK_TACTIVIDAD_ESTUDIANTE,
                CREATED_BY, CREATED_AT, ACTIVE
            )
            SELECT DISTINCT v_pk_adapt, ae.PK_TACTIVIDAD_ESTUDIANTE,
                   p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
              FROM jsonb_array_elements_text(v_elem->'estudiantes') mid
              JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
                ON ae.FK_TACTIVIDAD = p_pk_tactividad
               AND ae.FK_TMATRICULA = mid::BIGINT
               AND ae.ACTIVE = TRUE;
        END IF;

        v_insertadas := v_insertadas + 1;
    END LOOP;

    RETURN v_insertadas;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_adaptacion_reemplazar(BIGINT, BIGINT, JSONB)
    IS 'Reemplazo completo de las adaptaciones curriculares de una actividad (TACTIVIDAD_ADAPTACION + TACTIVIDAD_ADAPTACION_ESTUDIANTE). p_adaptaciones NULL = no tocar; array vacio = dejarla sin adaptaciones. Elemento {tipoAdaptacion, descripcion(<=500), usaVersionModificada(S/N), formatoAdaptacion?, fkTarchivo?, url?, aplicaA?, estudiantes?[]}. Reglas del figma: con usaVersionModificada=''S'' el formato es obligatorio y ARCHIVO/BIBLIOTECA exigen fkTarchivo mientras ENLACE exige url; con ''N'' no se admite formato. aplicaA=ESTUDIANTES_SELECCIONADOS exige la lista de matriculas, que deben estar YA asignadas a la actividad (por eso se llama despues de fn_actividad_estudiantes_asignar); con TODO_EL_GRUPO la lista debe venir vacia. Retorna cuantas adaptaciones quedaron. V224.';

-- ---------------------------------------------------------------------------
-- fn_actividad_estudiantes_asignar — pivote TACTIVIDAD_ESTUDIANTE.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_estudiantes_asignar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    -- NULL + p_todo_el_grupo=TRUE  -> todas las matriculas activas del grupo
    -- array                        -> reemplazo completo por ese set
    p_fk_tmatriculas           BIGINT[] DEFAULT NULL,
    p_todo_el_grupo            BOOLEAN  DEFAULT FALSE
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_fk_grupo   BIGINT;
    v_set        BIGINT[];
    v_asignados  INT := 0;
BEGIN
    IF p_fk_tmatriculas IS NULL AND NOT p_todo_el_grupo THEN
        RETURN 0;                          -- nada que hacer
    END IF;

    SELECT FK_TGRUPO INTO v_fk_grupo
      FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;

    IF p_fk_tmatriculas IS NULL THEN
        IF v_fk_grupo IS NULL THEN
            RAISE EXCEPTION 'La actividad no tiene grupo (FK_TGRUPO); no se puede asignar "todo el grupo"'
                USING ERRCODE = '22023';
        END IF;
        SELECT COALESCE(array_agg(m.PK_TMATRICULA), ARRAY[]::BIGINT[])
          INTO v_set
          FROM academico_test.TMATRICULA m
         WHERE m.FK_TGRUPO = v_fk_grupo AND m.ACTIVE = TRUE;
    ELSE
        v_set := p_fk_tmatriculas;
        IF array_length(v_set, 1) > 0 AND EXISTS (
            SELECT 1 FROM unnest(v_set) mid
             WHERE NOT EXISTS (
                 SELECT 1 FROM academico_test.TMATRICULA m
                  WHERE m.PK_TMATRICULA = mid
                    AND m.ACTIVE = TRUE
                    AND (v_fk_grupo IS NULL OR m.FK_TGRUPO = v_fk_grupo)
             )
        ) THEN
            RAISE EXCEPTION 'Una o mas matriculas no existen, no estan activas o no pertenecen al grupo de la actividad'
                USING ERRCODE = '23503';
        END IF;
    END IF;

    -- Desactiva las que ya no vienen.
    UPDATE academico_test.TACTIVIDAD_ESTUDIANTE
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad
       AND ACTIVE = TRUE
       AND NOT (FK_TMATRICULA = ANY(v_set));

    -- Reactiva las que ya existian desactivadas (respeta UN_TACTIVIDAD_ESTUDIANTE_1).
    UPDATE academico_test.TACTIVIDAD_ESTUDIANTE ae
       SET ACTIVE = TRUE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM unnest(v_set) mid
     WHERE ae.FK_TACTIVIDAD = p_pk_tactividad
       AND ae.FK_TMATRICULA = mid
       AND ae.ACTIVE = FALSE;

    -- Crea las nuevas.
    INSERT INTO academico_test.TACTIVIDAD_ESTUDIANTE (
        FK_TACTIVIDAD, FK_TMATRICULA, CREATED_BY, CREATED_AT, ACTIVE
    )
    SELECT DISTINCT p_pk_tactividad, mid, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
      FROM unnest(v_set) mid
     WHERE NOT EXISTS (
         SELECT 1 FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
          WHERE ae.FK_TACTIVIDAD = p_pk_tactividad AND ae.FK_TMATRICULA = mid
     );

    SELECT COUNT(*) INTO v_asignados
      FROM academico_test.TACTIVIDAD_ESTUDIANTE
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;

    RETURN v_asignados;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_estudiantes_asignar(BIGINT, BIGINT, BIGINT[], BOOLEAN)
    IS 'Reemplazo completo del pivote TACTIVIDAD_ESTUDIANTE de una actividad. p_fk_tmatriculas NULL + p_todo_el_grupo=TRUE asigna todas las matriculas ACTIVE del FK_TGRUPO de la actividad; un array la fija a ese set exacto (valida existencia/estado/grupo, 23503). Reactiva filas previamente desactivadas en vez de duplicar. Ambos NULL/FALSE = no toca nada. Retorna el total de asignados activos. V224.';

-- ===========================================================================
-- (4) ESCRITURA
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- fn_actividad_crear
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_crear(
    p_pk_usuario_solicitante            BIGINT,
    p_titulo                            VARCHAR(250),
    p_fk_tasignatura                    BIGINT,
    p_fk_tlv_tipo_actividad             BIGINT,
    p_fk_tlv_jerarquia                  BIGINT,
    p_descripcion                       VARCHAR(4000) DEFAULT NULL,
    p_fk_tgrupo                         BIGINT        DEFAULT NULL,
    p_fk_tunidad                        BIGINT        DEFAULT NULL,
    p_ponderacion                       NUMERIC       DEFAULT NULL,
    p_fecha_inicio                      DATE          DEFAULT NULL,
    p_fecha_cierre                      DATE          DEFAULT NULL,
    p_duracion_estimada                 NUMERIC       DEFAULT NULL,
    p_semana_cronograma                 VARCHAR(50)   DEFAULT NULL,
    p_fk_tlv_modalidad                  BIGINT        DEFAULT NULL,
    p_material_requerido                VARCHAR(4000) DEFAULT NULL,
    p_es_evaluativa                     VARCHAR(1)    DEFAULT 'S',
    p_fk_tlv_instrumento_evaluacion     BIGINT        DEFAULT NULL,
    p_descripcion_instrumento           VARCHAR(4000) DEFAULT NULL,
    p_fk_tlv_tipo_evidencia             BIGINT        DEFAULT NULL,
    p_fk_tlv_metodo_valoracion          BIGINT        DEFAULT NULL,
    p_fk_tlv_tipo_calculo               BIGINT        DEFAULT NULL,
    p_influencia                        NUMERIC       DEFAULT NULL,
    p_nota_maxima                       NUMERIC       DEFAULT NULL,
    p_requiere_archivo                  VARCHAR(1)    DEFAULT 'N',
    p_requiere_texto                    VARCHAR(1)    DEFAULT 'N',
    p_genera_evidencias                 VARCHAR(1)    DEFAULT 'N',
    p_requiere_validacion_coordinador   VARCHAR(1)    DEFAULT 'N',
    p_observaciones_docente             VARCHAR(4000) DEFAULT NULL,
    p_materiales                        JSONB         DEFAULT NULL,
    p_adaptaciones                      JSONB         DEFAULT NULL,
    p_fk_tmatriculas                    BIGINT[]      DEFAULT NULL,
    p_asignar_todo_el_grupo             BOOLEAN       DEFAULT FALSE
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_creado BIGINT;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'CREAR'
    );

    -- 1. Obligatorios.
    IF NULLIF(TRIM(p_titulo), '') IS NULL THEN
        RAISE EXCEPTION 'El nombre de la actividad es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_titulo no puede ser NULL ni vacio';
    END IF;
    IF p_fk_tasignatura IS NULL THEN
        RAISE EXCEPTION 'La asignatura (FK_TASIGNATURA) es obligatoria' USING ERRCODE = '22023';
    END IF;
    IF p_fk_tlv_tipo_actividad IS NULL THEN
        RAISE EXCEPTION 'El tipo de actividad (FK_TLV_TIPO_ACTIVIDAD) es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_tlv_jerarquia IS NULL THEN
        RAISE EXCEPTION 'La jerarquia (FK_TLV_JERARQUIA) es obligatoria' USING ERRCODE = '22023';
    END IF;

    -- 2. Coherencia de fechas y banderas S/N.
    IF p_fecha_inicio IS NOT NULL AND p_fecha_cierre IS NOT NULL
       AND p_fecha_cierre < p_fecha_inicio THEN
        RAISE EXCEPTION 'La fecha de cierre (%) no puede ser anterior a la de inicio (%)',
            p_fecha_cierre, p_fecha_inicio USING ERRCODE = '22023';
    END IF;
    IF UPPER(TRIM(COALESCE(p_es_evaluativa,'S'))) NOT IN ('S','N')
       OR UPPER(TRIM(COALESCE(p_requiere_archivo,'N'))) NOT IN ('S','N')
       OR UPPER(TRIM(COALESCE(p_requiere_texto,'N'))) NOT IN ('S','N')
       OR UPPER(TRIM(COALESCE(p_genera_evidencias,'N'))) NOT IN ('S','N')
       OR UPPER(TRIM(COALESCE(p_requiere_validacion_coordinador,'N'))) NOT IN ('S','N') THEN
        RAISE EXCEPTION 'Las banderas S/N solo aceptan ''S'' o ''N''' USING ERRCODE = '22023';
    END IF;

    -- 3. FKs propias.
    IF NOT EXISTS (SELECT 1 FROM academico_test.TASIGNATURA
                    WHERE PK_TASIGNATURA = p_fk_tasignatura AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'FK_TASIGNATURA (%) no existe o no esta activa', p_fk_tasignatura USING ERRCODE = '23503';
    END IF;
    IF p_fk_tgrupo IS NOT NULL AND NOT EXISTS (SELECT 1 FROM academico_test.TGRUPO
                    WHERE PK_TGRUPO = p_fk_tgrupo AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'FK_TGRUPO (%) no existe o no esta activo', p_fk_tgrupo USING ERRCODE = '23503';
    END IF;
    IF p_fk_tunidad IS NOT NULL AND NOT EXISTS (SELECT 1 FROM academico_test.TUNIDAD
                    WHERE PK_TUNIDAD = p_fk_tunidad AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'FK_TUNIDAD (%) no existe o no esta activa', p_fk_tunidad USING ERRCODE = '23503';
    END IF;
    IF p_ponderacion IS NOT NULL AND (p_ponderacion < 0 OR p_ponderacion > 100) THEN
        RAISE EXCEPTION 'La ponderacion (%) debe estar entre 0 y 100', p_ponderacion USING ERRCODE = '22023';
    END IF;
    IF p_ponderacion IS NOT NULL AND p_fk_tunidad IS NULL THEN
        RAISE EXCEPTION 'La ponderacion solo aplica cuando la actividad se vincula a una unidad'
            USING ERRCODE = '22023';
    END IF;

    -- 4. Catalogos (helper unico). Nombres de categoria verificados contra
    --    el servidor de test: la jerarquia es TIPO_JERARQUIA_ACTIVIDAD.
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_tipo_actividad,          'TIPO_ACTIVIDAD',           'FK_TLV_TIPO_ACTIVIDAD');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_jerarquia,               'TIPO_JERARQUIA_ACTIVIDAD', 'FK_TLV_JERARQUIA');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_modalidad,               'MODALIDAD',                'FK_TLV_MODALIDAD');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_instrumento_evaluacion,  'INSTRUMENTO_EVALUACION',   'FK_TLV_INSTRUMENTO_EVALUACION');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_tipo_evidencia,          'TIPO_EVIDENCIA',           'FK_TLV_TIPO_EVIDENCIA');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_metodo_valoracion,       'METODO_VALORACION',        'FK_TLV_METODO_VALORACION'); -- sin seed: solo valida existencia+ACTIVE
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_tipo_calculo,            'TIPO_CALCULO',             'FK_TLV_TIPO_CALCULO');

    -- 5. Unicidad (TITULO, unidad, grupo, jerarquia) entre activas —
    --    backstop de U_TACTIVIDAD_1 (V22), que con FK_TUNIDAD/FK_TGRUPO
    --    NULL no garantiza nada (NULL nunca colisiona en un UNIQUE).
    IF EXISTS (
        SELECT 1 FROM academico_test.TACTIVIDAD
         WHERE UPPER(TRIM(TITULO)) = UPPER(TRIM(p_titulo))
           AND FK_TUNIDAD       IS NOT DISTINCT FROM p_fk_tunidad
           AND FK_TGRUPO        IS NOT DISTINCT FROM p_fk_tgrupo
           AND FK_TLV_JERARQUIA = p_fk_tlv_jerarquia
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'Ya existe una actividad activa "%" para esa unidad, grupo y jerarquia', p_titulo
            USING ERRCODE = '23505';
    END IF;

    -- 6. INSERT. FK_TUNIDAD/PONDERACION van directo: la regla del 100% por
    --    (unidad, grupo) la impone el trigger tr_tactividad_ponderacion_unidad
    --    (V223) — no se re-implementa la suma aqui.
    INSERT INTO academico_test.TACTIVIDAD (
        TITULO, DESCRIPCION, FECHA_CREACION,
        FK_TASIGNATURA, FK_TGRUPO, FK_TUNIDAD, PONDERACION,
        FK_TLV_TIPO_ACTIVIDAD, FK_TLV_JERARQUIA, FK_TLV_TIPO_CALCULO,
        INFLUENCIA, NOTA_MAXIMA,
        FECHA_INICIO, FECHA_CIERRE, DURACION_ESTIMADA, SEMANA_CRONOGRAMA,
        FK_TLV_MODALIDAD, MATERIAL_REQUERIDO,
        ES_EVALUATIVA, FK_TLV_INSTRUMENTO_EVALUACION, DESCRIPCION_INSTRUMENTO,
        FK_TLV_TIPO_EVIDENCIA, FK_TLV_METODO_VALORACION,
        REQUIERE_ARCHIVO, REQUIERE_TEXTO,
        GENERA_EVIDENCIAS, REQUIERE_VALIDACION_COORDINADOR, OBSERVACIONES_DOCENTE,
        CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        TRIM(p_titulo), NULLIF(TRIM(p_descripcion), ''), CURRENT_DATE,
        p_fk_tasignatura, p_fk_tgrupo, p_fk_tunidad, p_ponderacion,
        p_fk_tlv_tipo_actividad, p_fk_tlv_jerarquia, p_fk_tlv_tipo_calculo,
        p_influencia, p_nota_maxima,
        p_fecha_inicio, p_fecha_cierre, p_duracion_estimada, NULLIF(TRIM(p_semana_cronograma), ''),
        p_fk_tlv_modalidad, NULLIF(TRIM(p_material_requerido), ''),
        UPPER(TRIM(COALESCE(p_es_evaluativa, 'S'))), p_fk_tlv_instrumento_evaluacion,
        NULLIF(TRIM(p_descripcion_instrumento), ''),
        p_fk_tlv_tipo_evidencia, p_fk_tlv_metodo_valoracion,
        UPPER(TRIM(COALESCE(p_requiere_archivo, 'N'))), UPPER(TRIM(COALESCE(p_requiere_texto, 'N'))),
        UPPER(TRIM(COALESCE(p_genera_evidencias, 'N'))),
        UPPER(TRIM(COALESCE(p_requiere_validacion_coordinador, 'N'))),
        NULLIF(TRIM(p_observaciones_docente), ''),
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TACTIVIDAD INTO v_id_creado;

    -- 7. Satelites (helpers reutilizables). ORDEN IMPORTA: los estudiantes
    --    van primero porque las adaptaciones con
    --    aplicaA = ESTUDIANTES_SELECCIONADOS apuntan a filas de
    --    TACTIVIDAD_ESTUDIANTE que deben existir ya.
    PERFORM academico_test.fn_actividad_estudiantes_asignar(
                p_pk_usuario_solicitante, v_id_creado, p_fk_tmatriculas, p_asignar_todo_el_grupo);
    PERFORM academico_test.fn_actividad_material_reemplazar(
                p_pk_usuario_solicitante, v_id_creado, p_materiales);
    PERFORM academico_test.fn_actividad_adaptacion_reemplazar(
                p_pk_usuario_solicitante, v_id_creado, p_adaptaciones);

    RETURN v_id_creado;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_crear(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, VARCHAR, BIGINT, BIGINT, NUMERIC, DATE, DATE, NUMERIC, VARCHAR, BIGINT, VARCHAR, VARCHAR, BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, NUMERIC, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, JSONB, JSONB, BIGINT[], BOOLEAN)
    IS 'Crea una actividad del Planeador (gate CREAR sobre PLANEADOR): inserta TACTIVIDAD (identificacion, programacion, evaluacion y seguimiento) y opcionalmente la vincula a una unidad con su PONDERACION (%) — la regla "la suma por (unidad, grupo) no pasa de 100" la impone el trigger de V223, no se re-implementa. Delega materiales de apoyo, adaptaciones curriculares y asignacion de estudiantes en fn_actividad_material_reemplazar / fn_actividad_adaptacion_reemplazar / fn_actividad_estudiantes_asignar. Valida catalogos con fn_actividad_lv_assert y unicidad (titulo, unidad, grupo, jerarquia) entre activas con IS NOT DISTINCT FROM (U_TACTIVIDAD_1 no cubre los NULL). Retorna PK_TACTIVIDAD. V224.';

-- ---------------------------------------------------------------------------
-- fn_actividad_actualizar — PATCH parcial.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_actualizar(
    p_pk_usuario_solicitante            BIGINT,
    p_pk_tactividad                     BIGINT,
    p_titulo                            VARCHAR(250)  DEFAULT NULL,
    p_descripcion                       VARCHAR(4000) DEFAULT NULL,
    p_fk_tasignatura                    BIGINT        DEFAULT NULL,
    p_fk_tgrupo                         BIGINT        DEFAULT NULL,
    p_fk_tunidad                        BIGINT        DEFAULT NULL,
    p_ponderacion                       NUMERIC       DEFAULT NULL,
    p_desvincular_unidad                BOOLEAN       DEFAULT FALSE,
    p_fk_tlv_tipo_actividad             BIGINT        DEFAULT NULL,
    p_fecha_inicio                      DATE          DEFAULT NULL,
    p_fecha_cierre                      DATE          DEFAULT NULL,
    p_duracion_estimada                 NUMERIC       DEFAULT NULL,
    p_semana_cronograma                 VARCHAR(50)   DEFAULT NULL,
    p_fk_tlv_modalidad                  BIGINT        DEFAULT NULL,
    p_material_requerido                VARCHAR(4000) DEFAULT NULL,
    p_es_evaluativa                     VARCHAR(1)    DEFAULT NULL,
    p_fk_tlv_instrumento_evaluacion     BIGINT        DEFAULT NULL,
    p_descripcion_instrumento           VARCHAR(4000) DEFAULT NULL,
    p_fk_tlv_tipo_evidencia             BIGINT        DEFAULT NULL,
    p_fk_tlv_metodo_valoracion          BIGINT        DEFAULT NULL,
    p_fk_tlv_tipo_calculo               BIGINT        DEFAULT NULL,
    p_influencia                        NUMERIC       DEFAULT NULL,
    p_nota_maxima                       NUMERIC       DEFAULT NULL,
    p_requiere_archivo                  VARCHAR(1)    DEFAULT NULL,
    p_requiere_texto                    VARCHAR(1)    DEFAULT NULL,
    p_genera_evidencias                 VARCHAR(1)    DEFAULT NULL,
    p_requiere_validacion_coordinador   VARCHAR(1)    DEFAULT NULL,
    p_observaciones_docente             VARCHAR(4000) DEFAULT NULL,
    -- NULL = no tocar; array (incl. vacio) = reemplazo completo
    p_materiales                        JSONB         DEFAULT NULL,
    p_adaptaciones                      JSONB         DEFAULT NULL,
    p_fk_tmatriculas                    BIGINT[]      DEFAULT NULL,
    p_asignar_todo_el_grupo             BOOLEAN       DEFAULT FALSE
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_actual    academico_test.TACTIVIDAD%ROWTYPE;
    v_titulo    VARCHAR(250);
    v_grupo     BIGINT;
    v_inicio    DATE;
    v_cierre    DATE;
BEGIN
    SELECT * INTO v_actual
      FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );

    IF v_actual.ACTIVE = FALSE THEN
        RAISE EXCEPTION 'La actividad "%" esta inactiva (borrado logico); no se puede editar', v_actual.TITULO
            USING ERRCODE = '22023';
    END IF;
    IF p_titulo IS NOT NULL AND NULLIF(TRIM(p_titulo), '') IS NULL THEN
        RAISE EXCEPTION 'El nombre de la actividad no puede quedar vacio' USING ERRCODE = '22023';
    END IF;
    IF p_desvincular_unidad AND (p_fk_tunidad IS NOT NULL OR p_ponderacion IS NOT NULL) THEN
        RAISE EXCEPTION 'p_desvincular_unidad es excluyente con p_fk_tunidad / p_ponderacion'
            USING ERRCODE = '22023';
    END IF;

    -- Valores resultantes para coherencia/unicidad.
    v_titulo := COALESCE(NULLIF(TRIM(p_titulo), ''), v_actual.TITULO);
    v_grupo  := COALESCE(p_fk_tgrupo, v_actual.FK_TGRUPO);
    v_inicio := COALESCE(p_fecha_inicio, v_actual.FECHA_INICIO);
    v_cierre := COALESCE(p_fecha_cierre, v_actual.FECHA_CIERRE);

    IF v_inicio IS NOT NULL AND v_cierre IS NOT NULL AND v_cierre < v_inicio THEN
        RAISE EXCEPTION 'La fecha de cierre (%) no puede ser anterior a la de inicio (%)',
            v_cierre, v_inicio USING ERRCODE = '22023';
    END IF;

    IF p_fk_tasignatura IS NOT NULL AND NOT EXISTS (SELECT 1 FROM academico_test.TASIGNATURA
                    WHERE PK_TASIGNATURA = p_fk_tasignatura AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'FK_TASIGNATURA (%) no existe o no esta activa', p_fk_tasignatura USING ERRCODE = '23503';
    END IF;
    IF p_fk_tgrupo IS NOT NULL AND NOT EXISTS (SELECT 1 FROM academico_test.TGRUPO
                    WHERE PK_TGRUPO = p_fk_tgrupo AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'FK_TGRUPO (%) no existe o no esta activo', p_fk_tgrupo USING ERRCODE = '23503';
    END IF;

    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_tipo_actividad,          'TIPO_ACTIVIDAD',         'FK_TLV_TIPO_ACTIVIDAD');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_modalidad,               'MODALIDAD',              'FK_TLV_MODALIDAD');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_instrumento_evaluacion,  'INSTRUMENTO_EVALUACION', 'FK_TLV_INSTRUMENTO_EVALUACION');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_tipo_evidencia,          'TIPO_EVIDENCIA',         'FK_TLV_TIPO_EVIDENCIA');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_metodo_valoracion,       'METODO_VALORACION',      'FK_TLV_METODO_VALORACION'); -- sin seed: solo valida existencia+ACTIVE
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_tipo_calculo,            'TIPO_CALCULO',           'FK_TLV_TIPO_CALCULO');

    IF EXISTS (
        SELECT 1 FROM academico_test.TACTIVIDAD
         WHERE UPPER(TRIM(TITULO)) = UPPER(TRIM(v_titulo))
           AND FK_TUNIDAD       IS NOT DISTINCT FROM v_actual.FK_TUNIDAD
           AND FK_TGRUPO        IS NOT DISTINCT FROM v_grupo
           AND FK_TLV_JERARQUIA = v_actual.FK_TLV_JERARQUIA
           AND ACTIVE = TRUE
           AND PK_TACTIVIDAD <> p_pk_tactividad
    ) THEN
        RAISE EXCEPTION 'Ya existe otra actividad activa "%" para esa unidad, grupo y jerarquia', v_titulo
            USING ERRCODE = '23505';
    END IF;

    UPDATE academico_test.TACTIVIDAD
       SET TITULO                          = v_titulo,
           DESCRIPCION                     = CASE WHEN p_descripcion IS NULL THEN DESCRIPCION
                                                  ELSE NULLIF(TRIM(p_descripcion), '') END,
           FK_TASIGNATURA                  = COALESCE(p_fk_tasignatura, FK_TASIGNATURA),
           FK_TGRUPO                       = v_grupo,
           FK_TLV_TIPO_ACTIVIDAD           = COALESCE(p_fk_tlv_tipo_actividad, FK_TLV_TIPO_ACTIVIDAD),
           FECHA_INICIO                    = v_inicio,
           FECHA_CIERRE                    = v_cierre,
           DURACION_ESTIMADA               = COALESCE(p_duracion_estimada, DURACION_ESTIMADA),
           SEMANA_CRONOGRAMA               = COALESCE(NULLIF(TRIM(p_semana_cronograma), ''), SEMANA_CRONOGRAMA),
           FK_TLV_MODALIDAD                = COALESCE(p_fk_tlv_modalidad, FK_TLV_MODALIDAD),
           MATERIAL_REQUERIDO              = CASE WHEN p_material_requerido IS NULL THEN MATERIAL_REQUERIDO
                                                  ELSE NULLIF(TRIM(p_material_requerido), '') END,
           ES_EVALUATIVA                   = COALESCE(UPPER(TRIM(p_es_evaluativa)), ES_EVALUATIVA),
           FK_TLV_INSTRUMENTO_EVALUACION   = COALESCE(p_fk_tlv_instrumento_evaluacion, FK_TLV_INSTRUMENTO_EVALUACION),
           DESCRIPCION_INSTRUMENTO         = CASE WHEN p_descripcion_instrumento IS NULL THEN DESCRIPCION_INSTRUMENTO
                                                  ELSE NULLIF(TRIM(p_descripcion_instrumento), '') END,
           FK_TLV_TIPO_EVIDENCIA           = COALESCE(p_fk_tlv_tipo_evidencia, FK_TLV_TIPO_EVIDENCIA),
           FK_TLV_METODO_VALORACION        = COALESCE(p_fk_tlv_metodo_valoracion, FK_TLV_METODO_VALORACION),
           FK_TLV_TIPO_CALCULO             = COALESCE(p_fk_tlv_tipo_calculo, FK_TLV_TIPO_CALCULO),
           INFLUENCIA                      = COALESCE(p_influencia, INFLUENCIA),
           NOTA_MAXIMA                     = COALESCE(p_nota_maxima, NOTA_MAXIMA),
           REQUIERE_ARCHIVO                = COALESCE(UPPER(TRIM(p_requiere_archivo)), REQUIERE_ARCHIVO),
           REQUIERE_TEXTO                  = COALESCE(UPPER(TRIM(p_requiere_texto)), REQUIERE_TEXTO),
           GENERA_EVIDENCIAS               = COALESCE(UPPER(TRIM(p_genera_evidencias)), GENERA_EVIDENCIAS),
           REQUIERE_VALIDACION_COORDINADOR = COALESCE(UPPER(TRIM(p_requiere_validacion_coordinador)), REQUIERE_VALIDACION_COORDINADOR),
           OBSERVACIONES_DOCENTE           = CASE WHEN p_observaciones_docente IS NULL THEN OBSERVACIONES_DOCENTE
                                                  ELSE NULLIF(TRIM(p_observaciones_docente), '') END,
           MODIFIED_BY                     = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT                     = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD = p_pk_tactividad;

    -- Unidad / ponderacion: se delega en las funciones de V223 (mismo gate
    -- EDITAR) para no duplicar la regla del 100%.
    IF p_desvincular_unidad THEN
        PERFORM academico_test.fn_unidad_actividad_desvincular(p_pk_usuario_solicitante, p_pk_tactividad);
    ELSIF p_fk_tunidad IS NOT NULL THEN
        PERFORM academico_test.fn_unidad_actividad_vincular(
                    p_pk_usuario_solicitante, p_pk_tactividad, p_fk_tunidad, p_ponderacion);
    ELSIF p_ponderacion IS NOT NULL THEN
        PERFORM academico_test.fn_unidad_actividad_ponderacion_set(
                    p_pk_usuario_solicitante, p_pk_tactividad, p_ponderacion);
    END IF;

    -- ORDEN IMPORTA: estudiantes antes que adaptaciones (ver fn_actividad_crear).
    PERFORM academico_test.fn_actividad_estudiantes_asignar(
                p_pk_usuario_solicitante, p_pk_tactividad, p_fk_tmatriculas, p_asignar_todo_el_grupo);
    PERFORM academico_test.fn_actividad_material_reemplazar(
                p_pk_usuario_solicitante, p_pk_tactividad, p_materiales);
    PERFORM academico_test.fn_actividad_adaptacion_reemplazar(
                p_pk_usuario_solicitante, p_pk_tactividad, p_adaptaciones);

    RETURN p_pk_tactividad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, BOOLEAN, BIGINT, DATE, DATE, NUMERIC, VARCHAR, BIGINT, VARCHAR, VARCHAR, BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, NUMERIC, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, JSONB, JSONB, BIGINT[], BOOLEAN)
    IS 'PATCH parcial de una actividad (gate EDITAR sobre PLANEADOR): cada parametro NULL preserva el valor actual. Unidad/ponderacion se delegan en fn_unidad_actividad_vincular / _ponderacion_set / _desvincular (V223) para que la regla del 100% viva en un solo sitio; p_desvincular_unidad=TRUE es excluyente con p_fk_tunidad/p_ponderacion. p_materiales / p_adaptaciones / p_fk_tmatriculas NULL = no tocar, array = reemplazo completo. Revalida fechas, catalogos y unicidad (titulo, unidad, grupo, jerarquia). Retorna PK_TACTIVIDAD. V224.';

-- ===========================================================================
-- (5) LECTURA OPTIMIZADA
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- fn_actividad_listar
--
-- Optimizacion: el CTE "base" resuelve filtro + orden + LIMIT/OFFSET
-- tocando SOLO TACTIVIDAD (los predicados caen en los indices parciales de
-- arriba) y calcula total_count con COUNT(*) OVER(). Los joins de catalogo
-- y el LATERAL de progreso se aplican DESPUES, contra las <= p_limite filas
-- de la pagina — no contra todo el universo (leccion de V112: evitar
-- SubPlan con loops = N filas del universo).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_listar(
    p_pk_usuario_solicitante   BIGINT,
    p_search                   VARCHAR   DEFAULT NULL,
    p_fk_tasignatura           BIGINT    DEFAULT NULL,
    p_fk_tgrupo                BIGINT    DEFAULT NULL,
    p_fk_tunidad               BIGINT    DEFAULT NULL,
    p_fk_tlv_tipo_actividad    BIGINT    DEFAULT NULL,
    p_fk_tlv_instrumento       BIGINT    DEFAULT NULL,
    p_fecha_desde              DATE      DEFAULT NULL,
    p_fecha_hasta              DATE      DEFAULT NULL,
    -- Filtro por estado derivado: array de FINALIZADA / VENCIDA /
    -- PENDIENTE_POR_EVALUAR / PROGRAMADA / EN_EVALUACION / SIN_PROGRAMAR.
    p_estados                  VARCHAR[] DEFAULT NULL,
    p_dias_gracia              INT       DEFAULT 2,
    p_incluir_inactivas        BOOLEAN   DEFAULT FALSE,
    p_orden_por                VARCHAR   DEFAULT 'fecha_inicio',
    p_orden_asc                BOOLEAN   DEFAULT TRUE,
    p_limite                   INT       DEFAULT 20,
    p_offset                   INT       DEFAULT 0
)
RETURNS TABLE (
    pk_tactividad                   BIGINT,
    titulo                          VARCHAR,
    descripcion                     VARCHAR,
    fk_tasignatura                  BIGINT,
    asignatura                      VARCHAR,
    fk_tarea                        BIGINT,
    area                            VARCHAR,
    fk_tunidad                      BIGINT,
    unidad                          VARCHAR,
    fk_tgrupo                       BIGINT,
    grupo                           VARCHAR,
    fk_tlv_tipo_actividad           BIGINT,
    tipo_actividad                  VARCHAR,
    fk_tlv_instrumento_evaluacion   BIGINT,
    instrumento_evaluacion          VARCHAR,
    ponderacion                     NUMERIC,
    influencia                      NUMERIC,
    es_evaluativa                   VARCHAR,
    fecha_inicio                    DATE,
    fecha_cierre                    DATE,
    fecha_calificado                DATE,
    estado                          VARCHAR,
    estudiantes_asignados           BIGINT,
    estudiantes_evaluados           BIGINT,
    porcentaje_evaluado             NUMERIC,
    active                          BOOLEAN,
    total_count                     BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_hoy  DATE := CURRENT_DATE;
    v_key  VARCHAR;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    -- Whitelist del criterio de orden (evita ramas muertas en el ORDER BY).
    v_key := LOWER(TRIM(COALESCE(p_orden_por, 'fecha_inicio')));
    IF v_key NOT IN ('fecha_inicio','fecha_cierre','fecha_creacion','titulo','ponderacion') THEN
        v_key := 'fecha_inicio';
    END IF;

    RETURN QUERY
    WITH base AS (
        SELECT a.PK_TACTIVIDAD AS pk,
               COUNT(*) OVER() AS total
          FROM academico_test.TACTIVIDAD a
         WHERE (p_incluir_inactivas OR a.ACTIVE = TRUE)
           AND (p_fk_tasignatura        IS NULL OR a.FK_TASIGNATURA = p_fk_tasignatura)
           AND (p_fk_tgrupo             IS NULL OR a.FK_TGRUPO = p_fk_tgrupo)
           AND (p_fk_tunidad            IS NULL OR a.FK_TUNIDAD = p_fk_tunidad)
           AND (p_fk_tlv_tipo_actividad IS NULL OR a.FK_TLV_TIPO_ACTIVIDAD = p_fk_tlv_tipo_actividad)
           AND (p_fk_tlv_instrumento    IS NULL OR a.FK_TLV_INSTRUMENTO_EVALUACION = p_fk_tlv_instrumento)
           -- Ventana de fechas: solapamiento con [desde, hasta].
           AND (p_fecha_desde IS NULL OR COALESCE(a.FECHA_CIERRE, a.FECHA_INICIO) >= p_fecha_desde)
           AND (p_fecha_hasta IS NULL OR COALESCE(a.FECHA_INICIO, a.FECHA_CIERRE) <= p_fecha_hasta)
           -- Texto libre: la expresion debe ser IDENTICA a la de
           -- idx_tactividad_busqueda_trgm para que el planner la use.
           AND (p_search IS NULL OR
                (COALESCE(a.TITULO,'') || ' ' || COALESCE(a.DESCRIPCION,''))
                    ILIKE '%' || p_search || '%')
           AND (p_estados IS NULL OR academico_test.fn_actividad_estado(
                    a.FECHA_INICIO, a.FECHA_CIERRE, a.FECHA_CALIFICADO, v_hoy, p_dias_gracia
                ) = ANY(p_estados))
         ORDER BY
           CASE WHEN     p_orden_asc AND v_key = 'fecha_inicio'   THEN a.FECHA_INICIO   END ASC  NULLS LAST,
           CASE WHEN NOT p_orden_asc AND v_key = 'fecha_inicio'   THEN a.FECHA_INICIO   END DESC NULLS LAST,
           CASE WHEN     p_orden_asc AND v_key = 'fecha_cierre'   THEN a.FECHA_CIERRE   END ASC  NULLS LAST,
           CASE WHEN NOT p_orden_asc AND v_key = 'fecha_cierre'   THEN a.FECHA_CIERRE   END DESC NULLS LAST,
           CASE WHEN     p_orden_asc AND v_key = 'fecha_creacion' THEN a.FECHA_CREACION END ASC  NULLS LAST,
           CASE WHEN NOT p_orden_asc AND v_key = 'fecha_creacion' THEN a.FECHA_CREACION END DESC NULLS LAST,
           CASE WHEN     p_orden_asc AND v_key = 'titulo'         THEN a.TITULO         END ASC  NULLS LAST,
           CASE WHEN NOT p_orden_asc AND v_key = 'titulo'         THEN a.TITULO         END DESC NULLS LAST,
           CASE WHEN     p_orden_asc AND v_key = 'ponderacion'    THEN a.PONDERACION    END ASC  NULLS LAST,
           CASE WHEN NOT p_orden_asc AND v_key = 'ponderacion'    THEN a.PONDERACION    END DESC NULLS LAST,
           a.PK_TACTIVIDAD
         LIMIT GREATEST(p_limite, 1)
        OFFSET GREATEST(p_offset, 0)
    )
    SELECT a.PK_TACTIVIDAD,
           a.TITULO,
           a.DESCRIPCION,
           a.FK_TASIGNATURA,
           asig.NOMBRE,
           asig.FK_TAREA,
           ar.NOMBRE,
           a.FK_TUNIDAD,
           u.NOMBRE,
           a.FK_TGRUPO,
           g.NOMBRE,
           a.FK_TLV_TIPO_ACTIVIDAD,
           lvt.NOMBRE,
           a.FK_TLV_INSTRUMENTO_EVALUACION,
           lvi.NOMBRE,
           a.PONDERACION,
           a.INFLUENCIA,
           a.ES_EVALUATIVA::VARCHAR,
           a.FECHA_INICIO,
           a.FECHA_CIERRE,
           a.FECHA_CALIFICADO,
           academico_test.fn_actividad_estado(a.FECHA_INICIO, a.FECHA_CIERRE, a.FECHA_CALIFICADO, v_hoy, p_dias_gracia),
           prog.asignados,
           prog.evaluados,
           CASE WHEN prog.asignados > 0
                THEN ROUND(prog.evaluados * 100.0 / prog.asignados, 2)
                ELSE 0 END,
           a.ACTIVE,
           b.total
      FROM base b
      JOIN academico_test.TACTIVIDAD a           ON a.PK_TACTIVIDAD = b.pk
      JOIN academico_test.TASIGNATURA asig       ON asig.PK_TASIGNATURA = a.FK_TASIGNATURA
      LEFT JOIN academico_test.TAREA ar          ON ar.PK_TAREA = asig.FK_TAREA
      LEFT JOIN academico_test.TUNIDAD u         ON u.PK_TUNIDAD = a.FK_TUNIDAD
      LEFT JOIN academico_test.TGRUPO g          ON g.PK_TGRUPO = a.FK_TGRUPO
      LEFT JOIN academico_test.TLISTA_VALOR lvt  ON lvt.PK_LISTA_VALOR = a.FK_TLV_TIPO_ACTIVIDAD
      LEFT JOIN academico_test.TLISTA_VALOR lvi  ON lvi.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
      -- Un solo LATERAL: asignados y evaluados en la misma pasada.
      LEFT JOIN LATERAL (
          SELECT COUNT(*)::BIGINT AS asignados,
                 COUNT(*) FILTER (
                     WHERE COALESCE(n.DEFINITIVA, n.CALIFICACION) IS NOT NULL
                 )::BIGINT AS evaluados
            FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
            LEFT JOIN academico_test.TACTIVIDAD_NOTA n
                   ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                  AND n.ACTIVE = TRUE
           WHERE ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
             AND ae.ACTIVE = TRUE
      ) prog ON TRUE
     ORDER BY
       CASE WHEN     p_orden_asc AND v_key = 'fecha_inicio'   THEN a.FECHA_INICIO   END ASC  NULLS LAST,
       CASE WHEN NOT p_orden_asc AND v_key = 'fecha_inicio'   THEN a.FECHA_INICIO   END DESC NULLS LAST,
       CASE WHEN     p_orden_asc AND v_key = 'fecha_cierre'   THEN a.FECHA_CIERRE   END ASC  NULLS LAST,
       CASE WHEN NOT p_orden_asc AND v_key = 'fecha_cierre'   THEN a.FECHA_CIERRE   END DESC NULLS LAST,
       CASE WHEN     p_orden_asc AND v_key = 'fecha_creacion' THEN a.FECHA_CREACION END ASC  NULLS LAST,
       CASE WHEN NOT p_orden_asc AND v_key = 'fecha_creacion' THEN a.FECHA_CREACION END DESC NULLS LAST,
       CASE WHEN     p_orden_asc AND v_key = 'titulo'         THEN a.TITULO         END ASC  NULLS LAST,
       CASE WHEN NOT p_orden_asc AND v_key = 'titulo'         THEN a.TITULO         END DESC NULLS LAST,
       CASE WHEN     p_orden_asc AND v_key = 'ponderacion'    THEN a.PONDERACION    END ASC  NULLS LAST,
       CASE WHEN NOT p_orden_asc AND v_key = 'ponderacion'    THEN a.PONDERACION    END DESC NULLS LAST,
       a.PK_TACTIVIDAD;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_listar(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR[], INT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT)
    IS 'Pagina de actividades del Planeador (gate VER). Filtros indexados: asignatura, grupo, unidad, tipo, instrumento, ventana de fechas y texto libre (la expresion ILIKE es identica a la de idx_tactividad_busqueda_trgm para que el GIN trigram se use). p_estados filtra por el estado DERIVADO (fn_actividad_estado) con p_dias_gracia (default 2). Orden (whitelist): fecha_inicio|fecha_cierre|fecha_creacion|titulo|ponderacion, cualquier otro valor cae a fecha_inicio. Devuelve nombres resueltos (asignatura, area, unidad, grupo, tipo, instrumento), el estado derivado y el progreso de evaluacion (asignados/evaluados/%). Optimizacion: el CTE base pagina tocando solo TACTIVIDAD y los joins + el LATERAL de progreso corren unicamente contra las filas de la pagina. total_count via COUNT(*) OVER(). V224.';

-- ---------------------------------------------------------------------------
-- fn_actividad_buscar_por_pk — detalle completo (una fila).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_buscar_por_pk(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    p_dias_gracia              INT DEFAULT 2
)
RETURNS TABLE (
    pk_tactividad                   BIGINT,
    titulo                          VARCHAR,
    descripcion                     VARCHAR,
    fk_tasignatura                  BIGINT,
    asignatura                      VARCHAR,
    fk_tunidad                      BIGINT,
    unidad                          VARCHAR,
    fk_tgrupo                       BIGINT,
    grupo                           VARCHAR,
    fk_tlv_tipo_actividad           BIGINT,
    tipo_actividad                  VARCHAR,
    fk_tlv_jerarquia                BIGINT,
    jerarquia                       VARCHAR,
    fk_tlv_modalidad                BIGINT,
    modalidad                       VARCHAR,
    fk_tlv_instrumento_evaluacion   BIGINT,
    instrumento_evaluacion          VARCHAR,
    descripcion_instrumento         VARCHAR,
    fk_tlv_tipo_evidencia           BIGINT,
    tipo_evidencia                  VARCHAR,
    fk_tlv_metodo_valoracion        BIGINT,
    metodo_valoracion               VARCHAR,
    fk_tlv_tipo_calculo             BIGINT,
    tipo_calculo                    VARCHAR,
    ponderacion                     NUMERIC,
    influencia                      NUMERIC,
    nota_maxima                     NUMERIC,
    fecha_inicio                    DATE,
    fecha_cierre                    DATE,
    fecha_calificado                DATE,
    fecha_publicacion               DATE,
    duracion_estimada               NUMERIC,
    semana_cronograma               VARCHAR,
    material_requerido              VARCHAR,
    es_evaluativa                   VARCHAR,
    es_recuperacion                 VARCHAR,
    requiere_archivo                VARCHAR,
    requiere_texto                  VARCHAR,
    genera_evidencias               VARCHAR,
    requiere_validacion_coordinador VARCHAR,
    observaciones_docente           VARCHAR,
    estado                          VARCHAR,
    estudiantes_asignados           BIGINT,
    estudiantes_evaluados           BIGINT,
    materiales                      JSONB,
    adaptaciones                    JSONB,
    active                          BOOLEAN
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_hoy DATE := CURRENT_DATE;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    RETURN QUERY
    SELECT a.PK_TACTIVIDAD, a.TITULO, a.DESCRIPCION,
           a.FK_TASIGNATURA, asig.NOMBRE,
           a.FK_TUNIDAD, u.NOMBRE,
           a.FK_TGRUPO, g.NOMBRE,
           a.FK_TLV_TIPO_ACTIVIDAD, lvt.NOMBRE,
           a.FK_TLV_JERARQUIA, lvj.NOMBRE,
           a.FK_TLV_MODALIDAD, lvm.NOMBRE,
           a.FK_TLV_INSTRUMENTO_EVALUACION, lvi.NOMBRE, a.DESCRIPCION_INSTRUMENTO,
           a.FK_TLV_TIPO_EVIDENCIA, lve.NOMBRE,
           a.FK_TLV_METODO_VALORACION, lvv.NOMBRE,
           a.FK_TLV_TIPO_CALCULO, lvc.NOMBRE,
           a.PONDERACION, a.INFLUENCIA, a.NOTA_MAXIMA,
           a.FECHA_INICIO, a.FECHA_CIERRE, a.FECHA_CALIFICADO, a.FECHA_PUBLICACION,
           a.DURACION_ESTIMADA, a.SEMANA_CRONOGRAMA, a.MATERIAL_REQUERIDO,
           a.ES_EVALUATIVA::VARCHAR, a.ES_RECUPERACION::VARCHAR,
           a.REQUIERE_ARCHIVO::VARCHAR, a.REQUIERE_TEXTO::VARCHAR,
           a.GENERA_EVIDENCIAS::VARCHAR, a.REQUIERE_VALIDACION_COORDINADOR::VARCHAR,
           a.OBSERVACIONES_DOCENTE,
           academico_test.fn_actividad_estado(a.FECHA_INICIO, a.FECHA_CIERRE, a.FECHA_CALIFICADO, v_hoy, p_dias_gracia),
           prog.asignados, prog.evaluados,
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'pk',           m.PK_TACTIVIDAD_MATERIAL,
                          'orden',        m.ORDEN,
                          'tipoRecurso',  m.FK_TLV_TIPO_RECURSO,
                          'url',          m.URL,
                          'fkTarchivo',   m.FK_TARCHIVO,
                          'descripcion',  m.DESCRIPCION)
                          ORDER BY m.ORDEN)
                 FROM academico_test.TACTIVIDAD_MATERIAL m
                WHERE m.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND m.ACTIVE = TRUE
           ), '[]'::jsonb),
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'pk',                        ad.PK_TACTIVIDAD_ADAPTACION,
                          'tipoAdaptacion',            ad.FK_TLV_TIPO_ADAPTACION,
                          'tipoAdaptacionNombre',      lta.NOMBRE,
                          'descripcion',               ad.DESCRIPCION,
                          'usaVersionModificada',      ad.USA_VERSION_MODIFICADA,
                          'formatoAdaptacion',         ad.FK_TLV_FORMATO_ADAPTACION,
                          'formatoAdaptacionNombre',   lfa.NOMBRE,
                          'fkTarchivo',                ad.FK_TARCHIVO,
                          'url',                       ad.URL,
                          'aplicaA',                   ad.FK_TLV_APLICA_A,
                          'aplicaANombre',             lap.NOMBRE,
                          -- Matriculas concretas del grupo a las que aplica
                          -- (vacio cuando aplicaA = TODO_EL_GRUPO).
                          'estudiantes', COALESCE((
                              SELECT jsonb_agg(ae2.FK_TMATRICULA ORDER BY ae2.FK_TMATRICULA)
                                FROM academico_test.TACTIVIDAD_ADAPTACION_ESTUDIANTE ade
                                JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae2
                                  ON ae2.PK_TACTIVIDAD_ESTUDIANTE = ade.FK_TACTIVIDAD_ESTUDIANTE
                               WHERE ade.FK_TACTIVIDAD_ADAPTACION = ad.PK_TACTIVIDAD_ADAPTACION
                                 AND ade.ACTIVE = TRUE
                          ), '[]'::jsonb))
                          ORDER BY ad.PK_TACTIVIDAD_ADAPTACION)
                 FROM academico_test.TACTIVIDAD_ADAPTACION ad
                 LEFT JOIN academico_test.TLISTA_VALOR lta ON lta.PK_LISTA_VALOR = ad.FK_TLV_TIPO_ADAPTACION
                 LEFT JOIN academico_test.TLISTA_VALOR lfa ON lfa.PK_LISTA_VALOR = ad.FK_TLV_FORMATO_ADAPTACION
                 LEFT JOIN academico_test.TLISTA_VALOR lap ON lap.PK_LISTA_VALOR = ad.FK_TLV_APLICA_A
                WHERE ad.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND ad.ACTIVE = TRUE
           ), '[]'::jsonb),
           a.ACTIVE
      FROM academico_test.TACTIVIDAD a
      JOIN academico_test.TASIGNATURA asig      ON asig.PK_TASIGNATURA = a.FK_TASIGNATURA
      LEFT JOIN academico_test.TUNIDAD u        ON u.PK_TUNIDAD = a.FK_TUNIDAD
      LEFT JOIN academico_test.TGRUPO g         ON g.PK_TGRUPO = a.FK_TGRUPO
      LEFT JOIN academico_test.TLISTA_VALOR lvt ON lvt.PK_LISTA_VALOR = a.FK_TLV_TIPO_ACTIVIDAD
      LEFT JOIN academico_test.TLISTA_VALOR lvj ON lvj.PK_LISTA_VALOR = a.FK_TLV_JERARQUIA
      LEFT JOIN academico_test.TLISTA_VALOR lvm ON lvm.PK_LISTA_VALOR = a.FK_TLV_MODALIDAD
      LEFT JOIN academico_test.TLISTA_VALOR lvi ON lvi.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
      LEFT JOIN academico_test.TLISTA_VALOR lve ON lve.PK_LISTA_VALOR = a.FK_TLV_TIPO_EVIDENCIA
      LEFT JOIN academico_test.TLISTA_VALOR lvv ON lvv.PK_LISTA_VALOR = a.FK_TLV_METODO_VALORACION
      LEFT JOIN academico_test.TLISTA_VALOR lvc ON lvc.PK_LISTA_VALOR = a.FK_TLV_TIPO_CALCULO
      LEFT JOIN LATERAL (
          SELECT COUNT(*)::BIGINT AS asignados,
                 COUNT(*) FILTER (WHERE COALESCE(n.DEFINITIVA, n.CALIFICACION) IS NOT NULL)::BIGINT AS evaluados
            FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
            LEFT JOIN academico_test.TACTIVIDAD_NOTA n
                   ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE AND n.ACTIVE = TRUE
           WHERE ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND ae.ACTIVE = TRUE
      ) prog ON TRUE
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_buscar_por_pk(BIGINT, BIGINT, INT)
    IS 'Detalle completo de una actividad (gate VER): todos los campos de TACTIVIDAD con los nombres de catalogo resueltos, el estado derivado (fn_actividad_estado), el progreso de evaluacion (asignados/evaluados en un solo LATERAL), los materiales de apoyo y las adaptaciones curriculares como JSONB. SETOF 0 o 1 fila (incluye inactivas). V224.';

-- ---------------------------------------------------------------------------
-- fn_actividad_resumen_estados — las tarjetas del Planeador en UNA pasada.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_resumen_estados(
    p_pk_usuario_solicitante   BIGINT,
    p_fk_tasignatura           BIGINT DEFAULT NULL,
    p_fk_tgrupo                BIGINT DEFAULT NULL,
    p_fk_tunidad               BIGINT DEFAULT NULL,
    p_fecha_desde              DATE   DEFAULT NULL,
    p_fecha_hasta              DATE   DEFAULT NULL,
    p_dias_gracia              INT    DEFAULT 2
)
RETURNS TABLE (
    pendientes_por_evaluar  BIGINT,
    en_evaluacion           BIGINT,
    finalizadas             BIGINT,
    vencidas                BIGINT,
    programadas             BIGINT,
    sin_programar           BIGINT,
    total                   BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_hoy DATE := CURRENT_DATE;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    RETURN QUERY
    WITH est AS (
        SELECT academico_test.fn_actividad_estado(
                   a.FECHA_INICIO, a.FECHA_CIERRE, a.FECHA_CALIFICADO, v_hoy, p_dias_gracia
               ) AS estado
          FROM academico_test.TACTIVIDAD a
         WHERE a.ACTIVE = TRUE
           AND (p_fk_tasignatura IS NULL OR a.FK_TASIGNATURA = p_fk_tasignatura)
           AND (p_fk_tgrupo      IS NULL OR a.FK_TGRUPO = p_fk_tgrupo)
           AND (p_fk_tunidad     IS NULL OR a.FK_TUNIDAD = p_fk_tunidad)
           AND (p_fecha_desde IS NULL OR COALESCE(a.FECHA_CIERRE, a.FECHA_INICIO) >= p_fecha_desde)
           AND (p_fecha_hasta IS NULL OR COALESCE(a.FECHA_INICIO, a.FECHA_CIERRE) <= p_fecha_hasta)
    )
    SELECT COUNT(*) FILTER (WHERE estado = 'PENDIENTE_POR_EVALUAR')::BIGINT,
           COUNT(*) FILTER (WHERE estado = 'EN_EVALUACION')::BIGINT,
           COUNT(*) FILTER (WHERE estado = 'FINALIZADA')::BIGINT,
           COUNT(*) FILTER (WHERE estado = 'VENCIDA')::BIGINT,
           COUNT(*) FILTER (WHERE estado = 'PROGRAMADA')::BIGINT,
           COUNT(*) FILTER (WHERE estado = 'SIN_PROGRAMAR')::BIGINT,
           COUNT(*)::BIGINT
      FROM est;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_resumen_estados(BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, INT)
    IS 'Contadores del tablero del Planeador (Pendientes por evaluar / En evaluacion vigentes / Finalizadas / Vencidas > p_dias_gracia dias / Programadas / Sin programar) en UNA sola pasada con COUNT(*) FILTER sobre el estado derivado por fn_actividad_estado — no seis queries. Filtros opcionales por asignatura, grupo, unidad y ventana de fechas. Gate VER sobre PLANEADOR. V224.';

-- ---------------------------------------------------------------------------
-- fn_actividad_calendario — grilla mensual.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_calendario(
    p_pk_usuario_solicitante   BIGINT,
    p_fecha_desde              DATE,
    p_fecha_hasta              DATE,
    p_fk_tasignatura           BIGINT  DEFAULT NULL,
    p_fk_tgrupo                BIGINT  DEFAULT NULL,
    p_fk_tunidad               BIGINT  DEFAULT NULL,
    p_dias_gracia              INT     DEFAULT 2
)
RETURNS TABLE (
    fecha             DATE,
    pk_tactividad     BIGINT,
    titulo            VARCHAR,
    fk_tgrupo         BIGINT,
    grupo             VARCHAR,
    fk_tasignatura    BIGINT,
    asignatura        VARCHAR,
    area              VARCHAR,
    estado            VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_hoy DATE := CURRENT_DATE;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    IF p_fecha_desde IS NULL OR p_fecha_hasta IS NULL THEN
        RAISE EXCEPTION 'El rango de fechas (p_fecha_desde, p_fecha_hasta) es obligatorio'
            USING ERRCODE = '22023';
    END IF;
    IF p_fecha_hasta < p_fecha_desde THEN
        RAISE EXCEPTION 'p_fecha_hasta (%) no puede ser anterior a p_fecha_desde (%)',
            p_fecha_hasta, p_fecha_desde USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    SELECT COALESCE(a.FECHA_INICIO, a.FECHA_CIERRE),
           a.PK_TACTIVIDAD,
           a.TITULO,
           a.FK_TGRUPO,
           g.NOMBRE,
           a.FK_TASIGNATURA,
           asig.NOMBRE,
           ar.NOMBRE,
           academico_test.fn_actividad_estado(a.FECHA_INICIO, a.FECHA_CIERRE, a.FECHA_CALIFICADO, v_hoy, p_dias_gracia)
      FROM academico_test.TACTIVIDAD a
      JOIN academico_test.TASIGNATURA asig ON asig.PK_TASIGNATURA = a.FK_TASIGNATURA
      LEFT JOIN academico_test.TAREA ar    ON ar.PK_TAREA = asig.FK_TAREA
      LEFT JOIN academico_test.TGRUPO g    ON g.PK_TGRUPO = a.FK_TGRUPO
     WHERE a.ACTIVE = TRUE
       AND COALESCE(a.FECHA_INICIO, a.FECHA_CIERRE) BETWEEN p_fecha_desde AND p_fecha_hasta
       AND (p_fk_tasignatura IS NULL OR a.FK_TASIGNATURA = p_fk_tasignatura)
       AND (p_fk_tgrupo      IS NULL OR a.FK_TGRUPO = p_fk_tgrupo)
       AND (p_fk_tunidad     IS NULL OR a.FK_TUNIDAD = p_fk_tunidad)
     ORDER BY 1, g.NOMBRE NULLS LAST, a.TITULO;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_calendario(BIGINT, DATE, DATE, BIGINT, BIGINT, BIGINT, INT)
    IS 'Actividades de un rango de fechas para la grilla mensual del Planeador (celdas "601 | Cognitiva"): fecha (FECHA_INICIO, o FECHA_CIERRE si no hay inicio), titulo, grupo, asignatura, area y estado derivado. Entra por idx_tactividad_asignatura_fechas / idx_tactividad_grupo_fechas. Rango obligatorio. Gate VER sobre PLANEADOR. V224.';
