-- ===========================================================================
-- 01_fixture - El colegio de prueba del modulo de informes (V330-V347).
--
-- QUE MONTA, Y POR QUE ASI
--   Dos establecimientos. El primero (A) es el sujeto de prueba; el segundo
--   (B) existe solo para tener un usuario LEGITIMO de otro colegio con el que
--   comprobar que el gate devuelve 42501 -- un usuario sin ningun rol falla
--   por una razon distinta (capability) y no probaria el ALCANCE.
--
--   Tres periodos de evaluacion con fechas relativas a CURRENT_DATE:
--     P1  ya termino   -> el unico que puede tener "planillas pendientes"
--     P2  en curso     -> el caso normal de proyeccion
--     P3  futuro       -> no debe aportar nada a ningun calculo
--   Los PORCENTAJE son 30/30/40: suman 100 y ninguna funcion del modulo los
--   lee. Es el hueco del periodo "4 / Final" hecho dato, para que el test que
--   lo documenta tenga contra que afirmar.
--
--   Tres grados, cada uno una rama distinta:
--     SEXTO   numerico, DESEMPENHO_MINIMO = 60   -> aprobada TRUE / FALSE
--     SEPTIMO numerico, criterio SIN minimo      -> aprobada NULL (desconocida)
--     JARDIN  preescolar, sin plan de estudios   -> formato cualitativo
--
--   Y tres motores de calculo, uno por asignatura, para que la proyeccion
--   recorra las tres ramas de fn_asignatura_definitiva_proyectada_periodo:
--     MAT  ACTIVIDADES + PONDERAR
--     LEN  UNIDADES    + PROMEDIAR
--     CN   sin configurar -> fallback a promedio simple
--
--   Cuatro estudiantes en 601 con notas elegidas para que el promedio y el
--   puesto se puedan calcular a mano, incluido un EMPATE (E2 y E3, porque el
--   puesto es RANK y no ROW_NUMBER) y un estudiante SIN NINGUNA nota (E4),
--   que debe quedar con puesto NULL: no tener notas no es rendir mal.
--
-- CATALOGOS QUE PUEDEN NO EXISTIR
--   FORMATO_CALIFICACION no viene en las migraciones (llega por el dump base,
--   igual que TROL). Si falta, la escala no resuelve, fn_nota_homologar
--   devuelve formato NULL y TODO el grupo se clasificaria como cualitativo --
--   el test numerico pasaria a probar otra cosa sin avisar. Por eso se siembra
--   si no esta, marcado con CREATED_BY='TSTINF' para que el teardown solo
--   borre lo que creo el fixture.
--
-- DONDE QUEDAN LOS IDS
--   En public.informes_test_fixture (clave, valor). Los tests y la coleccion
--   de Postman leen de ahi: ningun id se escribe a mano en un assert.
-- ===========================================================================

\set ON_ERROR_STOP on

CREATE TABLE IF NOT EXISTS public.informes_test_fixture (
    clave TEXT PRIMARY KEY,
    valor BIGINT
);
TRUNCATE public.informes_test_fixture;

DO $fixture$
DECLARE
    -- Catalogos: se resuelven por VALOR de texto, nunca por pk -- los
    -- pk_lista_valor difieren entre el servidor de test y un Postgres limpio.
    c_jornada    BIGINT; c_estado     BIGINT;
    c_niv_pre    BIGINT; c_niv_sec    BIGINT;
    c_td_ti      BIGINT; c_td_cc      BIGINT;
    c_genero     BIGINT; c_est_mat    BIGINT;
    c_tipo_act   BIGINT; c_jerarquia  BIGINT; c_instr_otro BIGINT;
    c_lv1        BIGINT; c_lv2        BIGINT;   -- CALCULO_DEFINITIVA '1' / '2'
    c_modelo     BIGINT; c_propjur    BIGINT; c_municipio BIGINT;
    c_zona       BIGINT; c_tipo_val   BIGINT;
    c_fmt_cinco  BIGINT;

    v_admin BIGINT := 1;    -- super admin: siembra sin pelear gates

    ee_a BIGINT; ee_b BIGINT; sede_a BIGINT; sede_b BIGINT;
    ano_a BIGINT; ano_b BIGINT; pa_a BIGINT; pa_b BIGINT;
    pe1 BIGINT; pe2 BIGINT; pe3 BIGINT;
    g_sexto BIGINT; g_septimo BIGINT; g_jardin BIGINT; g_b BIGINT;
    gr_601 BIGINT; gr_701 BIGINT; gr_jar BIGINT; gr_b BIGINT;
    pl_sexto BIGINT; pl_septimo BIGINT;

    area_mat BIGINT; area_len BIGINT; area_dim BIGINT;
    ta_mat BIGINT; ta_len BIGINT; ta_dim BIGINT;
    asg_mat BIGINT; asg_len BIGINT; asg_cn BIGINT; asg_dim BIGINT;
    esc BIGINT; crit_eval BIGINT;
    uni_len BIGINT; uni_cn BIGINT;

    u_rector_a BIGINT; f_rector_a BIGINT;
    u_doc_a BIGINT;    f_doc_a BIGINT;
    u_rector_b BIGINT;

    mat_ids BIGINT[] := '{}';
    mat_pre BIGINT[] := '{}';

    v_hoy DATE := CURRENT_DATE;
    v_tmp BIGINT; v_plan BIGINT; v_act BIGINT; v_ae BIGINT;
    i INT; r RECORD;
BEGIN
    ---------------------------------------------------------------------
    -- 0. Catalogos
    ---------------------------------------------------------------------
    SELECT PK_LISTA_VALOR INTO c_jornada    FROM academico_test.TLISTA_VALOR WHERE CATEGORIA='JORNADA'                   AND VALOR='MANANA'   AND ACTIVE LIMIT 1;
    SELECT PK_LISTA_VALOR INTO c_estado     FROM academico_test.TLISTA_VALOR WHERE CATEGORIA='ESTADO'                    AND VALOR='ACTIVO'   AND ACTIVE LIMIT 1;
    -- TNIVEL_ENSENANZA es tabla propia, NO un catalogo de TLISTA_VALOR, y en
    -- un Postgres limpio solo trae Preescolar: el resto llega por el dump base.
    SELECT PK_NIVEL_ENSENANZA INTO c_niv_pre FROM academico_test.TNIVEL_ENSENANZA WHERE CODIGO='1' AND ACTIVE LIMIT 1;
    SELECT PK_NIVEL_ENSENANZA INTO c_niv_sec FROM academico_test.TNIVEL_ENSENANZA WHERE CODIGO='3' AND ACTIVE LIMIT 1;
    IF c_niv_sec IS NULL THEN
        INSERT INTO academico_test.TNIVEL_ENSENANZA (CODIGO, NOMBRE, CREATED_BY, CREATED_AT, ACTIVE)
        VALUES ('3','Basica Secundaria y Media','TSTINF',CURRENT_TIMESTAMP,TRUE)
        RETURNING PK_NIVEL_ENSENANZA INTO c_niv_sec;
    END IF;
    IF c_niv_pre IS NULL THEN
        INSERT INTO academico_test.TNIVEL_ENSENANZA (CODIGO, NOMBRE, CREATED_BY, CREATED_AT, ACTIVE)
        VALUES ('1','Preescolar','TSTINF',CURRENT_TIMESTAMP,TRUE)
        RETURNING PK_NIVEL_ENSENANZA INTO c_niv_pre;
    END IF;
    SELECT PK_LISTA_VALOR INTO c_td_ti      FROM academico_test.TLISTA_VALOR WHERE CATEGORIA='TIPO_DOCUMENTO'            AND VALOR='TI'       AND ACTIVE LIMIT 1;
    SELECT PK_LISTA_VALOR INTO c_td_cc      FROM academico_test.TLISTA_VALOR WHERE CATEGORIA='TIPO_DOCUMENTO'            AND VALOR='CC'       AND ACTIVE LIMIT 1;
    SELECT PK_LISTA_VALOR INTO c_genero     FROM academico_test.TLISTA_VALOR WHERE CATEGORIA='GENERO'                    AND VALOR='NA'       AND ACTIVE LIMIT 1;
    SELECT PK_LISTA_VALOR INTO c_est_mat    FROM academico_test.TLISTA_VALOR WHERE CATEGORIA='ESTADO_MATRICULA'          AND VALOR='CURSANDO' AND ACTIVE LIMIT 1;
    SELECT PK_LISTA_VALOR INTO c_tipo_act   FROM academico_test.TLISTA_VALOR WHERE CATEGORIA='TIPO_ACTIVIDAD'            AND VALOR='2'        AND ACTIVE LIMIT 1;
    SELECT PK_LISTA_VALOR INTO c_jerarquia  FROM academico_test.TLISTA_VALOR WHERE CATEGORIA='TIPO_JERARQUIA_ACTIVIDAD'  AND VALOR='1'        AND ACTIVE LIMIT 1;
    SELECT PK_LISTA_VALOR INTO c_instr_otro FROM academico_test.TLISTA_VALOR WHERE CATEGORIA='INSTRUMENTO_EVALUACION'    AND VALOR='OTRO'     AND ACTIVE LIMIT 1;
    SELECT PK_LISTA_VALOR INTO c_lv1        FROM academico_test.TLISTA_VALOR WHERE CATEGORIA='CALCULO_DEFINITIVA'        AND VALOR='1'        AND ACTIVE LIMIT 1;
    SELECT PK_LISTA_VALOR INTO c_lv2        FROM academico_test.TLISTA_VALOR WHERE CATEGORIA='CALCULO_DEFINITIVA'        AND VALOR='2'        AND ACTIVE LIMIT 1;
    SELECT PK_LISTA_VALOR INTO c_modelo     FROM academico_test.TLISTA_VALOR WHERE CATEGORIA='MODELO_PEDAGOGICO'         AND ACTIVE LIMIT 1;
    SELECT PK_PROPIEDAD_JURIDICA INTO c_propjur FROM academico_test.TPROPIEDAD_JURIDICA WHERE ACTIVE LIMIT 1;
    SELECT PK_TMUNICIPIO  INTO c_municipio  FROM academico_test.TMUNICIPIO LIMIT 1;
    SELECT PK_LISTA_VALOR INTO c_zona       FROM academico_test.TLISTA_VALOR WHERE CATEGORIA='ZONA'                      AND ACTIVE LIMIT 1;
    SELECT PK_LISTA_VALOR INTO c_tipo_val   FROM academico_test.TLISTA_VALOR WHERE CATEGORIA='TIPO_ESCALA'               AND VALOR='CUALITATIVA' AND ACTIVE LIMIT 1;

    -- FORMATO_CALIFICACION / CINCO: se siembra si el dump base no lo trajo.
    SELECT PK_LISTA_VALOR INTO c_fmt_cinco FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA='FORMATO_CALIFICACION' AND VALOR='CINCO' AND ACTIVE LIMIT 1;
    IF c_fmt_cinco IS NULL THEN
        -- La secuencia de TLISTA_VALOR va por detras de MAX(pk) en cuanto
        -- alguna migracion siembra con pk explicito (es lo mismo que arregla
        -- la rama fix/tlista-valor-secuencia-identidad, y vuelve a pasar cada
        -- vez que se agrega un seed nuevo). Sin este setval el INSERT de abajo
        -- muere con 23505 contra tlista_valor_pkey.
        PERFORM SETVAL(
            PG_GET_SERIAL_SEQUENCE('academico_test.tlista_valor','pk_lista_valor'),
            GREATEST((SELECT MAX(PK_LISTA_VALOR) FROM academico_test.TLISTA_VALOR), 1));

        INSERT INTO academico_test.TLISTA_VALOR (CATEGORIA, NOMBRE, VALOR, CREATED_BY, CREATED_AT, ACTIVE)
        VALUES ('FORMATO_CALIFICACION', 'De 0.0 a 5.0', 'CINCO', 'TSTINF', CURRENT_TIMESTAMP, TRUE)
        RETURNING PK_LISTA_VALOR INTO c_fmt_cinco;
        RAISE NOTICE 'fixture: FORMATO_CALIFICACION/CINCO no existia, sembrado (pk=%)', c_fmt_cinco;
    END IF;

    IF c_jornada IS NULL OR c_niv_sec IS NULL OR c_est_mat IS NULL
       OR c_instr_otro IS NULL OR c_lv1 IS NULL OR c_lv2 IS NULL THEN
        RAISE EXCEPTION 'Faltan catalogos base imprescindibles para el fixture';
    END IF;

    ---------------------------------------------------------------------
    -- 1. Establecimientos y sedes
    ---------------------------------------------------------------------
    INSERT INTO academico_test.TESTABLECIMIENTO
        (NOMBRE, NIT, CODIGO, FK_TMUNICIPIO, FK_TPROPIEDAD_JURIDICA,
         DIRECCION, CORREO_ELECTRONICO, TELEFONO, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF Colegio A', 'TSTINF-NIT-A', 'TSTINF-A', c_municipio, c_propjur,
            'Calle 1', 'a@tstinf.local', '3000000001', 'TSTINF', CURRENT_TIMESTAMP, TRUE)
    RETURNING PK_ESTABLECIMIENTO INTO ee_a;

    INSERT INTO academico_test.TESTABLECIMIENTO
        (NOMBRE, NIT, CODIGO, FK_TMUNICIPIO, FK_TPROPIEDAD_JURIDICA,
         DIRECCION, CORREO_ELECTRONICO, TELEFONO, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF Colegio B', 'TSTINF-NIT-B', 'TSTINF-B', c_municipio, c_propjur,
            'Calle 2', 'b@tstinf.local', '3000000002', 'TSTINF', CURRENT_TIMESTAMP, TRUE)
    RETURNING PK_ESTABLECIMIENTO INTO ee_b;

    INSERT INTO academico_test.TSEDE
        (CODIGO, NOMBRE, CONSECUTIVO, FK_TLV_ZONA, LOCALIDAD, COMUNA, BARRIO,
         DIRECCION, TELEFONO, FK_TESTABLECIMIENTO, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF-SA','TSTINF Sede A', 1, c_zona, 'NA','NA','NA',
            'Calle 1','3000000001', ee_a,'TSTINF',CURRENT_TIMESTAMP,TRUE)
    RETURNING PK_TSEDE INTO sede_a;
    INSERT INTO academico_test.TSEDE
        (CODIGO, NOMBRE, CONSECUTIVO, FK_TLV_ZONA, LOCALIDAD, COMUNA, BARRIO,
         DIRECCION, TELEFONO, FK_TESTABLECIMIENTO, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF-SB','TSTINF Sede B', 1, c_zona, 'NA','NA','NA',
            'Calle 2','3000000002', ee_b,'TSTINF',CURRENT_TIMESTAMP,TRUE)
    RETURNING PK_TSEDE INTO sede_b;

    ---------------------------------------------------------------------
    -- 2. Ano lectivo y periodo academico (uno por sede+jornada)
    ---------------------------------------------------------------------
    INSERT INTO academico_test.TANO_LECTIVO (NOMBRE, FK_TESTABLECIMIENTO, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES (EXTRACT(YEAR FROM v_hoy)::TEXT, ee_a, 'TSTINF', CURRENT_TIMESTAMP, TRUE) RETURNING PK_ANO_LECTIVO INTO ano_a;
    INSERT INTO academico_test.TANO_LECTIVO (NOMBRE, FK_TESTABLECIMIENTO, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES (EXTRACT(YEAR FROM v_hoy)::TEXT, ee_b, 'TSTINF', CURRENT_TIMESTAMP, TRUE) RETURNING PK_ANO_LECTIVO INTO ano_b;

    INSERT INTO academico_test.TPERIODO_ACADEMICO
        (FK_TANO_LECTIVO, FK_TLV_ESTADO, FK_TSEDE, FECHA_INICIO, FECHA_FIN,
         FECHA_LIMITE_MATRICULA, FK_TLV_JORNADA, RESERVA, BLOQUES_POR_DEFECTO,
         NOMBRE, HORA_INICIO, HORA_FIN, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES (ano_a, c_estado, sede_a, DATE_TRUNC('year', v_hoy)::DATE,
            (DATE_TRUNC('year', v_hoy) + INTERVAL '1 year - 1 day')::DATE,
            (DATE_TRUNC('year', v_hoy) + INTERVAL '2 month')::DATE,
            c_jornada, 'N', 6, 'TSTINF Periodo A', TIME '07:00', TIME '13:00',
            'TSTINF', CURRENT_TIMESTAMP, TRUE)
    RETURNING PK_TPERIODO_ACADEMICO INTO pa_a;

    INSERT INTO academico_test.TPERIODO_ACADEMICO
        (FK_TANO_LECTIVO, FK_TLV_ESTADO, FK_TSEDE, FECHA_INICIO, FECHA_FIN,
         FECHA_LIMITE_MATRICULA, FK_TLV_JORNADA, RESERVA, BLOQUES_POR_DEFECTO,
         NOMBRE, HORA_INICIO, HORA_FIN, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES (ano_b, c_estado, sede_b, DATE_TRUNC('year', v_hoy)::DATE,
            (DATE_TRUNC('year', v_hoy) + INTERVAL '1 year - 1 day')::DATE,
            (DATE_TRUNC('year', v_hoy) + INTERVAL '2 month')::DATE,
            c_jornada, 'N', 6, 'TSTINF Periodo B', TIME '07:00', TIME '13:00',
            'TSTINF', CURRENT_TIMESTAMP, TRUE)
    RETURNING PK_TPERIODO_ACADEMICO INTO pa_b;

    ---------------------------------------------------------------------
    -- 3. Periodos de evaluacion: cerrado / en curso / futuro
    ---------------------------------------------------------------------
    INSERT INTO academico_test.TPERIODO_EVALUACION
        (CODIGO, NOMBRE, ABREVIACION, FECHA_INICIO, FECHA_FIN, FK_TLV_ESTADO,
         FK_TPERIODO_ACADEMICO, PORCENTAJE, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF-P1','Primer periodo','P1',  v_hoy-120, v_hoy-60, c_estado, pa_a, 30, 'TSTINF', CURRENT_TIMESTAMP, TRUE) RETURNING PK_TPERIODO_EVALUACION INTO pe1;
    INSERT INTO academico_test.TPERIODO_EVALUACION
        (CODIGO, NOMBRE, ABREVIACION, FECHA_INICIO, FECHA_FIN, FK_TLV_ESTADO,
         FK_TPERIODO_ACADEMICO, PORCENTAJE, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF-P2','Segundo periodo','P2', v_hoy-30,  v_hoy+30, c_estado, pa_a, 30, 'TSTINF', CURRENT_TIMESTAMP, TRUE) RETURNING PK_TPERIODO_EVALUACION INTO pe2;
    INSERT INTO academico_test.TPERIODO_EVALUACION
        (CODIGO, NOMBRE, ABREVIACION, FECHA_INICIO, FECHA_FIN, FK_TLV_ESTADO,
         FK_TPERIODO_ACADEMICO, PORCENTAJE, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF-P3','Tercer periodo','P3',  v_hoy+31,  v_hoy+120, c_estado, pa_a, 40, 'TSTINF', CURRENT_TIMESTAMP, TRUE) RETURNING PK_TPERIODO_EVALUACION INTO pe3;

    ---------------------------------------------------------------------
    -- 4. Grados y grupos
    ---------------------------------------------------------------------
    INSERT INTO academico_test.TGRADO (CODIGO, NOMBRE, FK_TPERIODO_ACADEMICO, FK_TNIVEL_ENSENANZA, TIENE_GRADO_SIGUIENTE, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF-6','Sexto',   pa_a, c_niv_sec,'N','TSTINF',CURRENT_TIMESTAMP,TRUE) RETURNING PK_TGRADO INTO g_sexto;
    INSERT INTO academico_test.TGRADO (CODIGO, NOMBRE, FK_TPERIODO_ACADEMICO, FK_TNIVEL_ENSENANZA, TIENE_GRADO_SIGUIENTE, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF-7','Septimo', pa_a, c_niv_sec,'N','TSTINF',CURRENT_TIMESTAMP,TRUE) RETURNING PK_TGRADO INTO g_septimo;
    INSERT INTO academico_test.TGRADO (CODIGO, NOMBRE, FK_TPERIODO_ACADEMICO, FK_TNIVEL_ENSENANZA, TIENE_GRADO_SIGUIENTE, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF-J','Jardin',  pa_a, c_niv_pre,'N','TSTINF',CURRENT_TIMESTAMP,TRUE) RETURNING PK_TGRADO INTO g_jardin;
    INSERT INTO academico_test.TGRADO (CODIGO, NOMBRE, FK_TPERIODO_ACADEMICO, FK_TNIVEL_ENSENANZA, TIENE_GRADO_SIGUIENTE, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF-B6','Sexto B',pa_b, c_niv_sec,'N','TSTINF',CURRENT_TIMESTAMP,TRUE) RETURNING PK_TGRADO INTO g_b;

    INSERT INTO academico_test.TGRUPO (CODIGO, NOMBRE, FK_TGRADO, FK_TLV_JORNADA, FK_TLV_MODELO_PEDAGOGICO, CAPACIDAD, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF-601','601', g_sexto,   c_jornada, c_modelo, 40,'TSTINF',CURRENT_TIMESTAMP,TRUE) RETURNING PK_TGRUPO INTO gr_601;
    INSERT INTO academico_test.TGRUPO (CODIGO, NOMBRE, FK_TGRADO, FK_TLV_JORNADA, FK_TLV_MODELO_PEDAGOGICO, CAPACIDAD, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF-701','701', g_septimo, c_jornada, c_modelo, 40,'TSTINF',CURRENT_TIMESTAMP,TRUE) RETURNING PK_TGRUPO INTO gr_701;
    INSERT INTO academico_test.TGRUPO (CODIGO, NOMBRE, FK_TGRADO, FK_TLV_JORNADA, FK_TLV_MODELO_PEDAGOGICO, CAPACIDAD, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF-JA1','JA1', g_jardin,  c_jornada, c_modelo, 40,'TSTINF',CURRENT_TIMESTAMP,TRUE) RETURNING PK_TGRUPO INTO gr_jar;
    INSERT INTO academico_test.TGRUPO (CODIGO, NOMBRE, FK_TGRADO, FK_TLV_JORNADA, FK_TLV_MODELO_PEDAGOGICO, CAPACIDAD, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF-B61','B61',g_b,        c_jornada, c_modelo, 40,'TSTINF',CURRENT_TIMESTAMP,TRUE) RETURNING PK_TGRUPO INTO gr_b;

    ---------------------------------------------------------------------
    -- 5. Areas y asignaturas
    ---------------------------------------------------------------------
    -- TAREA_ASIGNATURA es el catalogo NACIONAL de areas (de ahi sale
    -- AREA_NOMBRE en el informe); TAREA es el area del periodo academico.
    INSERT INTO academico_test.TAREA_ASIGNATURA (NOMBRE, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF Matematicas','TSTINF',CURRENT_TIMESTAMP,TRUE) RETURNING PK_TAREA_ASIGNATURA INTO ta_mat;
    INSERT INTO academico_test.TAREA_ASIGNATURA (NOMBRE, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF Lenguaje','TSTINF',CURRENT_TIMESTAMP,TRUE) RETURNING PK_TAREA_ASIGNATURA INTO ta_len;
    INSERT INTO academico_test.TAREA_ASIGNATURA (NOMBRE, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF Dimensiones','TSTINF',CURRENT_TIMESTAMP,TRUE) RETURNING PK_TAREA_ASIGNATURA INTO ta_dim;

    INSERT INTO academico_test.TAREA (CODIGO, NOMBRE, ABREVIACION, FK_TPERIODO_ACADEMICO, FK_TAREA_ASIGNATURA, ORDEN_REPORTE, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF-AMAT','Matematicas','MAT', pa_a, ta_mat, 1,'TSTINF',CURRENT_TIMESTAMP,TRUE) RETURNING PK_TAREA INTO area_mat;
    INSERT INTO academico_test.TAREA (CODIGO, NOMBRE, ABREVIACION, FK_TPERIODO_ACADEMICO, FK_TAREA_ASIGNATURA, ORDEN_REPORTE, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF-ALEN','Lenguaje','LEN',    pa_a, ta_len, 2,'TSTINF',CURRENT_TIMESTAMP,TRUE) RETURNING PK_TAREA INTO area_len;
    INSERT INTO academico_test.TAREA (CODIGO, NOMBRE, ABREVIACION, FK_TPERIODO_ACADEMICO, FK_TAREA_ASIGNATURA, ORDEN_REPORTE, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF-ADIM','Dimensiones','DIM', pa_a, ta_dim, 3,'TSTINF',CURRENT_TIMESTAMP,TRUE) RETURNING PK_TAREA INTO area_dim;

    INSERT INTO academico_test.TASIGNATURA (CODIGO, NOMBRE, ABREVIACION, FK_TAREA, ORDEN_REPORTE, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF-MAT','Matematicas','MAT', area_mat, 1,'TSTINF',CURRENT_TIMESTAMP,TRUE) RETURNING PK_TASIGNATURA INTO asg_mat;
    INSERT INTO academico_test.TASIGNATURA (CODIGO, NOMBRE, ABREVIACION, FK_TAREA, ORDEN_REPORTE, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF-LEN','Lenguaje','LEN',    area_len, 2,'TSTINF',CURRENT_TIMESTAMP,TRUE) RETURNING PK_TASIGNATURA INTO asg_len;
    INSERT INTO academico_test.TASIGNATURA (CODIGO, NOMBRE, ABREVIACION, FK_TAREA, ORDEN_REPORTE, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF-CN','Ciencias','CN',      area_mat, 3,'TSTINF',CURRENT_TIMESTAMP,TRUE) RETURNING PK_TASIGNATURA INTO asg_cn;
    INSERT INTO academico_test.TASIGNATURA (CODIGO, NOMBRE, ABREVIACION, FK_TAREA, ORDEN_REPORTE, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF-DIM','Dimension comunicativa','DIM', area_dim, 1,'TSTINF',CURRENT_TIMESTAMP,TRUE) RETURNING PK_TASIGNATURA INTO asg_dim;

    ---------------------------------------------------------------------
    -- 6. Escala + criterio de evaluacion (formato CINCO, 2 decimales)
    ---------------------------------------------------------------------
    INSERT INTO academico_test.TESCALA (CODIGO, NOMBRE, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF-ESC','TSTINF Escala','TSTINF',CURRENT_TIMESTAMP,TRUE) RETURNING PK_TESCALA INTO esc;

    -- Tres bandas, para que VALORACION_NOMBRE no venga siempre NULL.
    FOR r IN
        SELECT * FROM (VALUES
            ('TSTINF-BAJO','Bajo','D', 1, 0::NUMERIC, 59.99::NUMERIC),
            ('TSTINF-BAS','Basico','C', 2, 60::NUMERIC, 79.99::NUMERIC),
            ('TSTINF-ALT','Alto','A',   3, 80::NUMERIC, 100::NUMERIC)
        ) v(cod, nom, sim, ord, li, ls)
    LOOP
        INSERT INTO academico_test.TVALORACION (CODIGO, NOMBRE, GRAFICA_SIMBOLO, FK_TVL_TIPO_VALORACION, CREATED_BY, CREATED_AT, ACTIVE)
        VALUES (r.cod, r.nom, r.sim, c_tipo_val, 'TSTINF', CURRENT_TIMESTAMP, TRUE)
        RETURNING PK_TVALORACION INTO v_tmp;

        INSERT INTO academico_test.TESCALA_VALORACION
            (FK_TESCALA, FK_TVALORACION, FK_TVL_TIPO_VALORACION, ORDEN,
             LIMITE_INFERIOR, LIMITE_SUPERIOR, CREATED_BY, CREATED_AT, ACTIVE)
        VALUES (esc, v_tmp, c_tipo_val, r.ord, r.li, r.ls, 'TSTINF', CURRENT_TIMESTAMP, TRUE);
    END LOOP;

    -- OJO: TCRITERIO_EVALUACION es 1:1 con TPERIODO_ACADEMICO y lo hace por
    -- la PK, no por una FK aparte -- PK_TCRITERIO_EVALUACION *es*
    -- PK_TPERIODO_ACADEMICO. Dejarlo a la identity falla con 23503.
    INSERT INTO academico_test.TCRITERIO_EVALUACION
        (PK_TCRITERIO_EVALUACION, FK_TLV_FORMATO_CALIFICACION, FK_TESCALA,
         NUMERO_DECIMALES, PORCENTAJE_INICIAL_CALIF, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES (pa_a, c_fmt_cinco, esc, 2, 0, 'TSTINF', CURRENT_TIMESTAMP, TRUE)
    RETURNING PK_TCRITERIO_EVALUACION INTO crit_eval;

    ---------------------------------------------------------------------
    -- 7. Plan de estudios. SEXTO y SEPTIMO llevan las tres numericas;
    --    JARDIN NO lleva plan -- es lo que lo hace cualitativo.
    --
    --    Los tres motores de calculo:
    --      MAT  elemento '2' (ACTIVIDADES) + modo '2' (PONDERAR)
    --      LEN  elemento '1' (UNIDADES)    + modo '1' (PROMEDIAR)
    --      CN   sin configurar             -> fallback promedio simple
    ---------------------------------------------------------------------
    INSERT INTO academico_test.TPLAN (CODIGO, NOMBRE, FK_TGRADO, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF-PL6','Plan Sexto',  g_sexto,  'TSTINF',CURRENT_TIMESTAMP,TRUE) RETURNING PK_TPLAN INTO pl_sexto;
    INSERT INTO academico_test.TPLAN (CODIGO, NOMBRE, FK_TGRADO, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF-PL7','Plan Septimo',g_septimo,'TSTINF',CURRENT_TIMESTAMP,TRUE) RETURNING PK_TPLAN INTO pl_septimo;

    FOR r IN
        SELECT * FROM (VALUES (1, 'sexto'), (2, 'septimo')) v(n, etiqueta)
    LOOP
        v_plan := CASE WHEN r.n = 1 THEN pl_sexto ELSE pl_septimo END;

        INSERT INTO academico_test.TASIGNATURA_PLAN
            (FK_TPLAN, FK_TASIGNATURA, NUMERO_HORA, INFLUENCIA_AREA,
             MATRICULA_OBLIGATORIA, APROBACION_OBLIGATORIA, INFLUYE_DESEMPLENO_ACADEMICO,
             FK_TLV_ELEMENTO_CALCULO_DEF, FK_TLV_CALCULO_DEFINITIVA,
             CREATED_BY, CREATED_AT, ACTIVE)
        VALUES (v_plan, asg_mat, 4, 100, 'S', 'S', 'S', c_lv2, c_lv2, 'TSTINF', CURRENT_TIMESTAMP, TRUE),
               (v_plan, asg_len, 4, 100, 'S', 'S', 'S', c_lv1, c_lv1, 'TSTINF', CURRENT_TIMESTAMP, TRUE),
               (v_plan, asg_cn,  4, 100, 'S', 'S', 'S', NULL,  NULL,  'TSTINF', CURRENT_TIMESTAMP, TRUE);
    END LOOP;

    -- Enlace plan -> criterio de evaluacion (fila por defecto institucional)
    INSERT INTO academico_test.TCRITERIO_EVALUACION_ASIGNATURA_PLAN
        (FK_TCRITERIO_EVALUACION, FK_TASIGNATURA_PLAN, POR_DEFECTO, CREATED_BY, CREATED_AT, ACTIVE)
    SELECT crit_eval, ap.PK_TASIGNATURA_PLAN, 'S', 'TSTINF', CURRENT_TIMESTAMP, TRUE
      FROM academico_test.TASIGNATURA_PLAN ap
     WHERE ap.FK_TPLAN IN (pl_sexto, pl_septimo) AND ap.ACTIVE;

    ---------------------------------------------------------------------
    -- 8. Criterios de promocion
    --    SEXTO   -> DESEMPENHO_MINIMO 60   (aprobada decidible)
    --    SEPTIMO -> DESEMPENHO_MINIMO NULL (aprobada DESCONOCIDA)
    --    Ninguna fila POR_DEFECTO='S', para que el fallback no tape el caso.
    ---------------------------------------------------------------------
    INSERT INTO academico_test.TCRITERIO_PROMOCION
        (FK_TPERIODO_ACADEMICO, NODO_CURRICULAR, CANTIDAD_NIVELAR,
         ASIGNATURA_OBLIGATORIA, APROBACION_PROMEDIO, DESEMPENHO_MINIMO_GENERAL,
         DESEMPENHO_MINIMO, MAX_ASIG_PROMEDIO, FK_TGRADO, MINIMO_INASISTENCIAS,
         MAX_ASIG_NIVELAR_PROMOVIDO, POR_DEFECTO, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES (pa_a, 'AS', 2, 'N', 'S', 70, 60, 2, g_sexto,   20, 3,    'N','TSTINF',CURRENT_TIMESTAMP,TRUE),
           (pa_a, 'AS', 2, 'N', 'N', NULL, NULL, NULL, g_septimo, NULL, NULL,'N','TSTINF',CURRENT_TIMESTAMP,TRUE);

    ---------------------------------------------------------------------
    -- 9. Personas y alcance
    ---------------------------------------------------------------------
    INSERT INTO academico_test.TUSUARIO (CUENTA, CONTRASENA, ESTADO, IDENTIFICACION, FK_TLV_TIPO_DOCUMENTO, PRIMER_NOMBRE, PRIMER_APELLIDO, CORREO_ELECTRONICO, FK_TLV_GENERO, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('rector.a@tstinf.local','x','A','TSTINF-R-A',c_td_cc,'Rectora','Alfa','rector.a@tstinf.local',c_genero,'TSTINF',CURRENT_TIMESTAMP,TRUE) RETURNING PK_TUSUARIO INTO u_rector_a;
    INSERT INTO academico_test.TUSUARIO (CUENTA, CONTRASENA, ESTADO, IDENTIFICACION, FK_TLV_TIPO_DOCUMENTO, PRIMER_NOMBRE, PRIMER_APELLIDO, CORREO_ELECTRONICO, FK_TLV_GENERO, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('docente.a@tstinf.local','x','A','TSTINF-D-A',c_td_cc,'Docente','Alfa','docente.a@tstinf.local',c_genero,'TSTINF',CURRENT_TIMESTAMP,TRUE) RETURNING PK_TUSUARIO INTO u_doc_a;
    INSERT INTO academico_test.TUSUARIO (CUENTA, CONTRASENA, ESTADO, IDENTIFICACION, FK_TLV_TIPO_DOCUMENTO, PRIMER_NOMBRE, PRIMER_APELLIDO, CORREO_ELECTRONICO, FK_TLV_GENERO, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('rector.b@tstinf.local','x','A','TSTINF-R-B',c_td_cc,'Rector','Beta','rector.b@tstinf.local',c_genero,'TSTINF',CURRENT_TIMESTAMP,TRUE) RETURNING PK_TUSUARIO INTO u_rector_b;

    INSERT INTO academico_test.TFUNCIONARIO (FK_TUSUARIO, FK_ESTABLECIMIENTO, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES (u_rector_a, ee_a, 'TSTINF', CURRENT_TIMESTAMP, TRUE) RETURNING PK_TFUNCIONARIO INTO f_rector_a;
    INSERT INTO academico_test.TFUNCIONARIO (FK_TUSUARIO, FK_ESTABLECIMIENTO, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES (u_doc_a, ee_a, 'TSTINF', CURRENT_TIMESTAMP, TRUE) RETURNING PK_TFUNCIONARIO INTO f_doc_a;

    -- Alcance: rector = nivel 2 (EE completo); docente = nivel 3 (sede+jornada);
    -- rector B = nivel 2 pero de OTRO establecimiento -> debe recibir 42501.
    INSERT INTO academico_test.TSEDE_USUARIO (FK_TSEDE, FK_TROL, FK_TUSUARIO, ORDEN, FK_TLV_JORNADA, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES (sede_a, 7,  u_rector_a, 1, c_jornada,'TSTINF',CURRENT_TIMESTAMP,TRUE),
           (sede_a, 14, u_doc_a,    1, c_jornada,'TSTINF',CURRENT_TIMESTAMP,TRUE),
           (sede_b, 7,  u_rector_b, 1, c_jornada,'TSTINF',CURRENT_TIMESTAMP,TRUE);

    -- El docente asignado a las tres asignaturas de 601: es lo que alimenta
    -- las dos alertas, que parten de TDOCENTE_ASIGNATURA y no de la asignatura.
    INSERT INTO academico_test.TDOCENTE_ASIGNATURA (FK_TGRUPO, FK_TFUNCIONARIO, FK_TASIGNATURA, FK_TPERIODO_ACADEMICO, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES (gr_601, f_doc_a, asg_mat, pa_a,'TSTINF',CURRENT_TIMESTAMP,TRUE),
           (gr_601, f_doc_a, asg_len, pa_a,'TSTINF',CURRENT_TIMESTAMP,TRUE),
           (gr_601, f_doc_a, asg_cn,  pa_a,'TSTINF',CURRENT_TIMESTAMP,TRUE);

    ---------------------------------------------------------------------
    -- 10. Estudiantes y matriculas
    ---------------------------------------------------------------------
    FOR i IN 1..4 LOOP
        INSERT INTO academico_test.TUSUARIO (CUENTA, CONTRASENA, ESTADO, IDENTIFICACION, FK_TLV_TIPO_DOCUMENTO, PRIMER_NOMBRE, PRIMER_APELLIDO, FK_TLV_GENERO, CREATED_BY, CREATED_AT, ACTIVE)
        VALUES ('TSTINF-E'||i, 'x', 'A', 'TSTINF-E'||i, c_td_ti, 'Estudiante', 'Sexto'||i, c_genero, 'TSTINF', CURRENT_TIMESTAMP, TRUE)
        RETURNING PK_TUSUARIO INTO v_tmp;

        INSERT INTO academico_test.TESTUDIANTE (FK_TUSUARIO, FECHA_INGRESO, CREATED_BY, CREATED_AT, ACTIVE)
        VALUES (v_tmp, v_hoy, 'TSTINF', CURRENT_TIMESTAMP, TRUE) RETURNING PK_TESTUDIANTE INTO v_tmp;

        INSERT INTO academico_test.TMATRICULA (FK_TESTUDIANTE, FK_TGRUPO, FK_TLV_ESTADO_MATRICULA, ESTUDIANTE_NUEVO, CREATED_BY, CREATED_AT, ACTIVE)
        VALUES (v_tmp, gr_601, c_est_mat, 'N', 'TSTINF', CURRENT_TIMESTAMP, TRUE) RETURNING PK_TMATRICULA INTO v_tmp;
        mat_ids := mat_ids || v_tmp;
    END LOOP;

    FOR i IN 1..2 LOOP
        INSERT INTO academico_test.TUSUARIO (CUENTA, CONTRASENA, ESTADO, IDENTIFICACION, FK_TLV_TIPO_DOCUMENTO, PRIMER_NOMBRE, PRIMER_APELLIDO, FK_TLV_GENERO, CREATED_BY, CREATED_AT, ACTIVE)
        VALUES ('TSTINF-J'||i, 'x', 'A', 'TSTINF-J'||i, c_td_ti, 'Estudiante', 'Jardin'||i, c_genero, 'TSTINF', CURRENT_TIMESTAMP, TRUE)
        RETURNING PK_TUSUARIO INTO v_tmp;

        INSERT INTO academico_test.TESTUDIANTE (FK_TUSUARIO, FECHA_INGRESO, CREATED_BY, CREATED_AT, ACTIVE)
        VALUES (v_tmp, v_hoy, 'TSTINF', CURRENT_TIMESTAMP, TRUE) RETURNING PK_TESTUDIANTE INTO v_tmp;

        INSERT INTO academico_test.TMATRICULA (FK_TESTUDIANTE, FK_TGRUPO, FK_TLV_ESTADO_MATRICULA, ESTUDIANTE_NUEVO, CREATED_BY, CREATED_AT, ACTIVE)
        VALUES (v_tmp, gr_jar, c_est_mat, 'N', 'TSTINF', CURRENT_TIMESTAMP, TRUE) RETURNING PK_TMATRICULA INTO v_tmp;
        mat_pre := mat_pre || v_tmp;
    END LOOP;

    ---------------------------------------------------------------------
    -- 11. Unidades (solo LEN y CN las necesitan: MAT calcula plano)
    ---------------------------------------------------------------------
    INSERT INTO academico_test.TUNIDAD (NOMBRE, FK_TASIGNATURA, FK_TGRADO, FK_TFUNCIONARIO, FK_TLV_CALCULO_DEFINITIVA, PONDERACION, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF Unidad LEN', asg_len, g_sexto, f_doc_a, c_lv1, 100, 'TSTINF', CURRENT_TIMESTAMP, TRUE) RETURNING PK_TUNIDAD INTO uni_len;
    INSERT INTO academico_test.TUNIDAD (NOMBRE, FK_TASIGNATURA, FK_TGRADO, FK_TFUNCIONARIO, FK_TLV_CALCULO_DEFINITIVA, PONDERACION, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES ('TSTINF Unidad CN',  asg_cn,  g_sexto, f_doc_a, c_lv1, 100, 'TSTINF', CURRENT_TIMESTAMP, TRUE) RETURNING PK_TUNIDAD INTO uni_cn;

    ---------------------------------------------------------------------
    -- 12. Registro de ids (antes de las actividades: 02_notas.sql lo lee)
    ---------------------------------------------------------------------
    INSERT INTO public.informes_test_fixture (clave, valor) VALUES
        ('ee_a',ee_a),('ee_b',ee_b),('sede_a',sede_a),('sede_b',sede_b),
        ('pa_a',pa_a),('pa_b',pa_b),('pe1',pe1),('pe2',pe2),('pe3',pe3),
        ('g_sexto',g_sexto),('g_septimo',g_septimo),('g_jardin',g_jardin),
        ('gr_601',gr_601),('gr_701',gr_701),('gr_jar',gr_jar),('gr_b',gr_b),
        ('asg_mat',asg_mat),('asg_len',asg_len),('asg_cn',asg_cn),('asg_dim',asg_dim),
        ('uni_len',uni_len),('uni_cn',uni_cn),
        ('crit_eval',crit_eval),('escala',esc),('jornada',c_jornada),
        ('u_rector_a',u_rector_a),('u_doc_a',u_doc_a),('u_rector_b',u_rector_b),
        ('f_doc_a',f_doc_a),('anio',EXTRACT(YEAR FROM v_hoy)::BIGINT),
        ('tipo_act',c_tipo_act),('jerarquia',c_jerarquia),('instr_otro',c_instr_otro),
        ('mat_e1',mat_ids[1]),('mat_e2',mat_ids[2]),('mat_e3',mat_ids[3]),('mat_e4',mat_ids[4]),
        ('mat_j1',mat_pre[1]),('mat_j2',mat_pre[2]);

    RAISE NOTICE 'fixture: ee_a=% sede_a=% pa_a=% grupo601=% matriculas=%',
        ee_a, sede_a, pa_a, gr_601, CARDINALITY(mat_ids);
END
$fixture$;
