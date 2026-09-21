-- ===========================================================================
-- 01_seed - Sobre el fixture de informes (01_fixture + 02_notas), cuatro
-- actividades en MAT/601 fechadas HOY (P2 en curso), una por instrumento, y
-- sus calificaciones por la fachada fn_actividad_nota_calificar.
--
--   RUBRICA    2 criterios (100/50 y 100/60/20)   E1 80   E2 75
--   COTEJO     3 items, pesos 2 / NULL(=1) / 1    E1 75   E2 25
--   ESC CUAL   100/80/60/30                        E1 80   E2 60
--   ESC NUM    1.0 - 5.0                           E1 3.0  E2 5.0  E3 1.0
--
-- E4 queda sin asignar a proposito (control de asignacion). Los ids quedan
-- en public.calif_test_ids; 00 teardown de informes los borra por cascada.
-- ===========================================================================
\set ON_ERROR_STOP on
DROP TABLE IF EXISTS public.calif_test_ids;
CREATE TABLE public.calif_test_ids (clave TEXT PRIMARY KEY, valor BIGINT);

DO $seed$
DECLARE
    fx JSONB;
    v_admin BIGINT := 1;
    gr_601 BIGINT; asg_mat BIGINT; pe2 BIGINT;
    m1 BIGINT; m2 BIGINT; m3 BIGINT; m4 BIGINT;
    c_tipo_act BIGINT; c_jerarquia BIGINT;
    i_rub BIGINT; i_cot BIGINT; i_esc BIGINT;
    t_num BIGINT; t_cual BIGINT;
    a_rub BIGINT; a_cot BIGINT; a_escq BIGINT; a_escn BIGINT;
    d DATE := CURRENT_DATE;
    r RECORD;
    v_def JSONB;
    ae1 BIGINT; ae2 BIGINT; ae3 BIGINT;
    crit1 BIGINT; crit2 BIGINT; n1_alto BIGINT; n1_bajo BIGINT; n2_alto BIGINT; n2_medio BIGINT;
    it1 BIGINT; it2 BIGINT; it3 BIGINT;
    nq_sob BIGINT; nq_bas BIGINT;
    v_pct NUMERIC;
BEGIN
    SELECT JSONB_OBJECT_AGG(clave, valor) INTO fx FROM public.informes_test_fixture;
    gr_601 := (fx->>'gr_601')::BIGINT; asg_mat := (fx->>'asg_mat')::BIGINT; pe2 := (fx->>'pe2')::BIGINT;
    m1 := (fx->>'mat_e1')::BIGINT; m2 := (fx->>'mat_e2')::BIGINT; m3 := (fx->>'mat_e3')::BIGINT; m4 := (fx->>'mat_e4')::BIGINT;
    c_tipo_act := (fx->>'tipo_act')::BIGINT; c_jerarquia := (fx->>'jerarquia')::BIGINT;

    SELECT PK_LISTA_VALOR INTO i_rub FROM academico_test.TLISTA_VALOR WHERE CATEGORIA='INSTRUMENTO_EVALUACION' AND VALOR='RUBRICA' AND ACTIVE LIMIT 1;
    SELECT PK_LISTA_VALOR INTO i_cot FROM academico_test.TLISTA_VALOR WHERE CATEGORIA='INSTRUMENTO_EVALUACION' AND VALOR='LISTA_COTEJO' AND ACTIVE LIMIT 1;
    SELECT PK_LISTA_VALOR INTO i_esc FROM academico_test.TLISTA_VALOR WHERE CATEGORIA='INSTRUMENTO_EVALUACION' AND VALOR='ESCALA_VALORACION' AND ACTIVE LIMIT 1;
    SELECT PK_LISTA_VALOR INTO t_num  FROM academico_test.TLISTA_VALOR WHERE CATEGORIA='TIPO_ESCALA' AND VALOR='NUMERICA' AND ACTIVE LIMIT 1;
    SELECT PK_LISTA_VALOR INTO t_cual FROM academico_test.TLISTA_VALOR WHERE CATEGORIA='TIPO_ESCALA' AND VALOR='CUALITATIVA' AND ACTIVE LIMIT 1;
    IF i_rub IS NULL OR i_cot IS NULL OR i_esc IS NULL OR t_num IS NULL OR t_cual IS NULL THEN
        RAISE EXCEPTION 'faltan catalogos: rub=% cot=% esc=% num=% cual=%', i_rub, i_cot, i_esc, t_num, t_cual;
    END IF;

    FOR r IN SELECT * FROM (VALUES
        ('TSTCAL RUBRICA',   i_rub, 25::NUMERIC),
        ('TSTCAL COTEJO',    i_cot, 25::NUMERIC),
        ('TSTCAL ESC CUAL',  i_esc, 25::NUMERIC),
        ('TSTCAL ESC NUM',   i_esc, 25::NUMERIC)) v(titulo, instr, pond)
    LOOP
        INSERT INTO academico_test.TACTIVIDAD
            (TITULO, FK_TASIGNATURA, FK_TGRUPO, FK_TLV_TIPO_ACTIVIDAD, FK_TLV_JERARQUIA,
             FK_TLV_INSTRUMENTO_EVALUACION, ES_EVALUATIVA, PONDERACION,
             FECHA_INICIO, FECHA_CIERRE, FECHA_CREACION, NOTA_MAXIMA, CREATED_BY, CREATED_AT, ACTIVE)
        VALUES (r.titulo, asg_mat, gr_601, c_tipo_act, c_jerarquia, r.instr, 'S', r.pond,
                d, d, CURRENT_TIMESTAMP, 100, 'TSTCAL', CURRENT_TIMESTAMP, TRUE)
        RETURNING PK_TACTIVIDAD INTO a_rub;
        INSERT INTO public.calif_test_ids VALUES (r.titulo, a_rub);
        -- Solo E1..E3: E4 queda SIN asignar a proposito (control de asignacion)
        PERFORM academico_test.fn_actividad_estudiantes_asignar(v_admin, a_rub, ARRAY[m1,m2,m3], FALSE);
    END LOOP;
    SELECT valor INTO a_rub  FROM public.calif_test_ids WHERE clave='TSTCAL RUBRICA';
    SELECT valor INTO a_cot  FROM public.calif_test_ids WHERE clave='TSTCAL COTEJO';
    SELECT valor INTO a_escq FROM public.calif_test_ids WHERE clave='TSTCAL ESC CUAL';
    SELECT valor INTO a_escn FROM public.calif_test_ids WHERE clave='TSTCAL ESC NUM';

    ---------------- RUBRICA: 2 criterios, niveles 100/50 y 100/60/20 ----------------
    PERFORM academico_test.fn_actividad_instrumento_definir(v_admin, a_rub, jsonb_build_array(
        jsonb_build_object('nombre','Argumenta','niveles', jsonb_build_array(
            jsonb_build_object('etiqueta','Excelente','descripcion','Argumenta muy bien','ponderacion',100),
            jsonb_build_object('etiqueta','Bajo','descripcion','No argumenta','ponderacion',50))),
        jsonb_build_object('nombre','Presenta','niveles', jsonb_build_array(
            jsonb_build_object('etiqueta','Excelente','descripcion','Presenta muy bien','ponderacion',100),
            jsonb_build_object('etiqueta','Basico','descripcion','Presenta regular','ponderacion',60),
            jsonb_build_object('etiqueta','Bajo','descripcion','No presenta','ponderacion',20)))));
    SELECT c.PK_TACTIVIDAD_RUBRICA_CRITERIO INTO crit1 FROM academico_test.TACTIVIDAD_RUBRICA_CRITERIO c WHERE c.FK_TACTIVIDAD=a_rub AND c.NOMBRE='Argumenta' AND c.ACTIVE;
    SELECT c.PK_TACTIVIDAD_RUBRICA_CRITERIO INTO crit2 FROM academico_test.TACTIVIDAD_RUBRICA_CRITERIO c WHERE c.FK_TACTIVIDAD=a_rub AND c.NOMBRE='Presenta' AND c.ACTIVE;
    SELECT PK_TACTIVIDAD_RUBRICA_NIVEL INTO n1_alto FROM academico_test.TACTIVIDAD_RUBRICA_NIVEL WHERE FK_TACTIVIDAD_RUBRICA_CRITERIO=crit1 AND PONDERACION=100;
    SELECT PK_TACTIVIDAD_RUBRICA_NIVEL INTO n1_bajo FROM academico_test.TACTIVIDAD_RUBRICA_NIVEL WHERE FK_TACTIVIDAD_RUBRICA_CRITERIO=crit1 AND PONDERACION=50;
    SELECT PK_TACTIVIDAD_RUBRICA_NIVEL INTO n2_alto FROM academico_test.TACTIVIDAD_RUBRICA_NIVEL WHERE FK_TACTIVIDAD_RUBRICA_CRITERIO=crit2 AND PONDERACION=100;
    SELECT PK_TACTIVIDAD_RUBRICA_NIVEL INTO n2_medio FROM academico_test.TACTIVIDAD_RUBRICA_NIVEL WHERE FK_TACTIVIDAD_RUBRICA_CRITERIO=crit2 AND PONDERACION=60;
    INSERT INTO public.calif_test_ids VALUES ('crit1',crit1),('crit2',crit2),('n1_alto',n1_alto),('n1_bajo',n1_bajo),('n2_alto',n2_alto),('n2_medio',n2_medio);

    SELECT PK_TACTIVIDAD_ESTUDIANTE INTO ae1 FROM academico_test.TACTIVIDAD_ESTUDIANTE WHERE FK_TACTIVIDAD=a_rub AND FK_TMATRICULA=m1 AND ACTIVE;
    SELECT PK_TACTIVIDAD_ESTUDIANTE INTO ae2 FROM academico_test.TACTIVIDAD_ESTUDIANTE WHERE FK_TACTIVIDAD=a_rub AND FK_TMATRICULA=m2 AND ACTIVE;
    INSERT INTO public.calif_test_ids VALUES ('ae_rub_e1',ae1),('ae_rub_e2',ae2);
    -- E1: Excelente + Basico  -> (100 + 60)/2 = 80
    v_pct := academico_test.fn_actividad_nota_calificar(v_admin, ae1,
        jsonb_build_object('niveles', jsonb_build_array(
            jsonb_build_object('pkCriterio',crit1,'pkNivel',n1_alto),
            jsonb_build_object('pkCriterio',crit2,'pkNivel',n2_medio))), d);
    RAISE NOTICE 'RUBRICA E1 esperado 80.00 -> %', v_pct;
    -- E2: Bajo + Excelente -> (50 + 100)/2 = 75
    v_pct := academico_test.fn_actividad_nota_calificar(v_admin, ae2,
        jsonb_build_object('niveles', jsonb_build_array(
            jsonb_build_object('pkCriterio',crit1,'pkNivel',n1_bajo),
            jsonb_build_object('pkCriterio',crit2,'pkNivel',n2_alto))), d);
    RAISE NOTICE 'RUBRICA E2 esperado 75.00 -> %', v_pct;

    ---------------- COTEJO: 3 items, pesos 2, NULL(=1), 1 ; total 4 ----------------
    PERFORM academico_test.fn_actividad_instrumento_definir(v_admin, a_cot, jsonb_build_array(
        jsonb_build_object('descripcion','Entrega a tiempo','ponderacion',2),
        jsonb_build_object('descripcion','Portada'),
        jsonb_build_object('descripcion','Bibliografia','ponderacion',1)));
    SELECT PK_TACTIVIDAD_COTEJO_ITEM INTO it1 FROM academico_test.TACTIVIDAD_COTEJO_ITEM WHERE FK_TACTIVIDAD=a_cot AND DESCRIPCION='Entrega a tiempo' AND ACTIVE;
    SELECT PK_TACTIVIDAD_COTEJO_ITEM INTO it2 FROM academico_test.TACTIVIDAD_COTEJO_ITEM WHERE FK_TACTIVIDAD=a_cot AND DESCRIPCION='Portada' AND ACTIVE;
    SELECT PK_TACTIVIDAD_COTEJO_ITEM INTO it3 FROM academico_test.TACTIVIDAD_COTEJO_ITEM WHERE FK_TACTIVIDAD=a_cot AND DESCRIPCION='Bibliografia' AND ACTIVE;
    INSERT INTO public.calif_test_ids VALUES ('it1',it1),('it2',it2),('it3',it3);
    SELECT PK_TACTIVIDAD_ESTUDIANTE INTO ae1 FROM academico_test.TACTIVIDAD_ESTUDIANTE WHERE FK_TACTIVIDAD=a_cot AND FK_TMATRICULA=m1 AND ACTIVE;
    SELECT PK_TACTIVIDAD_ESTUDIANTE INTO ae2 FROM academico_test.TACTIVIDAD_ESTUDIANTE WHERE FK_TACTIVIDAD=a_cot AND FK_TMATRICULA=m2 AND ACTIVE;
    INSERT INTO public.calif_test_ids VALUES ('ae_cot_e1',ae1),('ae_cot_e2',ae2);
    -- E1 marca it1+it2 -> 3/4 = 75 ; E2 marca solo it3 -> 1/4 = 25
    v_pct := academico_test.fn_actividad_nota_calificar(v_admin, ae1, jsonb_build_object('itemsMarcados', jsonb_build_array(it1,it2)), d);
    RAISE NOTICE 'COTEJO E1 esperado 75.00 -> %', v_pct;
    v_pct := academico_test.fn_actividad_nota_calificar(v_admin, ae2, jsonb_build_object('itemsMarcados', jsonb_build_array(it3)), d);
    RAISE NOTICE 'COTEJO E2 esperado 25.00 -> %', v_pct;

    ---------------- ESCALA CUALITATIVA: Superior 100 / Sobresaliente 80 / Basico 60 / Bajo 30 ----------------
    PERFORM academico_test.fn_actividad_instrumento_definir(v_admin, a_escq, jsonb_build_object(
        'tipoEscala', t_cual,
        'niveles', jsonb_build_array(
            jsonb_build_object('etiqueta','Superior','descripcion','Superior','ponderacion',100),
            jsonb_build_object('etiqueta','Sobresaliente','descripcion','Sobresaliente','ponderacion',80),
            jsonb_build_object('etiqueta','Basico','descripcion','Basico','ponderacion',60),
            jsonb_build_object('etiqueta','Bajo','descripcion','Bajo','ponderacion',30))));
    SELECT n.PK_TACTIVIDAD_ESCALA_NIVEL INTO nq_sob FROM academico_test.TACTIVIDAD_ESCALA_NIVEL n JOIN academico_test.TACTIVIDAD_ESCALA e ON e.PK_TACTIVIDAD_ESCALA=n.FK_TACTIVIDAD_ESCALA WHERE e.FK_TACTIVIDAD=a_escq AND n.PONDERACION=80 AND n.ACTIVE;
    SELECT n.PK_TACTIVIDAD_ESCALA_NIVEL INTO nq_bas FROM academico_test.TACTIVIDAD_ESCALA_NIVEL n JOIN academico_test.TACTIVIDAD_ESCALA e ON e.PK_TACTIVIDAD_ESCALA=n.FK_TACTIVIDAD_ESCALA WHERE e.FK_TACTIVIDAD=a_escq AND n.PONDERACION=60 AND n.ACTIVE;
    INSERT INTO public.calif_test_ids VALUES ('nq_sob',nq_sob),('nq_bas',nq_bas);
    SELECT PK_TACTIVIDAD_ESTUDIANTE INTO ae1 FROM academico_test.TACTIVIDAD_ESTUDIANTE WHERE FK_TACTIVIDAD=a_escq AND FK_TMATRICULA=m1 AND ACTIVE;
    SELECT PK_TACTIVIDAD_ESTUDIANTE INTO ae2 FROM academico_test.TACTIVIDAD_ESTUDIANTE WHERE FK_TACTIVIDAD=a_escq AND FK_TMATRICULA=m2 AND ACTIVE;
    INSERT INTO public.calif_test_ids VALUES ('ae_escq_e1',ae1),('ae_escq_e2',ae2);
    v_pct := academico_test.fn_actividad_nota_calificar(v_admin, ae1, jsonb_build_object('pkNivel', nq_sob), d);
    RAISE NOTICE 'ESC CUAL E1 Sobresaliente esperado 80.00 -> %', v_pct;
    v_pct := academico_test.fn_actividad_nota_calificar(v_admin, ae2, jsonb_build_object('pkNivel', nq_bas), d);
    RAISE NOTICE 'ESC CUAL E2 Basico esperado 60.00 -> %', v_pct;

    ---------------- ESCALA NUMERICA 1.0 - 5.0 ----------------
    PERFORM academico_test.fn_actividad_instrumento_definir(v_admin, a_escn, jsonb_build_object(
        'tipoEscala', t_num, 'valorMin', 1, 'valorMax', 5));
    SELECT PK_TACTIVIDAD_ESTUDIANTE INTO ae1 FROM academico_test.TACTIVIDAD_ESTUDIANTE WHERE FK_TACTIVIDAD=a_escn AND FK_TMATRICULA=m1 AND ACTIVE;
    SELECT PK_TACTIVIDAD_ESTUDIANTE INTO ae2 FROM academico_test.TACTIVIDAD_ESTUDIANTE WHERE FK_TACTIVIDAD=a_escn AND FK_TMATRICULA=m2 AND ACTIVE;
    SELECT PK_TACTIVIDAD_ESTUDIANTE INTO ae3 FROM academico_test.TACTIVIDAD_ESTUDIANTE WHERE FK_TACTIVIDAD=a_escn AND FK_TMATRICULA=m3 AND ACTIVE;
    INSERT INTO public.calif_test_ids VALUES ('ae_escn_e1',ae1),('ae_escn_e2',ae2),('ae_escn_e3',ae3);
    v_pct := academico_test.fn_actividad_nota_calificar(v_admin, ae1, jsonb_build_object('valorNumerico', 3.0), d);
    RAISE NOTICE 'ESC NUM E1 digita 3.0 en 1-5 -> % (esperado 60)', v_pct;
    v_pct := academico_test.fn_actividad_nota_calificar(v_admin, ae2, jsonb_build_object('valorNumerico', 5.0), d);
    RAISE NOTICE 'ESC NUM E2 digita 5.0 -> %', v_pct;
    v_pct := academico_test.fn_actividad_nota_calificar(v_admin, ae3, jsonb_build_object('valorNumerico', 1.0), d);
    RAISE NOTICE 'ESC NUM E3 digita 1.0 -> %', v_pct;
END
$seed$;
