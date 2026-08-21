-- Bug: al editar el "nombre interno" de una asignatura y guardar, el back
-- terminaba creando una asignatura NUEVA en vez de actualizar la existente.
--
-- Causa: fn_subject_guardar_bulk hace upsert matcheando cada item del bulk
-- contra TASIGNATURA por NOMBRE (UPPER(TRIM(NOMBRE)) = UPPER(TRIM(v_nombre))).
-- Si el usuario cambia el nombre interno, el nombre nuevo no matchea ninguna
-- fila existente -> v_id queda NULL -> INSERT de una fila nueva. Encima, el
-- paso de "reemplazo" (baja logica de las asignaturas que ya no vienen en el
-- set) compara tambien por NOMBRE, así que la fila vieja (con el nombre
-- anterior, que ya no está en el payload) queda marcada como huérfana y se
-- da de baja -> el resultado neto es una asignatura "duplicada": la vieja
-- inactiva y una nueva activa con el nombre editado.
--
-- Fix: el front ya conoce el PK real de cada asignatura editada
-- (`AreaSubjectItem.id`, ver to-asignaturas-payload.ts) — antes se descartaba
-- al armar el payload. Ahora se manda como `id` en cada item del jsonb y el
-- back matchea PRIMERO por ese PK (si vino); solo cae al match por nombre
-- cuando no hay PK (alta nueva, todavía sin fila en TASIGNATURA). El paso de
-- "reemplazo" también respeta ese PK, para no dar de baja por error la fila
-- que se está renombrando (antes de llegar al loop que la actualiza).
CREATE OR REPLACE FUNCTION academico_test.fn_subject_guardar_bulk(p_fk_area bigint, p_asignaturas jsonb, p_pk_usuario_solicitante bigint)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_est BIGINT; v_periodo BIGINT; v_count INT := 0; it jsonb;
    v_id BIGINT; v_pk_hint BIGINT; v_nombre VARCHAR(130); v_codigo VARCHAR(30);
    v_aa BIGINT; v_enf BIGINT; v_esp BIGINT; v_color VARCHAR(10); v_orden NUMERIC;
    v_enf_name TEXT;
    v_nombre_area VARCHAR(130);
    v_nombre_aa VARCHAR(130);
BEGIN
    IF NOT academico_test.fn_periodo_usuario_puede_gestionar(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    -- Periodo y establecimiento del area (valida que el area exista/activa).
    SELECT a.FK_TPERIODO_ACADEMICO, s.FK_TESTABLECIMIENTO INTO v_periodo, v_est
      FROM academico_test.TAREA a
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = a.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE a.PK_TAREA = p_fk_area AND a.ACTIVE = TRUE;
    IF v_est IS NULL THEN
        SELECT NOMBRE INTO v_nombre_area FROM academico_test.TAREA WHERE PK_TAREA = p_fk_area;
        IF v_nombre_area IS NOT NULL THEN
            RAISE EXCEPTION 'El area % existe pero esta inactiva', v_nombre_area USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El area seleccionada no existe' USING ERRCODE = '23503';
        END IF;
    END IF;
    -- Gate fino: el establecimiento del area debe estar en el alcance del usuario.
    IF NOT academico_test.fn_periodo_usuario_puede_escribir(p_pk_usuario_solicitante, v_est) THEN
        RAISE EXCEPTION 'El usuario no puede gestionar datos academicos de este establecimiento'
            USING ERRCODE = '42501';
    END IF;

    -- Reemplazo: baja logica de las asignaturas del area que NO vienen en el set.
    -- Una fila se preserva si su PK viene explicito en el payload (edicion,
    -- incluye renombres) o si su NOMBRE matchea alguno del set (altas nuevas
    -- sin PK todavia).
    UPDATE academico_test.TASIGNATURA
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TAREA = p_fk_area AND ACTIVE = TRUE
       AND PK_TASIGNATURA NOT IN (
           SELECT NULLIF(e->>'id','')::bigint
             FROM jsonb_array_elements(COALESCE(p_asignaturas, '[]'::jsonb)) e
            WHERE NULLIF(e->>'id','') IS NOT NULL
       )
       AND UPPER(TRIM(NOMBRE)) NOT IN (
           SELECT UPPER(TRIM(e->>'nombreInterno'))
             FROM jsonb_array_elements(COALESCE(p_asignaturas, '[]'::jsonb)) e
            WHERE NULLIF(TRIM(e->>'nombreInterno'),'') IS NOT NULL
       );

    FOR it IN SELECT * FROM jsonb_array_elements(COALESCE(p_asignaturas, '[]'::jsonb))
    LOOP
        v_pk_hint  := NULLIF(it->>'id','')::bigint;
        v_nombre   := it->>'nombreInterno';
        v_codigo   := it->>'abreviacion';
        v_color    := NULLIF(it->>'color','');
        v_orden    := COALESCE(NULLIF(it->>'ordenReportes','')::NUMERIC, 0);
        v_enf_name := NULLIF(TRIM(it->>'especialidad'),'');

        IF NULLIF(TRIM(v_nombre),'') IS NULL OR NULLIF(TRIM(v_codigo),'') IS NULL THEN
            RAISE EXCEPTION 'Faltan campos obligatorios de la asignatura' USING ERRCODE = '22023';
        END IF;
        IF v_color IS NOT NULL AND v_color !~ '^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})$' THEN
            RAISE EXCEPTION 'El color (%) debe ser un HEX valido, p.ej. #FFAA00', v_color USING ERRCODE = '22023';
        END IF;
        -- Area general: el front manda el id (fk_area_asignatura), no el nombre.
        v_aa := NULLIF(TRIM(it->>'asignaturaGeneral'),'')::bigint;
        IF v_aa IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM academico_test.TAREA_ASIGNATURA
             WHERE PK_TAREA_ASIGNATURA = v_aa AND ACTIVE = TRUE
        ) THEN
            SELECT NOMBRE INTO v_nombre_aa FROM academico_test.TAREA_ASIGNATURA
             WHERE PK_TAREA_ASIGNATURA = v_aa;
            IF v_nombre_aa IS NOT NULL THEN
                RAISE EXCEPTION 'La asignatura general % ya existe pero esta inactiva', v_nombre_aa USING ERRCODE = '23503';
            ELSE
                RAISE EXCEPTION 'La asignatura general seleccionada no existe' USING ERRCODE = '23503';
            END IF;
        END IF;
        -- Especialidad: si el nombre corresponde a una ESPECIALIDAD global del
        -- catalogo, se resuelve preservandola (crea/reusa enfasis con su
        -- FK_TESPECIALIDAD y codigo incremental, via fn_enfasis_desde_seleccion).
        -- Si es un nombre nuevo (no del catalogo global), cae al resolver por
        -- nombre (enfasis con especialidad "Otro").
        v_enf := NULL;
        IF v_enf_name IS NOT NULL THEN
            SELECT PK_ESPECIALIDAD INTO v_esp FROM academico_test.TESPECIALIDAD
             WHERE ACTIVE = TRUE AND UPPER(TRIM(NOMBRE)) = UPPER(v_enf_name) LIMIT 1;
            IF v_esp IS NOT NULL THEN
                v_enf := academico_test.fn_enfasis_desde_seleccion(v_periodo, v_esp, v_audit);
            ELSE
                v_enf := academico_test.fn_enfasis_resolver(v_est, v_enf_name, NULL, p_pk_usuario_solicitante);
            END IF;
        END IF;

        -- Match: primero por PK explicito (edicion, incluye renombres); si no
        -- vino o no matchea una fila propia del area, cae al match por
        -- nombre (alta nueva o payloads legados sin PK).
        v_id := NULL;
        IF v_pk_hint IS NOT NULL THEN
            SELECT PK_TASIGNATURA INTO v_id FROM academico_test.TASIGNATURA
             WHERE PK_TASIGNATURA = v_pk_hint AND FK_TAREA = p_fk_area AND ACTIVE = TRUE;
        END IF;
        IF v_id IS NULL THEN
            SELECT PK_TASIGNATURA INTO v_id FROM academico_test.TASIGNATURA
             WHERE FK_TAREA = p_fk_area AND ACTIVE = TRUE
               AND UPPER(TRIM(NOMBRE)) = UPPER(TRIM(v_nombre)) LIMIT 1;
        END IF;
        -- Codigo unico en el area (excluyendo la fila que se va a actualizar).
        IF EXISTS (
            SELECT 1 FROM academico_test.TASIGNATURA s
             WHERE s.FK_TAREA = p_fk_area AND s.ACTIVE = TRUE
               AND s.PK_TASIGNATURA <> COALESCE(v_id, -1)
               AND UPPER(TRIM(s.CODIGO)) = UPPER(TRIM(v_codigo))
        ) THEN
            RAISE EXCEPTION 'Ya existe una asignatura con la abreviacion % en esta area', v_codigo USING ERRCODE = '23505';
        END IF;

        IF v_id IS NULL THEN
            INSERT INTO academico_test.TASIGNATURA
                (CODIGO, NOMBRE, FK_TAREA, FK_TAREA_ASIGNATURA, FK_TENFASIS, COLOR, ORDEN_REPORTE, CREATED_BY)
            VALUES (v_codigo, v_nombre, p_fk_area, v_aa, v_enf, v_color, v_orden, v_audit);
        ELSE
            UPDATE academico_test.TASIGNATURA SET
                CODIGO = v_codigo,
                NOMBRE = v_nombre,
                FK_TAREA_ASIGNATURA = v_aa,
                FK_TENFASIS = v_enf,
                COLOR = v_color,
                ORDEN_REPORTE = v_orden,
                MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
             WHERE PK_TASIGNATURA = v_id;
        END IF;
        v_count := v_count + 1;
    END LOOP;
    RETURN v_count;
END;
$function$;
