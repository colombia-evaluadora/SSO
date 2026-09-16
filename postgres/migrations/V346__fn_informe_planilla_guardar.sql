-- ===========================================================================
-- V346 - Guardar la planilla de UNA asignatura, y el recalculo de metricas
--        que eso obliga a centralizar.
--
--   fn_informe_metricas_recalcular   recalcula TINFORME_PERIODO_MATRICULA
--   fn_informe_periodo_guardar       (REESCRITA) ahora delega en el helper
--   fn_informe_planilla_guardar      congela UNA asignatura
--
--
-- EL PROBLEMA QUE OBLIGA A ESTO
--   TASIGNATURA_NOTA es por (matricula, periodo, ASIGNATURA), asi que guardar
--   una sola asignatura no pisa a las demas: ahi no hay conflicto.
--
--   Pero TINFORME_PERIODO_MATRICULA (V336) es por (matricula, periodo) y
--   AGREGA TODAS las asignaturas: promedio, aprobadas, reprobadas. Si se
--   guarda una sola y nadie recalcula esa fila, queda describiendo un estado
--   que ya no existe. Medido en el servidor:
--
--     notas guardadas   MAT.FINANCIERA=70.00, MATEMATICAS=20.00
--     promedio real     45.00
--     fila de metricas  77.71   <- vieja
--     listado muestra   77.71   <- y por tanto miente
--
--   Es el peor tipo de error: silencioso y consistente consigo mismo.
--
--
-- UN SEGUNDO DEFECTO, HEREDADO DE V336
--   Aquella acumulaba las metricas DENTRO del bucle, leyendo d.aprobada del
--   detalle. Pero el detalle calcula la aprobacion sobre la nota VISIBLE
--   -- COALESCE(guardada, proyectada) --, o sea sobre la nota VIEJA, mientras
--   que lo que se escribe es la proyectada. Con una guardada previa distinta,
--   la fila de metricas describia un numero distinto del que quedaba en
--   TASIGNATURA_NOTA. Reproducido: re-guardar sin cambiar ninguna nota movia
--   aprobadas de 2 a 1.
--
--   Por eso el helper calcula DESPUES de escribir y SOLO desde lo guardado.
--   Es la definicion correcta: las metricas describen lo consolidado, no lo
--   que se estaba por consolidar.
--
--
-- (1) EL HELPER
--   Recalcula y persiste la fila de (matricula, periodo) leyendo
--   TASIGNATURA_NOTA. El universo de asignaturas sale de
--   fn_informe_estudiante_asignaturas -- el mismo que ve el usuario --, de
--   modo que una asignatura sin nota guardada cuenta en SIN_DEFINIR en vez de
--   desaparecer del total.
--
--   Si no queda NINGUNA nota guardada, la fila se da de BAJA en vez de
--   quedarse en cero: cero promedio y cero aprobadas se leerian como "este
--   estudiante saco cero", y lo que pasa es que el periodo no esta
--   consolidado. Con la fila inactiva, el listado vuelve a calcular al vuelo y
--   CONSOLIDADO vuelve a FALSE, que es la verdad.
--
--
-- (2) POR QUE EL GUARDADO PARCIAL NO ESTORBA AL COMPLETO
--   No hay estado que se bloquee. Guardar MATEMATICAS y despues el informe
--   entero es valido y da el mismo resultado que guardar el informe entero
--   directamente: la asignatura ya guardada se reporta 'sin_cambio' -- no se
--   toca, para no borrar su MODIFIED_AT -- y las demas se congelan. El helper
--   corre igual al final y deja las metricas coherentes con lo que haya.
--
--   Y al reves: guardar el informe completo y despues una asignatura suelta
--   solo reescribe esa y recalcula. Las dos operaciones son idempotentes y
--   conmutativas en su efecto final.
--
--
-- (3) COMO SE ENTERA EL FRONT
--   Por tres campos que ya existen, sin nada nuevo:
--
--     CONSOLIDADO         (fn_informe_grupo_listar) TRUE si hay fila de
--                         metricas, es decir si algo se congelo en ese
--                         periodo para ese estudiante.
--     ESTADO_NOTA         por asignatura: 'proyectada' (nunca se guardo),
--                         'guardada' (congelada y al dia) o
--                         'cambio_propuesto' (congelada y el docente la
--                         movio despues).
--     PROMEDIO_GUARDADO   vs PROMEDIO_PROYECTADO: si difieren, hay algo sin
--                         consolidar.
--
--   Un guardado parcial se ve exactamente asi: la asignatura guardada queda
--   'guardada' y el resto sigue 'proyectada'. El front no necesita recordar
--   que se guardo ni desde donde.
--
-- Idempotente: CREATE OR REPLACE, con DROP de fn_informe_periodo_guardar
-- porque su RETURNS TABLE no cambia pero si su cuerpo -- el DROP se deja por
-- simetria con el resto del modulo y para que una firma vieja no sobreviva.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. Recalculo de metricas. Punto UNICO: lo llaman los dos guardados.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_metricas_recalcular(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tmatricula          BIGINT,
    p_fk_tperiodo_evaluacion BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_grado BIGINT;
    v_minimo   NUMERIC;
    v_total    BIGINT  := 0;
    v_conNota  BIGINT  := 0;
    v_suma     NUMERIC := 0;
    v_aprob    BIGINT  := 0;
    v_reprob   BIGINT  := 0;
    v_sindef   BIGINT  := 0;
    r          RECORD;
BEGIN
    SELECT gd.PK_TGRADO
      INTO v_fk_grado
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
     WHERE m.PK_TMATRICULA = p_fk_tmatricula;

    v_minimo := academico_test.fn_grado_desempeno_minimo(v_fk_grado);

    -- El universo sale del detalle -- el mismo que ve el usuario -- pero se
    -- lee NOTA_GUARDADA y no la proyectada: las metricas describen lo
    -- consolidado, no lo que se estaba por consolidar.
    FOR r IN
        SELECT d.nota_guardada
          FROM academico_test.fn_informe_estudiante_asignaturas(
                   p_pk_usuario_solicitante, p_fk_tmatricula,
                   ARRAY[p_fk_tperiodo_evaluacion]::BIGINT[]) d
    LOOP
        v_total := v_total + 1;

        IF r.nota_guardada IS NULL THEN
            v_sindef := v_sindef + 1;
        ELSE
            v_conNota := v_conNota + 1;
            v_suma    := v_suma + r.nota_guardada;

            IF v_minimo IS NULL THEN
                -- Sin umbral configurado la aprobacion es DESCONOCIDA, no
                -- falsa: 425 de las 742 filas activas de TCRITERIO_PROMOCION
                -- no lo tienen, y contar eso como reprobado seria reprobar
                -- gente por una configuracion que el colegio nunca hizo.
                v_sindef := v_sindef + 1;
            ELSIF r.nota_guardada >= v_minimo THEN
                v_aprob := v_aprob + 1;
            ELSE
                v_reprob := v_reprob + 1;
            END IF;
        END IF;
    END LOOP;

    IF v_conNota = 0 THEN
        -- Nada consolidado: la fila se da de BAJA, no se deja en cero. Un
        -- promedio 0 se leeria como "saco cero"; lo que pasa es que el
        -- periodo no esta consolidado. Con la fila inactiva el listado vuelve
        -- a calcular al vuelo y CONSOLIDADO vuelve a FALSE, que es la verdad.
        UPDATE academico_test.TINFORME_PERIODO_MATRICULA
           SET ACTIVE      = FALSE,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TMATRICULA          = p_fk_tmatricula
           AND FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
           AND ACTIVE = TRUE;
        RETURN;
    END IF;

    INSERT INTO academico_test.TINFORME_PERIODO_MATRICULA (
        FK_TMATRICULA, FK_TPERIODO_EVALUACION,
        PROMEDIO, ASIGNATURAS, APROBADAS, REPROBADAS, SIN_DEFINIR,
        CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        p_fk_tmatricula, p_fk_tperiodo_evaluacion,
        ROUND(v_suma / v_conNota, 2), v_total, v_aprob, v_reprob, v_sindef,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    ON CONFLICT (FK_TMATRICULA, FK_TPERIODO_EVALUACION)
    DO UPDATE SET PROMEDIO    = EXCLUDED.PROMEDIO,
                  ASIGNATURAS = EXCLUDED.ASIGNATURAS,
                  APROBADAS   = EXCLUDED.APROBADAS,
                  REPROBADAS  = EXCLUDED.REPROBADAS,
                  SIN_DEFINIR = EXCLUDED.SIN_DEFINIR,
                  ACTIVE      = TRUE,
                  MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
                  MODIFIED_AT = CURRENT_TIMESTAMP;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_metricas_recalcular(BIGINT, BIGINT, BIGINT)
    IS 'Recalcula y persiste la fila de TINFORME_PERIODO_MATRICULA de un (estudiante, periodo) a partir de lo que HAY GUARDADO en TASIGNATURA_NOTA. Es el punto UNICO de ese calculo y lo llaman los dos guardados -- el del informe completo y el de una sola asignatura desde la planilla -- porque esa fila agrega TODAS las asignaturas: guardar una sola y no recalcularla la deja describiendo un estado que ya no existe, en silencio y de forma consistente consigo misma (medido: notas 70 y 20, promedio real 45, fila diciendo 77.71). Calcula DESPUES de escribir y solo desde lo guardado, no desde lo que se iba a guardar: la version anterior acumulaba dentro del bucle leyendo la aprobacion del detalle, que la decide sobre la nota VISIBLE -- COALESCE(guardada, proyectada), es decir la VIEJA -- mientras escribia la proyectada, de modo que las metricas podian describir un numero distinto del que quedaba en la tabla (reproducido: re-guardar sin cambiar nada movia aprobadas de 2 a 1). El universo de asignaturas sale de fn_informe_estudiante_asignaturas, el mismo que ve el usuario, asi que una asignatura sin nota guardada cuenta en SIN_DEFINIR en vez de desaparecer del total; y una nota guardada cuyo grado no tiene DESEMPENHO_MINIMO tambien va a SIN_DEFINIR, nunca a reprobadas. Si no queda NINGUNA nota guardada la fila se da de BAJA en vez de quedar en cero: un promedio 0 se leeria como "saco cero" cuando lo que pasa es que el periodo no esta consolidado, y con la fila inactiva el listado vuelve a calcular al vuelo y CONSOLIDADO vuelve a FALSE.';


-- ---------------------------------------------------------------------------
-- 2. El guardado del informe completo, ahora delegando el recalculo.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_informe_periodo_guardar(BIGINT, BIGINT, BIGINT, BIGINT[]);

CREATE OR REPLACE FUNCTION academico_test.fn_informe_periodo_guardar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tperiodo_evaluacion BIGINT,
    p_fk_tmatriculas         BIGINT[] DEFAULT NULL
)
RETURNS TABLE(
    fk_tmatricula   BIGINT,
    estudiante      VARCHAR,
    guardadas       BIGINT,
    actualizadas    BIGINT,
    sin_proyeccion  BIGINT,
    sin_cambio      BIGINT,
    promedio        NUMERIC,
    aprobadas       BIGINT,
    reprobadas      BIGINT,
    detalle         JSONB
)
LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
DECLARE
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
    v_fk_peraca  BIGINT;
    v_pe_peraca  BIGINT;
    r_mat        RECORD;
    r_asig       RECORD;
    v_prev       NUMERIC;
    v_existe     BOOLEAN;
    v_g          BIGINT;
    v_a          BIGINT;
    v_s          BIGINT;
    v_n          BIGINT;
    v_det        JSONB;
    v_m          RECORD;
BEGIN
    SELECT s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO,
           gd.FK_TPERIODO_ACADEMICO
      INTO v_fk_sede, v_fk_jornada, v_fk_ee, v_fk_peraca
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE gr.PK_TGRUPO = p_fk_tgrupo
       AND gr.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el grupo solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    SELECT pe.FK_TPERIODO_ACADEMICO
      INTO v_pe_peraca
      FROM academico_test.TPERIODO_EVALUACION pe
     WHERE pe.PK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
       AND pe.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el periodo de evaluacion solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    IF v_pe_peraca IS DISTINCT FROM v_fk_peraca THEN
        RAISE EXCEPTION 'El periodo de evaluacion no pertenece al periodo academico del grupo'
            USING ERRCODE = '22023';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'EDITAR',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

    FOR r_mat IN
        SELECT m.PK_TMATRICULA AS pk,
               NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.PRIMER_APELLIDO)), '')::VARCHAR AS nombre
          FROM academico_test.TMATRICULA m
          LEFT JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          LEFT JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO     = es.FK_TUSUARIO
         WHERE m.FK_TGRUPO = p_fk_tgrupo
           AND m.ACTIVE = TRUE
           AND (p_fk_tmatriculas IS NULL
                OR CARDINALITY(p_fk_tmatriculas) = 0
                OR m.PK_TMATRICULA = ANY (p_fk_tmatriculas))
         ORDER BY 2, 1
    LOOP
        v_g := 0; v_a := 0; v_s := 0; v_n := 0; v_det := '[]'::JSONB;

        FOR r_asig IN
            SELECT d.fk_tasignatura, d.asignatura_nombre, d.nota_proyectada
              FROM academico_test.fn_informe_estudiante_asignaturas(
                       p_pk_usuario_solicitante, r_mat.pk,
                       ARRAY[p_fk_tperiodo_evaluacion]::BIGINT[]) d
        LOOP
            IF r_asig.nota_proyectada IS NULL THEN
                v_s := v_s + 1;
                v_det := v_det || JSONB_BUILD_OBJECT(
                    'asignatura', r_asig.asignatura_nombre,
                    'resultado',  'sin_proyeccion');
                CONTINUE;
            END IF;

            SELECT sn.DEFINITIVA, TRUE
              INTO v_prev, v_existe
              FROM academico_test.TASIGNATURA_NOTA sn
             WHERE sn.FK_TMATRICULA          = r_mat.pk
               AND sn.FK_TASIGNATURA         = r_asig.fk_tasignatura
               AND sn.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
               AND sn.ACTIVE = TRUE;

            IF COALESCE(v_existe, FALSE) AND v_prev = r_asig.nota_proyectada THEN
                v_n := v_n + 1;
                v_det := v_det || JSONB_BUILD_OBJECT(
                    'asignatura', r_asig.asignatura_nombre,
                    'resultado',  'sin_cambio',
                    'nota',       r_asig.nota_proyectada);
                v_existe := NULL;
                CONTINUE;
            END IF;

            INSERT INTO academico_test.TASIGNATURA_NOTA (
                FK_TMATRICULA, FK_TASIGNATURA, FK_TPERIODO_EVALUACION,
                CALIFICACION, DEFINITIVA, CREATED_BY, CREATED_AT, ACTIVE
            ) VALUES (
                r_mat.pk, r_asig.fk_tasignatura, p_fk_tperiodo_evaluacion,
                r_asig.nota_proyectada, r_asig.nota_proyectada,
                p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
            )
            ON CONFLICT (FK_TMATRICULA, FK_TPERIODO_EVALUACION, FK_TASIGNATURA)
                WHERE ACTIVE
            DO UPDATE SET CALIFICACION = EXCLUDED.CALIFICACION,
                          DEFINITIVA   = EXCLUDED.DEFINITIVA,
                          MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
                          MODIFIED_AT  = CURRENT_TIMESTAMP;

            IF COALESCE(v_existe, FALSE) THEN
                v_a := v_a + 1;
                v_det := v_det || JSONB_BUILD_OBJECT(
                    'asignatura', r_asig.asignatura_nombre,
                    'resultado',  'actualizada',
                    'nota',       r_asig.nota_proyectada,
                    'anterior',   v_prev);
            ELSE
                v_g := v_g + 1;
                v_det := v_det || JSONB_BUILD_OBJECT(
                    'asignatura', r_asig.asignatura_nombre,
                    'resultado',  'guardada',
                    'nota',       r_asig.nota_proyectada);
            END IF;

            v_existe := NULL;
        END LOOP;

        -- Metricas DESPUES de escribir y desde lo guardado. Ver la cabecera.
        PERFORM academico_test.fn_informe_metricas_recalcular(
            p_pk_usuario_solicitante, r_mat.pk, p_fk_tperiodo_evaluacion);

        SELECT ipm.PROMEDIO, ipm.APROBADAS, ipm.REPROBADAS
          INTO v_m
          FROM academico_test.TINFORME_PERIODO_MATRICULA ipm
         WHERE ipm.FK_TMATRICULA          = r_mat.pk
           AND ipm.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
           AND ipm.ACTIVE = TRUE;

        fk_tmatricula  := r_mat.pk;
        estudiante     := r_mat.nombre;
        guardadas      := v_g;
        actualizadas   := v_a;
        sin_proyeccion := v_s;
        sin_cambio     := v_n;
        promedio       := v_m.PROMEDIO;
        aprobadas      := COALESCE(v_m.APROBADAS, 0)::BIGINT;
        reprobadas     := COALESCE(v_m.REPROBADAS, 0)::BIGINT;
        detalle        := v_det;
        RETURN NEXT;
    END LOOP;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_periodo_guardar(BIGINT, BIGINT, BIGINT, BIGINT[])
    IS 'Consolida un periodo COMPLETO: congela la nota proyectada de cada asignatura en TASIGNATURA_NOTA para el grupo (o solo las matriculas indicadas; NULL o vacio = todas) y deja las metricas al dia. Es el paso de gris a negro de la vista de informes. Las metricas ya NO se acumulan dentro del bucle: se delegan en fn_informe_metricas_recalcular, que corre despues de escribir y lee lo GUARDADO. Aquel calculo inline tenia un defecto -- leia la aprobacion del detalle, que la decide sobre la nota visible COALESCE(guardada, proyectada), es decir la vieja, mientras escribia la proyectada --, de modo que re-guardar sin cambiar ninguna nota podia mover aprobadas de 2 a 1. Convive sin problemas con fn_informe_planilla_guardar, que congela una sola asignatura: TASIGNATURA_NOTA es por (matricula, periodo, asignatura) y no se pisan, y ambas terminan llamando al mismo recalculo, asi que las dos operaciones son idempotentes y su efecto final no depende del orden. Lo ya guardado con el mismo valor se reporta sin_cambio y no se toca, para no borrar el MODIFIED_AT que dice cuando se consolido. DEFINITIVA se guarda en PORCENTAJE, no homologada, porque la escala depende de TCRITERIO_EVALUACION por (asignatura, grado) y puede cambiar. Preescolar no usa este endpoint: alli todo sale sin_proyeccion porque las observaciones se guardan con CALIFICABLE=N y no promedian. Devuelve un informe por estudiante con el detalle en JSONB, y el promedio y los conteos ya recalculados. Gate: INFORMES/EDITAR.';


-- ---------------------------------------------------------------------------
-- 3. El guardado de la planilla: UNA asignatura.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_planilla_guardar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fk_tperiodo_evaluacion BIGINT,
    p_fk_tmatriculas         BIGINT[] DEFAULT NULL
)
RETURNS TABLE(
    fk_tmatricula      BIGINT,
    estudiante         VARCHAR,
    resultado          VARCHAR,
    nota_anterior      NUMERIC,
    nota_guardada      NUMERIC,
    promedio_periodo   NUMERIC,
    aprobadas          BIGINT,
    reprobadas         BIGINT
)
LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
DECLARE
    v_fk_grado   BIGINT;
    v_fk_peraca  BIGINT;
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
    v_pe_peraca  BIGINT;
    r_mat        RECORD;
    v_proy       NUMERIC;
    v_prev       NUMERIC;
    v_existe     BOOLEAN;
    v_res        VARCHAR;
    v_m          RECORD;
BEGIN
    SELECT gd.PK_TGRADO, gd.FK_TPERIODO_ACADEMICO,
           s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO
      INTO v_fk_grado, v_fk_peraca, v_fk_sede, v_fk_jornada, v_fk_ee
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE gr.PK_TGRUPO = p_fk_tgrupo
       AND gr.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el grupo solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    -- Mismo validador puro que usa la planilla al listar (V239), para que el
    -- filtro invalido de el mismo error al leer y al guardar.
    PERFORM academico_test.fn_planilla_grupo_asignatura_assert(
        p_fk_tgrupo, p_fk_tasignatura, v_fk_grado);

    SELECT pe.FK_TPERIODO_ACADEMICO
      INTO v_pe_peraca
      FROM academico_test.TPERIODO_EVALUACION pe
     WHERE pe.PK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
       AND pe.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el periodo de evaluacion solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    IF v_pe_peraca IS DISTINCT FROM v_fk_peraca THEN
        RAISE EXCEPTION 'El periodo de evaluacion no pertenece al periodo academico del grupo'
            USING ERRCODE = '22023';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'EDITAR',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

    FOR r_mat IN
        SELECT m.PK_TMATRICULA AS pk,
               NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.PRIMER_APELLIDO)), '')::VARCHAR AS nombre
          FROM academico_test.TMATRICULA m
          LEFT JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          LEFT JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO     = es.FK_TUSUARIO
         WHERE m.FK_TGRUPO = p_fk_tgrupo
           AND m.ACTIVE = TRUE
           AND (p_fk_tmatriculas IS NULL
                OR CARDINALITY(p_fk_tmatriculas) = 0
                OR m.PK_TMATRICULA = ANY (p_fk_tmatriculas))
         ORDER BY 2, 1
    LOOP
        v_proy := academico_test.fn_asignatura_definitiva_proyectada_periodo(
                      r_mat.pk, p_fk_tasignatura, p_fk_tperiodo_evaluacion);

        SELECT sn.DEFINITIVA, TRUE
          INTO v_prev, v_existe
          FROM academico_test.TASIGNATURA_NOTA sn
         WHERE sn.FK_TMATRICULA          = r_mat.pk
           AND sn.FK_TASIGNATURA         = p_fk_tasignatura
           AND sn.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
           AND sn.ACTIVE = TRUE;

        IF v_proy IS NULL THEN
            -- No hay con que congelar. Lo ya guardado NO se borra: quitarlo
            -- seria destruir un consolidado por una ausencia, y esa decision
            -- no es de un boton de guardar.
            v_res := 'sin_proyeccion';

        ELSIF COALESCE(v_existe, FALSE) AND v_prev = v_proy THEN
            v_res := 'sin_cambio';

        ELSE
            INSERT INTO academico_test.TASIGNATURA_NOTA (
                FK_TMATRICULA, FK_TASIGNATURA, FK_TPERIODO_EVALUACION,
                CALIFICACION, DEFINITIVA, CREATED_BY, CREATED_AT, ACTIVE
            ) VALUES (
                r_mat.pk, p_fk_tasignatura, p_fk_tperiodo_evaluacion,
                v_proy, v_proy,
                p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
            )
            ON CONFLICT (FK_TMATRICULA, FK_TPERIODO_EVALUACION, FK_TASIGNATURA)
                WHERE ACTIVE
            DO UPDATE SET CALIFICACION = EXCLUDED.CALIFICACION,
                          DEFINITIVA   = EXCLUDED.DEFINITIVA,
                          MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
                          MODIFIED_AT  = CURRENT_TIMESTAMP;

            v_res := CASE WHEN COALESCE(v_existe, FALSE) THEN 'actualizada'
                          ELSE 'guardada' END;
        END IF;

        -- SIEMPRE se recalcula, incluso en sin_cambio: otra asignatura pudo
        -- haberse movido desde el ultimo recalculo, y esta fila de metricas
        -- las agrega a todas.
        PERFORM academico_test.fn_informe_metricas_recalcular(
            p_pk_usuario_solicitante, r_mat.pk, p_fk_tperiodo_evaluacion);

        SELECT ipm.PROMEDIO, ipm.APROBADAS, ipm.REPROBADAS
          INTO v_m
          FROM academico_test.TINFORME_PERIODO_MATRICULA ipm
         WHERE ipm.FK_TMATRICULA          = r_mat.pk
           AND ipm.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
           AND ipm.ACTIVE = TRUE;

        fk_tmatricula    := r_mat.pk;
        estudiante       := r_mat.nombre;
        resultado        := v_res;
        nota_anterior    := v_prev;
        nota_guardada    := CASE WHEN v_res IN ('guardada', 'actualizada', 'sin_cambio')
                                 THEN v_proy END;
        promedio_periodo := v_m.PROMEDIO;
        aprobadas        := COALESCE(v_m.APROBADAS, 0)::BIGINT;
        reprobadas       := COALESCE(v_m.REPROBADAS, 0)::BIGINT;
        RETURN NEXT;

        v_prev := NULL; v_existe := NULL;
    END LOOP;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_planilla_guardar(BIGINT, BIGINT, BIGINT, BIGINT, BIGINT[])
    IS 'Congela la definitiva de UNA asignatura desde la planilla de informes, para el grupo o solo las matriculas indicadas (NULL o vacio = todas). Es el hermano acotado de fn_informe_periodo_guardar, que congela todas las asignaturas del estudiante. NO SE PISAN: TASIGNATURA_NOTA es por (matricula, periodo, asignatura), asi que guardar una no toca las demas, y las dos terminan llamando a fn_informe_metricas_recalcular, de modo que la fila agregada de TINFORME_PERIODO_MATRICULA queda coherente sin importar en que orden se hayan usado; ambas son idempotentes. El recalculo corre SIEMPRE, incluso cuando el resultado es sin_cambio, porque otra asignatura pudo haberse movido desde el ultimo y esa fila las agrega a todas. Resultados por estudiante: guardada (primera vez), actualizada (habia otra, se devuelve nota_anterior), sin_cambio (ya estaba con el mismo valor, no se toca para no borrar su MODIFIED_AT) o sin_proyeccion (no hay actividad evaluativa calificada en el periodo). En sin_proyeccion lo ya guardado NO se borra: quitar un consolidado por una ausencia no es decision de un boton de guardar. Devuelve ademas el promedio y los conteos del periodo ya recalculados, para que la pantalla pueda refrescar sin volver a consultar. La nota se guarda en PORCENTAJE, no homologada, por la misma razon que en el guardado completo. Gate: INFORMES/EDITAR sobre el grupo, mas el validador puro fn_planilla_grupo_asignatura_assert (V239) para que el filtro invalido de el mismo error al leer y al guardar.';
