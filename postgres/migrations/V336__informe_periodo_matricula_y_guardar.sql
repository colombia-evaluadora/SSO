-- ===========================================================================
-- V336 - TINFORME_PERIODO_MATRICULA y fn_informe_periodo_guardar: congelar el
--        periodo -- las notas y las metricas del estudiante.
--
-- LA TABLA VA AQUI Y NO EN SU PROPIA MIGRACION A PROPOSITO
--   Existe UNICAMENTE porque esta funcion la escribe. Separarlas obligaria a
--   leer dos archivos para entender una sola decision, y dejaria una ventana
--   en la que la funcion referencia una tabla que todavia no existe.
--
--
-- (1) QUE GUARDA LA TABLA, Y QUE NO
--   Grano (matricula, periodo de evaluacion): el promedio del estudiante en
--   ese periodo y sus conteos de aprobadas / reprobadas / sin definir. Es lo
--   que el listado muestra en las columnas PR, AP y RE.
--
--   La razon de guardarlo es no recalcularlo en cada consulta: el promedio
--   sale de recorrer todas las asignaturas del estudiante, y eso por cada
--   estudiante del grupo en cada apertura de la pantalla.
--
--   *** EL PUESTO NO SE GUARDA, Y ES DELIBERADO ***
--   Es la excepcion. El puesto no es un dato del estudiante sino de su
--   posicion RELATIVA en el grupo: subir la nota de uno cambia el puesto de
--   otro que nadie toco. Guardarlo obligaria a reescribir la fila de TODO el
--   grupo en cada guardado -- incluidos estudiantes que el usuario no
--   selecciono -- para que no quedara viejo al instante, y a ese costo ya no
--   se gana nada frente a calcularlo al listar, que es un RANK() sobre un
--   conjunto que de todas formas hay que traer entero.
--
--   Asi que el puesto se recalcula siempre en fn_informe_grupo_listar. El
--   resto se lee de aqui cuando existe.
--
--
-- (2) ESTA ES LA PRIMERA ESCRITURA EN LA CAPA DE CONSOLIDACION
--   TASIGNATURA_NOTA existe desde V22 y tiene CERO filas. Se reviso funcion
--   por funcion (474 en el esquema): ninguna la inserta ni la actualiza, solo
--   la leen para contar dependencias o borrarla en cascada. Lo mismo vale
--   para TUNIDAD_NOTA, TAREA_NOTA, TASIGNATURA_DEFINITIVA y TAREA_DEFINITIVA.
--
--   Por eso esta funcion fija la convencion que las demas deberan seguir.
--
--
-- (3) LA CONVENCION: SE GUARDA EL PORCENTAJE
--   DEFINITIVA se escribe en PORCENTAJE (0..100), igual que lo devuelve la
--   proyeccion y que lo espera fn_nota_homologar como entrada.
--
--   Es la unica opcion coherente: la nota en la escala del colegio (0-5, 0-10,
--   una valoracion literal) depende de TCRITERIO_EVALUACION, que se resuelve
--   por (asignatura, grado) y el colegio puede cambiar. Si se guardara ya
--   homologada, cambiar el criterio dejaria el historico en una escala y lo
--   nuevo en otra, sin forma de saber cual es cual. Guardando el porcentaje,
--   homologar sigue siendo una decision de presentacion, reversible.
--
--   CALIFICACION se escribe con el mismo valor que DEFINITIVA y RECUPERACION
--   queda NULL: hoy no hay flujo de recuperaciones que las distinga, y poner
--   algo distinto seria inventar una diferencia que el sistema no sabe hacer.
--
--
-- (4) PREESCOLAR NO PASA POR AQUI
--   Alli no hay nota que congelar -- las observaciones se guardan con
--   CALIFICABLE='N' y no promedian -- asi que todas las asignaturas salen
--   'sin_proyeccion' y no se escribe metrica. Lo que se guarda en preescolar
--   es el resumen de la IA, con fn_estudiante_periodo_observacion_guardar
--   (V332), que es otro endpoint.
--
--   Los dos guardados son operaciones distintas sobre datos distintos; quien
--   llame decide cual segun el formato que devolvio el listado.
--
--
-- (5) UPSERT SOBRE EL INDICE UNICO PARCIAL
--   TASIGNATURA_NOTA tiene u_tasignatura_nota_1 UNIQUE sobre
--   (FK_TMATRICULA, FK_TPERIODO_EVALUACION, FK_TASIGNATURA) WHERE ACTIVE, asi
--   que se usa ON CONFLICT con esa misma condicion. Volver a guardar
--   ACTUALIZA en vez de duplicar o fallar, que es lo que la pantalla necesita
--   cuando el usuario acepta un cambio propuesto.
--
--
-- (6) QUE SE OMITE, Y POR QUE SE INFORMA
--   'sin_proyeccion'  la asignatura no tiene actividad evaluativa calificada
--                     en el periodo. No hay nada que congelar, y escribir un
--                     0 seria inventar una nota.
--   'sin_cambio'      ya estaba guardada con el mismo valor. No se toca la
--                     fila, para no ensuciar MODIFIED_AT, que es lo unico que
--                     dice cuando se consolido de verdad.
--
--   Se devuelve un informe por estudiante y no un contador: guardar 30 y
--   responder "27" no le dice a nadie cuales fueron los otros 3.
--
-- Idempotente: CREATE TABLE IF NOT EXISTS + CREATE OR REPLACE. La operacion
-- tambien lo es: correrla dos veces deja todo igual y la segunda reporta
-- 'sin_cambio' en todo.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. Las metricas consolidadas del estudiante en el periodo.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS academico_test.TINFORME_PERIODO_MATRICULA (
    PK_TINFORME_PERIODO_MATRICULA BIGINT GENERATED BY DEFAULT AS IDENTITY,

    FK_TMATRICULA           BIGINT NOT NULL,
    FK_TPERIODO_EVALUACION  BIGINT NOT NULL,

    PROMEDIO                NUMERIC,
    ASIGNATURAS             NUMERIC,
    APROBADAS               NUMERIC,
    REPROBADAS              NUMERIC,
    SIN_DEFINIR             NUMERIC,

    CREATED_BY              VARCHAR(50) NOT NULL,
    CREATED_AT              TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    MODIFIED_BY             VARCHAR(50),
    MODIFIED_AT             TIMESTAMP,
    ACTIVE                  BOOLEAN     NOT NULL DEFAULT TRUE,

    CONSTRAINT PK_TINFORME_PERIODO_MATRICULA
        PRIMARY KEY (PK_TINFORME_PERIODO_MATRICULA),
    CONSTRAINT FK_TINFORME_PERIODO_MATRICULA_1
        FOREIGN KEY (FK_TMATRICULA)
        REFERENCES academico_test.TMATRICULA (PK_TMATRICULA),
    CONSTRAINT FK_TINFORME_PERIODO_MATRICULA_2
        FOREIGN KEY (FK_TPERIODO_EVALUACION)
        REFERENCES academico_test.TPERIODO_EVALUACION (PK_TPERIODO_EVALUACION)
);

CREATE INDEX IF NOT EXISTS IDX_TINFORME_PERIODO_MATRICULA_1
    ON academico_test.TINFORME_PERIODO_MATRICULA (FK_TMATRICULA);
CREATE INDEX IF NOT EXISTS IDX_TINFORME_PERIODO_MATRICULA_2
    ON academico_test.TINFORME_PERIODO_MATRICULA (FK_TPERIODO_EVALUACION);

CREATE UNIQUE INDEX IF NOT EXISTS U_TINFORME_PERIODO_MATRICULA_1
    ON academico_test.TINFORME_PERIODO_MATRICULA
       (FK_TMATRICULA, FK_TPERIODO_EVALUACION);

COMMENT ON TABLE academico_test.TINFORME_PERIODO_MATRICULA
    IS 'Metricas consolidadas de un estudiante en un periodo de evaluacion: promedio y conteos de asignaturas aprobadas / reprobadas / sin definir. Son las columnas PR, AP y RE del listado de informes, y se guardan para no recalcularlas en cada apertura de la pantalla -- el promedio obliga a recorrer todas las asignaturas de cada estudiante del grupo. Las escribe fn_informe_periodo_guardar junto con las notas; mientras no exista la fila, fn_informe_grupo_listar calcula los mismos valores al vuelo, de modo que la pantalla funciona igual antes y despues de consolidar. EL PUESTO NO ESTA AQUI Y ES DELIBERADO: no es un dato del estudiante sino de su posicion RELATIVA en el grupo -- subir la nota de uno cambia el puesto de otro que nadie toco --, asi que guardarlo obligaria a reescribir la fila de todo el grupo en cada guardado, incluidos estudiantes que el usuario no selecciono, y a ese costo ya no se gana nada frente a calcularlo al listar con un RANK() sobre un conjunto que de todas formas hay que traer entero. El promedio se guarda en PORCENTAJE, igual que TASIGNATURA_NOTA.DEFINITIVA, porque la escala del colegio depende de TCRITERIO_EVALUACION y puede cambiar.';

COMMENT ON COLUMN academico_test.TINFORME_PERIODO_MATRICULA.PROMEDIO
    IS 'Promedio del estudiante en el periodo, en PORCENTAJE (0..100). Media simple de la definitiva de cada asignatura; no se promedian notas homologadas porque mezclar escalas distintas en una media no significa nada';
COMMENT ON COLUMN academico_test.TINFORME_PERIODO_MATRICULA.APROBADAS
    IS 'Asignaturas con definitiva mayor o igual al DESEMPENHO_MINIMO del grado';
COMMENT ON COLUMN academico_test.TINFORME_PERIODO_MATRICULA.REPROBADAS
    IS 'Asignaturas con definitiva por debajo del DESEMPENHO_MINIMO del grado';
COMMENT ON COLUMN academico_test.TINFORME_PERIODO_MATRICULA.SIN_DEFINIR
    IS 'Asignaturas donde la aprobacion no se puede decidir: sin nota, o sin DESEMPENHO_MINIMO configurado en el grado. No se cuentan como reprobadas -- no se puede decir';


-- ---------------------------------------------------------------------------
-- 2. Congelar el periodo.
--
--    El RETURNS TABLE gana tres columnas (promedio, aprobadas, reprobadas)
--    para que quien guarda vea de una vez las metricas que quedaron, sin
--    tener que volver a listar. CREATE OR REPLACE no puede cambiar el tipo de
--    retorno, asi que hace falta el DROP.
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
-- Los parametros de salida (fk_tmatricula, promedio, aprobadas...) tienen el
-- mismo nombre que columnas reales de las tablas que se escriben, y el ON
-- CONFLICT las nombra. Con la regla por defecto de plpgsql eso es ambiguo y
-- falla. Aqui la columna siempre gana: los parametros de salida solo se
-- ASIGNAN, al final de cada vuelta, y una asignacion nunca es ambigua. El
-- resto de variables lleva prefijo v_ / r_, asi que no hay nada mas que pueda
-- chocar.
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
    v_suma       NUMERIC;
    v_cuenta     BIGINT;
    v_aprob      BIGINT;
    v_reprob     BIGINT;
    v_sindef     BIGINT;
    v_prom       NUMERIC;
BEGIN
    -- 2.1 Grupo, alcance y coherencia del periodo.
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

    -- 2.2 Estudiante por estudiante.
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
        v_suma := 0; v_cuenta := 0; v_aprob := 0; v_reprob := 0; v_sindef := 0;

        -- Las asignaturas se toman del detalle (V334), el mismo origen que ve
        -- el usuario en pantalla: no se puede guardar algo distinto de lo que
        -- se le mostro.
        FOR r_asig IN
            SELECT d.fk_tasignatura, d.asignatura_nombre,
                   d.nota_proyectada, d.aprobada
              FROM academico_test.fn_informe_estudiante_asignaturas(
                       p_pk_usuario_solicitante, r_mat.pk,
                       ARRAY[p_fk_tperiodo_evaluacion]::BIGINT[]) d
        LOOP
            IF r_asig.nota_proyectada IS NULL THEN
                -- Nada que congelar. Es el caso normal de preescolar.
                v_s      := v_s + 1;
                v_sindef := v_sindef + 1;
                v_det := v_det || JSONB_BUILD_OBJECT(
                    'asignatura', r_asig.asignatura_nombre,
                    'resultado',  'sin_proyeccion');
                CONTINUE;
            END IF;

            -- Las metricas se acumulan sobre lo que se esta CONGELANDO, no
            -- sobre lo que habia: al terminar, la fila de metricas describe
            -- exactamente las notas que quedaron guardadas.
            v_suma   := v_suma + r_asig.nota_proyectada;
            v_cuenta := v_cuenta + 1;
            IF    r_asig.aprobada IS TRUE  THEN v_aprob  := v_aprob + 1;
            ELSIF r_asig.aprobada IS FALSE THEN v_reprob := v_reprob + 1;
            ELSE                                v_sindef := v_sindef + 1;
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
                CALIFICACION, DEFINITIVA,
                CREATED_BY, CREATED_AT, ACTIVE
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

        -- 2.3 Las metricas del periodo. Solo si se congelo ALGO: una fila de
        --     metricas sin ninguna nota detras no describe nada, y ademas
        --     haria que el listado creyera que el periodo ya se consolido.
        --     Por eso preescolar no genera fila.
        IF v_cuenta > 0 THEN
            v_prom := ROUND(v_suma / v_cuenta, 2);

            -- ASIGNATURAS cuenta TODAS las filas consideradas, no solo las
            -- que se congelaron. El promedio si se calcula unicamente sobre
            -- las que tienen nota -- promediar un hueco como cero seria
            -- inventarla --, pero el conteo tiene que cuadrar con
            -- aprobadas + reprobadas + sin_definir, y sobre todo tiene que
            -- valer lo mismo antes y despues de guardar: el listado muestra
            -- esta columna calculada mientras no hay fila, y si aqui se
            -- guardara solo v_cuenta el numero cambiaria solo, al consolidar.
            INSERT INTO academico_test.TINFORME_PERIODO_MATRICULA (
                FK_TMATRICULA, FK_TPERIODO_EVALUACION,
                PROMEDIO, ASIGNATURAS, APROBADAS, REPROBADAS, SIN_DEFINIR,
                CREATED_BY, CREATED_AT, ACTIVE
            ) VALUES (
                r_mat.pk, p_fk_tperiodo_evaluacion,
                v_prom, v_aprob + v_reprob + v_sindef, v_aprob, v_reprob, v_sindef,
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
        ELSE
            v_prom := NULL;
        END IF;

        fk_tmatricula  := r_mat.pk;
        estudiante     := r_mat.nombre;
        guardadas      := v_g;
        actualizadas   := v_a;
        sin_proyeccion := v_s;
        sin_cambio     := v_n;
        promedio       := v_prom;
        aprobadas      := v_aprob;
        reprobadas     := v_reprob;
        detalle        := v_det;
        RETURN NEXT;
    END LOOP;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_periodo_guardar(BIGINT, BIGINT, BIGINT, BIGINT[])
    IS 'Congela el periodo: escribe la nota proyectada de cada asignatura en TASIGNATURA_NOTA y las metricas del estudiante (promedio, aprobadas, reprobadas, sin definir) en TINFORME_PERIODO_MATRICULA. Es el boton "guardar" del informe, el paso de gris a negro, para el grupo o solo las matriculas indicadas (NULL o vacio = todas). ES LA PRIMERA FUNCION DEL ESQUEMA QUE ESCRIBE EN LA CAPA DE CONSOLIDACION: TASIGNATURA_NOTA existe desde V22 con cero filas y ninguna de las 474 funciones la insertaba ni actualizaba -- solo la leian para contar dependencias o borrarla en cascada; lo mismo vale para TUNIDAD_NOTA, TAREA_NOTA, TASIGNATURA_DEFINITIVA y TAREA_DEFINITIVA. Por eso fija la convencion: DEFINITIVA y PROMEDIO se guardan en PORCENTAJE (0..100), no homologados, porque la escala del colegio depende de TCRITERIO_EVALUACION por (asignatura, grado) y puede cambiar; guardar ya homologado dejaria el historico en una escala y lo nuevo en otra sin forma de distinguirlos. CALIFICACION se escribe igual a DEFINITIVA y RECUPERACION queda NULL porque hoy no hay flujo que las distinga. Las metricas se acumulan sobre lo que se esta congelando, no sobre lo que habia, de modo que la fila describe exactamente las notas que quedaron; y solo se escribe si se congelo alguna nota, porque una fila de metricas sin notas detras no describe nada y ademas haria creer al listado que el periodo ya se consolido. EL PUESTO NO SE GUARDA -- ver el comentario de TINFORME_PERIODO_MATRICULA: es posicion relativa, y mantenerlo coherente obligaria a reescribir todo el grupo en cada guardado. PREESCOLAR NO PASA POR AQUI: alli las observaciones se guardan con CALIFICABLE=N y no promedian, asi que todo sale sin_proyeccion y no se escribe metrica; lo que se consolida alli es el resumen de la IA con fn_estudiante_periodo_observacion_guardar (V332), que es otro endpoint, y quien llame elige segun el formato que devolvio el listado. El upsert de notas usa ON CONFLICT sobre el indice unico parcial u_tasignatura_nota_1, asi que volver a guardar actualiza -- que es lo que hace falta al aceptar un cambio propuesto. Se omite con sin_proyeccion cuando no hay actividad evaluativa calificada (escribir 0 seria inventar una nota) y con sin_cambio cuando ya estaba guardada con el mismo valor, sin tocar la fila para no borrar el MODIFIED_AT que dice cuando se consolido. Devuelve un informe por estudiante y no un contador: guardar 30 y responder 27 no dice cuales fueron los otros 3. Las asignaturas se toman de fn_informe_estudiante_asignaturas, el mismo origen que ve el usuario: no se puede guardar algo distinto de lo que se le mostro. Gate: INFORMES/EDITAR.';
