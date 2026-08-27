-- =============================================================================
-- V114 — reaplica el "p_page_size NULL = sin limite" a fn_usu_empleados_listar,
--        que V112 revirtio sin querer.
--
-- Que paso: V66 parcheo las tres funciones de listado para que un p_page_size
-- NULL signifique "sin limite" (lo que necesita el reporte sin paginar). Pero
-- V112 (fix_listado_funcionarios_performance) reescribe fn_usu_empleados_listar
-- entera, y 112 > 66, asi que Flyway la aplica DESPUES y se lleva puesto el
-- parche. fn_est_listar y fn_sed_listar no las toca nadie mas y siguen bien.
--
-- El sintoma era silencioso y por eso peligroso: el endpoint de reporte
-- respondia 200 con un PDF valido… de 10 filas, que es el page-size por
-- defecto. Nada fallaba; el reporte simplemente estaba incompleto.
--
-- Esta migracion NO revierte V112. Parte de la definicion ACTUAL de la funcion
-- —con todo el trabajo de performance de V112 adentro— y le vuelve a aplicar
-- las dos unicas lineas del parche:
--
--   1. v_page_size: NULL se propaga como NULL en vez de caer al default de 10.
--      Para cualquier valor NO nulo el comportamiento es identico, incluido el
--      0 -> 10 y el tope de 100 (la rama vieja quedo entera dentro del ELSE).
--   2. OFFSET: COALESCE(v_page_size, 0) para no propagar el NULL.
--
-- El wrapper fn_usu_empleados_listar_paginado NO se toca: ya reenvia a la
-- funcion interna los valores normalizados (v_page_index / v_page_size), asi
-- que el endpoint paginado no puede quedar sin tope ni por accidente.
--
-- Sobre el numero: 114 y no 66-bis porque Flyway ordena por version y la unica
-- forma de ganarle a V112 es ir despues. Cuidado a futuro — cualquier
-- migracion posterior que reescriba esta funcion va a volver a borrar el
-- parche, y otra vez en silencio. Lo que cierra el agujero de verdad es que
-- ese "sin limite" viva en la funcion de origen y no como parche encima.
-- =============================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_usu_empleados_listar(p_pk_usuario_solicitante bigint, p_search character varying DEFAULT NULL::character varying, p_roles bigint[] DEFAULT NULL::bigint[], p_work_schedules bigint[] DEFAULT NULL::bigint[], p_statuses character varying[] DEFAULT NULL::character varying[], p_campus_id bigint DEFAULT NULL::bigint, p_sort_campo character varying DEFAULT NULL::character varying, p_sort_desc boolean DEFAULT false, p_page_index integer DEFAULT 0, p_page_size integer DEFAULT 10)
 RETURNS TABLE(pk_empleado bigint, numero_documento character varying, primer_nombre character varying, segundo_nombre character varying, primer_apellido character varying, segundo_apellido character varying, nombre_completo character varying, fk_estado character varying, estado_label character varying, jornada_id bigint, jornada_nombre character varying, roles jsonb, sedes jsonb, estados_permisos jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_page_size  INT := CASE
        WHEN p_page_size IS NULL THEN NULL   -- reporte: sin limite
        ELSE LEAST(CASE WHEN p_page_size > 0 THEN p_page_size ELSE 10 END, 100)
    END;
    v_page_index INT := GREATEST(COALESCE(p_page_index, 0), 0);
    v_es_super   BOOLEAN := academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante);
    v_fk_establecimiento BIGINT := academico_test.fn_resolver_establecimiento_unico(p_pk_usuario_solicitante);
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT v_es_super AND v_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    WITH funcionarios_ee AS (
        SELECT e.FK_TFUNCIONARIO_RECTOR AS pk_tfuncionario
          FROM academico_test.TESTABLECIMIENTO e
         WHERE e.PK_ESTABLECIMIENTO = v_fk_establecimiento AND e.ACTIVE = TRUE
           AND e.FK_TFUNCIONARIO_RECTOR IS NOT NULL
        UNION
        SELECT e.FK_TFUNCIONARIO_SECRETARIA
          FROM academico_test.TESTABLECIMIENTO e
         WHERE e.PK_ESTABLECIMIENTO = v_fk_establecimiento AND e.ACTIVE = TRUE
           AND e.FK_TFUNCIONARIO_SECRETARIA IS NOT NULL
        UNION
        SELECT f2.PK_TFUNCIONARIO
          FROM academico_test.TFUNCIONARIO f2
         WHERE f2.FK_ESTABLECIMIENTO = v_fk_establecimiento AND f2.ACTIVE = TRUE
        UNION
        SELECT f3.PK_TFUNCIONARIO
          FROM academico_test.TFUNCIONARIO f3
          JOIN academico_test.TSEDE_USUARIO su ON su.FK_TUSUARIO = f3.FK_TUSUARIO AND su.ACTIVE = TRUE
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
         WHERE s.FK_TESTABLECIMIENTO = v_fk_establecimiento AND f3.ACTIVE = TRUE
    ),
    -- Funcionarios visibles que matchean search/estado/roles/campus/jornada.
    -- A lo sumo el total de funcionarios activos del sistema (o del
    -- establecimiento si no es superadmin) — nunca el universo de
    -- TSEDE_USUARIO. sedes_agg/estados_agg/roles_agg/jornada YA NO se
    -- calculan aqui: se resuelven mas abajo, por fila, despues de
    -- ORDER BY + LIMIT (punto 1 del header).
    base AS (
        SELECT DISTINCT f.PK_TFUNCIONARIO, u.PK_TUSUARIO, u.IDENTIFICACION,
               u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
               u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO,
               u.ESTADO
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TUSUARIO      u ON u.PK_TUSUARIO = f.FK_TUSUARIO
         WHERE f.ACTIVE = TRUE
           AND (v_es_super OR f.PK_TFUNCIONARIO IN (SELECT pk_tfuncionario FROM funcionarios_ee))
           AND (NULLIF(TRIM(p_search), '') IS NULL
                OR (COALESCE(u.PRIMER_NOMBRE,'') || ' ' || COALESCE(u.SEGUNDO_NOMBRE,'') || ' ' ||
                    COALESCE(u.PRIMER_APELLIDO,'') || ' ' || COALESCE(u.SEGUNDO_APELLIDO,'') || ' ' ||
                    COALESCE(u.IDENTIFICACION,'')) ILIKE '%' || p_search || '%'
                OR EXISTS (
                    SELECT 1 FROM academico_test.TSEDE_USUARIO su2
                      JOIN academico_test.TSEDE  s ON s.PK_TSEDE = su2.FK_TSEDE
                      JOIN academico_test.TROL   r ON r.PK_TROL  = su2.FK_TROL
                     WHERE su2.FK_TUSUARIO = u.PK_TUSUARIO
                       AND su2.ACTIVE      = TRUE
                       AND (s.NOMBRE ILIKE '%' || p_search || '%'
                            OR r.NOMBRE ILIKE '%' || p_search || '%')
                  )
           )
           AND (p_statuses IS NULL OR CARDINALITY(p_statuses) = 0
                OR u.ESTADO = ANY(
                    SELECT CASE
                             WHEN x = 'ACTIVE'    THEN 'A'
                             WHEN x = 'SUSPENDED' THEN 'I'
                           END
                      FROM unnest(p_statuses) AS x
                     WHERE x IN ('ACTIVE','SUSPENDED')
                ))
           AND (p_campus_id IS NULL OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su3
                 WHERE su3.FK_TUSUARIO = u.PK_TUSUARIO
                   AND su3.ACTIVE      = TRUE
                   AND su3.FK_TSEDE    = p_campus_id
           ))
           AND (p_roles IS NULL OR CARDINALITY(p_roles) = 0 OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su4
                 WHERE su4.FK_TUSUARIO = u.PK_TUSUARIO
                   AND su4.ACTIVE      = TRUE
                   AND su4.FK_TROL     = ANY(p_roles)
           ))
           AND (p_work_schedules IS NULL OR CARDINALITY(p_work_schedules) = 0 OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su5
                 WHERE su5.FK_TUSUARIO    = u.PK_TUSUARIO
                   AND su5.ACTIVE         = TRUE
                   AND su5.FK_TLV_JORNADA = ANY(p_work_schedules)
           ))
    )
    SELECT b.PK_TFUNCIONARIO,
           b.IDENTIFICACION,
           b.PRIMER_NOMBRE,
           b.SEGUNDO_NOMBRE,
           b.PRIMER_APELLIDO,
           b.SEGUNDO_APELLIDO,
           TRIM(COALESCE(b.PRIMER_NOMBRE,'') || ' ' || COALESCE(b.SEGUNDO_NOMBRE,'')
                || ' ' || COALESCE(b.PRIMER_APELLIDO,'') || ' ' || COALESCE(b.SEGUNDO_APELLIDO,''))::VARCHAR AS nombre_completo,
           b.ESTADO::VARCHAR AS fk_estado,
           (CASE b.ESTADO
                WHEN 'A' THEN 'ACTIVE'
                WHEN 'I' THEN 'SUSPENDED'
                ELSE NULL
           END)::VARCHAR      AS estado_label,
           jp.jornada_id,
           jp.jornada_nombre,
           -- roles_agg: ya era una subquery correlacionada (patron correcto,
           -- sin cambios). Se evalua solo para las filas que sobreviven
           -- ORDER BY + LIMIT, igual que sedes_agg/estados_agg de abajo.
           COALESCE(
               (SELECT jsonb_agg(DISTINCT role_obj ORDER BY role_obj)
                  FROM (
                      SELECT jsonb_build_object('id', r.PK_TROL, 'nombre', r.NOMBRE) AS role_obj
                        FROM academico_test.TSEDE_USUARIO su_r
                        JOIN academico_test.TROL          r ON r.PK_TROL = su_r.FK_TROL
                       WHERE su_r.FK_TUSUARIO = b.PK_TUSUARIO
                         AND su_r.ACTIVE      = TRUE
                      UNION
                      SELECT jsonb_build_object('id', 7, 'nombre', 'Rector')
                       WHERE EXISTS (
                           SELECT 1 FROM academico_test.TESTABLECIMIENTO e
                            WHERE e.FK_TFUNCIONARIO_RECTOR = b.PK_TFUNCIONARIO AND e.ACTIVE = TRUE
                       )
                      UNION
                      SELECT jsonb_build_object('id', 17, 'nombre', 'Secretaria')
                       WHERE EXISTS (
                           SELECT 1 FROM academico_test.TESTABLECIMIENTO e
                            WHERE e.FK_TFUNCIONARIO_SECRETARIA = b.PK_TFUNCIONARIO AND e.ACTIVE = TRUE
                       )
                  ) roles_union),
               '[]'::jsonb
           )                             AS roles_agg,
           -- sedes_agg / estados_agg: FIX V112. Antes venian de un CTE
           -- `agregados` con GROUP BY sobre TODO TSEDE_USUARIO activo
           -- (126 704 usuarios en el servidor de test), unido con LEFT
           -- JOIN normal -> Postgres no podia empujar el filtro de `base`
           -- adentro y tenia que materializar el agregado completo antes
           -- de filtrar (11.5s medidos, aislado). Ahora son subqueries
           -- correlacionadas directas contra b.PK_TUSUARIO, exactamente
           -- el mismo patron que roles_agg de arriba: Postgres las evalua
           -- perezosamente solo para las <=v_page_size filas finales.
           COALESCE(
               (SELECT jsonb_agg(DISTINCT jsonb_build_object('id', s.PK_TSEDE, 'nombre', s.NOMBRE)
                                  ORDER BY jsonb_build_object('id', s.PK_TSEDE, 'nombre', s.NOMBRE))
                  FROM academico_test.TSEDE_USUARIO su_s
                  JOIN academico_test.TSEDE         s ON s.PK_TSEDE = su_s.FK_TSEDE
                 WHERE su_s.FK_TUSUARIO = b.PK_TUSUARIO AND su_s.ACTIVE = TRUE),
               '[]'::jsonb
           )                             AS sedes_agg,
           COALESCE(
               (SELECT jsonb_agg(DISTINCT su_e.TLV_ESTADO ORDER BY su_e.TLV_ESTADO)
                  FROM academico_test.TSEDE_USUARIO su_e
                 WHERE su_e.FK_TUSUARIO = b.PK_TUSUARIO AND su_e.ACTIVE = TRUE),
               '[]'::jsonb
           )                             AS estados_agg
      FROM base b
      -- jornada: FIX V112. Antes CTE `jornada_pick` con DISTINCT ON sobre
      -- TODO TSEDE_USUARIO activo (mismo problema de alcance que
      -- `agregados`, aunque con costo propio menor: ~165ms aislado por el
      -- sort de 130K filas). LATERAL + LIMIT 1 aplica exactamente la
      -- misma regla (PREDETERMINADO=1 si existe, si no ORDEN minimo) pero
      -- solo para las filas de `base`, y usa
      -- idx_tsede_usuario_fk_tusuario_activo (V112) para resolver el
      -- ORDER BY sin sort.
      LEFT JOIN LATERAL (
            SELECT su.FK_TLV_JORNADA AS jornada_id, tlv.NOMBRE AS jornada_nombre
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TLISTA_VALOR  tlv ON tlv.PK_LISTA_VALOR = su.FK_TLV_JORNADA
             WHERE su.FK_TUSUARIO = b.PK_TUSUARIO AND su.ACTIVE = TRUE
             ORDER BY su.PREDETERMINADO DESC, su.ORDEN ASC, su.PK_TSEDE_USUARIO ASC
             LIMIT 1
      ) jp ON TRUE
     ORDER BY
        CASE WHEN p_sort_campo = 'name'      AND NOT p_sort_desc
             THEN TRIM(COALESCE(b.PRIMER_NOMBRE,'') || ' ' || COALESCE(b.SEGUNDO_NOMBRE,'')
                       || ' ' || COALESCE(b.PRIMER_APELLIDO,'') || ' ' || COALESCE(b.SEGUNDO_APELLIDO,''))
        END ASC,
        CASE WHEN p_sort_campo = 'name'      AND     p_sort_desc
             THEN TRIM(COALESCE(b.PRIMER_NOMBRE,'') || ' ' || COALESCE(b.SEGUNDO_NOMBRE,'')
                       || ' ' || COALESCE(b.PRIMER_APELLIDO,'') || ' ' || COALESCE(b.SEGUNDO_APELLIDO,''))
        END DESC,
        CASE WHEN p_sort_campo = 'document'  AND NOT p_sort_desc THEN b.IDENTIFICACION END ASC,
        CASE WHEN p_sort_campo = 'document'  AND     p_sort_desc THEN b.IDENTIFICACION END DESC,
        CASE WHEN p_sort_campo = 'status'    AND NOT p_sort_desc THEN b.ESTADO END ASC,
        CASE WHEN p_sort_campo = 'status'    AND     p_sort_desc THEN b.ESTADO END DESC,
        b.PRIMER_NOMBRE  ASC,
        b.PRIMER_APELLIDO ASC,
        b.PK_TFUNCIONARIO ASC
     LIMIT v_page_size
    OFFSET v_page_index * COALESCE(v_page_size, 0);
END;
$function$;
