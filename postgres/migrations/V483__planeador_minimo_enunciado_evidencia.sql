-- V483 — Planeador: mínimo un enunciado por unidad y una evidencia por actividad.
--
-- Qué hace: una unidad activa con referente curricular que tiene enunciados
-- debe relacionar al menos uno (TUNIDAD_ENUNCIADO); una actividad activa con
-- unidad, si los enunciados de esa unidad tienen evidencias, debe escoger al
-- menos una de ellas (TACTIVIDAD_EVIDENCIA).
-- Por qué triggers diferidos: el mínimo se incumple entre sentencias de la
-- misma operación (se inserta la unidad y luego sus enunciados) y hay varios
-- caminos que lo rompen (crear, actualizar, quitar enunciado/evidencia);
-- validar al COMMIT los cubre todos sin duplicar la regla en cada función.
-- Solo se dispara sobre filas que cambian: los datos viejos no se revalidan.
-- Depende de: V212 (referente/enunciados), V214.1 (tablas puente), V216.

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_assert_minimo_enunciado(p_fk_tunidad BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_nombre     VARCHAR;
    v_referente  BIGINT;
    v_etiqueta   VARCHAR;
    v_etq_unidad VARCHAR;
BEGIN
    SELECT u.NOMBRE, u.FK_REFERENTE_CURRICULAR INTO v_nombre, v_referente
      FROM academico_test.TUNIDAD u
     WHERE u.PK_TUNIDAD = p_fk_tunidad AND u.ACTIVE = TRUE;

    IF v_referente IS NULL THEN
        RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM academico_test.TREFERENTE_ENUNCIADO e
                WHERE e.FK_REFERENTE_CURRICULAR = v_referente
                  AND e.FK_PADRE IS NULL AND e.ACTIVE = TRUE)
       AND NOT EXISTS (SELECT 1 FROM academico_test.TUNIDAD_ENUNCIADO ue
                        WHERE ue.FK_TUNIDAD = p_fk_tunidad AND ue.ACTIVE = TRUE)
    THEN
        SELECT LOWER(rc.NIVEL_1_ETIQUETA), NULLIF(TRIM(rc.INSTRUMENTO), '') INTO v_etiqueta, v_etq_unidad
          FROM academico_test.TREFERENTE_CURRICULAR rc
         WHERE rc.PK_REFERENTE_CURRICULAR = v_referente;
        RAISE EXCEPTION '% "%": debe tener al menos 1 % de su referente curricular',
            COALESCE(v_etq_unidad, 'Unidad tematica'), v_nombre, COALESCE(v_etiqueta, 'enunciado')
            USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_assert_minimo_evidencia(p_fk_tactividad BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_titulo    VARCHAR;
    v_unidad    BIGINT;
    v_etq_1     VARCHAR;
    v_etq_2     VARCHAR;
    v_etq_unid  VARCHAR;
BEGIN
    SELECT a.TITULO, a.FK_TUNIDAD INTO v_titulo, v_unidad
      FROM academico_test.TACTIVIDAD a
     WHERE a.PK_TACTIVIDAD = p_fk_tactividad AND a.ACTIVE = TRUE;

    IF v_unidad IS NULL THEN
        RETURN;
    END IF;

    IF EXISTS (SELECT 1
                 FROM academico_test.TUNIDAD_ENUNCIADO ue
                 JOIN academico_test.TREFERENTE_ENUNCIADO ev
                   ON ev.FK_PADRE = ue.FK_REFERENTE_ENUNCIADO AND ev.ACTIVE = TRUE
                WHERE ue.FK_TUNIDAD = v_unidad AND ue.ACTIVE = TRUE)
       AND NOT EXISTS (SELECT 1
                         FROM academico_test.TACTIVIDAD_EVIDENCIA ae
                         JOIN academico_test.TREFERENTE_ENUNCIADO ev
                           ON ev.PK_REFERENTE_ENUNCIADO = ae.FK_REFERENTE_ENUNCIADO
                         JOIN academico_test.TUNIDAD_ENUNCIADO ue
                           ON ue.FK_REFERENTE_ENUNCIADO = ev.FK_PADRE
                          AND ue.FK_TUNIDAD = v_unidad AND ue.ACTIVE = TRUE
                        WHERE ae.FK_TACTIVIDAD = p_fk_tactividad AND ae.ACTIVE = TRUE)
    THEN
        SELECT LOWER(rc.NIVEL_1_ETIQUETA), LOWER(rc.NIVEL_2_ETIQUETA), LOWER(NULLIF(TRIM(rc.INSTRUMENTO), ''))
          INTO v_etq_1, v_etq_2, v_etq_unid
          FROM academico_test.TUNIDAD u
          JOIN academico_test.TREFERENTE_CURRICULAR rc ON rc.PK_REFERENTE_CURRICULAR = u.FK_REFERENTE_CURRICULAR
         WHERE u.PK_TUNIDAD = v_unidad;
        RAISE EXCEPTION 'La actividad "%" debe tener al menos 1 % de cualquier % de su %',
            v_titulo, COALESCE(v_etq_2, 'evidencia'), COALESCE(v_etq_1, 'enunciado'), COALESCE(v_etq_unid, 'unidad tematica')
            USING ERRCODE = '22023';
    END IF;
END;
$$;

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
            PERFORM academico_test.fn_actividad_assert_minimo_evidencia(v_fila.FK_TACTIVIDAD);
    END CASE;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS tr_tunidad_minimo_enunciado ON academico_test.TUNIDAD;
CREATE CONSTRAINT TRIGGER tr_tunidad_minimo_enunciado
    AFTER INSERT OR UPDATE OF FK_REFERENTE_CURRICULAR, ACTIVE ON academico_test.TUNIDAD
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION academico_test.tg_planeador_minimo_enunciado_evidencia();

DROP TRIGGER IF EXISTS tr_tunidad_enunciado_minimo ON academico_test.TUNIDAD_ENUNCIADO;
CREATE CONSTRAINT TRIGGER tr_tunidad_enunciado_minimo
    AFTER UPDATE OF ACTIVE OR DELETE ON academico_test.TUNIDAD_ENUNCIADO
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION academico_test.tg_planeador_minimo_enunciado_evidencia();

DROP TRIGGER IF EXISTS tr_tactividad_minimo_evidencia ON academico_test.TACTIVIDAD;
CREATE CONSTRAINT TRIGGER tr_tactividad_minimo_evidencia
    AFTER INSERT OR UPDATE OF FK_TUNIDAD, ACTIVE ON academico_test.TACTIVIDAD
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION academico_test.tg_planeador_minimo_enunciado_evidencia();

DROP TRIGGER IF EXISTS tr_tactividad_evidencia_minimo ON academico_test.TACTIVIDAD_EVIDENCIA;
CREATE CONSTRAINT TRIGGER tr_tactividad_evidencia_minimo
    AFTER UPDATE OF ACTIVE OR DELETE ON academico_test.TACTIVIDAD_EVIDENCIA
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION academico_test.tg_planeador_minimo_enunciado_evidencia();

COMMENT ON FUNCTION academico_test.fn_unidad_assert_minimo_enunciado(BIGINT)
    IS 'Falla (22023) si la unidad activa tiene un referente curricular con enunciados y no relaciona ninguno en TUNIDAD_ENUNCIADO. Invocada por el constraint trigger diferido tr_tunidad_minimo_enunciado / tr_tunidad_enunciado_minimo. Sin gate: núcleo de validación. V483.';
COMMENT ON FUNCTION academico_test.fn_actividad_assert_minimo_evidencia(BIGINT)
    IS 'Falla (22023) si la actividad activa tiene unidad cuyos enunciados tienen evidencias y no escoge ninguna de ellas en TACTIVIDAD_EVIDENCIA. Invocada por el constraint trigger diferido tr_tactividad_minimo_evidencia / tr_tactividad_evidencia_minimo. Sin gate: núcleo de validación. V483.';
