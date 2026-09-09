-- =============================================================================
-- V162 -- Validaciones para el flujo de matricula: resolver el
-- TPERIODO_ACADEMICO vigente a partir de (sede, jornada), con el año
-- lectivo actual, y validar que la fecha limite de matricula no haya
-- pasado.
--
-- Contexto: TPERIODO_ACADEMICO combina sede + año lectivo + jornada +
-- fechas en un solo registro.
--
-- REV -- se penso originalmente que el NOMBRE del periodo, armado a partir
-- de esos mismos campos, garantizaba "0 o 1" resultado por (sede, jornada,
-- año) y que por eso no hacia falta desambiguar. Los datos lo desmienten:
-- la sede 1373 / jornada 51900 tiene dos periodos activos de 2026 ("2026" y
-- "2026A"). Con un LIMIT 1 sin ORDER BY el resultado era NO DETERMINISTA
-- -- la misma llamada devolvia un periodo distinto entre ejecuciones y el
-- alta de matricula fallaba de forma intermitente con "El grupo indicado no
-- pertenece al periodo academico resuelto". Ahora hay dos salidas de esa
-- ambiguedad:
--
--   * p_fk_tgrupo (opcional): cuando el llamador YA eligio un grupo -- el
--     caso de fn_matricula_directa_crear -- el grupo determina el periodo
--     sin ambiguedad, y esta funcion se limita a verificar que ese periodo
--     sea el de la sede/jornada/año pedidos, que sea visible para el
--     solicitante y que la inscripcion ya haya cerrado.
--   * sin p_fk_tgrupo (el caso del front, que todavia no tiene grupo porque
--     justamente lo esta por listar): orden determinista -- gana el periodo
--     con la FECHA_LIMITE_MATRICULA mas reciente y, a igualdad, el PK mas
--     alto; es decir, el ultimo configurado.
--
-- Uso previsto (formulario "Agregar estudiante"): tras elegir sede y
-- jornada (ver fn_jornadas_activas_por_sede), el front resuelve el
-- periodo academico vigente con esta funcion antes de poder listar grados
-- (fn_grado_listar) y grupos (fn_grupo_listar), que si requieren el PK del
-- periodo.
-- =============================================================================

-- CREATE OR REPLACE no puede agregar un parametro: dejaria viva la version
-- de 3 argumentos y una llamada con 3 quedaria ambigua entre ambas. Se
-- elimina la firma anterior explicitamente.
DROP FUNCTION IF EXISTS academico_test.fn_periodo_resolver_matricula(BIGINT, BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_resolver_matricula(
    p_fk_sede         BIGINT,
    p_fk_tlv_jornada  BIGINT,
    p_pk_usuario      BIGINT DEFAULT NULL,
    p_fk_tgrupo       BIGINT DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_pk_periodo    BIGINT;
    v_fecha_limite  DATE;
    v_ano_actual    VARCHAR(4);
BEGIN
    v_ano_actual := EXTRACT(YEAR FROM CURRENT_DATE)::VARCHAR;

    -- -----------------------------------------------------------------
    -- 1. Resolver el periodo academico vigente para (sede, jornada, año
    --    actual). fn_periodo_usuario_puede_ver aplica el mismo gate de
    --    visibilidad que el resto del modulo de periodos -- si el
    --    solicitante no puede ver el periodo, se trata igual que si no
    --    existiera (no se filtra informacion de existencia a quien no
    --    tiene alcance).
    --
    --    REV -- fallback para rector/secretaria asignados SOLO por FK
    --    (TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR/SECRETARIA, sin
    --    TSEDE_USUARIO propio todavia). fn_periodo_usuario_puede_ver
    --    resuelve el alcance unicamente por TSEDE_USUARIO, asi que a esa
    --    persona le devolvia FALSE y esta funcion concluia "no existe el
    --    periodo" -- un mensaje ademas enganoso, porque el periodo si
    --    existe. El gate de fn_matricula_directa_crear SI acepta esa
    --    asignacion por FK, con lo cual el alta pasaba el gate y moria
    --    aca.
    --
    --    El fallback vive en NUESTRA funcion a proposito: no se toca
    --    fn_periodo_usuario_puede_ver ni el resto del modulo de periodos,
    --    que es de otro dueño y alimenta sus propias pantallas.
    --
    --    En la practica los permisos de rector/secretaria se crean solos
    --    al crear la sede (ver fn_sed_crear paso 6), asi que este camino
    --    deberia ser raro; queda como red de seguridad para el intervalo
    --    entre asignar el cargo y tener el permiso.
    -- -----------------------------------------------------------------
    SELECT pa.PK_TPERIODO_ACADEMICO, pa.FECHA_LIMITE_MATRICULA
      INTO v_pk_periodo, v_fecha_limite
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TANO_LECTIVO al
        ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
      JOIN academico_test.TSEDE s
        ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE pa.FK_TSEDE        = p_fk_sede
       AND pa.FK_TLV_JORNADA  = p_fk_tlv_jornada
       AND al.NOMBRE          = v_ano_actual
       AND pa.ACTIVE          = TRUE
       AND al.ACTIVE          = TRUE
       AND (
             academico_test.fn_periodo_usuario_puede_ver(p_pk_usuario, pa.PK_TPERIODO_ACADEMICO)
             OR EXISTS (
                 SELECT 1
                   FROM academico_test.TESTABLECIMIENTO e
                   JOIN academico_test.TFUNCIONARIO f
                     ON f.PK_TFUNCIONARIO IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA)
                  WHERE e.PK_ESTABLECIMIENTO = s.FK_TESTABLECIMIENTO
                    AND e.ACTIVE      = TRUE
                    AND f.ACTIVE      = TRUE
                    AND f.FK_TUSUARIO = p_pk_usuario
             )
           )
       -- Desambiguacion por grupo: si el llamador ya eligio un grupo, el
       -- periodo buscado es el del grupo y no hay nada que elegir.
       AND (
             p_fk_tgrupo IS NULL
             OR pa.PK_TPERIODO_ACADEMICO = (
                    SELECT g.FK_TPERIODO_ACADEMICO
                      FROM academico_test.TGRUPO gr
                      JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
                     WHERE gr.PK_TGRUPO = p_fk_tgrupo
                       AND gr.ACTIVE    = TRUE
                       AND g.ACTIVE     = TRUE
                )
           )
     -- Desempate determinista para el caso sin grupo: el ultimo periodo
     -- configurado para esa sede/jornada/año.
     ORDER BY pa.FECHA_LIMITE_MATRICULA DESC, pa.PK_TPERIODO_ACADEMICO DESC
     LIMIT 1;

    IF v_pk_periodo IS NULL AND p_fk_tgrupo IS NOT NULL THEN
        -- Con grupo dado, "no hay periodo" significa en realidad que el
        -- grupo cuelga de otro periodo (otra sede, otra jornada, otro año)
        -- o que su grado/grupo esta inactivo. Mensaje propio para no
        -- confundirlo con una sede sin periodo configurado.
        RAISE EXCEPTION 'El grupo indicado no pertenece al periodo academico vigente de la sede y jornada dadas'
            USING ERRCODE = '22023',
                  HINT    = 'p_fk_tgrupo debe pertenecer (via TGRADO) a un periodo activo de p_fk_sede/p_fk_tlv_jornada en el año en curso';
    END IF;

    IF v_pk_periodo IS NULL THEN
        RAISE EXCEPTION 'No existe un periodo academico activo para la sede indicada, esa jornada y el año actual (%)',
            v_ano_actual
            USING ERRCODE = '23503',
                  HINT    = 'Verifique que la sede tenga un periodo academico configurado para esta jornada en el año en curso, o que el usuario tenga alcance sobre el';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Validar que ya haya terminado el periodo de inscripcion.
    --    REV -- Esta funcion se usa para el flujo de MATRICULA DIRECTA
    --    (fn_matricula_crear, mas adelante). Mientras el periodo de
    --    inscripcion sigue abierto (CURRENT_DATE <= FECHA_LIMITE_MATRICULA)
    --    lo correcto es inscribir o prematricular, no matricular
    --    directamente -- por eso el gate rechaza ANTES de que venza esa
    --    fecha, al reves de como se penso originalmente (se penso que
    --    FECHA_LIMITE_MATRICULA marcaba el cierre para poder matricular;
    --    en realidad marca el cierre de inscripcion, que es cuando recien
    --    se habilita la matricula directa).
    -- -----------------------------------------------------------------
    IF CURRENT_DATE <= v_fecha_limite THEN
        RAISE EXCEPTION 'El periodo de inscripcion de este periodo academico aun no ha terminado (vence %)',
            v_fecha_limite
            USING ERRCODE = '22023',
                  HINT    = 'Mientras el periodo de inscripcion este abierto, use inscripcion o prematricula en vez de matricula directa';
    END IF;

    RETURN v_pk_periodo;
END;
$function$;

-- =============================================================================
-- fn_matricula_validar_estudiante_disponible -- valida que un estudiante no
-- tenga ya una matricula activa dentro del año lectivo actual. Un mismo
-- estudiante no puede estar matriculado dos veces (en la misma sede o en
-- otra) dentro del mismo año.
-- =============================================================================

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

-- =============================================================================
-- fn_matricula_validar_cupo -- valida que un grupo tenga cupo disponible
-- antes de matricular un estudiante.
--
-- Alcance actual (a definir mas adelante): la unica validacion es que la
-- cantidad de TMATRICULA activas ligadas al grupo no rebase su CAPACIDAD.
-- No se filtra aun por FK_TLV_ESTADO_MATRICULA (el negocio no ha definido
-- que estados "liberan" el cupo, p.ej. retirado/desertor/trasladado), ni
-- se suman reservas (TRESERVA_CUPO) o prematriculas (TPREMATRICULA) -- las
-- pruebas iniciales arrancan sin ese historial. Cuando se defina esa
-- regla, se agrega aqui sin cambiar la firma de la funcion.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_validar_cupo(
    p_fk_grupo BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
AS $function$
DECLARE
    v_capacidad     NUMERIC;
    v_matriculados  BIGINT;
BEGIN
    SELECT CAPACIDAD
      INTO v_capacidad
      FROM academico_test.TGRUPO
     WHERE PK_TGRUPO = p_fk_grupo
       AND ACTIVE    = TRUE;

    IF v_capacidad IS NULL THEN
        RAISE EXCEPTION 'No se encontro un grupo activo con el identificador %',
            p_fk_grupo
            USING ERRCODE = '23503', HINT = 'p_fk_grupo debe apuntar a un TGRUPO activo';
    END IF;

    SELECT COUNT(*)
      INTO v_matriculados
      FROM academico_test.TMATRICULA
     WHERE FK_TGRUPO = p_fk_grupo
       AND ACTIVE    = TRUE;

    IF v_matriculados >= v_capacidad THEN
        RAISE EXCEPTION 'El grupo ya alcanzo su capacidad maxima (% de % cupos ocupados)',
            v_matriculados, v_capacidad
            USING ERRCODE = '22023',
                  HINT    = 'No hay cupos disponibles en este grupo';
    END IF;
END;
$function$;

-- =============================================================================
-- VALIDACIONES DE BAJA
-- -----------------------------------------------------------------------------
-- Las tres funciones de abajo NO lanzan excepcion: devuelven el NOMBRE de la
-- primera dependencia encontrada (o NULL si no hay ninguna). Quien decide que
-- hacer con esa respuesta es el caller:
--   - fn_matricula_dependencias_bloqueantes  -> si devuelve algo, se ABORTA la
--     baja con un mensaje que nombra la dependencia.
--   - fn_estudiante_dependencias_bloqueantes -> si devuelve algo, NO se aborta:
--     simplemente el estudiante no se da de baja (la matricula si).
--   - fn_usuario_otros_usos                  -> si devuelve algo, el TUSUARIO se
--     conserva y solo se le quitan los permisos de sede del rol que
--     corresponda.
-- Devolver texto en vez de lanzar deja la politica en el orquestador, que es
-- donde cambia segun el caso, y permite reusar la misma consulta para un
-- futuro "puedo borrar esto?" del front sin provocar un error.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- fn_matricula_dependencias_bloqueantes -- toda entidad viva que cuelgue de la
-- matricula y que NO se elimine en cascada con ella.
--
-- Se cae del listado a proposito (unica cascada libre, ver V166):
--   TMATRICULA_SOCIOECONOMICO y TMATRICULA_ARCHIVO.
--
-- Incluye la auto-referencia TMATRICULA.FK_TMATRICULA_ANTERIOR: si una
-- matricula posterior apunta a esta como su antecedente, borrarla dejaria esa
-- cadena rota.
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- fn_estudiante_dependencias_bloqueantes -- lo que impide dar de baja al
-- TESTUDIANTE una vez borrada la matricula. Incluye el observador, que cuelga
-- del estudiante y no de la matricula.
--
-- p_excluir_tmatricula deja fuera la matricula que se esta borrando en esta
-- misma operacion: cuando se llama, esa fila ya esta inactiva, pero el
-- parametro mantiene la funcion utilizable desde otros contextos.
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- fn_usuario_otros_usos -- que mas hace este TUSUARIO en el sistema, aparte del
-- estudiante y/o el acudiente que se estan dando de baja en esta operacion.
--
-- Si devuelve NULL, la persona no tiene ningun otro papel y su TUSUARIO se
-- puede desactivar por completo. Si devuelve algo, el usuario se conserva y
-- solo se le retiran los permisos de sede del rol correspondiente.
--
-- Los TSEDE_USUARIO NO se miran aca: los permisos del rol que se esta dando de
-- baja se retiran ANTES de llamar a esta funcion, y cualquier permiso que quede
-- vivo despues (otro rol, otra sede) se detecta como "permisos de sede
-- vigentes".
-- -----------------------------------------------------------------------------
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


-- =============================================================================
-- fn_matricula_validar_periodo_vigente -- ninguna accion sobre una matricula
-- puede ejecutarse una vez que TERMINO el periodo academico al que pertenece.
--
-- El corte es TPERIODO_ACADEMICO.FECHA_FIN: mientras CURRENT_DATE no la pase,
-- el periodo sigue abierto y la matricula se puede retirar, reingresar,
-- reactivar, promover o reubicar. Despues, no -- el año quedo cerrado y sus
-- matriculas son historia.
--
-- No se usa ACTIVE del periodo para esto: en los datos, 349 de los 361
-- periodos activos ya tienen FECHA_FIN pasada, asi que ACTIVE marca "el
-- registro sigue vigente", no "el periodo esta en curso". Son cosas distintas
-- y solo la fecha responde la pregunta.
--
-- REV -- fn_matricula_reactivar nacio SIN restriccion temporal ("se puede
-- reactivar una matricula de cualquier año lectivo, incluso cerrado"), que era
-- lo pedido entonces. El negocio lo reviso y confirmo lo contrario: la regla
-- aplica a todas las acciones por igual, reactivar incluida.
--
-- p_accion entra solo en el mensaje, para que el error diga que se intentaba
-- hacer en vez de un generico.
-- =============================================================================

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
        RAISE EXCEPTION 'No se pudo resolver el periodo academico de la matricula %', p_pk_tmatricula
            USING ERRCODE = '23503';
    END IF;

    IF v_fecha_fin < CURRENT_DATE THEN
        RAISE EXCEPTION 'No se puede % la matricula %: su periodo academico (%) termino el %',
            p_accion, p_pk_tmatricula, COALESCE(v_periodo_nombre, 'sin nombre'), v_fecha_fin
            USING ERRCODE = '22023',
                  HINT    = 'Las acciones sobre una matricula solo se permiten mientras su periodo academico siga en curso';
    END IF;
END;
$function$;
