-- V239 - Cálculo de la definitiva: ponderación de unidades por asignatura y su
-- trigger, plan y criterio de evaluación vigentes con sus accesores, y la
-- definitiva proyectada (la usa V408). Lo propio de la planilla de
-- calificación vive en V469.1-V469.5.
-- Depende de: V22, V223 (ponderación de actividades), V227.

SET search_path TO academico_test, public;

ALTER TABLE TUNIDAD
  ADD COLUMN IF NOT EXISTS PONDERACION NUMERIC(5,2);

ALTER TABLE TUNIDAD DROP CONSTRAINT IF EXISTS CK_TUNIDAD_PONDERACION;

ALTER TABLE TUNIDAD ADD CONSTRAINT CK_TUNIDAD_PONDERACION
  CHECK (PONDERACION IS NULL OR (PONDERACION >= 0 AND PONDERACION <= 100));

CREATE INDEX IF NOT EXISTS IDX_TUNIDAD_ASIGNATURA_GRADO
  ON TUNIDAD (FK_TASIGNATURA, FK_TGRADO) WHERE ACTIVE = true;

COMMENT ON COLUMN TUNIDAD.PONDERACION IS
  'Peso (%) de la unidad dentro de su asignatura, por grado: bucket (FK_TASIGNATURA, FK_TGRADO). 0..100, nullable (NULL = sin peso configurado). Analogo a TACTIVIDAD.PONDERACION (V223) pero un nivel arriba: aquella pesa una ACTIVIDAD dentro de su UNIDAD, esta pesa una UNIDAD dentro de su ASIGNATURA. La suma por (FK_TASIGNATURA, FK_TGRADO) de las unidades ACTIVE no puede pasar de 100 (trigger tr_tunidad_ponderacion_asignatura). Solo aplica cuando el plan de la asignatura (TASIGNATURA_PLAN) calcula la definitiva por UNIDADES y las combina con PONDERAR/SUMATORIA: es el peso que consume fn_planilla_definitiva_proyectada. V239.';

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_ponderacion_intra_asignatura_asignada(
    p_fk_tasignatura    BIGINT,
    p_fk_tgrado         BIGINT,
    p_excluir_tunidad   BIGINT DEFAULT NULL
)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(SUM(u.PONDERACION), 0)::NUMERIC
      FROM academico_test.TUNIDAD u
     WHERE u.FK_TASIGNATURA = p_fk_tasignatura
       AND u.FK_TGRADO      = p_fk_tgrado
       AND u.ACTIVE = TRUE
       AND u.PONDERACION IS NOT NULL
       AND u.PK_TUNIDAD IS DISTINCT FROM p_excluir_tunidad;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_ponderacion_intra_asignatura_asignada(BIGINT, BIGINT, BIGINT)
    IS 'Suma de TUNIDAD.PONDERACION de las unidades ACTIVE (y con PONDERACION no nula) de una (FK_TASIGNATURA, FK_TGRADO). p_excluir_tunidad (opcional) deja fuera una unidad concreta, para validar un INSERT/UPDATE sin contar la fila que se esta tocando. Definicion UNICA usada por el trigger tr_tunidad_ponderacion_asignatura, por fn_asignatura_grado_ponderacion_disponible y por fn_unidad_crear/fn_unidad_actualizar (V216, chequeo previo del 100% para dar un error claro antes del trigger). Retorna 0 (nunca NULL) si no hay nada asignado. Es el analogo de fn_unidad_ponderacion_asignada (V223) un nivel arriba: alli el bucket es (unidad, grupo) y el grupo NULL es su propio bucket; aqui el bucket es (asignatura, grado) y TUNIDAD no tiene grupo, asi que no hay caso NULL. V239.';

CREATE OR REPLACE FUNCTION academico_test.fn_tunidad_ponderacion_asignatura_check()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_suma NUMERIC(9,2);
BEGIN
    IF NEW.ACTIVE IS DISTINCT FROM TRUE
       OR NEW.PONDERACION IS NULL
       OR NEW.FK_TASIGNATURA IS NULL
       OR NEW.FK_TGRADO IS NULL THEN
        RETURN NEW;
    END IF;

    v_suma := academico_test.fn_unidad_ponderacion_intra_asignatura_asignada(
                  NEW.FK_TASIGNATURA, NEW.FK_TGRADO, NEW.PK_TUNIDAD);

    IF v_suma + NEW.PONDERACION > 100 THEN
        RAISE EXCEPTION
          'En % (grado %) la ponderación ya suma %; con el % de "%" llegaría a %, y no puede pasar de 100%%.',
          (SELECT a.NOMBRE FROM academico_test.TASIGNATURA a WHERE a.PK_TASIGNATURA = NEW.FK_TASIGNATURA),
          (SELECT g.NOMBRE FROM academico_test.TGRADO g WHERE g.PK_TGRADO = NEW.FK_TGRADO),
          trim_scale(v_suma)::TEXT || '%', trim_scale(NEW.PONDERACION)::TEXT || '%', NEW.NOMBRE, trim_scale(v_suma + NEW.PONDERACION)::TEXT || '%'
          USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_tunidad_ponderacion_asignatura_check()
    IS 'Trigger BEFORE INSERT/UPDATE de TUNIDAD: impide que la suma de PONDERACION de las unidades ACTIVE de una misma (FK_TASIGNATURA, FK_TGRADO) pase de 100 (23514), via fn_unidad_ponderacion_intra_asignatura_asignada. Analogo de fn_tactividad_ponderacion_unidad_check (V223) un nivel arriba, sin su excepcion de SUMATORIA: el peso de una unidad dentro de la asignatura siempre lo captura el docente, nunca es un derivado redondeado. V239.';

DROP TRIGGER IF EXISTS tr_tunidad_ponderacion_asignatura ON TUNIDAD;

CREATE TRIGGER tr_tunidad_ponderacion_asignatura
  BEFORE INSERT OR UPDATE OF PONDERACION, FK_TASIGNATURA, FK_TGRADO, ACTIVE ON TUNIDAD
  FOR EACH ROW
  EXECUTE FUNCTION academico_test.fn_tunidad_ponderacion_asignatura_check();

CREATE OR REPLACE FUNCTION academico_test.fn_asignatura_grado_ponderacion_disponible(
    p_pk_usuario_solicitante   BIGINT,
    p_fk_tasignatura           BIGINT,
    p_fk_tgrado                BIGINT
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, p_fk_tgrado
    );

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA
         WHERE PK_TASIGNATURA = p_fk_tasignatura AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se encontro la asignatura solicitada' USING ERRCODE = 'P0002';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TGRADO
         WHERE PK_TGRADO = p_fk_tgrado AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se encontro el grado solicitado' USING ERRCODE = 'P0002';
    END IF;

    RETURN GREATEST(
        100 - academico_test.fn_unidad_ponderacion_intra_asignatura_asignada(
                  p_fk_tasignatura, p_fk_tgrado, NULL),
        0
    );
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asignatura_grado_ponderacion_disponible(BIGINT, BIGINT, BIGINT)
    IS 'Porcentaje que le queda LIBRE a una (asignatura, grado) para repartir entre sus UNIDADES: 100 - fn_unidad_ponderacion_intra_asignatura_asignada(asignatura, grado). Alimenta el "Disponible para asignar: X%" del campo de peso de la unidad, igual que fn_unidad_ponderacion_disponible (V223) lo hace para las actividades de una unidad. Acotado a >= 0 por si algun dato historico previo al trigger tr_tunidad_ponderacion_asignatura pasara de 100. Gate VER sobre PLANEADOR. P0002 si la asignatura o el grado no existen/no estan activos. V239.';

CREATE OR REPLACE FUNCTION academico_test.fn_asignatura_plan_vigente_por_grado(
    p_fk_tgrado       BIGINT,
    p_fk_tasignatura  BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    -- plpgsql y no sql: una sql con FROM no se incrusta y se replanifica en
    -- cada llamada; aqui el plan queda en cache. Primera fila o NULL, como antes.
    RETURN (SELECT * FROM (
    SELECT ap.PK_TASIGNATURA_PLAN
      FROM academico_test.TPLAN pl
      JOIN academico_test.TASIGNATURA_PLAN ap
        ON ap.FK_TPLAN = pl.PK_TPLAN
       AND ap.FK_TASIGNATURA = p_fk_tasignatura
       AND ap.ACTIVE = TRUE
     WHERE pl.FK_TGRADO = p_fk_tgrado
       AND pl.ACTIVE = TRUE
     -- Desempate determinista cuando el grado tiene varios planes activos.
     ORDER BY pl.CREATED_AT DESC, pl.PK_TPLAN DESC
     LIMIT 1
    ) q LIMIT 1);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asignatura_plan_vigente_por_grado(BIGINT, BIGINT)
    IS 'Resolucion BASE de la fila de TASIGNATURA_PLAN (V22) que configura el calculo de la definitiva de una asignatura en un GRADO: grado -> TPLAN ACTIVE del grado -> TASIGNATURA_PLAN ACTIVE de esa asignatura. NULL si no hay ninguna. Aqui vive la consulta y el desempate (plan activo MAS RECIENTE: CREATED_AT DESC, PK_TPLAN DESC) y aqui vive la LIMITACION documentada de los grados con varios TPLAN activos (59 casos reales en el servidor). fn_asignatura_plan_vigente(grupo, asignatura) resuelve grupo -> grado y DELEGA en esta funcion, para que los dos puntos de entrada (la planilla, que parte de un grupo, y el CRUD de unidades de V216, que parte de un grado porque TUNIDAD no tiene grupo) compartan una sola definicion. V239.';

CREATE OR REPLACE FUNCTION academico_test.fn_asignatura_plan_vigente(
    p_fk_tgrupo       BIGINT,
    p_fk_tasignatura  BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    -- plpgsql y no sql: una sql con FROM no se incrusta y se replanifica en
    -- cada llamada; aqui el plan queda en cache. Primera fila o NULL, como antes.
    RETURN (SELECT * FROM (
    SELECT academico_test.fn_asignatura_plan_vigente_por_grado(
               gr.FK_TGRADO, p_fk_tasignatura)
      FROM academico_test.TGRUPO gr
     WHERE gr.PK_TGRUPO = p_fk_tgrupo
       AND gr.ACTIVE = TRUE
    ) q LIMIT 1);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asignatura_plan_vigente(BIGINT, BIGINT)
    IS 'Resuelve la fila de TASIGNATURA_PLAN (V22) que configura el calculo de la definitiva de una asignatura para los estudiantes de un grupo: grupo -> grado -> TPLAN ACTIVE del grado -> TASIGNATURA_PLAN ACTIVE de esa asignatura. NULL si no hay ninguna. LIMITACION CONOCIDA: el esquema no vincula una matricula/grupo a un plan concreto (no hay FK, ni vigencia ni marca de "principal" en TPLAN) y todo el repo (V44 fn_plan_*, V45, V46, V186) asume UN solo TPLAN activo por grado, cosa que en el servidor real no siempre se cumple (59 grados con mas de uno). Se toma el plan activo MAS RECIENTE (CREATED_AT DESC, PK_TPLAN DESC como desempate determinista); en un grado multi-plan puede elegir el equivocado. La consulta y el desempate NO viven aqui: esta funcion solo resuelve grupo -> grado y DELEGA en fn_asignatura_plan_vigente_por_grado (el otro punto de entrada, el CRUD de unidades de V216, parte del grado porque TUNIDAD no tiene grupo). Punto UNICO de esa resolucion: cuando el negocio defina el vinculo real, se cambia solo alli. V239.';

CREATE OR REPLACE FUNCTION academico_test.fn_asignatura_criterio_evaluacion_vigente(
    p_fk_tasignatura  BIGINT,
    p_fk_tgrado       BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    -- plpgsql y no sql: una sql con FROM no se incrusta y se replanifica en
    -- cada llamada; aqui el plan queda en cache. Primera fila o NULL, como antes.
    RETURN (SELECT * FROM (
    SELECT cep.FK_TCRITERIO_EVALUACION
      FROM academico_test.TCRITERIO_EVALUACION_ASIGNATURA_PLAN cep
     WHERE cep.FK_TASIGNATURA_PLAN =
               academico_test.fn_asignatura_plan_vigente_por_grado(
                   p_fk_tgrado, p_fk_tasignatura)
       AND cep.ACTIVE = TRUE
       -- El override del grado pedido, o la fila "por defecto" institucional.
       -- Cualquier otro grado no aplica aqui.
       AND (cep.FK_TGRADO = p_fk_tgrado OR cep.FK_TGRADO IS NULL)
     -- Prioridad: override por grado exacto ANTES que la fila por defecto.
     -- FALSE ordena antes que TRUE, asi que "FK_TGRADO IS NULL" pone el
     -- default al final. Los dos criterios siguientes son solo desempate
     -- determinista dentro del mismo escalon (hoy imposible; ver cabecera).
     ORDER BY (cep.FK_TGRADO IS NULL),
              cep.CREATED_AT DESC,
              cep.PK_TCRITERIO_EVALUACION_ASIGNATURA_PLAN DESC
     LIMIT 1
    ) q LIMIT 1);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asignatura_criterio_evaluacion_vigente(BIGINT, BIGINT)
    IS 'Resuelve el PK_TCRITERIO_EVALUACION (V22, 1:1 con TPERIODO_ACADEMICO) que configura los criterios de evaluacion aplicables a una (asignatura, grado): grado+asignatura -> TASIGNATURA_PLAN (fn_asignatura_plan_vigente_por_grado, con su limitacion documentada de grados multi-plan) -> TCRITERIO_EVALUACION_ASIGNATURA_PLAN ACTIVE -> TCRITERIO_EVALUACION. Da PRIORIDAD a la fila de override cuyo FK_TGRADO es exactamente el grado pedido sobre la fila "por defecto" institucional (FK_TGRADO IS NULL, POR_DEFECTO=''S''); dentro del mismo escalon desempata por CREATED_AT DESC y PK DESC. En el servidor real la cardinalidad es 1:1 de hecho (0 de 9684 TASIGNATURA_PLAN con mas de una fila activa), pero el esquema SI permite que coexistan la fila por defecto y un override por grado (CHK_TCE_ASIG_PLAN_INHERIT), por eso el desempate es explicito y no un LIMIT 1 arbitrario. Retorna NULL si se rompe cualquier eslabon de la cadena -- NULL no es error, significa "sin criterios configurados". Punto UNICO de esta resolucion; la consume V227 (fn_actividad_nota_ajustar_por_criterio) para el piso y el tope de las calificaciones. V239.';

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_evaluacion_porcentaje_inicial(
    p_pk_tcriterio_evaluacion  BIGINT
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    -- plpgsql y no sql: una sql con FROM no se incrusta y se replanifica en
    -- cada llamada; aqui el plan queda en cache. Primera fila o NULL, como antes.
    RETURN (SELECT * FROM (
    SELECT ce.PORCENTAJE_INICIAL_CALIF::NUMERIC
      FROM academico_test.TCRITERIO_EVALUACION ce
     WHERE ce.PK_TCRITERIO_EVALUACION = p_pk_tcriterio_evaluacion
    ) q LIMIT 1);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_criterio_evaluacion_porcentaje_inicial(BIGINT)
    IS 'TCRITERIO_EVALUACION.PORCENTAJE_INICIAL_CALIF (V22) de una fila de criterios de evaluacion: la "Nota inicial para las calificaciones", es decir el PISO institucional por debajo del cual no baja ninguna calificacion. Ya viene como PORCENTAJE 0-100 en la tabla (misma convencion que TACTIVIDAD_NOTA.CALIFICACION; fn_criterio_eval_obtener convierte a la escala del FORMATO_CALIFICACION solo para MOSTRAR en su pantalla), asi que este accesor NO hace ninguna conversion. NULL si no existe la fila o el campo esta vacio -- NULL significa "sin piso configurado", no es error. Lo consume V227 (fn_actividad_nota_ajustar_por_criterio). V239.';

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_evaluacion_porcentaje_maximo_recuperacion(
    p_pk_tcriterio_evaluacion  BIGINT
)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT ce.PORCENTAJE_MAXIMO_RECUPERACION::NUMERIC
      FROM academico_test.TCRITERIO_EVALUACION ce
     WHERE ce.PK_TCRITERIO_EVALUACION = p_pk_tcriterio_evaluacion;
$$;

COMMENT ON FUNCTION academico_test.fn_criterio_evaluacion_porcentaje_maximo_recuperacion(BIGINT)
    IS 'TCRITERIO_EVALUACION.PORCENTAJE_MAXIMO_RECUPERACION (columna agregada por V62) de una fila de criterios de evaluacion: la "Nota maxima de recuperacion", es decir el TOPE que no puede superar la calificacion de una actividad de recuperacion (TACTIVIDAD.ES_RECUPERACION=''S''). Ya viene como PORCENTAJE 0-100 en la tabla, igual que PORCENTAJE_INICIAL_CALIF: este accesor NO hace ninguna conversion de escala. NULL si no existe la fila o el campo esta vacio -- NULL significa "sin tope configurado", no es error. Lo consume V227 (fn_actividad_nota_ajustar_por_criterio). V239.';

CREATE OR REPLACE FUNCTION academico_test.fn_asignatura_plan_elemento_calculo(
    p_pk_tasignatura_plan  BIGINT
)
RETURNS VARCHAR
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    -- plpgsql y no sql: una sql con FROM no se incrusta y se replanifica en
    -- cada llamada; aqui el plan queda en cache. Primera fila o NULL, como antes.
    RETURN (SELECT * FROM (
    SELECT CASE lv.VALOR
               WHEN '2' THEN 'ACTIVIDADES'
               WHEN '1' THEN 'UNIDADES'
               ELSE NULL
           END::VARCHAR
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TLISTA_VALOR lv
        ON lv.PK_LISTA_VALOR = ap.FK_TLV_ELEMENTO_CALCULO_DEF
     WHERE ap.PK_TASIGNATURA_PLAN = p_pk_tasignatura_plan
    ) q LIMIT 1);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asignatura_plan_elemento_calculo(BIGINT)
    IS 'Elemento base con el que el motor calcula la definitiva de una asignatura, a partir de TASIGNATURA_PLAN.FK_TLV_ELEMENTO_CALCULO_DEF (TLISTA_VALOR categoria ELEMENTO_CALCULO_DEF): ''ACTIVIDADES'' (VALOR=''2'', combina PLANO todas las actividades evaluativas sin pasar por unidad; es el caso mayoritario en el servidor real: 8023 filas) | ''UNIDADES'' (VALOR=''1'', etiquetado "Instrumentos" en el legacy -- confirmado con negocio que "Instrumentos" es el nombre heredado de lo que el Planeador llama UNIDAD; 1668 filas) | NULL si no hay fila, el campo es NULL o el valor no se reconoce (nunca existio un tercer valor). Se resuelve por VALOR, nunca por PK. No filtra por lv.ACTIVE (mismo criterio que fn_unidad_calculo_definitiva_modo, V223: desactivar el catalogo no debe cambiar en silencio una nota). V239.';

CREATE OR REPLACE FUNCTION academico_test.fn_asignatura_plan_calculo_definitiva_modo(
    p_pk_tasignatura_plan  BIGINT
)
RETURNS VARCHAR
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    -- plpgsql y no sql: una sql con FROM no se incrusta y se replanifica en
    -- cada llamada; aqui el plan queda en cache. Primera fila o NULL, como antes.
    RETURN (SELECT * FROM (
    SELECT CASE lv.VALOR
               WHEN '2' THEN 'PONDERAR'
               WHEN '1' THEN 'PROMEDIAR'
               WHEN '3' THEN 'SUMATORIA'
               ELSE NULL
           END::VARCHAR
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TLISTA_VALOR lv
        ON lv.PK_LISTA_VALOR = ap.FK_TLV_CALCULO_DEFINITIVA
     WHERE ap.PK_TASIGNATURA_PLAN = p_pk_tasignatura_plan
    ) q LIMIT 1);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asignatura_plan_calculo_definitiva_modo(BIGINT)
    IS 'Modo canonico con el que se combinan los elementos base para dar la definitiva de una asignatura, a partir de TASIGNATURA_PLAN.FK_TLV_CALCULO_DEFINITIVA: ''PONDERAR'' | ''PROMEDIAR'' | ''SUMATORIA'' | NULL. Es el MISMO catalogo CALCULO_DEFINITIVA que usa TUNIDAD.FK_TLV_CALCULO_DEFINITIVA (V73) con los MISMOS VALOR (''1'' Promediar, ''2'' Ponderar, ''3'' Sumatoria, confirmados por SSH en V223), por eso este helper es un calco de fn_unidad_calculo_definitiva_modo sobre la otra tabla. Se resuelve por VALOR, nunca por PK. V239.';

CREATE OR REPLACE FUNCTION academico_test.fn_planilla_definitiva_proyectada(
    p_fk_tmatricula   BIGINT,
    p_fk_tasignatura  BIGINT
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pk_asignatura_plan BIGINT;
    v_elemento           VARCHAR;   -- 'ACTIVIDADES' | 'UNIDADES' | NULL
    v_modo               VARCHAR;   -- 'PONDERAR' | 'PROMEDIAR' | 'SUMATORIA' | NULL
    v_resultado          NUMERIC;
BEGIN
    -- Configuracion del motor de calculo para (grupo de la matricula,
    -- asignatura). Puede no resolverse: en ese caso v_elemento queda NULL y
    -- se aplica el fallback (punto (e) de la cabecera).
    SELECT academico_test.fn_asignatura_plan_vigente(m.FK_TGRUPO, p_fk_tasignatura)
      INTO v_pk_asignatura_plan
      FROM academico_test.TMATRICULA m
     WHERE m.PK_TMATRICULA = p_fk_tmatricula;

    IF v_pk_asignatura_plan IS NOT NULL THEN
        v_elemento := academico_test.fn_asignatura_plan_elemento_calculo(v_pk_asignatura_plan);
        v_modo     := academico_test.fn_asignatura_plan_calculo_definitiva_modo(v_pk_asignatura_plan);
    END IF;

    IF v_elemento = 'ACTIVIDADES' THEN
        -- (b) PLANO: todas las actividades evaluativas calificadas de la
        -- asignatura compiten en un mismo calculo, sin pasar por unidad.
        WITH notas AS (
            SELECT COALESCE(a.PONDERACION, 0)             AS peso,
                   COALESCE(n.DEFINITIVA, n.CALIFICACION) AS nota
              FROM academico_test.TACTIVIDAD a
              JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
                ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
               AND ae.FK_TMATRICULA = p_fk_tmatricula
               AND ae.ACTIVE = TRUE
              JOIN academico_test.TACTIVIDAD_NOTA n
                ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
               AND n.ACTIVE = TRUE
             WHERE a.ACTIVE = TRUE
               AND a.FK_TASIGNATURA = p_fk_tasignatura
               AND COALESCE(a.ES_EVALUATIVA::VARCHAR, 'S') = 'S'
               AND COALESCE(a.ES_RECUPERACION::VARCHAR, 'N') <> 'S'
               AND COALESCE(n.CALIFICABLE, 'S') <> 'N'
               AND COALESCE(n.DEFINITIVA, n.CALIFICACION) IS NOT NULL
        )
        SELECT ROUND(
                   CASE
                       WHEN v_modo IN ('PONDERAR', 'SUMATORIA') AND SUM(nt.peso) > 0
                       THEN SUM(nt.nota * nt.peso) / SUM(nt.peso)
                       ELSE AVG(nt.nota)
                   END, 2)
          INTO v_resultado
          FROM notas nt;

        RETURN v_resultado;
    END IF;

    -- (c) POR UNIDAD (v_elemento = 'UNIDADES') y (e) fallback sin
    -- configuracion: comparten el mismo camino. Cada unidad calcula su nota
    -- con el metodo de V223 y las notas-de-unidad se combinan entre si.
    --
    -- Combinacion ENTRE unidades: si v_modo es PONDERAR/SUMATORIA y TODAS las
    -- unidades con nota tienen TUNIDAD.PONDERACION (seccion (0) de este
    -- archivo) configurada, se pondera con ese peso, renormalizando sobre las
    -- unidades que ya tienen nota -- mismo espiritu que la formula de
    -- actividades. Si a alguna le falta el peso (o hay actividades sueltas sin
    -- unidad, que forman un bucket sin peso posible), se cae a PROMEDIO SIMPLE:
    -- ponderar con huecos daria un resultado sesgado y silencioso. Ver la
    -- cabecera.
    WITH notas AS (
        SELECT a.FK_TUNIDAD,
               COALESCE(a.PONDERACION, 0)                  AS peso,
               COALESCE(n.DEFINITIVA, n.CALIFICACION)      AS nota
          FROM academico_test.TACTIVIDAD a
          JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
            ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
           AND ae.FK_TMATRICULA = p_fk_tmatricula
           AND ae.ACTIVE = TRUE
          JOIN academico_test.TACTIVIDAD_NOTA n
            ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
           AND n.ACTIVE = TRUE
         WHERE a.ACTIVE = TRUE
           AND a.FK_TASIGNATURA = p_fk_tasignatura
           AND COALESCE(a.ES_EVALUATIVA::VARCHAR, 'S') = 'S'
           AND COALESCE(a.ES_RECUPERACION::VARCHAR, 'N') <> 'S'
           AND COALESCE(n.CALIFICABLE, 'S') <> 'N'
           AND COALESCE(n.DEFINITIVA, n.CALIFICACION) IS NOT NULL
    ),
    por_unidad AS (
        SELECT nt.FK_TUNIDAD,
               CASE
                   WHEN academico_test.fn_unidad_calculo_definitiva_modo(nt.FK_TUNIDAD)
                            IN ('PONDERAR', 'SUMATORIA')
                        AND SUM(nt.peso) > 0
                   THEN SUM(nt.nota * nt.peso) / SUM(nt.peso)
                   ELSE AVG(nt.nota)
               END AS nota_unidad
          FROM notas nt
         GROUP BY nt.FK_TUNIDAD
    ),
    con_peso AS (
        -- El bucket de actividades sin unidad (FK_TUNIDAD NULL) no tiene peso
        -- posible: el LEFT JOIN lo deja en NULL y, por la regla de abajo,
        -- fuerza el promedio simple.
        SELECT pu.nota_unidad,
               tu.PONDERACION AS peso_unidad
          FROM por_unidad pu
          LEFT JOIN academico_test.TUNIDAD tu ON tu.PK_TUNIDAD = pu.FK_TUNIDAD
    )
    SELECT ROUND(
               CASE
                   WHEN v_modo IN ('PONDERAR', 'SUMATORIA')
                        AND COUNT(*) FILTER (WHERE cp.peso_unidad IS NULL) = 0
                        AND SUM(cp.peso_unidad) > 0
                   THEN SUM(cp.nota_unidad * cp.peso_unidad) / SUM(cp.peso_unidad)
                   ELSE AVG(cp.nota_unidad)
               END, 2)
      INTO v_resultado
      FROM con_peso cp;

    RETURN v_resultado;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_planilla_definitiva_proyectada(BIGINT, BIGINT)
    IS 'Columna "DEFINIT PROY." de la pantalla "Planilla de calificacion": definitiva PROYECTADA (porcentaje 0-100, sin homologar a la escala visual del periodo -- misma frontera que documenta V227) de un estudiante en una asignatura, con lo calificado HASTA HOY. Implementa la regla del motor de calculo LEGACY, confirmada contra el servidor real y con negocio: TASIGNATURA_PLAN (V22) define QUE se combina (FK_TLV_ELEMENTO_CALCULO_DEF -> fn_asignatura_plan_elemento_calculo) y COMO (FK_TLV_CALCULO_DEFINITIVA -> fn_asignatura_plan_calculo_definitiva_modo, mismo catalogo CALCULO_DEFINITIVA de V73/V223). Formula: (a) universo = actividades ES_EVALUATIVA=''S'' de la asignatura, asignadas al estudiante, con CALIFICABLE distinto de ''N'' y con nota COALESCE(TACTIVIDAD_NOTA.DEFINITIVA, CALIFICACION) no nula -- la DEFINITIVA manda para que la recuperacion consolidada (fn_actividad_recuperacion_aplicar, V408) pese sobre la nota original, y por lo mismo las actividades ES_RECUPERACION=''S'' quedan FUERA del universo: su efecto ya esta dentro de la DEFINITIVA de la actividad recuperada (o en TASIGNATURA_NOTA si recuperan la nota final), y contarlas ademas como una actividad mas las pesaria dos veces -- y en NOTA_FINAL haria circular la base; (b) ELEMENTO=''ACTIVIDADES'' (VALOR=''2'', el caso mayoritario) -> calculo PLANO sobre TODAS esas actividades SIN pasar por unidad, con el modo del plan: PONDERAR/SUMATORIA -> SUM(nota*PONDERACION)/SUM(PONDERACION) renormalizado sobre las ya calificadas (por eso es proyeccion y no castigo por lo pendiente; en SUMATORIA la PONDERACION ya es derivada de NOTA_MAXIMA, V223), PROMEDIAR / sin modo / suma de pesos 0 -> promedio simple; (c) ELEMENTO=''UNIDADES'' (VALOR=''1'', etiquetado "Instrumentos" en el legacy: confirmado que es el nombre heredado de la UNIDAD del Planeador) -> cada unidad calcula su nota con fn_unidad_calculo_definitiva_modo (V223, misma mecanica del punto (b) acotada a la unidad; las actividades sin unidad forman un bucket propio con promedio simple) y esas notas-de-unidad se combinan entre si; (d) sin configuracion resoluble (no hay TASIGNATURA_PLAN o el elemento es NULL) -> fallback documentado: el mismo camino por unidad de (c). En el modo (c), la combinacion ENTRE unidades usa TUNIDAD.PONDERACION (columna agregada por esta misma migracion, seccion (0): peso de la unidad dentro de su (asignatura, grado), suma <= 100, capturable desde fn_unidad_crear/_actualizar de V216) cuando el modo del plan es PONDERAR/SUMATORIA: SUM(nota_unidad*PONDERACION)/SUM(PONDERACION) renormalizado sobre las unidades ya calificadas. FALLBACK documentado: si a alguna unidad con nota le falta ese peso -- incluido el bucket de actividades sin unidad, que no puede tenerlo -- se cae a PROMEDIO SIMPLE entre unidades, porque ponderar con huecos sesgaria el resultado en silencio. LIMITACIONES DOCUMENTADAS: (1) la fidelidad al motor legacy en la combinacion entre unidades depende de que el docente haya cargado TUNIDAD.PONDERACION en todas ellas; (2) la fila de TASIGNATURA_PLAN se resuelve via fn_asignatura_plan_vigente (grupo -> grado -> plan activo mas reciente), que puede elegir mal en los grados con varios TPLAN activos. NULL si el estudiante no tiene ninguna actividad calificada. NO recibe el rango de fechas ni el buscador: la definitiva no puede cambiar porque el docente filtre la vista. NO persiste nada (STABLE): consolidar TUNIDAD_NOTA es un flujo de cierre de periodo, no un efecto colateral de una lectura. V239.';
