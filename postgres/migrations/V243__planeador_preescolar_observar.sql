-- ===========================================================================
-- V243 - Preescolar observar: indice unico de soporte por archivo.
--
--   fn_actividad_es_formativa se crea solo si falta: V450 (LANGUAGE sql) la
--   necesita en una base limpia; la vigente es V475. fn_actividad_contexto_
--   evaluativo vive en V476.
-- ===========================================================================


SET search_path TO academico_test, public;

CREATE UNIQUE INDEX IF NOT EXISTS un_tactividad_soporte_archivo
    ON academico_test.TACTIVIDAD_SOPORTE (fk_tactividad_estudiante, fk_tarchivo)
 WHERE active = true AND fk_tarchivo IS NOT NULL;

COMMENT ON INDEX academico_test.un_tactividad_soporte_archivo
    IS 'Un archivo no puede estar adjunto dos veces a la misma fila de TACTIVIDAD_ESTUDIANTE. Parcial (solo ACTIVE) para que el borrado logico libere la combinacion, mismo patron que V65/V71. V243.';

-- La version vigente es posterior; esta solo hace falta en una base limpia (fn_actividad_es_formativa).
DO $guarda$
BEGIN
    IF to_regprocedure('academico_test.fn_actividad_contexto_evaluativo(bigint,bigint,bigint)') IS NULL THEN
        EXECUTE $crear$CREATE OR REPLACE FUNCTION academico_test.fn_actividad_contexto_evaluativo(
    p_fk_tgrupo      BIGINT,
    p_fk_tasignatura BIGINT,
    p_fk_tunidad     BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT CASE
        -- Con unidad manda la unidad: ya eligio referente.
        WHEN p_fk_tunidad IS NOT NULL
            THEN academico_test.fn_unidad_referente_evaluativo(p_fk_tunidad)
        -- Sin unidad, el referente se deriva del (grado del grupo, asignatura),
        -- igual que en fn_actividad_configuracion_contexto.
        ELSE COALESCE((
            SELECT lv.VALOR = 'EVALUATIVO'
              FROM academico_test.TGRUPO g
              JOIN academico_test.TREFERENTE_CURRICULAR rc
                ON rc.PK_REFERENTE_CURRICULAR =
                   academico_test.fn_unidad_referente_aplicable(
                       g.FK_TGRADO, p_fk_tasignatura, NULL)
              JOIN academico_test.TLISTA_VALOR lv
                ON lv.PK_LISTA_VALOR = rc.FK_TLV_ENFOQUE_PEDAGOGICO
             WHERE g.PK_TGRUPO = p_fk_tgrupo), TRUE)
    END;
$$$crear$;
    END IF;
END $guarda$;

-- La version vigente es posterior; esta solo hace falta en una base limpia (V450).
DO $guarda$
BEGIN
    IF to_regprocedure('academico_test.fn_actividad_es_formativa(bigint)') IS NULL THEN
        EXECUTE $crear$CREATE OR REPLACE FUNCTION academico_test.fn_actividad_es_formativa(
    p_pk_tactividad BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        (SELECT NOT academico_test.fn_actividad_contexto_evaluativo(
                        a.FK_TGRUPO, a.FK_TASIGNATURA, a.FK_TUNIDAD)
           FROM academico_test.TACTIVIDAD a
          WHERE a.PK_TACTIVIDAD = p_pk_tactividad
            AND a.ACTIVE = TRUE),
        FALSE
    );
$$$crear$;
    END IF;
END $guarda$;
