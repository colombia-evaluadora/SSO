-- ===========================================================================
-- V476 - ES_EVALUATIVA sale del referente, tambien sin unidad.
-- Autocontenido y transaccional: monta un nivel Preescolar de prueba con
-- referente FORMATIVO (la base local solo trae referentes EVALUATIVOS),
-- clonando un grado/grupo reales para no pelear con el gate de alcance.
-- Correr con:  psql -v ON_ERROR_STOP=1 -f este_fichero
-- ===========================================================================
\set ON_ERROR_STOP on
SET search_path TO academico_test, public;
BEGIN;

CREATE TEMP TABLE r (caso TEXT, esperado TEXT, obtenido TEXT);

-- --- fixture --------------------------------------------------------------
INSERT INTO TNIVEL_ENSENANZA (pk_nivel_ensenanza, codigo, nombre, created_by, active)
VALUES (-901, 'TST901', 'Preescolar Test V476', 'test', TRUE);

CREATE TEMP TABLE tg AS SELECT * FROM TGRADO WHERE PK_TGRADO = 990501;
UPDATE tg SET pk_tgrado = -901, codigo = 'TSTG901', nombre = 'Transicion Test',
              fk_tnivel_ensenanza = -901;
INSERT INTO TGRADO SELECT * FROM tg;

CREATE TEMP TABLE gp AS SELECT * FROM TGRUPO WHERE PK_TGRUPO = 990201;
UPDATE gp SET pk_tgrupo = -901, fk_tgrado = -901, nombre = 'GTEST901';
INSERT INTO TGRUPO SELECT * FROM gp;

INSERT INTO TREFERENTE_CURRICULAR (pk_referente_curricular, nombre, descripcion,
    fk_tlv_enfoque_pedagogico, fk_tlv_tipo_evaluacion, nivel_1_etiqueta,
    nivel_2_etiqueta, instrumento, normatividad, anio_vigencia_desde, estado,
    created_by, created_at, active, fk_tlv_nombre_asignatura)
SELECT -901, 'TEST FORMATIVO V476', 'temporal',
       (SELECT PK_LISTA_VALOR FROM TLISTA_VALOR
         WHERE CATEGORIA = 'ENFOQUE_PEDAGOGICO' AND VALOR = 'FORMATIVO' AND ACTIVE LIMIT 1),
       rc.fk_tlv_tipo_evaluacion, 'N1', 'N2', 'X', 'X',
       EXTRACT(YEAR FROM CURRENT_DATE)::INT, 'A', 'test', now(), TRUE,
       rc.fk_tlv_nombre_asignatura
  FROM TREFERENTE_CURRICULAR rc WHERE rc.PK_REFERENTE_CURRICULAR = 980001;
INSERT INTO TREFERENTE_CURRICULAR_NIVEL
    (fk_referente_curricular, fk_tnivel_ensenanza, created_by, created_at, active)
VALUES (-901, -901, 'test', now(), TRUE);

-- --- casos ----------------------------------------------------------------
DO $t$
DECLARE
    v_adm   BIGINT := 1;
    v_asg   BIGINT;
    v_tipo  BIGINT;
    v_jer   BIGINT;
    v_pk    BIGINT;
    v_val   TEXT;
BEGIN
    SELECT a.FK_TASIGNATURA, a.FK_TLV_TIPO_ACTIVIDAD, a.FK_TLV_JERARQUIA
      INTO v_asg, v_tipo, v_jer
      FROM TACTIVIDAD a WHERE a.ACTIVE AND a.FK_TASIGNATURA IS NOT NULL LIMIT 1;

    -- 1) Sin unidad, referente FORMATIVO, sin p_es_evaluativa -> N
    v_pk := fn_actividad_crear(v_adm, 'V476 caso 1', v_asg, v_tipo, v_jer,
                               p_fk_tgrupo => -901);
    INSERT INTO r VALUES ('1 default con referente formativo', 'N',
        (SELECT ES_EVALUATIVA::TEXT FROM TACTIVIDAD WHERE PK_TACTIVIDAD = v_pk));
    INSERT INTO r VALUES ('1b es_formativa de esa actividad', 'true',
        fn_actividad_es_formativa(v_pk)::TEXT);

    -- 2) Sin unidad, referente FORMATIVO, con 'S' explicito -> 22023
    BEGIN
        PERFORM fn_actividad_crear(v_adm, 'V476 caso 2', v_asg, v_tipo, v_jer,
                                   p_fk_tgrupo => -901, p_es_evaluativa => 'S');
        v_val := 'sin error';
    EXCEPTION WHEN OTHERS THEN v_val := SQLSTATE;
    END;
    INSERT INTO r VALUES ('2 S explicito contra formativo', '22023', v_val);

    -- 3) Sin unidad, referente EVALUATIVO (grupo real), sin parametro -> S
    v_pk := fn_actividad_crear(v_adm, 'V476 caso 3', v_asg, v_tipo, v_jer,
                               p_fk_tgrupo => 990201);
    INSERT INTO r VALUES ('3 default con referente evaluativo', 'S',
        (SELECT ES_EVALUATIVA::TEXT FROM TACTIVIDAD WHERE PK_TACTIVIDAD = v_pk));

    -- 4) PATCH que mueve esa actividad evaluativa al grupo formativo -> 22023
    BEGIN
        PERFORM fn_actividad_actualizar(v_adm, v_pk, p_fk_tgrupo => -901);
        v_val := 'sin error';
    EXCEPTION WHEN OTHERS THEN v_val := SQLSTATE;
    END;
    INSERT INTO r VALUES ('4 PATCH a contexto formativo siendo S', '22023', v_val);

    -- 5) El mismo PATCH bajando a N si pasa
    PERFORM fn_actividad_actualizar(v_adm, v_pk, p_fk_tgrupo => -901,
                                    p_es_evaluativa => 'N');
    INSERT INTO r VALUES ('5 PATCH a formativo con N', 'N',
        (SELECT ES_EVALUATIVA::TEXT FROM TACTIVIDAD WHERE PK_TACTIVIDAD = v_pk));

    -- 6) La configuracion por contexto sugiere el mismo valor
    INSERT INTO r VALUES ('6 contexto esSumativoSugerido', 'N',
        fn_actividad_configuracion_contexto(v_adm, -901, v_asg)->>'esSumativoSugerido');
    INSERT INTO r VALUES ('6b contexto esFormativo', 'true',
        fn_actividad_configuracion_contexto(v_adm, -901, v_asg)->>'esFormativo');
    INSERT INTO r VALUES ('6c preescolar con referente evaluativo sugiere S', 'S',
        fn_actividad_configuracion_contexto(v_adm, 990201, v_asg)->>'esSumativoSugerido');

    -- 7) La configuracion por actividad expone las dos claves
    INSERT INTO r VALUES ('7 campos_disponibles esFormativo', 'true',
        fn_actividad_campos_disponibles(v_adm, v_pk)->>'esFormativo');
    INSERT INTO r VALUES ('7b campos_disponibles esSumativoSugerido', 'N',
        fn_actividad_campos_disponibles(v_adm, v_pk)->>'esSumativoSugerido');

    -- 8) La configuracion por unidad tambien (unidad real, referente evaluativo)
    INSERT INTO r VALUES ('8 unidad esSumativoSugerido', 'S',
        fn_unidad_configuracion_actividad(v_adm,
            (SELECT PK_TUNIDAD FROM TUNIDAD WHERE ACTIVE LIMIT 1))->>'esSumativoSugerido');
END;
$t$;

SELECT CASE WHEN esperado = obtenido THEN 'OK  ' ELSE 'FALLA' END AS res,
       caso, esperado, obtenido
  FROM r ORDER BY caso;

ROLLBACK;
