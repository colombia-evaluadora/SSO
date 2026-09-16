-- V408 -- fn_actividad_recuperacion_aplicar
-- Que hace: al calificar una actividad con ES_RECUPERACION='S', lee su fila de
--   TACTIVIDAD_RECUPERACION (V22) y escribe RECUPERACION + DEFINITIVA en su
--   destino: la TACTIVIDAD_NOTA de la actividad recuperada, o la
--   TASIGNATURA_NOTA del periodo cuando el destino es NOTA_FINAL.
-- Por que aqui: V22 modelo las cuatro combinaciones COMPUTAR/REEMPLAZAR x
--   PROMEDIADO/PONDERADO y nadie las leia; V239 ya lee
--   COALESCE(DEFINITIVA, CALIFICACION) esperando este escritor.
-- Depende de: V22, V220 (periodo por fecha), V227 (piso/tope, grado), V239
--   (criterio vigente, accesores, definitiva proyectada).


-- 1. Accesores de configuracion (mismo estilo que los de V239).
CREATE OR REPLACE FUNCTION academico_test.fn_criterio_evaluacion_desempeno_sin_calificar(
    p_pk_criterio BIGINT
)
RETURNS VARCHAR
LANGUAGE sql
STABLE
AS $$
    SELECT CASE
               WHEN UPPER(COALESCE(lv.NOMBRE, '') || ' ' || COALESCE(lv.VALOR, '')) LIKE '%MENOR%'  THEN 'MENOR'
               WHEN UPPER(COALESCE(lv.NOMBRE, '') || ' ' || COALESCE(lv.VALOR, '')) LIKE '%NINGUN%' THEN 'NINGUNA'
               ELSE NULL
           END
      FROM academico_test.TCRITERIO_EVALUACION ce
      JOIN academico_test.TLISTA_VALOR lv
        ON lv.PK_LISTA_VALOR = ce.FK_TLV_DESEMPENO_SIN_CALIF
     WHERE ce.PK_TCRITERIO_EVALUACION = p_pk_criterio;
$$;

COMMENT ON FUNCTION academico_test.fn_criterio_evaluacion_desempeno_sin_calificar(BIGINT)
    IS 'Politica institucional para "que nota asume el sistema si un docente deja una actividad o asignatura sin calificar": TCRITERIO_EVALUACION.FK_TLV_DESEMPENO_SIN_CALIF, campo UI "Sin calificaciones" (V41), categoria DESEMPENIOSUGERIR. Normaliza los dos valores reales confirmados contra el servidor de test -- "Menor calificacion posible" y "Ninguna Calificacion" -- a los codigos MENOR y NINGUNA. Se clasifica por SUBCADENA sobre NOMBRE||VALOR y no por PK ni por igualdad exacta, por las dos razones de siempre en este repo: los PK de TLISTA_VALOR no son estables entre el servidor de test y un Postgres limpio, y comparar por texto exacto se rompe con las tildes (V396) -- MENOR y NINGUN son los prefijos sin tilde que distinguen ambos casos sin ambiguedad. NULL si no hay criterio, no hay valor configurado o el texto no calza con ninguno de los dos: NULL significa "el colegio no lo definio", no es error, y quien lo consuma debe abstenerse en vez de suponer. Lo consume fn_actividad_recuperacion_aplicar para decidir la parte restante de una recuperacion que COMPUTA sobre un estudiante que nunca tuvo nota en la actividad original. V408.';


CREATE OR REPLACE FUNCTION academico_test.fn_criterio_evaluacion_nota_final_editable(
    p_pk_criterio BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT UPPER(COALESCE(lv.VALOR, lv.NOMBRE, '')) NOT IN ('N', 'NO')
      FROM academico_test.TCRITERIO_EVALUACION ce
      JOIN academico_test.TLISTA_VALOR lv
        ON lv.PK_LISTA_VALOR = ce.FK_TLV_MODIF_FINAL_PERACA
     WHERE ce.PK_TCRITERIO_EVALUACION = p_pk_criterio;
$$;

COMMENT ON FUNCTION academico_test.fn_criterio_evaluacion_nota_final_editable(BIGINT)
    IS 'Si el colegio permite modificar la nota final del periodo academico: TCRITERIO_EVALUACION.FK_TLV_MODIF_FINAL_PERACA, el SI/NO que V62 expone como final_grade_editable. Devuelve FALSE solo cuando el valor resuelve inequivocamente a NO (N o NO en VALOR, o en NOMBRE si VALOR es NULL) y TRUE en cualquier otro caso, incluido un texto que no se reconozca: bloquear por un valor que no se entiende dejaria al docente sin poder consolidar una recuperacion por un dato de catalogo mal cargado, y ante la duda hay que permitir y que se vea, no prohibir en silencio. NULL si no hay criterio o la columna esta vacia -- el llamador lo trata como permitido, misma razon. Lo consume fn_actividad_recuperacion_aplicar SOLO para el destino NOTA_FINAL, que es exactamente la nota que esta columna gobierna; el destino ACTIVIDAD no la mira, porque ahi no se toca ninguna nota final. V408.';


-- ---------------------------------------------------------------------------
-- 2. Ubicacion temporal de la actividad.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_periodo_evaluacion(
    p_pk_tactividad BIGINT,
    p_fk_tmatricula BIGINT
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT academico_test.fn_asistencia_periodo_eval(
               m.FK_TGRUPO,
               COALESCE(a.FECHA_CIERRE, a.FECHA_INICIO, a.FECHA_CREACION))
      FROM academico_test.TACTIVIDAD a
      JOIN academico_test.TMATRICULA m ON m.PK_TMATRICULA = p_fk_tmatricula
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_periodo_evaluacion(BIGINT, BIGINT)
    IS 'PK_TPERIODO_EVALUACION al que aporta una actividad para un estudiante concreto. TACTIVIDAD no tiene FK al periodo de evaluacion (y V218 quito la que TUNIDAD tenia), asi que la unica via es la fecha: COALESCE(FECHA_CIERRE, FECHA_INICIO, FECHA_CREACION) resuelta contra los cortes del periodo academico del grado del grupo de la MATRICULA, delegando en fn_asistencia_periodo_eval (V220) para no duplicar esa resolucion. FECHA_CIERRE va primero porque el periodo al que una actividad aporta es aquel en que termina de evaluarse. Es deliberadamente la MISMA convencion de fecha que fn_actividad_en_periodo_eval del modulo de Informes: si las dos divergen, una recuperacion consolidada caeria en un periodo y el informe la leeria en otro. Se toma el grupo de la MATRICULA y no TACTIVIDAD.FK_TGRUPO porque una actividad planeada desde la unidad no tiene grupo propio (V218) y porque es el estudiante quien define de que grupo es su nota. NULL si la fecha no cae en ningun corte activo -- no es error: significa que esa actividad no tiene periodo al que aportar, y el llamador se abstiene. V408.';


-- ---------------------------------------------------------------------------
-- 3. Nota base del periodo para el destino NOTA_FINAL.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_recuperacion_definitiva_periodo(
    p_fk_tmatricula          BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fk_tperiodo_evaluacion BIGINT
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_nota NUMERIC;
BEGIN
    -- El modulo de Informes trae la version acotada al periodo. Mientras no
    -- este, la de V239 es la mejor aproximacion disponible.
    IF to_regprocedure('academico_test.fn_asignatura_definitiva_proyectada_periodo(bigint,bigint,bigint)') IS NOT NULL THEN
        EXECUTE 'SELECT academico_test.fn_asignatura_definitiva_proyectada_periodo($1,$2,$3)'
           INTO v_nota
          USING p_fk_tmatricula, p_fk_tasignatura, p_fk_tperiodo_evaluacion;
    ELSE
        v_nota := academico_test.fn_planilla_definitiva_proyectada(p_fk_tmatricula, p_fk_tasignatura);
    END IF;

    RETURN v_nota;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_recuperacion_definitiva_periodo(BIGINT, BIGINT, BIGINT)
    IS 'Nota base (porcentaje 0-100) sobre la que COMPUTA una recuperacion con destino NOTA_FINAL, cuando el periodo todavia no se ha consolidado en TASIGNATURA_NOTA. Prefiere fn_asignatura_definitiva_proyectada_periodo -- la proyectada ACOTADA al periodo de evaluacion, que es la nota que la recuperacion dice recuperar -- y cae a fn_planilla_definitiva_proyectada (V239) cuando aquella no existe. La eleccion se hace en tiempo de EJECUCION con to_regprocedure y no con una dependencia de migracion porque esa funcion vive hoy solo en la rama del modulo de Informes: atarla en duro dejaria V408 sin aplicar en dev, y exigirla por Flyway invertiria el orden de dos trabajos independientes. El fallback NO es equivalente y se asume a sabiendas: la de V239 barre TODAS las actividades evaluativas de la asignatura sin mirar fechas, asi que mientras Informes no se mergee una recuperacion de nota final COMPUTA contra el acumulado del ano y no contra el corte -- se prefiere una base amplia y explicada a no consolidar nada. Al mergearse Informes la funcion se afila sola, sin tocar este archivo. NULL si no hay ninguna actividad calificada: no hay con que proyectar, y el llamador se abstiene. V408.';


-- ---------------------------------------------------------------------------
-- 4. La combinacion. Punto UNICO de las cuatro variantes.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_recuperacion_combinar(
    p_nota_base         NUMERIC,
    p_nota_recuperacion NUMERIC,
    p_aplicacion        VARCHAR,
    p_calculo           VARCHAR,
    p_ponderacion       NUMERIC,
    p_politica_sin_nota VARCHAR,
    p_piso              NUMERIC
)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_base NUMERIC := p_nota_base;
BEGIN
    IF p_nota_recuperacion IS NULL THEN
        RETURN NULL;
    END IF;

    -- REEMPLAZAR no mira la nota anterior, asi que no necesita politica.
    IF p_aplicacion = 'REEMPLAZAR' THEN
        RETURN ROUND(p_nota_recuperacion, 2);
    END IF;

    -- COMPUTAR sin nota previa: lo decide el colegio, no esta funcion.
    IF v_base IS NULL THEN
        IF p_politica_sin_nota = 'MENOR' THEN
            v_base := COALESCE(p_piso, 0);
        ELSIF p_politica_sin_nota = 'NINGUNA' THEN
            RETURN ROUND(p_nota_recuperacion, 2);
        ELSE
            RETURN NULL;
        END IF;
    END IF;

    IF p_calculo = 'PONDERADO' AND p_ponderacion IS NOT NULL THEN
        RETURN ROUND(p_nota_recuperacion * p_ponderacion / 100
                     + v_base * (100 - p_ponderacion) / 100, 2);
    END IF;

    RETURN ROUND((v_base + p_nota_recuperacion) / 2, 2);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_recuperacion_combinar(NUMERIC, NUMERIC, VARCHAR, VARCHAR, NUMERIC, VARCHAR, NUMERIC)
    IS 'Definicion UNICA de como una nota de recuperacion se combina con la nota anterior, compartida por los dos destinos (ACTIVIDAD y NOTA_FINAL) para que recuperar una actividad y recuperar la nota final del periodo no den numeros distintos con la misma configuracion. Todo en PORCENTAJE 0-100. Las cuatro combinaciones de TACTIVIDAD_RECUPERACION (V22): REEMPLAZAR ignora la nota anterior Y el tipo de calculo -- devuelve la recuperacion tal cual, y por eso es el unico caso que no necesita politica de "sin nota previa"; COMPUTAR+PONDERADO devuelve recuperacion*p/100 + base*(100-p)/100, donde p es VALOR_PONDERACION_RECUPERACION y es el peso de LA RECUPERACION, no el de la nota anterior (la pantalla lo dice literalmente: "Este porcentaje corresponde al valor de la recuperacion. El valor restante se aplicara a la nota actual"); COMPUTAR+PROMEDIADO devuelve el promedio simple de las dos. PONDERADO sin ponderacion cargada cae a promedio simple en vez de fallar, mismo criterio que V239 con TUNIDAD.PONDERACION: ponderar con un peso que no existe seria inventarselo. SIN NOTA PREVIA en COMPUTAR no se decide aqui con una constante: se recibe ya resuelta la politica institucional (fn_criterio_evaluacion_desempeno_sin_calificar) -- MENOR toma como base el piso PORCENTAJE_INICIAL_CALIF que tambien se recibe (0 si el colegio no lo puso), NINGUNA hace que la recuperacion valga el total, y cualquier otra cosa (incluido el colegio que no lo configuro) devuelve NULL para que el llamador se abstenga de escribir en vez de suponer una nota que nadie definio. Recuperacion NULL entra y sale NULL: "aun no hay nota de recuperacion". NO acota con el tope ni con el piso: eso es fn_actividad_nota_ajustar_por_criterio (V227) y lo aplica el llamador, para no tener la misma regla en dos sitios. Funcion PURA (IMMUTABLE): no lee tablas, no escribe, no gatea -- es aritmetica, y aislarla es lo que permite probar las cuatro combinaciones sin montar un estudiante. Redondea a 2 decimales, la escala de las columnas destino. V408.';


-- ---------------------------------------------------------------------------
-- 5. El orquestador. Se llama en cada calificacion; sale rapido si no aplica.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_recuperacion_aplicar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_tactividad   BIGINT;
    v_fk_tmatricula   BIGINT;
    v_fk_tasignatura  BIGINT;
    v_es_recuperacion CHAR(1);
    v_destino         VARCHAR;
    v_aplicacion      VARCHAR;
    v_calculo         VARCHAR;
    v_ponderacion     NUMERIC;
    v_fk_recuperar    BIGINT;
    v_nota_recup      NUMERIC;
    v_fk_tgrado       BIGINT;
    v_pk_criterio     BIGINT;
    v_politica        VARCHAR;
    v_piso            NUMERIC;
    v_base            NUMERIC;
    v_definitiva      NUMERIC;
    v_pk_destino      BIGINT;
    v_fk_periodo_eval BIGINT;
    v_usuario         VARCHAR := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    SELECT ae.FK_TACTIVIDAD, ae.FK_TMATRICULA, a.ES_RECUPERACION, a.FK_TASIGNATURA
      INTO v_pk_tactividad, v_fk_tmatricula, v_es_recuperacion, v_fk_tasignatura
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
      JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = ae.FK_TACTIVIDAD
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;

    IF v_es_recuperacion IS DISTINCT FROM 'S' THEN
        RETURN jsonb_build_object('aplicada', FALSE, 'motivo', 'NO_ES_RECUPERACION');
    END IF;

    SELECT lv_d.VALOR, lv_a.VALOR, lv_c.VALOR,
           r.VALOR_PONDERACION_RECUPERACION, r.FK_TACTIVIDAD_RECUPERAR
      INTO v_destino, v_aplicacion, v_calculo, v_ponderacion, v_fk_recuperar
      FROM academico_test.TACTIVIDAD_RECUPERACION r
      JOIN academico_test.TLISTA_VALOR lv_d ON lv_d.PK_LISTA_VALOR = r.FK_TLV_DESTINO_RECUPERACION
      JOIN academico_test.TLISTA_VALOR lv_a ON lv_a.PK_LISTA_VALOR = r.FK_TLV_TIPO_APLICACION_RECUPERACION
      JOIN academico_test.TLISTA_VALOR lv_c ON lv_c.PK_LISTA_VALOR = r.FK_TLV_TIPO_CALCULO_RECUPERACION
     WHERE r.FK_TACTIVIDAD = v_pk_tactividad AND r.ACTIVE = TRUE;

    IF v_destino IS NULL THEN
        RETURN jsonb_build_object('aplicada', FALSE, 'motivo', 'SIN_CONFIGURACION');
    END IF;

    SELECT n.CALIFICACION INTO v_nota_recup
      FROM academico_test.TACTIVIDAD_NOTA n
     WHERE n.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND n.ACTIVE = TRUE;

    IF v_nota_recup IS NULL THEN
        RETURN jsonb_build_object('aplicada', FALSE, 'motivo', 'SIN_NOTA_DE_RECUPERACION');
    END IF;

    -- Configuracion institucional: politica de "sin calificar" y piso.
    v_fk_tgrado := academico_test.fn_actividad_grado_resolver(v_pk_tactividad);
    IF v_fk_tgrado IS NOT NULL AND v_fk_tasignatura IS NOT NULL THEN
        v_pk_criterio := academico_test.fn_asignatura_criterio_evaluacion_vigente(
                             v_fk_tasignatura, v_fk_tgrado);
    END IF;
    IF v_pk_criterio IS NOT NULL THEN
        v_politica := academico_test.fn_criterio_evaluacion_desempeno_sin_calificar(v_pk_criterio);
        v_piso     := academico_test.fn_criterio_evaluacion_porcentaje_inicial(v_pk_criterio);
    END IF;

    -- ----- Destino ACTIVIDAD: la nota del MISMO estudiante en la original.
    IF v_destino = 'ACTIVIDAD' THEN
        SELECT n.PK_TACTIVIDAD_NOTA, n.CALIFICACION
          INTO v_pk_destino, v_base
          FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
          JOIN academico_test.TACTIVIDAD_NOTA n
            ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE AND n.ACTIVE = TRUE
         WHERE ae.FK_TACTIVIDAD = v_fk_recuperar
           AND ae.FK_TMATRICULA = v_fk_tmatricula
           AND ae.ACTIVE = TRUE;

        IF v_pk_destino IS NULL THEN
            RETURN jsonb_build_object('aplicada', FALSE, 'motivo', 'DESTINO_NO_ASIGNADO');
        END IF;

        v_definitiva := academico_test.fn_recuperacion_combinar(
                            v_base, v_nota_recup, v_aplicacion, v_calculo,
                            v_ponderacion, v_politica, v_piso);
        IF v_definitiva IS NULL THEN
            RETURN jsonb_build_object('aplicada', FALSE, 'motivo', 'SIN_POLITICA_SIN_CALIFICAR');
        END IF;

        v_definitiva := academico_test.fn_actividad_nota_ajustar_por_criterio(
                            v_pk_tactividad, v_definitiva);

        UPDATE academico_test.TACTIVIDAD_NOTA
           SET RECUPERACION = v_nota_recup,
               DEFINITIVA   = v_definitiva,
               MODIFIED_BY  = v_usuario,
               MODIFIED_AT  = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD_NOTA = v_pk_destino;

    -- ----- Destino NOTA_FINAL: la nota del periodo en TASIGNATURA_NOTA.
    ELSE
        IF academico_test.fn_criterio_evaluacion_nota_final_editable(v_pk_criterio) = FALSE THEN
            RETURN jsonb_build_object('aplicada', FALSE, 'motivo', 'NOTA_FINAL_NO_EDITABLE');
        END IF;

        v_fk_periodo_eval := academico_test.fn_actividad_periodo_evaluacion(
                                 v_pk_tactividad, v_fk_tmatricula);
        IF v_fk_periodo_eval IS NULL OR v_fk_tasignatura IS NULL THEN
            RETURN jsonb_build_object('aplicada', FALSE, 'motivo', 'SIN_PERIODO_DE_EVALUACION');
        END IF;

        SELECT sn.PK_TASIGNATURA_NOTA, sn.CALIFICACION
          INTO v_pk_destino, v_base
          FROM academico_test.TASIGNATURA_NOTA sn
         WHERE sn.FK_TMATRICULA          = v_fk_tmatricula
           AND sn.FK_TPERIODO_EVALUACION = v_fk_periodo_eval
           AND sn.FK_TASIGNATURA         = v_fk_tasignatura
           AND sn.ACTIVE = TRUE;

        IF v_base IS NULL THEN
            v_base := academico_test.fn_recuperacion_definitiva_periodo(
                          v_fk_tmatricula, v_fk_tasignatura, v_fk_periodo_eval);
        END IF;

        v_definitiva := academico_test.fn_recuperacion_combinar(
                            v_base, v_nota_recup, v_aplicacion, v_calculo,
                            v_ponderacion, v_politica, v_piso);
        IF v_definitiva IS NULL THEN
            RETURN jsonb_build_object('aplicada', FALSE, 'motivo', 'SIN_POLITICA_SIN_CALIFICAR');
        END IF;

        v_definitiva := academico_test.fn_actividad_nota_ajustar_por_criterio(
                            v_pk_tactividad, v_definitiva);

        IF v_pk_destino IS NULL THEN
            INSERT INTO academico_test.TASIGNATURA_NOTA (
                FK_TMATRICULA, FK_TPERIODO_EVALUACION, FK_TASIGNATURA,
                CALIFICACION, RECUPERACION, DEFINITIVA, CREATED_BY, CREATED_AT, ACTIVE
            ) VALUES (
                v_fk_tmatricula, v_fk_periodo_eval, v_fk_tasignatura,
                v_base, v_nota_recup, v_definitiva, v_usuario, CURRENT_TIMESTAMP, TRUE
            )
            ON CONFLICT (FK_TMATRICULA, FK_TPERIODO_EVALUACION, FK_TASIGNATURA)
                WHERE ACTIVE = TRUE
            DO UPDATE SET RECUPERACION = EXCLUDED.RECUPERACION,
                          DEFINITIVA   = EXCLUDED.DEFINITIVA,
                          MODIFIED_BY  = v_usuario,
                          MODIFIED_AT  = CURRENT_TIMESTAMP
            RETURNING PK_TASIGNATURA_NOTA INTO v_pk_destino;
        ELSE
            UPDATE academico_test.TASIGNATURA_NOTA
               SET RECUPERACION = v_nota_recup,
                   DEFINITIVA   = v_definitiva,
                   MODIFIED_BY  = v_usuario,
                   MODIFIED_AT  = CURRENT_TIMESTAMP
             WHERE PK_TASIGNATURA_NOTA = v_pk_destino;
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'aplicada',          TRUE,
        'destino',           v_destino,
        'tipo_aplicacion',   v_aplicacion,
        'tipo_calculo',      v_calculo,
        'pk_destino',        v_pk_destino,
        'nota_base',         v_base,
        'nota_recuperacion', v_nota_recup,
        'definitiva',        v_definitiva
    );
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_recuperacion_aplicar(BIGINT, BIGINT)
    IS 'Consolida la nota de una recuperacion sobre su destino: el escritor que faltaba. Se invoca DESPUES de cada escritura de TACTIVIDAD_NOTA.CALIFICACION en V227 (los seis sitios de los cuatro instrumentos, individual y bulk) y lo PRIMERO que hace es salir si la actividad no es de recuperacion, que es el caso mayoritario: el coste en la ruta caliente es una consulta por PK. Lee la config 1:1 de TACTIVIDAD_RECUPERACION (V22) y combina con fn_recuperacion_combinar, unica definicion de las cuatro variantes. DESTINO ACTIVIDAD: escribe RECUPERACION y DEFINITIVA en la TACTIVIDAD_NOTA que ESE MISMO estudiante tiene en la actividad recuperada, emparejando por FK_TMATRICULA -- una recuperacion aplicada a un grupo consolida a cada estudiante contra SU propia nota anterior, no contra un promedio. DESTINO NOTA_FINAL: escribe en TASIGNATURA_NOTA por (matricula, periodo de evaluacion, asignatura), la capa donde vive la nota final del periodo; el periodo se resuelve por fecha con fn_actividad_periodo_evaluacion, la base sale de la fila ya consolidada o, si no existe, de fn_recuperacion_definitiva_periodo, y la fila se crea con CALIFICACION = esa base para que siempre se pueda explicar de donde salio la definitiva. Escribir ahi consolida de hecho esa asignatura de ese periodo, igual que hace fn_informe_planilla_guardar del modulo de Informes con una sola asignatura; no se recalculan las metricas de TINFORME_PERIODO_MATRICULA, que son de aquel modulo. LA BASE NUNCA ES DEFINITIVA, SIEMPRE CALIFICACION: DEFINITIVA es la SALIDA de esta funcion, asi que recalcular desde ella acumularia la recuperacion sobre si misma cada vez que el docente corrige la nota; leyendo CALIFICACION la operacion es IDEMPOTENTE y volver a calificar la recuperacion recalcula desde cero. El resultado pasa por fn_actividad_nota_ajustar_por_criterio (V227) con la PK de la actividad de RECUPERACION y no la del destino: asi se aplica el tope PORCENTAJE_MAXIMO_RECUPERACION -- es una nota que sale de una recuperacion, que es lo que ese tope acota -- y tambien el piso, sin duplicar esa regla en dos sitios. NO ESCRIBE Y DEVUELVE EL MOTIVO en vez de lanzar excepcion, porque calificar no es el sitio donde bloquear al docente por configuracion que no es suya: NO_ES_RECUPERACION, SIN_CONFIGURACION, SIN_NOTA_DE_RECUPERACION (la rubrica aun incompleta), DESTINO_NO_ASIGNADO (al estudiante nunca se le asigno la actividad original), SIN_PERIODO_DE_EVALUACION, NOTA_FINAL_NO_EDITABLE (el colegio cerro la nota final del periodo, FK_TLV_MODIF_FINAL_PERACA) y SIN_POLITICA_SIN_CALIFICAR (COMPUTAR sobre un estudiante sin nota previa y sin FK_TLV_DESEMPENO_SIN_CALIF configurado: no se inventa la base). Devuelve JSONB con aplicada mas el detalle del calculo, para que la pantalla pueda explicar la nota y para poder probar la funcion sin leer las tablas. NO gatea permisos: helper interno, siempre invocado desde una funcion de V227 que ya valido EDITAR sobre PLANEADOR. LO QUE NO HACE: no decide promocion -- TCRITERIO_PROMOCION se consulta al promover, no al calificar. V408.';
