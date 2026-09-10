-- ===========================================================================
-- V294 - fn_assert_rango_rol: uno siempre se alcanza a si mismo.
--
-- POR QUE ESTA MIGRACION EXISTE
--   fn_assert_rango_rol (V29) protege el rango de rol: nadie puede consultar
--   ni afectar a un funcionario cuya categoria de rol sea la MISMA o
--   SUPERIOR a la suya. La comparacion es
--
--       IF v_nivel_solicitante >= v_nivel_objetivo THEN  -> 42501
--
--   y no exceptua el caso en que el objetivo ES el propio solicitante.
--   Comparado consigo mismo el nivel es, por definicion, igual, asi que el
--   ">=" se cumple SIEMPRE y nadie puede tocar su propia ficha.
--
--   Medido en el servidor de test antes del cambio, con el rector del EE 887
--   (usuario 197798, categoria nivel 2) sobre su propio TFUNCIONARIO
--   3587713:
--
--       fn_assert_permiso_funcionario(197798,'VER',   3587713) -> 42501
--       fn_assert_permiso_funcionario(197798,'EDITAR',3587713) -> 42501
--       fn_fun_permisos_actualizar   (197798, 3587713, '[]')   -> 42501
--
--   con el mensaje "El funcionario "YOVANY ZHU" tiene un rol de categoria
--   igual o superior a la del usuario", donde YOVANY ZHU es el propio
--   solicitante. El GET (fn_usu_empleado_buscar_por_pk) si pasaba, asi que
--   el sintoma era ver la ficha propia y no poder guardarla.
--
--   Se nota sobre todo en un establecimiento recien creado: alli el rector
--   suele ser el UNICO funcionario, asi que el unico objetivo disponible es
--   el mismo y el modulo entero parece sin permisos. No es que el EE sea
--   nuevo: es que no hay nadie mas a quien apuntar.
--
-- QUE CAMBIA
--   Una salida temprana: si el TFUNCIONARIO objetivo pertenece al usuario
--   solicitante (f.FK_TUSUARIO = p_pk_solicitante), la funcion retorna. El
--   rango existe para proteger a TERCEROS de igual o mayor categoria; frente
--   a uno mismo no hay rango que proteger, y el resto de capas sigue
--   aplicando -- la capability por menu (fn_assert_permiso_seccion) y el
--   scope de EE los evalua fn_assert_permiso_funcionario antes de llegar
--   aqui, y lo que se pueda otorgar lo sigue decidiendo
--   fn_assert_rango_rol_otorgable.
--
--   Nada mas cambia: mismos parametros, mismo mensaje, mismo 42501, mismo
--   bypass de nivel 0, misma decision de "objetivo sin roles activos pasa".
--
-- QUE NO ARREGLA (a proposito)
--   * El crear de sedes. fn_sed_crear propaga el permiso del rector a la
--     sede nueva llamando a fn_fun_permisos_actualizar, la funcion de cara
--     al usuario, asi que cuando el que crea la sede ES ese rector choca
--     con DOS guardas: esta y, despues, fn_assert_rango_rol_otorgable sobre
--     el rol Rector ("es de categoria igual o superior; no se puede
--     otorgar"). Se verifico que con esta migracion aplicada el crear de
--     sedes sigue fallando en la segunda. Mantener un invariante del sistema
--     no es un acto discrecional del usuario y no deberia pasar por la
--     puerta de autorizacion humana; eso se corrige aparte.
--   * Asignar permisos a un funcionario que YA existe en OTRO
--     establecimiento. Ahi falla el SCOPE, no el rango: 42501 "El usuario no
--     tiene alcance sobre el funcionario X". La excepcion chicken-and-egg de
--     fn_fun_permisos_actualizar solo cubre a quien no tiene NINGUN
--     TSEDE_USUARIO activo. Se comprobo que el gate anterior al modelo
--     dinamico exigia lo mismo (v_visible), asi que no es un retroceso sino
--     un flujo que nunca existio.
--
-- Idempotente: CREATE OR REPLACE, misma firma que V29 (no crea sobrecarga).
-- ===========================================================================


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
    v_nombre_objetivo    TEXT;
    v_es_el_mismo        BOOLEAN;
BEGIN
    v_nivel_solicitante := academico_test.fn_usuario_categoria_rol_nivel(p_pk_solicitante);

    -- SUPER_ADMIN: sin rango que lo limite.
    IF v_nivel_solicitante = 0 THEN
        RETURN;
    END IF;

    -- V294: uno siempre se alcanza a si mismo. Sin esto, la comparacion de
    -- niveles de abajo es un ">=" contra su propio nivel y se cumple
    -- siempre, de modo que nadie puede editar su propia ficha ni sus
    -- permisos. El rango protege a terceros, no a uno de si mismo.
    SELECT (f.FK_TUSUARIO = p_pk_solicitante)
      INTO v_es_el_mismo
      FROM academico_test.TFUNCIONARIO f
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario_objetivo;

    IF COALESCE(v_es_el_mismo, FALSE) THEN
        RETURN;
    END IF;

    SELECT MIN(academico_test.fn_rol_categoria_nivel(su.FK_TROL))
      INTO v_nivel_objetivo
      FROM academico_test.TFUNCIONARIO f
      JOIN academico_test.TSEDE_USUARIO su
        ON su.FK_TUSUARIO = f.FK_TUSUARIO
       AND su.ACTIVE = TRUE
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario_objetivo;

    -- El objetivo no tiene roles activos: no hay rango que proteger.
    IF v_nivel_objetivo IS NULL THEN
        RETURN;
    END IF;

    -- Solicitante sin rol activo (NULL): la comparacion nunca autoriza.
    IF v_nivel_solicitante IS NULL OR v_nivel_solicitante >= v_nivel_objetivo THEN
        SELECT TRIM(COALESCE(u.PRIMER_NOMBRE, '') || ' ' || COALESCE(u.PRIMER_APELLIDO, ''))
          INTO v_nombre_objetivo
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
         WHERE f.PK_TFUNCIONARIO = p_pk_funcionario_objetivo;

        RAISE EXCEPTION 'El funcionario "%" tiene un rol de categoria igual o superior a la del usuario; no se puede consultar ni afectar',
            COALESCE(NULLIF(v_nombre_objetivo, ''), 'objetivo')
            USING ERRCODE = '42501';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_assert_rango_rol(BIGINT, BIGINT)
    IS 'Assertion de RANGO DE ROL (capa 3): un usuario no puede ver ni afectar a funcionarios cuya categoria de rol sea la MISMA o SUPERIOR a la suya. nivel_objetivo = MIN(fn_rol_categoria_nivel) de los TSEDE_USUARIO ACTIVE del funcionario objetivo (via su FK_TUSUARIO); si fn_usuario_categoria_rol_nivel(solicitante) >= nivel_objetivo -> 42501 nombrando al funcionario. Un solicitante de nivel 0 (SUPER_ADMIN) pasa siempre. DECISION: si el objetivo no tiene ningun rol activo, nivel_objetivo es NULL y la funcion PASA -- no hay rango que proteger (un funcionario sin rol no es "superior" a nadie); el alcance sobre el sigue gobernado por el scope de EE. Un solicitante sin rol activo (nivel NULL) nunca pasa. V294: si el TFUNCIONARIO objetivo es del PROPIO solicitante (f.FK_TUSUARIO = p_pk_solicitante) la funcion retorna antes de comparar. Sin esa excepcion el ">=" se cumplia siempre contra uno mismo y nadie podia editar su propia ficha ni sus permisos -- medido con el rector del EE 887 sobre su propio funcionario, que recibia 42501 con su propio nombre en el mensaje; se notaba sobre todo en un EE recien creado, donde el rector es el unico funcionario y por tanto el unico objetivo posible. El rango protege a TERCEROS de igual o mayor categoria; frente a uno mismo no hay rango que proteger, y la capability, el scope de EE y fn_assert_rango_rol_otorgable siguen aplicando igual.';
