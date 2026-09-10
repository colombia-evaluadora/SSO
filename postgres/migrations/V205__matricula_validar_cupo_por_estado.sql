-- =============================================================================
-- V205 -- fn_matricula_validar_cupo cuenta por ESTADO.
--
-- Pasa a delegar en fn_matricula_cupo_ocupado (V145), que es la definicion
-- unica de "que estado ocupa plaza": Cursando, Aprobado y Reprobado. Un
-- Reubicado o un Promovido ya no gastan silla -- su estudiante esta en el grupo
-- nuevo, contarlo aqui seria contarlo dos veces.
--
-- La razon completa y las mediciones estan en la cabecera de V145.
--
-- Va en migracion nueva y no editando V162, donde vive la funcion, porque V162
-- YA esta aplicada y registrada en flyway_schema_history (28 de agosto).
--
-- Lo unico que cambia es de donde sale v_matriculados. El resto -- el gate, el
-- mensaje, el codigo de error -- se conserva tal cual estaba.
--
-- Idempotente: CREATE OR REPLACE.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_validar_cupo(
    p_fk_grupo BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
AS $function$
DECLARE
    v_capacidad     NUMERIC;
    v_matriculados  BIGINT;
BEGIN
    SELECT CAPACIDAD
      INTO v_capacidad
      FROM academico_test.TGRUPO
     WHERE PK_TGRUPO = p_fk_grupo
       AND ACTIVE    = TRUE;

    IF v_capacidad IS NULL THEN
        RAISE EXCEPTION 'No se encontro un grupo activo con el identificador %',
            p_fk_grupo
            USING ERRCODE = '23503', HINT = 'p_fk_grupo debe apuntar a un TGRUPO activo';
    END IF;

    -- Antes: COUNT(*) de TMATRICULA por grupo, sin mirar el estado. Ver V145.
    v_matriculados := academico_test.fn_matricula_cupo_ocupado(p_fk_grupo);

    IF v_matriculados >= v_capacidad THEN
        RAISE EXCEPTION 'El grupo ya alcanzo su capacidad maxima (% de % cupos ocupados)',
            v_matriculados, v_capacidad
            USING ERRCODE = '22023',
                  HINT    = 'No hay cupos disponibles en este grupo';
    END IF;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_matricula_validar_cupo(BIGINT)
    IS 'Levanta 22023 si el grupo no tiene plazas libres. Las plazas ocupadas las cuenta fn_matricula_cupo_ocupado (V145), que solo considera Cursando, Aprobado y Reprobado: un Reubicado o un Promovido no gastan silla porque su estudiante ya esta en el grupo nuevo. Antes contaba todas las matriculas activas del grupo sin mirar el estado. V205.';
