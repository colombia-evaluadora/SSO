-- ===========================================================================
-- V352 - fn_periodo_resolver_matricula: se INVIERTE el gate de la fecha
--        limite de matricula.
--
-- QUE CAMBIA
--   Antes (V162) la matricula directa exigia que la fecha limite YA hubiera
--   pasado:
--
--       IF CURRENT_DATE <= v_fecha_limite THEN  -> 22023
--
--   El razonamiento era que FECHA_LIMITE_MATRICULA marca el cierre de la
--   INSCRIPCION, y que mientras ese periodo sigue abierto lo correcto es
--   inscribir o prematricular, no matricular directamente. Por eso el gate
--   rechazaba ANTES de que venciera la fecha.
--
--   Ahora es al reves: la matricula directa exige que la fecha limite NO
--   haya pasado.
--
--       IF CURRENT_DATE > v_fecha_limite THEN   -> 22023
--
--   Es decir, FECHA_LIMITE_MATRICULA vuelve a leerse como lo que su nombre y
--   el comentario de la DDL dicen -- "Fecha limite para la matricula" --, o
--   sea el cierre del plazo para matricular, no su apertura. Es la forma que
--   tuvo en una fase anterior del desarrollo.
--
-- POR QUE
--   Cambio de planes y de alcance del entregable: la reserva de cupo y la
--   prematricula no entran todavia (TRESERVA_CUPO esta vacia y
--   TPREMATRICULA solo tiene los 47 registros de la migracion; ninguna de
--   las dos tiene funciones ni endpoints). Con el gate anterior, la unica
--   via de alta que existe hoy quedaba cerrada justo durante el plazo en que
--   el negocio la necesita.
--
-- IMPACTO MEDIDO
--   Esta funcion solo considera periodos ACTIVOS del AÑO EN CURSO, asi que
--   la cifra que importa es esa: de los 21 periodos de 2026 en el servidor
--   de test, 2 tienen la fecha limite por delante y 19 ya vencida. La
--   inversion da la vuelta exacta a ese reparto:
--
--       antes:  19 permiten matricula directa, 2 la rechazan
--       ahora:   2 permiten matricula directa, 19 la rechazan
--
--   (Sobre el total de 366 periodos activos de todos los años serian 359
--   vencidos y 7 vigentes, pero los de años anteriores ni siquiera llegan a
--   este gate: los descarta antes el filtro por año lectivo.)
--
--   No es un efecto de la migracion sino de los datos, pero conviene tenerlo
--   presente al probar: la mayoria de las sedes va a responder 22023 hasta
--   que se configure un periodo con la fecha limite por delante.
--
-- ALCANCE
--   Se toca solo el paso 2. El resto de la funcion queda byte a byte igual:
--   la resolucion del periodo por (sede, jornada, año), el desempate
--   determinista por FECHA_LIMITE_MATRICULA DESC + PK DESC, la verificacion
--   contra p_fk_tgrupo y el filtro por alcance del solicitante.
--
--   Es la unica funcion del esquema que usa FECHA_LIMITE_MATRICULA como
--   gate: las demas que la mencionan (fn_periodo_crear, fn_periodo_actualizar,
--   fn_periodo_detalle, fn_periodo_listar) solo la leen o la escriben.
--   La llaman fn_matricula_directa_crear (V166), fn_matricula_crear (V163) y
--   el endpoint de resolucion de periodo del front (V127).
--
-- Idempotente: CREATE OR REPLACE, misma firma (no crea sobrecarga).
-- ===========================================================================


CREATE OR REPLACE FUNCTION academico_test.fn_periodo_resolver_matricula(p_fk_sede bigint, p_fk_tlv_jornada bigint, p_pk_usuario bigint DEFAULT NULL::bigint, p_fk_tgrupo bigint DEFAULT NULL::bigint)
 RETURNS bigint
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
    -- 2. Validar que la fecha limite de matricula NO haya pasado.
    --
    --    V352 -- se invierte respecto a V162. Antes se exigia que la fecha
    --    ya hubiera vencido, leyendo FECHA_LIMITE_MATRICULA como el cierre
    --    de la INSCRIPCION: mientras ese plazo seguia abierto lo correcto
    --    era inscribir o prematricular, no matricular directo.
    --
    --    Ahora se lee como lo que dice su nombre y el comentario de la DDL,
    --    "Fecha limite para la matricula": el plazo para matricular, que se
    --    cierra cuando la fecha pasa. El motivo es de alcance -- la reserva
    --    de cupo y la prematricula no entran en este entregable, asi que la
    --    matricula directa es la unica via de alta y no puede quedar cerrada
    --    durante el plazo en que se la necesita.
    -- -----------------------------------------------------------------
    IF CURRENT_DATE > v_fecha_limite THEN
        RAISE EXCEPTION 'La fecha limite de matricula de este periodo academico ya paso (vencio %)',
            v_fecha_limite
            USING ERRCODE = '22023',
                  HINT    = 'Solo se puede matricular hasta la fecha limite configurada en el periodo academico';
    END IF;

    RETURN v_pk_periodo;
END;
$function$
