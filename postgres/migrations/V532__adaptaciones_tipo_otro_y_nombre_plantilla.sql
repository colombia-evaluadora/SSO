-- ===========================================================================
-- V532 — Adaptaciones curriculares (Bloque 6): dos campos que el mockup
-- exige y la tabla nunca tuvo dónde guardar (Mantis case_id 283):
--   1. "Otro" en Tipo de adaptación -> texto libre OBLIGATORIO que lo
--      justifique (TIPO_OTRO).
--   2. Archivo/Enlace de la versión modificada -> "Nombre de plantilla"
--      (máx. 100) para identificarla en la Biblioteca (NOMBRE_PLANTILLA),
--      hoy la Biblioteca solo mostraba el nombre crudo del archivo.
-- Ambos viajan DENTRO del JSONB de BODY.ADAPTACIONES (PUT .../adaptaciones,
-- V496.4) — no cambia el endpoint, solo el núcleo que lo procesa.
-- Depende de: V22 (TACTIVIDAD_ADAPTACION), V452 (fn_actividad_buscar_por_pk),
-- V471 (biblioteca), V496.1/V496.2 (validación/escritura).
-- ===========================================================================

SET search_path TO academico_test, public;

ALTER TABLE TACTIVIDAD_ADAPTACION ADD COLUMN IF NOT EXISTS TIPO_OTRO VARCHAR(255);
ALTER TABLE TACTIVIDAD_ADAPTACION ADD COLUMN IF NOT EXISTS NOMBRE_PLANTILLA VARCHAR(100);

-- ===========================================================================
-- (1) Validación — exige TIPO_OTRO cuando el tipo elegido es "Otro", y
-- NOMBRE_PLANTILLA cuando la versión modificada es archivo o enlace (una
-- plantilla de BIBLIOTECA ya trae su propio nombre de origen, no hace falta
-- pedirlo de nuevo).
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_adaptaciones(p_adaptaciones JSONB)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_a       RECORD;
    v_que     VARCHAR;
    v_usa     VARCHAR;
    v_formato VARCHAR;
    v_aplica  VARCHAR;
    v_tipo    VARCHAR;
BEGIN
    IF p_adaptaciones IS NULL THEN
        RETURN;
    END IF;
    IF jsonb_typeof(p_adaptaciones) <> 'array' THEN
        RAISE EXCEPTION 'Las adaptaciones curriculares deben enviarse como una lista' USING ERRCODE = '22023';
    END IF;
    FOR v_a IN SELECT e AS j, ord FROM jsonb_array_elements(p_adaptaciones) WITH ORDINALITY AS t(e, ord) LOOP
        v_que := format('la adaptación %s', v_a.ord);
        IF (v_a.j->>'tipoAdaptacion') IS NULL THEN
            RAISE EXCEPTION 'Indique el tipo de adaptación en %', v_que USING ERRCODE = '22023';
        END IF;
        IF NULLIF(TRIM(v_a.j->>'descripcion'), '') IS NULL THEN
            RAISE EXCEPTION 'Describa qué se va a hacer en %', v_que USING ERRCODE = '22023';
        END IF;
        PERFORM academico_test.fn_actividad_validar_texto(v_a.j->>'descripcion', 'La descripción de ' || v_que, 500);
        PERFORM academico_test.fn_actividad_validar_catalogo((v_a.j->>'tipoAdaptacion')::BIGINT,    'TIPO_ADAPTACION',    'Tipo de adaptación');
        PERFORM academico_test.fn_actividad_validar_catalogo((v_a.j->>'formatoAdaptacion')::BIGINT, 'FORMATO_ADAPTACION', 'Versión modificada del instrumento');
        PERFORM academico_test.fn_actividad_validar_catalogo((v_a.j->>'aplicaA')::BIGINT,           'APLICA_A',           '¿A quién se aplica?');

        SELECT VALOR INTO v_tipo FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = (v_a.j->>'tipoAdaptacion')::BIGINT;
        IF v_tipo = 'OTRO' THEN
            IF NULLIF(TRIM(v_a.j->>'tipoOtro'), '') IS NULL THEN
                RAISE EXCEPTION 'Especifique el tipo de adaptación en % (elegiste "Otro")', v_que USING ERRCODE = '22023';
            END IF;
            PERFORM academico_test.fn_actividad_validar_texto(v_a.j->>'tipoOtro', 'El tipo de adaptación de ' || v_que, 255);
        END IF;

        v_usa := UPPER(TRIM(COALESCE(v_a.j->>'usaVersionModificada', 'N')));
        IF v_usa NOT IN ('S', 'N') THEN
            RAISE EXCEPTION 'Indique si % usa una versión modificada del instrumento (Sí o No)', v_que
                USING ERRCODE = '22023';
        END IF;
        SELECT VALOR INTO v_formato FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = (v_a.j->>'formatoAdaptacion')::BIGINT;
        SELECT VALOR INTO v_aplica FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = (v_a.j->>'aplicaA')::BIGINT;

        IF v_usa = 'S' THEN
            IF v_formato IS NULL THEN
                RAISE EXCEPTION 'Indique cómo se entrega la versión modificada de % (archivo, enlace o biblioteca)', v_que
                    USING ERRCODE = '22023';
            END IF;
            IF v_formato IN ('ARCHIVO', 'BIBLIOTECA') AND (v_a.j->>'fkTarchivo') IS NULL THEN
                RAISE EXCEPTION 'Adjunte o elija de la biblioteca el archivo de %', v_que USING ERRCODE = '22023';
            END IF;
            IF v_formato = 'ENLACE' AND NULLIF(TRIM(v_a.j->>'url'), '') IS NULL THEN
                RAISE EXCEPTION 'Escriba el enlace de la versión modificada de %', v_que USING ERRCODE = '22023';
            END IF;
            IF v_formato IN ('ARCHIVO', 'ENLACE') THEN
                IF NULLIF(TRIM(v_a.j->>'nombrePlantilla'), '') IS NULL THEN
                    RAISE EXCEPTION 'Indique el nombre de la plantilla de %, para identificarla en la biblioteca', v_que
                        USING ERRCODE = '22023';
                END IF;
                PERFORM academico_test.fn_actividad_validar_texto(v_a.j->>'nombrePlantilla', 'El nombre de plantilla de ' || v_que, 100);
            END IF;
        ELSIF v_formato IS NOT NULL THEN
            RAISE EXCEPTION '% no usa versión modificada del instrumento: quite el archivo o enlace', v_que
                USING ERRCODE = '22023';
        END IF;
        PERFORM academico_test.fn_actividad_validar_url(v_a.j->>'url', v_que);
        PERFORM academico_test.fn_actividad_validar_archivo_existente((v_a.j->>'fkTarchivo')::BIGINT, v_que);

        IF v_aplica = 'ESTUDIANTES_SELECCIONADOS'
           AND (jsonb_typeof(v_a.j->'estudiantes') IS DISTINCT FROM 'array'
                OR jsonb_array_length(v_a.j->'estudiantes') = 0) THEN
            RAISE EXCEPTION 'Seleccione al menos un estudiante para % ("Estudiantes específicos")', v_que
                USING ERRCODE = '22023';
        END IF;
        IF v_aplica IS DISTINCT FROM 'ESTUDIANTES_SELECCIONADOS'
           AND jsonb_typeof(v_a.j->'estudiantes') = 'array'
           AND jsonb_array_length(v_a.j->'estudiantes') > 0 THEN
            RAISE EXCEPTION '% aplica a todo el grupo: no se le escogen estudiantes', v_que USING ERRCODE = '22023';
        END IF;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_validar_adaptaciones(JSONB)
    IS 'Valida BODY.ADAPTACIONES completo (PUT .../adaptaciones). V532: tipoOtro obligatorio (máx 255) cuando el tipo elegido resuelve a TIPO_ADAPTACION=OTRO; nombrePlantilla obligatorio (máx 100) cuando usaVersionModificada=S y el formato es ARCHIVO o ENLACE (BIBLIOTECA reusa el nombre de origen, no pide uno nuevo). Resto de las reglas sin cambios: descripción obligatoria (máx 500), catálogos válidos, archivo/enlace coherente con el formato elegido, URL con formato http(s), estudiantes solo si aplica a "específicos". V496.1/V532.';

-- ===========================================================================
-- (2) Escritura — guarda los dos campos nuevos tal cual vienen del JSONB.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_adaptacion_reemplazar_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_adaptaciones           JSONB
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_por      VARCHAR := p_pk_usuario_solicitante::VARCHAR;
    v_elem     JSONB;
    v_pk_adapt BIGINT;
    v_n        INT := 0;
BEGIN
    IF p_adaptaciones IS NULL THEN
        RETURN 0;
    END IF;
    PERFORM academico_test.fn_actividad_validar_existente(p_pk_tactividad);
    PERFORM academico_test.fn_actividad_validar_adaptaciones(p_adaptaciones);
    PERFORM academico_test.fn_actividad_validar_adaptacion_estudiantes(p_pk_tactividad, e->'estudiantes')
       FROM jsonb_array_elements(p_adaptaciones) e;

    UPDATE academico_test.TACTIVIDAD_ADAPTACION_ESTUDIANTE ae
       SET ACTIVE = FALSE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TACTIVIDAD_ADAPTACION ad
     WHERE ae.FK_TACTIVIDAD_ADAPTACION = ad.PK_TACTIVIDAD_ADAPTACION
       AND ad.FK_TACTIVIDAD = p_pk_tactividad AND ae.ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_ADAPTACION
       SET ACTIVE = FALSE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;

    FOR v_elem IN SELECT * FROM jsonb_array_elements(p_adaptaciones) LOOP
        INSERT INTO academico_test.TACTIVIDAD_ADAPTACION (
            FK_TACTIVIDAD, FK_TLV_TIPO_ADAPTACION, TIPO_OTRO, DESCRIPCION, USA_VERSION_MODIFICADA,
            FK_TARCHIVO, URL, FK_TLV_FORMATO_ADAPTACION, NOMBRE_PLANTILLA, FK_TLV_APLICA_A,
            CREATED_BY, CREATED_AT, ACTIVE
        ) VALUES (
            p_pk_tactividad, (v_elem->>'tipoAdaptacion')::BIGINT, NULLIF(TRIM(v_elem->>'tipoOtro'), ''),
            TRIM(v_elem->>'descripcion'),
            UPPER(TRIM(COALESCE(v_elem->>'usaVersionModificada', 'N'))),
            (v_elem->>'fkTarchivo')::BIGINT, NULLIF(TRIM(v_elem->>'url'), ''),
            (v_elem->>'formatoAdaptacion')::BIGINT, NULLIF(TRIM(v_elem->>'nombrePlantilla'), ''),
            (v_elem->>'aplicaA')::BIGINT,
            v_por, CURRENT_TIMESTAMP, TRUE
        )
        RETURNING PK_TACTIVIDAD_ADAPTACION INTO v_pk_adapt;

        INSERT INTO academico_test.TACTIVIDAD_ADAPTACION_ESTUDIANTE (
            FK_TACTIVIDAD_ADAPTACION, FK_TACTIVIDAD_ESTUDIANTE, CREATED_BY, CREATED_AT, ACTIVE)
        SELECT DISTINCT v_pk_adapt, ae.PK_TACTIVIDAD_ESTUDIANTE, v_por, CURRENT_TIMESTAMP, TRUE
          FROM jsonb_array_elements_text(COALESCE(v_elem->'estudiantes', '[]'::jsonb)) mid
          JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
            ON ae.FK_TACTIVIDAD = p_pk_tactividad AND ae.FK_TMATRICULA = mid::BIGINT AND ae.ACTIVE = TRUE;

        v_n := v_n + 1;
    END LOOP;
    RETURN v_n;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_adaptacion_reemplazar_interno(BIGINT, BIGINT, JSONB)
    IS 'Núcleo de PUT .../adaptaciones: valida y reemplaza por completo TACTIVIDAD_ADAPTACION (+ estudiantes) de una actividad. V532: guarda TIPO_OTRO y NOMBRE_PLANTILLA tal cual vienen del JSONB (tipoOtro/nombrePlantilla), ya exigidos por fn_actividad_validar_adaptaciones cuando corresponde. V496.2/V532.';

-- ===========================================================================
-- (3) Lectura (detalle/edición) — expone los dos campos nuevos en el JSONB
-- de cada adaptación. El RETURNS TABLE no cambia (sigue siendo la misma
-- lista de columnas, `adaptaciones` sigue JSONB), así que no hace falta
-- DROP: se edita el cuerpo real de V452 in-place, solo agregando
-- `'tipoOtro'`/`'nombrePlantilla'` al jsonb_build_object de cada adaptación.
-- ===========================================================================
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
    evidencias                      JSONB,
    criterios                       JSONB,
    estudiantes                     JSONB,
    recuperacion                    JSONB,
    campos_disponibles              JSONB,
    unidad_configuracion            JSONB,
    active                          BOOLEAN,
    -- Regla 13: como se llama la actividad para su grado/asignatura, mismo
    -- calculo que fn_actividad_listar_interno (V481) y fn_unidad_listar_interno
    -- (V488). No llama a fn_planeador_rotulo_actividad_interno (V511): es
    -- posterior a este archivo.
    rotulo_ejecucion                VARCHAR
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
                          -- V532: justificación libre de "Otro", y el rótulo
                          -- con el que esta plantilla aparece en la Biblioteca.
                          'tipoOtro',                  ad.TIPO_OTRO,
                          'descripcion',               ad.DESCRIPCION,
                          'usaVersionModificada',      ad.USA_VERSION_MODIFICADA,
                          'formatoAdaptacion',         ad.FK_TLV_FORMATO_ADAPTACION,
                          'formatoAdaptacionNombre',   lfa.NOMBRE,
                          'fkTarchivo',                ad.FK_TARCHIVO,
                          'url',                       ad.URL,
                          'nombrePlantilla',           ad.NOMBRE_PLANTILLA,
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
           a.ACTIVE,
           COALESCE(
               (SELECT rc_rot.ROTULO_EJECUCION
                  FROM academico_test.TREFERENTE_CURRICULAR rc_rot
                 WHERE rc_rot.PK_REFERENTE_CURRICULAR =
                       academico_test.fn_unidad_referente_aplicable(gr.PK_TGRADO, a.FK_TASIGNATURA)),
               'Actividad'
           )::VARCHAR
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
    IS 'estudiantes ([{pkTactividadEstudiante, pkTmatricula, fkTestudiante, estudiante, calificacion, calificable, observacion}]) son los asignados ACTIVE con el pk de la asignacion -- el que piden calificar, observar y las adaptaciones -- y su nota u observacion actual; con esto el detalle trae todo lo relacionado a la actividad (unidad con referente/rubrica/enunciados en unidad_configuracion, materiales, adaptaciones, evidencias, criterios, recuperacion y estudiantes) en una sola llamada. Detalle completo de una actividad (gate VER): todos los campos de TACTIVIDAD con los nombres de catalogo resueltos, el estado derivado (fn_actividad_estado), el progreso de evaluacion (asignados/evaluados en un solo LATERAL), los materiales de apoyo y las adaptaciones curriculares como JSONB, las evidencias y los criterios ya relacionados, y la config de recuperacion. campos_disponibles = fn_actividad_campos_disponibles; unidad_configuracion = fn_actividad_unidad_configuracion. SETOF 0 o 1 fila (incluye inactivas). V532: cada adaptación en `adaptaciones` trae además `tipoOtro` (justificación libre de "Otro") y `nombrePlantilla` (rótulo de la versión modificada en archivo/enlace para la Biblioteca). V224/V452/V532.';

-- ===========================================================================
-- (4) Biblioteca — expone `nombre_plantilla` para que el combobox muestre el
-- rótulo elegido por el docente en vez de obligarlo a reconocer el nombre
-- crudo del archivo. Cambia el RETURNS TABLE: hace falta DROP antes.
-- ===========================================================================
DROP FUNCTION IF EXISTS academico_test.fn_actividad_adaptaciones_reutilizables_listar(BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, INTEGER, INTEGER, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_adaptaciones_reutilizables_listar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT  DEFAULT NULL,
    p_fk_tasignatura         BIGINT  DEFAULT NULL,
    p_fk_tfuncionario        BIGINT  DEFAULT NULL,
    p_search                 VARCHAR DEFAULT NULL,
    p_pagina                 INTEGER DEFAULT 1,
    p_tamano_pagina          INTEGER DEFAULT 20,
    p_fk_tgrupo              BIGINT  DEFAULT NULL
)
RETURNS TABLE(
    fk_tarchivo             BIGINT,
    nombre_archivo          VARCHAR,
    nombre_plantilla        VARCHAR,
    peso                    BIGINT,
    pk_tactividad_origen    BIGINT,
    titulo_actividad_origen VARCHAR,
    fk_tlv_tipo_adaptacion  BIGINT,
    tipo_adaptacion         VARCHAR,
    descripcion             VARCHAR,
    total_count             BIGINT
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_limite INT;
    v_offset INT;
    v_grupo  BIGINT;
    v_ee     BIGINT;
BEGIN
    IF p_pk_tactividad IS NULL AND p_fk_tgrupo IS NULL THEN
        RAISE EXCEPTION 'Indique la actividad o el grupo para consultar la biblioteca de adaptaciones'
            USING ERRCODE = '22023',
                  HINT    = 'Al editar se manda la actividad; al crear, el grupo que ya eligio el formulario';
    END IF;

    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER',
        CASE WHEN p_pk_tactividad IS NULL THEN p_fk_tgrupo END,
        NULL, NULL, p_pk_tactividad
    );

    v_grupo := COALESCE(
        p_fk_tgrupo,
        (SELECT a.FK_TGRUPO FROM academico_test.TACTIVIDAD a
          WHERE a.PK_TACTIVIDAD = p_pk_tactividad)
    );
    v_ee := academico_test.fn_grupo_establecimiento(v_grupo);

    v_limite := GREATEST(COALESCE(p_tamano_pagina, 20), 1);
    v_offset := (GREATEST(COALESCE(p_pagina, 1), 1) - 1) * v_limite;

    RETURN QUERY
    SELECT t.PK_TARCHIVO,
           t.NOMBRE,
           ad.NOMBRE_PLANTILLA,
           t.PESO,
           a.PK_TACTIVIDAD,
           a.TITULO,
           ad.FK_TLV_TIPO_ADAPTACION,
           lv.NOMBRE,
           ad.DESCRIPCION,
           COUNT(*) OVER()
      FROM academico_test.TACTIVIDAD_ADAPTACION ad
      JOIN academico_test.TACTIVIDAD a  ON a.PK_TACTIVIDAD = ad.FK_TACTIVIDAD AND a.ACTIVE = TRUE
      JOIN academico_test.TARCHIVO t    ON t.PK_TARCHIVO = ad.FK_TARCHIVO AND t.ACTIVE = TRUE
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = ad.FK_TLV_TIPO_ADAPTACION
      LEFT JOIN academico_test.TUNIDAD u ON u.PK_TUNIDAD = a.FK_TUNIDAD
     WHERE ad.ACTIVE = TRUE
       AND ad.FK_TARCHIVO IS NOT NULL
       AND (p_pk_tactividad IS NULL OR a.PK_TACTIVIDAD <> p_pk_tactividad)
       AND (p_fk_tasignatura  IS NULL OR a.FK_TASIGNATURA = p_fk_tasignatura)
       AND (p_fk_tfuncionario IS NULL OR u.FK_TFUNCIONARIO = p_fk_tfuncionario)
       AND (v_ee IS NULL
            OR academico_test.fn_grupo_establecimiento(a.FK_TGRUPO) = v_ee)
       AND (p_search IS NULL OR TRIM(p_search) = ''
            OR t.NOMBRE ILIKE '%' || TRIM(p_search) || '%'
            OR ad.NOMBRE_PLANTILLA ILIKE '%' || TRIM(p_search) || '%'
            OR a.TITULO ILIKE '%' || TRIM(p_search) || '%')
     ORDER BY COALESCE(ad.NOMBRE_PLANTILLA, t.NOMBRE), a.TITULO
     LIMIT v_limite
    OFFSET v_offset;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_actividad_adaptaciones_reutilizables_listar(BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, INTEGER, INTEGER, BIGINT)
    IS 'La "biblioteca institucional" de adaptaciones curriculares: plantillas (archivo) ya subidas en OTRAS actividades, para reusarlas sin volver a cargarlas. V532: expone nombre_plantilla (rótulo que el docente le dio al guardarla) y lo prioriza en el orden y la búsqueda sobre el nombre crudo del archivo (nombre_archivo), que sigue disponible como respaldo cuando una adaptación antigua no tiene plantilla con nombre. Mismo diseño que fn_actividad_materiales_reutilizables_listar (V429): ancla por actividad o grupo, gate fn_planeador_assert_alcance, resultados acotados al establecimiento del ancla. Solo trae adaptaciones CON archivo. Pagina con PAGINA (1-based) y SIZE. V471/V532.';
