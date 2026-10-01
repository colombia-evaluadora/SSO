-- ===========================================================================
-- V446 - El alcance de un rol deja de derramarse a los demas establecimientos.
--
--   fn_usuario_solo_sus_grupos(usuario)
--     -> fn_usuario_solo_sus_grupos(usuario, sede, jornada)
--
--
-- EL FALLO
--   Un rector del establecimiento A que ademas es DOCENTE en una sede del
--   establecimiento B veia los informes de TODOS los grupos de esa sede de B,
--   no solo los suyos. Reproducido contra datos reales:
--
--     antes de darle el rol de docente en B -> 42501 (no alcanza)
--     despues                               -> 54 grupos de la sede de B
--
--   El gate no es el culpable: el paso 2.c de fn_assert_permiso_seccion lo
--   autoriza por el par (sede, jornada) donde SI es docente, y eso esta bien
--   -- como docente tiene algo que hacer ahi.
--
--   El culpable es el recorte de la V489. fn_usuario_solo_sus_grupos se
--   evaluaba sobre el usuario ENTERO:
--
--     SELECT COUNT(*) > 0 AND NOT BOOL_OR(fn_rol_alcance_sede(su.FK_TROL))
--       FROM TSEDE_USUARIO su WHERE su.FK_TUSUARIO = p_pk_tusuario AND ACTIVE
--
--   Su rol de rector -- en el OTRO establecimiento -- otorga alcance de sede,
--   asi que BOOL_OR daba TRUE, la funcion devolvia FALSE y el filtro no se
--   aplicaba en ninguna parte. La amplitud de un rol se derramaba a los demas
--   establecimientos.
--
--
-- LA REGLA CORRECTA
--   La pregunta no es "¿este usuario tiene en algun lado un rol amplio?" sino
--   "¿lo tiene AQUI?". Un rol alcanza la sede consultada cuando:
--
--     (a) tiene un TSEDE_USUARIO activo en esa misma sede -- y, si es de
--         nivel 3, en esa misma jornada: un coordinador de la tarde no manda
--         en la mañana;
--     (b) tiene un rol de nivel <= 2 en CUALQUIER sede del mismo
--         establecimiento -- un rol de establecimiento cubre todo su EE, no
--         solo la sede donde quedo registrado;
--     (c) es rector o secretaria de ese establecimiento por puntero, sin
--         TSEDE_USUARIO de por medio.
--
--   Sin (c) un rector que solo figura por puntero se quedaria sin ver su
--   propio establecimiento, que es el error contrario.
--
--
-- COMPATIBILIDAD
--   La sede es OPCIONAL y sin ella la funcion responde exactamente lo de
--   antes -- solo TSEDE_USUARIO, sin mirar punteros --, asi que ningun
--   llamador que todavia no la pase cambia de comportamiento. Los seis que
--   existen hoy se actualizan en la V447; el DEFAULT esta para que las dos
--   migraciones puedan desplegarse uma detras de otra sin romper nada en el
--   medio.
--
-- Hace falta DROP: CREATE OR REPLACE no puede agregar parametros.
-- Idempotente: DROP ... IF EXISTS + CREATE.
-- ===========================================================================

DROP FUNCTION IF EXISTS academico_test.fn_usuario_solo_sus_grupos(BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_usuario_solo_sus_grupos(BIGINT, BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_usuario_solo_sus_grupos(
    p_pk_tusuario     BIGINT,
    p_fk_tsede        BIGINT DEFAULT NULL,
    p_fk_tlv_jornada  BIGINT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    WITH ee_objetivo AS (
        SELECT s.FK_TESTABLECIMIENTO AS ee
          FROM academico_test.TSEDE s
         WHERE p_fk_tsede IS NOT NULL
           AND s.PK_TSEDE = p_fk_tsede
    ),
    roles_que_aplican AS (
        -- (a) y (b): los TSEDE_USUARIO que alcanzan la sede consultada.
        SELECT academico_test.fn_rol_alcance_sede(su.FK_TROL) AS da_sede
          FROM academico_test.TSEDE_USUARIO su
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
         WHERE su.FK_TUSUARIO = p_pk_tusuario
           AND su.ACTIVE      = TRUE
           AND (
                p_fk_tsede IS NULL                       -- sin sede: como antes
                OR su.FK_TSEDE = p_fk_tsede              -- (a) la sede misma
                OR (academico_test.fn_rol_categoria_nivel(su.FK_TROL) <= 2
                    AND s.FK_TESTABLECIMIENTO IN (SELECT ee FROM ee_objetivo))
               )                                         -- (b) todo el EE
           AND (
                p_fk_tlv_jornada IS NULL
                -- La jornada solo distingue a los roles de sede (nivel 3):
                -- un rol de establecimiento vale para todas.
                OR academico_test.fn_rol_categoria_nivel(su.FK_TROL) <= 2
                OR su.FK_TLV_JORNADA = p_fk_tlv_jornada
               )

        UNION ALL

        -- (c) Rector o secretaria por puntero del EE dueño de esa sede. Solo
        --     cuando hay sede objetivo: sin ella se conserva el
        --     comportamiento historico, que nunca miro los punteros.
        SELECT TRUE
          FROM academico_test.TESTABLECIMIENTO e
          JOIN academico_test.TFUNCIONARIO f
            ON f.PK_TFUNCIONARIO IN (e.FK_TFUNCIONARIO_RECTOR,
                                     e.FK_TFUNCIONARIO_SECRETARIA)
         WHERE p_fk_tsede IS NOT NULL
           AND e.ACTIVE = TRUE
           AND f.ACTIVE = TRUE
           AND f.FK_TUSUARIO = p_pk_tusuario
           AND e.PK_ESTABLECIMIENTO IN (SELECT ee FROM ee_objetivo)
    )
    SELECT COUNT(*) > 0 AND NOT BOOL_OR(da_sede)
      FROM roles_que_aplican;
$$;

COMMENT ON FUNCTION academico_test.fn_usuario_solo_sus_grupos(BIGINT, BIGINT, BIGINT)
    IS 'TRUE cuando al usuario, EN LA SEDE CONSULTADA, solo le corresponden los grupos que dirige. Un rol alcanza esa sede si (a) tiene un TSEDE_USUARIO activo ahi -- y en esa jornada, si es de nivel 3: un coordinador de la tarde no manda en la mañana --, (b) tiene un rol de nivel <=2 en cualquier sede del mismo establecimiento, o (c) es rector/secretaria de ese establecimiento por puntero. Antes se evaluaba sobre el usuario entero y la amplitud de un rol se derramaba a los demas establecimientos: un rector de A que era docente en B veia TODOS los grupos de la sede de B. La sede es opcional y sin ella responde lo mismo que la version anterior (solo TSEDE_USUARIO, sin punteros), para que el despliegue pueda ir en dos pasos. La lista de roles que otorgan sede sigue siendo la whitelist de fn_rol_alcance_sede (V489).';
