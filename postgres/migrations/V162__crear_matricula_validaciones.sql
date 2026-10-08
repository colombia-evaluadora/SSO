-- ===========================================================================
-- V162 - Validaciones de matricula: estudiante disponible, dependencias
-- bloqueantes, periodo vigente, jornadas y periodos por sede.
-- fn_periodo_resolver_matricula vive en V415; fn_matricula_validar_cupo en V205.
-- ===========================================================================


CREATE OR REPLACE FUNCTION academico_test.fn_matricula_validar_estudiante_disponible(
    p_fk_testudiante BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
AS $function$
DECLARE
    v_ano_actual              VARCHAR(4);
    v_pk_matricula_existente  BIGINT;
BEGIN
    v_ano_actual := EXTRACT(YEAR FROM CURRENT_DATE)::VARCHAR;

    SELECT m.PK_TMATRICULA
      INTO v_pk_matricula_existente
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr           ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO g            ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TANO_LECTIVO al     ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
     WHERE m.FK_TESTUDIANTE = p_fk_testudiante
       AND m.ACTIVE         = TRUE
       AND al.NOMBRE        = v_ano_actual
     LIMIT 1;

    IF v_pk_matricula_existente IS NOT NULL THEN
        RAISE EXCEPTION 'El estudiante ya tiene una matricula activa en el año lectivo actual (%)',
            v_ano_actual
            USING ERRCODE = '23505',
                  HINT    = 'Un estudiante no puede tener mas de una matricula activa por año lectivo';
    END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_dependencias_bloqueantes(
    p_fk_tmatricula BIGINT
)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_tabla   TEXT;
    v_columna TEXT;
    v_nombre  TEXT;
    v_n       BIGINT;
BEGIN
    -- Nombres en minuscula a proposito: format('%I') cita el identificador
    -- preservando la caja, y las tablas reales estan en minuscula --
    -- 'TASIGNATURA_NOTA' generaria "TASIGNATURA_NOTA", que no existe.
    FOR v_tabla, v_columna, v_nombre IN
        SELECT * FROM (VALUES
            ('tasignatura_nota',              'fk_tmatricula',          'calificaciones de asignatura'),
            ('tasignatura_definitiva',        'fk_tmatricula',          'definitivas de asignatura'),
            ('tarea_nota',                    'fk_tmatricula',          'calificaciones de tareas'),
            ('tarea_definitiva',              'fk_tmatricula',          'definitivas de tareas'),
            ('tunidad_nota',                  'fk_tmatricula',          'calificaciones por unidad'),
            ('tactividad_estudiante',         'fk_tmatricula',          'actividades del estudiante'),
            ('trecomendaciones_calificacion', 'fk_tmatricula',          'recomendaciones de calificacion'),
            ('tcomportamiento_calificado',    'fk_tmatricula',          'registros de comportamiento'),
            ('tasistencia',                   'fk_tmatricula',          'registros de asistencia'),
            ('tmatricula_asignatura',         'fk_tmatricula',          'asignaturas matriculadas'),
            ('tmatricula_promocion',          'fk_tmatricula',          'registros de promocion'),
            ('tacta_grado_detalle',           'fk_tmatricula',          'actas de grado'),
            ('tdiploma_detalle',              'fk_tmatricula',          'diplomas'),
            ('tretiro_matricula',             'fk_tmatricula',          'retiros de matricula'),
            ('ttraslado_matricula',           'fk_tmatricula',          'traslados de matricula'),
            ('tsede_convenio_matricula',      'fk_tmatricula',          'convenios de sede'),
            ('tlog_carnet',                   'fk_tmatricula',          'registros de carnet'),
            ('tvideo_usuarios',               'fk_tmatricula',          'videos del estudiante'),
            ('tmatricula',                    'fk_tmatricula_anterior', 'otra matricula que la referencia como antecedente')
        ) AS t(tabla, columna, nombre)
    LOOP
        EXECUTE format(
            'SELECT COUNT(*) FROM academico_test.%I WHERE %I = $1 AND ACTIVE = TRUE',
            v_tabla, v_columna)
        INTO v_n USING p_fk_tmatricula;

        IF v_n > 0 THEN
            RETURN v_nombre || ' (' || v_n || ')';
        END IF;
    END LOOP;

    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_estudiante_dependencias_bloqueantes(
    p_fk_testudiante      BIGINT,
    p_excluir_tmatricula  BIGINT DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_n BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_n FROM academico_test.TOBSERVADOR
     WHERE FK_TESTUDIANTE = p_fk_testudiante AND ACTIVE = TRUE;
    IF v_n > 0 THEN RETURN 'observador del estudiante (' || v_n || ')'; END IF;

    SELECT COUNT(*) INTO v_n FROM academico_test.TMATRICULA
     WHERE FK_TESTUDIANTE = p_fk_testudiante AND ACTIVE = TRUE
       AND PK_TMATRICULA IS DISTINCT FROM p_excluir_tmatricula;
    IF v_n > 0 THEN RETURN 'otras matriculas activas (' || v_n || ')'; END IF;

    SELECT COUNT(*) INTO v_n FROM academico_test.TPREMATRICULA
     WHERE FK_TESTUDIANTE = p_fk_testudiante AND ACTIVE = TRUE;
    IF v_n > 0 THEN RETURN 'prematriculas (' || v_n || ')'; END IF;

    SELECT COUNT(*) INTO v_n FROM academico_test.TINSCRIPCION
     WHERE FK_TESTUDIANTE = p_fk_testudiante AND ACTIVE = TRUE;
    IF v_n > 0 THEN RETURN 'inscripciones (' || v_n || ')'; END IF;

    SELECT COUNT(*) INTO v_n FROM academico_test.TRESERVA_CUPO
     WHERE FK_TESTUDIANTE = p_fk_testudiante AND ACTIVE = TRUE;
    IF v_n > 0 THEN RETURN 'reservas de cupo (' || v_n || ')'; END IF;

    SELECT COUNT(*) INTO v_n FROM academico_test.TTRASLADO_ESTUDIANTE
     WHERE FK_TESTUDIANTE = p_fk_testudiante AND ACTIVE = TRUE;
    IF v_n > 0 THEN RETURN 'traslados de estudiante (' || v_n || ')'; END IF;

    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_usuario_otros_usos(
    p_pk_usuario          BIGINT,
    p_excluir_testudiante BIGINT DEFAULT NULL,
    p_excluir_tpadre      BIGINT DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_n BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_n FROM academico_test.TFUNCIONARIO
     WHERE FK_TUSUARIO = p_pk_usuario AND ACTIVE = TRUE;
    IF v_n > 0 THEN RETURN 'es funcionario'; END IF;

    SELECT COUNT(*) INTO v_n FROM academico_test.TESTUDIANTE
     WHERE FK_TUSUARIO = p_pk_usuario AND ACTIVE = TRUE
       AND PK_TESTUDIANTE IS DISTINCT FROM p_excluir_testudiante;
    IF v_n > 0 THEN RETURN 'es estudiante en otro registro'; END IF;

    SELECT COUNT(*) INTO v_n FROM academico_test.TPADRE
     WHERE FK_TUSUARIO = p_pk_usuario AND ACTIVE = TRUE
       AND PK_TPADRE IS DISTINCT FROM p_excluir_tpadre;
    IF v_n > 0 THEN RETURN 'es acudiente en otro registro'; END IF;

    SELECT COUNT(*) INTO v_n FROM academico_test.TSEDE_USUARIO
     WHERE FK_TUSUARIO = p_pk_usuario AND ACTIVE = TRUE;
    IF v_n > 0 THEN RETURN 'tiene permisos de sede vigentes (' || v_n || ')'; END IF;

    SELECT COUNT(*) INTO v_n FROM academico_test.TENTE_USUARIO
     WHERE FK_TUSUARIO = p_pk_usuario AND ACTIVE = TRUE;
    IF v_n > 0 THEN RETURN 'esta vinculado a un ente territorial'; END IF;

    SELECT COUNT(*) INTO v_n FROM academico_test.TINSCRIPCION
     WHERE FK_TUSUARIO = p_pk_usuario AND ACTIVE = TRUE;
    IF v_n > 0 THEN RETURN 'figura en inscripciones'; END IF;

    SELECT COUNT(*) INTO v_n FROM academico_test.TRESERVA_CUPO
     WHERE FK_TUSUARIO = p_pk_usuario AND ACTIVE = TRUE;
    IF v_n > 0 THEN RETURN 'figura en reservas de cupo'; END IF;

    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_validar_periodo_vigente(
    p_pk_tmatricula BIGINT,
    p_accion        VARCHAR DEFAULT 'modificar'
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_fecha_fin      DATE;
    v_periodo_nombre VARCHAR;
BEGIN
    SELECT pa.FECHA_FIN, pa.NOMBRE
      INTO v_fecha_fin, v_periodo_nombre
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr              ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO g               ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa  ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
     WHERE m.PK_TMATRICULA = p_pk_tmatricula;

    IF v_fecha_fin IS NULL THEN
        RAISE EXCEPTION 'No se pudo identificar el periodo académico de la matrícula de %.',
            (SELECT CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)
               FROM academico_test.TMATRICULA m
               JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
               JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = es.FK_TUSUARIO
              WHERE m.PK_TMATRICULA = p_pk_tmatricula)
            USING ERRCODE = '23503';
    END IF;

    IF v_fecha_fin < CURRENT_DATE THEN
        RAISE EXCEPTION 'No se puede % la matrícula de %: su periodo académico (%) terminó el %.',
            p_accion, (SELECT CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)
               FROM academico_test.TMATRICULA m
               JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
               JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = es.FK_TUSUARIO
              WHERE m.PK_TMATRICULA = p_pk_tmatricula),
            COALESCE(v_periodo_nombre, 'sin nombre'), to_char(v_fecha_fin, 'DD/MM/YYYY')
            USING ERRCODE = '22023',
                  HINT    = 'Las acciones sobre una matricula solo se permiten mientras su periodo academico siga en curso';
    END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_jornadas_activas_por_sede(
    p_fk_sede    BIGINT,
    p_pk_usuario BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, nombre VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT jor.PK_LISTA_VALOR, jor.NOMBRE
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TANO_LECTIVO al  ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
      JOIN academico_test.TLISTA_VALOR jor ON jor.PK_LISTA_VALOR = pa.FK_TLV_JORNADA
     WHERE pa.FK_TSEDE = p_fk_sede
       AND pa.ACTIVE  = TRUE
       AND al.ACTIVE  = TRUE
       AND al.NOMBRE  = to_char(CURRENT_DATE, 'YYYY')
       AND academico_test.fn_periodo_puede_ver(p_pk_usuario, pa.PK_TPERIODO_ACADEMICO)
     ORDER BY jor.NOMBRE;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_sede_tiene_periodos(
    p_fk_sede BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM academico_test.TPERIODO_ACADEMICO
         WHERE FK_TSEDE = p_fk_sede
    );
$$;
