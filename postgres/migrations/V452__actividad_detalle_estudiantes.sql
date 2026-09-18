-- ===========================================================================
-- V452 — el detalle de la actividad trae sus estudiantes asignados.
--
-- Que hace: fn_actividad_buscar_por_pk gana la columna estudiantes (los
-- TACTIVIDAD_ESTUDIANTE activos con el pk de la asignacion y su nota u
-- observacion) y fn_actividad_pantalla_edicion la expone. Con eso el detalle
-- devuelve todo lo relacionado a la actividad en una sola llamada.
-- Por que aqui y no en V224/V353: re-ejecutar V224 arrastra V251 y su cadena;
-- una migracion posterior aplica limpia. Ambas quedan muertas para estas dos
-- funciones. V272 (exportar) lee la fila por nombre y no se ve afectada.
-- Depende de: V224 (cuerpo base), V353 (cuerpo base), V246 (fila del endpoint).
-- ===========================================================================

SET search_path TO academico_test, public;

-- Cambia el RETURNS TABLE: hay que soltar la firma viva o CREATE OR REPLACE
-- falla con 42P13.
DROP FUNCTION IF EXISTS academico_test.fn_actividad_buscar_por_pk(BIGINT, BIGINT, INT);

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
    -- Grado del grupo de la actividad y, si no tiene grupo, el de su unidad.
    -- grado_grupo es la etiqueta compuesta (fn_grado_grupo_etiqueta): es lo
    -- que el prototipo pinta en la tarjeta y en la celda del calendario.
    fk_tgrado                       BIGINT,
    grado                           VARCHAR,
    grado_codigo                    VARCHAR,
    grado_grupo                     VARCHAR,
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
    -- Evidencias (TACTIVIDAD_EVIDENCIA) y criterios (TACTIVIDAD_CRITERIO_UNIDAD)
    -- ya relacionados: el "pk" de cada elemento es el de la RELACION, que es
    -- lo que exigen fn_actividad_evidencia_quitar / _criterio_quitar (V214.1).
    evidencias                      JSONB,
    criterios                       JSONB,
    -- Los estudiantes asignados (TACTIVIDAD_ESTUDIANTE ACTIVE), con el pk de
    -- la asignacion que piden calificar, observar y las adaptaciones.
    estudiantes                     JSONB,
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
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, NULL, p_pk_tactividad
    );

    RETURN QUERY
    SELECT a.PK_TACTIVIDAD, a.TITULO, a.DESCRIPCION,
           a.FK_TASIGNATURA, asig.NOMBRE,
           a.FK_TUNIDAD, u.NOMBRE,
           a.FK_TGRUPO, g.NOMBRE,
           gr.PK_TGRADO, gr.NOMBRE, gr.CODIGO,
           academico_test.fn_grado_grupo_etiqueta(gr.NOMBRE, gr.CODIGO, g.NOMBRE),
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
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'pk',                   ev.PK_TACTIVIDAD_EVIDENCIA,
                          'fkReferenteEnunciado', ev.FK_REFERENTE_ENUNCIADO,
                          'texto',                re.TEXTO,
                          'fkPadre',              re.FK_PADRE,
                          'textoPadre',           rep.TEXTO)
                          ORDER BY re.FK_PADRE, ev.PK_TACTIVIDAD_EVIDENCIA)
                 FROM academico_test.TACTIVIDAD_EVIDENCIA ev
                 JOIN academico_test.TREFERENTE_ENUNCIADO re
                   ON re.PK_REFERENTE_ENUNCIADO = ev.FK_REFERENTE_ENUNCIADO
                 LEFT JOIN academico_test.TREFERENTE_ENUNCIADO rep
                   ON rep.PK_REFERENTE_ENUNCIADO = re.FK_PADRE
                WHERE ev.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND ev.ACTIVE = TRUE
           ), '[]'::jsonb),
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'pk',                cr.PK_TACTIVIDAD_CRITERIO_UNIDAD,
                          'fkTcriterioUnidad', cr.FK_TCRITERIO_UNIDAD,
                          'descripcion',       cu.DESCRIPCION,
                          'codigo',            cu.CODIGO,
                          'orden',             cu.ORDEN)
                          ORDER BY cu.ORDEN, cr.PK_TACTIVIDAD_CRITERIO_UNIDAD)
                 FROM academico_test.TACTIVIDAD_CRITERIO_UNIDAD cr
                 JOIN academico_test.TCRITERIO_UNIDAD cu
                   ON cu.PK_TCRITERIO_UNIDAD = cr.FK_TCRITERIO_UNIDAD
                WHERE cr.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND cr.ACTIVE = TRUE
           ), '[]'::jsonb),
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'pkTactividadEstudiante', ae.PK_TACTIVIDAD_ESTUDIANTE,
                          'pkTmatricula',           ae.FK_TMATRICULA,
                          'fkTestudiante',          m.FK_TESTUDIANTE,
                          'estudiante',             NULLIF(TRIM(CONCAT_WS(' ', us.PRIMER_NOMBRE, us.SEGUNDO_NOMBRE,
                                                                             us.PRIMER_APELLIDO, us.SEGUNDO_APELLIDO)), ''),
                          'calificacion',           n.CALIFICACION,
                          'calificable',            n.CALIFICABLE,
                          'observacion',            n.OBSERVACION)
                          ORDER BY us.PRIMER_APELLIDO, us.PRIMER_NOMBRE, ae.PK_TACTIVIDAD_ESTUDIANTE)
                 FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
                 JOIN academico_test.TMATRICULA m    ON m.PK_TMATRICULA = ae.FK_TMATRICULA
                 JOIN academico_test.TESTUDIANTE es  ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
                 JOIN academico_test.TUSUARIO us     ON us.PK_TUSUARIO = es.FK_TUSUARIO
                 LEFT JOIN academico_test.TACTIVIDAD_NOTA n
                        ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE AND n.ACTIVE = TRUE
                WHERE ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND ae.ACTIVE = TRUE
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
           -- Dependencias dinamicas del formulario (V214.2): calculadas solo
           -- para esta fila (0 o 1), no en fn_actividad_listar -- ver nota
           -- de estilo en la cabecera de esa funcion.
           academico_test.fn_actividad_campos_disponibles(p_pk_usuario_solicitante, a.PK_TACTIVIDAD),
           academico_test.fn_actividad_unidad_configuracion(p_pk_usuario_solicitante, a.PK_TACTIVIDAD),
           a.ACTIVE
      FROM academico_test.TACTIVIDAD a
      JOIN academico_test.TASIGNATURA asig      ON asig.PK_TASIGNATURA = a.FK_TASIGNATURA
      LEFT JOIN academico_test.TUNIDAD u        ON u.PK_TUNIDAD = a.FK_TUNIDAD
      LEFT JOIN academico_test.TGRUPO g         ON g.PK_TGRUPO = a.FK_TGRUPO
      -- Igual que en fn_actividad_listar: grado del grupo o, si no tiene
      -- grupo, el de su unidad.
      LEFT JOIN academico_test.TGRADO gr        ON gr.PK_TGRADO = COALESCE(g.FK_TGRADO, u.FK_TGRADO)
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
    IS 'estudiantes ([{pkTactividadEstudiante, pkTmatricula, fkTestudiante, estudiante, calificacion, calificable, observacion}]) son los asignados ACTIVE con el pk de la asignacion -- el que piden calificar, observar y las adaptaciones -- y su nota u observacion actual; con esto el detalle trae todo lo relacionado a la actividad (unidad con referente/rubrica/enunciados en unidad_configuracion, materiales, adaptaciones, evidencias, criterios, recuperacion y estudiantes) en una sola llamada. Detalle completo de una actividad (gate VER): todos los campos de TACTIVIDAD con los nombres de catalogo resueltos, el estado derivado (fn_actividad_estado), el progreso de evaluacion (asignados/evaluados en un solo LATERAL), los materiales de apoyo y las adaptaciones curriculares como JSONB, las evidencias y los criterios ya relacionados (columnas "evidencias" y "criterios", ambas [] cuando no hay ninguno: evidencias = [{pk, fkReferenteEnunciado, texto, fkPadre, textoPadre}] sobre TACTIVIDAD_EVIDENCIA y criterios = [{pk, fkTcriterioUnidad, descripcion, codigo, orden}] sobre TACTIVIDAD_CRITERIO_UNIDAD, solo filas ACTIVE -- el "pk" de cada elemento es el de la RELACION, que es justo el que exigen fn_actividad_evidencia_quitar / fn_actividad_criterio_quitar de V214.1 y que antes solo se conocia en la respuesta del POST que lo creo), y la config de recuperacion (columna "recuperacion": objeto con destino/tipoAplicacion/tipoCalculo/valorPonderacion + nombres resueltos, o NULL si no es de recuperacion). campos_disponibles = fn_actividad_campos_disponibles (dependencias dinamicas actividad->criterio / actividad->evaluacion, V214.2); unidad_configuracion = fn_actividad_unidad_configuracion (snapshot de la unidad relacionada, o {tieneUnidad:false}, V214.2) -- ambas calculadas solo para esta fila (detalle), no en fn_actividad_listar. SETOF 0 o 1 fila (incluye inactivas). V224.';

-- Devuelve JSONB: no cambia el tipo, CREATE OR REPLACE basta.
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

COMMENT ON FUNCTION academico_test.fn_actividad_pantalla_edicion(BIGINT, BIGINT, INT)
    IS 'DTO compuesto de la pantalla "editar actividad": compone fn_actividad_buscar_por_pk (V224) y fn_actividad_instrumento_obtener en UN JSONB ya en camelCase y anidado por concepto (actividad{...}, materiales, adaptaciones, evidencias, criterios, estudiantes, recuperacion, instrumento, camposDisponibles, unidadConfiguracion), con las banderas S/N convertidas a boolean. No reimplementa ninguna regla: solo reempaqueta. evidencias y criterios son las relaciones ACTIVE que ya tiene la actividad, con el pk DE LA RELACION -- el que exigen fn_actividad_evidencia_quitar / fn_actividad_criterio_quitar (V214.1) --, para que al reabrir la actividad se puedan pre-marcar y quitar. Gate VER (fn_planeador_assert_alcance) una sola vez. P0002 si la actividad no existe. V353. estudiantes: los asignados con el pk de la asignacion y su nota u observacion (misma forma que fn_actividad_buscar_por_pk).';

-- Las filas de los dos endpoints existen con ON CONFLICT DO NOTHING: se
-- reconcilia el detail aparte (patron V253/V279). No-op al reaplicar.
UPDATE public.query q
   SET detail = 'V353 -- DTO compuesto para PlaneadorEditarActividadPage: actividad + instrumento en una sola llamada, ya en camelCase y anidado por concepto. Reemplaza, PARA ESA PANTALLA, la cadena GET .../:ID + GET .../:ID/instrumento. Incluye ademas evidencias (TACTIVIDAD_EVIDENCIA: [{pk, fkReferenteEnunciado, texto, fkPadre, textoPadre}]) y criterios (TACTIVIDAD_CRITERIO_UNIDAD: [{pk, fkTcriterioUnidad, descripcion, codigo, orden}]) ya relacionados, para poder pre-marcarlos al reabrir la actividad y para conocer el pk que exigen PATCH /planeador/actividades/evidencias/:ID y PATCH /planeador/actividades/criterios/:ID. Y estudiantes ([{pkTactividadEstudiante, pkTmatricula, fkTestudiante, estudiante, calificacion, calificable, observacion}]): los asignados, con el pk de la asignacion que piden calificar, observar y las adaptaciones.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/:ID/pantalla-edicion'
   AND q.http_method     = 'GET'
   AND q.detail IS DISTINCT FROM 'V353 -- DTO compuesto para PlaneadorEditarActividadPage: actividad + instrumento en una sola llamada, ya en camelCase y anidado por concepto. Reemplaza, PARA ESA PANTALLA, la cadena GET .../:ID + GET .../:ID/instrumento. Incluye ademas evidencias (TACTIVIDAD_EVIDENCIA: [{pk, fkReferenteEnunciado, texto, fkPadre, textoPadre}]) y criterios (TACTIVIDAD_CRITERIO_UNIDAD: [{pk, fkTcriterioUnidad, descripcion, codigo, orden}]) ya relacionados, para poder pre-marcarlos al reabrir la actividad y para conocer el pk que exigen PATCH /planeador/actividades/evidencias/:ID y PATCH /planeador/actividades/criterios/:ID. Y estudiantes ([{pkTactividadEstudiante, pkTmatricula, fkTestudiante, estudiante, calificacion, calificable, observacion}]): los asignados, con el pk de la asignacion que piden calificar, observar y las adaptaciones.';

UPDATE public.query q
   SET detail = q.detail || ' V452 -- ademas estudiantes: [{pkTactividadEstudiante, pkTmatricula, fkTestudiante, estudiante, calificacion, calificable, observacion}], los asignados activos con el pk de la asignacion (el que piden calificar, observar y las adaptaciones) y su nota u observacion actual.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/:ID'
   AND q.http_method     = 'GET'
   AND q.detail NOT LIKE '%V452 --%';
