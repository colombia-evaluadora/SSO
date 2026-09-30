-- V496.2 — Planeador, actividad: núcleos _interno sin permisos (2 de 4).
--
-- Qué hace: alta, PATCH y cada satélite de la actividad (estudiantes,
-- materiales, adaptaciones, recuperación, evidencias y criterios) como núcleo
-- que valida con V496.1 y escribe, sin gate ni etiqueta: los reutilizan los
-- wrappers de V496.3, la importación y la unidad. Un trigger aplica las Reglas
-- 36/39: al cambiar o quitar la unidad se sueltan las evidencias y criterios
-- que eran de la anterior.
-- Depende de: V496.1, V492.2 (vínculo con la unidad), V482 (eliminar),
-- V483 (mínimo de evidencias), V408 (revertir recuperación).

SET search_path TO academico_test, public;

-- Las versiones sin gate que usaban crear/actualizar se reemplazan por _interno.
DROP FUNCTION IF EXISTS academico_test.fn_actividad_estudiantes_asignar(BIGINT, BIGINT, BIGINT[], BOOLEAN);
DROP FUNCTION IF EXISTS academico_test.fn_actividad_recuperacion_configurar(BIGINT, BIGINT, JSONB);

-- ---------------------------------------------------------------------------
-- Estudiantes
-- ---------------------------------------------------------------------------

-- Reemplazo del set. p_fk_tmatriculas NULL + todo el grupo = las matrículas
-- activas del grupo; los dos vacíos = no tocar. Reactiva en vez de duplicar.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_estudiantes_asignar_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_fk_tmatriculas         BIGINT[] DEFAULT NULL,
    p_todo_el_grupo          BOOLEAN  DEFAULT FALSE
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_por    VARCHAR := p_pk_usuario_solicitante::VARCHAR;
    v_grupo  BIGINT;
    v_titulo VARCHAR;
    v_set    BIGINT[];
BEGIN
    IF p_fk_tmatriculas IS NULL AND NOT COALESCE(p_todo_el_grupo, FALSE) THEN
        RETURN 0;
    END IF;
    PERFORM academico_test.fn_actividad_validar_existente(p_pk_tactividad);
    SELECT FK_TGRUPO, academico_test.fn_actividad_etiqueta(p_pk_tactividad) INTO v_grupo, v_titulo
      FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad;
    PERFORM academico_test.fn_actividad_validar_matriculas(v_grupo, v_titulo, p_fk_tmatriculas, p_todo_el_grupo);

    IF p_fk_tmatriculas IS NULL THEN
        SELECT COALESCE(array_agg(m.PK_TMATRICULA), ARRAY[]::BIGINT[]) INTO v_set
          FROM academico_test.TMATRICULA m
         WHERE m.FK_TGRUPO = v_grupo AND m.ACTIVE = TRUE;
    ELSE
        v_set := ARRAY(SELECT DISTINCT x FROM unnest(p_fk_tmatriculas) x WHERE x IS NOT NULL);
    END IF;

    -- Regla 46: el estudiante que sale de la actividad sale también de sus adaptaciones.
    UPDATE academico_test.TACTIVIDAD_ADAPTACION_ESTUDIANTE ade
       SET ACTIVE = FALSE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE ade.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
       AND ae.FK_TACTIVIDAD = p_pk_tactividad
       AND ae.ACTIVE = TRUE AND ade.ACTIVE = TRUE
       AND NOT (ae.FK_TMATRICULA = ANY(v_set));

    UPDATE academico_test.TACTIVIDAD_ESTUDIANTE
       SET ACTIVE = FALSE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE
       AND NOT (FK_TMATRICULA = ANY(v_set));

    UPDATE academico_test.TACTIVIDAD_ESTUDIANTE ae
       SET ACTIVE = TRUE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM unnest(v_set) mid
     WHERE ae.FK_TACTIVIDAD = p_pk_tactividad AND ae.FK_TMATRICULA = mid AND ae.ACTIVE = FALSE;

    INSERT INTO academico_test.TACTIVIDAD_ESTUDIANTE (FK_TACTIVIDAD, FK_TMATRICULA, CREATED_BY, CREATED_AT, ACTIVE)
    SELECT p_pk_tactividad, mid, v_por, CURRENT_TIMESTAMP, TRUE
      FROM unnest(v_set) mid
     WHERE NOT EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
                        WHERE ae.FK_TACTIVIDAD = p_pk_tactividad AND ae.FK_TMATRICULA = mid);

    RETURN (SELECT COUNT(*) FROM academico_test.TACTIVIDAD_ESTUDIANTE
             WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE);
END;
$$;

-- ---------------------------------------------------------------------------
-- Materiales de apoyo y adaptaciones
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_material_reemplazar_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_materiales             JSONB
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_por        VARCHAR := p_pk_usuario_solicitante::VARCHAR;
    v_insertados INT;
BEGIN
    IF p_materiales IS NULL THEN
        RETURN 0;
    END IF;
    PERFORM academico_test.fn_actividad_validar_existente(p_pk_tactividad);
    PERFORM academico_test.fn_actividad_validar_materiales(p_materiales);

    UPDATE academico_test.TACTIVIDAD_MATERIAL
       SET ACTIVE = FALSE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;

    INSERT INTO academico_test.TACTIVIDAD_MATERIAL (
        FK_TACTIVIDAD, ORDEN, FK_TLV_TIPO_RECURSO, URL, FK_TARCHIVO, DESCRIPCION,
        CREATED_BY, CREATED_AT, ACTIVE)
    SELECT p_pk_tactividad, e.ord, (e.j->>'tipoRecurso')::BIGINT, NULLIF(TRIM(e.j->>'url'), ''),
           (e.j->>'fkTarchivo')::BIGINT, NULLIF(TRIM(e.j->>'descripcion'), ''),
           v_por, CURRENT_TIMESTAMP, TRUE
      FROM jsonb_array_elements(p_materiales) WITH ORDINALITY AS e(j, ord);

    GET DIAGNOSTICS v_insertados = ROW_COUNT;
    RETURN v_insertados;
END;
$$;

-- Reemplazo completo. Va después de estudiantes: las adaptaciones a
-- "Estudiantes específicos" apuntan a filas de TACTIVIDAD_ESTUDIANTE.
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
            FK_TACTIVIDAD, FK_TLV_TIPO_ADAPTACION, DESCRIPCION, USA_VERSION_MODIFICADA,
            FK_TARCHIVO, URL, FK_TLV_FORMATO_ADAPTACION, FK_TLV_APLICA_A,
            CREATED_BY, CREATED_AT, ACTIVE
        ) VALUES (
            p_pk_tactividad, (v_elem->>'tipoAdaptacion')::BIGINT, TRIM(v_elem->>'descripcion'),
            UPPER(TRIM(COALESCE(v_elem->>'usaVersionModificada', 'N'))),
            (v_elem->>'fkTarchivo')::BIGINT, NULLIF(TRIM(v_elem->>'url'), ''),
            (v_elem->>'formatoAdaptacion')::BIGINT, (v_elem->>'aplicaA')::BIGINT,
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

-- ---------------------------------------------------------------------------
-- Recuperación
-- ---------------------------------------------------------------------------

-- p_config NULL = la actividad deja de ser recuperación: revierte lo aplicado,
-- desactiva la configuración y pone ES_RECUPERACION = N.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_recuperacion_configurar_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_config                 JSONB
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_por        VARCHAR := p_pk_usuario_solicitante::VARCHAR;
    v_aplic      VARCHAR;
    v_pk_calculo BIGINT;
    v_recuperar  BIGINT;
    v_valor      NUMERIC(5,2);
    v_pk         BIGINT;
BEGIN
    PERFORM academico_test.fn_actividad_validar_existente(p_pk_tactividad);

    IF p_config IS NULL THEN
        PERFORM academico_test.fn_actividad_recuperacion_revertir(p_pk_usuario_solicitante, p_pk_tactividad);
        UPDATE academico_test.TACTIVIDAD_RECUPERACION
           SET ACTIVE = FALSE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;
        UPDATE academico_test.TACTIVIDAD
           SET ES_RECUPERACION = 'N', MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD = p_pk_tactividad AND ES_RECUPERACION <> 'N';
        RETURN NULL;
    END IF;

    PERFORM academico_test.fn_actividad_validar_activa(p_pk_tactividad);
    PERFORM academico_test.fn_actividad_validar_recuperacion_config(p_config);
    v_recuperar := (p_config->>'fkActividadRecuperar')::BIGINT;
    IF v_recuperar IS NOT NULL THEN
        PERFORM academico_test.fn_actividad_validar_recuperable(
            v_recuperar, p_pk_tactividad,
            (SELECT FK_TASIGNATURA FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad));
    END IF;

    SELECT VALOR INTO v_aplic FROM academico_test.TLISTA_VALOR
     WHERE PK_LISTA_VALOR = (p_config->>'tipoAplicacion')::BIGINT;
    v_valor      := NULLIF(TRIM(p_config->>'valorPonderacion'), '')::NUMERIC;
    -- REEMPLAZAR no usa tipo de cálculo, pero la columna es NOT NULL y
    -- fn_recuperacion_combinar no la mira: se guarda PROMEDIADO.
    v_pk_calculo := CASE WHEN v_aplic = 'REEMPLAZAR'
                         THEN (SELECT PK_LISTA_VALOR FROM academico_test.TLISTA_VALOR
                                WHERE CATEGORIA = 'TIPO_CALCULO_RECUPERACION' AND VALOR = 'PROMEDIADO'
                                  AND ACTIVE = TRUE LIMIT 1)
                         ELSE NULLIF(p_config->>'tipoCalculo', '')::BIGINT END;

    UPDATE academico_test.TACTIVIDAD
       SET ES_RECUPERACION = 'S', MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD = p_pk_tactividad AND ES_RECUPERACION <> 'S';

    SELECT PK_TACTIVIDAD_RECUPERACION INTO v_pk
      FROM academico_test.TACTIVIDAD_RECUPERACION WHERE FK_TACTIVIDAD = p_pk_tactividad;

    IF v_pk IS NULL THEN
        INSERT INTO academico_test.TACTIVIDAD_RECUPERACION (
            FK_TACTIVIDAD, FK_TLV_DESTINO_RECUPERACION, FK_TACTIVIDAD_RECUPERAR,
            FK_TLV_TIPO_APLICACION_RECUPERACION, FK_TLV_TIPO_CALCULO_RECUPERACION,
            VALOR_PONDERACION_RECUPERACION, CREATED_BY, CREATED_AT, ACTIVE
        ) VALUES (
            p_pk_tactividad, (p_config->>'destino')::BIGINT, v_recuperar,
            (p_config->>'tipoAplicacion')::BIGINT, v_pk_calculo, v_valor, v_por, CURRENT_TIMESTAMP, TRUE
        )
        RETURNING PK_TACTIVIDAD_RECUPERACION INTO v_pk;
    ELSE
        UPDATE academico_test.TACTIVIDAD_RECUPERACION
           SET FK_TLV_DESTINO_RECUPERACION         = (p_config->>'destino')::BIGINT,
               FK_TACTIVIDAD_RECUPERAR             = v_recuperar,
               FK_TLV_TIPO_APLICACION_RECUPERACION = (p_config->>'tipoAplicacion')::BIGINT,
               FK_TLV_TIPO_CALCULO_RECUPERACION    = v_pk_calculo,
               VALOR_PONDERACION_RECUPERACION      = v_valor,
               ACTIVE = TRUE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD_RECUPERACION = v_pk;
    END IF;
    RETURN v_pk;
END;
$$;

-- La sección "Es una recuperación" del formulario. El selector aplica la
-- misma regla que la escritura (fn_actividad_validar_recuperable, Regla 64).
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_recuperacion_campos_disponibles(
    p_evaluativo              BOOLEAN,
    p_es_sumativo             VARCHAR DEFAULT 'S',
    p_es_preescolar           BOOLEAN DEFAULT FALSE,
    p_recuperar               VARCHAR DEFAULT 'N',
    p_fk_tgrupo               BIGINT  DEFAULT NULL,
    p_fk_tasignatura          BIGINT  DEFAULT NULL,
    p_fk_tactividad_recuperar BIGINT  DEFAULT NULL,
    p_pk_tactividad_actual    BIGINT  DEFAULT NULL,
    p_pk_usuario_solicitante  BIGINT  DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_sum     VARCHAR := UPPER(TRIM(COALESCE(p_es_sumativo, 'S')));
    v_rec     VARCHAR := UPPER(TRIM(COALESCE(p_recuperar, 'N')));
    v_visible BOOLEAN := COALESCE(p_evaluativo, FALSE) AND v_sum <> 'N'
                         AND NOT COALESCE(p_es_preescolar, FALSE);
    v_lista   JSONB;
    v_origen  JSONB;
    v_o       RECORD;
BEGIN
    IF v_visible AND v_rec = 'S' AND p_fk_tasignatura IS NOT NULL THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'pk',          a.PK_TACTIVIDAD,
                   'titulo',      a.TITULO,
                   'fkTgrupo',    a.FK_TGRUPO,
                   'fkTunidad',   a.FK_TUNIDAD,
                   'unidad',      u.NOMBRE,
                   'fechaInicio', a.FECHA_INICIO,
                   'fechaCierre', a.FECHA_CIERRE,
                   'estudiantesAsignados',
                       (SELECT COUNT(*) FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
                         WHERE ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND ae.ACTIVE = TRUE))
                   ORDER BY a.FECHA_INICIO DESC NULLS LAST, a.PK_TACTIVIDAD DESC), '[]'::jsonb)
          INTO v_lista
          FROM academico_test.TACTIVIDAD a
          LEFT JOIN academico_test.TUNIDAD u ON u.PK_TUNIDAD = a.FK_TUNIDAD
         WHERE a.ACTIVE = TRUE
           AND a.FK_TASIGNATURA = p_fk_tasignatura
           AND (p_fk_tgrupo IS NULL
                OR a.FK_TGRUPO = p_fk_tgrupo
                OR (a.FK_TGRUPO IS NULL AND u.FK_TGRADO = (SELECT g.FK_TGRADO FROM academico_test.TGRUPO g
                                                             WHERE g.PK_TGRUPO = p_fk_tgrupo)))
           AND COALESCE(a.ES_EVALUATIVA::VARCHAR, 'S') = 'S'
           AND COALESCE(a.ES_RECUPERACION::VARCHAR, 'N') = 'N'
           AND a.PK_TACTIVIDAD IS DISTINCT FROM p_pk_tactividad_actual
           AND academico_test.fn_actividad_estudiantes_con_resultado(a.PK_TACTIVIDAD) > 0;
    END IF;

    IF p_fk_tactividad_recuperar IS NOT NULL THEN
        -- Alcance antes que las reglas: sus mensajes nombran la actividad.
        IF p_pk_usuario_solicitante IS NOT NULL THEN
            PERFORM academico_test.fn_planeador_assert_alcance(
                p_pk_usuario_solicitante, 'VER', NULL, NULL, NULL, p_fk_tactividad_recuperar);
        END IF;
        PERFORM academico_test.fn_actividad_validar_recuperable(
            p_fk_tactividad_recuperar, p_pk_tactividad_actual, p_fk_tasignatura);

        SELECT a.PK_TACTIVIDAD, a.TITULO, a.FK_TGRUPO, gr.NOMBRE AS grupo,
               COALESCE(gd.PK_TGRADO, gdu.PK_TGRADO) AS PK_TGRADO,
               COALESCE(gd.NOMBRE, gdu.NOMBRE)       AS grado,
               a.FK_TASIGNATURA, asg.NOMBRE AS asignatura,
               a.FK_TUNIDAD, u.NOMBRE AS unidad
          INTO v_o
          FROM academico_test.TACTIVIDAD a
          LEFT JOIN academico_test.TGRUPO gr       ON gr.PK_TGRUPO = a.FK_TGRUPO
          LEFT JOIN academico_test.TGRADO gd       ON gd.PK_TGRADO = gr.FK_TGRADO
          LEFT JOIN academico_test.TASIGNATURA asg ON asg.PK_TASIGNATURA = a.FK_TASIGNATURA
          LEFT JOIN academico_test.TUNIDAD u       ON u.PK_TUNIDAD = a.FK_TUNIDAD
          LEFT JOIN academico_test.TGRADO gdu      ON gdu.PK_TGRADO = u.FK_TGRADO
         WHERE a.PK_TACTIVIDAD = p_fk_tactividad_recuperar;

        v_origen := jsonb_build_object(
            'pkActividad',    v_o.PK_TACTIVIDAD,
            'tituloBase',     v_o.TITULO,
            'tituloSugerido', 'Recuperacion - ' || v_o.TITULO,
            'fkTgrado',       v_o.PK_TGRADO,      'grado',      v_o.grado,
            'fkTgrupo',       v_o.FK_TGRUPO,      'grupo',      v_o.grupo,
            'fkTasignatura',  v_o.FK_TASIGNATURA, 'asignatura', v_o.asignatura,
            'fkTunidad',      v_o.FK_TUNIDAD,     'unidad',     v_o.unidad,
            'camposHeredados', jsonb_build_array('FK_TGRUPO', 'FK_TASIGNATURA', 'FK_TUNIDAD'),
            'estudiantes', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                           'pkTmatricula',           ae.FK_TMATRICULA,
                           'pkTactividadEstudiante', ae.PK_TACTIVIDAD_ESTUDIANTE,
                           'fkTestudiante',          m.FK_TESTUDIANTE,
                           'estudiante',             NULLIF(TRIM(CONCAT_WS(' ', us.PRIMER_NOMBRE, us.SEGUNDO_NOMBRE,
                                                                                us.PRIMER_APELLIDO, us.SEGUNDO_APELLIDO)), ''),
                           'notaPrevia',             COALESCE(n.DEFINITIVA, n.CALIFICACION),
                           'seleccionado',           TRUE)
                           ORDER BY us.PRIMER_APELLIDO, us.PRIMER_NOMBRE, ae.PK_TACTIVIDAD_ESTUDIANTE)
                  FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
                  JOIN academico_test.TMATRICULA m   ON m.PK_TMATRICULA = ae.FK_TMATRICULA
                  JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
                  JOIN academico_test.TUSUARIO us    ON us.PK_TUSUARIO = es.FK_TUSUARIO
                  LEFT JOIN academico_test.TACTIVIDAD_NOTA n
                         ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE AND n.ACTIVE = TRUE
                 WHERE ae.FK_TACTIVIDAD = v_o.PK_TACTIVIDAD AND ae.ACTIVE = TRUE), '[]'::jsonb));
    END IF;

    RETURN jsonb_build_object(
        'visible',   v_visible,
        'requerido', FALSE,
        'motivo', CASE
            WHEN COALESCE(p_es_preescolar, FALSE)
                THEN 'El nivel Preescolar se rige por un referente formativo: no hay nota que recuperar'
            WHEN v_sum = 'N' THEN 'La actividad se creara como NO sumativa; una actividad de recuperacion debe ser sumativa'
            WHEN NOT COALESCE(p_evaluativo, FALSE) THEN 'El referente curricular no es EVALUATIVO: no hay nota que recuperar'
            ELSE 'Opcional: la actividad puede registrarse como recuperacion de otra actividad o de la nota final'
        END,
        'recuperarConsultado', v_rec,
        'catalogos', (
            SELECT jsonb_object_agg(k, v)
              FROM (SELECT CASE lv.CATEGORIA
                               WHEN 'DESTINO_RECUPERACION'         THEN 'destino'
                               WHEN 'TIPO_APLICACION_RECUPERACION' THEN 'tipoAplicacion'
                               ELSE 'tipoCalculo' END AS k,
                           jsonb_agg(jsonb_build_object(
                               'pk', lv.PK_LISTA_VALOR, 'valor', lv.VALOR, 'nombre', lv.NOMBRE)
                               ORDER BY lv.VALOR) AS v
                      FROM academico_test.TLISTA_VALOR lv
                     WHERE lv.CATEGORIA IN ('DESTINO_RECUPERACION',
                                            'TIPO_APLICACION_RECUPERACION',
                                            'TIPO_CALCULO_RECUPERACION')
                       AND lv.ACTIVE = TRUE
                     GROUP BY lv.CATEGORIA) c),
        'reglas', jsonb_build_object(
            'actividadRecuperarRequeridaSi', 'destino = ACTIVIDAD',
            'actividadRecuperableSi',        'ES_EVALUATIVA = S y ES_RECUPERACION = N, con al menos un resultado registrado y sin otra recuperacion activa',
            'tipoCalculoRequeridoSi',        'tipoAplicacion = COMPUTAR',
            'tipoCalculoOcultoSi',           'tipoAplicacion = REEMPLAZAR',
            'valorPonderacionRequeridoSi',   'tipoAplicacion = COMPUTAR y tipoCalculo = PONDERADO',
            'valorPonderacionRango',         jsonb_build_object('min', 0, 'max', 100),
            'estudiantesPorDefecto',         'los asignados a la actividad origen; se envian en FK_TMATRICULAS los que quedan marcados'),
        'actividadesRecuperables', v_lista,
        'origen', v_origen);
END;
$$;

-- ---------------------------------------------------------------------------
-- Evidencias y criterios de la unidad
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_evidencia_relacionar_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_fk_referente_enunciado BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_titulo VARCHAR;
    v_unidad BIGINT;
    v_pk     BIGINT;
BEGIN
    PERFORM academico_test.fn_actividad_validar_existente(p_pk_tactividad);
    PERFORM academico_test.fn_actividad_validar_activa(p_pk_tactividad);
    SELECT academico_test.fn_actividad_etiqueta(p_pk_tactividad), FK_TUNIDAD INTO v_titulo, v_unidad
      FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad;
    PERFORM academico_test.fn_actividad_validar_evidencia(v_unidad, v_titulo, p_fk_referente_enunciado);

    SELECT PK_TACTIVIDAD_EVIDENCIA INTO v_pk
      FROM academico_test.TACTIVIDAD_EVIDENCIA
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND FK_REFERENTE_ENUNCIADO = p_fk_referente_enunciado;
    IF v_pk IS NULL THEN
        INSERT INTO academico_test.TACTIVIDAD_EVIDENCIA (FK_TACTIVIDAD, FK_REFERENTE_ENUNCIADO, CREATED_BY, CREATED_AT, ACTIVE)
        VALUES (p_pk_tactividad, p_fk_referente_enunciado, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE)
        RETURNING PK_TACTIVIDAD_EVIDENCIA INTO v_pk;
    ELSE
        UPDATE academico_test.TACTIVIDAD_EVIDENCIA
           SET ACTIVE = TRUE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD_EVIDENCIA = v_pk AND ACTIVE = FALSE;
    END IF;
    RETURN v_pk;
END;
$$;

-- El mínimo de la Regla 43 lo impone el trigger diferido de V483 al commit.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_evidencia_quitar_interno(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_tactividad_evidencia BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_EVIDENCIA
                    WHERE PK_TACTIVIDAD_EVIDENCIA = p_pk_tactividad_evidencia AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'La evidencia ya no está marcada en la actividad' USING ERRCODE = 'P0002';
    END IF;
    UPDATE academico_test.TACTIVIDAD_EVIDENCIA
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD_EVIDENCIA = p_pk_tactividad_evidencia;
    RETURN TRUE;
END;
$$;

-- Reemplazo del set: desactiva lo que ya no viene y relaciona lo que llega.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_evidencias_set_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_evidencias             BIGINT[]
)
RETURNS INT
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_evidencias IS NULL THEN
        RETURN NULL;
    END IF;
    UPDATE academico_test.TACTIVIDAD_EVIDENCIA
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE
       AND FK_REFERENTE_ENUNCIADO <> ALL(ARRAY(SELECT x FROM unnest(p_evidencias) x WHERE x IS NOT NULL));
    PERFORM academico_test.fn_actividad_evidencia_relacionar_interno(p_pk_usuario_solicitante, p_pk_tactividad, ev)
       FROM (SELECT DISTINCT ev FROM unnest(p_evidencias) ev WHERE ev IS NOT NULL) s;
    RETURN (SELECT COUNT(*) FROM academico_test.TACTIVIDAD_EVIDENCIA
             WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE);
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_criterio_relacionar_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_fk_tcriterio_unidad    BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_titulo VARCHAR;
    v_unidad BIGINT;
    v_pk     BIGINT;
BEGIN
    PERFORM academico_test.fn_actividad_validar_existente(p_pk_tactividad);
    PERFORM academico_test.fn_actividad_validar_activa(p_pk_tactividad);
    SELECT academico_test.fn_actividad_etiqueta(p_pk_tactividad), FK_TUNIDAD INTO v_titulo, v_unidad
      FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad;
    PERFORM academico_test.fn_actividad_validar_criterio(v_unidad, v_titulo, p_fk_tcriterio_unidad);

    SELECT PK_TACTIVIDAD_CRITERIO_UNIDAD INTO v_pk
      FROM academico_test.TACTIVIDAD_CRITERIO_UNIDAD
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND FK_TCRITERIO_UNIDAD = p_fk_tcriterio_unidad;
    IF v_pk IS NULL THEN
        INSERT INTO academico_test.TACTIVIDAD_CRITERIO_UNIDAD (FK_TACTIVIDAD, FK_TCRITERIO_UNIDAD, CREATED_BY, CREATED_AT, ACTIVE)
        VALUES (p_pk_tactividad, p_fk_tcriterio_unidad, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE)
        RETURNING PK_TACTIVIDAD_CRITERIO_UNIDAD INTO v_pk;
    ELSE
        UPDATE academico_test.TACTIVIDAD_CRITERIO_UNIDAD
           SET ACTIVE = TRUE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD_CRITERIO_UNIDAD = v_pk AND ACTIVE = FALSE;
    END IF;
    RETURN v_pk;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_criterio_quitar_interno(
    p_pk_usuario_solicitante        BIGINT,
    p_pk_tactividad_criterio_unidad BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_CRITERIO_UNIDAD
                    WHERE PK_TACTIVIDAD_CRITERIO_UNIDAD = p_pk_tactividad_criterio_unidad AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El criterio ya no está seleccionado en la actividad' USING ERRCODE = 'P0002';
    END IF;
    UPDATE academico_test.TACTIVIDAD_CRITERIO_UNIDAD
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD_CRITERIO_UNIDAD = p_pk_tactividad_criterio_unidad;
    RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_criterios_set_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_criterios              BIGINT[]
)
RETURNS INT
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_criterios IS NULL THEN
        RETURN NULL;
    END IF;
    UPDATE academico_test.TACTIVIDAD_CRITERIO_UNIDAD
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE
       AND FK_TCRITERIO_UNIDAD <> ALL(ARRAY(SELECT x FROM unnest(p_criterios) x WHERE x IS NOT NULL));
    PERFORM academico_test.fn_actividad_criterio_relacionar_interno(p_pk_usuario_solicitante, p_pk_tactividad, cr)
       FROM (SELECT DISTINCT cr FROM unnest(p_criterios) cr WHERE cr IS NOT NULL) s;
    RETURN (SELECT COUNT(*) FROM academico_test.TACTIVIDAD_CRITERIO_UNIDAD
             WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE);
END;
$$;

-- ---------------------------------------------------------------------------
-- Reglas 36 y 39: las evidencias y criterios pertenecen a la unidad. Al
-- cambiarla o quitarla se sueltan los de la anterior, sin importar quién
-- mueva la actividad (PATCH, pestaña Actividades de la unidad, eliminar).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.tg_tactividad_depurar_por_unidad()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE academico_test.TACTIVIDAD_EVIDENCIA ae
       SET ACTIVE = FALSE, MODIFIED_BY = NEW.MODIFIED_BY, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE ae.FK_TACTIVIDAD = NEW.PK_TACTIVIDAD AND ae.ACTIVE = TRUE
       AND NOT EXISTS (SELECT 1
                         FROM academico_test.TREFERENTE_ENUNCIADO ev
                         JOIN academico_test.TUNIDAD_ENUNCIADO ue
                           ON ue.FK_REFERENTE_ENUNCIADO = ev.FK_PADRE
                          AND ue.FK_TUNIDAD = NEW.FK_TUNIDAD AND ue.ACTIVE = TRUE
                        WHERE ev.PK_REFERENTE_ENUNCIADO = ae.FK_REFERENTE_ENUNCIADO);

    UPDATE academico_test.TACTIVIDAD_CRITERIO_UNIDAD ac
       SET ACTIVE = FALSE, MODIFIED_BY = NEW.MODIFIED_BY, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE ac.FK_TACTIVIDAD = NEW.PK_TACTIVIDAD AND ac.ACTIVE = TRUE
       AND NOT EXISTS (SELECT 1
                         FROM academico_test.TCRITERIO_UNIDAD cu
                         JOIN academico_test.TRUBRICA_UNIDAD ru ON ru.PK_TRUBRICA_UNIDAD = cu.FK_TRUBRICA_UNIDAD
                        WHERE cu.PK_TCRITERIO_UNIDAD = ac.FK_TCRITERIO_UNIDAD
                          AND ru.FK_TUNIDAD = NEW.FK_TUNIDAD);
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS tr_tactividad_depurar_por_unidad ON academico_test.TACTIVIDAD;
CREATE TRIGGER tr_tactividad_depurar_por_unidad
    AFTER UPDATE OF FK_TUNIDAD ON academico_test.TACTIVIDAD
    FOR EACH ROW
    WHEN (OLD.FK_TUNIDAD IS DISTINCT FROM NEW.FK_TUNIDAD)
    EXECUTE FUNCTION academico_test.tg_tactividad_depurar_por_unidad();

-- El mínimo de evidencias (V483) se revisa al quitar una evidencia de la
-- unidad ACTUAL. Las que el trigger anterior suelta por cambio de unidad no
-- eran de ella: que la actividad elija las nuevas lo exige el PATCH.
CREATE OR REPLACE FUNCTION academico_test.tg_planeador_minimo_enunciado_evidencia()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_fila RECORD;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_fila := OLD;
    ELSE
        v_fila := NEW;
    END IF;

    CASE TG_TABLE_NAME
        WHEN 'tunidad' THEN
            PERFORM academico_test.fn_unidad_assert_minimo_enunciado(v_fila.PK_TUNIDAD);
        WHEN 'tunidad_enunciado' THEN
            PERFORM academico_test.fn_unidad_assert_minimo_enunciado(v_fila.FK_TUNIDAD);
        WHEN 'tactividad' THEN
            PERFORM academico_test.fn_actividad_assert_minimo_evidencia(v_fila.PK_TACTIVIDAD);
        WHEN 'tactividad_evidencia' THEN
            IF EXISTS (SELECT 1
                         FROM academico_test.TACTIVIDAD a
                         JOIN academico_test.TREFERENTE_ENUNCIADO ev ON ev.PK_REFERENTE_ENUNCIADO = v_fila.FK_REFERENTE_ENUNCIADO
                         JOIN academico_test.TUNIDAD_ENUNCIADO ue
                           ON ue.FK_TUNIDAD = a.FK_TUNIDAD AND ue.FK_REFERENTE_ENUNCIADO = ev.FK_PADRE
                        WHERE a.PK_TACTIVIDAD = v_fila.FK_TACTIVIDAD) THEN
                PERFORM academico_test.fn_actividad_assert_minimo_evidencia(v_fila.FK_TACTIVIDAD);
            END IF;
    END CASE;
    RETURN NULL;
END;
$$;

-- ---------------------------------------------------------------------------
-- Alta
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_actividad_crear_interno(
    BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, VARCHAR, BIGINT, BIGINT, NUMERIC, DATE, DATE, NUMERIC, VARCHAR,
    BIGINT, VARCHAR, academico_test.bool_sn, BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, NUMERIC,
    academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, VARCHAR,
    JSONB, JSONB, BIGINT[], BOOLEAN, JSONB, BIGINT[], BIGINT[]);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_crear_interno(
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
    p_es_evaluativa                     academico_test.bool_sn DEFAULT NULL,
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
    p_recuperacion                      JSONB         DEFAULT NULL,
    p_evidencias                        BIGINT[]      DEFAULT NULL,
    p_criterios                         BIGINT[]      DEFAULT NULL,
    p_exigir_minimos                    BOOLEAN       DEFAULT TRUE
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_id             BIGINT;
    v_titulo         VARCHAR := TRIM(p_titulo);
    v_etiqueta       VARCHAR := academico_test.fn_actividad_etiqueta_de(p_titulo, p_fk_tgrupo, p_fk_tasignatura, p_fk_tunidad);
    v_ctx_evaluativo BOOLEAN;
    v_evaluativa     academico_test.bool_sn;
    v_todo_el_grupo  BOOLEAN := COALESCE(p_asignar_todo_el_grupo, FALSE);
BEGIN
    PERFORM academico_test.fn_actividad_validar_campos(
        TRUE, p_titulo, p_fk_tasignatura, p_fk_tlv_tipo_actividad, p_fk_tlv_jerarquia,
        p_descripcion, p_material_requerido, p_descripcion_instrumento, p_fk_tlv_modalidad,
        p_fk_tlv_instrumento_evaluacion, p_fk_tlv_tipo_evidencia, p_fk_tlv_metodo_valoracion,
        p_fk_tlv_tipo_calculo, p_nota_maxima, p_materiales, p_adaptaciones, p_recuperacion);

    -- Sin valor enviado, "¿Es sumativa?" es la que le corresponde al referente.
    v_ctx_evaluativo := academico_test.fn_actividad_contexto_evaluativo(p_fk_tgrupo, p_fk_tasignatura, p_fk_tunidad);
    v_evaluativa     := COALESCE(p_es_evaluativa, CASE WHEN v_ctx_evaluativo THEN 'S' ELSE 'N' END);

    PERFORM academico_test.fn_actividad_validar_coherencia(
        v_etiqueta, p_fk_tasignatura, p_fk_tgrupo, p_fk_tunidad, p_ponderacion, p_nota_maxima,
        v_evaluativa, v_ctx_evaluativo, p_recuperacion IS NOT NULL, p_fk_tlv_instrumento_evaluacion,
        p_fecha_inicio, p_fecha_cierre, p_duracion_estimada, p_semana_cronograma,
        p_evidencias, TRUE, p_exigir_minimos);
    PERFORM academico_test.fn_actividad_validar_titulo_unico(
        v_titulo, p_fk_tunidad, p_fk_tgrupo, p_fk_tlv_jerarquia);

    -- La regla del 100% por (unidad, grupo) la impone tr_tactividad_ponderacion_unidad.
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
        v_titulo, NULLIF(TRIM(p_descripcion), ''), CURRENT_DATE,
        p_fk_tasignatura, p_fk_tgrupo, p_fk_tunidad, p_ponderacion,
        p_fk_tlv_tipo_actividad, p_fk_tlv_jerarquia, p_fk_tlv_tipo_calculo,
        p_influencia, p_nota_maxima,
        p_fecha_inicio, p_fecha_cierre, p_duracion_estimada, NULLIF(TRIM(p_semana_cronograma), ''),
        p_fk_tlv_modalidad, NULLIF(TRIM(p_material_requerido), ''),
        v_evaluativa, CASE WHEN p_recuperacion IS NOT NULL THEN 'S' ELSE 'N' END,
        p_fk_tlv_instrumento_evaluacion, NULLIF(TRIM(p_descripcion_instrumento), ''),
        p_fk_tlv_tipo_evidencia, p_fk_tlv_metodo_valoracion,
        COALESCE(p_requiere_archivo, 'N'), COALESCE(p_requiere_texto, 'N'),
        COALESCE(p_genera_evidencias, 'N'), COALESCE(p_requiere_validacion_coordinador, 'N'),
        NULLIF(TRIM(p_observaciones_docente), ''),
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TACTIVIDAD INTO v_id;

    PERFORM academico_test.fn_unidad_ponderacion_recalcular_sumatoria(p_fk_tunidad, p_fk_tgrupo);

    -- Bloque 1: por defecto, todos los estudiantes del grupo.
    IF p_fk_tmatriculas IS NULL AND p_fk_tgrupo IS NOT NULL THEN
        v_todo_el_grupo := TRUE;
    END IF;
    -- ORDEN IMPORTA: estudiantes antes que adaptaciones.
    PERFORM academico_test.fn_actividad_estudiantes_asignar_interno(
        p_pk_usuario_solicitante, v_id, p_fk_tmatriculas, v_todo_el_grupo);
    IF p_exigir_minimos THEN
        PERFORM academico_test.fn_actividad_validar_estudiantes_minimo(v_id);
    END IF;
    PERFORM academico_test.fn_actividad_material_reemplazar_interno(p_pk_usuario_solicitante, v_id, p_materiales);
    PERFORM academico_test.fn_actividad_adaptacion_reemplazar_interno(p_pk_usuario_solicitante, v_id, p_adaptaciones);
    IF p_recuperacion IS NOT NULL THEN
        PERFORM academico_test.fn_actividad_recuperacion_configurar_interno(p_pk_usuario_solicitante, v_id, p_recuperacion);
    END IF;
    PERFORM academico_test.fn_actividad_evidencias_set_interno(p_pk_usuario_solicitante, v_id, p_evidencias);
    PERFORM academico_test.fn_actividad_criterios_set_interno(p_pk_usuario_solicitante, v_id, p_criterios);

    RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- PATCH: las reglas se aplican sobre los valores que QUEDAN, y los mínimos
-- del formulario solo sobre lo que el PATCH toca (una actividad vieja sin
-- evidencias se sigue pudiendo renombrar).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_actualizar_interno(
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
    p_materiales                        JSONB         DEFAULT NULL,
    p_adaptaciones                      JSONB         DEFAULT NULL,
    p_fk_tmatriculas                    BIGINT[]      DEFAULT NULL,
    p_asignar_todo_el_grupo             BOOLEAN       DEFAULT FALSE,
    p_recuperacion                      JSONB         DEFAULT NULL,
    p_quitar_recuperacion               BOOLEAN       DEFAULT FALSE,
    p_evidencias                        BIGINT[]      DEFAULT NULL,
    p_criterios                         BIGINT[]      DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_actual         academico_test.TACTIVIDAD%ROWTYPE;
    v_titulo         VARCHAR(250);
    v_asignatura     BIGINT;
    v_grupo          BIGINT;
    v_unidad         BIGINT;
    v_ponderacion    NUMERIC;
    v_instrumento    BIGINT;
    v_evaluativa     academico_test.bool_sn;
    v_ctx_evaluativo BOOLEAN;
    v_cambia_unidad  BOOLEAN;
    v_cambia_grupo   BOOLEAN;
    v_evidencias     BIGINT[];
    v_todo_el_grupo  BOOLEAN := COALESCE(p_asignar_todo_el_grupo, FALSE);
BEGIN
    PERFORM academico_test.fn_actividad_validar_existente(p_pk_tactividad);
    PERFORM academico_test.fn_actividad_validar_activa(p_pk_tactividad);
    SELECT * INTO v_actual FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad;

    IF p_desvincular_unidad AND (p_fk_tunidad IS NOT NULL OR p_ponderacion IS NOT NULL) THEN
        RAISE EXCEPTION 'No se puede quitar % de su unidad y a la vez asignarle una unidad o un peso: elija una de las dos cosas',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad) USING ERRCODE = '22023';
    END IF;
    IF p_quitar_recuperacion AND p_recuperacion IS NOT NULL THEN
        RAISE EXCEPTION 'No se puede quitar y configurar la recuperación de % en la misma operación: elija una de las dos cosas',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad) USING ERRCODE = '22023';
    END IF;

    PERFORM academico_test.fn_actividad_validar_campos(
        FALSE, p_titulo, p_fk_tasignatura, p_fk_tlv_tipo_actividad, NULL,
        p_descripcion, p_material_requerido, p_descripcion_instrumento, p_fk_tlv_modalidad,
        p_fk_tlv_instrumento_evaluacion, p_fk_tlv_tipo_evidencia, p_fk_tlv_metodo_valoracion,
        p_fk_tlv_tipo_calculo, p_nota_maxima, p_materiales, p_adaptaciones, p_recuperacion);

    v_titulo        := COALESCE(NULLIF(TRIM(p_titulo), ''), v_actual.TITULO);
    v_asignatura    := COALESCE(p_fk_tasignatura, v_actual.FK_TASIGNATURA);
    v_grupo         := COALESCE(p_fk_tgrupo, v_actual.FK_TGRUPO);
    v_unidad        := CASE WHEN p_desvincular_unidad THEN NULL ELSE COALESCE(p_fk_tunidad, v_actual.FK_TUNIDAD) END;
    v_cambia_unidad := v_unidad IS DISTINCT FROM v_actual.FK_TUNIDAD;
    v_cambia_grupo  := v_grupo IS DISTINCT FROM v_actual.FK_TGRUPO;
    v_ponderacion   := CASE WHEN v_unidad IS NULL THEN NULL
                            ELSE COALESCE(p_ponderacion, CASE WHEN v_cambia_unidad THEN NULL ELSE v_actual.PONDERACION END) END;
    v_instrumento   := COALESCE(p_fk_tlv_instrumento_evaluacion, v_actual.FK_TLV_INSTRUMENTO_EVALUACION);
    v_ctx_evaluativo := academico_test.fn_actividad_contexto_evaluativo(v_grupo, v_asignatura, v_unidad);
    v_evaluativa    := COALESCE(p_es_evaluativa, v_actual.ES_EVALUATIVA,
                                CASE WHEN v_ctx_evaluativo THEN 'S' ELSE 'N' END);
    -- Con unidad nueva, las evidencias de la anterior se sueltan (Regla 36).
    v_evidencias    := COALESCE(p_evidencias, CASE WHEN v_cambia_unidad THEN ARRAY[]::BIGINT[] END);

    PERFORM academico_test.fn_actividad_validar_coherencia(
        academico_test.fn_actividad_etiqueta_de(v_titulo, v_grupo, v_asignatura, v_unidad), v_asignatura, v_grupo, v_unidad, v_ponderacion,
        COALESCE(p_nota_maxima, v_actual.NOTA_MAXIMA),
        v_evaluativa, v_ctx_evaluativo,
        p_recuperacion IS NOT NULL OR (v_actual.ES_RECUPERACION = 'S' AND NOT p_quitar_recuperacion),
        v_instrumento,
        COALESCE(p_fecha_inicio, v_actual.FECHA_INICIO), COALESCE(p_fecha_cierre, v_actual.FECHA_CIERRE),
        COALESCE(p_duracion_estimada, v_actual.DURACION_ESTIMADA),
        COALESCE(NULLIF(TRIM(p_semana_cronograma), ''), v_actual.SEMANA_CRONOGRAMA),
        v_evidencias, v_evidencias IS NOT NULL,
        v_cambia_unidad OR p_evidencias IS NOT NULL OR p_ponderacion IS NOT NULL);
    -- Contra la unidad RESULTANTE: con la vieja, mover de unidad comparaba
    -- contra el bucket equivocado.
    PERFORM academico_test.fn_actividad_validar_titulo_unico(
        v_titulo, v_unidad, v_grupo, v_actual.FK_TLV_JERARQUIA, p_pk_tactividad);

    UPDATE academico_test.TACTIVIDAD
       SET TITULO                          = v_titulo,
           DESCRIPCION                     = CASE WHEN p_descripcion IS NULL THEN DESCRIPCION
                                                  ELSE NULLIF(TRIM(p_descripcion), '') END,
           FK_TASIGNATURA                  = v_asignatura,
           FK_TGRUPO                       = v_grupo,
           FK_TLV_TIPO_ACTIVIDAD           = COALESCE(p_fk_tlv_tipo_actividad, FK_TLV_TIPO_ACTIVIDAD),
           FECHA_INICIO                    = COALESCE(p_fecha_inicio, FECHA_INICIO),
           FECHA_CIERRE                    = COALESCE(p_fecha_cierre, FECHA_CIERRE),
           DURACION_ESTIMADA               = COALESCE(p_duracion_estimada, DURACION_ESTIMADA),
           SEMANA_CRONOGRAMA               = COALESCE(NULLIF(TRIM(p_semana_cronograma), ''), SEMANA_CRONOGRAMA),
           FK_TLV_MODALIDAD                = COALESCE(p_fk_tlv_modalidad, FK_TLV_MODALIDAD),
           MATERIAL_REQUERIDO              = CASE WHEN p_material_requerido IS NULL THEN MATERIAL_REQUERIDO
                                                  ELSE NULLIF(TRIM(p_material_requerido), '') END,
           ES_EVALUATIVA                   = v_evaluativa,
           FK_TLV_INSTRUMENTO_EVALUACION   = v_instrumento,
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

    -- Unidad / peso: la regla del 100% es de los núcleos de unidad. Elegir otra
    -- unidad en el formulario ya es la confirmación de moverla.
    IF p_desvincular_unidad THEN
        PERFORM academico_test.fn_unidad_actividad_desvincular_interno(p_pk_usuario_solicitante, p_pk_tactividad);
    ELSIF p_fk_tunidad IS NOT NULL THEN
        PERFORM academico_test.fn_unidad_actividad_vincular_interno(
            p_pk_usuario_solicitante, p_pk_tactividad, p_fk_tunidad, p_ponderacion, TRUE);
    ELSIF p_ponderacion IS NOT NULL THEN
        PERFORM academico_test.fn_unidad_actividad_ponderacion_set_interno(
            p_pk_usuario_solicitante, p_pk_tactividad, p_ponderacion);
    END IF;

    -- Sumatoria: se recalcula el bucket destino y, si cambió, el de origen.
    PERFORM academico_test.fn_unidad_ponderacion_recalcular_sumatoria(v_unidad, v_grupo);
    IF v_actual.FK_TUNIDAD IS NOT NULL AND (v_cambia_unidad OR v_cambia_grupo) THEN
        PERFORM academico_test.fn_unidad_ponderacion_recalcular_sumatoria(v_actual.FK_TUNIDAD, v_actual.FK_TGRUPO);
    END IF;

    -- Regla 35: con otro grupo, los estudiantes del anterior no aplican.
    IF v_cambia_grupo AND p_fk_tmatriculas IS NULL THEN
        v_todo_el_grupo := TRUE;
    END IF;
    PERFORM academico_test.fn_actividad_estudiantes_asignar_interno(
        p_pk_usuario_solicitante, p_pk_tactividad, p_fk_tmatriculas, v_todo_el_grupo);
    IF p_fk_tmatriculas IS NOT NULL OR v_todo_el_grupo THEN
        PERFORM academico_test.fn_actividad_validar_estudiantes_minimo(p_pk_tactividad);
    END IF;
    PERFORM academico_test.fn_actividad_material_reemplazar_interno(p_pk_usuario_solicitante, p_pk_tactividad, p_materiales);
    PERFORM academico_test.fn_actividad_adaptacion_reemplazar_interno(p_pk_usuario_solicitante, p_pk_tactividad, p_adaptaciones);

    IF p_quitar_recuperacion THEN
        PERFORM academico_test.fn_actividad_recuperacion_configurar_interno(p_pk_usuario_solicitante, p_pk_tactividad, NULL);
    ELSIF p_recuperacion IS NOT NULL THEN
        PERFORM academico_test.fn_actividad_recuperacion_configurar_interno(p_pk_usuario_solicitante, p_pk_tactividad, p_recuperacion);
    END IF;

    PERFORM academico_test.fn_actividad_evidencias_set_interno(p_pk_usuario_solicitante, p_pk_tactividad, p_evidencias);
    PERFORM academico_test.fn_actividad_criterios_set_interno(p_pk_usuario_solicitante, p_pk_tactividad, p_criterios);

    RETURN p_pk_tactividad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_crear_interno(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, VARCHAR, BIGINT, BIGINT, NUMERIC, DATE, DATE, NUMERIC, VARCHAR, BIGINT, VARCHAR, academico_test.bool_sn, BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, NUMERIC, academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, VARCHAR, JSONB, JSONB, BIGINT[], BOOLEAN, JSONB, BIGINT[], BIGINT[], BOOLEAN)
    IS 'INTERNO: alta de actividad sin gate ni etiqueta (validaciones de V496.1 + INSERT + satélites). Sin estudiantes explícitos asigna todo el grupo. p_exigir_minimos (TRUE) exige peso/puntaje según la unidad, al menos una evidencia de la unidad y un estudiante; la importación lo apaga. La usan fn_actividad_crear y fn_actividad_importar.';
COMMENT ON FUNCTION academico_test.fn_actividad_actualizar_interno(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, BOOLEAN, BIGINT, DATE, DATE, NUMERIC, VARCHAR, BIGINT, VARCHAR, academico_test.bool_sn, BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, NUMERIC, academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, VARCHAR, JSONB, JSONB, BIGINT[], BOOLEAN, JSONB, BOOLEAN, BIGINT[], BIGINT[])
    IS 'INTERNO: PATCH de actividad sin gate ni etiqueta; valida sobre los valores resultantes y aplica UPDATE + unidad + satélites. Cambiar la unidad suelta las evidencias de la anterior y exige marcar las nuevas; cambiar el grupo reasigna todo el grupo si no llegan estudiantes. La usa fn_actividad_actualizar.';
COMMENT ON FUNCTION academico_test.fn_actividad_estudiantes_asignar_interno(BIGINT, BIGINT, BIGINT[], BOOLEAN)
    IS 'INTERNO: reemplazo del set de estudiantes de la actividad (matrículas activas de su grupo); quien sale, sale también de sus adaptaciones. NULL/FALSE = no tocar. La usan crear/actualizar_interno y fn_actividad_estudiantes_set.';
COMMENT ON FUNCTION academico_test.fn_actividad_material_reemplazar_interno(BIGINT, BIGINT, JSONB)
    IS 'INTERNO: reemplazo de los materiales de apoyo (máximo 10, archivo o enlace http(s)). NULL = no tocar. La usan crear/actualizar_interno y fn_actividad_material_reemplazar.';
COMMENT ON FUNCTION academico_test.fn_actividad_adaptacion_reemplazar_interno(BIGINT, BIGINT, JSONB)
    IS 'INTERNO: reemplazo de las adaptaciones curriculares; sus estudiantes deben ser de la actividad. NULL = no tocar. La usan crear/actualizar_interno y fn_actividad_adaptacion_reemplazar.';
COMMENT ON FUNCTION academico_test.fn_actividad_recuperacion_configurar_interno(BIGINT, BIGINT, JSONB)
    IS 'INTERNO: configuración 1:1 de recuperación. NULL = deja de ser recuperación (revierte lo aplicado). La actividad a recuperar debe cumplir fn_actividad_validar_recuperable. La usan crear/actualizar_interno.';
COMMENT ON FUNCTION academico_test.fn_actividad_evidencias_set_interno(BIGINT, BIGINT, BIGINT[])
    IS 'INTERNO: reemplazo del set de evidencias de la actividad; cada una validada contra la unidad. NULL = no tocar. La usan crear/actualizar_interno.';
COMMENT ON FUNCTION academico_test.fn_actividad_criterios_set_interno(BIGINT, BIGINT, BIGINT[])
    IS 'INTERNO: reemplazo del set de criterios de la rúbrica de la unidad que evalúan la actividad. NULL = no tocar. La usan crear/actualizar_interno.';
COMMENT ON FUNCTION academico_test.fn_actividad_recuperacion_campos_disponibles(BOOLEAN, VARCHAR, BOOLEAN, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT)
    IS 'La sección "Es una recuperación" del formulario: {visible, requerido, motivo, recuperarConsultado, catalogos, reglas, actividadesRecuperables, origen}. visible exige referente evaluativo, sumativa y nivel distinto de Preescolar. actividadesRecuperables (con p_recuperar = S): las sumativas del (grupo, asignatura), no recuperación, con resultados (Regla 64); puede tener ya otros Refuerzos (Regla 67). origen (con p_fk_tactividad_recuperar): alcance VER y fn_actividad_validar_recuperable antes de devolver el contexto heredado y los estudiantes con su nota previa.';
