-- ===========================================================================
-- V505 - Prematricula (4/9): las validaciones del SEGUNDO endpoint (un grupo).
--
--   fn_prematricula_matricula_procesable(matricula)  -> ya tiene prematricula?
--   fn_prematricula_grupo_procesado(grupo)           -> cuantas van y cuantas faltan
--   fn_prematricula_assert_grupo_no_procesado(grupo) -> 23505 si ya se hizo entero
--
--
-- EL PROBLEMA QUE RESUELVEN
--   El proceso se llama grupo por grupo, en tandas. Si se interrumpe a la
--   mitad y alguien vuelve a pedir el plan y lo reanuda, los grupos ya hechos
--   no deben volver a prematricularse: se duplicarian las filas y se gastaria
--   el tiempo que justamente se quiso ahorrar partiendo el proceso.
--
--
-- COMO SE SABE QUE UN GRUPO YA SE HIZO
--   Por el ESTUDIANTE, no por el grupo destino. Un estudiante ya
--   prematriculado tiene una TPREMATRICULA activa en algun grupo del periodo
--   siguiente; cual sea da igual -- pudo mandarse al de ascenso o al de
--   repeticion, y un reubicado manual pudo moverlo a un tercero. Preguntar
--   "existe prematricula activa de este estudiante en el periodo siguiente"
--   cubre los tres casos; preguntar por el grupo destino que ESTE proceso
--   calcularia no cubriria el tercero y duplicaria la fila.
--
--   Se mira el periodo entero y no el ano calendario porque un estudiante
--   puede tener prematricula vieja de otro ano; acotar al periodo siguiente
--   de SU sede y jornada es lo que hace la pregunta correcta.
--
--
-- POR QUE PARCIAL Y NO SOLO SI/NO
--   Si el grupo quedo a medias -- se cayo la conexion en el estudiante 12 de
--   30 --, reanudar tiene que completar los que faltan, no rechazar el grupo
--   entero. Por eso fn_prematricula_grupo_procesado devuelve el conteo y el
--   assert solo corta cuando estan TODOS.
--
-- Idempotente: CREATE OR REPLACE.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) Una matricula concreta: ya tiene prematricula para el ano que viene?
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_prematricula_matricula_procesable(
    p_pk_tmatricula  BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT NOT EXISTS (
        SELECT 1
          FROM academico_test.TMATRICULA m
          JOIN academico_test.TGRUPO  g  ON g.PK_TGRUPO  = m.FK_TGRUPO
          JOIN academico_test.TGRADO  gd ON gd.PK_TGRADO = g.FK_TGRADO
          JOIN academico_test.TPREMATRICULA pm
            ON pm.FK_TESTUDIANTE = m.FK_TESTUDIANTE
           AND pm.ACTIVE = TRUE
          JOIN academico_test.TGRUPO  gp  ON gp.PK_TGRUPO  = pm.FK_TGRUPO
          JOIN academico_test.TGRADO  gdp ON gdp.PK_TGRADO = gp.FK_TGRADO
         WHERE m.PK_TMATRICULA = p_pk_tmatricula
           AND gdp.FK_TPERIODO_ACADEMICO
             = academico_test.fn_prematricula_periodo_siguiente(gd.FK_TPERIODO_ACADEMICO)
    );
$$;

COMMENT ON FUNCTION academico_test.fn_prematricula_matricula_procesable(BIGINT)
    IS 'TRUE si al estudiante de esa matricula todavia NO se le creo una prematricula activa en el periodo academico siguiente al suyo. Se pregunta por el estudiante y por el PERIODO destino, no por el grupo destino que este proceso calcularia: si alguien ya lo reubico a mano en otro grupo del mismo periodo, sigue estando prematriculado y no hay que duplicarlo.';

-- ---------------------------------------------------------------------------
-- 2) El grupo entero: cuantos van, cuantos faltan.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_prematricula_grupo_procesado(
    p_fk_tgrupo  BIGINT
)
RETURNS TABLE (
    matriculas   BIGINT,
    procesadas   BIGINT,
    pendientes   BIGINT
)
LANGUAGE sql
STABLE
ROWS 1
AS $$
    SELECT COUNT(*)::BIGINT,
           COUNT(*) FILTER (
               WHERE NOT academico_test.fn_prematricula_matricula_procesable(m.PK_TMATRICULA)
           )::BIGINT,
           COUNT(*) FILTER (
               WHERE academico_test.fn_prematricula_matricula_procesable(m.PK_TMATRICULA)
           )::BIGINT
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TLISTA_VALOR lv
        ON lv.PK_LISTA_VALOR = m.FK_TLV_ESTADO_MATRICULA
       AND lv.CATEGORIA = 'ESTADO_MATRICULA'
     WHERE m.FK_TGRUPO = p_fk_tgrupo
       AND m.ACTIVE    = TRUE
       -- Los tres estados que entran al proceso: Cursando, Aprobado,
       -- Reprobado. Por VALOR y no por NOMBRE, mismo criterio que
       -- fn_matricula_cupo_ocupado.
       AND lv.VALOR IN ('1', '2', '3');
$$;

COMMENT ON FUNCTION academico_test.fn_prematricula_grupo_procesado(BIGINT)
    IS 'Cuantas matriculas prematriculables tiene un grupo (Cursando/Aprobado/Reprobado, activas), cuantas ya tienen prematricula en el periodo siguiente y cuantas faltan. Devuelve SIEMPRE una fila, con ceros si el grupo no tiene a nadie. Sirve para reanudar: un grupo a medias completa lo que falta en vez de rechazarse entero. ROWS 1 declarado.';

-- ---------------------------------------------------------------------------
-- 3) El corte: el grupo ya se hizo COMPLETO.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_prematricula_assert_grupo_no_procesado(
    p_fk_tgrupo  BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v  RECORD;
BEGIN
    SELECT * INTO v FROM academico_test.fn_prematricula_grupo_procesado(p_fk_tgrupo);

    IF v.matriculas = 0 THEN
        RAISE EXCEPTION
            'El grupo % no tiene matriculas en estado Cursando, Aprobado ni Reprobado: no hay a quien prematricular',
            p_fk_tgrupo
            USING ERRCODE = '22023';
    END IF;

    IF v.pendientes = 0 THEN
        RAISE EXCEPTION
            'El grupo % ya fue prematriculado por completo (% de % estudiantes)',
            p_fk_tgrupo, v.procesadas, v.matriculas
            USING ERRCODE = '23505';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_prematricula_assert_grupo_no_procesado(BIGINT)
    IS 'Falla con 23505 si el grupo ya fue prematriculado COMPLETO, y con 22023 si no tiene ninguna matricula prematriculable. Un grupo a medias NO falla: se deja reanudar. El 23505 (unique_violation) es deliberado -- para quien llama es el mismo caso que intentar crear algo que ya existe, y el front puede tratarlo como "ya estaba hecho" en vez de como un error.';
