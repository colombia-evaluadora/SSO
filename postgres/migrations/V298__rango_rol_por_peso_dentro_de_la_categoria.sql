-- ===========================================================================
-- V298 - fn_assert_rango_rol: dentro de la MISMA categoria decide
--        PESO_CATEGORIA, igual que ya hace fn_assert_rango_rol_otorgable.
--        Se extrae el calculo del peso a un helper para que las dos no
--        puedan divergir.
--
-- POR QUE ESTA MIGRACION EXISTE
--   V295 hizo que OTORGAR un rol de la misma categoria dependa del peso: un
--   Rector (peso 1) puede otorgar Jefe De Sistema (2) y Auxiliar
--   administrativo (3), y no otro Rector. Pero fn_assert_rango_rol -- el que
--   decide si puedo AFECTAR a un funcionario -- seguia comparando solo la
--   CATEGORIA, asi que un Rector es "igual" a su propio auxiliar y no puede
--   tocarlo.
--
--   La combinacion es absurda, y esta medida en el servidor de test. El
--   rector del EE 887 sobre un funcionario suyo:
--
--     1) le otorga Auxiliar administrativo (nivel 2)   -> OK (V295)
--     2) editar su ficha                               -> 42501
--     2) darle otro permiso                            -> 42501
--     2) darle de baja                                 -> 42501
--
--   Puede crearlo y en el instante siguiente ya no puede volver a tocarlo,
--   porque el rol que acaba de otorgarle lo convierte en su "igual". Eso no
--   es una regla de negocio: es el efecto de tener dos criterios distintos
--   para la misma jerarquia.
--
--   El alcance real: fn_assert_rango_rol gatea NUEVE funciones, asi que no
--   se trata solo del editar. Medido con el rector del EE 745 sobre su Jefe
--   De Sistema:
--
--     VER su ficha (fn_usu_empleado_buscar_por_pk)   OK  -- no pasa por aqui
--     EDITAR su ficha (fn_fun_actualizar)            42501
--     ASIGNAR/QUITAR sus permisos                    42501
--     DARLE DE BAJA del establecimiento              42501
--
--   mas fn_sede_usuario_actualizar, fn_fun_cancelar_pendiente,
--   fn_fun_enlazar_establecimiento y los fn_fun_filtros_permiso_*. Son 67
--   funcionarios de nivel 2 hoy a los que su propio rector no puede
--   gestionar.
--
-- QUE CAMBIA
--   1) Se crea fn_usuario_peso_categoria(p_pk_tusuario): el MIN(
--      PESO_CATEGORIA) entre los roles que el usuario tiene HOY y que caen
--      en su categoria mas alta. Los roles se toman igual que en
--      fn_cat_roles_listar (V121): TSEDE_USUARIO activas mas los punteros de
--      rector (rol 7) y secretaria (rol 9) del EE.
--
--      Existe para que el criterio viva en UN solo sitio. V295 lo llevaba
--      inline; aqui se saca y las dos assertions lo llaman.
--
--   2) fn_assert_rango_rol pasa a decidir en tres tramos, como el otorgable:
--        * objetivo de categoria INFERIOR  -> pasa
--        * objetivo de categoria SUPERIOR  -> 42501
--        * MISMA categoria                 -> pasa solo si el peso del
--          objetivo es estrictamente MAYOR (menor autoridad) que el propio
--
--   3) fn_assert_rango_rol_otorgable se reescribe identica en
--      comportamiento, pero delegando el peso al helper en vez de repetir la
--      consulta.
--
--   Lo que NO cambia: el bypass de nivel 0; la excepcion de si-mismo (V294);
--   "objetivo sin ningun rol activo pasa" (304 funcionarios hoy);
--   "solicitante sin rol activo no pasa"; y el mensaje y el 42501.
--
--   Sigue prohibido tocar a un par del mismo peso: un Rector no puede
--   afectar a otro Rector, y un Auxiliar no puede afectar a otro Auxiliar.
--
-- LO QUE DELIBERADAMENTE NO SE TOCA
--   La nocion de "mi categoria" sigue siendo fn_usuario_categoria_rol_nivel,
--   que se calcula SOLO sobre TSEDE_USUARIO y no mira los punteros de
--   rector/secretaria. Por eso hay 7 rectores y 4 secretarias que lo son
--   solo por puntero y a los que el rango no protege: su nivel sale NULL.
--   Cerrar eso cambiaria el nivel en todo el modelo de permisos, no solo
--   aqui, asi que se deja como decision aparte -- meter los punteros solo en
--   esta funcion crearia otra divergencia como la que esta migracion viene a
--   cerrar. El peso si los mira, porque solo se consulta cuando el nivel ya
--   quedo resuelto por un TSEDE_USUARIO.
--
-- Idempotente: CREATE OR REPLACE, mismas firmas (no crea sobrecargas).
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1) fn_usuario_peso_categoria — el peso del usuario en su categoria alta.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_usuario_peso_categoria(
    p_pk_tusuario  BIGINT
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_nivel  INT;
    v_peso   NUMERIC;
BEGIN
    v_nivel := academico_test.fn_usuario_categoria_rol_nivel(p_pk_tusuario);

    IF v_nivel IS NULL THEN
        RETURN NULL;
    END IF;

    WITH roles_del_usuario AS (
        SELECT su.FK_TROL AS pk_trol
          FROM academico_test.TSEDE_USUARIO su
         WHERE su.FK_TUSUARIO = p_pk_tusuario
           AND su.ACTIVE = TRUE
        UNION
        SELECT 7
          FROM academico_test.TESTABLECIMIENTO e
          JOIN academico_test.TFUNCIONARIO f
            ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
         WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE
           AND f.FK_TUSUARIO = p_pk_tusuario
        UNION
        SELECT 9
          FROM academico_test.TESTABLECIMIENTO e
          JOIN academico_test.TFUNCIONARIO f
            ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
         WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE
           AND f.FK_TUSUARIO = p_pk_tusuario
    )
    SELECT MIN(r.PESO_CATEGORIA)
      INTO v_peso
      FROM roles_del_usuario ru
      JOIN academico_test.TROL r
        ON r.PK_TROL = ru.pk_trol AND r.ACTIVE = TRUE
     WHERE academico_test.fn_rol_categoria_nivel(r.PK_TROL) = v_nivel;

    RETURN v_peso;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_usuario_peso_categoria(BIGINT)
    IS 'Peso de autoridad de un usuario DENTRO de su categoria de rol mas alta: MIN(TROL.PESO_CATEGORIA) entre los roles que tiene hoy y que caen en esa categoria (menor peso = mas autoridad). Los roles se toman igual que en fn_cat_roles_listar (V121): TSEDE_USUARIO activas mas los punteros FK_TFUNCIONARIO_RECTOR (rol 7) y FK_TFUNCIONARIO_SECRETARIA (rol 9) de los EE activos, porque hay establecimientos donde la vinculacion vive solo en el puntero. NULL si el usuario no tiene ningun rol activo (nivel NULL) o si los roles de su categoria no tienen peso sembrado -- en ambos casos quien consulta debe tratarlo como "no autorizado", igual que hace el select de roles. La categoria se resuelve con fn_usuario_categoria_rol_nivel, que solo mira TSEDE_USUARIO: el peso solo se consulta cuando el nivel ya quedo resuelto por ahi. V298: extraido de fn_assert_rango_rol_otorgable (V295) para que el rango de AFECTAR y el rango de OTORGAR usen el mismo criterio y no puedan divergir.';


-- ---------------------------------------------------------------------------
-- 2) fn_assert_rango_rol — afectar: peso dentro de la misma categoria.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_assert_rango_rol(
    p_pk_solicitante           BIGINT,
    p_pk_funcionario_objetivo  BIGINT
)
RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_nivel_solicitante  INT;
    v_nivel_objetivo     INT;
    v_peso_solicitante   NUMERIC;
    v_peso_objetivo      NUMERIC;
    v_fk_tusuario_obj    BIGINT;
    v_nombre_objetivo    TEXT;
BEGIN
    v_nivel_solicitante := academico_test.fn_usuario_categoria_rol_nivel(p_pk_solicitante);

    -- SUPER_ADMIN: sin rango que lo limite.
    IF v_nivel_solicitante = 0 THEN
        RETURN;
    END IF;

    SELECT f.FK_TUSUARIO
      INTO v_fk_tusuario_obj
      FROM academico_test.TFUNCIONARIO f
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario_objetivo;

    -- V294: uno siempre se alcanza a si mismo.
    IF v_fk_tusuario_obj IS NOT NULL AND v_fk_tusuario_obj = p_pk_solicitante THEN
        RETURN;
    END IF;

    v_nivel_objetivo := academico_test.fn_usuario_categoria_rol_nivel(v_fk_tusuario_obj);

    -- El objetivo no tiene roles activos: no hay rango que proteger.
    IF v_nivel_objetivo IS NULL THEN
        RETURN;
    END IF;

    IF v_nivel_solicitante IS NOT NULL THEN

        -- Objetivo de categoria estrictamente INFERIOR: se alcanza.
        IF v_nivel_solicitante < v_nivel_objetivo THEN
            RETURN;
        END IF;

        -- V298 -- MISMA categoria: decide el peso, solo hacia abajo. Sin
        -- esto, un Rector no podia gestionar a su propio Jefe De Sistema ni
        -- a su Auxiliar administrativo, aunque V295 si le deja otorgarles
        -- esos roles.
        IF v_nivel_solicitante = v_nivel_objetivo THEN
            v_peso_solicitante := academico_test.fn_usuario_peso_categoria(p_pk_solicitante);
            v_peso_objetivo    := academico_test.fn_usuario_peso_categoria(v_fk_tusuario_obj);

            IF v_peso_solicitante IS NOT NULL
               AND v_peso_objetivo IS NOT NULL
               AND v_peso_objetivo > v_peso_solicitante THEN
                RETURN;
            END IF;
        END IF;
    END IF;

    SELECT TRIM(COALESCE(u.PRIMER_NOMBRE, '') || ' ' || COALESCE(u.PRIMER_APELLIDO, ''))
      INTO v_nombre_objetivo
      FROM academico_test.TFUNCIONARIO f
      JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario_objetivo;

    RAISE EXCEPTION 'El funcionario "%" tiene un rol de categoria igual o superior a la del usuario; no se puede consultar ni afectar',
        COALESCE(NULLIF(v_nombre_objetivo, ''), 'objetivo')
        USING ERRCODE = '42501';
END;
$$;

COMMENT ON FUNCTION academico_test.fn_assert_rango_rol(BIGINT, BIGINT)
    IS 'Assertion de RANGO DE ROL (capa 3): decide si el solicitante puede consultar o afectar a un funcionario. Nivel 0 (SUPER_ADMIN) pasa siempre; un solicitante sin rol activo nunca pasa; un objetivo sin ningun rol activo pasa (no hay rango que proteger, el alcance sobre el lo gobierna el scope de EE). V294: si el TFUNCIONARIO objetivo es del PROPIO solicitante, pasa -- sin eso el ">=" se cumplia siempre contra uno mismo y nadie podia editar su propia ficha ni sus permisos. V298: dentro de la MISMA categoria ya no se rechaza en bloque, decide fn_usuario_peso_categoria -- se alcanza al objetivo solo si su peso es estrictamente MAYOR (menor autoridad) que el propio, el mismo criterio que fn_assert_rango_rol_otorgable y que el select de roles de fn_cat_roles_listar. Hacia falta porque un Rector no podia gestionar a su propio Jefe De Sistema (peso 2) ni a su Auxiliar administrativo (peso 3) -- ni editarles la ficha, ni tocarles los permisos, ni darlos de baja -- aunque V295 si le permite otorgarles esos roles: podia crearlos y no volver a tocarlos. Un par del mismo peso sigue protegido (Rector no afecta a otro Rector). Gatea nueve funciones: fn_fun_actualizar, fn_fun_permisos_actualizar, fn_fun_baja_establecimiento, fn_fun_cancelar_pendiente, fn_fun_crear, fn_fun_enlazar_establecimiento, fn_sede_usuario_actualizar y los dos fn_fun_filtros_permiso_*. NOTA: la categoria sale de fn_usuario_categoria_rol_nivel, que solo mira TSEDE_USUARIO, asi que los rectores/secretarias que lo son unicamente por puntero (7 y 4 respectivamente) tienen nivel NULL y esta funcion no los protege; cerrarlo implica cambiar la nocion de nivel en todo el modelo y se dejo como decision aparte.';


-- ---------------------------------------------------------------------------
-- 3) fn_assert_rango_rol_otorgable — igual que V295, pero via el helper.
-- ---------------------------------------------------------------------------
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

    IF v_nivel_solicitante IS NOT NULL AND v_nivel_rol IS NOT NULL THEN

        -- Categoria estrictamente INFERIOR: se ofrece completa.
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

            -- V298 -- el peso del solicitante sale del helper compartido, en
            -- vez de repetir aqui la consulta que traia V295.
            v_peso_solicitante := academico_test.fn_usuario_peso_categoria(p_pk_solicitante);

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
    IS 'Assertion de RANGO al OTORGAR un rol. Nivel 0 (SUPER_ADMIN) otorga cualquiera; un solicitante sin rol activo no otorga ninguno. V295: tres tramos en vez de "categoria igual o superior -> 42501" a secas -- categoria SUPERIOR se rechaza, INFERIOR se permite, y en la MISMA categoria decide TROL.PESO_CATEGORIA: solo se otorga un rol de peso estrictamente MAYOR (menor autoridad) que el propio. Es el mismo criterio que el select de roles de fn_cat_roles_listar (V121), asi que el backend autoriza exactamente lo que el front ofrece; sigue impidiendo que un rector nombre a otro rector. V298: el peso del solicitante se pide a fn_usuario_peso_categoria en vez de repetir la consulta aqui, para que este rango y el de fn_assert_rango_rol no puedan divergir. Relajarlo es seguro porque la autoridad sobre la SEDE la validan los llamadores: fn_fun_permisos_actualizar por operacion contra v_sedes_plenas / v_sedes_coord, y fn_sede_usuario_crear via fn_assert_permiso_seccion con sede y jornada.';
