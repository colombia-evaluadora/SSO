-- ===========================================================================
-- V451 — fn_unidad_referente_aplicable: las areas del referente son una
-- PREFERENCIA, no una exclusion.
--
-- Que hace: la unica funcion que deriva el referente de (grado, asignatura)
-- descartaba todo referente acotado a areas que no incluyera el area de la
-- asignatura; como un nivel puede tener varios referentes y el de Preescolar
-- declara areas, (Jardin I, SEGUIMIENTOS1) devolvia NULL y las unidades nuevas
-- nacian sin referente. Ahora ordena: 1) lista el area, 2) sin areas (aplica a
-- todas), 3) cualquier otro activo del nivel; dentro de cada nivel, el mas
-- reciente. NULL solo si no hay ninguno activo para ese nivel.
-- Depende de: V216 (firma y llamadores), V212 (TREFERENTE_CURRICULAR*).
-- ===========================================================================

SET search_path TO academico_test, public;

-- Misma firma que V216: CREATE OR REPLACE basta, no hay DROP.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_referente_aplicable(
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
        RETURN NULL;
    END IF;

    -- Area de la asignatura: la FK directa es nullable, el enganche real esta en su TAREA.
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
      CROSS JOIN LATERAL (
          SELECT EXISTS (SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR_AREA a
                          WHERE a.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                            AND a.ACTIVE = TRUE)                              AS tiene_areas,
                 EXISTS (SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR_AREA a
                          WHERE a.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                            AND a.FK_TAREA_ASIGNATURA = v_area
                            AND a.ACTIVE = TRUE)                              AS lista_el_area
      ) ar
     WHERE rc.ACTIVE = TRUE                 -- borrado logico
       AND rc.ESTADO = 'A'                  -- estado de negocio (Activo)
       AND rc.ANIO_VIGENCIA_DESDE <= v_anio
       AND (rc.ANIO_VIGENCIA_HASTA IS NULL OR rc.ANIO_VIGENCIA_HASTA >= v_anio)
     ORDER BY CASE
                  WHEN v_area IS NOT NULL AND ar.lista_el_area THEN 0   -- 1) lista el area
                  WHEN NOT ar.tiene_areas                      THEN 1   -- 2) aplica a todas
                  ELSE                                              2   -- 3) el resto
              END,
              rc.ANIO_VIGENCIA_DESDE DESC,
              rc.PK_REFERENTE_CURRICULAR DESC
     LIMIT 1;

    RETURN v_pk;
END;
$fnra$;

COMMENT ON FUNCTION academico_test.fn_unidad_referente_aplicable(BIGINT, BIGINT, INT)
    IS 'El referente curricular que le CORRESPONDE a un (grado, asignatura): unica definicion de la regla de derivacion, compartida por fn_unidad_crear, fn_unidad_actualizar, V280, fn_docente_unidad_tabs_listar y fn_actividad_configuracion_contexto. grado -> TGRADO.FK_TNIVEL_ENSENANZA -> TREFERENTE_CURRICULAR_NIVEL (N:N) y vigencia que cubra p_anio (default: anio en curso). Solo referentes ACTIVOS en los dos sentidos: ESTADO = A (estado de negocio que edita el usuario) y ACTIVE = true (borrado logico); son independientes y hay filas con uno sin el otro. Las areas del referente (TREFERENTE_CURRICULAR_AREA contra TAREA_ASIGNATURA; el area de la asignatura se resuelve con COALESCE(TASIGNATURA.FK_TAREA_ASIGNATURA, TAREA.FK_TAREA_ASIGNATURA)) son una PREFERENCIA, no una exclusion: gana 1) el que lista el area de la asignatura, 2) si no hay, el que no declara areas (aplica a todas), 3) si tampoco, cualquier otro activo del nivel; dentro de cada nivel, la vigencia mas reciente. Antes un referente acotado a otras areas quedaba EXCLUIDO y, como un nivel puede tener varios referentes, (Jardin I, SEGUIMIENTOS1) devolvia NULL y las unidades nuevas de Preescolar nacian sin referente. Sin asignatura no hay nivel 1 y decide 2) sobre 3). Devuelve NULL solo si no hay ningun referente activo para ese nivel. Sin gate: helper de lectura invocado desde funciones que ya gatearon.';
