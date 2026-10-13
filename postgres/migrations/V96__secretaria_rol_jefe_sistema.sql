-- V96 — La secretaria del establecimiento queda con su rol correcto, Jefe de
-- sistema (JEFE_SISTEMA_ESTABLECIMIENTO), en vez de Auxiliar administrativo.
-- Qué hace: (1) sus permisos de sede con el rol viejo, en sedes de su
-- establecimiento, pasan al nuevo; (2) le da el permiso por defecto (jornada
-- Completa) en las sedes activas de su establecimiento donde no lo tenga;
-- (3) alinea public.role_users (CEVAL y PIGSE). Los auxiliares que no son
-- secretaria no se tocan.
-- Por qué aquí: conversión de datos viejos (out-of-order). El alta y el cambio
-- de secretaria ya asignan el rol nuevo: V414, V399 y V302. Idempotente; en
-- una base limpia no hay roles ni secretarias y no hace nada.

DO $$
DECLARE
    v_aux     BIGINT;
    v_jefe    BIGINT;
    c_jornada CONSTANT BIGINT := 51900;
BEGIN
    SELECT PK_TROL INTO v_aux  FROM academico_test.TROL WHERE CODIGO = 'AUXILIAR_ADMINISTRATIVO';
    SELECT PK_TROL INTO v_jefe FROM academico_test.TROL WHERE CODIGO = 'JEFE_SISTEMA_ESTABLECIMIENTO';
    IF v_aux IS NULL OR v_jefe IS NULL THEN
        RETURN;
    END IF;

    DROP TABLE IF EXISTS tmp_secretaria;
    CREATE TEMP TABLE tmp_secretaria ON COMMIT DROP AS
    SELECT DISTINCT f.FK_TUSUARIO AS fk_tusuario, e.PK_ESTABLECIMIENTO AS pk_ee
      FROM academico_test.TESTABLECIMIENTO e
      JOIN academico_test.TFUNCIONARIO f
        ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA AND f.ACTIVE = TRUE
     WHERE e.ACTIVE = TRUE AND f.FK_TUSUARIO IS NOT NULL;
    IF NOT EXISTS (SELECT 1 FROM tmp_secretaria) THEN
        RETURN;
    END IF;

    PERFORM set_config('app.etiqueta',
        'Secretarias de establecimiento: rol Auxiliar administrativo a Jefe de sistema', true);

    -- (1a) Ya tiene el rol nuevo en esa sede y jornada: se reactiva ese y se
    -- apaga el viejo (la llave única no deja convertirlo).
    UPDATE academico_test.TSEDE_USUARIO j
       SET ACTIVE = TRUE, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TSEDE_USUARIO a
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = a.FK_TSEDE
      JOIN tmp_secretaria t ON t.fk_tusuario = a.FK_TUSUARIO AND t.pk_ee = s.FK_TESTABLECIMIENTO
     WHERE a.FK_TROL = v_aux AND a.ACTIVE = TRUE
       AND j.FK_TROL = v_jefe AND j.FK_TSEDE = a.FK_TSEDE AND j.FK_TUSUARIO = a.FK_TUSUARIO
       AND j.FK_TLV_JORNADA = a.FK_TLV_JORNADA AND j.ACTIVE = FALSE;

    UPDATE academico_test.TSEDE_USUARIO a
       SET ACTIVE = FALSE, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TSEDE s, tmp_secretaria t
     WHERE s.PK_TSEDE = a.FK_TSEDE
       AND t.fk_tusuario = a.FK_TUSUARIO AND t.pk_ee = s.FK_TESTABLECIMIENTO
       AND a.FK_TROL = v_aux AND a.ACTIVE = TRUE
       AND EXISTS (SELECT 1 FROM academico_test.TSEDE_USUARIO j
                    WHERE j.FK_TROL = v_jefe AND j.FK_TSEDE = a.FK_TSEDE
                      AND j.FK_TUSUARIO = a.FK_TUSUARIO AND j.FK_TLV_JORNADA = a.FK_TLV_JORNADA);

    -- (1b) El resto cambia de rol; si su ORDEN ya lo usa otro permiso del rol
    -- nuevo en la sede, toma el siguiente libre.
    WITH convertir AS (
        SELECT a.PK_TSEDE_USUARIO AS pk,
               EXISTS (SELECT 1 FROM academico_test.TSEDE_USUARIO j
                        WHERE j.FK_TROL = v_jefe AND j.FK_TSEDE = a.FK_TSEDE
                          AND j.FK_TUSUARIO = a.FK_TUSUARIO AND j.ORDEN = a.ORDEN) AS choca,
               (SELECT COALESCE(MAX(x.ORDEN), 0) FROM academico_test.TSEDE_USUARIO x
                 WHERE x.FK_TSEDE = a.FK_TSEDE AND x.FK_TUSUARIO = a.FK_TUSUARIO
                   AND x.FK_TROL IN (v_aux, v_jefe))
               + ROW_NUMBER() OVER (PARTITION BY a.FK_TSEDE, a.FK_TUSUARIO ORDER BY a.PK_TSEDE_USUARIO) AS orden_libre
          FROM academico_test.TSEDE_USUARIO a
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = a.FK_TSEDE
          JOIN tmp_secretaria t ON t.fk_tusuario = a.FK_TUSUARIO AND t.pk_ee = s.FK_TESTABLECIMIENTO
         WHERE a.FK_TROL = v_aux AND a.ACTIVE = TRUE
    )
    UPDATE academico_test.TSEDE_USUARIO a
       SET FK_TROL = v_jefe,
           ORDEN = CASE WHEN c.choca THEN c.orden_libre ELSE a.ORDEN END,
           MODIFIED_AT = CURRENT_TIMESTAMP
      FROM convertir c
     WHERE a.PK_TSEDE_USUARIO = c.pk;

    -- (2) Permiso por defecto en las sedes activas donde no tiene el rol nuevo.
    UPDATE academico_test.TSEDE_USUARIO j
       SET ACTIVE = TRUE, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TSEDE s, tmp_secretaria t
     WHERE s.PK_TSEDE = j.FK_TSEDE AND s.ACTIVE = TRUE
       AND t.fk_tusuario = j.FK_TUSUARIO AND t.pk_ee = s.FK_TESTABLECIMIENTO
       AND j.FK_TROL = v_jefe AND j.FK_TLV_JORNADA = c_jornada AND j.ACTIVE = FALSE
       AND NOT EXISTS (SELECT 1 FROM academico_test.TSEDE_USUARIO x
                        WHERE x.FK_TSEDE = j.FK_TSEDE AND x.FK_TUSUARIO = j.FK_TUSUARIO
                          AND x.FK_TROL = v_jefe AND x.ACTIVE = TRUE);

    INSERT INTO academico_test.TSEDE_USUARIO (
        FK_TSEDE, FK_TROL, FK_TUSUARIO, FK_TLV_JORNADA, ORDEN,
        TLV_ESTADO, PREDETERMINADO, CREATED_BY, CREATED_AT, ACTIVE
    )
    SELECT s.PK_TSEDE, v_jefe, t.fk_tusuario, c_jornada,
           (SELECT COALESCE(MAX(x.ORDEN), 0) + 1 FROM academico_test.TSEDE_USUARIO x
             WHERE x.FK_TSEDE = s.PK_TSEDE AND x.FK_TUSUARIO = t.fk_tusuario AND x.FK_TROL = v_jefe),
           'ACTIVO', 0, 'SISTEMA', CURRENT_TIMESTAMP, TRUE
      FROM tmp_secretaria t
      JOIN academico_test.TSEDE s ON s.FK_TESTABLECIMIENTO = t.pk_ee AND s.ACTIVE = TRUE
     WHERE NOT EXISTS (SELECT 1 FROM academico_test.TSEDE_USUARIO x
                        WHERE x.FK_TSEDE = s.PK_TSEDE AND x.FK_TUSUARIO = t.fk_tusuario
                          AND x.FK_TROL = v_jefe
                          AND (x.ACTIVE = TRUE OR x.FK_TLV_JORNADA = c_jornada));

    -- (3) Roles del token, sin depender de la versión de fn_sincronizar_rol_publico
    -- que haya en el servidor cuando esto corre.
    INSERT INTO public.role_users (user_id, role_id)
    SELECT DISTINCT u.id_user, r.id_role
      FROM tmp_secretaria t
      JOIN academico_test.TUSUARIO tu ON tu.PK_TUSUARIO = t.fk_tusuario
      JOIN public.users u ON UPPER(u.email) = UPPER(tu.CUENTA)
      JOIN public.role r ON r.name IN ('CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'PIGSE-JEFE_SISTEMA_ESTABLECIMIENTO')
     WHERE NOT EXISTS (SELECT 1 FROM public.role_users ru
                        WHERE ru.user_id = u.id_user AND ru.role_id = r.id_role);

    DELETE FROM public.role_users ru
     USING public.role r, public.users u, academico_test.TUSUARIO tu, tmp_secretaria t
     WHERE ru.role_id = r.id_role
       AND r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'PIGSE-AUXILIAR_ADMINISTRATIVO')
       AND ru.user_id = u.id_user
       AND UPPER(u.email) = UPPER(tu.CUENTA)
       AND tu.PK_TUSUARIO = t.fk_tusuario
       AND NOT EXISTS (SELECT 1 FROM academico_test.TSEDE_USUARIO su
                        WHERE su.FK_TUSUARIO = t.fk_tusuario AND su.FK_TROL = v_aux AND su.ACTIVE = TRUE)
       AND NOT EXISTS (SELECT 1 FROM academico_test.TENTE_USUARIO eu
                        WHERE eu.FK_TUSUARIO = t.fk_tusuario AND eu.FK_TROL = v_aux AND eu.ACTIVE = TRUE);
END;
$$;
