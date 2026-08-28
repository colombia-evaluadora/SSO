-- =============================================================================
-- V162 -- Validaciones para el flujo de matricula: resolver el
-- TPERIODO_ACADEMICO vigente a partir de (sede, jornada), con el año
-- lectivo actual, y validar que la fecha limite de matricula no haya
-- pasado.
--
-- Contexto: TPERIODO_ACADEMICO combina sede + año lectivo + jornada +
-- fechas en un solo registro; su NOMBRE se arma a partir de esos mismos
-- campos, lo que garantiza -- a nivel de negocio -- que no puede haber dos
-- periodos activos solapados para la misma (sede, jornada, año). Por eso
-- esta funcion puede asumir "0 o 1" resultado sin necesidad de desambiguar.
--
-- Uso previsto (formulario "Agregar estudiante"): tras elegir sede y
-- jornada (ver fn_jornadas_activas_por_sede), el front resuelve el
-- periodo academico vigente con esta funcion antes de poder listar grados
-- (fn_grado_listar) y grupos (fn_grupo_listar), que si requieren el PK del
-- periodo.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_resolver_matricula(
    p_fk_sede         BIGINT,
    p_fk_tlv_jornada  BIGINT,
    p_pk_usuario      BIGINT DEFAULT NULL
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
    -- -----------------------------------------------------------------
    SELECT pa.PK_TPERIODO_ACADEMICO, pa.FECHA_LIMITE_MATRICULA
      INTO v_pk_periodo, v_fecha_limite
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TANO_LECTIVO al
        ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
     WHERE pa.FK_TSEDE        = p_fk_sede
       AND pa.FK_TLV_JORNADA  = p_fk_tlv_jornada
       AND al.NOMBRE          = v_ano_actual
       AND pa.ACTIVE          = TRUE
       AND al.ACTIVE          = TRUE
       AND academico_test.fn_periodo_usuario_puede_ver(p_pk_usuario, pa.PK_TPERIODO_ACADEMICO)
     LIMIT 1;

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
        RAISE EXCEPTION 'No se encontro un grupo activo con ese identificador'
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
