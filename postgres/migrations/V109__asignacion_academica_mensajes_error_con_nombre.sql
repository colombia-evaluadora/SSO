-- fn_asignacion_guardar respondia varios RAISE EXCEPTION con PKs crudos en
-- lugar del nombre legible de la entidad -- mismo patron ya corregido en
-- V99-V102 para periodo/criterio-promocion. Se revisaron las 4 funciones del
-- modulo "asignacion academica" (fn_asignacion_guardar, fn_asignacion_docente,
-- fn_asignacion_pool, fn_asignacion_docente_listar); solo fn_asignacion_guardar
-- tiene RAISE EXCEPTION (las otras 3 son SELECT/consulta pura, sin errores).
--
-- Cambios dentro de fn_asignacion_guardar:
--   1) "El periodo academico % no existe o no esta activo" -- p_academic_period_id
--      es una FK que el usuario manda. Se agrega lookup del NOMBRE del periodo
--      IGNORANDO ACTIVE: si existe pero inactivo -> nombre + "existe pero esta
--      inactivo"; si no existe -> mensaje generico sin id. Mismo ERRCODE (23503).
--   2) "No existe un funcionario con id %" -- mismo patron que (1): lookup del
--      nombre completo del funcionario (via TUSUARIO) ignorando ACTIVE. Mismo
--      ERRCODE (23503).
--   3) "La asignatura % en el grupo % ya esta asignada a otro docente en el
--      periodo" -- en este punto asignatura y grupo YA fueron confirmados
--      activos por el chequeo de pool inmediatamente anterior (linea "El par
--      debe ser una combinacion valida del pool"), asi que se resuelven sus
--      nombres sin volver a filtrar por ACTIVE. Mismo ERRCODE (23505).
--   4) "La asignatura % en el grupo % esta duplicada en la asignacion" --
--      mismo caso que (3), reutiliza el mismo lookup de nombres.
--
-- NO tocados (y por que):
--   - "Identificador de asignacion invalido: %" (v_pair) -- ya es el string
--     crudo ingresado por el usuario, no un PK de una entidad (regla 1).
--   - "La asignatura % no corresponde al grupo % en el plan del periodo" --
--     ambiguo: se dispara precisamente cuando el JOIN (grupo activo + plan +
--     asignatura activa + asignatura_plan) NO encuentra fila, con lo cual no
--     sabemos si asignatura/grupo no existen, estan inactivos, o simplemente
--     no pertenecen al plan de ese grado/periodo. No es un lookup de una sola
--     FK tipo regla 4/5 ni una entidad confirmada activa tipo regla 3 -- es
--     una validacion de combinacion invalida entre dos ids no confirmados. Se
--     deja intacto; si se quiere mejorar requeriria decidir un mensaje para
--     cada una de las 3+ causas posibles por separado (fuera del alcance de
--     este parche mecanico).
--   - fn_asignacion_docente, fn_asignacion_pool, fn_asignacion_docente_listar:
--     no tienen RAISE EXCEPTION (son SELECT/plpgsql de solo lectura).
--
-- Firma, tipos, DEFAULTs, ERRCODEs y logica de negocio quedan intactos; solo
-- se agregan variables DECLARE y SELECTs de lookup antes de los RAISE.

CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_guardar(p_academic_period_id bigint, p_fk_funcionario bigint, p_subject_ids text[], p_pk_usuario_solicitante bigint)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_func BIGINT; v_count INT := 0; v_pair TEXT; v_grupo BIGINT; v_asig BIGINT;
    v_nombre_periodo TEXT;
    v_nombre_funcionario TEXT;
    v_nombre_asig TEXT;
    v_nombre_grupo TEXT;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, academico_test.fn_periodo_establecimiento(p_academic_period_id));

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TPERIODO_ACADEMICO
         WHERE PK_TPERIODO_ACADEMICO = p_academic_period_id AND ACTIVE = TRUE
    ) THEN
        SELECT NOMBRE INTO v_nombre_periodo
          FROM academico_test.TPERIODO_ACADEMICO
         WHERE PK_TPERIODO_ACADEMICO = p_academic_period_id;
        IF v_nombre_periodo IS NOT NULL THEN
            RAISE EXCEPTION 'El periodo academico "%" existe pero esta inactivo', v_nombre_periodo
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El periodo academico no existe' USING ERRCODE = '23503';
        END IF;
    END IF;

    SELECT f.PK_TFUNCIONARIO INTO v_func
      FROM academico_test.TFUNCIONARIO f
     WHERE f.PK_TFUNCIONARIO = p_fk_funcionario AND f.ACTIVE = TRUE;
    IF v_func IS NULL THEN
        SELECT TRIM(concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO))
          INTO v_nombre_funcionario
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
         WHERE f.PK_TFUNCIONARIO = p_fk_funcionario;
        IF v_nombre_funcionario IS NOT NULL THEN
            RAISE EXCEPTION 'El funcionario "%" existe pero esta inactivo', v_nombre_funcionario
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'No existe un funcionario con el id proporcionado' USING ERRCODE = '23503';
        END IF;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('docasig:' || p_academic_period_id::text || ':' || v_func::text));

    -- v_nombre_periodo/v_nombre_funcionario solo quedaban resueltos en las
    -- ramas de error de arriba; en el camino exitoso hacen falta para la
    -- etiqueta, se resuelven aca reusando el mismo lookup.
    SELECT NOMBRE INTO v_nombre_periodo
      FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_academic_period_id;
    SELECT TRIM(concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO))
      INTO v_nombre_funcionario
      FROM academico_test.TFUNCIONARIO f
      JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
     WHERE f.PK_TFUNCIONARIO = v_func;

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Asignación académica del docente %s para el periodo %s', v_nombre_funcionario, v_nombre_periodo),
        academico_test.fn_periodo_establecimiento(p_academic_period_id)
    );

    UPDATE academico_test.TDOCENTE_ASIGNATURA
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TFUNCIONARIO = v_func AND FK_TPERIODO_ACADEMICO = p_academic_period_id AND ACTIVE = TRUE;

    IF p_subject_ids IS NOT NULL THEN
        FOREACH v_pair IN ARRAY p_subject_ids
        LOOP
            -- Formato "grupoId:asignaturaId" (ambos numericos).
            IF v_pair !~ '^[0-9]+:[0-9]+$' THEN
                RAISE EXCEPTION 'Identificador de asignacion invalido: %', v_pair USING ERRCODE = '22023';
            END IF;
            v_grupo := split_part(v_pair, ':', 1)::BIGINT;
            v_asig  := split_part(v_pair, ':', 2)::BIGINT;

            -- El par debe ser una combinacion valida del pool: grupo activo del
            -- periodo, y asignatura activa presente en el plan del grado del grupo.
            IF NOT EXISTS (
                SELECT 1
                  FROM academico_test.TGRUPO gr
                  JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO AND g.ACTIVE = TRUE
                       AND g.FK_TPERIODO_ACADEMICO = p_academic_period_id
                  JOIN academico_test.TPLAN pl ON pl.FK_TGRADO = g.PK_TGRADO AND pl.ACTIVE = TRUE
                  JOIN academico_test.TASIGNATURA_PLAN ap ON ap.FK_TPLAN = pl.PK_TPLAN
                       AND ap.FK_TASIGNATURA = v_asig AND ap.ACTIVE = TRUE
                  JOIN academico_test.TASIGNATURA s ON s.PK_TASIGNATURA = v_asig AND s.ACTIVE = TRUE
                 WHERE gr.PK_TGRUPO = v_grupo AND gr.ACTIVE = TRUE
            ) THEN
                RAISE EXCEPTION 'La asignatura % no corresponde al grupo % en el plan del periodo', v_asig, v_grupo
                    USING ERRCODE = '22023';
            END IF;

            -- A partir de aqui asignatura y grupo estan confirmados activos por el
            -- chequeo anterior; se resuelven sus nombres para los mensajes de
            -- conflicto/duplicado de abajo.
            SELECT s2.NOMBRE, g2.NOMBRE || ' ' || gr2.NOMBRE
              INTO v_nombre_asig, v_nombre_grupo
              FROM academico_test.TASIGNATURA s2
              JOIN academico_test.TGRUPO gr2 ON gr2.PK_TGRUPO = v_grupo
              JOIN academico_test.TGRADO g2 ON g2.PK_TGRADO = gr2.FK_TGRADO
             WHERE s2.PK_TASIGNATURA = v_asig;

            -- Conflicto: la materia-grupo ya esta asignada a OTRO docente en el periodo.
            IF EXISTS (
                SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA
                 WHERE FK_TGRUPO = v_grupo AND FK_TASIGNATURA = v_asig
                   AND FK_TPERIODO_ACADEMICO = p_academic_period_id AND ACTIVE = TRUE
                   AND FK_TFUNCIONARIO <> v_func
            ) THEN
                RAISE EXCEPTION 'La asignatura "%" en el grupo "%" ya esta asignada a otro docente en el periodo',
                    v_nombre_asig, v_nombre_grupo USING ERRCODE = '23505';
            END IF;

            -- Duplicado dentro del mismo guardado (ya insertado en este loop).
            IF EXISTS (
                SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA
                 WHERE FK_TGRUPO = v_grupo AND FK_TASIGNATURA = v_asig
                   AND FK_TPERIODO_ACADEMICO = p_academic_period_id AND ACTIVE = TRUE
                   AND FK_TFUNCIONARIO = v_func
            ) THEN
                RAISE EXCEPTION 'La asignatura "%" en el grupo "%" esta duplicada en la asignacion',
                    v_nombre_asig, v_nombre_grupo USING ERRCODE = '23505';
            END IF;

            INSERT INTO academico_test.TDOCENTE_ASIGNATURA
                (FK_TGRUPO, FK_TFUNCIONARIO, FK_TASIGNATURA, FK_TPERIODO_ACADEMICO, CREATED_BY)
            VALUES (v_grupo, v_func, v_asig, p_academic_period_id, v_audit);
            v_count := v_count + 1;
        END LOOP;
    END IF;

    RETURN v_count;
END;
$function$;

-- ===========================================================================
-- Consolidacion adicional para autocontener el modulo "asignacion academica":
-- ademas de fn_asignacion_guardar, el modulo (creado en V46) incluye
-- fn_asignacion_docente (sin cambios de cuerpo entre V46 y V99, no se
-- duplica aqui por regla 5), fn_asignacion_pool y fn_asignacion_docente_listar
-- -- estas dos ULTIMAS SI tuvieron cambios de cuerpo antes de V100 que este
-- archivo aun no incluia (V109 solo tocaba fn_asignacion_guardar):
--
--   fn_asignacion_docente_listar: creada en V46 (SELECT plano, sin paginar).
--     V83__add_asignacion_docentes_listar_endpoint.sql le cambio la firma
--     (agrego p_page_index/p_page_size/p_sort_by/p_sort_dir + total_count,
--     mismo patron de fn_periodo_listar) y de paso dio de alta su endpoint.
--     V84__fix_asignacion_docentes_listar_order_by.sql corrigio un bug de esa
--     misma migracion: las columnas del SELECT interno (subconsulta `t`) no
--     tenian alias, asi que el ORDER BY externo (funcionario_id) y el
--     whitelist de columnas ordenables (u.IDENTIFICACION/u.ESTADO, referencias
--     a un alias que solo existe dentro de la subconsulta) fallaban en
--     runtime. No hay otro cambio de cuerpo antes de V100 -> V84 es el estado
--     vigente, se copia completo abajo (con su DROP FUNCTION IF EXISTS previo,
--     la firma cambio en V83).
--
--   fn_asignacion_pool: creada en V46 (sin columna funcionario_id, y con
--     "p_solo_sin_docente" usado directo sin COALESCE). Cambio de cuerpo en
--     dos pasos antes de V100:
--       V87__fix_asignacion_pool_solo_sin_docente_null.sql: el query-service
--         siempre manda el parametro (aunque el front no lo pida), asi que
--         "no enviado" llega como NULL, no como "omitido" -- con el DEFAULT
--         FALSE original, `NOT p_solo_sin_docente OR ...` evaluaba a NULL y
--         WHERE lo trataba como "no matchea", ocultando filas con docente
--         asignado aun sin pedir el filtro. Fix: COALESCE(p_solo_sin_docente,
--         FALSE).
--       V89__fn_asignacion_pool_incluye_funcionario_actual.sql: agrego la
--         columna funcionario_id (LEFT JOIN a TDOCENTE_ASIGNATURA) para que
--         el front pueda distinguir "libre" de "tomado por otro docente" del
--         de "tomado por el docente que se esta editando" sin depender solo
--         de p_solo_sin_docente. Este CREATE OR REPLACE YA incluye el
--         COALESCE de V87 (no lo revierte), asi que V89 es el estado vigente
--         justo antes de V100 -- se copia completo abajo (con su DROP
--         FUNCTION IF EXISTS previo, la firma de columnas de salida cambio).
--
-- Los cambios de V85/V86/V88 (mover PERIODO_ACADEMICO_ID/ACADEMIC_PERIOD_ID/
-- ID de query-string a path-param) son UPDATE sobre el catalogo public.query
-- (routing del endpoint), no redefinen el cuerpo de ninguna funcion PL/pgSQL
-- -- fuera del alcance de esta consolidacion (que es sobre funciones de
-- academico_test), no se duplican aqui para no arriesgar un UPDATE
-- inconsistente sobre una fila de catalogo que ya fue migrada en su momento.
-- ===========================================================================

SET search_path TO academico_test, public;

DROP FUNCTION IF EXISTS academico_test.fn_asignacion_docente_listar(BIGINT, TEXT, TEXT, BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_docente_listar(
    p_academic_period_id BIGINT,
    p_estado             TEXT DEFAULT NULL,
    p_filtro             TEXT DEFAULT NULL,
    p_pk_usuario         BIGINT DEFAULT NULL,
    p_page_index         INT  DEFAULT 0,
    p_page_size          INT  DEFAULT 10,
    p_sort_by            TEXT DEFAULT NULL,
    p_sort_dir           TEXT DEFAULT NULL
)
RETURNS TABLE (
    funcionario_id BIGINT, document_number VARCHAR, nombre_completo TEXT, estado TEXT,
    total_count BIGINT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_col TEXT;
    v_dir TEXT;
BEGIN
    v_col := CASE lower(coalesce(p_sort_by, ''))
        WHEN 'documentnumber' THEN 'document_number'
        WHEN 'status'         THEN 'estado'
        ELSE 'nombre_completo'
    END;
    v_dir := CASE WHEN lower(coalesce(p_sort_dir, '')) = 'desc' THEN 'DESC' ELSE 'ASC' END;

    RETURN QUERY EXECUTE format($q$
        SELECT * FROM (
            SELECT DISTINCT f.PK_TFUNCIONARIO AS funcionario_id, u.IDENTIFICACION AS document_number,
                   TRIM(concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO))
                       AS nombre_completo,
                   u.ESTADO::text AS estado,
                   count(*) OVER()::BIGINT AS total_count
              FROM academico_test.TPERIODO_ACADEMICO pa
              JOIN academico_test.TSEDE_USUARIO su ON su.FK_TSEDE = pa.FK_TSEDE AND su.ACTIVE = TRUE
                                                  AND su.FK_TROL = 14  -- rol Docente
              JOIN academico_test.TUSUARIO u      ON u.PK_TUSUARIO = su.FK_TUSUARIO AND u.ACTIVE = TRUE
              JOIN academico_test.TFUNCIONARIO f  ON f.FK_TUSUARIO = u.PK_TUSUARIO AND f.ACTIVE = TRUE
             WHERE pa.PK_TPERIODO_ACADEMICO = $1
               AND academico_test.fn_periodo_usuario_puede_ver($4, $1)
               AND (NULLIF(TRIM($2),'') IS NULL OR u.ESTADO::text = $2)
               AND (NULLIF(TRIM($3),'') IS NULL
                    OR u.IDENTIFICACION ILIKE '%%' || $3 || '%%'
                    OR TRIM(concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO))
                       ILIKE '%%' || $3 || '%%')
        ) t
         ORDER BY %s %s, funcionario_id
         LIMIT NULLIF($6, 0)
        OFFSET COALESCE($5, 0) * COALESCE(NULLIF($6, 0), 0)
    $q$, v_col, v_dir)
    USING p_academic_period_id, p_estado, p_filtro, p_pk_usuario, p_page_index, p_page_size;
END;
$$;

DROP FUNCTION IF EXISTS academico_test.fn_asignacion_pool(BIGINT, TEXT, BOOLEAN, BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_pool(
    p_academic_period_id BIGINT,
    p_filtro             TEXT    DEFAULT NULL,
    p_solo_sin_docente   BOOLEAN DEFAULT FALSE,
    p_pk_usuario         BIGINT  DEFAULT NULL
)
RETURNS TABLE (
    id TEXT, nombre VARCHAR, grado_grupo TEXT, jornada VARCHAR, jornada_name VARCHAR,
    funcionario_id BIGINT
)
LANGUAGE sql STABLE AS $$
    SELECT gr.PK_TGRUPO || ':' || s.PK_TASIGNATURA, s.NOMBRE,
           g.NOMBRE || ' ' || gr.NOMBRE, jor.VALOR, jor.NOMBRE, da.FK_TFUNCIONARIO
      FROM academico_test.TGRADO g
      JOIN academico_test.TGRUPO gr            ON gr.FK_TGRADO = g.PK_TGRADO AND gr.ACTIVE = TRUE
      JOIN academico_test.TPLAN p              ON p.FK_TGRADO = g.PK_TGRADO AND p.ACTIVE = TRUE
      JOIN academico_test.TASIGNATURA_PLAN ap  ON ap.FK_TPLAN = p.PK_TPLAN AND ap.ACTIVE = TRUE
      JOIN academico_test.TASIGNATURA s        ON s.PK_TASIGNATURA = ap.FK_TASIGNATURA AND s.ACTIVE = TRUE
      LEFT JOIN academico_test.TLISTA_VALOR jor ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
      LEFT JOIN academico_test.TDOCENTE_ASIGNATURA da
             ON da.FK_TGRUPO = gr.PK_TGRUPO AND da.FK_TASIGNATURA = s.PK_TASIGNATURA
            AND da.FK_TPERIODO_ACADEMICO = p_academic_period_id AND da.ACTIVE = TRUE
     WHERE g.FK_TPERIODO_ACADEMICO = p_academic_period_id AND g.ACTIVE = TRUE
       AND academico_test.fn_periodo_usuario_puede_ver(p_pk_usuario, p_academic_period_id)
       AND (NULLIF(TRIM(p_filtro),'') IS NULL
            OR s.NOMBRE  ILIKE '%' || p_filtro || '%'
            OR g.NOMBRE  ILIKE '%' || p_filtro || '%'
            OR gr.NOMBRE ILIKE '%' || p_filtro || '%'
            OR jor.VALOR ILIKE '%' || p_filtro || '%')
       -- Se conserva por compatibilidad: TRUE sigue significando "solo
       -- libres". El front ya no lo manda -- filtra "libre vs. de otro
       -- docente" con `funcionario_id` en el cliente.
       AND (NOT COALESCE(p_solo_sin_docente, FALSE) OR da.FK_TFUNCIONARIO IS NULL)
     ORDER BY g.NOMBRE, gr.NOMBRE, s.NOMBRE;
$$;

-- Consolidado desde V126 (fn_asignacion_docente_listar_estado_de_sede_usuario.sql,
-- de la rama feature, eliminada por colision de numero de version con dev):
-- bug de scope -- fn_asignacion_docente_listar filtraba/devolvia
-- TUSUARIO.ESTADO (estado GLOBAL de la cuenta) en vez de
-- TSEDE_USUARIO.TLV_ESTADO (el estado del docente EN LA SEDE de este
-- periodo puntual, el mismo campo que ya usan fn_grupo_crear/
-- fn_grupo_actualizar para validar el director de grupo). Un docente puede
-- estar activo globalmente pero con otro estado en una sede especifica.
-- Reemplaza la definicion de fn_asignacion_docente_listar de mas arriba en
-- este archivo.
CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_docente_listar(p_academic_period_id bigint, p_estado text DEFAULT NULL::text, p_filtro text DEFAULT NULL::text, p_pk_usuario bigint DEFAULT NULL::bigint, p_page_index integer DEFAULT 0, p_page_size integer DEFAULT 10, p_sort_by text DEFAULT NULL::text, p_sort_dir text DEFAULT NULL::text)
 RETURNS TABLE(funcionario_id bigint, document_number character varying, nombre_completo text, estado text, total_count bigint)
 LANGUAGE plpgsql
 STABLE
AS $$
DECLARE
    v_col TEXT;
    v_dir TEXT;
BEGIN
    v_col := CASE lower(coalesce(p_sort_by, ''))
        WHEN 'documentnumber' THEN 'document_number'
        WHEN 'status'         THEN 'estado'
        ELSE 'nombre_completo'
    END;
    v_dir := CASE WHEN lower(coalesce(p_sort_dir, '')) = 'desc' THEN 'DESC' ELSE 'ASC' END;

    RETURN QUERY EXECUTE format($q$
        SELECT * FROM (
            SELECT DISTINCT f.PK_TFUNCIONARIO AS funcionario_id, u.IDENTIFICACION AS document_number,
                   TRIM(concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO))
                       AS nombre_completo,
                   su.TLV_ESTADO::text AS estado,
                   count(*) OVER()::BIGINT AS total_count
              FROM academico_test.TPERIODO_ACADEMICO pa
              JOIN academico_test.TSEDE_USUARIO su ON su.FK_TSEDE = pa.FK_TSEDE AND su.ACTIVE = TRUE
                                                  AND su.FK_TROL = 14  -- rol Docente
              JOIN academico_test.TUSUARIO u      ON u.PK_TUSUARIO = su.FK_TUSUARIO AND u.ACTIVE = TRUE
              JOIN academico_test.TFUNCIONARIO f  ON f.FK_TUSUARIO = u.PK_TUSUARIO AND f.ACTIVE = TRUE
             WHERE pa.PK_TPERIODO_ACADEMICO = $1
               AND academico_test.fn_periodo_usuario_puede_ver($4, $1)
               AND (NULLIF(TRIM($2),'') IS NULL OR su.TLV_ESTADO = $2)
               AND (NULLIF(TRIM($3),'') IS NULL
                    OR u.IDENTIFICACION ILIKE '%%' || $3 || '%%'
                    OR TRIM(concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO))
                       ILIKE '%%' || $3 || '%%')
        ) t
         ORDER BY %s %s, funcionario_id
         LIMIT NULLIF($6, 0)
        OFFSET COALESCE($5, 0) * COALESCE(NULLIF($6, 0), 0)
    $q$, v_col, v_dir)
    USING p_academic_period_id, p_estado, p_filtro, p_pk_usuario, p_page_index, p_page_size;
END;
$$;
