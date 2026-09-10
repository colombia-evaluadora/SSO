-- ===========================================================================
-- V295 - fn_assert_rango_rol_otorgable: dentro de la MISMA categoria decide
--        PESO_CATEGORIA, no el "igual o superior" a secas.
--
-- POR QUE ESTA MIGRACION EXISTE
--   fn_assert_rango_rol_otorgable (V29) bloquea otorgar un rol cuya
--   categoria sea la MISMA o SUPERIOR a la del solicitante:
--
--       IF v_nivel_solicitante >= v_nivel_rol THEN  -> 42501
--
--   Con eso un Rector (categoria ADMINISTRATIVOS_ESTABLECIMIENTO) no puede
--   otorgar NINGUN rol de su propia categoria -- ni Jefe De Sistema
--   (Establecimiento) ni Auxiliar administrativo -- aunque la sede sea de su
--   establecimiento. Medido en el servidor de test con el rector del EE 887
--   (usuario 197798) asignando en su sede 1664: los roles 7, 8 y 9 daban
--   42501 y solo pasaban del 10 al 16.
--
--   Es un RETROCESO respecto al modelo de permisos fijos. El gate anterior
--   de fn_fun_permisos_actualizar no miraba la categoria del rol: la
--   autoridad se resolvia por SEDE, y una sede "plena" (donde el actor es
--   rector / secretaria / jefe de sistema del EE) admitia CUALQUIER rol --
--   la restriccion "rol >= 9" existia solo para las sedes donde el actor era
--   coordinador:
--
--       AND NOT (v_perm.fk_sede = ANY(v_sedes_plenas))
--       AND NOT (v_perm.fk_sede = ANY(v_sedes_coord) AND v_perm.fk_rol >= 9 ...)
--
--   Un rector tiene que poder nombrar auxiliares y jefes de sistema en las
--   sedes de su establecimiento; eso es su trabajo.
--
-- QUE CAMBIA
--   La comparacion se parte en tres:
--
--     * categoria SUPERIOR a la del solicitante  -> 42501, como antes.
--     * categoria INFERIOR                       -> pasa, como antes.
--     * MISMA categoria                          -> decide PESO_CATEGORIA:
--       solo se puede otorgar un rol de MENOR autoridad, es decir de peso
--       estrictamente MAYOR que el mejor peso del solicitante.
--
--   El peso no se inventa aqui: es el mismo criterio y la misma consulta que
--   ya usa fn_cat_roles_listar (V121) para construir el select de roles del
--   front, punteros de rector/secretaria incluidos. Asi el backend autoriza
--   exactamente lo que el front ofrece, por construccion, en vez de por
--   coincidencia. Hoy, con los pesos sembrados (Rector 1, Jefe De Sistema
--   (Establecimiento) 2, Auxiliar administrativo 3), para un Rector queda:
--
--       rol 7 Rector                            -> 42501  (peso 1, no es menor)
--       rol 8 Jefe De Sistema (Establecimiento) -> pasa    (peso 2 > 1)
--       rol 9 Auxiliar administrativo           -> pasa    (peso 3 > 1)
--       roles 1-6 (categorias superiores)       -> 42501
--       roles 10-16 (categorias inferiores)     -> pasa
--
--   Un rector sigue sin poder nombrar a otro rector, que es el caso que de
--   verdad importa, y ahora lo impide el backend y no solo el front.
--
--   Si el peso no se puede resolver (rol sin PESO_CATEGORIA sembrado, o
--   solicitante sin peso en su categoria mas alta) NO se autoriza: mismo
--   criterio conservador que fn_cat_roles_listar, que en ese caso no ofrece
--   nada de la propia categoria.
--
-- POR QUE ES SEGURO RELAJARLO
--   Porque la autoridad sobre la SEDE se valida aparte, y sigue intacta:
--     * fn_fun_permisos_actualizar comprueba, operacion por operacion, que
--       la sede este en v_sedes_plenas (fn_usuario_ee_accesibles) o en
--       v_sedes_coord (fn_usuario_sedes_jornadas_accesibles), y si no
--       devuelve 'error:sin_permiso_en_sede'.
--     * fn_sede_usuario_crear llama a fn_assert_permiso_seccion con la sede
--       y la jornada como objeto.
--   Este helper solo responde "¿este rol esta por debajo de mi?"; el "¿esta
--   sede es mia?" no era ni es su trabajo.
--
--   Los dos llamadores son fn_fun_permisos_actualizar (V51) y
--   fn_sede_usuario_crear (V111); ninguno cambia de firma.
--
-- QUE NO ARREGLA
--   El crear de sedes. fn_sed_crear propaga el permiso del rector a la sede
--   nueva otorgandole el rol RECTOR, que es justo el que sigue bloqueado
--   -- correctamente -- por la regla de peso. Se corrige en V296 haciendo
--   que la propagacion no pase por la puerta de autorizacion humana.
--
-- Idempotente: CREATE OR REPLACE, misma firma que V29 (no crea sobrecarga).
-- ===========================================================================


CREATE OR REPLACE FUNCTION academico_test.fn_assert_rango_rol_otorgable(
    p_pk_solicitante  BIGINT,
    p_pk_trol         BIGINT
)
RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_nivel_solicitante  INT;
    v_nivel_rol          INT;
    v_peso_rol           NUMERIC;
    v_peso_solicitante   NUMERIC;
    v_nombre_rol         TEXT;
BEGIN
    v_nivel_solicitante := academico_test.fn_usuario_categoria_rol_nivel(p_pk_solicitante);

    -- SUPER_ADMIN: puede otorgar cualquier rol.
    IF v_nivel_solicitante = 0 THEN
        RETURN;
    END IF;

    v_nivel_rol := academico_test.fn_rol_categoria_nivel(p_pk_trol);

    -- Solicitante sin rol activo: no otorga nada. Rol sin categoria
    -- resoluble: tampoco se autoriza a ciegas.
    IF v_nivel_solicitante IS NOT NULL AND v_nivel_rol IS NOT NULL THEN

        -- Categoria estrictamente INFERIOR a la del solicitante: se ofrece
        -- completa, igual que en fn_cat_roles_listar.
        IF v_nivel_solicitante < v_nivel_rol THEN
            RETURN;
        END IF;

        -- MISMA categoria: decide el peso. Solo hacia abajo.
        IF v_nivel_solicitante = v_nivel_rol THEN
            SELECT r.PESO_CATEGORIA
              INTO v_peso_rol
              FROM academico_test.TROL r
             WHERE r.PK_TROL = p_pk_trol
               AND r.ACTIVE = TRUE;

            -- Mejor (MIN) peso entre los roles que el solicitante tiene HOY
            -- y que caen en su categoria mas alta. Los roles se toman igual
            -- que en fn_cat_roles_listar (V121): TSEDE_USUARIO activas mas
            -- los punteros de rector (rol 7) y secretaria (rol 9) del EE,
            -- porque hay establecimientos donde la vinculacion vive solo en
            -- el puntero.
            WITH roles_del_solicitante AS (
                SELECT su.FK_TROL AS pk_trol
                  FROM academico_test.TSEDE_USUARIO su
                 WHERE su.FK_TUSUARIO = p_pk_solicitante
                   AND su.ACTIVE = TRUE
                UNION
                SELECT 7
                  FROM academico_test.TESTABLECIMIENTO e
                  JOIN academico_test.TFUNCIONARIO f
                    ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
                 WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE
                   AND f.FK_TUSUARIO = p_pk_solicitante
                UNION
                SELECT 9
                  FROM academico_test.TESTABLECIMIENTO e
                  JOIN academico_test.TFUNCIONARIO f
                    ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
                 WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE
                   AND f.FK_TUSUARIO = p_pk_solicitante
            )
            SELECT MIN(r.PESO_CATEGORIA)
              INTO v_peso_solicitante
              FROM roles_del_solicitante rs
              JOIN academico_test.TROL r
                ON r.PK_TROL = rs.pk_trol AND r.ACTIVE = TRUE
             WHERE academico_test.fn_rol_categoria_nivel(r.PK_TROL) = v_nivel_solicitante;

            -- Peso estrictamente mayor = menor autoridad = se puede otorgar.
            -- Sin pesos resolubles no se autoriza (igual que el select).
            IF v_peso_rol IS NOT NULL
               AND v_peso_solicitante IS NOT NULL
               AND v_peso_rol > v_peso_solicitante THEN
                RETURN;
            END IF;
        END IF;
    END IF;

    SELECT r.NOMBRE INTO v_nombre_rol
      FROM academico_test.TROL r
     WHERE r.PK_TROL = p_pk_trol;

    RAISE EXCEPTION 'El rol "%" es de categoria igual o superior a la del usuario; no se puede otorgar',
        COALESCE(NULLIF(TRIM(COALESCE(v_nombre_rol, '')), ''), p_pk_trol::TEXT)
        USING ERRCODE = '42501';
END;
$$;

COMMENT ON FUNCTION academico_test.fn_assert_rango_rol_otorgable(BIGINT, BIGINT)
    IS 'Assertion de RANGO al OTORGAR un rol. Nivel 0 (SUPER_ADMIN) otorga cualquiera; un solicitante sin rol activo no otorga ninguno. V295: la comparacion ya no es "categoria igual o superior -> 42501" a secas, sino en tres tramos -- categoria SUPERIOR se rechaza, categoria INFERIOR se permite, y en la MISMA categoria decide TROL.PESO_CATEGORIA: solo se otorga un rol de peso estrictamente MAYOR (menor autoridad) que el mejor peso de los roles que el solicitante tiene hoy en su categoria mas alta, contando TSEDE_USUARIO activas mas los punteros de rector/secretaria del EE. Es el mismo criterio y la misma consulta que fn_cat_roles_listar (V121) usa para el select de roles del front, asi que el backend autoriza exactamente lo que el front ofrece. Si algun peso no es resoluble, no se autoriza. Hacia falta porque el ">=" impedia a un Rector nombrar Jefe De Sistema (Establecimiento) o Auxiliar administrativo en sedes de SU establecimiento -- un retroceso frente al modelo de permisos fijos, donde una sede "plena" admitia cualquier rol y el limite "rol >= 9" era solo para el coordinador. Sigue impidiendo que un rector nombre a otro rector (peso 1 no es mayor que 1), y ahora lo impide el backend, no solo el select. Relajarlo es seguro porque la autoridad sobre la SEDE la validan los llamadores: fn_fun_permisos_actualizar por operacion contra v_sedes_plenas / v_sedes_coord, y fn_sede_usuario_crear via fn_assert_permiso_seccion con sede y jornada.';
