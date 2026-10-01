-- ===========================================================================
-- V496.22 - Regla 85: el Coordinador academico consulta la bitacora de su
-- establecimiento, igual que el Rector (que se queda).
--   1. role_query: CEVAL-COORDINADOR en cada query de audit-clickhouse-cval
--      que hoy tiene CEVAL-RECTOR (listados, stats y exports de V362-V405).
--   2. fn_mi_establecimiento_para_auditoria resuelve tambien al coordinador
--      (TSEDE_USUARIO con TROL.CODIGO = COORDINADOR). Sin esto el claim `est`
--      del JWT llega vacio y el filtro por establecimiento le devuelve 0 filas.
-- Depende de: V362 (funcion y patron de role_query), V180, V496.18 (fn_usuario_sedes_coordinador).
-- ===========================================================================

INSERT INTO public.role_query (role_id, query_id)
SELECT coord.id_role, rq.query_id
  FROM public.role_query rq
  JOIN public.role rector ON rector.id_role = rq.role_id AND rector.name = 'CEVAL-RECTOR'
  JOIN public.query q     ON q.id_query = rq.query_id
  JOIN public.microservice m
    ON m.id_microservice = q.microservice_id
   AND m.serviceid = 'audit-clickhouse-cval'
  CROSS JOIN public.role coord
 WHERE coord.name = 'CEVAL-COORDINADOR'
ON CONFLICT DO NOTHING;


CREATE OR REPLACE FUNCTION academico_test.fn_mi_establecimiento_para_auditoria(
    p_id_user BIGINT
)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pk_tusuario BIGINT;
    v_fk_est      BIGINT;
    v_n           INT;
    v_nombre      TEXT;
BEGIN
    IF p_id_user IS NULL THEN
        RETURN NULL;
    END IF;

    v_pk_tusuario := public.fn_get_academico_usuario_id(p_id_user);
    IF v_pk_tusuario IS NULL THEN
        RETURN NULL;
    END IF;

    -- La llama el login: "sin establecimiento unico" no es un error que
    -- deba propagarse, es un claim vacio.
    BEGIN
        v_fk_est := academico_test.fn_matricula_config_ee_solicitante(v_pk_tusuario);
    EXCEPTION WHEN OTHERS THEN
        v_fk_est := NULL;
    END;

    IF v_fk_est IS NULL THEN
        SELECT COUNT(DISTINCT s.FK_TESTABLECIMIENTO), MIN(s.FK_TESTABLECIMIENTO)
          INTO v_n, v_fk_est
          FROM academico_test.fn_usuario_sedes_coordinador(v_pk_tusuario) sede
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = sede AND s.ACTIVE = TRUE;

        IF v_n IS DISTINCT FROM 1 THEN
            RETURN NULL;
        END IF;
    END IF;

    SELECT NOMBRE INTO v_nombre
      FROM academico_test.TESTABLECIMIENTO
     WHERE PK_ESTABLECIMIENTO = v_fk_est;

    RETURN v_nombre;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_mi_establecimiento_para_auditoria(BIGINT) IS
    'Nombre del unico establecimiento que este usuario (public.users.id_user) administra como rector/secretaria/jefe de sistema (fn_matricula_config_ee_solicitante) o, si no es ninguno de esos, en el que es COORDINADOR (fn_usuario_sedes_coordinador). NULL si no aplica (super-admin, sin rol de EE, o 2+ EE). Lo usa auth-center (EstablishmentResolver) para el claim `est` del JWT que alimenta el filtro de auditoria por establecimiento (Regla 85).';
