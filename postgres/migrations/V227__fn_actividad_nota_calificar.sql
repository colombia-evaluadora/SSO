-- ===========================================================================
-- V227 — Planeador educativo: motor de calculo de notas de actividad, segun
-- el instrumento de evaluacion ya definido en V226 (RUBRICA / LISTA_COTEJO /
-- ESCALA_VALORACION / OTRO) (CU-86e311xxp — G. Academico Back Planeador
-- educativo).
--
-- Complementa V226 (definicion del instrumento). Alli se define la
-- ESTRUCTURA (criterios/niveles, items, escala); aqui se CAPTURA la
-- calificacion de un estudiante contra esa estructura y se calcula el %
-- final que se guarda en TACTIVIDAD_NOTA.CALIFICACION.
--
-- Modulos:
--   (1) DDL   — FK_TACTIVIDAD_RUBRICA_NIVEL en TACTIVIDAD_RUBRICA_EVALUACION
--               y FK_TACTIVIDAD_ESCALA_NIVEL en TACTIVIDAD_ESCALA_EVALUACION
--               (ver nota "Tablas de captura" abajo).
--   (2) Helpers — fn_actividad_estudiante_actividad (resuelve
--               TACTIVIDAD_ESTUDIANTE -> FK_TACTIVIDAD validando que la
--               asignacion este activa; punto UNICO usado por las 4
--               funciones de calculo, la fachada y el bulk, que antes
--               repetian el mismo SELECT ... IF NOT FOUND),
--               fn_actividad_nota_get_or_create (get-or-create de la fila
--               TACTIVIDAD_NOTA por FK_TACTIVIDAD_ESTUDIANTE),
--               fn_actividad_nota_asistencia_assert (gate de asistencia),
--               fn_actividad_nota_rubrica_recalcular (nota final de rubrica
--               a partir de lo YA capturado; unica definicion del calculo,
--               usada por la version individual y por la bulk) y
--               fn_actividad_nota_cotejo_recalcular (equivalente para lista
--               de cotejo: % = SUM(peso de los items CUMPLIDO='S') /
--               SUM(peso de TODOS los items activos) * 100; tambien unica
--               definicion, compartida por _cotejo y _cotejo_bulk).
--   (3) Calculo por instrumento — fn_actividad_nota_calificar_rubrica,
--               _rubrica_bulk (un criterio + un nivel aplicado a N
--               estudiantes, el flujo real de la pantalla de calificacion),
--               _cotejo, _cotejo_bulk (un item marcado S/N para N
--               estudiantes), _escala, _escala_bulk (un nivel de escala
--               CUALITATIVA para N estudiantes; la NUMERICA no admite bulk),
--               _otro (todas con p_fecha DATE).
--   (4) Fachada y lectura — fn_actividad_nota_calificar (despacha segun el
--               instrumento de la actividad), fn_actividad_nota_obtener
--               (detalle de UN estudiante) y
--               fn_actividad_estudiantes_calificaciones_listar (la tabla
--               completa de la pantalla "Calificaciones: <actividad>":
--               todos los estudiantes con nombre + asistencia del dia +
--               nota).
--
-- -------------------------------------------------------------------------
-- TABLAS DE CAPTURA — se REUTILIZAN, no se crean nuevas.
--
-- V22 ya trae TACTIVIDAD_RUBRICA_EVALUACION, TACTIVIDAD_COTEJO_EVALUACION y
-- TACTIVIDAD_ESCALA_EVALUACION (una fila por criterio/item/escala x
-- TACTIVIDAD_ESTUDIANTE, con UNIQUE que impide duplicados), pensadas
-- exactamente para esto — no hay que inventar tablas nuevas. Se les hacen
-- 2 ajustes minimos via ALTER (las tres tablas estan vacias en todos los
-- ambientes: ningun fn_* las escribia hasta esta migracion):
--
--   * TACTIVIDAD_RUBRICA_EVALUACION solo guardaba la PONDERACION del nivel
--     elegido, sin trazabilidad a CUAL nivel fue (la spec de negocio pide
--     poder saber que nivel selecciono el docente, no solo su peso). Se
--     agrega FK_TACTIVIDAD_RUBRICA_NIVEL (obligatoria en la practica: la
--     exige fn_actividad_nota_calificar_rubrica) y PONDERACION se sigue
--     llenando como snapshot del peso del nivel al momento de calificar
--     (igual que ya hacia la tabla; queda igual si el nivel cambia despues).
--
--   * TACTIVIDAD_ESCALA_EVALUACION mezcla NUMERICA (VALOR = el numero
--     digitado, PONDERACION NULL) y CUALITATIVA (un nivel elegido) en la
--     misma fila, pero tampoco tenia FK al nivel. Se agrega
--     FK_TACTIVIDAD_ESCALA_NIVEL (NULL en NUMERICA, obligatoria en
--     CUALITATIVA). En CUALITATIVA, VALOR se llena con la PONDERACION del
--     nivel elegido (para satisfacer el NOT NULL existente de VALOR de forma
--     consistente: "el valor que califica al estudiante es el peso del
--     nivel"), y PONDERACION queda igual como snapshot del peso.
--
--   * TACTIVIDAD_COTEJO_EVALUACION YA calza perfecto tal cual (CUMPLIDO
--     CHAR(1) S/N, UNIQUE(item, estudiante)): no requiere ALTER. La opcion
--     de "1 fila por item marcado, cumplido implicito" se descarto a favor
--     de "1 fila por item con bandera S/N explicita" porque asi ya la trae
--     V22 y permite distinguir "no marcado todavia" (sin fila) de "marcado
--     como NO cumplido" (fila con CUMPLIDO='N') sin ambiguedad.
--
-- -------------------------------------------------------------------------
-- REGLA DE PORCENTAJE — mismo espiritu que V96
-- (fn_criterio_eval_actualizar / fn_criterio_eval_obtener): el resultado se
-- guarda SIEMPRE como porcentaje (0-100) en TACTIVIDAD_NOTA.CALIFICACION,
-- nunca en la escala visual del periodo/asignatura. V96 convierte en
-- ESCRITURA porque el front le manda la nota ya en la escala del formato;
-- aqui el front no manda una "nota en escala" sino la seleccion cruda
-- (nivel/items/valor), asi que el % se CALCULA aqui mismo a partir de esa
-- seleccion (no hay conversion de formato que hacer en escritura).
--
-- HOMOLOGACION EN LECTURA — fuera de alcance. V96 homologa en lectura
-- contra TASIGNATURA_PLAN.FK_TLV_FORMATO_CALIFICACION_ACT/TESCALA_VALORACION
-- para notas de PERIODO. Para actividades existe una columna analoga
-- (TASIGNATURA_PLAN.FK_TLV_FORMATO_CALIFICACION_ACT), pero resolver la fila
-- de TASIGNATURA_PLAN vigente para una TACTIVIDAD (que plan/periodo aplica)
-- no esta confirmado con negocio y se sale del alcance de esta tarea; se
-- documenta aqui en vez de inventar el join. fn_actividad_nota_obtener
-- retorna el % crudo — homologarlo a la escala visual del periodo es
-- responsabilidad de la capa de lectura/reporte existente.
--
-- ASISTENCIA — gate implementado: no se puede calificar sin asistencia
-- registrada ese dia, ni si esa asistencia es una inasistencia injustificada.
-- TASISTENCIA YA EXISTE en V22 de ESTA rama (no es dependencia cross-branch:
-- PK_TASISTENCIA, FECHA, FK_TLV_TIPO_ASISTENCIA, FK_TASIGNATURA,
-- FK_TPERIODO_EVALUACION, FK_TMATRICULA, OBSERVACION, FK_SOPORTE_ARCHIVO,
-- BLOQUE, ACTIVE), asi que fn_actividad_nota_asistencia_assert (abajo) hace
-- el JOIN/lookup directo contra ella sin problema.
--
-- *** DEPENDENCIA CROSS-BRANCH (deliberada) — mismo criterio que V220 ***
-- Lo que SI vive en otra rama sin mergear
-- (feature/CU-86e32gvpp-G-Academ-Back-Asistencias, V220__sistema_asistencias.sql)
-- es el helper de mas alto nivel que se reutiliza aqui:
--     academico_test.fn_asistencia_tipo_pk(p_valor NUMERIC) RETURNS BIGINT
-- que resuelve el PK_LISTA_VALOR de TLISTA_VALOR CATEGORIA='TIPO_ASISTENCIA'
-- por su VALOR (los pk_lista_valor NO son estables entre ambientes, por eso
-- esa rama centraliza la resolucion por VALOR en vez de hardcodear pks).
-- Valores relevantes: 1=Asistio, 2=NO Asistio (injustificada, la que
-- BLOQUEA), 3=NO Asistio justificada (NO bloquea), 5=Llego tarde,
-- 6=Llego tarde justificada.
--
-- fn_actividad_nota_asistencia_assert es LANGUAGE plpgsql: PostgreSQL NO
-- valida en CREATE FUNCTION los nombres que el cuerpo referencia -- los
-- resuelve en tiempo de EJECUCION -- asi que este archivo APLICA limpio hoy
-- (fn_asistencia_tipo_pk todavia no existe en esta rama) y el gate empieza a
-- operar en cuanto se mergee esa otra rama. Hasta entonces, cualquier
-- llamada real a fn_actividad_nota_calificar_rubrica/_cotejo/_escala/_otro
-- fallara en tiempo de ejecucion con "function ... does not exist" (42883)
-- en vez de silenciarse -- se prefiere fallar cerrado a dejar el gate inerte
-- en silencio.
--
-- p_fecha DATE (nuevo parametro, DEFAULT CURRENT_DATE, en las 4 funciones de
-- calculo y en la fachada): el "dia de clase" que se esta calificando. Por
-- defecto hoy, pero el llamador puede calificar retroactivo pasando una
-- fecha pasada -- el gate de asistencia se evalua contra esa fecha, no
-- contra CURRENT_DATE a secas.
--
-- -------------------------------------------------------------------------
-- Depende de (orden de version de Flyway):
--   * V22  — TACTIVIDAD_ESTUDIANTE, TACTIVIDAD_NOTA, TACTIVIDAD_RUBRICA_*,
--            TACTIVIDAD_COTEJO_*, TACTIVIDAD_ESCALA_*, TASISTENCIA.
--   * V224 — fn_actividad_lv_assert, menu 'PLANEADOR'; V29/V185 —
--            fn_assert_permiso_seccion.
--   * V226 — fn_actividad_instrumento_assert, TIPO_ESCALA, ETIQUETA en
--            niveles.
--   * EN RAMA SIN MERGEAR (resuelta en ejecucion, ver seccion ASISTENCIA
--     arriba) — fn_asistencia_tipo_pk de
--     feature/CU-86e32gvpp-G-Academ-Back-Asistencias V220.
--
-- Estilo: V226 (gate, 22023/23503/P0002, JSONB entrada/salida, fachada por
-- instrumento) y V224 (get-or-create 1:1 tipo fn_actividad_recuperacion_
-- configurar).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ===========================================================================
-- (1) DDL — trazabilidad al nivel elegido (ver nota "Tablas de captura").
-- ===========================================================================

ALTER TABLE TACTIVIDAD_RUBRICA_EVALUACION
  ADD COLUMN IF NOT EXISTS FK_TACTIVIDAD_RUBRICA_NIVEL BIGINT;

ALTER TABLE TACTIVIDAD_RUBRICA_EVALUACION DROP CONSTRAINT IF EXISTS FK_TAC_RUBRICA_EVAL_3;
ALTER TABLE TACTIVIDAD_RUBRICA_EVALUACION ADD CONSTRAINT FK_TAC_RUBRICA_EVAL_3
  FOREIGN KEY (FK_TACTIVIDAD_RUBRICA_NIVEL) REFERENCES TACTIVIDAD_RUBRICA_NIVEL (PK_TACTIVIDAD_RUBRICA_NIVEL) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS IDX_TAC_RUBRICA_EVAL_3 ON TACTIVIDAD_RUBRICA_EVALUACION (FK_TACTIVIDAD_RUBRICA_NIVEL);

COMMENT ON COLUMN TACTIVIDAD_RUBRICA_EVALUACION.FK_TACTIVIDAD_RUBRICA_NIVEL IS
  'Nivel de desempeno seleccionado por el docente para este criterio/estudiante. Obligatoria en la practica (la exige fn_actividad_nota_calificar_rubrica); nullable en DDL para no romper si la tabla ya tuviera filas. PONDERACION queda como snapshot del peso del nivel al momento de calificar. V227.';

ALTER TABLE TACTIVIDAD_ESCALA_EVALUACION
  ADD COLUMN IF NOT EXISTS FK_TACTIVIDAD_ESCALA_NIVEL BIGINT;

ALTER TABLE TACTIVIDAD_ESCALA_EVALUACION DROP CONSTRAINT IF EXISTS FK_TAC_ESCALA_EVAL_3;
ALTER TABLE TACTIVIDAD_ESCALA_EVALUACION ADD CONSTRAINT FK_TAC_ESCALA_EVAL_3
  FOREIGN KEY (FK_TACTIVIDAD_ESCALA_NIVEL) REFERENCES TACTIVIDAD_ESCALA_NIVEL (PK_TACTIVIDAD_ESCALA_NIVEL) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS IDX_TAC_ESCALA_EVAL_3 ON TACTIVIDAD_ESCALA_EVALUACION (FK_TACTIVIDAD_ESCALA_NIVEL);

COMMENT ON COLUMN TACTIVIDAD_ESCALA_EVALUACION.FK_TACTIVIDAD_ESCALA_NIVEL IS
  'Nivel seleccionado por el docente cuando la escala es CUALITATIVA (NULL en escala NUMERICA). En CUALITATIVA, VALOR se llena con la PONDERACION del nivel elegido y PONDERACION queda como snapshot del peso. V227.';

-- ===========================================================================
-- (2) HELPERS
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- fn_actividad_estudiante_actividad — resuelve la actividad de una
-- asignacion actividad-estudiante, exigiendo que la asignacion este ACTIVA.
--
-- Antes este mismo SELECT + IF NOT FOUND estaba copiado en las 4 funciones
-- de calculo y en la fachada (que ademas lo hacia DOS veces: una para
-- decidir el instrumento y otra dentro de la funcion destino). Ahora es un
-- unico punto: mismo mensaje, mismo ERRCODE (P0002), una sola query.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_estudiante_actividad(
    p_pk_tactividad_estudiante BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pk_tactividad BIGINT;
BEGIN
    SELECT ae.FK_TACTIVIDAD INTO v_pk_tactividad
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
       AND ae.ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la asignacion actividad-estudiante solicitada' USING ERRCODE = 'P0002';
    END IF;
    RETURN v_pk_tactividad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_estudiante_actividad(BIGINT)
    IS 'Resuelve TACTIVIDAD_ESTUDIANTE.FK_TACTIVIDAD exigiendo que la asignacion actividad-estudiante exista y este ACTIVE; lanza P0002 con mensaje legible si no. Punto UNICO de esa resolucion: lo usan fn_actividad_nota_calificar_rubrica / _rubrica_bulk / _cotejo / _escala / _otro y la fachada fn_actividad_nota_calificar (que asi ya no resuelve dos veces la misma actividad). V227.';

-- ---------------------------------------------------------------------------
-- get-or-create de la fila de nota (1:1 por TACTIVIDAD_ESTUDIANTE).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_get_or_create(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk BIGINT;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TACTIVIDAD_ESTUDIANTE
         WHERE PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se encontro la asignacion actividad-estudiante solicitada' USING ERRCODE = 'P0002';
    END IF;

    SELECT PK_TACTIVIDAD_NOTA INTO v_pk
      FROM academico_test.TACTIVIDAD_NOTA
     WHERE FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;

    IF v_pk IS NULL THEN
        INSERT INTO academico_test.TACTIVIDAD_NOTA (
            FK_TACTIVIDAD_ESTUDIANTE, CALIFICABLE, CREATED_BY, CREATED_AT, ACTIVE
        ) VALUES (
            p_pk_tactividad_estudiante, 'S', p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
        )
        RETURNING PK_TACTIVIDAD_NOTA INTO v_pk;
    ELSIF NOT (SELECT ACTIVE FROM academico_test.TACTIVIDAD_NOTA WHERE PK_TACTIVIDAD_NOTA = v_pk) THEN
        UPDATE academico_test.TACTIVIDAD_NOTA
           SET ACTIVE = TRUE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD_NOTA = v_pk;
    END IF;

    RETURN v_pk;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_get_or_create(BIGINT, BIGINT)
    IS 'Get-or-create de la fila TACTIVIDAD_NOTA (UK_TACTIVIDAD_NOTA_1 es 1:1 por FK_TACTIVIDAD_ESTUDIANTE): la crea con CALIFICABLE=''S'' si no existe, o la reactiva si estaba inactiva. Valida que la asignacion actividad-estudiante exista y este activa. Helper de fn_actividad_nota_calificar_*. V227.';

-- ---------------------------------------------------------------------------
-- fn_actividad_nota_asistencia_assert — gate de asistencia (ver cabecera,
-- seccion ASISTENCIA, para la dependencia cross-branch de fn_asistencia_tipo_pk).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_asistencia_assert(
    p_pk_tactividad_estudiante BIGINT,
    p_fecha                    DATE
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_matricula  BIGINT;
    v_pk_asignatura BIGINT;
    v_fk_tipo       BIGINT;
BEGIN
    SELECT ae.FK_TMATRICULA, a.FK_TASIGNATURA
      INTO v_pk_matricula, v_pk_asignatura
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
      JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = ae.FK_TACTIVIDAD
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ae.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la asignacion actividad-estudiante solicitada' USING ERRCODE = 'P0002';
    END IF;

    SELECT s.FK_TLV_TIPO_ASISTENCIA INTO v_fk_tipo
      FROM academico_test.TASISTENCIA s
     WHERE s.FK_TMATRICULA = v_pk_matricula
       AND s.FK_TASIGNATURA = v_pk_asignatura
       AND s.FECHA = p_fecha
       AND s.ACTIVE = TRUE
     LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se puede calificar: no hay asistencia registrada para esta asignatura el %', p_fecha
            USING ERRCODE = '22023';
    END IF;

    -- VALOR=2 (NO Asistio, injustificada) bloquea; VALOR=3 (justificada) no.
    IF v_fk_tipo = academico_test.fn_asistencia_tipo_pk(2) THEN
        RAISE EXCEPTION 'No se puede calificar: el estudiante tiene una inasistencia injustificada registrada el %', p_fecha
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_asistencia_assert(BIGINT, DATE)
    IS 'Gate de asistencia: exige que exista un registro ACTIVO en TASISTENCIA para (matricula del estudiante via TACTIVIDAD_ESTUDIANTE, asignatura de la actividad via TACTIVIDAD.FK_TASIGNATURA, FECHA=p_fecha) -- 22023 si no hay ninguno. Si lo hay pero su FK_TLV_TIPO_ASISTENCIA resuelve (via academico_test.fn_asistencia_tipo_pk, dependencia cross-branch de feature/CU-86e32gvpp, ver cabecera) a VALOR=2 (NO Asistio, injustificada), tambien lanza 22023 -- VALOR=3 (justificada) SI permite calificar. Helper de fn_actividad_nota_calificar_*. V227.';

-- ---------------------------------------------------------------------------
-- fn_actividad_nota_rubrica_recalcular — nota final de rubrica a partir de
-- lo YA capturado en TACTIVIDAD_RUBRICA_EVALUACION para ese estudiante.
--
-- Unica definicion del calculo (antes vivia inline en el loop de
-- fn_actividad_nota_calificar_rubrica): por criterio,
--   % = PONDERACION capturada (snapshot del peso del nivel elegido)
--       / MAX(PONDERACION de los niveles ACTIVE de ese criterio) * 100
-- y la nota final es el PROMEDIO SIMPLE de esos % — mismo criterio de
-- negocio de siempre, sin cambios.
--
-- Contrato: retorna NULL si la rubrica todavia NO esta completa (hay menos
-- criterios capturados y activos que criterios activos de la actividad).
-- NULL = "aun no hay nota definitiva", no es un error: el llamador decide si
-- escribe o no en TACTIVIDAD_NOTA. NO escribe nada por si misma (STABLE).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_rubrica_recalcular(
    p_pk_tactividad_estudiante BIGINT
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pk_tactividad   BIGINT;
    v_total_criterios INT;
    v_cubiertos       INT;
    v_pct             NUMERIC(5,2);
BEGIN
    v_pk_tactividad := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);

    SELECT COUNT(*) INTO v_total_criterios
      FROM academico_test.TACTIVIDAD_RUBRICA_CRITERIO
     WHERE FK_TACTIVIDAD = v_pk_tactividad AND ACTIVE = TRUE;

    IF v_total_criterios = 0 THEN
        RETURN NULL;
    END IF;

    SELECT COUNT(*),
           AVG(re.PONDERACION / NULLIF(mx.max_pond, 0) * 100)
      INTO v_cubiertos, v_pct
      FROM academico_test.TACTIVIDAD_RUBRICA_EVALUACION re
      JOIN academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
        ON c.PK_TACTIVIDAD_RUBRICA_CRITERIO = re.FK_TACTIVIDAD_RUBRICA_CRITERIO
       AND c.FK_TACTIVIDAD = v_pk_tactividad
       AND c.ACTIVE = TRUE
      JOIN LATERAL (
          SELECT MAX(n.PONDERACION) AS max_pond
            FROM academico_test.TACTIVIDAD_RUBRICA_NIVEL n
           WHERE n.FK_TACTIVIDAD_RUBRICA_CRITERIO = c.PK_TACTIVIDAD_RUBRICA_CRITERIO
             AND n.ACTIVE = TRUE
      ) mx ON TRUE
     WHERE re.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
       AND re.ACTIVE = TRUE;

    IF v_cubiertos < v_total_criterios THEN
        RETURN NULL;                       -- rubrica incompleta: sin nota definitiva
    END IF;

    RETURN ROUND(v_pct, 2);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_rubrica_recalcular(BIGINT)
    IS 'Nota final (porcentaje 0-100) de la rubrica de un estudiante a partir de lo YA capturado en TACTIVIDAD_RUBRICA_EVALUACION: por criterio % = PONDERACION capturada / MAX(PONDERACION de los niveles ACTIVE de ese criterio) * 100, y el resultado es el promedio simple de esos %. Retorna NULL cuando la rubrica todavia no esta completa (menos criterios capturados activos que criterios ACTIVE de la actividad) o cuando la actividad no tiene criterios -- NULL significa "aun no hay nota definitiva", no es un error. NO escribe: el llamador decide si guarda el valor en TACTIVIDAD_NOTA. Unica definicion del calculo, compartida por fn_actividad_nota_calificar_rubrica y fn_actividad_nota_calificar_rubrica_bulk. V227.';

-- ---------------------------------------------------------------------------
-- fn_actividad_nota_cotejo_recalcular — nota final de lista de cotejo a
-- partir de lo YA capturado en TACTIVIDAD_COTEJO_EVALUACION.
--
-- Mismo criterio que se hizo con fn_actividad_nota_rubrica_recalcular: unica
-- definicion de la formula, compartida por la version individual
-- (fn_actividad_nota_calificar_cotejo) y la bulk (_cotejo_bulk).
--
--   % = SUM(peso de los items con CUMPLIDO='S') / SUM(peso de TODOS los
--       items ACTIVE de la actividad) * 100
--
-- con "peso" = COALESCE(PONDERACION, 1) (items sin ponderacion cuentan como
-- peso 1, ver comentario de fn_actividad_nota_calificar_cotejo).
--
-- DIFERENCIA CLAVE CON RUBRICA: aqui NO existe el concepto de "incompleto".
-- Un item sin fila de captura (o con fila inactiva) cuenta como NO cumplido
-- por diseño — es exactamente lo que ya hacia la version individual, que
-- sumaba en el denominador TODOS los items activos y en el numerador solo
-- los marcados. Por eso esta funcion NUNCA retorna NULL por "faltan items":
-- siempre hay un % valido. Solo retorna NULL si la actividad no tiene items
-- activos (denominador 0), caso que la version individual ademas rechaza
-- explicitamente antes de llegar aqui.
--
-- NO escribe: el llamador decide si guarda el valor en TACTIVIDAD_NOTA
-- (STABLE, igual que la de rubrica).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_cotejo_recalcular(
    p_pk_tactividad_estudiante BIGINT
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pk_tactividad BIGINT;
    v_suma_total    NUMERIC(10,2);
    v_suma_cumplida NUMERIC(10,2);
BEGIN
    v_pk_tactividad := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);

    SELECT SUM(COALESCE(i.PONDERACION, 1)),
           SUM(CASE WHEN ce.CUMPLIDO = 'S' THEN COALESCE(i.PONDERACION, 1) ELSE 0 END)
      INTO v_suma_total, v_suma_cumplida
      FROM academico_test.TACTIVIDAD_COTEJO_ITEM i
      LEFT JOIN academico_test.TACTIVIDAD_COTEJO_EVALUACION ce
             ON ce.FK_TACTIVIDAD_COTEJO_ITEM = i.PK_TACTIVIDAD_COTEJO_ITEM
            AND ce.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
            AND ce.ACTIVE = TRUE
     WHERE i.FK_TACTIVIDAD = v_pk_tactividad AND i.ACTIVE = TRUE;

    IF COALESCE(v_suma_total, 0) = 0 THEN
        RETURN NULL;
    END IF;

    RETURN ROUND(COALESCE(v_suma_cumplida, 0) / v_suma_total * 100, 2);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_cotejo_recalcular(BIGINT)
    IS 'Nota final (porcentaje 0-100) de la lista de cotejo de un estudiante a partir de lo YA capturado en TACTIVIDAD_COTEJO_EVALUACION: % = SUM(peso de los items con CUMPLIDO=''S'') / SUM(peso de TODOS los items ACTIVE de la actividad) * 100, con peso = COALESCE(PONDERACION, 1) (items sin ponderacion cuentan como peso 1). A diferencia de fn_actividad_nota_rubrica_recalcular NO existe el concepto de "captura incompleta": un item sin fila de evaluacion (o con fila inactiva) cuenta como NO cumplido por diseño, asi que siempre hay un % valido; solo retorna NULL si la actividad no tiene items activos (denominador 0). NO escribe: el llamador decide si guarda el valor en TACTIVIDAD_NOTA. Unica definicion del calculo, compartida por fn_actividad_nota_calificar_cotejo y fn_actividad_nota_calificar_cotejo_bulk. V227.';

-- ===========================================================================
-- (3) CALCULO POR INSTRUMENTO
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- fn_actividad_nota_calificar_rubrica
--
-- p_niveles JSONB = [{ "pkCriterio": <pk>, "pkNivel": <pk> }, ...]
--
-- Regla de "todos los criterios cubiertos o parcial": se exige que
-- p_niveles cubra TODOS los criterios activos de la actividad (ni de mas ni
-- de menos) — una rubrica parcial no tiene una nota "justa" sin una regla
-- de negocio explicita para los criterios faltantes (¿cuentan como 0?
-- ¿se excluyen del promedio?), y esa regla no esta confirmada. Se prefiere
-- exigir el set completo y fallar con mensaje claro antes que adivinar.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_actividad_nota_calificar_rubrica(BIGINT, BIGINT, JSONB);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar_rubrica(
    p_pk_usuario_solicitante    BIGINT,
    p_pk_tactividad_estudiante  BIGINT,
    p_niveles                   JSONB,
    p_fecha                     DATE DEFAULT CURRENT_DATE
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_tactividad     BIGINT;
    v_pk_nota           BIGINT;
    v_total_criterios   INT;
    v_cubiertos         INT;
    v_pct_final         NUMERIC(5,2);
    v_elem              JSONB;
    v_pk_criterio       BIGINT;
    v_pk_nivel          BIGINT;
    v_nivel_ponderacion NUMERIC(5,2);
    v_pk_eval_existente BIGINT;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );

    v_pk_tactividad := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);
    PERFORM academico_test.fn_actividad_nota_asistencia_assert(p_pk_tactividad_estudiante, p_fecha);
    PERFORM academico_test.fn_actividad_instrumento_assert(v_pk_tactividad, 'RUBRICA');

    IF p_niveles IS NULL OR jsonb_typeof(p_niveles) <> 'array' OR jsonb_array_length(p_niveles) = 0 THEN
        RAISE EXCEPTION 'p_niveles debe ser un arreglo JSON con al menos un {pkCriterio, pkNivel}'
            USING ERRCODE = '22023';
    END IF;

    SELECT COUNT(*) INTO v_total_criterios
      FROM academico_test.TACTIVIDAD_RUBRICA_CRITERIO
     WHERE FK_TACTIVIDAD = v_pk_tactividad AND ACTIVE = TRUE;

    SELECT COUNT(DISTINCT (e->>'pkCriterio')::BIGINT) INTO v_cubiertos
      FROM jsonb_array_elements(p_niveles) e;

    IF v_cubiertos <> jsonb_array_length(p_niveles) THEN
        RAISE EXCEPTION 'p_niveles tiene criterios repetidos: debe traer un nivel por cada criterio, uno solo'
            USING ERRCODE = '22023';
    END IF;
    IF v_cubiertos <> v_total_criterios THEN
        RAISE EXCEPTION 'La rubrica tiene % criterio(s) activo(s) pero se calificaron % — deben cubrirse todos',
            v_total_criterios, v_cubiertos USING ERRCODE = '22023';
    END IF;

    v_pk_nota := academico_test.fn_actividad_nota_get_or_create(p_pk_usuario_solicitante, p_pk_tactividad_estudiante);

    -- Reemplazo completo de la captura previa (mismo espiritu de "reemplazo
    -- completo" que fn_actividad_rubrica_definir en V226).
    UPDATE academico_test.TACTIVIDAD_RUBRICA_EVALUACION re
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
     WHERE re.FK_TACTIVIDAD_RUBRICA_CRITERIO = c.PK_TACTIVIDAD_RUBRICA_CRITERIO
       AND c.FK_TACTIVIDAD = v_pk_tactividad
       AND re.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
       AND re.ACTIVE = TRUE;

    FOR v_elem IN SELECT * FROM jsonb_array_elements(p_niveles) LOOP
        v_pk_criterio := (v_elem->>'pkCriterio')::BIGINT;
        v_pk_nivel    := (v_elem->>'pkNivel')::BIGINT;

        IF NOT EXISTS (
            SELECT 1 FROM academico_test.TACTIVIDAD_RUBRICA_CRITERIO
             WHERE PK_TACTIVIDAD_RUBRICA_CRITERIO = v_pk_criterio
               AND FK_TACTIVIDAD = v_pk_tactividad AND ACTIVE = TRUE
        ) THEN
            RAISE EXCEPTION 'El criterio % no pertenece a la rubrica de esta actividad', v_pk_criterio
                USING ERRCODE = '22023';
        END IF;

        SELECT PONDERACION INTO v_nivel_ponderacion
          FROM academico_test.TACTIVIDAD_RUBRICA_NIVEL
         WHERE PK_TACTIVIDAD_RUBRICA_NIVEL = v_pk_nivel
           AND FK_TACTIVIDAD_RUBRICA_CRITERIO = v_pk_criterio AND ACTIVE = TRUE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El nivel % no pertenece al criterio % de esta rubrica', v_pk_nivel, v_pk_criterio
                USING ERRCODE = '22023';
        END IF;

        -- Upsert manual: UN_TAC_RUBRICA_EVAL_1 es DEFERRABLE INITIALLY DEFERRED
        -- y por eso no sirve como arbitro de ON CONFLICT (mismo motivo que
        -- fn_actividad_escala_definir en V226 hace upsert manual).
        SELECT PK_TACTIVIDAD_RUBRICA_EVAL INTO v_pk_eval_existente
          FROM academico_test.TACTIVIDAD_RUBRICA_EVALUACION
         WHERE FK_TACTIVIDAD_RUBRICA_CRITERIO = v_pk_criterio
           AND FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;

        IF v_pk_eval_existente IS NULL THEN
            INSERT INTO academico_test.TACTIVIDAD_RUBRICA_EVALUACION (
                FK_TACTIVIDAD_RUBRICA_CRITERIO, FK_TACTIVIDAD_ESTUDIANTE, FK_TACTIVIDAD_RUBRICA_NIVEL,
                PONDERACION, CREATED_BY, CREATED_AT, ACTIVE
            ) VALUES (
                v_pk_criterio, p_pk_tactividad_estudiante, v_pk_nivel,
                v_nivel_ponderacion, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
            );
        ELSE
            UPDATE academico_test.TACTIVIDAD_RUBRICA_EVALUACION
               SET FK_TACTIVIDAD_RUBRICA_NIVEL = v_pk_nivel,
                   PONDERACION                 = v_nivel_ponderacion,
                   ACTIVE                       = TRUE,
                   MODIFIED_BY                  = p_pk_usuario_solicitante::VARCHAR,
                   MODIFIED_AT                  = CURRENT_TIMESTAMP
             WHERE PK_TACTIVIDAD_RUBRICA_EVAL = v_pk_eval_existente;
        END IF;
    END LOOP;

    -- Nota final: unica definicion del calculo, compartida con la version
    -- bulk (ver fn_actividad_nota_rubrica_recalcular). Aqui nunca puede
    -- volver NULL: mas arriba se exigio cubrir TODOS los criterios activos.
    v_pct_final := academico_test.fn_actividad_nota_rubrica_recalcular(p_pk_tactividad_estudiante);

    UPDATE academico_test.TACTIVIDAD_NOTA
       SET CALIFICACION = v_pct_final, CALIFICABLE = 'S',
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD_NOTA = v_pk_nota;

    RETURN v_pct_final;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar_rubrica(BIGINT, BIGINT, JSONB, DATE)
    IS 'Califica a un estudiante con la rubrica de su actividad: p_niveles = [{pkCriterio, pkNivel}], UNO por cada criterio ACTIVO de la actividad (se exige el set completo; no hay regla de negocio confirmada para rubricas parciales). p_fecha (DEFAULT CURRENT_DATE) es el dia de clase que se califica: se exige asistencia registrada y no injustificada para esa fecha (fn_actividad_nota_asistencia_assert). Por criterio: % = ponderacion del nivel elegido / MAX(ponderacion de los niveles de ese criterio) * 100. Nota final = promedio simple de esos %. Reemplazo completo de TACTIVIDAD_RUBRICA_EVALUACION para ese estudiante y upsert de TACTIVIDAD_NOTA.CALIFICACION (guardado como porcentaje 0-100, ver cabecera). Gate EDITAR sobre PLANEADOR. V227.';

-- ---------------------------------------------------------------------------
-- fn_actividad_nota_calificar_rubrica_bulk — UN criterio + UN nivel aplicado
-- a VARIOS estudiantes de una vez.
--
-- Es el flujo real de la pantalla de calificacion por rubrica: el docente
-- elige una columna ("Diseño: Excelente"), marca con checkbox a N
-- estudiantes y aplica. fn_actividad_nota_calificar_rubrica (arriba) exige
-- el set COMPLETO de criterios en una sola llamada — util para el detalle de
-- un estudiante, incompatible con este flujo por columna. Las dos conviven:
-- comparten helpers, gate y formula.
--
-- Se toca UNA fila de TACTIVIDAD_RUBRICA_EVALUACION por estudiante (la de
-- ESE criterio). Lo ya capturado en los OTROS criterios de ese estudiante NO
-- se toca — a diferencia de la version individual, que hace reemplazo
-- completo.
--
-- CONTRATO DE SALIDA (decision de diseño): una fila por estudiante del
-- array, con criterios_totales / criterios_cubiertos y:
--   * calificacion_actualizada = TRUE  -> el estudiante ya tiene los N
--     criterios activos cubiertos: se recalculo y se guardo `calificacion`
--     (% 0-100) en TACTIVIDAD_NOTA.
--   * calificacion_actualizada = FALSE -> el criterio se guardo bien, pero
--     al estudiante aun le faltan criterios por cubrir: `calificacion` viene
--     NULL y TACTIVIDAD_NOTA.CALIFICACION queda como estaba. NO es un error
--     (es el caso normal mientras el docente recorre columna por columna);
--     se devuelve como informacion para que el cliente pueda pintar
--     "faltan X de Y criterios" sin una segunda consulta.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar_rubrica_bulk(
    p_pk_usuario_solicitante    BIGINT,
    p_pk_tactividad             BIGINT,
    p_pk_criterio               BIGINT,
    p_pk_nivel                  BIGINT,
    p_pk_tactividad_estudiante  BIGINT[],
    p_fecha                     DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    pk_tactividad_estudiante  BIGINT,
    criterios_totales         INT,
    criterios_cubiertos       INT,
    calificacion              NUMERIC,
    calificacion_actualizada  BOOLEAN
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_nivel_ponderacion NUMERIC(5,2);
    v_total_criterios   INT;
    v_pk_est            BIGINT;
    v_pk_nota           BIGINT;
    v_pk_eval_existente BIGINT;
    v_pct               NUMERIC(5,2);
    v_cubiertos         INT;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );

    IF p_pk_tactividad_estudiante IS NULL
       OR COALESCE(array_length(p_pk_tactividad_estudiante, 1), 0) = 0 THEN
        RAISE EXCEPTION 'p_pk_tactividad_estudiante debe traer al menos un estudiante' USING ERRCODE = '22023';
    END IF;

    PERFORM academico_test.fn_actividad_instrumento_assert(p_pk_tactividad, 'RUBRICA');

    -- El criterio pertenece a la rubrica de ESTA actividad (misma validacion
    -- que la version individual).
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TACTIVIDAD_RUBRICA_CRITERIO
         WHERE PK_TACTIVIDAD_RUBRICA_CRITERIO = p_pk_criterio
           AND FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'El criterio % no pertenece a la rubrica de esta actividad', p_pk_criterio
            USING ERRCODE = '22023';
    END IF;

    -- Y el nivel a ESE criterio.
    SELECT PONDERACION INTO v_nivel_ponderacion
      FROM academico_test.TACTIVIDAD_RUBRICA_NIVEL
     WHERE PK_TACTIVIDAD_RUBRICA_NIVEL = p_pk_nivel
       AND FK_TACTIVIDAD_RUBRICA_CRITERIO = p_pk_criterio AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El nivel % no pertenece al criterio % de esta rubrica', p_pk_nivel, p_pk_criterio
            USING ERRCODE = '22023';
    END IF;

    SELECT COUNT(*) INTO v_total_criterios
      FROM academico_test.TACTIVIDAD_RUBRICA_CRITERIO
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;

    FOREACH v_pk_est IN ARRAY p_pk_tactividad_estudiante LOOP
        -- Cada estudiante debe pertenecer a ESTA actividad (el helper valida
        -- ademas que la asignacion este activa).
        IF academico_test.fn_actividad_estudiante_actividad(v_pk_est) <> p_pk_tactividad THEN
            RAISE EXCEPTION 'La asignacion actividad-estudiante % no pertenece a la actividad %', v_pk_est, p_pk_tactividad
                USING ERRCODE = '22023';
        END IF;

        PERFORM academico_test.fn_actividad_nota_asistencia_assert(v_pk_est, p_fecha);

        v_pk_nota := academico_test.fn_actividad_nota_get_or_create(p_pk_usuario_solicitante, v_pk_est);

        -- Upsert manual de la UNICA fila (criterio, estudiante): los demas
        -- criterios ya capturados de ese estudiante NO se tocan.
        SELECT PK_TACTIVIDAD_RUBRICA_EVAL INTO v_pk_eval_existente
          FROM academico_test.TACTIVIDAD_RUBRICA_EVALUACION
         WHERE FK_TACTIVIDAD_RUBRICA_CRITERIO = p_pk_criterio
           AND FK_TACTIVIDAD_ESTUDIANTE = v_pk_est;

        IF v_pk_eval_existente IS NULL THEN
            INSERT INTO academico_test.TACTIVIDAD_RUBRICA_EVALUACION (
                FK_TACTIVIDAD_RUBRICA_CRITERIO, FK_TACTIVIDAD_ESTUDIANTE, FK_TACTIVIDAD_RUBRICA_NIVEL,
                PONDERACION, CREATED_BY, CREATED_AT, ACTIVE
            ) VALUES (
                p_pk_criterio, v_pk_est, p_pk_nivel,
                v_nivel_ponderacion, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
            );
        ELSE
            UPDATE academico_test.TACTIVIDAD_RUBRICA_EVALUACION
               SET FK_TACTIVIDAD_RUBRICA_NIVEL = p_pk_nivel,
                   PONDERACION                 = v_nivel_ponderacion,
                   ACTIVE                      = TRUE,
                   MODIFIED_BY                 = p_pk_usuario_solicitante::VARCHAR,
                   MODIFIED_AT                 = CURRENT_TIMESTAMP
             WHERE PK_TACTIVIDAD_RUBRICA_EVAL = v_pk_eval_existente;
        END IF;

        -- ¿Ya tiene todos los criterios? (misma formula, un solo sitio).
        SELECT COUNT(*) INTO v_cubiertos
          FROM academico_test.TACTIVIDAD_RUBRICA_EVALUACION re
          JOIN academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
            ON c.PK_TACTIVIDAD_RUBRICA_CRITERIO = re.FK_TACTIVIDAD_RUBRICA_CRITERIO
         WHERE re.FK_TACTIVIDAD_ESTUDIANTE = v_pk_est
           AND re.ACTIVE = TRUE
           AND c.FK_TACTIVIDAD = p_pk_tactividad
           AND c.ACTIVE = TRUE;

        v_pct := academico_test.fn_actividad_nota_rubrica_recalcular(v_pk_est);

        IF v_pct IS NOT NULL THEN
            UPDATE academico_test.TACTIVIDAD_NOTA
               SET CALIFICACION = v_pct, CALIFICABLE = 'S',
                   MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
             WHERE PK_TACTIVIDAD_NOTA = v_pk_nota;
        END IF;

        pk_tactividad_estudiante := v_pk_est;
        criterios_totales        := v_total_criterios;
        criterios_cubiertos      := v_cubiertos;
        calificacion             := v_pct;
        calificacion_actualizada := (v_pct IS NOT NULL);
        RETURN NEXT;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar_rubrica_bulk(BIGINT, BIGINT, BIGINT, BIGINT, BIGINT[], DATE)
    IS 'Calificacion BULK por rubrica: aplica UN criterio + UN nivel a VARIOS estudiantes de la misma actividad (el flujo real de la pantalla: el docente elige la columna "Criterio: Nivel" y la aplica a los estudiantes marcados). Valida gate EDITAR sobre PLANEADOR, que la actividad tenga instrumento RUBRICA (fn_actividad_instrumento_assert), que el criterio pertenezca a esa rubrica y el nivel a ese criterio, que cada TACTIVIDAD_ESTUDIANTE pertenezca a ESA actividad y este activo (fn_actividad_estudiante_actividad) y la asistencia de cada uno para p_fecha (fn_actividad_nota_asistencia_assert). Hace upsert de UNA sola fila de TACTIVIDAD_RUBRICA_EVALUACION por estudiante (la de ese criterio): NO toca lo ya capturado en los otros criterios -- a diferencia de fn_actividad_nota_calificar_rubrica, que exige el set completo y hace reemplazo total. Devuelve una fila por estudiante {pk_tactividad_estudiante, criterios_totales, criterios_cubiertos, calificacion, calificacion_actualizada}: calificacion_actualizada=TRUE significa que ese estudiante ya cubrio los N criterios activos, se recalculo con fn_actividad_nota_rubrica_recalcular y se guardo el % en TACTIVIDAD_NOTA.CALIFICACION; FALSE significa que el criterio quedo guardado pero aun faltan criterios (calificacion=NULL, la nota NO se toca) -- caso normal e informativo, no un error. V227.';

-- ---------------------------------------------------------------------------
-- fn_actividad_nota_calificar_cotejo
--
-- p_items_marcados BIGINT[] = PKs de TACTIVIDAD_COTEJO_ITEM cumplidos.
--
-- Regla de items sin PONDERACION (V226 la dejo opcional y ambigua cuando se
-- mezclan con items ponderados): se tratan como peso 1 tanto en el
-- numerador (si estan marcados) como en el denominador (siempre), es decir
-- "cuentan igual entre si, y se sinergizan con los que si tienen peso"
-- -- exactamente lo que ya explica el COMMENT de V226 sobre PONDERACION
-- ("todos los items sin peso cuentan igual").
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_actividad_nota_calificar_cotejo(BIGINT, BIGINT, BIGINT[]);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar_cotejo(
    p_pk_usuario_solicitante    BIGINT,
    p_pk_tactividad_estudiante  BIGINT,
    p_items_marcados            BIGINT[],
    p_fecha                     DATE DEFAULT CURRENT_DATE
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_tactividad BIGINT;
    v_pk_nota       BIGINT;
    v_total_items   INT;
    v_pct_final     NUMERIC(5,2);
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );

    v_pk_tactividad := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);
    PERFORM academico_test.fn_actividad_nota_asistencia_assert(p_pk_tactividad_estudiante, p_fecha);
    PERFORM academico_test.fn_actividad_instrumento_assert(v_pk_tactividad, 'LISTA_COTEJO');

    SELECT COUNT(*) INTO v_total_items
      FROM academico_test.TACTIVIDAD_COTEJO_ITEM
     WHERE FK_TACTIVIDAD = v_pk_tactividad AND ACTIVE = TRUE;
    IF v_total_items = 0 THEN
        RAISE EXCEPTION 'La lista de cotejo de esta actividad no tiene items definidos' USING ERRCODE = '22023';
    END IF;

    IF p_items_marcados IS NOT NULL AND EXISTS (
        SELECT 1 FROM unnest(p_items_marcados) m(pk)
         WHERE NOT EXISTS (
             SELECT 1 FROM academico_test.TACTIVIDAD_COTEJO_ITEM
              WHERE PK_TACTIVIDAD_COTEJO_ITEM = m.pk AND FK_TACTIVIDAD = v_pk_tactividad AND ACTIVE = TRUE
         )
    ) THEN
        RAISE EXCEPTION 'p_items_marcados contiene un item que no pertenece a la lista de cotejo de esta actividad'
            USING ERRCODE = '22023';
    END IF;

    v_pk_nota := academico_test.fn_actividad_nota_get_or_create(p_pk_usuario_solicitante, p_pk_tactividad_estudiante);

    -- Reemplazo completo: 1 fila por item, CUMPLIDO='S' si vino en el arreglo, 'N' si no.
    -- Upsert manual (UPDATE + INSERT de faltantes) porque UN_TAC_COTEJO_EVAL_1
    -- es DEFERRABLE INITIALLY DEFERRED y no sirve como arbitro de ON CONFLICT
    -- (mismo motivo documentado en fn_actividad_nota_calificar_rubrica).
    UPDATE academico_test.TACTIVIDAD_COTEJO_EVALUACION ce
       SET CUMPLIDO    = CASE WHEN ce.FK_TACTIVIDAD_COTEJO_ITEM = ANY (COALESCE(p_items_marcados, ARRAY[]::BIGINT[])) THEN 'S' ELSE 'N' END,
           ACTIVE       = TRUE,
           MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT  = CURRENT_TIMESTAMP
      FROM academico_test.TACTIVIDAD_COTEJO_ITEM i
     WHERE i.PK_TACTIVIDAD_COTEJO_ITEM = ce.FK_TACTIVIDAD_COTEJO_ITEM
       AND i.FK_TACTIVIDAD = v_pk_tactividad AND i.ACTIVE = TRUE
       AND ce.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;

    INSERT INTO academico_test.TACTIVIDAD_COTEJO_EVALUACION (
        FK_TACTIVIDAD_COTEJO_ITEM, FK_TACTIVIDAD_ESTUDIANTE, CUMPLIDO, CREATED_BY, CREATED_AT, ACTIVE
    )
    SELECT i.PK_TACTIVIDAD_COTEJO_ITEM, p_pk_tactividad_estudiante,
           CASE WHEN i.PK_TACTIVIDAD_COTEJO_ITEM = ANY (COALESCE(p_items_marcados, ARRAY[]::BIGINT[])) THEN 'S' ELSE 'N' END,
           p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
      FROM academico_test.TACTIVIDAD_COTEJO_ITEM i
     WHERE i.FK_TACTIVIDAD = v_pk_tactividad AND i.ACTIVE = TRUE
       AND NOT EXISTS (
           SELECT 1 FROM academico_test.TACTIVIDAD_COTEJO_EVALUACION ce
            WHERE ce.FK_TACTIVIDAD_COTEJO_ITEM = i.PK_TACTIVIDAD_COTEJO_ITEM
              AND ce.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
       );

    -- Nota final: unica definicion del calculo, compartida con la version
    -- bulk (ver fn_actividad_nota_cotejo_recalcular). Se lee de lo que se
    -- acaba de escribir en TACTIVIDAD_COTEJO_EVALUACION (1 fila por item con
    -- CUMPLIDO S/N explicito), no del arreglo de entrada: mismo resultado y
    -- una sola formula. Aqui nunca puede volver NULL: mas arriba se rechazo
    -- la actividad sin items activos.
    v_pct_final := academico_test.fn_actividad_nota_cotejo_recalcular(p_pk_tactividad_estudiante);

    UPDATE academico_test.TACTIVIDAD_NOTA
       SET CALIFICACION = v_pct_final, CALIFICABLE = 'S',
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD_NOTA = v_pk_nota;

    RETURN v_pct_final;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar_cotejo(BIGINT, BIGINT, BIGINT[], DATE)
    IS 'Califica a un estudiante con la lista de cotejo de su actividad: p_items_marcados = PKs de TACTIVIDAD_COTEJO_ITEM cumplidos (puede ser vacio/NULL = nada cumplido). p_fecha (DEFAULT CURRENT_DATE) es el dia de clase que se califica: se exige asistencia registrada y no injustificada para esa fecha (fn_actividad_nota_asistencia_assert). Hace reemplazo completo de TACTIVIDAD_COTEJO_EVALUACION (1 fila por item ACTIVE de la actividad, CUMPLIDO S/N explicito) y luego calcula el % con fn_actividad_nota_cotejo_recalcular (unica definicion de la formula, compartida con fn_actividad_nota_calificar_cotejo_bulk): % = SUM(peso de los items cumplidos) / SUM(peso de TODOS los items) * 100, tratando los items SIN ponderacion (V226, columna opcional) como peso 1 tanto en el numerador como en el denominador. Guarda el resultado en TACTIVIDAD_NOTA.CALIFICACION (porcentaje 0-100). Gate EDITAR sobre PLANEADOR. V227.';

-- ---------------------------------------------------------------------------
-- fn_actividad_nota_calificar_cotejo_bulk — UN item marcado como cumplido /
-- no cumplido para VARIOS estudiantes de una vez.
--
-- Mismo espiritu que fn_actividad_nota_calificar_rubrica_bulk (el docente
-- recorre la lista item por item y marca a los estudiantes que lo cumplen),
-- con dos diferencias respecto a la rubrica:
--
--   * Se toca UNA sola fila de TACTIVIDAD_COTEJO_EVALUACION por estudiante
--     (la de ESE item). Lo ya capturado en los otros items NO se toca — a
--     diferencia de fn_actividad_nota_calificar_cotejo, que hace reemplazo
--     completo de todos los items.
--
--   * SIEMPRE recalcula y guarda TACTIVIDAD_NOTA.CALIFICACION en la misma
--     pasada (no hay "calificacion_actualizada = FALSE" como en rubrica):
--     el cotejo NO exige tener todos los items cubiertos, porque un item sin
--     fila de captura ya cuenta como NO cumplido por el diseño existente de
--     la version individual (denominador = TODOS los items activos). Asi que
--     tras marcar un solo item ya hay un % valido y definitivo-hasta-ahora.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar_cotejo_bulk(
    p_pk_usuario_solicitante    BIGINT,
    p_pk_tactividad             BIGINT,
    p_pk_item                   BIGINT,
    p_cumplido                  CHAR(1),
    p_pk_tactividad_estudiante  BIGINT[],
    p_fecha                     DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    pk_tactividad_estudiante  BIGINT,
    items_totales             INT,
    items_cumplidos           INT,
    calificacion              NUMERIC
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_items       INT;
    v_pk_est            BIGINT;
    v_pk_nota           BIGINT;
    v_pk_eval_existente BIGINT;
    v_pct               NUMERIC(5,2);
    v_cumplidos         INT;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );

    IF p_pk_tactividad_estudiante IS NULL
       OR COALESCE(array_length(p_pk_tactividad_estudiante, 1), 0) = 0 THEN
        RAISE EXCEPTION 'p_pk_tactividad_estudiante debe traer al menos un estudiante' USING ERRCODE = '22023';
    END IF;

    IF p_cumplido IS NULL OR p_cumplido NOT IN ('S', 'N') THEN
        RAISE EXCEPTION 'p_cumplido debe ser ''S'' (cumplido) o ''N'' (no cumplido)' USING ERRCODE = '22023';
    END IF;

    PERFORM academico_test.fn_actividad_instrumento_assert(p_pk_tactividad, 'LISTA_COTEJO');

    -- El item pertenece a la lista de cotejo de ESTA actividad (misma
    -- validacion que hace la version individual sobre p_items_marcados).
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TACTIVIDAD_COTEJO_ITEM
         WHERE PK_TACTIVIDAD_COTEJO_ITEM = p_pk_item
           AND FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'El item % no pertenece a la lista de cotejo de esta actividad', p_pk_item
            USING ERRCODE = '22023';
    END IF;

    SELECT COUNT(*) INTO v_total_items
      FROM academico_test.TACTIVIDAD_COTEJO_ITEM
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;

    FOREACH v_pk_est IN ARRAY p_pk_tactividad_estudiante LOOP
        IF academico_test.fn_actividad_estudiante_actividad(v_pk_est) <> p_pk_tactividad THEN
            RAISE EXCEPTION 'La asignacion actividad-estudiante % no pertenece a la actividad %', v_pk_est, p_pk_tactividad
                USING ERRCODE = '22023';
        END IF;

        PERFORM academico_test.fn_actividad_nota_asistencia_assert(v_pk_est, p_fecha);

        v_pk_nota := academico_test.fn_actividad_nota_get_or_create(p_pk_usuario_solicitante, v_pk_est);

        -- Upsert manual de la UNICA fila (item, estudiante): UN_TAC_COTEJO_EVAL_1
        -- es DEFERRABLE INITIALLY DEFERRED y no sirve como arbitro de ON CONFLICT.
        SELECT PK_TACTIVIDAD_COTEJO_EVAL INTO v_pk_eval_existente
          FROM academico_test.TACTIVIDAD_COTEJO_EVALUACION
         WHERE FK_TACTIVIDAD_COTEJO_ITEM = p_pk_item
           AND FK_TACTIVIDAD_ESTUDIANTE = v_pk_est;

        IF v_pk_eval_existente IS NULL THEN
            INSERT INTO academico_test.TACTIVIDAD_COTEJO_EVALUACION (
                FK_TACTIVIDAD_COTEJO_ITEM, FK_TACTIVIDAD_ESTUDIANTE, CUMPLIDO,
                CREATED_BY, CREATED_AT, ACTIVE
            ) VALUES (
                p_pk_item, v_pk_est, p_cumplido,
                p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
            );
        ELSE
            UPDATE academico_test.TACTIVIDAD_COTEJO_EVALUACION
               SET CUMPLIDO    = p_cumplido,
                   ACTIVE      = TRUE,
                   MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
                   MODIFIED_AT = CURRENT_TIMESTAMP
             WHERE PK_TACTIVIDAD_COTEJO_EVAL = v_pk_eval_existente;
        END IF;

        SELECT COUNT(*) INTO v_cumplidos
          FROM academico_test.TACTIVIDAD_COTEJO_EVALUACION ce
          JOIN academico_test.TACTIVIDAD_COTEJO_ITEM i
            ON i.PK_TACTIVIDAD_COTEJO_ITEM = ce.FK_TACTIVIDAD_COTEJO_ITEM
         WHERE ce.FK_TACTIVIDAD_ESTUDIANTE = v_pk_est
           AND ce.ACTIVE = TRUE AND ce.CUMPLIDO = 'S'
           AND i.FK_TACTIVIDAD = p_pk_tactividad
           AND i.ACTIVE = TRUE;

        -- Siempre hay % valido (ver comentario de la funcion): se guarda en
        -- la misma pasada, sin esperar a que se cubran los demas items.
        v_pct := academico_test.fn_actividad_nota_cotejo_recalcular(v_pk_est);

        UPDATE academico_test.TACTIVIDAD_NOTA
           SET CALIFICACION = v_pct, CALIFICABLE = 'S',
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD_NOTA = v_pk_nota;

        pk_tactividad_estudiante := v_pk_est;
        items_totales            := v_total_items;
        items_cumplidos          := v_cumplidos;
        calificacion             := v_pct;
        RETURN NEXT;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar_cotejo_bulk(BIGINT, BIGINT, BIGINT, CHAR, BIGINT[], DATE)
    IS 'Calificacion BULK por lista de cotejo: marca UN item como cumplido (p_cumplido=''S'') o no cumplido (''N'') para VARIOS estudiantes de la misma actividad (el flujo real de la pantalla: el docente recorre la lista item por item). Valida gate EDITAR sobre PLANEADOR, que la actividad tenga instrumento LISTA_COTEJO (fn_actividad_instrumento_assert), que el item pertenezca a esa lista, que cada TACTIVIDAD_ESTUDIANTE pertenezca a ESA actividad y este activo (fn_actividad_estudiante_actividad) y la asistencia de cada uno para p_fecha (fn_actividad_nota_asistencia_assert). Hace upsert de UNA sola fila de TACTIVIDAD_COTEJO_EVALUACION por estudiante (la de ese item): NO toca los demas items ya capturados -- a diferencia de fn_actividad_nota_calificar_cotejo, que hace reemplazo completo. A diferencia de fn_actividad_nota_calificar_rubrica_bulk, SIEMPRE recalcula (fn_actividad_nota_cotejo_recalcular) y guarda TACTIVIDAD_NOTA.CALIFICACION en la misma pasada, porque el cotejo NO exige cubrir todos los items: un item sin fila de captura ya cuenta como NO cumplido por diseño. Devuelve una fila por estudiante {pk_tactividad_estudiante, items_totales, items_cumplidos, calificacion}. V227.';

-- ---------------------------------------------------------------------------
-- fn_actividad_nota_calificar_escala
--
-- Exactamente uno de p_pk_nivel (CUALITATIVA) / p_valor_numerico (NUMERICA)
-- segun FK_TLV_TIPO_ESCALA de la escala de la actividad.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_actividad_nota_calificar_escala(BIGINT, BIGINT, BIGINT, NUMERIC);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar_escala(
    p_pk_usuario_solicitante    BIGINT,
    p_pk_tactividad_estudiante  BIGINT,
    p_pk_nivel                  BIGINT  DEFAULT NULL,
    p_valor_numerico             NUMERIC DEFAULT NULL,
    p_fecha                      DATE    DEFAULT CURRENT_DATE
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_tactividad   BIGINT;
    v_pk_nota         BIGINT;
    v_pk_escala       BIGINT;
    v_tipo_val        VARCHAR;
    v_min             NUMERIC(5,2);
    v_max             NUMERIC(5,2);
    v_nivel_pond      NUMERIC(5,2);
    v_max_pond        NUMERIC(5,2);
    v_pct_final       NUMERIC(5,2);
    v_pk_eval_existente BIGINT;
    v_valor_final     NUMERIC(5,2);
    v_pond_final      NUMERIC(5,2);
    v_nivel_final     BIGINT;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );

    v_pk_tactividad := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);
    PERFORM academico_test.fn_actividad_nota_asistencia_assert(p_pk_tactividad_estudiante, p_fecha);
    PERFORM academico_test.fn_actividad_instrumento_assert(v_pk_tactividad, 'ESCALA_VALORACION');

    SELECT e.PK_TACTIVIDAD_ESCALA, lv.VALOR, e.VALOR_MIN, e.VALOR_MAX
      INTO v_pk_escala, v_tipo_val, v_min, v_max
      FROM academico_test.TACTIVIDAD_ESCALA e
      JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = e.FK_TLV_TIPO_ESCALA
     WHERE e.FK_TACTIVIDAD = v_pk_tactividad AND e.ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La actividad no tiene una escala de valoracion definida (use fn_actividad_escala_definir primero)'
            USING ERRCODE = '22023';
    END IF;

    IF (p_pk_nivel IS NOT NULL) = (p_valor_numerico IS NOT NULL) THEN
        RAISE EXCEPTION 'Debe indicarse exactamente uno de pkNivel (escala CUALITATIVA) o valorNumerico (escala NUMERICA)'
            USING ERRCODE = '22023';
    END IF;

    v_pk_nota := academico_test.fn_actividad_nota_get_or_create(p_pk_usuario_solicitante, p_pk_tactividad_estudiante);

    IF v_tipo_val = 'CUALITATIVA' THEN
        IF p_pk_nivel IS NULL THEN
            RAISE EXCEPTION 'La escala de esta actividad es CUALITATIVA: se requiere pkNivel' USING ERRCODE = '22023';
        END IF;

        SELECT PONDERACION INTO v_nivel_pond
          FROM academico_test.TACTIVIDAD_ESCALA_NIVEL
         WHERE PK_TACTIVIDAD_ESCALA_NIVEL = p_pk_nivel
           AND FK_TACTIVIDAD_ESCALA = v_pk_escala AND ACTIVE = TRUE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El nivel % no pertenece a la escala de esta actividad', p_pk_nivel
                USING ERRCODE = '22023';
        END IF;

        SELECT MAX(PONDERACION) INTO v_max_pond
          FROM academico_test.TACTIVIDAD_ESCALA_NIVEL
         WHERE FK_TACTIVIDAD_ESCALA = v_pk_escala AND ACTIVE = TRUE;

        v_pct_final := ROUND(v_nivel_pond / NULLIF(v_max_pond, 0) * 100, 2);
        v_nivel_final := p_pk_nivel;
        v_valor_final := v_nivel_pond;
        v_pond_final  := v_nivel_pond;

    ELSE  -- NUMERICA
        IF p_valor_numerico IS NULL THEN
            RAISE EXCEPTION 'La escala de esta actividad es NUMERICA: se requiere valorNumerico' USING ERRCODE = '22023';
        END IF;
        IF v_min IS NULL OR v_max IS NULL THEN
            RAISE EXCEPTION 'La escala NUMERICA de esta actividad no tiene valorMin/valorMax definidos' USING ERRCODE = '22023';
        END IF;
        IF p_valor_numerico < v_min OR p_valor_numerico > v_max THEN
            RAISE EXCEPTION 'valorNumerico (%) debe estar entre % y %', p_valor_numerico, v_min, v_max
                USING ERRCODE = '22023';
        END IF;

        v_pct_final := ROUND((p_valor_numerico - v_min) / NULLIF(v_max - v_min, 0) * 100, 2);
        v_nivel_final := NULL;
        v_valor_final := p_valor_numerico;
        v_pond_final  := NULL;
    END IF;

    -- Upsert manual (UN_TAC_ESCALA_EVAL_1 es DEFERRABLE INITIALLY DEFERRED,
    -- no sirve como arbitro de ON CONFLICT; mismo motivo que en rubrica/cotejo).
    SELECT PK_TACTIVIDAD_ESCALA_EVAL INTO v_pk_eval_existente
      FROM academico_test.TACTIVIDAD_ESCALA_EVALUACION
     WHERE FK_TACTIVIDAD_ESCALA = v_pk_escala AND FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;

    IF v_pk_eval_existente IS NULL THEN
        INSERT INTO academico_test.TACTIVIDAD_ESCALA_EVALUACION (
            FK_TACTIVIDAD_ESCALA, FK_TACTIVIDAD_ESTUDIANTE, FK_TACTIVIDAD_ESCALA_NIVEL,
            VALOR, PONDERACION, CREATED_BY, CREATED_AT, ACTIVE
        ) VALUES (
            v_pk_escala, p_pk_tactividad_estudiante, v_nivel_final,
            v_valor_final, v_pond_final, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
        );
    ELSE
        UPDATE academico_test.TACTIVIDAD_ESCALA_EVALUACION
           SET FK_TACTIVIDAD_ESCALA_NIVEL = v_nivel_final,
               VALOR                       = v_valor_final,
               PONDERACION                 = v_pond_final,
               ACTIVE                       = TRUE,
               MODIFIED_BY                  = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT                  = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD_ESCALA_EVAL = v_pk_eval_existente;
    END IF;

    UPDATE academico_test.TACTIVIDAD_NOTA
       SET CALIFICACION = v_pct_final, CALIFICABLE = 'S',
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD_NOTA = v_pk_nota;

    RETURN v_pct_final;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar_escala(BIGINT, BIGINT, BIGINT, NUMERIC, DATE)
    IS 'Califica a un estudiante con la escala de valoracion de su actividad. Exactamente uno de p_pk_nivel (CUALITATIVA: % = ponderacion del nivel / MAX ponderacion de la escala * 100) o p_valor_numerico (NUMERICA, dentro de [VALOR_MIN,VALOR_MAX]: % = (valor - min)/(max - min) * 100). p_fecha (DEFAULT CURRENT_DATE) es el dia de clase que se califica: se exige asistencia registrada y no injustificada para esa fecha (fn_actividad_nota_asistencia_assert). Upsert de TACTIVIDAD_ESCALA_EVALUACION (1:1 por estudiante, UN_TAC_ESCALA_EVAL_1) y de TACTIVIDAD_NOTA.CALIFICACION (porcentaje 0-100). Gate EDITAR sobre PLANEADOR. V227.';

-- ---------------------------------------------------------------------------
-- fn_actividad_nota_calificar_escala_bulk — UN nivel de la escala
-- CUALITATIVA aplicado a VARIOS estudiantes de una vez.
--
-- Mismo espiritu que _rubrica_bulk / _cotejo_bulk, pero la escala es 1:1 por
-- estudiante (UN_TAC_ESCALA_EVAL_1): no existe el concepto de "faltan otros
-- niveles/items", asi que SIEMPRE se recalcula y se guarda la nota en la
-- misma pasada.
--
-- SOLO CUALITATIVA: si la escala de la actividad es NUMERICA se rechaza —
-- un valor numerico es por definicion individual por estudiante, no hay
-- "nivel" comun que aplicar en bloque.
--
-- DECISION DE DISEÑO (reutilizacion): en vez de duplicar el calculo
-- (% = ponderacion del nivel / MAX ponderacion de la escala * 100) y el
-- upsert de TACTIVIDAD_ESCALA_EVALUACION, esta funcion DELEGA por estudiante
-- en fn_actividad_nota_calificar_escala (la individual), que ya hace gate,
-- asistencia, instrumento assert, validacion del nivel contra la escala de
-- la actividad, upsert y escritura de TACTIVIDAD_NOTA. No se extrajo un
-- helper "_escala_recalcular" separado como en rubrica/cotejo porque ahi el
-- helper existe para poder leer una captura PARCIAL ya guardada (varias
-- filas por estudiante); en escala la captura es una sola fila y el % se
-- deriva por completo de los parametros de entrada, asi que no hay formula
-- que compartir con nadie mas: llamar a la individual ya es el unico punto.
-- Se pagan N llamadas (una por estudiante) a cambio de cero duplicacion de
-- reglas — el universo es el grupo de una actividad, no un catalogo.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar_escala_bulk(
    p_pk_usuario_solicitante    BIGINT,
    p_pk_tactividad             BIGINT,
    p_pk_nivel                  BIGINT,
    p_pk_tactividad_estudiante  BIGINT[],
    p_fecha                     DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    pk_tactividad_estudiante  BIGINT,
    calificacion              NUMERIC
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_tipo_val VARCHAR;
    v_pk_est   BIGINT;
    v_pct      NUMERIC(5,2);
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );

    IF p_pk_tactividad_estudiante IS NULL
       OR COALESCE(array_length(p_pk_tactividad_estudiante, 1), 0) = 0 THEN
        RAISE EXCEPTION 'p_pk_tactividad_estudiante debe traer al menos un estudiante' USING ERRCODE = '22023';
    END IF;

    IF p_pk_nivel IS NULL THEN
        RAISE EXCEPTION 'p_pk_nivel es obligatorio: la calificacion bulk aplica UN nivel de la escala a varios estudiantes'
            USING ERRCODE = '22023';
    END IF;

    PERFORM academico_test.fn_actividad_instrumento_assert(p_pk_tactividad, 'ESCALA_VALORACION');

    SELECT lv.VALOR INTO v_tipo_val
      FROM academico_test.TACTIVIDAD_ESCALA e
      JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = e.FK_TLV_TIPO_ESCALA
     WHERE e.FK_TACTIVIDAD = p_pk_tactividad AND e.ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La actividad no tiene una escala de valoracion definida (use fn_actividad_escala_definir primero)'
            USING ERRCODE = '22023';
    END IF;

    IF v_tipo_val <> 'CUALITATIVA' THEN
        RAISE EXCEPTION 'la escala NUMERICA no admite calificacion bulk por nivel — cada estudiante requiere su propio valor numerico, use fn_actividad_nota_calificar_escala individual'
            USING ERRCODE = '22023';
    END IF;

    FOREACH v_pk_est IN ARRAY p_pk_tactividad_estudiante LOOP
        IF academico_test.fn_actividad_estudiante_actividad(v_pk_est) <> p_pk_tactividad THEN
            RAISE EXCEPTION 'La asignacion actividad-estudiante % no pertenece a la actividad %', v_pk_est, p_pk_tactividad
                USING ERRCODE = '22023';
        END IF;

        -- Delegacion (ver DECISION DE DISEÑO arriba): la individual valida
        -- asistencia, el nivel contra la escala, hace el upsert y escribe la
        -- nota. Aqui no se recalcula nada por cuenta propia.
        v_pct := academico_test.fn_actividad_nota_calificar_escala(
                     p_pk_usuario_solicitante, v_pk_est, p_pk_nivel, NULL, p_fecha);

        pk_tactividad_estudiante := v_pk_est;
        calificacion             := v_pct;
        RETURN NEXT;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar_escala_bulk(BIGINT, BIGINT, BIGINT, BIGINT[], DATE)
    IS 'Calificacion BULK por escala de valoracion CUALITATIVA: aplica UN nivel a VARIOS estudiantes de la misma actividad. Si la escala de la actividad es NUMERICA rechaza con 22023 ("la escala NUMERICA no admite calificacion bulk por nivel..."): un valor numerico es por definicion individual por estudiante. Valida gate EDITAR sobre PLANEADOR, instrumento ESCALA_VALORACION (fn_actividad_instrumento_assert) y que cada TACTIVIDAD_ESTUDIANTE pertenezca a ESA actividad (fn_actividad_estudiante_actividad); luego DELEGA por estudiante en fn_actividad_nota_calificar_escala, que ya valida la asistencia de p_fecha, comprueba el nivel contra la escala, hace el upsert de TACTIVIDAD_ESCALA_EVALUACION (1:1) y guarda el % en TACTIVIDAD_NOTA. No se extrajo un helper de recalculo (como si se hizo en rubrica/cotejo) porque la escala guarda UNA sola fila por estudiante y el % se deriva por completo de los parametros de entrada: no hay captura parcial que releer ni formula que compartir. Al ser 1:1, SIEMPRE recalcula y guarda la nota en la misma pasada. Devuelve una fila por estudiante {pk_tactividad_estudiante, calificacion}. V227.';

-- ---------------------------------------------------------------------------
-- fn_actividad_nota_calificar_otro — sin calculo automatico.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_actividad_nota_calificar_otro(BIGINT, BIGINT, NUMERIC);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar_otro(
    p_pk_usuario_solicitante    BIGINT,
    p_pk_tactividad_estudiante  BIGINT,
    p_porcentaje                 NUMERIC,
    p_fecha                      DATE DEFAULT CURRENT_DATE
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_tactividad BIGINT;
    v_pk_nota       BIGINT;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );

    v_pk_tactividad := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);
    PERFORM academico_test.fn_actividad_nota_asistencia_assert(p_pk_tactividad_estudiante, p_fecha);
    PERFORM academico_test.fn_actividad_instrumento_assert(v_pk_tactividad, 'OTRO');

    IF p_porcentaje IS NULL OR p_porcentaje < 0 OR p_porcentaje > 100 THEN
        RAISE EXCEPTION 'p_porcentaje debe estar entre 0 y 100' USING ERRCODE = '22023';
    END IF;

    v_pk_nota := academico_test.fn_actividad_nota_get_or_create(p_pk_usuario_solicitante, p_pk_tactividad_estudiante);

    UPDATE academico_test.TACTIVIDAD_NOTA
       SET CALIFICACION = ROUND(p_porcentaje, 2), CALIFICABLE = 'S',
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD_NOTA = v_pk_nota;

    RETURN ROUND(p_porcentaje, 2);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar_otro(BIGINT, BIGINT, NUMERIC, DATE)
    IS 'Instrumento OTRO (sin estructura, V226): NO hay calculo automatico. p_fecha (DEFAULT CURRENT_DATE) es el dia de clase que se califica: se exige asistencia registrada y no injustificada para esa fecha (fn_actividad_nota_asistencia_assert). Guarda directo el % (0-100) que manda el llamador en TACTIVIDAD_NOTA.CALIFICACION; el calculo/criterio es responsabilidad del cliente (DESCRIPCION_INSTRUMENTO). Gate EDITAR sobre PLANEADOR. V227.';

-- ===========================================================================
-- (4) FACHADA — despacha segun el instrumento de la actividad + lectura.
-- ===========================================================================
DROP FUNCTION IF EXISTS academico_test.fn_actividad_nota_calificar(BIGINT, BIGINT, JSONB);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar(
    p_pk_usuario_solicitante    BIGINT,
    p_pk_tactividad_estudiante  BIGINT,
    p_calificacion               JSONB,
    p_fecha                      DATE DEFAULT CURRENT_DATE
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_tactividad BIGINT;
    v_valor         VARCHAR;
    v_pct           NUMERIC(5,2);
BEGIN
    -- Resolucion UNICA de la actividad (antes se resolvia aqui y otra vez
    -- dentro de la funcion destino): las funciones de calculo llaman al mismo
    -- helper, que revalida en O(1) por PK.
    v_pk_tactividad := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);

    SELECT lv.VALOR INTO v_valor
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
     WHERE a.PK_TACTIVIDAD = v_pk_tactividad;

    IF p_calificacion IS NULL OR jsonb_typeof(p_calificacion) <> 'object' THEN
        RAISE EXCEPTION 'p_calificacion debe ser un objeto JSON' USING ERRCODE = '22023';
    END IF;

    CASE v_valor
        WHEN 'RUBRICA' THEN
            v_pct := academico_test.fn_actividad_nota_calificar_rubrica(
                         p_pk_usuario_solicitante, p_pk_tactividad_estudiante, p_calificacion->'niveles', p_fecha);
        WHEN 'LISTA_COTEJO' THEN
            v_pct := academico_test.fn_actividad_nota_calificar_cotejo(
                         p_pk_usuario_solicitante, p_pk_tactividad_estudiante,
                         ARRAY(SELECT jsonb_array_elements_text(COALESCE(p_calificacion->'itemsMarcados', '[]'::jsonb))::BIGINT),
                         p_fecha);
        WHEN 'ESCALA_VALORACION' THEN
            v_pct := academico_test.fn_actividad_nota_calificar_escala(
                         p_pk_usuario_solicitante, p_pk_tactividad_estudiante,
                         (p_calificacion->>'pkNivel')::BIGINT, (p_calificacion->>'valorNumerico')::NUMERIC, p_fecha);
        WHEN 'OTRO' THEN
            v_pct := academico_test.fn_actividad_nota_calificar_otro(
                         p_pk_usuario_solicitante, p_pk_tactividad_estudiante,
                         (p_calificacion->>'porcentaje')::NUMERIC, p_fecha);
        ELSE
            RAISE EXCEPTION 'La actividad no tiene un instrumento de evaluacion valido para calificar (%)',
                COALESCE(v_valor, 'sin instrumento') USING ERRCODE = '22023';
    END CASE;

    RETURN v_pct;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar(BIGINT, BIGINT, JSONB, DATE)
    IS 'Fachada: lee el instrumento de la actividad (via TACTIVIDAD_ESTUDIANTE.FK_TACTIVIDAD) y despacha a fn_actividad_nota_calificar_rubrica ({niveles:[{pkCriterio,pkNivel}]}), _cotejo ({itemsMarcados:[pk,...]}), _escala ({pkNivel} o {valorNumerico}) u _otro ({porcentaje}), pasando p_fecha (DEFAULT CURRENT_DATE, el dia de clase que se califica; el gate de asistencia se aplica contra ella, ver cabecera). Calcula (salvo OTRO) y guarda el % (0-100) en TACTIVIDAD_NOTA.CALIFICACION. Gate EDITAR sobre PLANEADOR (via las funciones destino). V227.';

-- ---------------------------------------------------------------------------
-- fn_actividad_nota_obtener — lectura de la nota + detalle de captura.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_obtener(
    p_pk_usuario_solicitante    BIGINT,
    p_pk_tactividad_estudiante  BIGINT
)
RETURNS TABLE (
    instrumento         VARCHAR,
    calificacion        NUMERIC,
    calificable         CHAR(1),
    observacion         VARCHAR,
    detalle             JSONB
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TACTIVIDAD_ESTUDIANTE
         WHERE PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se encontro la asignacion actividad-estudiante solicitada' USING ERRCODE = 'P0002';
    END IF;

    RETURN QUERY
    SELECT lv.VALOR,
           n.CALIFICACION,
           n.CALIFICABLE,
           n.OBSERVACION,
           CASE lv.VALOR
               WHEN 'RUBRICA' THEN COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'pkCriterio',  re.FK_TACTIVIDAD_RUBRICA_CRITERIO,
                              'pkNivel',     re.FK_TACTIVIDAD_RUBRICA_NIVEL,
                              'ponderacion', re.PONDERACION))
                     FROM academico_test.TACTIVIDAD_RUBRICA_EVALUACION re
                     JOIN academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
                       ON c.PK_TACTIVIDAD_RUBRICA_CRITERIO = re.FK_TACTIVIDAD_RUBRICA_CRITERIO
                    WHERE re.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                      AND re.ACTIVE = TRUE AND c.FK_TACTIVIDAD = a.PK_TACTIVIDAD
               ), '[]'::jsonb)

               WHEN 'LISTA_COTEJO' THEN COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'pkItem',   ce.FK_TACTIVIDAD_COTEJO_ITEM,
                              'cumplido', ce.CUMPLIDO))
                     FROM academico_test.TACTIVIDAD_COTEJO_EVALUACION ce
                     JOIN academico_test.TACTIVIDAD_COTEJO_ITEM i
                       ON i.PK_TACTIVIDAD_COTEJO_ITEM = ce.FK_TACTIVIDAD_COTEJO_ITEM
                    WHERE ce.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                      AND ce.ACTIVE = TRUE AND i.FK_TACTIVIDAD = a.PK_TACTIVIDAD
               ), '[]'::jsonb)

               WHEN 'ESCALA_VALORACION' THEN (
                   SELECT jsonb_build_object(
                              'pkNivel',      ee.FK_TACTIVIDAD_ESCALA_NIVEL,
                              'valor',        ee.VALOR,
                              'ponderacion',  ee.PONDERACION)
                     FROM academico_test.TACTIVIDAD_ESCALA_EVALUACION ee
                     JOIN academico_test.TACTIVIDAD_ESCALA e ON e.PK_TACTIVIDAD_ESCALA = ee.FK_TACTIVIDAD_ESCALA
                    WHERE ee.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                      AND ee.ACTIVE = TRUE AND e.FK_TACTIVIDAD = a.PK_TACTIVIDAD
               )

               ELSE NULL
           END
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
      JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = ae.FK_TACTIVIDAD
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
      LEFT JOIN academico_test.TACTIVIDAD_NOTA n
             ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE AND n.ACTIVE = TRUE
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_obtener(BIGINT, BIGINT)
    IS 'Lee la nota de un estudiante para una actividad: instrumento aplicado, CALIFICACION (porcentaje 0-100, SIN homologar a la escala visual del periodo/asignatura — eso es responsabilidad de la capa de lectura/reporte existente, ver cabecera de V227), CALIFICABLE, OBSERVACION y el detalle de captura segun el instrumento (RUBRICA: [{pkCriterio,pkNivel,ponderacion}]; LISTA_COTEJO: [{pkItem,cumplido}]; ESCALA_VALORACION: {pkNivel,valor,ponderacion}; OTRO/sin captura estructurada: NULL). Gate VER sobre PLANEADOR. Es el DETALLE de UN estudiante; para la tabla completa de la pantalla use fn_actividad_estudiantes_calificaciones_listar. V227.';

-- ---------------------------------------------------------------------------
-- fn_actividad_estudiantes_calificaciones_listar — la tabla de la pantalla
-- "Calificaciones: <actividad>": una fila por estudiante asignado, con
-- NOMBRES + ASISTENCIA del dia + NOTA.
--
-- Relacion con fn_actividad_nota_obtener: aquella es el DETALLE de UN
-- estudiante (incluye el detalle de captura completo del instrumento, para
-- el modal/panel de calificacion individual); esta es el LISTADO de la
-- pantalla, que necesita a TODOS los estudiantes y ademas la asistencia del
-- dia — dato que la de detalle no trae. No se fusionan a proposito: el
-- detalle de captura por instrumento en un listado seria N subconsultas por
-- fila para informacion que la tabla no pinta.
--
-- ASISTENCIA: mismo lookup que fn_actividad_nota_asistencia_assert
-- (matricula del estudiante via TACTIVIDAD_ESTUDIANTE.FK_TMATRICULA,
-- asignatura via TACTIVIDAD.FK_TASIGNATURA, FECHA = p_fecha) pero de SOLO
-- LECTURA: si no hay registro NO lanza excepcion, las columnas de asistencia
-- vienen NULL ("sin registrar", que es como la pantalla lo pinta). El NOMBRE
-- del tipo sale de TLISTA_VALOR.NOMBRE, resuelto por JOIN directo — aqui no
-- hace falta fn_asistencia_tipo_pk (la dependencia cross-branch descrita en
-- la cabecera) porque no se compara contra ningun VALOR concreto, solo se
-- muestra lo que haya. Se devuelven ademas los datos CRUDOS
-- (fk_tlv_tipo_asistencia, observacion, fk_soporte_archivo) para que el
-- cliente arme el texto "Justificada..." y el icono de adjunto: la
-- redaccion exacta de la UI no se replica aqui.
--
-- Sin paginacion: el universo ya esta acotado a los estudiantes de UNA
-- actividad (normalmente un grupo). p_search filtra por nombre con ILIKE
-- simple por el mismo motivo (no amerita un indice trgm nuevo).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_estudiantes_calificaciones_listar(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_tactividad           BIGINT,
    p_fecha                   DATE    DEFAULT CURRENT_DATE,
    p_search                  VARCHAR DEFAULT NULL
)
RETURNS TABLE (
    pk_tactividad_estudiante  BIGINT,
    pk_tmatricula             BIGINT,
    nombre_estudiante         VARCHAR,
    instrumento               VARCHAR,
    fecha                     DATE,
    pk_tasistencia            BIGINT,
    fk_tlv_tipo_asistencia    BIGINT,
    tipo_asistencia           VARCHAR,
    asistencia_observacion    VARCHAR,
    fk_soporte_archivo        BIGINT,
    calificacion              NUMERIC,
    calificable               CHAR(1),
    nota_observacion          VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pk_asignatura BIGINT;
    v_instrumento   VARCHAR;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    SELECT a.FK_TASIGNATURA, lv.VALOR
      INTO v_pk_asignatura, v_instrumento
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad AND a.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;

    RETURN QUERY
    WITH base AS (
        SELECT ae.PK_TACTIVIDAD_ESTUDIANTE,
               ae.FK_TMATRICULA,
               NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                          u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)), '')::VARCHAR AS nombre
          FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
          JOIN academico_test.TMATRICULA m   ON m.PK_TMATRICULA = ae.FK_TMATRICULA
          JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO = es.FK_TUSUARIO
         WHERE ae.FK_TACTIVIDAD = p_pk_tactividad
           AND ae.ACTIVE = TRUE
    )
    SELECT b.PK_TACTIVIDAD_ESTUDIANTE,
           b.FK_TMATRICULA,
           b.nombre,
           v_instrumento,
           p_fecha,
           s.PK_TASISTENCIA,
           s.FK_TLV_TIPO_ASISTENCIA,
           lva.NOMBRE::VARCHAR,
           s.OBSERVACION,
           s.FK_SOPORTE_ARCHIVO,
           n.CALIFICACION,
           n.CALIFICABLE,
           n.OBSERVACION
      FROM base b
      LEFT JOIN LATERAL (
          SELECT s2.PK_TASISTENCIA, s2.FK_TLV_TIPO_ASISTENCIA, s2.OBSERVACION, s2.FK_SOPORTE_ARCHIVO
            FROM academico_test.TASISTENCIA s2
           WHERE s2.FK_TMATRICULA  = b.FK_TMATRICULA
             AND s2.FK_TASIGNATURA = v_pk_asignatura
             AND s2.FECHA          = p_fecha
             AND s2.ACTIVE = TRUE
           ORDER BY s2.PK_TASISTENCIA DESC
           LIMIT 1
      ) s ON TRUE
      LEFT JOIN academico_test.TLISTA_VALOR lva ON lva.PK_LISTA_VALOR = s.FK_TLV_TIPO_ASISTENCIA
      LEFT JOIN academico_test.TACTIVIDAD_NOTA n
             ON n.FK_TACTIVIDAD_ESTUDIANTE = b.PK_TACTIVIDAD_ESTUDIANTE AND n.ACTIVE = TRUE
     WHERE p_search IS NULL
        OR TRIM(p_search) = ''
        OR b.nombre ILIKE '%' || TRIM(p_search) || '%'
     ORDER BY b.nombre, b.PK_TACTIVIDAD_ESTUDIANTE;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_estudiantes_calificaciones_listar(BIGINT, BIGINT, DATE, VARCHAR)
    IS 'Lectura que alimenta la TABLA de la pantalla "Calificaciones: <actividad>": una fila por cada TACTIVIDAD_ESTUDIANTE ACTIVO de la actividad con (a) el nombre completo del estudiante (TACTIVIDAD_ESTUDIANTE -> TMATRICULA -> TESTUDIANTE -> TUSUARIO), (b) la asistencia de p_fecha (DEFAULT CURRENT_DATE) buscada igual que fn_actividad_nota_asistencia_assert (matricula + TACTIVIDAD.FK_TASIGNATURA + FECHA) pero de SOLO LECTURA: si no hay registro NO lanza excepcion y pk_tasistencia/fk_tlv_tipo_asistencia/tipo_asistencia/asistencia_observacion/fk_soporte_archivo vienen NULL ("sin registrar"); se devuelven los datos crudos para que el cliente arme el texto "Justificada..." y el icono de adjunto, (c) la nota de TACTIVIDAD_NOTA (LEFT JOIN: puede no existir todavia) y (d) el instrumento de la actividad repetido por fila, para evitarle al cliente una segunda consulta. p_search filtra por nombre con ILIKE simple; sin paginacion (el universo ya esta acotado a una actividad). Ordena por nombre. Distinta de fn_actividad_nota_obtener, que es el DETALLE de UN estudiante e incluye el detalle de captura completo del instrumento. Gate VER sobre PLANEADOR. V227.';
