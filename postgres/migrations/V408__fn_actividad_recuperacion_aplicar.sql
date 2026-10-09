-- V408 -- Consolidacion de la recuperacion: al calificar una actividad con
--   ES_RECUPERACION='S' escribe RECUPERACION + DEFINITIVA en su destino (la
--   nota de la actividad recuperada o TASIGNATURA_NOTA del periodo si el
--   destino es NOTA_FINAL), y la deshace al retirarla. Con varios Refuerzos
--   manda el mas reciente con nota (Regla 67, fn_actividad_refuerzo_vigente).
-- Depende de: V22, V220 (periodo por fecha), V227 (piso/tope, grado), V239
--   (criterio vigente, accesores, definitiva proyectada). fn_recuperacion_combinar
--   y fn_actividad_recuperacion_consolidar viven hoy en V496.19.

-- 1. Accesores de configuracion (mismo estilo que los de V239).
CREATE OR REPLACE FUNCTION academico_test.fn_criterio_evaluacion_desempeno_sin_calificar(
    p_pk_criterio BIGINT
)
RETURNS VARCHAR
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    -- plpgsql y no sql: una sql con FROM no se incrusta y se replanifica en
    -- cada llamada; aqui el plan queda en cache. Primera fila o NULL, como antes.
    RETURN (SELECT * FROM (
    SELECT CASE
               WHEN UPPER(COALESCE(lv.NOMBRE, '') || ' ' || COALESCE(lv.VALOR, '')) LIKE '%MENOR%'  THEN 'MENOR'
               WHEN UPPER(COALESCE(lv.NOMBRE, '') || ' ' || COALESCE(lv.VALOR, '')) LIKE '%NINGUN%' THEN 'NINGUNA'
               ELSE NULL
           END
      FROM academico_test.TCRITERIO_EVALUACION ce
      JOIN academico_test.TLISTA_VALOR lv
        ON lv.PK_LISTA_VALOR = ce.FK_TLV_DESEMPENO_SIN_CALIF
     WHERE ce.PK_TCRITERIO_EVALUACION = p_pk_criterio
    ) q LIMIT 1);
END;
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
-- ---------------------------------------------------------------------------
-- 5. Regla 67: con varios Refuerzos de la misma actividad, manda el mas
--    reciente que ya tenga nota para ese estudiante.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_refuerzo_vigente(
    p_pk_tactividad_original BIGINT,
    p_fk_tmatricula          BIGINT,
    p_pk_tactividad_excluir  BIGINT DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT ae.PK_TACTIVIDAD_ESTUDIANTE
      FROM academico_test.TACTIVIDAD_RECUPERACION r
      JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = r.FK_TACTIVIDAD AND a.ACTIVE = TRUE
      JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
        ON ae.FK_TACTIVIDAD = r.FK_TACTIVIDAD AND ae.FK_TMATRICULA = p_fk_tmatricula AND ae.ACTIVE = TRUE
      JOIN academico_test.TACTIVIDAD_NOTA n
        ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE AND n.ACTIVE = TRUE AND n.CALIFICACION IS NOT NULL
     WHERE r.FK_TACTIVIDAD_RECUPERAR = p_pk_tactividad_original
       AND r.ACTIVE = TRUE
       AND r.FK_TACTIVIDAD IS DISTINCT FROM p_pk_tactividad_excluir
     ORDER BY a.CREATED_AT DESC, a.PK_TACTIVIDAD DESC
     LIMIT 1;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_refuerzo_vigente(BIGINT, BIGINT, BIGINT)
    IS 'Regla 67: asignacion (TACTIVIDAD_ESTUDIANTE) del Refuerzo mas reciente de la actividad original que ya tiene nota para el estudiante; NULL si no hay. p_pk_tactividad_excluir deja fuera un Refuerzo que se esta retirando. Lo usan la consolidacion y la reversion de la recuperacion.';

-- ---------------------------------------------------------------------------
-- 6. Deshacer. Lo llaman el _interno de eliminar actividad y el de quitar la
--    configuracion de recuperacion, antes de desactivar su fila.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_recuperacion_revertir(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_destino      VARCHAR;
    v_fk_recuperar BIGINT;
    v_fk_tasig     BIGINT;
    v_n            INTEGER := 0;
    v_usuario      VARCHAR := p_pk_usuario_solicitante::VARCHAR;
    v_ae           RECORD;
    v_otro         BIGINT;
BEGIN
    SELECT lv.VALOR, r.FK_TACTIVIDAD_RECUPERAR, a.FK_TASIGNATURA
      INTO v_destino, v_fk_recuperar, v_fk_tasig
      FROM academico_test.TACTIVIDAD_RECUPERACION r
      JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = r.FK_TLV_DESTINO_RECUPERACION
      JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = r.FK_TACTIVIDAD
     WHERE r.FK_TACTIVIDAD = p_pk_tactividad AND r.ACTIVE = TRUE;

    IF v_destino = 'ACTIVIDAD' THEN
        FOR v_ae IN SELECT DISTINCT ae_r.FK_TMATRICULA FROM academico_test.TACTIVIDAD_ESTUDIANTE ae_r
                     WHERE ae_r.FK_TACTIVIDAD = p_pk_tactividad LOOP
            UPDATE academico_test.TACTIVIDAD_NOTA n
               SET RECUPERACION = NULL, DEFINITIVA = NULL,
                   MODIFIED_BY = v_usuario, MODIFIED_AT = CURRENT_TIMESTAMP
              FROM academico_test.TACTIVIDAD_ESTUDIANTE ae_o
             WHERE n.FK_TACTIVIDAD_ESTUDIANTE = ae_o.PK_TACTIVIDAD_ESTUDIANTE
               AND ae_o.FK_TACTIVIDAD = v_fk_recuperar
               AND ae_o.FK_TMATRICULA = v_ae.FK_TMATRICULA
               AND (n.RECUPERACION IS NOT NULL OR n.DEFINITIVA IS NOT NULL);
            IF FOUND THEN
                v_n := v_n + 1;
            END IF;
            -- Regla 67: si queda otro Refuerzo con nota, pasa a mandar ese.
            v_otro := academico_test.fn_actividad_refuerzo_vigente(v_fk_recuperar, v_ae.FK_TMATRICULA, p_pk_tactividad);
            IF v_otro IS NOT NULL THEN
                PERFORM academico_test.fn_actividad_recuperacion_consolidar(p_pk_usuario_solicitante, v_otro, p_pk_tactividad);
            END IF;
        END LOOP;
    ELSIF v_destino = 'NOTA_FINAL' THEN
        UPDATE academico_test.TASIGNATURA_NOTA sn
           SET RECUPERACION = NULL, DEFINITIVA = sn.CALIFICACION,
               MODIFIED_BY = v_usuario, MODIFIED_AT = CURRENT_TIMESTAMP
          FROM academico_test.TACTIVIDAD_ESTUDIANTE ae_r
         WHERE ae_r.FK_TACTIVIDAD = p_pk_tactividad
           AND sn.FK_TMATRICULA = ae_r.FK_TMATRICULA
           AND sn.FK_TASIGNATURA = v_fk_tasig
           AND sn.FK_TPERIODO_EVALUACION =
               academico_test.fn_actividad_periodo_evaluacion(p_pk_tactividad, ae_r.FK_TMATRICULA)
           AND sn.RECUPERACION IS NOT NULL
           AND sn.ACTIVE = TRUE;
        GET DIAGNOSTICS v_n = ROW_COUNT;
    END IF;

    RETURN v_n;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_recuperacion_revertir(BIGINT, BIGINT)
    IS 'Deshace lo que fn_actividad_recuperacion_aplicar escribio en el destino de una recuperacion, para cuando la recuperacion deja de existir: la invocan fn_actividad_recuperacion_configurar_interno (p_config NULL) y fn_actividad_eliminar_interno, ANTES de desactivar la fila de TACTIVIDAD_RECUPERACION, que es de donde lee el destino. Sin esto la actividad original se quedaria con una DEFINITIVA que sale de una recuperacion que ya no existe, y V239 la seguiria mostrando. Destino ACTIVIDAD: pone RECUPERACION y DEFINITIVA a NULL en la nota de la original de cada estudiante que estaba en la recuperacion -- solo esos, y solo si tenian algo escrito -- y, si ese estudiante tiene otro Refuerzo con nota, lo consolida (Regla 67). Destino NOTA_FINAL: en TASIGNATURA_NOTA del periodo deja RECUPERACION NULL y DEFINITIVA = CALIFICACION, que es exactamente el estado en que la deja el guardado del modulo de Informes; no se desactiva la fila porque no se puede saber si la consolido Informes o esta recuperacion, y borrar una consolidacion ajena seria peor que dejar una de mas. Devuelve cuantas filas toco. No gatea: helper de V224, que ya valido. V408.';


-- ---------------------------------------------------------------------------
-- 7. El orquestador. Se llama en cada calificacion; sale rapido si no aplica.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_recuperacion_aplicar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN academico_test.fn_actividad_recuperacion_consolidar(p_pk_usuario_solicitante, p_pk_tactividad_estudiante, NULL);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_recuperacion_aplicar(BIGINT, BIGINT)
    IS 'INTERNO: consolida la recuperacion tras escribir una nota (fn_actividad_recuperacion_consolidar sin exclusiones). La invoca fn_actividad_nota_guardar_interno despues de cada calificacion.';
