-- ===========================================================================
-- 00_teardown - Borra el fixture del modulo de informes.
--
-- Todo lo que siembra 01_fixture.sql cuelga de los establecimientos cuyo
-- CODIGO empieza por 'TSTINF'; lo que no tiene codigo se alcanza navegando
-- desde ahi. Se borra DE VERDAD -- DELETE, no ACTIVE=FALSE -- porque un
-- fixture desactivado seguiria chocando contra los indices unicos que no son
-- parciales.
--
-- El orden es el inverso de las FK, explicito y largo a proposito: un
-- TRUNCATE CASCADE sobre estas tablas se llevaria por delante el dump base.
--
-- Idempotente: correrlo sin fixture no hace nada y no falla.
-- ===========================================================================

DO $teardown$
DECLARE
    v_ee     BIGINT[];
    v_sede   BIGINT[];
    v_peraca BIGINT[];
    v_grado  BIGINT[];
    v_grupo  BIGINT[];
    v_mat    BIGINT[];
    v_asig   BIGINT[];
    v_area   BIGINT[];
    v_act    BIGINT[];
    v_uni    BIGINT[];
    v_usr    BIGINT[];
    v_fun    BIGINT[];
    v_est    BIGINT[];
BEGIN
    SELECT COALESCE(ARRAY_AGG(PK_ESTABLECIMIENTO), '{}')
      INTO v_ee FROM academico_test.TESTABLECIMIENTO WHERE CODIGO LIKE 'TSTINF%';

    SELECT COALESCE(ARRAY_AGG(PK_TUSUARIO), '{}') INTO v_usr
      FROM academico_test.TUSUARIO WHERE IDENTIFICACION LIKE 'TSTINF%';

    IF CARDINALITY(v_ee) = 0 AND CARDINALITY(v_usr) = 0 THEN
        RAISE NOTICE 'teardown: no hay fixture que borrar';
        DROP TABLE IF EXISTS public.informes_test_fixture;
        RETURN;
    END IF;

    SELECT COALESCE(ARRAY_AGG(PK_TSEDE), '{}') INTO v_sede
      FROM academico_test.TSEDE WHERE FK_TESTABLECIMIENTO = ANY (v_ee);

    SELECT COALESCE(ARRAY_AGG(PK_TPERIODO_ACADEMICO), '{}') INTO v_peraca
      FROM academico_test.TPERIODO_ACADEMICO WHERE FK_TSEDE = ANY (v_sede);

    SELECT COALESCE(ARRAY_AGG(PK_TGRADO), '{}') INTO v_grado
      FROM academico_test.TGRADO WHERE FK_TPERIODO_ACADEMICO = ANY (v_peraca);

    SELECT COALESCE(ARRAY_AGG(PK_TGRUPO), '{}') INTO v_grupo
      FROM academico_test.TGRUPO WHERE FK_TGRADO = ANY (v_grado);

    SELECT COALESCE(ARRAY_AGG(PK_TMATRICULA), '{}') INTO v_mat
      FROM academico_test.TMATRICULA WHERE FK_TGRUPO = ANY (v_grupo);

    SELECT COALESCE(ARRAY_AGG(PK_TAREA), '{}') INTO v_area
      FROM academico_test.TAREA WHERE FK_TPERIODO_ACADEMICO = ANY (v_peraca);

    SELECT COALESCE(ARRAY_AGG(PK_TASIGNATURA), '{}') INTO v_asig
      FROM academico_test.TASIGNATURA WHERE FK_TAREA = ANY (v_area);

    SELECT COALESCE(ARRAY_AGG(PK_TUNIDAD), '{}') INTO v_uni
      FROM academico_test.TUNIDAD WHERE FK_TASIGNATURA = ANY (v_asig);

    SELECT COALESCE(ARRAY_AGG(PK_TACTIVIDAD), '{}') INTO v_act
      FROM academico_test.TACTIVIDAD WHERE FK_TASIGNATURA = ANY (v_asig);

    SELECT COALESCE(ARRAY_AGG(PK_TFUNCIONARIO), '{}') INTO v_fun
      FROM academico_test.TFUNCIONARIO WHERE FK_TUSUARIO = ANY (v_usr);

    SELECT COALESCE(ARRAY_AGG(PK_TESTUDIANTE), '{}') INTO v_est
      FROM academico_test.TESTUDIANTE WHERE FK_TUSUARIO = ANY (v_usr);

    -- Notas y consolidados -------------------------------------------------
    DELETE FROM academico_test.TACTIVIDAD_NOTA
     WHERE FK_TACTIVIDAD_ESTUDIANTE IN (
           SELECT PK_TACTIVIDAD_ESTUDIANTE FROM academico_test.TACTIVIDAD_ESTUDIANTE
            WHERE FK_TACTIVIDAD = ANY (v_act) OR FK_TMATRICULA = ANY (v_mat));
    DELETE FROM academico_test.TACTIVIDAD_ESTUDIANTE
     WHERE FK_TACTIVIDAD = ANY (v_act) OR FK_TMATRICULA = ANY (v_mat);
    DELETE FROM academico_test.TASISTENCIA                     WHERE FK_TMATRICULA = ANY (v_mat);
    DELETE FROM academico_test.TESTUDIANTE_PERIODO_OBSERVACION WHERE FK_TMATRICULA = ANY (v_mat);
    DELETE FROM academico_test.TINFORME_PERIODO_MATRICULA      WHERE FK_TMATRICULA = ANY (v_mat);
    DELETE FROM academico_test.TASIGNATURA_NOTA                WHERE FK_TMATRICULA = ANY (v_mat);
    DELETE FROM academico_test.TINFORME_GUARDADO_ESTUDIANTE    WHERE FK_TMATRICULA = ANY (v_mat);
    DELETE FROM academico_test.TINFORME_GUARDADO               WHERE FK_TGRUPO = ANY (v_grupo) OR FK_TASIGNATURA = ANY (v_asig);
    DELETE FROM academico_test.TESTUDIANTE_ANIO_OBSERVACION    WHERE FK_TMATRICULA = ANY (v_mat);
    DELETE FROM academico_test.TUNIDAD_NOTA                    WHERE FK_TMATRICULA = ANY (v_mat);
    DELETE FROM academico_test.TASIGNATURA_DEFINITIVA          WHERE FK_TMATRICULA = ANY (v_mat);

    -- Planeador ------------------------------------------------------------
    DELETE FROM academico_test.TACTIVIDAD  WHERE PK_TACTIVIDAD = ANY (v_act);
    DELETE FROM academico_test.TUNIDAD     WHERE PK_TUNIDAD    = ANY (v_uni);

    -- Matricula ------------------------------------------------------------
    DELETE FROM academico_test.TMATRICULA  WHERE PK_TMATRICULA = ANY (v_mat);
    DELETE FROM academico_test.TESTUDIANTE WHERE PK_TESTUDIANTE = ANY (v_est);

    -- Plan de estudios y criterios ----------------------------------------
    DELETE FROM academico_test.TCRITERIO_EVALUACION_ASIGNATURA_PLAN
     WHERE FK_TASIGNATURA_PLAN IN (SELECT ap.PK_TASIGNATURA_PLAN
                                     FROM academico_test.TASIGNATURA_PLAN ap
                                     JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
                                    WHERE pl.FK_TGRADO = ANY (v_grado));
    DELETE FROM academico_test.TASIGNATURA_PLAN
     WHERE FK_TPLAN IN (SELECT PK_TPLAN FROM academico_test.TPLAN WHERE FK_TGRADO = ANY (v_grado));
    DELETE FROM academico_test.TPLAN WHERE FK_TGRADO = ANY (v_grado);
    DELETE FROM academico_test.TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA
     WHERE FK_TCRITERIO_PROMOCION IN (SELECT PK_TCRITERIO_PROMOCION
                                        FROM academico_test.TCRITERIO_PROMOCION
                                       WHERE FK_TPERIODO_ACADEMICO = ANY (v_peraca));
    DELETE FROM academico_test.TCRITERIO_PROMOCION_GRADO
     WHERE FK_TCRITERIO_PROMOCION IN (SELECT PK_TCRITERIO_PROMOCION
                                        FROM academico_test.TCRITERIO_PROMOCION
                                       WHERE FK_TPERIODO_ACADEMICO = ANY (v_peraca));
    DELETE FROM academico_test.TCRITERIO_PROMOCION WHERE FK_TPERIODO_ACADEMICO = ANY (v_peraca);

    -- TESCALA / TCRITERIO_EVALUACION / TPLAN no cuelgan del periodo
    -- academico: se identifican por CREATED_BY.
    DELETE FROM academico_test.TESCALA_VALORACION
     WHERE FK_TESCALA IN (SELECT PK_TESCALA FROM academico_test.TESCALA WHERE CREATED_BY='TSTINF');
    DELETE FROM academico_test.TCRITERIO_EVALUACION WHERE CREATED_BY = 'TSTINF';
    DELETE FROM academico_test.TVALORACION          WHERE CREATED_BY = 'TSTINF';
    DELETE FROM academico_test.TESCALA              WHERE CREATED_BY = 'TSTINF';

    -- Asignacion academica -------------------------------------------------
    DELETE FROM academico_test.TDOCENTE_ASIGNATURA WHERE FK_TPERIODO_ACADEMICO = ANY (v_peraca);
    DELETE FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = ANY (v_asig);
    DELETE FROM academico_test.TAREA       WHERE PK_TAREA = ANY (v_area);

    -- Estructura -----------------------------------------------------------
    DELETE FROM academico_test.TGRUPO  WHERE PK_TGRUPO = ANY (v_grupo);
    DELETE FROM academico_test.TGRADO  WHERE PK_TGRADO = ANY (v_grado);
    DELETE FROM academico_test.TPERIODO_EVALUACION WHERE FK_TPERIODO_ACADEMICO = ANY (v_peraca);
    DELETE FROM academico_test.TPERIODO_ACADEMICO  WHERE PK_TPERIODO_ACADEMICO = ANY (v_peraca);
    DELETE FROM academico_test.TANO_LECTIVO        WHERE FK_TESTABLECIMIENTO  = ANY (v_ee);

    -- Usuarios y alcance ---------------------------------------------------
    DELETE FROM academico_test.TSEDE_USUARIO WHERE FK_TUSUARIO = ANY (v_usr) OR FK_TSEDE = ANY (v_sede);
    UPDATE academico_test.TESTABLECIMIENTO
       SET FK_TFUNCIONARIO_RECTOR = NULL, FK_TFUNCIONARIO_SECRETARIA = NULL
     WHERE PK_ESTABLECIMIENTO = ANY (v_ee);
    DELETE FROM academico_test.TFUNCIONARIO WHERE PK_TFUNCIONARIO = ANY (v_fun);
    DELETE FROM academico_test.TSEDE WHERE PK_TSEDE = ANY (v_sede);
    DELETE FROM academico_test.TESTABLECIMIENTO WHERE PK_ESTABLECIMIENTO = ANY (v_ee);
    DELETE FROM academico_test.TUSUARIO WHERE PK_TUSUARIO = ANY (v_usr);
    DELETE FROM public.users WHERE email LIKE '%@tstinf.local';

    -- Catalogos que el fixture siembra solo si faltaban. Se borran por
    -- CREATED_BY para no tocar nunca lo que trajo el dump base.
    DELETE FROM academico_test.TAREA_ASIGNATURA   WHERE CREATED_BY = 'TSTINF';
    DELETE FROM academico_test.TNIVEL_ENSENANZA   WHERE CREATED_BY = 'TSTINF';
    DELETE FROM academico_test.TLISTA_VALOR       WHERE CREATED_BY = 'TSTINF';

    RAISE NOTICE 'teardown: % establecimiento(s), % grupo(s), % matricula(s) borrados',
        CARDINALITY(v_ee), CARDINALITY(v_grupo), CARDINALITY(v_mat);
END
$teardown$;

DROP TABLE IF EXISTS public.informes_test_fixture;
