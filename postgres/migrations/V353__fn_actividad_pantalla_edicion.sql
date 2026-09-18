-- ===========================================================================
-- V353 -- fn_actividad_pantalla_edicion: un solo endpoint para la pantalla
-- "editar actividad" del front, en vez de dos round-trips encadenados.
--
-- ---------------------------------------------------------------------------
-- POR QUE
-- ---------------------------------------------------------------------------
-- El front (`PlaneadorEditarActividadPage`) hoy pega, siempre en cadena, a:
--   GET /planeador/actividades/:id             (fn_actividad_buscar_por_pk)
--   GET /planeador/actividades/:id/instrumento (fn_actividad_instrumento_obtener)
-- La segunda espera el `id` de la primera y solo se omite si la actividad no
-- es evaluativa -- en la practica, siempre se dispara. Es el caso mas claro
-- de "esto podria ser un solo endpoint" de todo el modulo Planeador: mismo
-- pk_tactividad, mismo gate de alcance (las dos llaman a
-- fn_planeador_assert_alcance(..., 'VER', ...) por separado), una sola
-- pantalla.
--
-- ---------------------------------------------------------------------------
-- POR QUE UNA FUNCION NUEVA Y NO TOCAR LAS DOS EXISTENTES
-- ---------------------------------------------------------------------------
-- fn_actividad_buscar_por_pk y fn_actividad_instrumento_obtener siguen
-- existiendo tal cual: las usan otras pantallas (el detalle solo, o el
-- instrumento solo, por ejemplo desde `dialog-*` que no necesitan el resto).
-- Esta funcion nueva es pura COMPOSICION -- llama a las dos de siempre y
-- reempaqueta su resultado -- no reimplementa ninguna regla de negocio ni
-- duplica una sola consulta a TACTIVIDAD/TACTIVIDAD_RUBRICA_*/etc.
--
-- ---------------------------------------------------------------------------
-- POR QUE EL DTO SE REESCRIBE EN VEZ DE PEGAR LAS DOS FILAS TAL CUAL
-- ---------------------------------------------------------------------------
-- Las dos funciones devuelven filas de SQL casi crudas: columnas sueltas en
-- snake_case (`fk_tlv_tipo_actividad`, `tipo_actividad`) en vez de un objeto
-- (`tipoActividad: {id, nombre}`), y sin agrupar por concepto (fechas,
-- banderas S/N, catalogos). Es exactamente el patron que hace que el front
-- tenga que mapear 60+ campos a mano (`use-actividad-detalle-query.ts`).
-- Esta funcion devuelve UN JSONB ya en camelCase y anidado por concepto:
--
-- {
--   "actividad": {
--     "id", "titulo", "descripcion", "estado", "active",
--     "asignatura": {"id","nombre"}, "unidad": {"id","nombre"},
--     "grupo": {"id","nombre"}, "grado": {"id","nombre","codigo","grupo"},
--     "tipoActividad": {"id","nombre"}, "jerarquia": {"id","nombre"},
--     "modalidad": {"id","nombre"},
--     "fechas": {"inicio","cierre","calificado","publicacion"},
--     "ponderacion", "influencia", "notaMaxima",
--     "duracionEstimada", "semanaCronograma", "materialRequerido",
--     "banderas": {
--       "esEvaluativa", "esRecuperacion", "requiereArchivo",
--       "requiereTexto", "generaEvidencias", "requiereValidacionCoordinador"
--     },
--     "observacionesDocente",
--     "estudiantes": {"asignados", "evaluados"}
--   },
--   "materiales": [...],       -- tal cual venia (ya es un array limpio)
--   "adaptaciones": [...],     -- idem
--   "evidencias": [...],      -- TACTIVIDAD_EVIDENCIA ya relacionadas
--   "criterios": [...],       -- TACTIVIDAD_CRITERIO_UNIDAD ya relacionados
--   "estudiantes": [...],     -- TACTIVIDAD_ESTUDIANTE asignados, con su nota/observacion
--   "recuperacion": {...} | null,
--   "instrumento": {
--     "tipo": {"valor","nombre"},
--     "definicion": {...} | [...] | null
--   } | null,                  -- null si la actividad no tiene instrumento
--                              -- definido (FK_TLV_INSTRUMENTO_EVALUACION NULL)
--   "camposDisponibles": {...},   -- se deja tal cual: ya es camelCase (V214.2)
--   "unidadConfiguracion": {...}  -- idem (fn_actividad_unidad_configuracion)
-- }
--
-- Las banderas S/N (`academico_test.bool_sn`) se convierten a boolean real:
-- el front las convertia el mismo con `=== 'S'` en cuatro sitios distintos
-- (`use-actividad-detalle-query.ts`) -- se resuelve una sola vez, en el
-- servidor.
--
-- ---------------------------------------------------------------------------
-- GATE DE ALCANCE
-- ---------------------------------------------------------------------------
-- Se comprueba UNA sola vez aca (antes de llamar a las dos funciones
-- compuestas), igual que hace cada una de ellas por separado -- no se pierde
-- seguridad, se evita el chequeo duplicado.
-- ===========================================================================

SET search_path TO public;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_pantalla_edicion(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_dias_gracia            INT DEFAULT 2
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_det   RECORD;
    v_instr RECORD;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, NULL, p_pk_tactividad
    );

    SELECT * INTO v_det
      FROM academico_test.fn_actividad_buscar_por_pk(
               p_pk_usuario_solicitante, p_pk_tactividad, p_dias_gracia);

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;

    -- El instrumento SIEMPRE se resuelve: si la actividad no tiene
    -- FK_TLV_INSTRUMENTO_EVALUACION, fn_actividad_instrumento_obtener ya
    -- devuelve una fila con instrumento/definicion en NULL (LEFT JOIN contra
    -- TLISTA_VALOR) -- no hace falta condicionar por es_evaluativa aca, y
    -- evita que un cambio futuro en esa regla desincronice a las dos.
    SELECT * INTO v_instr
      FROM academico_test.fn_actividad_instrumento_obtener(
               p_pk_usuario_solicitante, p_pk_tactividad);

    RETURN jsonb_build_object(
        'actividad', jsonb_build_object(
            'id',           v_det.pk_tactividad,
            'titulo',       v_det.titulo,
            'descripcion',  v_det.descripcion,
            'estado',       v_det.estado,
            'active',       v_det.active,
            'asignatura',   CASE WHEN v_det.fk_tasignatura IS NULL THEN NULL
                                 ELSE jsonb_build_object('id', v_det.fk_tasignatura, 'nombre', v_det.asignatura) END,
            'unidad',       CASE WHEN v_det.fk_tunidad IS NULL THEN NULL
                                 ELSE jsonb_build_object('id', v_det.fk_tunidad, 'nombre', v_det.unidad) END,
            'grupo',        CASE WHEN v_det.fk_tgrupo IS NULL THEN NULL
                                 ELSE jsonb_build_object('id', v_det.fk_tgrupo, 'nombre', v_det.grupo) END,
            'grado',        CASE WHEN v_det.fk_tgrado IS NULL THEN NULL
                                 ELSE jsonb_build_object(
                                          'id', v_det.fk_tgrado, 'nombre', v_det.grado,
                                          'codigo', v_det.grado_codigo, 'grupo', v_det.grado_grupo) END,
            'tipoActividad', CASE WHEN v_det.fk_tlv_tipo_actividad IS NULL THEN NULL
                                  ELSE jsonb_build_object('id', v_det.fk_tlv_tipo_actividad, 'nombre', v_det.tipo_actividad) END,
            'jerarquia',    CASE WHEN v_det.fk_tlv_jerarquia IS NULL THEN NULL
                                 ELSE jsonb_build_object('id', v_det.fk_tlv_jerarquia, 'nombre', v_det.jerarquia) END,
            'modalidad',    CASE WHEN v_det.fk_tlv_modalidad IS NULL THEN NULL
                                 ELSE jsonb_build_object('id', v_det.fk_tlv_modalidad, 'nombre', v_det.modalidad) END,
            'fechas', jsonb_build_object(
                'inicio',       v_det.fecha_inicio,
                'cierre',       v_det.fecha_cierre,
                'calificado',   v_det.fecha_calificado,
                'publicacion',  v_det.fecha_publicacion
            ),
            'ponderacion',       v_det.ponderacion,
            'influencia',        v_det.influencia,
            'notaMaxima',        v_det.nota_maxima,
            'duracionEstimada',  v_det.duracion_estimada,
            'semanaCronograma',  v_det.semana_cronograma,
            'materialRequerido', v_det.material_requerido,
            'descripcionInstrumento', v_det.descripcion_instrumento,
            -- Catalogos sueltos que ya traia el detalle (independientes del
            -- bloque `instrumento` de abajo, que es la DEFINICION completa):
            -- tipo de evidencia / metodo de valoracion / tipo de calculo que
            -- la actividad tiene fijados, incluso si el instrumento en si
            -- todavia no se definio.
            'tipoEvidencia',     CASE WHEN v_det.fk_tlv_tipo_evidencia IS NULL THEN NULL
                                      ELSE jsonb_build_object('id', v_det.fk_tlv_tipo_evidencia, 'nombre', v_det.tipo_evidencia) END,
            'metodoValoracion',  CASE WHEN v_det.fk_tlv_metodo_valoracion IS NULL THEN NULL
                                      ELSE jsonb_build_object('id', v_det.fk_tlv_metodo_valoracion, 'nombre', v_det.metodo_valoracion) END,
            'tipoCalculo',       CASE WHEN v_det.fk_tlv_tipo_calculo IS NULL THEN NULL
                                      ELSE jsonb_build_object('id', v_det.fk_tlv_tipo_calculo, 'nombre', v_det.tipo_calculo) END,
            'banderas', jsonb_build_object(
                'esEvaluativa',                  v_det.es_evaluativa = 'S',
                'esRecuperacion',                v_det.es_recuperacion = 'S',
                'requiereArchivo',               v_det.requiere_archivo = 'S',
                'requiereTexto',                 v_det.requiere_texto = 'S',
                'generaEvidencias',              v_det.genera_evidencias = 'S',
                'requiereValidacionCoordinador',  v_det.requiere_validacion_coordinador = 'S'
            ),
            'observacionesDocente', v_det.observaciones_docente,
            'estudiantes', jsonb_build_object(
                'asignados', v_det.estudiantes_asignados,
                'evaluados', v_det.estudiantes_evaluados
            )
        ),
        'materiales',          v_det.materiales,
        'adaptaciones',        v_det.adaptaciones,
        'evidencias',          v_det.evidencias,
        'criterios',           v_det.criterios,
        'estudiantes',         v_det.estudiantes,
        'recuperacion',        v_det.recuperacion,
        'instrumento',         CASE WHEN v_instr.instrumento IS NULL THEN NULL
                                    ELSE jsonb_build_object(
                                             'tipo', jsonb_build_object(
                                                 'valor',  v_instr.instrumento,
                                                 'nombre', v_instr.instrumento_nombre
                                             ),
                                             'definicion', v_instr.definicion
                                         ) END,
        'camposDisponibles',   v_det.campos_disponibles,
        'unidadConfiguracion', v_det.unidad_configuracion
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Endpoint: GET /planeador/actividades/:ID/pantalla-edicion
-- ---------------------------------------------------------------------------
-- No reemplaza a GET /planeador/actividades/:ID ni a .../instrumento (otras
-- pantallas los siguen usando sueltos): es una ruta ADICIONAL, propia de
-- PlaneadorEditarActividadPage. `DIAS_GRACIA` se deja opcional igual que en
-- el detalle original.
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-planeador-actividad-pantalla-edicion',
    'SELECT academico_test.fn_actividad_pantalla_edicion(
        public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
        CAST(:PARAM.ID AS BIGINT),
        COALESCE(CAST(:QUERY.DIAS_GRACIA AS INT), 2)
    ) AS pantalla',
    'postgres', false, false,
    m.id_microservice,
    '/planeador/actividades/:ID/pantalla-edicion', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT", "QUERY.DIAS_GRACIA": "INTEGER"}'::jsonb,
    NULL,
    'V353 -- DTO compuesto para PlaneadorEditarActividadPage: actividad + instrumento en una sola llamada, ya en camelCase y anidado por concepto. Reemplaza, PARA ESA PANTALLA, la cadena GET .../:ID + GET .../:ID/instrumento. Incluye ademas evidencias (TACTIVIDAD_EVIDENCIA: [{pk, fkReferenteEnunciado, texto, fkPadre, textoPadre}]) y criterios (TACTIVIDAD_CRITERIO_UNIDAD: [{pk, fkTcriterioUnidad, descripcion, codigo, orden}]) ya relacionados, para poder pre-marcarlos al reabrir la actividad y para conocer el pk que exigen PATCH /planeador/actividades/evidencias/:ID y PATCH /planeador/actividades/criterios/:ID. Y estudiantes ([{pkTactividadEstudiante, pkTmatricula, fkTestudiante, estudiante, calificacion, calificable, observacion}]): los asignados, con el pk de la asignacion que piden calificar, observar y las adaptaciones.',
    NULL,
    NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

-- role_query: mismos roles que ya pueden ver el detalle de la actividad
-- (GET /planeador/actividades/:ID) -- "quien puede ver la actividad puede
-- ver esta vista compuesta de la misma actividad", ningun permiso nuevo.
INSERT INTO public.role_query (role_id, query_id)
SELECT rq.role_id, q_new.id_query
  FROM public.role_query rq
  JOIN public.query q_old ON q_old.path_template = '/planeador/actividades/:ID'
                          AND q_old.http_method = 'GET'
                          AND q_old.id_query = rq.query_id
  JOIN public.query q_new ON q_new.uuid = 'q-planeador-actividad-pantalla-edicion'
 WHERE NOT EXISTS (
     SELECT 1 FROM public.role_query rq2
      WHERE rq2.query_id = q_new.id_query AND rq2.role_id = rq.role_id
 );

COMMENT ON FUNCTION academico_test.fn_actividad_pantalla_edicion(BIGINT, BIGINT, INT)
    IS 'DTO compuesto de la pantalla "editar actividad": compone fn_actividad_buscar_por_pk (V224) y fn_actividad_instrumento_obtener en UN JSONB ya en camelCase y anidado por concepto (actividad{...}, materiales, adaptaciones, evidencias, criterios, recuperacion, instrumento, camposDisponibles, unidadConfiguracion), con las banderas S/N convertidas a boolean. No reimplementa ninguna regla: solo reempaqueta. evidencias y criterios son las relaciones ACTIVE que ya tiene la actividad, con el pk DE LA RELACION -- el que exigen fn_actividad_evidencia_quitar / fn_actividad_criterio_quitar (V214.1) --, para que al reabrir la actividad se puedan pre-marcar y quitar. Gate VER (fn_planeador_assert_alcance) una sola vez. P0002 si la actividad no existe. V353.';

-- La fila de arriba se inserta con ON CONFLICT DO NOTHING: donde ya existe,
-- editar el INSERT no la actualiza. Se reconcilia el detail aparte.
UPDATE public.query q
   SET detail = 'V353 -- DTO compuesto para PlaneadorEditarActividadPage: actividad + instrumento en una sola llamada, ya en camelCase y anidado por concepto. Reemplaza, PARA ESA PANTALLA, la cadena GET .../:ID + GET .../:ID/instrumento. Incluye ademas evidencias (TACTIVIDAD_EVIDENCIA: [{pk, fkReferenteEnunciado, texto, fkPadre, textoPadre}]) y criterios (TACTIVIDAD_CRITERIO_UNIDAD: [{pk, fkTcriterioUnidad, descripcion, codigo, orden}]) ya relacionados, para poder pre-marcarlos al reabrir la actividad y para conocer el pk que exigen PATCH /planeador/actividades/evidencias/:ID y PATCH /planeador/actividades/criterios/:ID. Y estudiantes ([{pkTactividadEstudiante, pkTmatricula, fkTestudiante, estudiante, calificacion, calificable, observacion}]): los asignados, con el pk de la asignacion que piden calificar, observar y las adaptaciones.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/:ID/pantalla-edicion'
   AND q.http_method     = 'GET'
   AND q.detail IS DISTINCT FROM 'V353 -- DTO compuesto para PlaneadorEditarActividadPage: actividad + instrumento en una sola llamada, ya en camelCase y anidado por concepto. Reemplaza, PARA ESA PANTALLA, la cadena GET .../:ID + GET .../:ID/instrumento. Incluye ademas evidencias (TACTIVIDAD_EVIDENCIA: [{pk, fkReferenteEnunciado, texto, fkPadre, textoPadre}]) y criterios (TACTIVIDAD_CRITERIO_UNIDAD: [{pk, fkTcriterioUnidad, descripcion, codigo, orden}]) ya relacionados, para poder pre-marcarlos al reabrir la actividad y para conocer el pk que exigen PATCH /planeador/actividades/evidencias/:ID y PATCH /planeador/actividades/criterios/:ID. Y estudiantes ([{pkTactividadEstudiante, pkTmatricula, fkTestudiante, estudiante, calificacion, calificable, observacion}]): los asignados, con el pk de la asignacion que piden calificar, observar y las adaptaciones.';
