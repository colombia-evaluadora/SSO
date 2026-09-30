-- ===========================================================================
-- V216 - Planeador: menu e indice trigram de busqueda de unidades.
--
--   fn_unidad_referente_aplicable se crea solo si falta: V243 (LANGUAGE sql) y
--   el backfill de V280 la necesitan en una base limpia; la vigente es V451.
--   crear/eliminar y los listados de objetivos y contenidos viven en V492.1-V492.3.
-- ===========================================================================

SET search_path TO academico_test, public;

INSERT INTO academico_test.tmenu (codigo, nombre, icono, visible, estado, url, fk_tmenu, orden, created_by)
SELECT 'PLANEADOR', 'Planeador', 'CalendarCheck-Icon', 'S', 'A',
       '/academico/planeador', NULL, 6::NUMERIC, 'V216_seed'
 WHERE NOT EXISTS (
     SELECT 1 FROM academico_test.tmenu m
      WHERE m.codigo = 'PLANEADOR' AND m.active = TRUE
 );

INSERT INTO academico_test.trol_menu (fk_trol, fk_tmenu, orden_rol, active, created_by)
SELECT t.pk_trol, m.pk_tmenu, 1, TRUE, 'V216_seed'
  FROM academico_test.tmenu m
 CROSS JOIN academico_test.trol t
 WHERE t.codigo IN ('DOCENTE', 'SUPER_ADMINISTRADOR')
   AND t.active = TRUE
   AND m.codigo = 'PLANEADOR'
   AND m.active = TRUE
   AND NOT EXISTS (
       SELECT 1 FROM academico_test.trol_menu tm
        WHERE tm.fk_trol = t.pk_trol AND tm.fk_tmenu = m.pk_tmenu AND tm.active = TRUE
       );

DO $guarda$
BEGIN
    IF to_regprocedure('academico_test.fn_unidad_referente_aplicable(bigint,bigint,integer)') IS NULL THEN
        EXECUTE $crear$CREATE OR REPLACE FUNCTION academico_test.fn_unidad_referente_aplicable(
    p_fk_tgrado       BIGINT,
    p_fk_tasignatura  BIGINT DEFAULT NULL,
    p_anio            INT    DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $fnra$
DECLARE
    v_nivel BIGINT;
    v_area  BIGINT;
    v_anio  INT := COALESCE(p_anio, EXTRACT(YEAR FROM CURRENT_DATE)::INT);
    v_pk    BIGINT;
BEGIN
    IF p_fk_tgrado IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT g.FK_TNIVEL_ENSENANZA INTO v_nivel
      FROM academico_test.TGRADO g
     WHERE g.PK_TGRADO = p_fk_tgrado;

    IF v_nivel IS NULL THEN
        RETURN NULL;   -- grado inexistente o sin nivel: nada que derivar
    END IF;

    IF p_fk_tasignatura IS NOT NULL THEN
        SELECT COALESCE(asig.FK_TAREA_ASIGNATURA, ta.FK_TAREA_ASIGNATURA) INTO v_area
          FROM academico_test.TASIGNATURA asig
          LEFT JOIN academico_test.TAREA ta ON ta.PK_TAREA = asig.FK_TAREA
         WHERE asig.PK_TASIGNATURA = p_fk_tasignatura;
    END IF;

    SELECT rc.PK_REFERENTE_CURRICULAR INTO v_pk
      FROM academico_test.TREFERENTE_CURRICULAR rc
      JOIN academico_test.TREFERENTE_CURRICULAR_NIVEL rcn
            ON rcn.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
           AND rcn.FK_TNIVEL_ENSENANZA = v_nivel
           AND rcn.ACTIVE = TRUE
     WHERE rc.ACTIVE = TRUE
       AND rc.ESTADO = 'A'
       AND rc.ANIO_VIGENCIA_DESDE <= v_anio
       AND (rc.ANIO_VIGENCIA_HASTA IS NULL OR rc.ANIO_VIGENCIA_HASTA >= v_anio)
       AND (v_area IS NULL
            OR NOT EXISTS (SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR_AREA a
                            WHERE a.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                              AND a.ACTIVE = TRUE)
            OR EXISTS (SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR_AREA a
                        WHERE a.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                          AND a.FK_TAREA_ASIGNATURA = v_area
                          AND a.ACTIVE = TRUE))
     ORDER BY CASE WHEN EXISTS (SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR_AREA a
                                 WHERE a.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                                   AND a.ACTIVE = TRUE) THEN 0 ELSE 1 END,
              rc.ANIO_VIGENCIA_DESDE DESC,
              rc.PK_REFERENTE_CURRICULAR
     LIMIT 1;

    RETURN v_pk;
END;
$fnra$$crear$;
    END IF;
END $guarda$;

CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX IF NOT EXISTS idx_tunidad_busqueda_trgm
    ON academico_test.TUNIDAD
 USING gin ((COALESCE(NOMBRE,'') || ' ' || COALESCE(DESCRIPCION,'')) gin_trgm_ops);

COMMENT ON INDEX academico_test.idx_tunidad_busqueda_trgm
    IS 'GIN trigram sobre NOMBRE+DESCRIPCION concatenados para que p_search (ILIKE %texto%) de fn_unidad_listar no haga Seq Scan. El texto de la expresion debe coincidir exacto con el del WHERE de esa funcion. V216.';

