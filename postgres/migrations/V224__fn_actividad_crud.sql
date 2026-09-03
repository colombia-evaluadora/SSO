-- ===========================================================================
-- V224 — Planeador educativo: actividades (crear / editar / listar)
-- (CU-86e311xxp — G. Academico Back Planeador educativo).
--
-- Modulos de este archivo:
--   (1) Seed de TLISTA_VALOR         — los 10 catalogos que las pantallas
--                                       "Nueva actividad" / recuperacion
--                                       usan y que NO existen en el servidor.
--   (2) Indices de soporte           — todo el filtrado del listado y del
--                                       tablero entra por indice.
--   (3) Helpers reutilizables        — fn_actividad_lv_assert,
--                                       fn_actividad_estado,
--                                       fn_actividad_material_reemplazar,
--                                       fn_actividad_materiales_reutilizables_listar
--                                       (picker de reuso de archivos entre
--                                       actividades), fn_actividad_adaptacion_reemplazar,
--                                       fn_actividad_estudiantes_asignar,
--                                       fn_actividad_recuperacion_configurar.
--   (4) Escritura                    — fn_actividad_crear / _actualizar /
--                                       _eliminar (soft delete en cascada).
--   (5) Lectura optimizada           — fn_actividad_listar,
--                                       fn_actividad_buscar_por_pk,
--                                       fn_actividad_resumen_estados,
--                                       fn_actividad_calendario.
--
-- ASIGNACION DE ESTUDIANTES: fn_actividad_crear NO vincula a nadie por
-- defecto. p_asignar_todo_el_grupo=TRUE toma todas las matriculas ACTIVE
-- del FK_TGRUPO; p_fk_tmatriculas fija estudiantes especificos (1 o mas,
-- validados contra el grupo). El pivote es TACTIVIDAD_ESTUDIANTE (N:M).
--
-- RECUPERACION: si p_recuperacion (objeto) viene en crear/actualizar, la
-- actividad queda con ES_RECUPERACION='S' y se crea su fila 1:1 en
-- TACTIVIDAD_RECUPERACION (V22) via fn_actividad_recuperacion_configurar
-- (destino ACTIVIDAD|NOTA_FINAL, aplicacion COMPUTAR|REEMPLAZAR, calculo
-- PROMEDIADO|PONDERADO). NO se tocan las notas/definitivas: eso es del
-- motor de calificacion, fuera de este archivo.
--
-- HUECO CONOCIDO (documentado, NO resuelto aqui) — camino "formativo sin
-- asignatura ni unidad": el negocio describe un camino donde una actividad
-- de un referente curricular FORMATIVO (p.ej. Preescolar / "Propositos e
-- Imprescindibles") no tiene evaluacion, no tiene adaptaciones (ver gate
-- nuevo en fn_actividad_adaptacion_reemplazar mas abajo), no tiene unidad NI
-- asignatura, y su "nota" es en realidad un comentario/observacion. Hoy eso
-- NO es posible: TACTIVIDAD.FK_TASIGNATURA es NOT NULL (agregada en V218,
-- rama feature/CU-86e329pvq-Fix-Correciones-de-Relacion-Unidad-Actividad,
-- migracion ajena a este archivo/rama) y TREFERENTE_CURRICULAR (V212, rama
-- feature/CU-86e311xqh) no tiene ningun flag "aplica/no aplica por
-- asignatura" -- TREFERENTE_CURRICULAR_AREA es un concepto distinto (N:N
-- con areas/dimensiones DENTRO de una asignatura, no "sin asignatura en
-- absoluto"). Resolverlo requeriria: (a) volver FK_TASIGNATURA nullable en
-- V218 (migracion de otra rama, fuera del alcance de este cambio) y (b) un
-- flag nuevo en TREFERENTE_CURRICULAR. Se deja documentado a proposito, sin
-- tocar V218 ni inventar el flag, hasta que se confirme con negocio si el
-- modelo formativo realmente no necesita asignatura o solo necesita que sea
-- opcional.
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
--       ("Recurso 1 - Fuente" -> Tipo / URL / Sitio web / Archivo en PC).
--       Gana un tercer valor REPOSITORIO ("Unidad virtual / repositorio",
--       confirmado en el figma de "Recursos agregados"): material que NO se
--       sube de nuevo sino que se REFERENCIA desde otra actividad via
--       fn_actividad_materiales_reutilizables_listar -- mismo FK_TARCHIVO,
--       otra fila TACTIVIDAD_MATERIAL. Estructuralmente ARCHIVO y
--       REPOSITORIO son identicos (ambos usan FK_TARCHIVO, el CHECK
--       CK_TACTIVIDAD_MATERIAL_RECURSO no distingue); REPOSITORIO es
--       puramente la etiqueta que el front necesita para pintar el badge
--       correcto y el subtitulo "Desde actividad: ...".
--     * TIPO_EVIDENCIA: CONFIRMADO con el figma del bloque "Seguimiento"
--       (dropdown "Tipo de evidencia"): Archivo / Enlace / Imagen / Video /
--       Observacion. Reemplaza la lista MINIMA anterior (Archivo / Enlace /
--       Texto / Otro), que quedo con dos valores incorrectos (TEXTO, OTRO) y
--       dos faltantes (IMAGEN, VIDEO) -- ver el DEACTIVATE de esos dos abajo,
--       en el mismo bloque de seed.
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
--   * fn_unidad_calculo_definitiva_modo + fn_unidad_ponderacion_recalcular_sumatoria
--     (V223) — la regla dinamica de la ponderacion segun el metodo de
--     calculo de la unidad (V73) vive alli; aqui solo se RECHAZA la
--     ponderacion manual cuando no aplica y se dispara el recalculo del
--     bucket (unidad, grupo) tras crear / actualizar / eliminar.
--
-- PONDERACION DE LA ACTIVIDAD (condicion dinamica de V137, bloque
-- 'ponderacion'), dos gates encadenados en crear/actualizar:
--   (a) ES_EVALUATIVA = 'N' -> la ponderacion NO aplica (22023 si viene).
--   (b) metodo de calculo de la unidad (TUNIDAD.FK_TLV_CALCULO_DEFINITIVA,
--       V73): Ponderar -> el docente escribe el %; Promediar -> no aplica
--       (22023); Sumatoria -> el docente escribe el PUNTAJE en la columna ya
--       existente NOTA_MAXIMA (no se crea columna nueva) y el % lo
--       autocalcula el sistema para todo el bucket.
-- En _actualizar los dos gates se evaluan contra los valores RESULTANTES
-- (ES_EVALUATIVA y unidad tras aplicar el PATCH), igual que ya hacian
-- v_fk_tunidad / v_instrumento para la sub-rama de evaluacion.
--
-- Depende de (orden de version de Flyway):
--   * V22  — TACTIVIDAD, TACTIVIDAD_MATERIAL, TACTIVIDAD_ADAPTACION,
--            TACTIVIDAD_ESTUDIANTE, TACTIVIDAD_NOTA, TMATRICULA, TGRUPO,
--            TASIGNATURA, TAREA, TLISTA_VALOR, TARCHIVO.
--   * V112 — extension pg_trgm (se re-asegura aqui, idempotente).
--   * V218 — TACTIVIDAD.FK_TASIGNATURA (NOT NULL), FK_TUNIDAD nullable.
--   * V73  — TUNIDAD.FK_TLV_CALCULO_DEFINITIVA (rama CU-86e30a25v).
--   * V223 — TACTIVIDAD.PONDERACION + trigger del 100% + fn_unidad_actividad_*
--            + fn_unidad_calculo_definitiva_modo + fn_unidad_ponderacion_recalcular_sumatoria.
--   * V137 — fn_unidad_referente_evaluativo (sub-rama de evaluacion).
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
    -- Recuperacion (TACTIVIDAD_RECUPERACION, cuando ES_RECUPERACION='S').
    -- Valores de los comentarios de V22.
    ('DESTINO_RECUPERACION',            'Recuperar una actividad',            'ACTIVIDAD'),
    ('DESTINO_RECUPERACION',            'Recuperar la nota final',            'NOTA_FINAL'),
    ('TIPO_APLICACION_RECUPERACION',    'Computar con la nota anterior',      'COMPUTAR'),
    ('TIPO_APLICACION_RECUPERACION',    'Reemplazar la nota anterior',        'REEMPLAZAR'),
    ('TIPO_CALCULO_RECUPERACION',       'Promediado',                         'PROMEDIADO'),
    ('TIPO_CALCULO_RECUPERACION',       'Ponderado',                          'PONDERADO'),
    -- Seguimiento (figma "Tipo de evidencia", confirmado)
    ('TIPO_EVIDENCIA',                  'Archivo',                            'ARCHIVO'),
    ('TIPO_EVIDENCIA',                  'Enlace',                             'ENLACE'),
    ('TIPO_EVIDENCIA',                  'Imagen',                             'IMAGEN'),
    ('TIPO_EVIDENCIA',                  'Video',                              'VIDEO'),
    ('TIPO_EVIDENCIA',                  'Observación',                        'OBSERVACION'),
    -- Materiales de apoyo (TACTIVIDAD_MATERIAL: URL XOR ARCHIVO, sin
    -- distincion estructural entre ARCHIVO y REPOSITORIO -- ver nota arriba).
    -- Etiquetas del figma ("Recurso 1 - Fuente" -> Tipo).
    ('TIPO_RECURSO',                    'URL / Sitio web',                    'URL'),
    ('TIPO_RECURSO',                    'Archivo en PC',                      'ARCHIVO'),
    ('TIPO_RECURSO',                    'Unidad virtual / repositorio',       'REPOSITORIO'),
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

-- Correccion del seed anterior de TIPO_EVIDENCIA (ver nota arriba): TEXTO y
-- OTRO no aparecen en el figma confirmado y se reemplazan por IMAGEN/VIDEO/
-- OBSERVACION. Se desactivan en vez de borrarlas (UPDATE, no DELETE) por si
-- algun ambiente ya las tuviera referenciadas desde una corrida anterior de
-- este mismo archivo -- soft delete, mismo criterio que el resto del repo.
UPDATE academico_test.tlista_valor
   SET ACTIVE = FALSE, MODIFIED_BY = 'V224_seed_fix', MODIFIED_AT = CURRENT_TIMESTAMP
 WHERE CATEGORIA = 'TIPO_EVIDENCIA'
   AND VALOR IN ('TEXTO', 'OTRO')
   AND ACTIVE = TRUE;

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
    IS 'Reemplazo completo de los materiales de apoyo de una actividad (TACTIVIDAD_MATERIAL): desactiva los ACTIVE y re-inserta los del array con ORDEN por posicion. p_materiales NULL = no tocar; array vacio = dejarla sin materiales. Cada elemento {tipoRecurso, url|fkTarchivo, descripcion?} debe traer exactamente uno de url/fkTarchivo (CHECK de V22). Para REUTILIZAR un archivo ya usado en otra actividad, se pasa el mismo fkTarchivo (obtenido de fn_actividad_materiales_reutilizables_listar) con tipoRecurso=REPOSITORIO -- no hay restriccion que lo impida, un TARCHIVO puede estar referenciado por N filas TACTIVIDAD_MATERIAL de distintas actividades. Helper de fn_actividad_crear/_actualizar. Retorna cuantos quedaron. V224.';

-- ---------------------------------------------------------------------------
-- fn_actividad_materiales_reutilizables_listar — picker de "Materiales de
-- apoyo" para referenciar un archivo YA subido en OTRA actividad (badge
-- "Unidad virtual / repositorio" del figma, subtitulo "Desde actividad: ...").
--
-- Lista materiales de tipo ARCHIVO o REPOSITORIO (con FK_TARCHIVO, no URL)
-- de actividades ACTIVAS distintas a p_pk_tactividad (si se pasa, para no
-- ofrecer los materiales de la propia actividad que se esta editando).
-- Filtra opcionalmente por asignatura y/o docente autor de la actividad de
-- origen. Si el mismo TARCHIVO quedo referenciado por varias actividades
-- (ya reutilizado antes), se muestra una fila por CADA actividad de origen
-- (no se colapsa): cada una es una fuente valida distinta para el subtitulo
-- "Desde actividad: ...".
--
-- Sin patron CTE-base de paginacion pesada: el universo tipico (materiales
-- con archivo de las actividades del docente/asignatura) es acotado: se usa
-- LIMIT/OFFSET simple sobre el filtro ya indexado por FK_TASIGNATURA
-- (IDX_TACTIVIDAD_26, V218) y FK_TFUNCIONARIO (via TUNIDAD, no directo en
-- TACTIVIDAD -- ver JOIN).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_materiales_reutilizables_listar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT  DEFAULT NULL,
    p_fk_tasignatura           BIGINT  DEFAULT NULL,
    p_fk_tfuncionario          BIGINT  DEFAULT NULL,
    p_search                   VARCHAR DEFAULT NULL,
    p_pagina                   INT     DEFAULT 1,
    p_tamano_pagina            INT     DEFAULT 20
)
RETURNS TABLE (
    fk_tarchivo             BIGINT,
    nombre_archivo          VARCHAR,
    peso                    BIGINT,
    pk_tactividad_origen    BIGINT,
    titulo_actividad_origen VARCHAR,
    fk_tlv_tipo_recurso     BIGINT,
    tipo_recurso            VARCHAR,
    descripcion             VARCHAR,
    total_count             BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_limite INT;
    v_offset INT;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    v_limite := GREATEST(COALESCE(p_tamano_pagina, 20), 1);
    v_offset := (GREATEST(COALESCE(p_pagina, 1), 1) - 1) * v_limite;

    RETURN QUERY
    SELECT t.PK_TARCHIVO,
           t.NOMBRE,
           t.PESO,
           a.PK_TACTIVIDAD,
           a.TITULO,
           m.FK_TLV_TIPO_RECURSO,
           lv.NOMBRE,
           m.DESCRIPCION,
           COUNT(*) OVER()
      FROM academico_test.TACTIVIDAD_MATERIAL m
      JOIN academico_test.TACTIVIDAD a  ON a.PK_TACTIVIDAD = m.FK_TACTIVIDAD AND a.ACTIVE = TRUE
      JOIN academico_test.TARCHIVO t    ON t.PK_TARCHIVO = m.FK_TARCHIVO AND t.ACTIVE = TRUE
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = m.FK_TLV_TIPO_RECURSO
      LEFT JOIN academico_test.TUNIDAD u ON u.PK_TUNIDAD = a.FK_TUNIDAD
     WHERE m.ACTIVE = TRUE
       AND m.FK_TARCHIVO IS NOT NULL
       AND (p_pk_tactividad IS NULL OR a.PK_TACTIVIDAD <> p_pk_tactividad)
       AND (p_fk_tasignatura  IS NULL OR a.FK_TASIGNATURA = p_fk_tasignatura)
       AND (p_fk_tfuncionario IS NULL OR u.FK_TFUNCIONARIO = p_fk_tfuncionario)
       AND (p_search IS NULL OR TRIM(p_search) = ''
            OR t.NOMBRE ILIKE '%' || TRIM(p_search) || '%'
            OR a.TITULO ILIKE '%' || TRIM(p_search) || '%')
     ORDER BY t.NOMBRE, a.TITULO
     LIMIT v_limite
    OFFSET v_offset;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_materiales_reutilizables_listar(BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, INT, INT)
    IS 'Picker de reutilizacion de materiales de apoyo: materiales con archivo (FK_TARCHIVO, tipoRecurso ARCHIVO o REPOSITORIO) de OTRAS actividades activas, para referenciar el mismo TARCHIVO en la actividad que se esta editando/creando (badge "Unidad virtual / repositorio" del figma, "Desde actividad: <titulo>"). p_pk_tactividad (opcional) excluye los materiales de esa misma actividad; p_fk_tasignatura y p_fk_tfuncionario (via la unidad de la actividad de origen) filtran el universo; p_search busca por nombre de archivo o titulo de la actividad de origen. Si un TARCHIVO ya fue reutilizado antes, aparece una fila por cada actividad de origen distinta (no se colapsa). Gate VER sobre PLANEADOR. total_count via COUNT(*) OVER(). V224.';

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
--
-- CONDICION DINAMICA "adaptaciones -> evaluacion" — NO APLICA. Se evaluo
-- exigir que la actividad tenga unidad con referente EVALUATIVO (misma
-- condicion del instrumento), pero el negocio confirmo que una actividad SIN
-- unidad SI puede tener adaptaciones curriculares: la adaptacion (accesos,
-- material alternativo, formato modificado) es independiente de si la
-- actividad se evalua formalmente o no. No se agrega ningun gate contra
-- FK_TUNIDAD/referente aqui.
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
    IS 'Reemplazo completo de las adaptaciones curriculares de una actividad (TACTIVIDAD_ADAPTACION + TACTIVIDAD_ADAPTACION_ESTUDIANTE). p_adaptaciones NULL = no tocar; array vacio = dejarla sin adaptaciones. Sin gate contra unidad/referente: una actividad SIN unidad SI puede tener adaptaciones (confirmado con negocio -- la adaptacion es independiente de si la actividad se evalua formalmente). Elemento {tipoAdaptacion, descripcion(<=500), usaVersionModificada(S/N), formatoAdaptacion?, fkTarchivo?, url?, aplicaA?, estudiantes?[]}. Reglas del figma: con usaVersionModificada=''S'' el formato es obligatorio y ARCHIVO/BIBLIOTECA exigen fkTarchivo mientras ENLACE exige url; con ''N'' no se admite formato. aplicaA=ESTUDIANTES_SELECCIONADOS exige la lista de matriculas, que deben estar YA asignadas a la actividad (por eso se llama despues de fn_actividad_estudiantes_asignar); con TODO_EL_GRUPO la lista debe venir vacia. Retorna cuantas adaptaciones quedaron. V224.';

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
    IS 'Reemplazo completo del pivote TACTIVIDAD_ESTUDIANTE de una actividad. p_fk_tmatriculas NULL + p_todo_el_grupo=TRUE asigna todas las matriculas ACTIVE del FK_TGRUPO de la actividad; un array la fija a ese set exacto (valida existencia/estado/grupo, 23503). Reactiva filas previamente desactivadas en vez de duplicar. Ambos NULL/FALSE = no toca nada (fn_actividad_crear NO asigna estudiantes por defecto). Retorna el total de asignados activos. V224.';

-- ---------------------------------------------------------------------------
-- fn_actividad_recuperacion_configurar — 1:1 TACTIVIDAD_RECUPERACION.
--
-- Una actividad de recuperacion (TACTIVIDAD.ES_RECUPERACION = 'S') SIEMPRE
-- lleva su fila en TACTIVIDAD_RECUPERACION (V22) con la config del destino
-- y la forma de calculo. Esta funcion es el punto unico que la crea /
-- actualiza / desactiva.
--
-- p_config JSONB (NULL = la actividad NO es de recuperacion):
--   {
--     "destino":              <pk_lv DESTINO_RECUPERACION>,   -- ACTIVIDAD | NOTA_FINAL
--     "fkActividadRecuperar": <pk_tactividad>,                -- oblig. si destino=ACTIVIDAD; NULL si NOTA_FINAL
--     "tipoAplicacion":       <pk_lv TIPO_APLICACION_RECUPERACION>,  -- COMPUTAR | REEMPLAZAR
--     "tipoCalculo":          <pk_lv TIPO_CALCULO_RECUPERACION>,     -- PROMEDIADO | PONDERADO
--     "valorPonderacion":     <numeric 0..100>                -- oblig. si tipoCalculo=PONDERADO; NULL si PROMEDIADO
--   }
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_recuperacion_configurar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    p_config                   JSONB
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_act_active   BOOLEAN;
    v_destino_val  VARCHAR;
    v_calculo_val  VARCHAR;
    v_fk_recuperar BIGINT;
    v_valor_pond   NUMERIC(5,2);
    v_pk           BIGINT;
BEGIN
    SELECT ACTIVE INTO v_act_active
      FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;

    -- ----- Sin config: la actividad deja de ser (o nunca fue) de recuperacion.
    IF p_config IS NULL THEN
        UPDATE academico_test.TACTIVIDAD_RECUPERACION
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;
        UPDATE academico_test.TACTIVIDAD
           SET ES_RECUPERACION = 'N', MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD = p_pk_tactividad AND ES_RECUPERACION <> 'N';
        RETURN NULL;
    END IF;

    IF jsonb_typeof(p_config) <> 'object' THEN
        RAISE EXCEPTION 'p_config (recuperacion) debe ser un objeto JSON' USING ERRCODE = '22023';
    END IF;

    -- ----- Catalogos.
    IF (p_config->>'destino') IS NULL OR (p_config->>'tipoAplicacion') IS NULL
       OR (p_config->>'tipoCalculo') IS NULL THEN
        RAISE EXCEPTION 'La recuperacion requiere destino, tipoAplicacion y tipoCalculo' USING ERRCODE = '22023';
    END IF;
    PERFORM academico_test.fn_actividad_lv_assert((p_config->>'destino')::BIGINT,        'DESTINO_RECUPERACION',         'destino');
    PERFORM academico_test.fn_actividad_lv_assert((p_config->>'tipoAplicacion')::BIGINT, 'TIPO_APLICACION_RECUPERACION', 'tipoAplicacion');
    PERFORM academico_test.fn_actividad_lv_assert((p_config->>'tipoCalculo')::BIGINT,    'TIPO_CALCULO_RECUPERACION',    'tipoCalculo');

    SELECT VALOR INTO v_destino_val FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = (p_config->>'destino')::BIGINT;
    SELECT VALOR INTO v_calculo_val FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = (p_config->>'tipoCalculo')::BIGINT;

    -- ----- Destino: ACTIVIDAD exige la actividad origen; NOTA_FINAL la prohibe.
    v_fk_recuperar := (p_config->>'fkActividadRecuperar')::BIGINT;
    IF v_destino_val = 'ACTIVIDAD' THEN
        IF v_fk_recuperar IS NULL THEN
            RAISE EXCEPTION 'destino = ACTIVIDAD exige fkActividadRecuperar' USING ERRCODE = '22023';
        END IF;
        IF v_fk_recuperar = p_pk_tactividad THEN
            RAISE EXCEPTION 'Una actividad no puede recuperarse a si misma' USING ERRCODE = '22023';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD
                        WHERE PK_TACTIVIDAD = v_fk_recuperar AND ACTIVE = TRUE) THEN
            RAISE EXCEPTION 'fkActividadRecuperar (%) no existe o no esta activa', v_fk_recuperar USING ERRCODE = '23503';
        END IF;
    ELSE  -- NOTA_FINAL
        IF v_fk_recuperar IS NOT NULL THEN
            RAISE EXCEPTION 'destino = NOTA_FINAL no admite fkActividadRecuperar' USING ERRCODE = '22023';
        END IF;
    END IF;

    -- ----- Calculo: PONDERADO exige el peso; PROMEDIADO lo prohibe.
    v_valor_pond := (p_config->>'valorPonderacion')::NUMERIC;
    IF v_calculo_val = 'PONDERADO' THEN
        IF v_valor_pond IS NULL OR v_valor_pond < 0 OR v_valor_pond > 100 THEN
            RAISE EXCEPTION 'tipoCalculo = PONDERADO exige valorPonderacion entre 0 y 100' USING ERRCODE = '22023';
        END IF;
    ELSIF v_valor_pond IS NOT NULL THEN
        RAISE EXCEPTION 'valorPonderacion solo aplica con tipoCalculo = PONDERADO' USING ERRCODE = '22023';
    END IF;

    -- ----- Marca la actividad como de recuperacion.
    UPDATE academico_test.TACTIVIDAD
       SET ES_RECUPERACION = 'S', MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD = p_pk_tactividad AND ES_RECUPERACION <> 'S';

    -- ----- Upsert 1:1 (UNIQUE FK_TACTIVIDAD, patron get-or-create/reactivar).
    SELECT PK_TACTIVIDAD_RECUPERACION INTO v_pk
      FROM academico_test.TACTIVIDAD_RECUPERACION
     WHERE FK_TACTIVIDAD = p_pk_tactividad;

    IF v_pk IS NULL THEN
        INSERT INTO academico_test.TACTIVIDAD_RECUPERACION (
            FK_TACTIVIDAD, FK_TLV_DESTINO_RECUPERACION, FK_TACTIVIDAD_RECUPERAR,
            FK_TLV_TIPO_APLICACION_RECUPERACION, FK_TLV_TIPO_CALCULO_RECUPERACION,
            VALOR_PONDERACION_RECUPERACION, CREATED_BY, CREATED_AT, ACTIVE
        ) VALUES (
            p_pk_tactividad, (p_config->>'destino')::BIGINT, v_fk_recuperar,
            (p_config->>'tipoAplicacion')::BIGINT, (p_config->>'tipoCalculo')::BIGINT,
            v_valor_pond, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
        )
        RETURNING PK_TACTIVIDAD_RECUPERACION INTO v_pk;
    ELSE
        UPDATE academico_test.TACTIVIDAD_RECUPERACION
           SET FK_TLV_DESTINO_RECUPERACION           = (p_config->>'destino')::BIGINT,
               FK_TACTIVIDAD_RECUPERAR               = v_fk_recuperar,
               FK_TLV_TIPO_APLICACION_RECUPERACION   = (p_config->>'tipoAplicacion')::BIGINT,
               FK_TLV_TIPO_CALCULO_RECUPERACION      = (p_config->>'tipoCalculo')::BIGINT,
               VALOR_PONDERACION_RECUPERACION        = v_valor_pond,
               ACTIVE                                = TRUE,
               MODIFIED_BY                           = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT                           = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD_RECUPERACION = v_pk;
    END IF;

    RETURN v_pk;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_recuperacion_configurar(BIGINT, BIGINT, JSONB)
    IS 'Punto unico para la config 1:1 de recuperacion (TACTIVIDAD_RECUPERACION). p_config NULL = la actividad NO es de recuperacion (desactiva la fila y pone ES_RECUPERACION=''N''). Con objeto {destino, fkActividadRecuperar?, tipoAplicacion, tipoCalculo, valorPonderacion?}: valida los 3 catalogos (DESTINO_RECUPERACION / TIPO_APLICACION_RECUPERACION / TIPO_CALCULO_RECUPERACION), exige fkActividadRecuperar sii destino=ACTIVIDAD (y != la propia actividad, activa), exige valorPonderacion 0..100 sii tipoCalculo=PONDERADO, marca ES_RECUPERACION=''S'' y hace upsert de la fila. Llamada por fn_actividad_crear/_actualizar. Retorna PK_TACTIVIDAD_RECUPERACION (o NULL). V224.';

-- ===========================================================================
-- (4) ESCRITURA
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- fn_actividad_crear
-- ---------------------------------------------------------------------------
-- Gana p_evidencias / p_criterios (BIGINT[]) al final: cambia el numero de
-- parametros, asi que CREATE OR REPLACE no reemplaza la firma vieja (33
-- args) -- se antepone el DROP FUNCTION IF EXISTS de esa firma, mismo
-- patron que V100/V106/V109/V113.
DROP FUNCTION IF EXISTS academico_test.fn_actividad_crear(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, VARCHAR, BIGINT, BIGINT, NUMERIC, DATE, DATE, NUMERIC, VARCHAR, BIGINT, VARCHAR, VARCHAR, BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, NUMERIC, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, JSONB, JSONB, BIGINT[], BOOLEAN, JSONB);
-- p_es_evaluativa/p_requiere_archivo/p_requiere_texto/p_genera_evidencias/
-- p_requiere_validacion_coordinador pasan de VARCHAR(1) a
-- academico_test.bool_sn (mismo dominio ya usado por la columna, y
-- convencion ya establecida en el repo -- V37/V39/V53/V100/V111/V159/V180 --
-- para tipar parametros S/N, en vez de VARCHAR(1) + validacion manual
-- NOT IN ('S','N')): otro cambio de tipo de parametro, mismo criterio de
-- DROP FUNCTION IF EXISTS de la firma inmediatamente anterior (35 args, con
-- VARCHAR en esas 5 posiciones).
DROP FUNCTION IF EXISTS academico_test.fn_actividad_crear(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, VARCHAR, BIGINT, BIGINT, NUMERIC, DATE, DATE, NUMERIC, VARCHAR, BIGINT, VARCHAR, VARCHAR, BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, NUMERIC, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, JSONB, JSONB, BIGINT[], BOOLEAN, JSONB, BIGINT[], BIGINT[]);
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
    p_es_evaluativa                     academico_test.bool_sn DEFAULT 'S',
    p_fk_tlv_instrumento_evaluacion     BIGINT        DEFAULT NULL,
    p_descripcion_instrumento           VARCHAR(4000) DEFAULT NULL,
    p_fk_tlv_tipo_evidencia             BIGINT        DEFAULT NULL,
    p_fk_tlv_metodo_valoracion          BIGINT        DEFAULT NULL,
    p_fk_tlv_tipo_calculo               BIGINT        DEFAULT NULL,
    p_influencia                        NUMERIC       DEFAULT NULL,
    p_nota_maxima                       NUMERIC       DEFAULT NULL,
    p_requiere_archivo                  academico_test.bool_sn DEFAULT 'N',
    p_requiere_texto                    academico_test.bool_sn DEFAULT 'N',
    p_genera_evidencias                 academico_test.bool_sn DEFAULT 'N',
    p_requiere_validacion_coordinador   academico_test.bool_sn DEFAULT 'N',
    p_observaciones_docente             VARCHAR(4000) DEFAULT NULL,
    p_materiales                        JSONB         DEFAULT NULL,
    p_adaptaciones                      JSONB         DEFAULT NULL,
    p_fk_tmatriculas                    BIGINT[]      DEFAULT NULL,
    p_asignar_todo_el_grupo             BOOLEAN       DEFAULT FALSE,
    -- NULL = actividad normal. Objeto = actividad de recuperacion:
    -- {destino, fkActividadRecuperar?, tipoAplicacion, tipoCalculo, valorPonderacion?}
    p_recuperacion                      JSONB         DEFAULT NULL,
    -- PK_REFERENTE_ENUNCIADO (nivel 2 / evidencia) que esta actividad
    -- sustenta. Solo tiene sentido si la actividad tiene unidad (p_fk_tunidad)
    -- y cada evidencia cuelga de un enunciado ya relacionado con esa unidad
    -- (TUNIDAD_ENUNCIADO) -- fn_actividad_evidencia_relacionar (V136) valida
    -- todo eso, aborta el CREATE si alguna no cumple.
    p_evidencias                        BIGINT[]      DEFAULT NULL,
    -- PK_TCRITERIO_UNIDAD de la rubrica de la unidad que esta actividad
    -- evalua. Solo tiene sentido si la actividad tiene unidad; cada criterio
    -- debe pertenecer a la rubrica de ESA unidad --
    -- fn_actividad_criterio_relacionar (V136) lo valida, aborta el CREATE
    -- si alguno no cumple.
    p_criterios                         BIGINT[]      DEFAULT NULL
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
    -- Las banderas S/N ya son academico_test.bool_sn: el dominio (CHECK IN
    -- ('S','N')) las valida al vuelo, no hace falta un chequeo manual aqui.

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
    -- Condicion dinamica "actividad -> ponderacion" (V137, bloque
    -- 'ponderacion'), gate (a): sin evaluacion no hay peso que repartir.
    IF p_ponderacion IS NOT NULL AND COALESCE(p_es_evaluativa, 'S') = 'N' THEN
        RAISE EXCEPTION 'La ponderacion no aplica: la actividad no es evaluativa (p_es_evaluativa = ''N'')'
            USING ERRCODE = '22023';
    END IF;
    -- Gate (b): el metodo de calculo de la unidad (V73) decide si el % se
    -- captura a mano (Ponderar), no aplica (Promediar) o lo autocalcula el
    -- sistema a partir de NOTA_MAXIMA (Sumatoria). fn_unidad_calculo_definitiva_modo
    -- y el recalculo viven en V223, punto unico de la regla.
    IF p_ponderacion IS NOT NULL AND p_fk_tunidad IS NOT NULL THEN
        IF academico_test.fn_unidad_calculo_definitiva_modo(p_fk_tunidad) = 'PROMEDIAR' THEN
            RAISE EXCEPTION 'La ponderacion no aplica: la unidad (%) promedia sus actividades', p_fk_tunidad
                USING ERRCODE = '22023';
        ELSIF academico_test.fn_unidad_calculo_definitiva_modo(p_fk_tunidad) = 'SUMATORIA' THEN
            RAISE EXCEPTION 'La ponderacion de la unidad (%) se autocalcula: es una unidad de Sumatoria, envie el puntaje de la actividad (p_nota_maxima) en vez del porcentaje', p_fk_tunidad
                USING ERRCODE = '22023';
        END IF;
    END IF;
    -- Una actividad de recuperacion recupera una NOTA: tiene que ser evaluativa.
    IF p_recuperacion IS NOT NULL AND COALESCE(p_es_evaluativa, 'S') = 'N' THEN
        RAISE EXCEPTION 'Una actividad de recuperacion debe ser evaluativa (p_es_evaluativa = ''S'')'
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

    -- 4.b Sub-rama "evaluacion" (instrumento de evaluacion, condicion
    --     dinamica "actividad -> evaluacion" de V137): solo aplica si la
    --     actividad se vincula a una unidad cuyo referente curricular es
    --     EVALUATIVO. Se resuelve aqui con fn_unidad_referente_evaluativo
    --     (toma pk_tunidad, disponible antes del INSERT) en vez de
    --     fn_actividad_instrumentos_permitidos (V137), que exige un
    --     pk_tactividad que todavia no existe en este punto (se crea en el
    --     paso 6, mas abajo).
    IF p_fk_tlv_instrumento_evaluacion IS NOT NULL THEN
        IF p_fk_tunidad IS NULL THEN
            RAISE EXCEPTION 'El instrumento de evaluacion (FK_TLV_INSTRUMENTO_EVALUACION) no aplica: la actividad no esta vinculada a una unidad'
                USING ERRCODE = '22023';
        ELSIF NOT academico_test.fn_unidad_referente_evaluativo(p_fk_tunidad) THEN
            RAISE EXCEPTION 'El instrumento de evaluacion (FK_TLV_INSTRUMENTO_EVALUACION) no aplica: el referente curricular de la unidad no es EVALUATIVO'
                USING ERRCODE = '22023';
        END IF;
    END IF;

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
        ES_EVALUATIVA, ES_RECUPERACION, FK_TLV_INSTRUMENTO_EVALUACION, DESCRIPCION_INSTRUMENTO,
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
        COALESCE(p_es_evaluativa, 'S'),
        CASE WHEN p_recuperacion IS NOT NULL THEN 'S' ELSE 'N' END,
        p_fk_tlv_instrumento_evaluacion,
        NULLIF(TRIM(p_descripcion_instrumento), ''),
        p_fk_tlv_tipo_evidencia, p_fk_tlv_metodo_valoracion,
        COALESCE(p_requiere_archivo, 'N'), COALESCE(p_requiere_texto, 'N'),
        COALESCE(p_genera_evidencias, 'N'),
        COALESCE(p_requiere_validacion_coordinador, 'N'),
        NULLIF(TRIM(p_observaciones_docente), ''),
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TACTIVIDAD INTO v_id_creado;

    -- 6.b Unidad de SUMATORIA: el % de TODAS las actividades del bucket
    --     (unidad, grupo) se reparte proporcionalmente segun NOTA_MAXIMA, asi
    --     que entrar una actividad nueva obliga a recalcular el bucket
    --     completo. No-op si la unidad no es de sumatoria (o no hay unidad).
    PERFORM academico_test.fn_unidad_ponderacion_recalcular_sumatoria(p_fk_tunidad, p_fk_tgrupo);

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
    -- Config 1:1 de recuperacion (crea TACTIVIDAD_RECUPERACION si p_recuperacion no es NULL).
    PERFORM academico_test.fn_actividad_recuperacion_configurar(
                p_pk_usuario_solicitante, v_id_creado, p_recuperacion);

    -- 8. Evidencias de enunciado (opcional; TACTIVIDAD_EVIDENCIA, V136).
    --    fn_actividad_evidencia_relacionar exige FK_TUNIDAD y que el
    --    enunciado padre de cada evidencia ya este en TUNIDAD_ENUNCIADO
    --    para esa misma unidad -- revienta y aborta el CREATE si no.
    IF p_evidencias IS NOT NULL THEN
        PERFORM academico_test.fn_actividad_evidencia_relacionar(
                    p_pk_usuario_solicitante, v_id_creado, ev)
          FROM unnest(p_evidencias) AS ev
         WHERE ev IS NOT NULL;
    END IF;

    -- 9. Criterios de la rubrica de la unidad (opcional;
    --    TACTIVIDAD_CRITERIO_UNIDAD, V136). fn_actividad_criterio_relacionar
    --    exige FK_TUNIDAD y que cada criterio pertenezca a la rubrica de
    --    esa misma unidad -- revienta y aborta el CREATE si no.
    IF p_criterios IS NOT NULL THEN
        PERFORM academico_test.fn_actividad_criterio_relacionar(
                    p_pk_usuario_solicitante, v_id_creado, cr)
          FROM unnest(p_criterios) AS cr
         WHERE cr IS NOT NULL;
    END IF;

    RETURN v_id_creado;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_crear(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, VARCHAR, BIGINT, BIGINT, NUMERIC, DATE, DATE, NUMERIC, VARCHAR, BIGINT, VARCHAR, academico_test.bool_sn, BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, NUMERIC, academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, VARCHAR, JSONB, JSONB, BIGINT[], BOOLEAN, JSONB, BIGINT[], BIGINT[])
    IS 'Crea una actividad del Planeador (gate CREAR sobre PLANEADOR): inserta TACTIVIDAD (identificacion, programacion, evaluacion y seguimiento) y opcionalmente la vincula a una unidad con su PONDERACION (%) — la regla "la suma por (unidad, grupo) no pasa de 100" la impone el trigger de V223. NO asigna estudiantes por defecto: p_asignar_todo_el_grupo=TRUE los toma del FK_TGRUPO, o p_fk_tmatriculas fija estudiantes especificos (1 o mas). p_recuperacion (objeto) marca la actividad como de recuperacion y crea su fila TACTIVIDAD_RECUPERACION via fn_actividad_recuperacion_configurar. p_evidencias (PKs de TREFERENTE_ENUNCIADO nivel 2) y p_criterios (PKs de TCRITERIO_UNIDAD) relacionan la actividad, via fn_actividad_evidencia_relacionar / fn_actividad_criterio_relacionar (V136), con evidencias de enunciados ya vinculados a la unidad y con criterios de la rubrica de esa misma unidad — ambos exigen FK_TUNIDAD y abortan el CREATE si la actividad no tiene unidad o alguna PK no cumple la regla de negocio. Delega materiales / adaptaciones / estudiantes en sus helpers. Valida catalogos con fn_actividad_lv_assert y unicidad (titulo, unidad, grupo, jerarquia) entre activas con IS NOT DISTINCT FROM. p_fk_tlv_instrumento_evaluacion solo se acepta si la actividad se vincula a una unidad (p_fk_tunidad) cuyo referente curricular es EVALUATIVO (fn_unidad_referente_evaluativo, condicion dinamica "actividad -> evaluacion" de V137); en otro caso lanza 22023. PONDERACION (condicion dinamica "actividad -> ponderacion" de V137): se rechaza (22023) si la actividad no es evaluativa (p_es_evaluativa=''N''), si no se vincula a una unidad, si la unidad PROMEDIA (no aplica) o si la unidad calcula por SUMATORIA -- ahi el docente envia p_nota_maxima (puntaje) y el % lo autocalcula fn_unidad_ponderacion_recalcular_sumatoria (V223), invocada tras el INSERT para repartir el bucket (unidad, grupo) completo. Retorna PK_TACTIVIDAD. V224.';

-- ---------------------------------------------------------------------------
-- fn_actividad_actualizar — PATCH parcial.
--
-- Mismo cambio de tipo que en fn_actividad_crear (VARCHAR(1) ->
-- academico_test.bool_sn en las 5 banderas S/N): DROP FUNCTION IF EXISTS de
-- la firma anterior antes del CREATE OR REPLACE.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_actividad_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, BOOLEAN, BIGINT, DATE, DATE, NUMERIC, VARCHAR, BIGINT, VARCHAR, VARCHAR, BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, NUMERIC, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, JSONB, JSONB, BIGINT[], BOOLEAN, JSONB, BOOLEAN);
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
    p_es_evaluativa                     academico_test.bool_sn DEFAULT NULL,
    p_fk_tlv_instrumento_evaluacion     BIGINT        DEFAULT NULL,
    p_descripcion_instrumento           VARCHAR(4000) DEFAULT NULL,
    p_fk_tlv_tipo_evidencia             BIGINT        DEFAULT NULL,
    p_fk_tlv_metodo_valoracion          BIGINT        DEFAULT NULL,
    p_fk_tlv_tipo_calculo               BIGINT        DEFAULT NULL,
    p_influencia                        NUMERIC       DEFAULT NULL,
    p_nota_maxima                       NUMERIC       DEFAULT NULL,
    p_requiere_archivo                  academico_test.bool_sn DEFAULT NULL,
    p_requiere_texto                    academico_test.bool_sn DEFAULT NULL,
    p_genera_evidencias                 academico_test.bool_sn DEFAULT NULL,
    p_requiere_validacion_coordinador   academico_test.bool_sn DEFAULT NULL,
    p_observaciones_docente             VARCHAR(4000) DEFAULT NULL,
    -- NULL = no tocar; array (incl. vacio) = reemplazo completo
    p_materiales                        JSONB         DEFAULT NULL,
    p_adaptaciones                      JSONB         DEFAULT NULL,
    p_fk_tmatriculas                    BIGINT[]      DEFAULT NULL,
    p_asignar_todo_el_grupo             BOOLEAN       DEFAULT FALSE,
    -- NULL = no tocar la recuperacion. Objeto = configurarla. Para QUITARLA
    -- (volver la actividad a normal) usar p_quitar_recuperacion = TRUE.
    p_recuperacion                      JSONB         DEFAULT NULL,
    p_quitar_recuperacion               BOOLEAN       DEFAULT FALSE
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_actual      academico_test.TACTIVIDAD%ROWTYPE;
    v_titulo      VARCHAR(250);
    v_grupo       BIGINT;
    v_inicio      DATE;
    v_cierre      DATE;
    v_fk_tunidad  BIGINT;
    v_instrumento BIGINT;
    v_evaluativa  academico_test.bool_sn;
    v_modo_calc   VARCHAR;
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
    IF p_quitar_recuperacion AND p_recuperacion IS NOT NULL THEN
        RAISE EXCEPTION 'p_quitar_recuperacion es excluyente con p_recuperacion' USING ERRCODE = '22023';
    END IF;
    IF p_recuperacion IS NOT NULL
       AND COALESCE(p_es_evaluativa, v_actual.ES_EVALUATIVA) = 'N' THEN
        RAISE EXCEPTION 'Una actividad de recuperacion debe ser evaluativa' USING ERRCODE = '22023';
    END IF;

    -- Valores resultantes para coherencia/unicidad.
    v_titulo := COALESCE(NULLIF(TRIM(p_titulo), ''), v_actual.TITULO);
    v_grupo  := COALESCE(p_fk_tgrupo, v_actual.FK_TGRUPO);
    v_inicio := COALESCE(p_fecha_inicio, v_actual.FECHA_INICIO);
    v_cierre := COALESCE(p_fecha_cierre, v_actual.FECHA_CIERRE);
    -- Unidad resultante tras aplicar p_desvincular_unidad / p_fk_tunidad,
    -- necesaria para validar la sub-rama de evaluacion mas abajo.
    v_fk_tunidad  := CASE WHEN p_desvincular_unidad THEN NULL
                          ELSE COALESCE(p_fk_tunidad, v_actual.FK_TUNIDAD) END;
    v_instrumento := COALESCE(p_fk_tlv_instrumento_evaluacion, v_actual.FK_TLV_INSTRUMENTO_EVALUACION);
    -- ES_EVALUATIVA resultante (nueva o heredada), mismo criterio de "valor
    -- resultante" que v_fk_tunidad / v_instrumento.
    v_evaluativa  := COALESCE(p_es_evaluativa, v_actual.ES_EVALUATIVA, 'S');

    -- Condicion dinamica "actividad -> ponderacion" (V137). Gate (a): sin
    -- evaluacion no hay peso. Gate (b): el metodo de calculo de la unidad
    -- resultante decide si el % se captura a mano (Ponderar), no aplica
    -- (Promediar) o lo autocalcula el sistema desde NOTA_MAXIMA (Sumatoria).
    IF p_ponderacion IS NOT NULL AND v_evaluativa = 'N' THEN
        RAISE EXCEPTION 'La ponderacion no aplica: la actividad "%" no es evaluativa', v_titulo
            USING ERRCODE = '22023';
    END IF;
    v_modo_calc := CASE WHEN v_fk_tunidad IS NULL THEN NULL
                        ELSE academico_test.fn_unidad_calculo_definitiva_modo(v_fk_tunidad) END;
    IF p_ponderacion IS NOT NULL AND v_modo_calc = 'PROMEDIAR' THEN
        RAISE EXCEPTION 'La ponderacion no aplica: la unidad (%) promedia sus actividades', v_fk_tunidad
            USING ERRCODE = '22023';
    END IF;
    IF p_ponderacion IS NOT NULL AND v_modo_calc = 'SUMATORIA' THEN
        RAISE EXCEPTION 'La ponderacion de la unidad (%) se autocalcula: es una unidad de Sumatoria, envie el puntaje de la actividad (p_nota_maxima) en vez del porcentaje', v_fk_tunidad
            USING ERRCODE = '22023';
    END IF;

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

    -- Sub-rama "evaluacion" (instrumento de evaluacion, condicion dinamica
    -- "actividad -> evaluacion" de V137): solo aplica si, tras el PATCH, la
    -- actividad queda vinculada a una unidad con referente EVALUATIVO. Se
    -- valida contra v_fk_tunidad / v_instrumento (valores resultantes, no
    -- solo los parametros entrantes) para cubrir tanto "fijar instrumento
    -- ahora" como "desvincular la unidad dejando un instrumento heredado".
    IF v_instrumento IS NOT NULL THEN
        IF v_fk_tunidad IS NULL THEN
            RAISE EXCEPTION 'El instrumento de evaluacion (FK_TLV_INSTRUMENTO_EVALUACION) no aplica: la actividad no queda vinculada a una unidad'
                USING ERRCODE = '22023';
        ELSIF NOT academico_test.fn_unidad_referente_evaluativo(v_fk_tunidad) THEN
            RAISE EXCEPTION 'El instrumento de evaluacion (FK_TLV_INSTRUMENTO_EVALUACION) no aplica: el referente curricular de la unidad no es EVALUATIVO'
                USING ERRCODE = '22023';
        END IF;
    END IF;

    -- Unicidad contra la unidad RESULTANTE (v_fk_tunidad, ya calculada
    -- arriba y usada tambien para la sub-rama de evaluacion), NO contra
    -- v_actual.FK_TUNIDAD: con la unidad vieja, mover una actividad de
    -- unidad comparaba contra el bucket equivocado y podia lanzar un 23505
    -- falso (o dejar pasar un duplicado real en la unidad destino).
    IF EXISTS (
        SELECT 1 FROM academico_test.TACTIVIDAD
         WHERE UPPER(TRIM(TITULO)) = UPPER(TRIM(v_titulo))
           AND FK_TUNIDAD       IS NOT DISTINCT FROM v_fk_tunidad
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
           ES_EVALUATIVA                   = COALESCE(p_es_evaluativa, ES_EVALUATIVA),
           FK_TLV_INSTRUMENTO_EVALUACION   = COALESCE(p_fk_tlv_instrumento_evaluacion, FK_TLV_INSTRUMENTO_EVALUACION),
           DESCRIPCION_INSTRUMENTO         = CASE WHEN p_descripcion_instrumento IS NULL THEN DESCRIPCION_INSTRUMENTO
                                                  ELSE NULLIF(TRIM(p_descripcion_instrumento), '') END,
           FK_TLV_TIPO_EVIDENCIA           = COALESCE(p_fk_tlv_tipo_evidencia, FK_TLV_TIPO_EVIDENCIA),
           FK_TLV_METODO_VALORACION        = COALESCE(p_fk_tlv_metodo_valoracion, FK_TLV_METODO_VALORACION),
           FK_TLV_TIPO_CALCULO             = COALESCE(p_fk_tlv_tipo_calculo, FK_TLV_TIPO_CALCULO),
           INFLUENCIA                      = COALESCE(p_influencia, INFLUENCIA),
           NOTA_MAXIMA                     = COALESCE(p_nota_maxima, NOTA_MAXIMA),
           REQUIERE_ARCHIVO                = COALESCE(p_requiere_archivo, REQUIERE_ARCHIVO),
           REQUIERE_TEXTO                  = COALESCE(p_requiere_texto, REQUIERE_TEXTO),
           GENERA_EVIDENCIAS               = COALESCE(p_genera_evidencias, GENERA_EVIDENCIAS),
           REQUIERE_VALIDACION_COORDINADOR = COALESCE(p_requiere_validacion_coordinador, REQUIERE_VALIDACION_COORDINADOR),
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

    -- Sumatoria: el reparto proporcional depende de NOTA_MAXIMA y del
    -- conjunto de actividades del bucket, asi que se recalcula SIEMPRE (no
    -- solo cuando se toco la unidad): editar el puntaje de una actividad
    -- cambia el % de TODAS las de su (unidad, grupo). Se recalcula tambien el
    -- bucket de origen si la unidad o el grupo cambiaron. No-op fuera de
    -- Sumatoria.
    PERFORM academico_test.fn_unidad_ponderacion_recalcular_sumatoria(v_fk_tunidad, v_grupo);
    IF v_actual.FK_TUNIDAD IS NOT NULL
       AND (v_actual.FK_TUNIDAD IS DISTINCT FROM v_fk_tunidad
            OR v_actual.FK_TGRUPO IS DISTINCT FROM v_grupo) THEN
        PERFORM academico_test.fn_unidad_ponderacion_recalcular_sumatoria(
                    v_actual.FK_TUNIDAD, v_actual.FK_TGRUPO);
    END IF;

    -- ORDEN IMPORTA: estudiantes antes que adaptaciones (ver fn_actividad_crear).
    PERFORM academico_test.fn_actividad_estudiantes_asignar(
                p_pk_usuario_solicitante, p_pk_tactividad, p_fk_tmatriculas, p_asignar_todo_el_grupo);
    PERFORM academico_test.fn_actividad_material_reemplazar(
                p_pk_usuario_solicitante, p_pk_tactividad, p_materiales);
    PERFORM academico_test.fn_actividad_adaptacion_reemplazar(
                p_pk_usuario_solicitante, p_pk_tactividad, p_adaptaciones);

    -- Recuperacion: solo si el caller la toco (objeto = configurar; flag = quitar).
    IF p_quitar_recuperacion THEN
        PERFORM academico_test.fn_actividad_recuperacion_configurar(
                    p_pk_usuario_solicitante, p_pk_tactividad, NULL);
    ELSIF p_recuperacion IS NOT NULL THEN
        PERFORM academico_test.fn_actividad_recuperacion_configurar(
                    p_pk_usuario_solicitante, p_pk_tactividad, p_recuperacion);
    END IF;

    RETURN p_pk_tactividad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, BOOLEAN, BIGINT, DATE, DATE, NUMERIC, VARCHAR, BIGINT, VARCHAR, academico_test.bool_sn, BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, NUMERIC, academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, VARCHAR, JSONB, JSONB, BIGINT[], BOOLEAN, JSONB, BOOLEAN)
    IS 'PATCH parcial de una actividad (gate EDITAR sobre PLANEADOR): cada parametro NULL preserva el valor actual. Unidad/ponderacion se delegan en fn_unidad_actividad_vincular / _ponderacion_set / _desvincular (V223) para que la regla del 100% viva en un solo sitio; p_desvincular_unidad=TRUE es excluyente con p_fk_tunidad/p_ponderacion. Recuperacion: p_recuperacion (objeto) la configura via fn_actividad_recuperacion_configurar, p_quitar_recuperacion=TRUE la elimina (vuelve la actividad a normal); son excluyentes y NULL/FALSE no la tocan. p_materiales / p_adaptaciones / p_fk_tmatriculas NULL = no tocar, array = reemplazo completo. Revalida fechas, catalogos y unicidad (titulo, unidad, grupo, jerarquia). El FK_TLV_INSTRUMENTO_EVALUACION resultante (nuevo o heredado) solo se admite si la unidad resultante (nueva, heredada, o NULL si p_desvincular_unidad) tiene referente curricular EVALUATIVO (fn_unidad_referente_evaluativo, condicion dinamica "actividad -> evaluacion" de V137); en otro caso lanza 22023. PONDERACION (condicion dinamica "actividad -> ponderacion" de V137, evaluada contra los valores RESULTANTES): se rechaza p_ponderacion (22023) si la actividad queda NO evaluativa (ES_EVALUATIVA resultante = ''N''), si la unidad resultante PROMEDIA, o si calcula por SUMATORIA -- ahi el docente envia p_nota_maxima y el % lo autocalcula fn_unidad_ponderacion_recalcular_sumatoria (V223), que se invoca SIEMPRE al final sobre el bucket resultante (y sobre el de origen si cambio la unidad o el grupo), porque editar el puntaje de una actividad cambia el % de todas las de su (unidad, grupo). Retorna PK_TACTIVIDAD. V224.';

-- ---------------------------------------------------------------------------
-- fn_actividad_eliminar — soft delete en cascada.
--
-- DECISION DE CASCADA (documentada): se arrastran TODOS los satelites
-- activos de la actividad, no se dejan huerfanos-mudos. Criterio: ninguno de
-- ellos tiene sentido ni pantalla propia sin su actividad (a diferencia de
-- TACTIVIDAD respecto a TUNIDAD, que SI sigue viva desvinculada -- por eso
-- fn_unidad_eliminar bloquea en vez de cascadear). Es el mismo criterio de
-- fn_unidad_eliminar (V216) con sus objetivos/contenidos/rubrica y de
-- fn_unidad_enunciado_quitar (V136), que arrastra las TACTIVIDAD_EVIDENCIA
-- que dependian del enunciado que se quita.
--
-- Se desactivan, en orden hijo -> padre:
--   * capturas de calificacion por estudiante (TACTIVIDAD_RUBRICA_EVALUACION,
--     TACTIVIDAD_COTEJO_EVALUACION, TACTIVIDAD_ESCALA_EVALUACION),
--     TACTIVIDAD_NOTA y TACTIVIDAD_SOPORTE — todos cuelgan de
--     TACTIVIDAD_ESTUDIANTE;
--   * el pivote TACTIVIDAD_ADAPTACION_ESTUDIANTE y luego TACTIVIDAD_ESTUDIANTE;
--   * la definicion del instrumento (V226): niveles -> criterios de rubrica,
--     items de cotejo, niveles -> escala;
--   * materiales, adaptaciones, recuperacion (1:1), evidencias y criterios de
--     unidad (V136);
--   * y por ultimo la propia TACTIVIDAD.
--
-- BLOQUEOS (23503) — dos casos que NO se cascadean:
--   * la actividad tiene NOTAS registradas (TACTIVIDAD_NOTA.CALIFICACION
--     IS NOT NULL para alguno de sus estudiantes): borrar una actividad ya
--     calificada perderia informacion de evaluacion real, a diferencia de
--     una TACTIVIDAD_NOTA "vacia" (fila creada por
--     fn_actividad_nota_get_or_create pero sin CALIFICACION todavia, p.ej.
--     una rubrica bulk a medio cubrir) que si se puede arrastrar sin perder
--     nada. El caller debe reactivar/anular las notas antes (no existe hoy
--     una funcion para eso; se documenta como pendiente).
--   * otra actividad de recuperacion ACTIVA apunta a esta como su
--     TACTIVIDAD_RECUPERACION.FK_TACTIVIDAD_RECUPERAR, borrarla dejaria esa
--     otra actividad recuperando una nota inexistente. Se exige resolverla
--     primero, mismo espiritu que el bloqueo de fn_unidad_eliminar.
--
-- Las tablas de V136 (TACTIVIDAD_EVIDENCIA / TACTIVIDAD_CRITERIO_UNIDAD) y
-- las de captura se referencian por nombre dentro de un cuerpo plpgsql: se
-- resuelven en EJECUCION, asi que el orden de aplicacion de las migraciones
-- no importa aqui (mismo criterio documentado en V227).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_eliminar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_active       BOOLEAN;
    v_titulo       VARCHAR;
    v_dependientes BIGINT := 0;
    v_estudiantes  BIGINT := 0;
    v_fk_tunidad   BIGINT;
    v_fk_tgrupo    BIGINT;
BEGIN
    SELECT ACTIVE, TITULO, FK_TUNIDAD, FK_TGRUPO
      INTO v_active, v_titulo, v_fk_tunidad, v_fk_tgrupo
      FROM academico_test.TACTIVIDAD
     WHERE PK_TACTIVIDAD = p_pk_tactividad;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'ELIMINAR'
    );

    IF v_active = FALSE THEN
        RAISE EXCEPTION 'La actividad "%" ya se encuentra inactiva', v_titulo USING ERRCODE = '22023';
    END IF;

    -- Bloqueo: la actividad tiene notas registradas (CALIFICACION no nula
    -- para alguno de sus estudiantes). Una TACTIVIDAD_NOTA "vacia" (sin
    -- CALIFICACION) SI se puede arrastrar, no cuenta aqui.
    IF EXISTS (
        SELECT 1
          FROM academico_test.TACTIVIDAD_NOTA n
          JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae ON ae.PK_TACTIVIDAD_ESTUDIANTE = n.FK_TACTIVIDAD_ESTUDIANTE
         WHERE ae.FK_TACTIVIDAD = p_pk_tactividad
           AND ae.ACTIVE = TRUE
           AND n.ACTIVE = TRUE
           AND n.CALIFICACION IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'La actividad "%" tiene notas registradas; no se puede eliminar', v_titulo
            USING ERRCODE = '23503',
                  HINT = 'Anule o corrija las calificaciones de los estudiantes antes de eliminar la actividad';
    END IF;

    -- Bloqueo: actividades de recuperacion activas que recuperan a esta.
    SELECT COUNT(*) INTO v_dependientes
      FROM academico_test.TACTIVIDAD_RECUPERACION r
      JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = r.FK_TACTIVIDAD
     WHERE r.FK_TACTIVIDAD_RECUPERAR = p_pk_tactividad
       AND r.ACTIVE = TRUE AND a.ACTIVE = TRUE;
    IF v_dependientes > 0 THEN
        RAISE EXCEPTION 'La actividad "%" es recuperada por % actividad(es) de recuperacion activa(s); no se puede eliminar', v_titulo, v_dependientes
            USING ERRCODE = '23503',
                  HINT = 'Reconfigure o elimine esas actividades de recuperacion (fn_actividad_actualizar con p_quitar_recuperacion, o fn_actividad_eliminar) y reintente';
    END IF;

    -- 1. Capturas de calificacion por estudiante (V22/V226/V227).
    UPDATE academico_test.TACTIVIDAD_RUBRICA_EVALUACION re
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE re.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
       AND ae.FK_TACTIVIDAD = p_pk_tactividad AND re.ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_COTEJO_EVALUACION ce
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE ce.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
       AND ae.FK_TACTIVIDAD = p_pk_tactividad AND ce.ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_ESCALA_EVALUACION ee
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE ee.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
       AND ae.FK_TACTIVIDAD = p_pk_tactividad AND ee.ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_NOTA n
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
       AND ae.FK_TACTIVIDAD = p_pk_tactividad AND n.ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_SOPORTE s
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE s.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
       AND ae.FK_TACTIVIDAD = p_pk_tactividad AND s.ACTIVE = TRUE;

    -- 2. Pivote de adaptacion por estudiante y luego los estudiantes.
    UPDATE academico_test.TACTIVIDAD_ADAPTACION_ESTUDIANTE ade
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE ade.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
       AND ae.FK_TACTIVIDAD = p_pk_tactividad AND ade.ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_ESTUDIANTE
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_estudiantes = ROW_COUNT;

    -- 3. Definicion del instrumento (V226): hijos antes que padres.
    UPDATE academico_test.TACTIVIDAD_RUBRICA_NIVEL rn
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TACTIVIDAD_RUBRICA_CRITERIO rc
     WHERE rn.FK_TACTIVIDAD_RUBRICA_CRITERIO = rc.PK_TACTIVIDAD_RUBRICA_CRITERIO
       AND rc.FK_TACTIVIDAD = p_pk_tactividad AND rn.ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_RUBRICA_CRITERIO
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_COTEJO_ITEM
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_ESCALA_NIVEL en
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TACTIVIDAD_ESCALA e
     WHERE en.FK_TACTIVIDAD_ESCALA = e.PK_TACTIVIDAD_ESCALA
       AND e.FK_TACTIVIDAD = p_pk_tactividad AND en.ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_ESCALA
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;

    -- 4. Satelites directos de la actividad.
    UPDATE academico_test.TACTIVIDAD_MATERIAL
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_ADAPTACION
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_RECUPERACION
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_EVIDENCIA
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_CRITERIO_UNIDAD
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;

    -- 5. La actividad. Se suelta tambien de la unidad (FK_TUNIDAD /
    --    PONDERACION a NULL) para que su peso deje de ocupar cupo en la
    --    regla del 100% por (unidad, grupo) del trigger de V223.
    UPDATE academico_test.TACTIVIDAD
       SET ACTIVE      = FALSE,
           FK_TUNIDAD  = NULL,
           PONDERACION = NULL,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD = p_pk_tactividad;

    -- 6. Si la unidad de la que salio calcula por SUMATORIA, el reparto
    --    proporcional de las actividades que quedan cambia (una menos en el
    --    denominador). Se usa la unidad/grupo capturados ANTES del paso 5,
    --    que ya puso FK_TUNIDAD en NULL. No-op fuera de Sumatoria.
    PERFORM academico_test.fn_unidad_ponderacion_recalcular_sumatoria(v_fk_tunidad, v_fk_tgrupo);

    RAISE NOTICE 'Soft delete TACTIVIDAD=% (autor: %): estudiantes_asignados=%',
        p_pk_tactividad, p_pk_usuario_solicitante, v_estudiantes;

    RETURN p_pk_tactividad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_eliminar(BIGINT, BIGINT)
    IS 'Soft delete (ACTIVE=FALSE) de una TACTIVIDAD (gate ELIMINAR sobre PLANEADOR), en cascada sobre TODOS sus satelites activos -- ninguno tiene sentido sin su actividad: capturas de calificacion (TACTIVIDAD_RUBRICA/COTEJO/ESCALA_EVALUACION), TACTIVIDAD_NOTA, TACTIVIDAD_SOPORTE, TACTIVIDAD_ADAPTACION_ESTUDIANTE, TACTIVIDAD_ESTUDIANTE, la definicion del instrumento de V226 (niveles->criterios de rubrica, items de cotejo, niveles->escala), materiales, adaptaciones, la fila 1:1 de recuperacion, y las relaciones de V136 (TACTIVIDAD_EVIDENCIA, TACTIVIDAD_CRITERIO_UNIDAD). Ademas suelta la actividad de su unidad (FK_TUNIDAD y PONDERACION a NULL) para liberar cupo en la regla del 100% por (unidad, grupo) de V223, y si esa unidad calculaba por SUMATORIA recalcula el % de las actividades que quedan en el bucket (fn_unidad_ponderacion_recalcular_sumatoria, V223). Se BLOQUEA (23503) si la actividad tiene notas registradas (TACTIVIDAD_NOTA.CALIFICACION IS NOT NULL para alguno de sus estudiantes activos -- una nota "vacia" sin CALIFICACION si se arrastra) o si otra actividad de recuperacion ACTIVA la referencia como TACTIVIDAD_RECUPERACION.FK_TACTIVIDAD_RECUPERAR. 22023 si ya estaba inactiva, P0002 si no existe. Retorna PK_TACTIVIDAD. V224.';

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
           -- Buscador unico "nombre, nivel educativo o instrumento".
           --
           -- Rama 1 (TITULO+DESCRIPCION): la expresion es IDENTICA a la de
           -- idx_tactividad_busqueda_trgm para que el planner pueda usarlo.
           --
           -- Ramas 2 y 3 (nivel de ensenanza via la unidad -> grado ->
           -- TNIVEL_ENSENANZA, e instrumento via TLISTA_VALOR.NOMBRE): NO
           -- estan cubiertas por ese indice -- son un post-filtro por EXISTS
           -- sobre catalogos pequeños, que solo se evalua cuando p_search
           -- viene informado y siempre dentro de este mismo CTE base, ya
           -- acotado por los demas filtros (asignatura / grupo / unidad /
           -- tipo / instrumento / ventana de fechas) y por la paginacion.
           -- Honestidad de rendimiento: al ser un OR, esta rama impide el
           -- Bitmap Index Scan puro del trigram; ver COMMENT ON FUNCTION.
           AND (p_search IS NULL
                OR (COALESCE(a.TITULO,'') || ' ' || COALESCE(a.DESCRIPCION,''))
                       ILIKE '%' || p_search || '%'
                OR EXISTS (
                       SELECT 1
                         FROM academico_test.TUNIDAD u2
                         JOIN academico_test.TGRADO g2            ON g2.PK_TGRADO = u2.FK_TGRADO
                         JOIN academico_test.TNIVEL_ENSENANZA ne2 ON ne2.PK_NIVEL_ENSENANZA = g2.FK_TNIVEL_ENSENANZA
                        WHERE u2.PK_TUNIDAD = a.FK_TUNIDAD
                          AND ne2.NOMBRE ILIKE '%' || p_search || '%')
                OR EXISTS (
                       SELECT 1
                         FROM academico_test.TLISTA_VALOR lvs
                        WHERE lvs.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
                          AND lvs.NOMBRE ILIKE '%' || p_search || '%'))
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
    IS 'Pagina de actividades del Planeador (gate VER). Filtros indexados: asignatura, grupo, unidad, tipo, instrumento y ventana de fechas. p_search es el buscador unico "nombre, nivel educativo o instrumento": matchea (a) TITULO+DESCRIPCION con la expresion identica a la de idx_tactividad_busqueda_trgm, (b) el NOMBRE del nivel de ensenanza de la actividad (via FK_TUNIDAD -> TUNIDAD.FK_TGRADO -> TGRADO.FK_TNIVEL_ENSENANZA -> TNIVEL_ENSENANZA; solo aplica si la actividad tiene unidad) y (c) el NOMBRE del instrumento (TLISTA_VALOR de FK_TLV_INSTRUMENTO_EVALUACION). HONESTIDAD DE RENDIMIENTO: solo (a) puede entrar por el indice trigram; (b) y (c) son un post-filtro por EXISTS NO indexado sobre catalogos pequeños que, al ir en OR, impide el Bitmap Index Scan puro del trigram cuando p_search viene informado -- se evalua dentro del mismo CTE base ya acotado por los demas filtros y por LIMIT/OFFSET, nunca sobre un seq scan del universo sin filtrar. p_estados filtra por el estado DERIVADO (fn_actividad_estado) con p_dias_gracia (default 2). Orden (whitelist): fecha_inicio|fecha_cierre|fecha_creacion|titulo|ponderacion, cualquier otro valor cae a fecha_inicio. Devuelve nombres resueltos (asignatura, area, unidad, grupo, tipo, instrumento), el estado derivado y el progreso de evaluacion (asignados/evaluados/%). Optimizacion: el CTE base pagina tocando solo TACTIVIDAD y los joins + el LATERAL de progreso corren unicamente contra las filas de la pagina. total_count via COUNT(*) OVER(). V224.';

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
    recuperacion                    JSONB,
    campos_disponibles              JSONB,
    unidad_configuracion            JSONB,
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
           -- Config de recuperacion (NULL si la actividad no es de recuperacion).
           (SELECT jsonb_build_object(
                       'pk',                    r.PK_TACTIVIDAD_RECUPERACION,
                       'destino',               r.FK_TLV_DESTINO_RECUPERACION,
                       'destinoNombre',         ldr.NOMBRE,
                       'fkActividadRecuperar',  r.FK_TACTIVIDAD_RECUPERAR,
                       'actividadRecuperarTitulo', ar.TITULO,
                       'tipoAplicacion',        r.FK_TLV_TIPO_APLICACION_RECUPERACION,
                       'tipoAplicacionNombre',  lap2.NOMBRE,
                       'tipoCalculo',           r.FK_TLV_TIPO_CALCULO_RECUPERACION,
                       'tipoCalculoNombre',     ltc.NOMBRE,
                       'valorPonderacion',      r.VALOR_PONDERACION_RECUPERACION)
              FROM academico_test.TACTIVIDAD_RECUPERACION r
              LEFT JOIN academico_test.TLISTA_VALOR ldr  ON ldr.PK_LISTA_VALOR = r.FK_TLV_DESTINO_RECUPERACION
              LEFT JOIN academico_test.TLISTA_VALOR lap2 ON lap2.PK_LISTA_VALOR = r.FK_TLV_TIPO_APLICACION_RECUPERACION
              LEFT JOIN academico_test.TLISTA_VALOR ltc  ON ltc.PK_LISTA_VALOR = r.FK_TLV_TIPO_CALCULO_RECUPERACION
              LEFT JOIN academico_test.TACTIVIDAD ar     ON ar.PK_TACTIVIDAD = r.FK_TACTIVIDAD_RECUPERAR
             WHERE r.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND r.ACTIVE = TRUE),
           -- Dependencias dinamicas del formulario (V137): calculadas solo
           -- para esta fila (0 o 1), no en fn_actividad_listar -- ver nota
           -- de estilo en la cabecera de esa funcion.
           academico_test.fn_actividad_campos_disponibles(p_pk_usuario_solicitante, a.PK_TACTIVIDAD),
           academico_test.fn_actividad_unidad_configuracion(p_pk_usuario_solicitante, a.PK_TACTIVIDAD),
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
    IS 'Detalle completo de una actividad (gate VER): todos los campos de TACTIVIDAD con los nombres de catalogo resueltos, el estado derivado (fn_actividad_estado), el progreso de evaluacion (asignados/evaluados en un solo LATERAL), los materiales de apoyo y las adaptaciones curriculares como JSONB, y la config de recuperacion (columna "recuperacion": objeto con destino/tipoAplicacion/tipoCalculo/valorPonderacion + nombres resueltos, o NULL si no es de recuperacion). campos_disponibles = fn_actividad_campos_disponibles (dependencias dinamicas actividad->criterio / actividad->evaluacion, V137); unidad_configuracion = fn_actividad_unidad_configuracion (snapshot de la unidad relacionada, o {tieneUnidad:false}, V137) -- ambas calculadas solo para esta fila (detalle), no en fn_actividad_listar. SETOF 0 o 1 fila (incluye inactivas). V224.';

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
