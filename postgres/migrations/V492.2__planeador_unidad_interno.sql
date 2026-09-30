-- V492.2 — Planeador, unidad: núcleos _interno sin permisos (2 de 3).
--
-- Qué hace: crear/actualizar/eliminar la unidad, sus enunciados, los criterios
-- de su rúbrica y el vínculo con actividades, más las lecturas de la unidad.
-- Validan con V492.1 antes de escribir y no saben de permisos: los reutilizan
-- los wrappers de V492.3 y fn_actividad_actualizar_interno (V479).
-- p_pk_usuario_solicitante solo firma CREATED_BY/MODIFIED_BY.
-- Reemplaza fn_unidad_rubrica_asegurar (V222), que llevaba el gate dentro.
-- Depende de: V492.1, V223 (reparto por Sumatoria), V451 (referente
-- aplicable), V455 (escala de la unidad), V483 (mínimos diferidos).

SET search_path TO academico_test, public;

DROP FUNCTION IF EXISTS academico_test.fn_unidad_rubrica_asegurar(BIGINT, BIGINT);

-- ---------------------------------------------------------------------------
-- Referente efectivo de la unidad
-- ---------------------------------------------------------------------------

-- El referente no se elige a mano: se deriva del grado (y del área de la
-- asignatura). Si llega uno se respeta; si no llega, se conserva el actual
-- mientras siga vigente y cubra el nivel del grado, y si dejó de aplicar se
-- re-deriva en vez de dejar la unidad apuntando a un referente muerto.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_referente_efectivo_interno(
    p_pk_tunidad              BIGINT,
    p_fk_tgrado               BIGINT,
    p_fk_tasignatura          BIGINT,
    p_fk_referente_curricular BIGINT,
    p_limpiar                 BOOLEAN DEFAULT FALSE
)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_actual BIGINT;
BEGIN
    IF p_limpiar THEN
        RETURN NULL;
    END IF;
    IF p_fk_referente_curricular IS NOT NULL THEN
        RETURN p_fk_referente_curricular;
    END IF;

    SELECT FK_REFERENTE_CURRICULAR INTO v_actual
      FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = p_pk_tunidad;
    IF v_actual IS NOT NULL AND EXISTS (
        SELECT 1
          FROM academico_test.TREFERENTE_CURRICULAR rc
          JOIN academico_test.TREFERENTE_CURRICULAR_NIVEL rcn
                ON rcn.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR AND rcn.ACTIVE = TRUE
          JOIN academico_test.TGRADO g ON g.PK_TGRADO = p_fk_tgrado
         WHERE rc.PK_REFERENTE_CURRICULAR = v_actual
           AND rc.ACTIVE = TRUE AND rc.ESTADO = 'A'
           AND rcn.FK_TNIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
    ) THEN
        RETURN v_actual;
    END IF;

    RETURN academico_test.fn_unidad_referente_aplicable(p_fk_tgrado, p_fk_tasignatura);
END;
$$;

-- ---------------------------------------------------------------------------
-- Objetivos y contenidos (reemplazo completo; NULL = no tocar)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_objetivos_reemplazar_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tunidad             BIGINT,
    p_objetivos              VARCHAR[]
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_objetivos IS NULL THEN
        RETURN;
    END IF;
    UPDATE academico_test.TUNIDAD_OBJETIVO
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;

    INSERT INTO academico_test.TUNIDAD_OBJETIVO (FK_TUNIDAD, ORDEN, DESCRIPCION, CREATED_BY, CREATED_AT, ACTIVE)
    SELECT p_pk_tunidad, ROW_NUMBER() OVER (ORDER BY o.pos), TRIM(o.txt),
           p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
      FROM unnest(p_objetivos) WITH ORDINALITY AS o(txt, pos)
     WHERE NULLIF(TRIM(o.txt), '') IS NOT NULL;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_contenidos_reemplazar_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tunidad             BIGINT,
    p_contenidos             VARCHAR[]
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_contenidos IS NULL THEN
        RETURN;
    END IF;
    UPDATE academico_test.TUNIDAD_CONTENIDO
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;

    INSERT INTO academico_test.TUNIDAD_CONTENIDO (FK_TUNIDAD, ORDEN, DESCRIPCION, CREATED_BY, CREATED_AT, ACTIVE)
    SELECT p_pk_tunidad, ROW_NUMBER() OVER (ORDER BY c.pos), TRIM(c.txt),
           p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
      FROM unnest(p_contenidos) WITH ORDINALITY AS c(txt, pos)
     WHERE NULLIF(TRIM(c.txt), '') IS NOT NULL;
END;
$$;

-- ---------------------------------------------------------------------------
-- Enunciados de la unidad (TUNIDAD_ENUNCIADO)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_enunciado_relacionar_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tunidad             BIGINT,
    p_fk_referente_enunciado BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk BIGINT;
BEGIN
    PERFORM academico_test.fn_unidad_validar_existente(p_pk_tunidad);
    PERFORM academico_test.fn_unidad_validar_activa(p_pk_tunidad);

    -- Uno ya relacionado se conserva tal cual: reenviarlo en el PUT no lo
    -- revalida, así un enunciado que luego se inactivó sigue siendo historia.
    SELECT PK_TUNIDAD_ENUNCIADO INTO v_pk
      FROM academico_test.TUNIDAD_ENUNCIADO
     WHERE FK_TUNIDAD = p_pk_tunidad AND FK_REFERENTE_ENUNCIADO = p_fk_referente_enunciado AND ACTIVE = TRUE;
    IF v_pk IS NOT NULL THEN
        RETURN v_pk;
    END IF;

    PERFORM academico_test.fn_unidad_validar_enunciado(p_pk_tunidad, p_fk_referente_enunciado);

    -- Get-or-create sobre el índice único parcial: una fila dada de baja se reactiva.
    SELECT PK_TUNIDAD_ENUNCIADO INTO v_pk
      FROM academico_test.TUNIDAD_ENUNCIADO
     WHERE FK_TUNIDAD = p_pk_tunidad AND FK_REFERENTE_ENUNCIADO = p_fk_referente_enunciado;

    IF v_pk IS NULL THEN
        INSERT INTO academico_test.TUNIDAD_ENUNCIADO (FK_TUNIDAD, FK_REFERENTE_ENUNCIADO, CREATED_BY, CREATED_AT, ACTIVE)
        VALUES (p_pk_tunidad, p_fk_referente_enunciado, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE)
        RETURNING PK_TUNIDAD_ENUNCIADO INTO v_pk;
    ELSE
        UPDATE academico_test.TUNIDAD_ENUNCIADO
           SET ACTIVE = TRUE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TUNIDAD_ENUNCIADO = v_pk;
    END IF;

    RETURN v_pk;
END;
$$;

-- Quitar un enunciado desactiva las evidencias que las actividades de la
-- unidad habían marcado de él: solo existen mientras el enunciado esté en la
-- unidad. El mínimo de un enunciado lo exige el trigger diferido de V483.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_enunciados_desactivar_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tunidad             BIGINT,
    p_fk_referente_enunciados BIGINT[]
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_filas INT;
BEGIN
    UPDATE academico_test.TACTIVIDAD_EVIDENCIA ae
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TREFERENTE_ENUNCIADO ev, academico_test.TACTIVIDAD a
     WHERE ae.FK_REFERENTE_ENUNCIADO = ev.PK_REFERENTE_ENUNCIADO
       AND a.PK_TACTIVIDAD = ae.FK_TACTIVIDAD
       AND a.FK_TUNIDAD = p_pk_tunidad
       AND ae.ACTIVE = TRUE
       AND ev.FK_PADRE = ANY(p_fk_referente_enunciados);

    UPDATE academico_test.TUNIDAD_ENUNCIADO
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TUNIDAD = p_pk_tunidad
       AND ACTIVE = TRUE
       AND FK_REFERENTE_ENUNCIADO = ANY(p_fk_referente_enunciados);
    GET DIAGNOSTICS v_filas = ROW_COUNT;
    RETURN v_filas;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_enunciado_quitar_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tunidad_enunciado   BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_unidad    BIGINT;
    v_enunciado BIGINT;
    v_active    BOOLEAN;
BEGIN
    SELECT FK_TUNIDAD, FK_REFERENTE_ENUNCIADO, ACTIVE INTO v_unidad, v_enunciado, v_active
      FROM academico_test.TUNIDAD_ENUNCIADO WHERE PK_TUNIDAD_ENUNCIADO = p_pk_tunidad_enunciado;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontró el enunciado de la unidad solicitado' USING ERRCODE = 'P0002';
    END IF;
    IF NOT v_active THEN
        RAISE EXCEPTION '% ya no está relacionado con %',
            academico_test.fn_unidad_enunciado_etiqueta(v_enunciado), academico_test.fn_unidad_etiqueta(v_unidad)
            USING ERRCODE = '22023';
    END IF;
    PERFORM academico_test.fn_unidad_validar_activa(v_unidad);

    PERFORM academico_test.fn_unidad_enunciados_desactivar_interno(
        p_pk_usuario_solicitante, v_unidad, ARRAY[v_enunciado]);
    RETURN TRUE;
END;
$$;

-- p_enunciados es el conjunto final: lo que no venga se quita.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_enunciados_reemplazar_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tunidad             BIGINT,
    p_enunciados             BIGINT[]
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_final BIGINT[] := ARRAY(SELECT DISTINCT e FROM unnest(p_enunciados) e WHERE e IS NOT NULL);
BEGIN
    IF p_enunciados IS NULL THEN
        RETURN;
    END IF;
    PERFORM academico_test.fn_unidad_enunciados_desactivar_interno(
        p_pk_usuario_solicitante, p_pk_tunidad,
        ARRAY(SELECT ue.FK_REFERENTE_ENUNCIADO FROM academico_test.TUNIDAD_ENUNCIADO ue
               WHERE ue.FK_TUNIDAD = p_pk_tunidad AND ue.ACTIVE = TRUE
                 AND ue.FK_REFERENTE_ENUNCIADO <> ALL(v_final)));

    PERFORM academico_test.fn_unidad_enunciado_relacionar_interno(p_pk_usuario_solicitante, p_pk_tunidad, e)
       FROM unnest(v_final) AS e;
END;
$$;

-- Tras cambiar de referente, los enunciados del anterior dejan de valer (Regla 16).
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_enunciados_depurar_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tunidad             BIGINT
)
RETURNS INT
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN academico_test.fn_unidad_enunciados_desactivar_interno(
        p_pk_usuario_solicitante, p_pk_tunidad,
        ARRAY(SELECT ue.FK_REFERENTE_ENUNCIADO
                FROM academico_test.TUNIDAD_ENUNCIADO ue
                JOIN academico_test.TUNIDAD u ON u.PK_TUNIDAD = ue.FK_TUNIDAD
                JOIN academico_test.TREFERENTE_ENUNCIADO e ON e.PK_REFERENTE_ENUNCIADO = ue.FK_REFERENTE_ENUNCIADO
               WHERE ue.FK_TUNIDAD = p_pk_tunidad AND ue.ACTIVE = TRUE
                 AND e.FK_REFERENTE_CURRICULAR IS DISTINCT FROM u.FK_REFERENTE_CURRICULAR));
END;
$$;

-- ---------------------------------------------------------------------------
-- Peso de las actividades al cambiar el criterio de cálculo (Regla 18)
-- ---------------------------------------------------------------------------

-- De Sumatoria a Ponderar se conserva la distribución: Pᵢ = xᵢ / Σx × 100 a
-- 1 decimal, y el residuo del redondeo va a la actividad de mayor peso (la
-- última si empatan) para cerrar exactamente 100. Se escribe en un solo
-- UPDATE sobre pesos ya en NULL: el trigger del 100 % ve sumas parciales.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_ponderacion_desde_sumatoria_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tunidad             BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    WITH base AS (
        SELECT a.PK_TACTIVIDAD, a.FK_TGRUPO,
               ROUND(COALESCE(a.NOTA_MAXIMA, 0) * 100
                     / NULLIF(SUM(COALESCE(a.NOTA_MAXIMA, 0)) OVER (PARTITION BY a.FK_TGRUPO), 0), 1) AS peso
          FROM academico_test.TACTIVIDAD a
         WHERE a.FK_TUNIDAD = p_pk_tunidad AND a.ACTIVE = TRUE
    ), ajuste AS (
        SELECT b.*,
               100 - SUM(b.peso) OVER (PARTITION BY b.FK_TGRUPO) AS delta,
               row_number() OVER (PARTITION BY b.FK_TGRUPO ORDER BY b.peso DESC, b.PK_TACTIVIDAD DESC) AS rn
          FROM base b
         WHERE b.peso IS NOT NULL
    )
    UPDATE academico_test.TACTIVIDAD a
       SET PONDERACION = aj.peso + CASE WHEN aj.rn = 1 THEN aj.delta ELSE 0 END,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
      FROM ajuste aj
     WHERE a.PK_TACTIVIDAD = aj.PK_TACTIVIDAD;
END;
$$;

-- ---------------------------------------------------------------------------
-- Unidad: crear / actualizar / eliminar
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_crear_interno(
    p_pk_usuario_solicitante    BIGINT,
    p_nombre                    VARCHAR,
    p_fk_tasignatura            BIGINT,
    p_fk_tgrado                 BIGINT,
    p_fk_tfuncionario           BIGINT,
    p_fk_tlv_calculo_definitiva BIGINT,
    p_descripcion               VARCHAR   DEFAULT NULL,
    p_fk_referente_curricular   BIGINT    DEFAULT NULL,
    p_objetivos                 VARCHAR[] DEFAULT NULL,
    p_contenidos                VARCHAR[] DEFAULT NULL,
    p_enunciados                BIGINT[]  DEFAULT NULL,
    p_ponderacion               NUMERIC   DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_referente BIGINT;
    v_pk        BIGINT;
BEGIN
    PERFORM academico_test.fn_unidad_validar_campos(
        NULL, p_nombre, p_descripcion, p_fk_tasignatura, p_fk_tgrado, p_fk_tfuncionario,
        p_fk_tlv_calculo_definitiva, p_objetivos, p_contenidos, p_ponderacion);

    v_referente := academico_test.fn_unidad_referente_efectivo_interno(
        NULL, p_fk_tgrado, p_fk_tasignatura, p_fk_referente_curricular);

    PERFORM academico_test.fn_unidad_validar_coherencia(
        NULL, TRIM(p_nombre), p_fk_tasignatura, p_fk_tgrado, v_referente, p_ponderacion, TRUE);

    INSERT INTO academico_test.TUNIDAD (
        NOMBRE, FK_TASIGNATURA, FK_TGRADO, FK_TFUNCIONARIO, DESCRIPCION,
        FK_TLV_CALCULO_DEFINITIVA, FK_REFERENTE_CURRICULAR, PONDERACION,
        CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        TRIM(p_nombre), p_fk_tasignatura, p_fk_tgrado, p_fk_tfuncionario, NULLIF(TRIM(p_descripcion), ''),
        p_fk_tlv_calculo_definitiva, v_referente, p_ponderacion,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TUNIDAD INTO v_pk;

    PERFORM academico_test.fn_unidad_objetivos_reemplazar_interno(p_pk_usuario_solicitante, v_pk, p_objetivos);
    PERFORM academico_test.fn_unidad_contenidos_reemplazar_interno(p_pk_usuario_solicitante, v_pk, p_contenidos);
    PERFORM academico_test.fn_unidad_enunciados_reemplazar_interno(p_pk_usuario_solicitante, v_pk, p_enunciados);

    RETURN v_pk;
END;
$$;

-- PATCH: NULL = no tocar; los arrays son reemplazo completo.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_actualizar_interno(
    p_pk_usuario_solicitante    BIGINT,
    p_pk_tunidad                BIGINT,
    p_nombre                    VARCHAR   DEFAULT NULL,
    p_descripcion               VARCHAR   DEFAULT NULL,
    p_fk_tasignatura            BIGINT    DEFAULT NULL,
    p_fk_tgrado                 BIGINT    DEFAULT NULL,
    p_fk_tfuncionario           BIGINT    DEFAULT NULL,
    p_fk_tlv_calculo_definitiva BIGINT    DEFAULT NULL,
    p_fk_referente_curricular   BIGINT    DEFAULT NULL,
    p_limpiar_referente         BOOLEAN   DEFAULT FALSE,
    p_objetivos                 VARCHAR[] DEFAULT NULL,
    p_contenidos                VARCHAR[] DEFAULT NULL,
    p_ponderacion               NUMERIC   DEFAULT NULL,
    p_limpiar_ponderacion       BOOLEAN   DEFAULT FALSE,
    p_enunciados                BIGINT[]  DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_actual      academico_test.TUNIDAD%ROWTYPE;
    v_nombre      VARCHAR;
    v_asig        BIGINT;
    v_grado       BIGINT;
    v_referente   BIGINT;
    v_ponderacion NUMERIC;
    v_modo_previo VARCHAR;
    v_modo_nuevo  VARCHAR;
    v_grupo       BIGINT;
BEGIN
    PERFORM academico_test.fn_unidad_validar_existente(p_pk_tunidad);
    PERFORM academico_test.fn_unidad_validar_activa(p_pk_tunidad);
    PERFORM academico_test.fn_unidad_validar_campos(
        p_pk_tunidad, p_nombre, p_descripcion, p_fk_tasignatura, p_fk_tgrado, p_fk_tfuncionario,
        p_fk_tlv_calculo_definitiva, p_objetivos, p_contenidos, p_ponderacion);

    SELECT * INTO v_actual FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = p_pk_tunidad;
    v_nombre      := COALESCE(NULLIF(TRIM(p_nombre), ''), v_actual.NOMBRE);
    v_asig        := COALESCE(p_fk_tasignatura, v_actual.FK_TASIGNATURA);
    v_grado       := COALESCE(p_fk_tgrado, v_actual.FK_TGRADO);
    v_ponderacion := CASE WHEN p_limpiar_ponderacion THEN NULL
                          ELSE COALESCE(p_ponderacion, v_actual.PONDERACION) END;
    -- Depende del grado RESULTANTE: mover la unidad de grado puede cambiarle el nivel.
    v_referente   := academico_test.fn_unidad_referente_efectivo_interno(
                         p_pk_tunidad, v_grado, v_asig, p_fk_referente_curricular, p_limpiar_referente);

    PERFORM academico_test.fn_unidad_validar_coherencia(
        p_pk_tunidad, v_nombre, v_asig, v_grado, v_referente, v_ponderacion, p_ponderacion IS NOT NULL);

    v_modo_previo := academico_test.fn_unidad_calculo_definitiva_modo(p_pk_tunidad);

    UPDATE academico_test.TUNIDAD
       SET NOMBRE                    = v_nombre,
           DESCRIPCION               = CASE WHEN p_descripcion IS NULL THEN DESCRIPCION
                                            ELSE NULLIF(TRIM(p_descripcion), '') END,
           FK_TASIGNATURA            = v_asig,
           FK_TGRADO                 = v_grado,
           FK_TFUNCIONARIO           = COALESCE(p_fk_tfuncionario, FK_TFUNCIONARIO),
           FK_TLV_CALCULO_DEFINITIVA = COALESCE(p_fk_tlv_calculo_definitiva, FK_TLV_CALCULO_DEFINITIVA),
           FK_REFERENTE_CURRICULAR   = v_referente,
           PONDERACION               = v_ponderacion,
           MODIFIED_BY               = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT               = CURRENT_TIMESTAMP
     WHERE PK_TUNIDAD = p_pk_tunidad;

    PERFORM academico_test.fn_unidad_objetivos_reemplazar_interno(p_pk_usuario_solicitante, p_pk_tunidad, p_objetivos);
    PERFORM academico_test.fn_unidad_contenidos_reemplazar_interno(p_pk_usuario_solicitante, p_pk_tunidad, p_contenidos);

    IF v_referente IS DISTINCT FROM v_actual.FK_REFERENTE_CURRICULAR THEN
        PERFORM academico_test.fn_unidad_enunciados_depurar_interno(p_pk_usuario_solicitante, p_pk_tunidad);
    END IF;
    PERFORM academico_test.fn_unidad_enunciados_reemplazar_interno(p_pk_usuario_solicitante, p_pk_tunidad, p_enunciados);

    -- Regla 18: el peso que las actividades traían del criterio anterior no
    -- significa lo mismo en el nuevo. Promediar no lleva peso; Sumatoria lo
    -- deriva del puntaje; Ponderar conserva el reparto si venía de Sumatoria.
    v_modo_nuevo := academico_test.fn_unidad_calculo_definitiva_modo(p_pk_tunidad);
    IF v_modo_nuevo IS DISTINCT FROM v_modo_previo THEN
        UPDATE academico_test.TACTIVIDAD
           SET PONDERACION = NULL, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE AND PONDERACION IS NOT NULL;

        IF v_modo_nuevo = 'SUMATORIA' THEN
            FOR v_grupo IN SELECT DISTINCT a.FK_TGRUPO FROM academico_test.TACTIVIDAD a
                            WHERE a.FK_TUNIDAD = p_pk_tunidad AND a.ACTIVE = TRUE LOOP
                PERFORM academico_test.fn_unidad_ponderacion_recalcular_sumatoria(p_pk_tunidad, v_grupo);
            END LOOP;
        ELSIF v_modo_nuevo = 'PONDERAR' AND v_modo_previo = 'SUMATORIA' THEN
            PERFORM academico_test.fn_unidad_ponderacion_desde_sumatoria_interno(p_pk_usuario_solicitante, p_pk_tunidad);
        END IF;
    END IF;

    RETURN p_pk_tunidad;
END;
$$;

-- Baja lógica de la unidad y de lo que es solo suyo (rúbrica, objetivos,
-- contenidos, enunciados). Las actividades bloquean: no se arrastran.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_eliminar_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tunidad             BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_usuario VARCHAR := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    PERFORM academico_test.fn_unidad_validar_existente(p_pk_tunidad);
    PERFORM academico_test.fn_unidad_validar_activa(p_pk_tunidad);
    PERFORM academico_test.fn_unidad_validar_eliminable(p_pk_tunidad);

    UPDATE academico_test.TUNIDAD
       SET ACTIVE = FALSE, MODIFIED_BY = v_usuario, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TUNIDAD = p_pk_tunidad;

    UPDATE academico_test.TNIVEL_CRITERIO_UNIDAD ncu
       SET ACTIVE = FALSE, MODIFIED_BY = v_usuario, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TCRITERIO_UNIDAD cu
      JOIN academico_test.TRUBRICA_UNIDAD ru ON ru.PK_TRUBRICA_UNIDAD = cu.FK_TRUBRICA_UNIDAD
     WHERE ncu.FK_TCRITERIO_UNIDAD = cu.PK_TCRITERIO_UNIDAD AND ru.FK_TUNIDAD = p_pk_tunidad AND ncu.ACTIVE = TRUE;

    UPDATE academico_test.TCRITERIO_UNIDAD cu
       SET ACTIVE = FALSE, MODIFIED_BY = v_usuario, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TRUBRICA_UNIDAD ru
     WHERE cu.FK_TRUBRICA_UNIDAD = ru.PK_TRUBRICA_UNIDAD AND ru.FK_TUNIDAD = p_pk_tunidad AND cu.ACTIVE = TRUE;

    UPDATE academico_test.TRUBRICA_UNIDAD
       SET ACTIVE = FALSE, MODIFIED_BY = v_usuario, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;

    UPDATE academico_test.TUNIDAD_OBJETIVO
       SET ACTIVE = FALSE, MODIFIED_BY = v_usuario, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;

    UPDATE academico_test.TUNIDAD_CONTENIDO
       SET ACTIVE = FALSE, MODIFIED_BY = v_usuario, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;

    UPDATE academico_test.TUNIDAD_ENUNCIADO
       SET ACTIVE = FALSE, MODIFIED_BY = v_usuario, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;

    RETURN p_pk_tunidad;
END;
$$;

-- ---------------------------------------------------------------------------
-- Rúbrica de la unidad y sus criterios
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_rubrica_asegurar_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tunidad             BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk BIGINT;
BEGIN
    SELECT PK_TRUBRICA_UNIDAD INTO v_pk
      FROM academico_test.TRUBRICA_UNIDAD WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;
    IF v_pk IS NOT NULL THEN
        RETURN v_pk;
    END IF;

    UPDATE academico_test.TRUBRICA_UNIDAD
       SET ACTIVE = TRUE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TUNIDAD = p_pk_tunidad
    RETURNING PK_TRUBRICA_UNIDAD INTO v_pk;

    IF v_pk IS NULL THEN
        INSERT INTO academico_test.TRUBRICA_UNIDAD (FK_TUNIDAD, CREATED_BY, CREATED_AT, ACTIVE)
        VALUES (p_pk_tunidad, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE)
        RETURNING PK_TRUBRICA_UNIDAD INTO v_pk;
    END IF;
    RETURN v_pk;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_criterio_agregar_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tunidad             BIGINT,
    p_descripcion            VARCHAR,
    p_niveles                JSONB,
    p_publico                VARCHAR DEFAULT 'S',
    p_codigo                 VARCHAR DEFAULT NULL,
    p_descriptor_prom        VARCHAR DEFAULT 'N'
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_rubrica  BIGINT;
    v_criterio BIGINT;
BEGIN
    PERFORM academico_test.fn_unidad_validar_existente(p_pk_tunidad);
    PERFORM academico_test.fn_unidad_validar_activa(p_pk_tunidad);
    PERFORM academico_test.fn_unidad_validar_admite_rubrica(p_pk_tunidad);
    PERFORM academico_test.fn_unidad_validar_criterio_texto(p_descripcion, TRUE);
    p_publico := COALESCE(p_publico, 'S');
    PERFORM academico_test.fn_unidad_validar_bandera_sn(p_publico, 'Público');
    PERFORM academico_test.fn_unidad_validar_bandera_sn(p_descriptor_prom, 'Descriptor para promoción');
    PERFORM academico_test.fn_unidad_validar_criterio_niveles_nuevos(p_pk_tunidad, p_niveles);

    v_rubrica := academico_test.fn_unidad_rubrica_asegurar_interno(p_pk_usuario_solicitante, p_pk_tunidad);

    INSERT INTO academico_test.TCRITERIO_UNIDAD (
        FK_TRUBRICA_UNIDAD, ORDEN, DESCRIPCION, PUBLICO, CODIGO, DESCRIPTOR_PROM, CREATED_BY, CREATED_AT, ACTIVE
    )
    SELECT v_rubrica, COALESCE(MAX(ORDEN), 0) + 1, TRIM(p_descripcion), UPPER(TRIM(p_publico)),
           NULLIF(TRIM(p_codigo), ''), COALESCE(UPPER(TRIM(p_descriptor_prom)), 'N'),
           p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
      FROM academico_test.TCRITERIO_UNIDAD WHERE FK_TRUBRICA_UNIDAD = v_rubrica
    RETURNING PK_TCRITERIO_UNIDAD INTO v_criterio;

    INSERT INTO academico_test.TNIVEL_CRITERIO_UNIDAD (
        FK_TCRITERIO_UNIDAD, INDICADOR, RECOMENDACION, TAREA, FK_TESCALA_VALORACION, CREATED_BY, CREATED_AT, ACTIVE
    )
    SELECT v_criterio, TRIM(e->>'indicador'), NULLIF(TRIM(e->>'recomendacion'), ''), NULLIF(TRIM(e->>'tarea'), ''),
           (e->>'fkTescalaValoracion')::BIGINT, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
      FROM jsonb_array_elements(p_niveles) e;

    RETURN v_criterio;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_criterio_actualizar_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tcriterio_unidad    BIGINT,
    p_descripcion            VARCHAR DEFAULT NULL,
    p_publico                VARCHAR DEFAULT NULL,
    p_codigo                 VARCHAR DEFAULT NULL,
    p_limpiar_codigo         BOOLEAN DEFAULT FALSE,
    p_descriptor_prom        VARCHAR DEFAULT NULL,
    p_niveles                JSONB   DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_unidad_validar_criterio_existente(p_pk_tcriterio_unidad);
    PERFORM academico_test.fn_unidad_validar_criterio_activo(p_pk_tcriterio_unidad);
    PERFORM academico_test.fn_unidad_validar_criterio_texto(p_descripcion, FALSE);
    PERFORM academico_test.fn_unidad_validar_bandera_sn(p_publico, 'Público');
    PERFORM academico_test.fn_unidad_validar_bandera_sn(p_descriptor_prom, 'Descriptor para promoción');
    PERFORM academico_test.fn_unidad_validar_criterio_niveles_edicion(p_pk_tcriterio_unidad, p_niveles);

    UPDATE academico_test.TCRITERIO_UNIDAD
       SET DESCRIPCION     = COALESCE(NULLIF(TRIM(p_descripcion), ''), DESCRIPCION),
           PUBLICO         = COALESCE(UPPER(TRIM(p_publico)), PUBLICO),
           CODIGO          = CASE WHEN p_limpiar_codigo THEN NULL
                                  ELSE COALESCE(NULLIF(TRIM(p_codigo), ''), CODIGO) END,
           DESCRIPTOR_PROM = COALESCE(UPPER(TRIM(p_descriptor_prom)), DESCRIPTOR_PROM),
           MODIFIED_BY     = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT     = CURRENT_TIMESTAMP
     WHERE PK_TCRITERIO_UNIDAD = p_pk_tcriterio_unidad;

    IF p_niveles IS NOT NULL THEN
        UPDATE academico_test.TNIVEL_CRITERIO_UNIDAD ncu
           SET INDICADOR     = COALESCE(NULLIF(TRIM(e.j->>'indicador'), ''), ncu.INDICADOR),
               RECOMENDACION = CASE WHEN e.j ? 'recomendacion' THEN NULLIF(TRIM(e.j->>'recomendacion'), '') ELSE ncu.RECOMENDACION END,
               TAREA         = CASE WHEN e.j ? 'tarea' THEN NULLIF(TRIM(e.j->>'tarea'), '') ELSE ncu.TAREA END,
               MODIFIED_BY   = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT   = CURRENT_TIMESTAMP
          FROM (SELECT elem AS j FROM jsonb_array_elements(p_niveles) elem) e
         WHERE ncu.FK_TCRITERIO_UNIDAD = p_pk_tcriterio_unidad
           AND ncu.FK_TESCALA_VALORACION = (e.j->>'fkTescalaValoracion')::BIGINT
           AND ncu.ACTIVE = TRUE;
    END IF;

    RETURN p_pk_tcriterio_unidad;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_criterio_eliminar_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tcriterio_unidad    BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_unidad_validar_criterio_existente(p_pk_tcriterio_unidad);
    PERFORM academico_test.fn_unidad_validar_criterio_activo(p_pk_tcriterio_unidad);

    UPDATE academico_test.TNIVEL_CRITERIO_UNIDAD
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TCRITERIO_UNIDAD = p_pk_tcriterio_unidad AND ACTIVE = TRUE;

    UPDATE academico_test.TCRITERIO_UNIDAD
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TCRITERIO_UNIDAD = p_pk_tcriterio_unidad;

    RETURN p_pk_tcriterio_unidad;
END;
$$;

-- ---------------------------------------------------------------------------
-- Vínculo actividad <-> unidad
-- ---------------------------------------------------------------------------

-- El criterio de cálculo de la unidad manda sobre el peso: en Promediar no
-- aplica y en Sumatoria lo recalcula el sistema, así que ahí se ignora el que
-- llegue en lugar de rechazarlo (el front no tiene por qué saber el modo).
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_actividad_vincular_interno(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    p_pk_tunidad               BIGINT,
    p_ponderacion              NUMERIC DEFAULT NULL,
    p_permitir_mover_de_unidad BOOLEAN DEFAULT FALSE
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_grupo  BIGINT;
    v_previa BIGINT;
    v_modo   VARCHAR;
BEGIN
    PERFORM academico_test.fn_unidad_validar_actividad_existente(p_pk_tactividad);
    PERFORM academico_test.fn_unidad_validar_actividad_activa(p_pk_tactividad);
    PERFORM academico_test.fn_unidad_validar_existente(p_pk_tunidad);
    PERFORM academico_test.fn_unidad_validar_activa(p_pk_tunidad);
    PERFORM academico_test.fn_unidad_validar_actividad_compatible(p_pk_tactividad, p_pk_tunidad);
    PERFORM academico_test.fn_unidad_validar_actividad_mover(p_pk_tactividad, p_pk_tunidad, p_permitir_mover_de_unidad);

    SELECT FK_TGRUPO, FK_TUNIDAD INTO v_grupo, v_previa
      FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad;

    v_modo := academico_test.fn_unidad_calculo_definitiva_modo(p_pk_tunidad);
    IF v_modo IN ('PROMEDIAR', 'SUMATORIA') THEN
        p_ponderacion := NULL;
    END IF;
    PERFORM academico_test.fn_unidad_validar_ponderacion_actividad(p_pk_tunidad, v_grupo, p_ponderacion, p_pk_tactividad);

    UPDATE academico_test.TACTIVIDAD
       SET FK_TUNIDAD  = p_pk_tunidad,
           PONDERACION = CASE WHEN v_modo IN ('PROMEDIAR', 'SUMATORIA') THEN NULL
                              ELSE COALESCE(p_ponderacion, PONDERACION) END,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD = p_pk_tactividad;

    PERFORM academico_test.fn_unidad_ponderacion_recalcular_sumatoria(p_pk_tunidad, v_grupo);
    IF v_previa IS NOT NULL AND v_previa <> p_pk_tunidad THEN
        PERFORM academico_test.fn_unidad_ponderacion_recalcular_sumatoria(v_previa, v_grupo);
    END IF;

    RETURN p_pk_tactividad;
END;
$$;

-- Desvincular es idempotente: una actividad ya suelta no es un error.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_actividad_desvincular_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_previa BIGINT;
    v_grupo  BIGINT;
BEGIN
    PERFORM academico_test.fn_unidad_validar_actividad_existente(p_pk_tactividad);
    PERFORM academico_test.fn_unidad_validar_actividad_activa(p_pk_tactividad);

    SELECT FK_TUNIDAD, FK_TGRUPO INTO v_previa, v_grupo
      FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad;
    IF v_previa IS NULL THEN
        RETURN p_pk_tactividad;
    END IF;

    UPDATE academico_test.TACTIVIDAD
       SET FK_TUNIDAD = NULL, PONDERACION = NULL,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD = p_pk_tactividad;

    PERFORM academico_test.fn_unidad_ponderacion_recalcular_sumatoria(v_previa, v_grupo);
    RETURN p_pk_tactividad;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_actividad_ponderacion_set_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_ponderacion            NUMERIC
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_unidad BIGINT;
    v_grupo  BIGINT;
BEGIN
    PERFORM academico_test.fn_unidad_validar_actividad_existente(p_pk_tactividad);
    PERFORM academico_test.fn_unidad_validar_actividad_activa(p_pk_tactividad);
    PERFORM academico_test.fn_unidad_validar_actividad_vinculada(p_pk_tactividad);
    IF p_ponderacion IS NULL THEN
        RAISE EXCEPTION 'Indique el peso (%%) de la actividad' USING ERRCODE = '22023';
    END IF;

    SELECT FK_TUNIDAD, FK_TGRUPO INTO v_unidad, v_grupo
      FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad;
    PERFORM academico_test.fn_unidad_validar_ponderacion_actividad_manual(v_unidad);
    PERFORM academico_test.fn_unidad_validar_ponderacion_actividad(v_unidad, v_grupo, p_ponderacion, p_pk_tactividad);

    UPDATE academico_test.TACTIVIDAD
       SET PONDERACION = p_ponderacion,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD = p_pk_tactividad;

    RETURN p_pk_tactividad;
END;
$$;

-- ---------------------------------------------------------------------------
-- Lecturas de la unidad
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_objetivos_listar_interno(p_pk_tunidad BIGINT)
RETURNS TABLE(pk_tunidad_objetivo BIGINT, orden NUMERIC, descripcion VARCHAR)
LANGUAGE sql
STABLE
AS $$
    SELECT o.PK_TUNIDAD_OBJETIVO, o.ORDEN, o.DESCRIPCION
      FROM academico_test.TUNIDAD_OBJETIVO o
     WHERE o.FK_TUNIDAD = p_pk_tunidad AND o.ACTIVE = TRUE
     ORDER BY o.ORDEN;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_contenidos_listar_interno(p_pk_tunidad BIGINT)
RETURNS TABLE(pk_tunidad_contenido BIGINT, orden NUMERIC, descripcion VARCHAR)
LANGUAGE sql
STABLE
AS $$
    SELECT c.PK_TUNIDAD_CONTENIDO, c.ORDEN, c.DESCRIPCION
      FROM academico_test.TUNIDAD_CONTENIDO c
     WHERE c.FK_TUNIDAD = p_pk_tunidad AND c.ACTIVE = TRUE
     ORDER BY c.ORDEN;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_criterio_listar_interno(
    p_pk_tunidad        BIGINT,
    p_incluir_inactivos BOOLEAN DEFAULT FALSE
)
RETURNS TABLE(pk_tcriterio_unidad BIGINT, orden NUMERIC, descripcion VARCHAR, publico VARCHAR,
              codigo VARCHAR, descriptor_prom VARCHAR, niveles JSONB, active BOOLEAN)
LANGUAGE sql
STABLE
AS $$
    SELECT cu.PK_TCRITERIO_UNIDAD, cu.ORDEN, cu.DESCRIPCION, cu.PUBLICO, cu.CODIGO, cu.DESCRIPTOR_PROM,
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'pk',                  ncu.PK_TNIVEL_CRITERIO_UNIDAD,
                          'fkTescalaValoracion', ncu.FK_TESCALA_VALORACION,
                          'valoracion',          val.NOMBRE,
                          'orden',               ev.ORDEN,
                          'indicador',           ncu.INDICADOR,
                          'recomendacion',       ncu.RECOMENDACION,
                          'tarea',               ncu.TAREA)
                          ORDER BY ev.ORDEN)
                 FROM academico_test.TNIVEL_CRITERIO_UNIDAD ncu
                 JOIN academico_test.TESCALA_VALORACION ev ON ev.PK_TESCALA_VALORACION = ncu.FK_TESCALA_VALORACION
                 JOIN academico_test.TVALORACION val       ON val.PK_TVALORACION = ev.FK_TVALORACION
                WHERE ncu.FK_TCRITERIO_UNIDAD = cu.PK_TCRITERIO_UNIDAD AND ncu.ACTIVE = TRUE
           ), '[]'::jsonb),
           cu.ACTIVE
      FROM academico_test.TCRITERIO_UNIDAD cu
      JOIN academico_test.TRUBRICA_UNIDAD ru ON ru.PK_TRUBRICA_UNIDAD = cu.FK_TRUBRICA_UNIDAD
     WHERE ru.FK_TUNIDAD = p_pk_tunidad
       AND (p_incluir_inactivos OR (cu.ACTIVE = TRUE AND ru.ACTIVE = TRUE))
     ORDER BY cu.ORDEN;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_ponderacion_disponible_interno(
    p_pk_tunidad BIGINT,
    p_fk_tgrupo  BIGINT
)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT GREATEST(100 - academico_test.fn_unidad_ponderacion_asignada(p_pk_tunidad, p_fk_tgrupo, NULL), 0);
$$;

-- ---------------------------------------------------------------------------
-- Reglas 38a y 39: al eliminar o desvincular no se redistribuye el peso; se
-- avisa cuánto quedó libre para que el docente lo ajuste.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_aviso_peso_liberado(
    p_fk_tunidad  BIGINT,
    p_fk_tgrupo   BIGINT,
    p_ponderacion NUMERIC,
    p_accion      VARCHAR
)
RETURNS TABLE (porcentaje_libre NUMERIC, aviso VARCHAR)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_libre NUMERIC;
BEGIN
    IF p_fk_tunidad IS NULL OR p_ponderacion IS NULL
       OR academico_test.fn_unidad_calculo_definitiva_modo(p_fk_tunidad) IS DISTINCT FROM 'PONDERAR' THEN
        RETURN QUERY SELECT NULL::NUMERIC, NULL::VARCHAR;
        RETURN;
    END IF;
    v_libre := academico_test.fn_unidad_ponderacion_disponible_interno(p_fk_tunidad, p_fk_tgrupo);
    RETURN QUERY SELECT v_libre,
        format(CASE WHEN p_accion = 'DESVINCULAR'
                    THEN 'Al desvincular esta actividad, quedará un %s%% libre en %s. Ajuste los pesos restantes para cerrar el 100%%.'
                    ELSE 'La eliminación dejará %s%% libre en %s. Ajuste los pesos restantes para cerrar el 100%%.' END,
               trim_scale(v_libre), academico_test.fn_unidad_etiqueta(p_fk_tunidad))::VARCHAR;
END;
$$;

-- Solo enunciados del referente vigente de la unidad, con sus evidencias activas.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_referente_detalle_interno(p_pk_tunidad BIGINT)
RETURNS TABLE(pk_tunidad BIGINT, unidad_nombre VARCHAR, fk_tgrado BIGINT, grado VARCHAR,
              fk_tnivel_ensenanza BIGINT, nivel_ensenanza VARCHAR, pk_referente_curricular BIGINT,
              referente_nombre VARCHAR, referente_descripcion VARCHAR, enfoque_valor VARCHAR,
              enfoque_nombre VARCHAR, es_evaluativo BOOLEAN, tipo_evaluacion_valor VARCHAR,
              tipo_evaluacion_nombre VARCHAR, nivel_1_etiqueta VARCHAR, nivel_2_etiqueta VARCHAR,
              enunciados JSONB)
LANGUAGE sql
STABLE
AS $$
    SELECT u.PK_TUNIDAD, u.NOMBRE, u.FK_TGRADO, g.NOMBRE, g.FK_TNIVEL_ENSENANZA, ne.NOMBRE,
           rc.PK_REFERENTE_CURRICULAR, rc.NOMBRE, rc.DESCRIPCION, enf.VALOR, enf.NOMBRE,
           (enf.VALOR = 'EVALUATIVO'), tev.VALOR, tev.NOMBRE, rc.NIVEL_1_ETIQUETA, rc.NIVEL_2_ETIQUETA,
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'pk',                   en.PK_REFERENTE_ENUNCIADO,
                          'texto',                en.TEXTO,
                          'relacionadoConUnidad', TRUE,
                          'pkTunidadEnunciado',   ue.PK_TUNIDAD_ENUNCIADO,
                          'evidencias', COALESCE((
                              SELECT jsonb_agg(jsonb_build_object('pk', ev.PK_REFERENTE_ENUNCIADO, 'texto', ev.TEXTO)
                                               ORDER BY ev.PK_REFERENTE_ENUNCIADO)
                                FROM academico_test.TREFERENTE_ENUNCIADO ev
                               WHERE ev.FK_PADRE = en.PK_REFERENTE_ENUNCIADO AND ev.ACTIVE = TRUE
                          ), '[]'::jsonb))
                          ORDER BY en.PK_REFERENTE_ENUNCIADO)
                 FROM academico_test.TUNIDAD_ENUNCIADO ue
                 JOIN academico_test.TREFERENTE_ENUNCIADO en ON en.PK_REFERENTE_ENUNCIADO = ue.FK_REFERENTE_ENUNCIADO
                WHERE ue.FK_TUNIDAD = u.PK_TUNIDAD AND ue.ACTIVE = TRUE
                  AND en.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                  AND en.FK_PADRE IS NULL AND en.ACTIVE = TRUE
           ), '[]'::jsonb)
      FROM academico_test.TUNIDAD u
      LEFT JOIN academico_test.TGRADO g            ON g.PK_TGRADO = u.FK_TGRADO
      LEFT JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
      LEFT JOIN academico_test.TREFERENTE_CURRICULAR rc
             ON rc.PK_REFERENTE_CURRICULAR = u.FK_REFERENTE_CURRICULAR AND rc.ACTIVE = TRUE AND rc.ESTADO = 'A'
      LEFT JOIN academico_test.TLISTA_VALOR enf ON enf.PK_LISTA_VALOR = rc.FK_TLV_ENFOQUE_PEDAGOGICO
      LEFT JOIN academico_test.TLISTA_VALOR tev ON tev.PK_LISTA_VALOR = rc.FK_TLV_TIPO_EVALUACION
     WHERE u.PK_TUNIDAD = p_pk_tunidad;
$$;
COMMENT ON FUNCTION academico_test.fn_unidad_aviso_peso_liberado(BIGINT, BIGINT, NUMERIC, VARCHAR)
    IS 'INTERNO: Reglas 38a/39. En una unidad que pondera, el % que queda libre en (unidad, grupo) tras eliminar o desvincular una actividad con peso, y el aviso para el docente; NULL si no aplica. No redistribuye. La usan fn_unidad_actividad_desvincular y fn_actividad_eliminar.';
