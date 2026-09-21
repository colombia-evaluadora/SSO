-- ===========================================================================
-- 02_notas - Unidades ya estan; aqui van las ACTIVIDADES y sus CALIFICACIONES.
--
-- LAS NOTAS NO SON ALEATORIAS
--   Cada porcentaje esta elegido para que el resultado de cada funcion se
--   pueda calcular a mano en la cabecera del test que lo comprueba. El cuadro
--   completo del PRIMER PERIODO (P1), que es el unico cerrado:
--
--     asignatura  motor                     E1            E2            E3
--     MAT         ACTIVIDADES + PONDERAR    80/90 -> 87   60/50 -> 53   40/60 -> 54
--                 (ponderaciones 30 y 70)
--     LEN         UNIDADES + PROMEDIAR      70/90 -> 80   60/80 -> 70   90/70 -> 80
--     CN          sin configurar -> promedio   50 -> 50      95 -> 95      84 -> 84
--
--     promedio    media simple de las tres  72.33         72.67         72.67
--     puesto (RANK, desc)                       3             1             1
--
--   E2 y E3 EMPATAN a proposito: el puesto es RANK y no ROW_NUMBER, y dos
--   empatados tienen que compartir el 1. E4 no tiene ninguna nota: su puesto
--   debe ser NULL, no el ultimo -- no tener notas no es rendir mal.
--
--   Con DESEMPENHO_MINIMO = 60 los tres quedan 2 aprobadas / 1 reprobada,
--   pero por asignaturas DISTINTAS (E1 pierde CN, E2 y E3 pierden MAT). Es
--   deliberado: un conteo correcto por casualidad no prueba nada.
--
-- P2 (EN CURSO) SOLO TIENE MATEMATICAS
--   E1 saca 100 y E2 saca 20. Es lo que demuestra que
--   fn_asignatura_definitiva_proyectada_periodo ACOTA por periodo: la misma
--   matricula y la misma asignatura dan 87 en P1 y 100 en P2. Si alguien
--   reintrodujera fn_planilla_definitiva_proyectada (que no filtra por
--   periodo) los dos numeros colapsarian y el test lo veria.
--
-- P3 (FUTURO) TIENE UNA ACTIVIDAD CALIFICADA
--   Para que "futuro" no se pruebe con el conjunto vacio, que pasaria igual
--   con una funcion rota. Hay nota en P3 y NO debe aparecer en P1 ni en P2.
--
-- PREESCOLAR
--   Dos actividades con OBSERVACION y CALIFICABLE='N'. No promedian -- es
--   justo lo que hace que el grupo salga 'cualitativo' -- y son la materia
--   prima del resumen de la IA (V332).
--
-- LA PLANILLA PENDIENTE
--   A 601 se le asigna un docente en DIM sin ninguna actividad. Como DIM no
--   tiene plan ni actividades, NO aparece en el informe (el universo son las
--   asignaturas con nota o actividad), pero SI en la alerta roja, que parte de
--   TDOCENTE_ASIGNATURA. Es el unico caso 'actividades = 0' del fixture.
-- ===========================================================================

\set ON_ERROR_STOP on

DO $notas$
DECLARE
    fx  JSONB;
    v_admin BIGINT := 1;
    v_hoy DATE := CURRENT_DATE;

    pe1 BIGINT; pe2 BIGINT; pe3 BIGINT;
    gr_601 BIGINT; gr_jar BIGINT;
    asg_mat BIGINT; asg_len BIGINT; asg_cn BIGINT; asg_dim BIGINT;
    uni_len BIGINT; uni_cn BIGINT;
    g_sexto BIGINT; pa_a BIGINT; f_doc_a BIGINT;
    m1 BIGINT; m2 BIGINT; m3 BIGINT; j1 BIGINT; j2 BIGINT;
    c_tipo_act BIGINT; c_jerarquia BIGINT; c_instr BIGINT; c_asistio BIGINT;

    v_act BIGINT;
    r RECORD;

    -- Fechas: el centro de cada periodo, para que fn_actividad_en_periodo_eval
    -- (que usa COALESCE(FECHA_CIERRE, FECHA_INICIO, FECHA_CREACION)) no quede
    -- nunca en el borde.
    d_p1 DATE := CURRENT_DATE - 90;
    d_p2 DATE := CURRENT_DATE;
    d_p3 DATE := CURRENT_DATE + 60;

BEGIN
    SELECT JSONB_OBJECT_AGG(clave, valor) INTO fx FROM public.informes_test_fixture;
    IF fx IS NULL THEN RAISE EXCEPTION '02_notas: falta el fixture (corre 01_fixture.sql)'; END IF;

    pe1 := (fx->>'pe1')::BIGINT;   pe2 := (fx->>'pe2')::BIGINT;   pe3 := (fx->>'pe3')::BIGINT;
    gr_601 := (fx->>'gr_601')::BIGINT; gr_jar := (fx->>'gr_jar')::BIGINT;
    asg_mat := (fx->>'asg_mat')::BIGINT; asg_len := (fx->>'asg_len')::BIGINT;
    asg_cn := (fx->>'asg_cn')::BIGINT;   asg_dim := (fx->>'asg_dim')::BIGINT;
    uni_len := (fx->>'uni_len')::BIGINT; uni_cn := (fx->>'uni_cn')::BIGINT;
    g_sexto := (fx->>'g_sexto')::BIGINT; pa_a := (fx->>'pa_a')::BIGINT;
    f_doc_a := (fx->>'f_doc_a')::BIGINT;
    m1 := (fx->>'mat_e1')::BIGINT; m2 := (fx->>'mat_e2')::BIGINT; m3 := (fx->>'mat_e3')::BIGINT;
    j1 := (fx->>'mat_j1')::BIGINT; j2 := (fx->>'mat_j2')::BIGINT;
    c_tipo_act := (fx->>'tipo_act')::BIGINT; c_jerarquia := (fx->>'jerarquia')::BIGINT;
    c_instr := (fx->>'instr_otro')::BIGINT;

    SELECT PK_LISTA_VALOR INTO c_asistio
      FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA='TIPO_ASISTENCIA' AND VALOR='1' AND ACTIVE LIMIT 1;

    ---------------------------------------------------------------------
    -- Asistencia: fn_actividad_nota_calificar_* NO deja calificar un dia
    -- sin asistencia registrada para esa (matricula, asignatura)
    -- -- fn_actividad_nota_asistencia_assert, V227. No es un obstaculo del
    -- fixture sino el contrato real: se siembra 'Asistio' para cada
    -- combinacion que se va a calificar. Sembrar 'NO Asistio' (VALOR=2)
    -- bloquearia la calificacion, que es otro test y no este.
    ---------------------------------------------------------------------
    INSERT INTO academico_test.TASISTENCIA
        (FECHA, FK_TLV_TIPO_ASISTENCIA, FK_TASIGNATURA, FK_TPERIODO_EVALUACION,
         FK_TMATRICULA, CREATED_BY, CREATED_AT, ACTIVE)
    SELECT d.fecha, c_asistio, a.asig, d.pe, m.mat, 'TSTINF', CURRENT_TIMESTAMP, TRUE
      FROM (VALUES (d_p1, pe1), (d_p2, pe2), (d_p3, pe3)) d(fecha, pe)
     CROSS JOIN (VALUES (asg_mat), (asg_len), (asg_cn), (asg_dim)) a(asig)
     CROSS JOIN (VALUES (m1), (m2), (m3), ((fx->>'mat_e4')::BIGINT),
                        (j1), (j2)) m(mat);

    ---------------------------------------------------------------------
    -- Helper inline: crear actividad + asignar al grupo.
    -- (se repite en linea porque una funcion auxiliar en el esquema seria
    --  un objeto mas que limpiar en el teardown)
    ---------------------------------------------------------------------

    -- ---------- P1 / MAT: dos actividades ponderadas 30 y 70 ----------
    FOR r IN
        SELECT * FROM (VALUES
            ('TSTINF MAT P1 A1', 30::NUMERIC, d_p1, ARRAY[80,60,40]),
            ('TSTINF MAT P1 A2', 70::NUMERIC, d_p1, ARRAY[90,50,60])
        ) v(titulo, pond, fecha, notas)
    LOOP
        INSERT INTO academico_test.TACTIVIDAD
            (TITULO, FK_TASIGNATURA, FK_TGRUPO, FK_TLV_TIPO_ACTIVIDAD, FK_TLV_JERARQUIA,
             FK_TLV_INSTRUMENTO_EVALUACION, ES_EVALUATIVA, PONDERACION,
             FECHA_INICIO, FECHA_CIERRE, FECHA_CREACION, NOTA_MAXIMA,
             CREATED_BY, CREATED_AT, ACTIVE)
        VALUES (r.titulo, asg_mat, gr_601, c_tipo_act, c_jerarquia, c_instr, 'S', r.pond,
                r.fecha, r.fecha, CURRENT_TIMESTAMP, 100, 'TSTINF', CURRENT_TIMESTAMP, TRUE)
        RETURNING PK_TACTIVIDAD INTO v_act;

        PERFORM academico_test.fn_actividad_estudiantes_asignar(v_admin, v_act, NULL, TRUE);

        PERFORM academico_test.fn_actividad_nota_calificar_otro(
                    v_admin, ae.PK_TACTIVIDAD_ESTUDIANTE,
                    (r.notas[x.i])::NUMERIC, r.fecha)
           FROM (VALUES (m1,1),(m2,2),(m3,3)) x(mat, i)
           JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
             ON ae.FK_TACTIVIDAD = v_act AND ae.FK_TMATRICULA = x.mat AND ae.ACTIVE;
    END LOOP;

    -- ---------- P1 / LEN: dos actividades DENTRO de la unidad ----------
    FOR r IN
        SELECT * FROM (VALUES
            ('TSTINF LEN P1 A1', ARRAY[70,60,90]),
            ('TSTINF LEN P1 A2', ARRAY[90,80,70])
        ) v(titulo, notas)
    LOOP
        INSERT INTO academico_test.TACTIVIDAD
            (TITULO, FK_TASIGNATURA, FK_TGRUPO, FK_TUNIDAD, FK_TLV_TIPO_ACTIVIDAD, FK_TLV_JERARQUIA,
             FK_TLV_INSTRUMENTO_EVALUACION, ES_EVALUATIVA, PONDERACION,
             FECHA_INICIO, FECHA_CIERRE, FECHA_CREACION, NOTA_MAXIMA,
             CREATED_BY, CREATED_AT, ACTIVE)
        VALUES (r.titulo, asg_len, gr_601, uni_len, c_tipo_act, c_jerarquia, c_instr, 'S', 50,
                d_p1, d_p1, CURRENT_TIMESTAMP, 100, 'TSTINF', CURRENT_TIMESTAMP, TRUE)
        RETURNING PK_TACTIVIDAD INTO v_act;

        PERFORM academico_test.fn_actividad_estudiantes_asignar(v_admin, v_act, NULL, TRUE);

        PERFORM academico_test.fn_actividad_nota_calificar_otro(
                    v_admin, ae.PK_TACTIVIDAD_ESTUDIANTE, (r.notas[x.i])::NUMERIC, d_p1)
           FROM (VALUES (m1,1),(m2,2),(m3,3)) x(mat, i)
           JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
             ON ae.FK_TACTIVIDAD = v_act AND ae.FK_TMATRICULA = x.mat AND ae.ACTIVE;
    END LOOP;

    -- ---------- P1 / CN: una actividad, sin configuracion de motor ----------
    INSERT INTO academico_test.TACTIVIDAD
        (TITULO, FK_TASIGNATURA, FK_TGRUPO, FK_TUNIDAD, FK_TLV_TIPO_ACTIVIDAD, FK_TLV_JERARQUIA,
         FK_TLV_INSTRUMENTO_EVALUACION, ES_EVALUATIVA, PONDERACION,
         FECHA_INICIO, FECHA_CIERRE, FECHA_CREACION, NOTA_MAXIMA,
         CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF CN P1 A1', asg_cn, gr_601, uni_cn, c_tipo_act, c_jerarquia, c_instr, 'S', 100,
            d_p1, d_p1, CURRENT_TIMESTAMP, 100, 'TSTINF', CURRENT_TIMESTAMP, TRUE)
    RETURNING PK_TACTIVIDAD INTO v_act;
    PERFORM academico_test.fn_actividad_estudiantes_asignar(v_admin, v_act, NULL, TRUE);
    PERFORM academico_test.fn_actividad_nota_calificar_otro(
                v_admin, ae.PK_TACTIVIDAD_ESTUDIANTE, (x.nota)::NUMERIC, d_p1)
       FROM (VALUES (m1,50),(m2,95),(m3,84)) x(mat, nota)
       JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
         ON ae.FK_TACTIVIDAD = v_act AND ae.FK_TMATRICULA = x.mat AND ae.ACTIVE;

    -- ---------- P2 (en curso) / MAT: solo E1 y E2 ----------
    INSERT INTO academico_test.TACTIVIDAD
        (TITULO, FK_TASIGNATURA, FK_TGRUPO, FK_TLV_TIPO_ACTIVIDAD, FK_TLV_JERARQUIA,
         FK_TLV_INSTRUMENTO_EVALUACION, ES_EVALUATIVA, PONDERACION,
         FECHA_INICIO, FECHA_CIERRE, FECHA_CREACION, NOTA_MAXIMA,
         CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF MAT P2 A1', asg_mat, gr_601, c_tipo_act, c_jerarquia, c_instr, 'S', 100,
            d_p2, d_p2, CURRENT_TIMESTAMP, 100, 'TSTINF', CURRENT_TIMESTAMP, TRUE)
    RETURNING PK_TACTIVIDAD INTO v_act;
    PERFORM academico_test.fn_actividad_estudiantes_asignar(v_admin, v_act, NULL, TRUE);
    PERFORM academico_test.fn_actividad_nota_calificar_otro(
                v_admin, ae.PK_TACTIVIDAD_ESTUDIANTE, (x.nota)::NUMERIC, d_p2)
       FROM (VALUES (m1,100),(m2,20)) x(mat, nota)
       JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
         ON ae.FK_TACTIVIDAD = v_act AND ae.FK_TMATRICULA = x.mat AND ae.ACTIVE;

    -- ---------- P3 (futuro) / MAT: nota que NO debe filtrarse ----------
    INSERT INTO academico_test.TACTIVIDAD
        (TITULO, FK_TASIGNATURA, FK_TGRUPO, FK_TLV_TIPO_ACTIVIDAD, FK_TLV_JERARQUIA,
         FK_TLV_INSTRUMENTO_EVALUACION, ES_EVALUATIVA, PONDERACION,
         FECHA_INICIO, FECHA_CIERRE, FECHA_CREACION, NOTA_MAXIMA,
         CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF MAT P3 A1', asg_mat, gr_601, c_tipo_act, c_jerarquia, c_instr, 'S', 100,
            d_p3, d_p3, CURRENT_TIMESTAMP, 100, 'TSTINF', CURRENT_TIMESTAMP, TRUE)
    RETURNING PK_TACTIVIDAD INTO v_act;
    PERFORM academico_test.fn_actividad_estudiantes_asignar(v_admin, v_act, NULL, TRUE);
    PERFORM academico_test.fn_actividad_nota_calificar_otro(
                v_admin, ae.PK_TACTIVIDAD_ESTUDIANTE, 10::NUMERIC, d_p3)
       FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
      WHERE ae.FK_TACTIVIDAD = v_act AND ae.FK_TMATRICULA = m1 AND ae.ACTIVE;

    -- ---------- Preescolar: observaciones, CALIFICABLE='N' ----------
    FOR r IN
        SELECT * FROM (VALUES
            ('TSTINF DIM P1 Juego', 'Participa con entusiasmo en el juego libre.'),
            ('TSTINF DIM P1 Ronda', 'Sigue instrucciones sencillas y comparte materiales.')
        ) v(titulo, obs)
    LOOP
        INSERT INTO academico_test.TACTIVIDAD
            (TITULO, FK_TASIGNATURA, FK_TGRUPO, FK_TLV_TIPO_ACTIVIDAD, FK_TLV_JERARQUIA,
             FK_TLV_INSTRUMENTO_EVALUACION, ES_EVALUATIVA, PONDERACION,
             FECHA_INICIO, FECHA_CIERRE, FECHA_CREACION, NOTA_MAXIMA,
             CREATED_BY, CREATED_AT, ACTIVE)
        VALUES (r.titulo, asg_dim, gr_jar, c_tipo_act, c_jerarquia, c_instr, 'S', 100,
                d_p1, d_p1, CURRENT_TIMESTAMP, 100, 'TSTINF', CURRENT_TIMESTAMP, TRUE)
        RETURNING PK_TACTIVIDAD INTO v_act;

        PERFORM academico_test.fn_actividad_estudiantes_asignar(v_admin, v_act, NULL, TRUE);

        -- Se escriben directo: el camino real (fn_actividad_observar_*) exige
        -- alcance de planeador y aqui interesa el DATO, no ese gate, que tiene
        -- sus propias pruebas.
        INSERT INTO academico_test.TACTIVIDAD_NOTA
            (FK_TACTIVIDAD_ESTUDIANTE, CALIFICABLE, OBSERVACION, CREATED_BY, CREATED_AT, ACTIVE)
        SELECT ae.PK_TACTIVIDAD_ESTUDIANTE, 'N', r.obs, 'TSTINF', CURRENT_TIMESTAMP, TRUE
          FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
         WHERE ae.FK_TACTIVIDAD = v_act AND ae.ACTIVE;
    END LOOP;

    -- ---------- Planilla pendiente: docente en DIM para 601, sin actividades --
    INSERT INTO academico_test.TDOCENTE_ASIGNATURA
        (FK_TGRUPO, FK_TFUNCIONARIO, FK_TASIGNATURA, FK_TPERIODO_ACADEMICO, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES (gr_601, f_doc_a, asg_dim, pa_a, 'TSTINF', CURRENT_TIMESTAMP, TRUE);

    RAISE NOTICE '02_notas: % actividades, % notas',
        (SELECT COUNT(*) FROM academico_test.TACTIVIDAD WHERE CREATED_BY='TSTINF'),
        (SELECT COUNT(*) FROM academico_test.TACTIVIDAD_NOTA WHERE CREATED_BY='TSTINF'
            OR FK_TACTIVIDAD_ESTUDIANTE IN (SELECT PK_TACTIVIDAD_ESTUDIANTE
                                              FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
                                              JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD=ae.FK_TACTIVIDAD
                                             WHERE a.CREATED_BY='TSTINF'));
END
$notas$;
