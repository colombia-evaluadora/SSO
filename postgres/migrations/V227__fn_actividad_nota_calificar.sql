-- ===========================================================================
-- V227 - Calificacion de actividades: columnas y FKs de rubrica/escala, las
-- funciones de calificar por instrumento que siguen vigentes y el endpoint de
-- valoraciones. Escala, bulk, calificar, obtener, listado de calificaciones,
-- fn_nota_homologar y valoraciones de unidad viven en V241-V484.
-- ===========================================================================


SET search_path TO academico_test, public;

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

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_grado_resolver(
    p_pk_tactividad BIGINT
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(u.FK_TGRADO, g.FK_TGRADO)
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TUNIDAD u ON u.PK_TUNIDAD = a.FK_TUNIDAD
      LEFT JOIN academico_test.TGRUPO  g ON g.PK_TGRUPO  = a.FK_TGRUPO
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_grado_resolver(BIGINT)
    IS 'Grado al que pertenece una actividad. TACTIVIDAD no tiene FK_TGRADO propia, asi que se resuelve por prioridad: (1) TUNIDAD.FK_TGRADO via TACTIVIDAD.FK_TUNIDAD -- fuente preferida, la unidad es la que define el contexto academico (asignatura+grado) en el que se planeo la actividad; (2) si no tiene unidad, TGRUPO.FK_TGRADO via TACTIVIDAD.FK_TGRUPO; (3) NULL si no tiene ninguna de las dos, caso posible desde V218 (ambas FK nullable) y que NO es un error. No exige ACTIVE en unidad/grupo: se resuelve el contexto historico de una actividad ya creada y desactivar una unidad no debe cambiar en silencio con que limites se califica. Helper interno (no gatea permisos), usado por fn_actividad_nota_ajustar_por_criterio. V227.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_ajustar_por_criterio(
    p_pk_tactividad BIGINT,
    p_valor         NUMERIC
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_fk_tgrado        BIGINT;
    v_fk_tasignatura   BIGINT;
    v_es_recuperacion  CHAR(1);
    v_pk_criterio      BIGINT;
    v_piso             NUMERIC;
    v_tope             NUMERIC;
    v_valor            NUMERIC := p_valor;
BEGIN
    IF v_valor IS NULL THEN
        RETURN NULL;                       -- "aun no hay nota": nada que acotar
    END IF;

    SELECT a.FK_TASIGNATURA, a.ES_RECUPERACION
      INTO v_fk_tasignatura, v_es_recuperacion
      FROM academico_test.TACTIVIDAD a
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;

    v_fk_tgrado := academico_test.fn_actividad_grado_resolver(p_pk_tactividad);

    -- Sin grado (actividad sin unidad NI grupo, posible desde V218) o sin
    -- asignatura no hay con que resolver el criterio: se guarda tal cual.
    IF v_fk_tgrado IS NULL OR v_fk_tasignatura IS NULL THEN
        RETURN v_valor;
    END IF;

    v_pk_criterio := academico_test.fn_asignatura_criterio_evaluacion_vigente(
                         v_fk_tasignatura, v_fk_tgrado);
    IF v_pk_criterio IS NULL THEN
        RETURN v_valor;                    -- sin criterios configurados
    END IF;

    -- 1) TOPE, solo para actividades de recuperacion.
    IF v_es_recuperacion = 'S' THEN
        v_tope := academico_test.fn_criterio_evaluacion_porcentaje_maximo_recuperacion(v_pk_criterio);
        IF v_tope IS NOT NULL THEN
            v_valor := LEAST(v_valor, v_tope);
        END IF;
    END IF;

    -- 2) PISO, para CUALQUIER actividad (incluida una recuperacion ya topada:
    --    por eso va despues; ver la cabecera).
    v_piso := academico_test.fn_criterio_evaluacion_porcentaje_inicial(v_pk_criterio);
    IF v_piso IS NOT NULL THEN
        v_valor := GREATEST(v_valor, v_piso);
    END IF;

    RETURN v_valor;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_ajustar_por_criterio(BIGINT, NUMERIC)
    IS 'Punto UNICO donde se aplican a una calificacion los dos limites que el colegio configura en TCRITERIO_EVALUACION (V22 + V62), ambos ya guardados como porcentaje 0-100 (sin conversion de escala): el TOPE (PORCENTAJE_MAXIMO_RECUPERACION, "Nota maxima de recuperacion") y el PISO (PORCENTAJE_INICIAL_CALIF, "Nota inicial para las calificaciones"). Resuelve el grado de la actividad con fn_actividad_grado_resolver (unidad primero, grupo despues) y el criterio con fn_asignatura_criterio_evaluacion_vigente (V239). ORDEN: primero LEAST(valor, tope) y SOLO si TACTIVIDAD.ES_RECUPERACION=''S'' -- el tope acota hasta donde puede llegar una recuperacion --, y despues GREATEST(valor, piso) para CUALQUIER actividad -- el minimo institucional debe poder levantar tambien una recuperacion ya topada, por eso va al final. Si el colegio configura piso > tope (inconsistencia de configuracion, no un caso de negocio) gana el piso; no se valida ni se lanza error, calificar no es el sitio para bloquear al docente por eso. NUNCA falla por falta de configuracion: si la actividad no tiene grado resoluble (sin unidad NI grupo, posible desde V218), no hay TASIGNATURA_PLAN, no hay TCRITERIO_EVALUACION o los porcentajes son NULL, devuelve el valor intacto. p_valor NULL entra y sale NULL ("aun no hay nota", caso de la rubrica incompleta): no se levanta al piso. No redondea: piso y tope no pueden aportar mas decimales de los que ya traia el valor. Helper interno, no gatea permisos. Lo invocan fn_actividad_nota_rubrica_recalcular, fn_actividad_nota_cotejo_recalcular, fn_actividad_nota_calificar_escala y fn_actividad_nota_calificar_otro -- los cuatro unicos caminos por los que se escribe TACTIVIDAD_NOTA.CALIFICACION. V227.';

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

    -- Piso/tope institucionales SOBRE el valor ya redondeado a 2 decimales
    -- (ver seccion "PISO Y TOPE" de la cabecera): el ajuste no puede aportar
    -- mas decimales, y aplicarlo aqui -- y no en los llamadores -- garantiza
    -- que la nota que se guarda y la que se devuelve sean la misma en las dos
    -- rutas (individual y bulk).
    RETURN academico_test.fn_actividad_nota_ajustar_por_criterio(
               v_pk_tactividad, ROUND(v_pct, 2));
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_rubrica_recalcular(BIGINT)
    IS 'Nota final (porcentaje 0-100) de la rubrica de un estudiante a partir de lo YA capturado en TACTIVIDAD_RUBRICA_EVALUACION: por criterio % = PONDERACION capturada / MAX(PONDERACION de los niveles ACTIVE de ese criterio) * 100, y el resultado es el promedio simple de esos %. Retorna NULL cuando la rubrica todavia no esta completa (menos criterios capturados activos que criterios ACTIVE de la actividad) o cuando la actividad no tiene criterios -- NULL significa "aun no hay nota definitiva", no es un error. Antes de retornar aplica el piso/tope institucional con fn_actividad_nota_ajustar_por_criterio (TCRITERIO_EVALUACION: tope de recuperacion si ES_RECUPERACION=''S'', luego piso PORCENTAJE_INICIAL_CALIF), sobre el valor ya redondeado a 2 decimales -- los limites son porcentajes de configuracion, no aportan mas decimales. El ajuste vive aqui y no en los llamadores para que individual y bulk guarden y devuelvan exactamente el mismo numero. NO escribe: el llamador decide si guarda el valor en TACTIVIDAD_NOTA. Unica definicion del calculo, compartida por fn_actividad_nota_calificar_rubrica y fn_actividad_nota_calificar_rubrica_bulk. V227.';

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

    -- Piso/tope institucionales, mismo criterio que en rubrica: sobre el valor
    -- ya redondeado y dentro del recalculo, para que individual y bulk lo
    -- apliquen por igual (ver seccion "PISO Y TOPE" de la cabecera).
    RETURN academico_test.fn_actividad_nota_ajustar_por_criterio(
               v_pk_tactividad,
               ROUND(COALESCE(v_suma_cumplida, 0) / v_suma_total * 100, 2));
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_cotejo_recalcular(BIGINT)
    IS 'Nota final (porcentaje 0-100) de la lista de cotejo de un estudiante a partir de lo YA capturado en TACTIVIDAD_COTEJO_EVALUACION: % = SUM(peso de los items con CUMPLIDO=''S'') / SUM(peso de TODOS los items ACTIVE de la actividad) * 100, con peso = COALESCE(PONDERACION, 1) (items sin ponderacion cuentan como peso 1). A diferencia de fn_actividad_nota_rubrica_recalcular NO existe el concepto de "captura incompleta": un item sin fila de evaluacion (o con fila inactiva) cuenta como NO cumplido por diseño, asi que siempre hay un % valido; solo retorna NULL si la actividad no tiene items activos (denominador 0). Antes de retornar aplica el piso/tope institucional con fn_actividad_nota_ajustar_por_criterio (TCRITERIO_EVALUACION: tope de recuperacion si ES_RECUPERACION=''S'', luego piso PORCENTAJE_INICIAL_CALIF) sobre el valor ya redondeado a 2 decimales; igual que en rubrica, el ajuste vive dentro del recalculo para que la version individual y la bulk lo apliquen por igual. NO escribe: el llamador decide si guarda el valor en TACTIVIDAD_NOTA. Unica definicion del calculo, compartida por fn_actividad_nota_calificar_cotejo y fn_actividad_nota_calificar_cotejo_bulk. V227.';

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
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, NULL, NULL, academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante)
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

    -- Consolida la recuperacion sobre su destino, si esta actividad lo es (V408).
    PERFORM academico_test.fn_actividad_recuperacion_aplicar(
                p_pk_usuario_solicitante, p_pk_tactividad_estudiante);

    RETURN v_pct_final;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar_rubrica(BIGINT, BIGINT, JSONB, DATE)
    IS 'Califica a un estudiante con la rubrica de su actividad: p_niveles = [{pkCriterio, pkNivel}], UNO por cada criterio ACTIVO de la actividad (se exige el set completo; no hay regla de negocio confirmada para rubricas parciales). p_fecha (DEFAULT CURRENT_DATE) es el dia de clase que se califica: se exige asistencia registrada y no injustificada para esa fecha (fn_actividad_nota_asistencia_assert). Por criterio: % = ponderacion del nivel elegido / MAX(ponderacion de los niveles de ese criterio) * 100. Nota final = promedio simple de esos %. Reemplazo completo de TACTIVIDAD_RUBRICA_EVALUACION para ese estudiante y upsert de TACTIVIDAD_NOTA.CALIFICACION (guardado como porcentaje 0-100, ver cabecera). Gate EDITAR sobre PLANEADOR. V227.';

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
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, NULL, NULL, p_pk_tactividad
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

        -- Consolida la recuperacion sobre su destino, si esta actividad lo es (V408).
        PERFORM academico_test.fn_actividad_recuperacion_aplicar(
                    p_pk_usuario_solicitante, v_pk_est);
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
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, NULL, NULL, academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante)
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

    -- Consolida la recuperacion sobre su destino, si esta actividad lo es (V408).
    PERFORM academico_test.fn_actividad_recuperacion_aplicar(
                p_pk_usuario_solicitante, p_pk_tactividad_estudiante);

    RETURN v_pct_final;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar_cotejo(BIGINT, BIGINT, BIGINT[], DATE)
    IS 'Califica a un estudiante con la lista de cotejo de su actividad: p_items_marcados = PKs de TACTIVIDAD_COTEJO_ITEM cumplidos (puede ser vacio/NULL = nada cumplido). p_fecha (DEFAULT CURRENT_DATE) es el dia de clase que se califica: se exige asistencia registrada y no injustificada para esa fecha (fn_actividad_nota_asistencia_assert). Hace reemplazo completo de TACTIVIDAD_COTEJO_EVALUACION (1 fila por item ACTIVE de la actividad, CUMPLIDO S/N explicito) y luego calcula el % con fn_actividad_nota_cotejo_recalcular (unica definicion de la formula, compartida con fn_actividad_nota_calificar_cotejo_bulk): % = SUM(peso de los items cumplidos) / SUM(peso de TODOS los items) * 100, tratando los items SIN ponderacion (V226, columna opcional) como peso 1 tanto en el numerador como en el denominador. Guarda el resultado en TACTIVIDAD_NOTA.CALIFICACION (porcentaje 0-100). Gate EDITAR sobre PLANEADOR. V227.';

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
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, NULL, NULL, p_pk_tactividad
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

        -- Consolida la recuperacion sobre su destino, si esta actividad lo es (V408).
        PERFORM academico_test.fn_actividad_recuperacion_aplicar(
                    p_pk_usuario_solicitante, v_pk_est);

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

DROP FUNCTION IF EXISTS academico_test.fn_actividad_nota_calificar_escala(BIGINT, BIGINT, BIGINT, NUMERIC);

DROP FUNCTION IF EXISTS academico_test.fn_actividad_nota_calificar_escala_bulk(BIGINT, BIGINT, BIGINT, BIGINT[], DATE);

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
    v_pct_final     NUMERIC(5,2);
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, NULL, NULL, academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante)
    );

    v_pk_tactividad := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);
    PERFORM academico_test.fn_actividad_nota_asistencia_assert(p_pk_tactividad_estudiante, p_fecha);
    PERFORM academico_test.fn_actividad_instrumento_assert(v_pk_tactividad, 'OTRO');

    IF p_porcentaje IS NULL OR p_porcentaje < 0 OR p_porcentaje > 100 THEN
        RAISE EXCEPTION 'p_porcentaje debe estar entre 0 y 100' USING ERRCODE = '22023';
    END IF;

    v_pk_nota := academico_test.fn_actividad_nota_get_or_create(p_pk_usuario_solicitante, p_pk_tactividad_estudiante);

    -- El valor viene directo del llamador, pero pasa por el MISMO piso/tope
    -- institucional que los instrumentos con calculo propio: el limite es de
    -- la nota, no del instrumento (ver seccion "PISO Y TOPE" de la cabecera).
    v_pct_final := academico_test.fn_actividad_nota_ajustar_por_criterio(
                       v_pk_tactividad, ROUND(p_porcentaje, 2));

    UPDATE academico_test.TACTIVIDAD_NOTA
       SET CALIFICACION = v_pct_final, CALIFICABLE = 'S',
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD_NOTA = v_pk_nota;

    -- Consolida la recuperacion sobre su destino, si esta actividad lo es (V408).
    PERFORM academico_test.fn_actividad_recuperacion_aplicar(
                p_pk_usuario_solicitante, p_pk_tactividad_estudiante);

    RETURN v_pct_final;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar_otro(BIGINT, BIGINT, NUMERIC, DATE)
    IS 'Instrumento OTRO (sin estructura, V226): NO hay calculo automatico. p_fecha (DEFAULT CURRENT_DATE) es el dia de clase que se califica: se exige asistencia registrada y no injustificada para esa fecha (fn_actividad_nota_asistencia_assert). Guarda el % (0-100) que manda el llamador en TACTIVIDAD_NOTA.CALIFICACION; el calculo/criterio es responsabilidad del cliente (DESCRIPCION_INSTRUMENTO), pero el valor NO se guarda crudo: pasa por el MISMO piso/tope institucional que los demas instrumentos (fn_actividad_nota_ajustar_por_criterio -- tope de recuperacion si ES_RECUPERACION=''S'', luego piso PORCENTAJE_INICIAL_CALIF), porque el limite es de la nota y no del instrumento. El valor retornado es el ya ajustado. Gate EDITAR sobre PLANEADOR. V227.';

DROP FUNCTION IF EXISTS academico_test.fn_actividad_nota_calificar(BIGINT, BIGINT, JSONB);

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_evaluacion_formato(
    p_pk_tcriterio_evaluacion BIGINT
)
RETURNS TABLE (
    formato_valor   VARCHAR,
    formato_nombre  VARCHAR,
    es_numerico     BOOLEAN,
    nota_maxima     NUMERIC,
    decimales       INT,
    fk_tescala      BIGINT
)
LANGUAGE sql
STABLE
AS $fn$
    SELECT lv.VALOR,
           lv.NOMBRE,
           (lv.VALOR IN ('CINCO', 'DIEZ', 'CIEN')),
           CASE lv.VALOR WHEN 'CINCO' THEN 5 WHEN 'DIEZ' THEN 10 WHEN 'CIEN' THEN 100 END::NUMERIC,
           COALESCE(ce.NUMERO_DECIMALES, 1)::INT,
           ce.FK_TESCALA
      FROM academico_test.TCRITERIO_EVALUACION ce
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = ce.FK_TLV_FORMATO_CALIFICACION
     WHERE ce.PK_TCRITERIO_EVALUACION = p_pk_tcriterio_evaluacion
       AND ce.ACTIVE = TRUE;
$fn$;

COMMENT ON FUNCTION academico_test.fn_criterio_evaluacion_formato(BIGINT)
    IS 'Accesor del FORMATO DE CALIFICACION configurado en TCRITERIO_EVALUACION para un periodo: codigo (TLISTA_VALOR.VALOR de la categoria FORMATO_CALIFICACION), nombre, si es numerico, la nota maxima equivalente, los decimales a usar y la escala institucional asociada. es_numerico distingue los tres formatos con nota (CINCO/DIEZ/CIEN) de los tres que NO la tienen (LITERAL/SIMBOLO/CARITA), para los que nota_maxima viene NULL: en esos el colegio no califica con un numero sino con la valoracion. Se compara por VALOR y no por NOMBRE -- V97 documenta que comparar por NOMBRE fue un bug y fn_criterio_eval_obtener (V62) todavia lo arrastra. Mismo estilo de accesor que fn_criterio_evaluacion_porcentaje_inicial / _maximo_recuperacion (V239). V227.';

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_unidad_valoraciones_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/unidades/:ID/valoraciones', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V227 -- valoraciones (las bandas Bajo/Basico/Alto/Superior) de la escala que aplica a la unidad :ID. Es el select que faltaba para poder AGREGAR UN CRITERIO a la rubrica de la unidad: POST /planeador/unidades/:ID/criterios exige un indicador por cada valoracion activa de la escala, y cada uno se identifica con el pk_tescala_valoracion que devuelve esta ruta. La escala se deriva de la unidad (asignatura + grado -> criterio de evaluacion vigente -> escala; si no hay, por el nivel de ensenanza del grado), asi que el cliente no tiene que conocerla ni filtrar entre las escalas del periodo. Cada fila trae el orden, el codigo/nombre de la valoracion y sus graficas (simbolo, carita), los limites crudos en porcentaje 0-100 (limite_inferior/limite_superior, que es como se guardan) y esos mismos limites ya convertidos al formato de calificacion del colegio (nota_minima/nota_maxima, NULL si el formato no es numerico) para poder rotular "Alto (4.0 - 4.7)". Sin paginacion: una escala tiene unas pocas bandas. Gate VER sobre PLANEADOR.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-DOCENTE')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/unidades/:ID/valoraciones'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;
