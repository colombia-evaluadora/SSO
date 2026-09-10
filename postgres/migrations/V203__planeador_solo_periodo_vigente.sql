-- =============================================================================
-- V203 -- El planeador solo opera sobre el periodo academico en curso.
--
--   fn_planeador_periodo_vigente(grupo, grado, unidad) -> BOOLEAN
--
-- La usan fn_actividad_exportar (V272) y fn_actividad_importar (V274). Numero
-- bajo y en un hueco libre (203-211 estaban sin usar y sin registrar en
-- flyway_schema_history) para poder llamarla desde las migraciones del
-- planeador, que van en el rango alto.
--
-- -----------------------------------------------------------------------------
-- No es una eleccion del usuario
-- -----------------------------------------------------------------------------
-- Exportar o importar actividades de un año que ya cerro no es un caso de uso:
-- es un accidente. El planeador se usa para planificar lo que viene, y una
-- actividad importada a un periodo terminado no la va a ver nadie ni la va a
-- calificar nadie -- queda colgada de un grupo que ya no existe como tal.
--
-- Asi que no hay parametro para pedirlo. No se puede desactivar.
--
-- -----------------------------------------------------------------------------
-- Por que la FECHA y no el ESTADO
-- -----------------------------------------------------------------------------
-- TPERIODO_ACADEMICO tiene FK_TLV_ESTADO (Abierto / Cerrado / Inscripciones /
-- Nivelaciones / Promociones), asi que la tentacion es mirar ahi. Se midio, y
-- la respuesta es que ese estado NO se mantiene:
--
--   estado                    no terminados   terminados
--   A Abierto                            12           80     <-- 80 "abiertos" que ya acabaron
--   C Cerrado                             0          205
--   I Inscripciones                       2           11
--   N Nivelaciones                        0           45
--   P Promociones                         0            7
--
-- Ochenta periodos siguen en "Abierto" despues de haber terminado. En cambio
-- ningun periodo no terminado esta en "Cerrado": la fecha nunca contradice al
-- estado, pero el estado si se queda atras. La fecha es la señal fiable.
--
-- Es ademas la convencion que ya usa la casa:
-- fn_matricula_validar_periodo_vigente decide con FECHA_FIN < CURRENT_DATE y no
-- mira el estado, y fn_docente_periodo_vigente ordena por
-- CURRENT_DATE BETWEEN FECHA_INICIO AND FECHA_FIN. Ninguna funcion del esquema
-- usa el estado para esto.
--
-- -----------------------------------------------------------------------------
-- "Vigente" = no ha TERMINADO, no "esta en curso"
-- -----------------------------------------------------------------------------
-- Solo se exige FECHA_FIN >= CURRENT_DATE. Un periodo que todavia no ha
-- empezado SI se acepta, y eso es deliberado por dos razones:
--
--   * es lo que hace planeador: un docente prepara las actividades del periodo
--     que viene ANTES de que arranque. Exigir FECHA_INICIO <= CURRENT_DATE
--     rompería justo el caso de uso principal.
--   * es lo que hace fn_matricula_validar_periodo_vigente, que solo rechaza los
--     periodos ya terminados.
--
-- -----------------------------------------------------------------------------
-- Una sola definicion, usada de dos formas
-- -----------------------------------------------------------------------------
-- Se declara LANGUAGE sql STABLE a proposito: asi el planificador la puede
-- INLINE, y el exportador la usa dentro de un WHERE sobre TACTIVIDAD sin pagar
-- una llamada por fila, mientras el importador la usa como predicado por fila.
-- La regla vive en un solo sitio aunque se consuma de dos maneras.
--
-- Devuelve FALSE si la cadena no resuelve -- sin grupo, grado ni unidad, o con
-- el grado sin periodo. Mismo criterio que fn_planeador_assert_alcance (V202):
-- si no se puede determinar, no se autoriza.
--
-- Impacto medido al aplicarla: 0 de las 18 actividades activas y 0 de las 4
-- unidades activas estan en un periodo terminado, asi que no invalida nada de
-- lo que hay hoy.
--
-- Idempotente: CREATE OR REPLACE.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_planeador_periodo_vigente(
    p_fk_tgrupo  BIGINT DEFAULT NULL,
    p_fk_tgrado  BIGINT DEFAULT NULL,
    p_fk_tunidad BIGINT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $function$
    SELECT EXISTS (
        SELECT 1
          FROM academico_test.TGRADO g
          JOIN academico_test.TPERIODO_ACADEMICO pa
            ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
         WHERE g.PK_TGRADO = COALESCE(
                   -- el grupo primero, que es el mas especifico de los tres
                   (SELECT gr.FK_TGRADO FROM academico_test.TGRUPO gr
                     WHERE gr.PK_TGRUPO = p_fk_tgrupo AND gr.ACTIVE = TRUE),
                   (SELECT u.FK_TGRADO FROM academico_test.TUNIDAD u
                     WHERE u.PK_TUNIDAD = p_fk_tunidad AND u.ACTIVE = TRUE),
                   p_fk_tgrado)
           AND g.ACTIVE  = TRUE
           AND pa.ACTIVE = TRUE
           AND pa.FECHA_FIN >= CURRENT_DATE
    );
$function$;

COMMENT ON FUNCTION academico_test.fn_planeador_periodo_vigente(BIGINT, BIGINT, BIGINT)
    IS 'TRUE si el periodo academico del grupo, grado o unidad indicados no ha terminado (FECHA_FIN >= CURRENT_DATE). El planeador solo opera sobre el periodo en curso y eso no es elegible por el usuario: exportar o importar actividades de un año cerrado es un accidente, no un caso de uso. Decide por FECHA y no por FK_TLV_ESTADO porque el estado no se mantiene -- se midieron 80 periodos ya terminados que siguen en "Abierto", mientras ningun periodo no terminado esta en "Cerrado"; es ademas la convencion de fn_matricula_validar_periodo_vigente. Acepta un periodo que aun no empezo, porque planificar el periodo siguiente antes de que arranque es justo para lo que existe el planeador. FALSE si la cadena no resuelve. LANGUAGE sql para que el planificador la pueda inline dentro de un WHERE. V203.';
