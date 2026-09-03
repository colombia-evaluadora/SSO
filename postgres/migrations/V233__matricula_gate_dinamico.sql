-- =============================================================================
-- V233 -- El gate del modulo de matricula pasa de una allowlist fija de roles
-- al modelo de permisos dinamicos (capability + scope, V29/V185).
--
-- Punto unico de cambio: fn_matricula_puede_cambiar_estado. Las once funciones
-- del modulo que la usan quedan migradas de una vez:
--
--   V166  fn_matricula_retirar / _reingresar / _reactivar
--         fn_matricula_directa_eliminar        (y _bulk, que delega)
--   V175  fn_matricula_puede_cambiar_estado    (esta)
--   V177  fn_estudiante_actualizar, fn_padre_actualizar,
--         fn_matricula_socioeconomico_actualizar, fn_matricula_archivo_actualizar,
--         fn_matricula_actualizar, fn_matricula_directa_actualizar
--   V178  fn_matricula_mover_lote              (promover/reubicar/corregir)
--   V179  fn_usu_actualizar
--
-- -----------------------------------------------------------------------------
-- Que decide ahora y quien lo configura
-- -----------------------------------------------------------------------------
--   1. CAPABILITY -- fn_usuario_puede_en_menu(usuario, 'MATRICULA', accion),
--      que envuelve fn_usuario_permisos_menu (V185): TROL_MENU concede por rol
--      y TUSUARIO_ROL_PERMISO recorta por usuario. Es la parte CONFIGURABLE: el
--      super-admin cambia quien entra desde la pantalla de roles
--      (PUT /roles/:ROLEID/menus, 132) sin que nadie toque codigo. V231 dejo el
--      menu MATRICULA concedido a los roles 7, 8 y 9.
--
--   2. SCOPE -- sobre que establecimiento. Es ESTRUCTURAL, no configurable:
--      sale de la categoria del rol (fn_usuario_categoria_rol_nivel) y de
--      fn_usuario_ee_accesibles, que une TSEDE_USUARIO con los punteros
--      rector/secretaria de TESTABLECIMIENTO.
--
-- -----------------------------------------------------------------------------
-- El super-admin queda FUERA, a proposito
-- -----------------------------------------------------------------------------
-- fn_assert_permiso_seccion (V29) hace bypass total en nivel 0: el super-admin
-- no pasa por capability ni por scope. Aca NO se usa ese atajo -- se rechaza el
-- nivel 0 explicitamente -- para conservar la decision del modulo: las acciones
-- sobre datos academicos de una institucion las hace quien la administra
-- (rector, secretaria, jefe de sistema), no un administrador global.
--
-- Consecuencia a tener presente: cuando la rama de permisos entre a dev,
-- fn_matricula_directa_crear y los GET pasaran a usar fn_assert_permiso_seccion
-- y SI admitiran al super-admin. El modulo quedara con dos criterios hasta que
-- se unifique -- o pidiendo un parametro para desactivar el bypass, o aceptando
-- que el super-admin entra. Es una decision de negocio pendiente, no un bug.
--
-- -----------------------------------------------------------------------------
-- Por que aca no se llama a fn_matricula_gate_escritura
-- -----------------------------------------------------------------------------
-- Esa funcion es el wrapper equivalente de la rama de permisos, pero vive en su
-- V40 y NO esta en el servidor. Llamarla dejaria el modulo roto hasta que esa
-- rama se aplique. Reimplementar la decision aca, con los helpers de V29 que si
-- estan vivos, evita eso y ademas no duplica ningun nombre suyo: al mergear no
-- hay colision, y si despues conviene se cambia por su wrapper.
--
-- Otra diferencia deliberada: su wrapper resuelve el scope desde el GRUPO
-- (grupo -> grado -> periodo -> sede + jornada), lo que permite acotar a los
-- roles de nivel 3 (coordinador, docente...) a su par (sede, jornada). Aca el
-- scope es por ESTABLECIMIENTO porque es lo que reciben las once funciones de
-- arriba, y porque hoy ningun rol de nivel 3 tiene el menu MATRICULA. Si
-- manana se le concede a un coordinador, esta funcion lo rechazara -- ver el
-- comentario del nivel 3 mas abajo.
--
-- -----------------------------------------------------------------------------
-- Firma
-- -----------------------------------------------------------------------------
-- Entra un tercer parametro, p_accion, con DEFAULT 'EDITAR', de modo que las
-- once llamadas existentes de dos argumentos siguen compilando sin tocarlas.
-- CREATE OR REPLACE no puede agregar un parametro, asi que se elimina primero
-- la firma de dos: dejarla viva haria ambigua toda llamada con dos argumentos.
--
-- Hoy distinguir la accion no cambia el resultado -- fn_usuario_permisos_menu
-- calcula puede_crear = puede_editar = puede_eliminar del mismo bool_or, y solo
-- puede_ver aparte -- pero se pasa igual para que el dia que separen esos flags
-- las funciones ya esten correctas.
-- =============================================================================

DROP FUNCTION IF EXISTS academico_test.fn_matricula_puede_cambiar_estado(BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_puede_cambiar_estado(
    p_pk_usuario          BIGINT,
    p_fk_establecimiento  BIGINT,
    p_accion              VARCHAR DEFAULT 'EDITAR'
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_nivel INTEGER;
BEGIN
    IF p_pk_usuario IS NULL OR p_fk_establecimiento IS NULL THEN
        RETURN FALSE;
    END IF;

    -- -----------------------------------------------------------------
    -- 0. Categoria del rol. NULL = el usuario no tiene ningun rol activo
    --    en TSEDE_USUARIO; sin rol no hay de donde colgar la capability,
    --    asi que se rechaza (fail-closed). Es el caso de los rectores y
    --    secretarias asignados SOLO por los punteros de
    --    TESTABLECIMIENTO: el alta de sede les crea el permiso desde
    --    V52 REV4, pero los anteriores a ese cambio quedaron sin el.
    -- -----------------------------------------------------------------
    v_nivel := academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario);

    IF v_nivel IS NULL THEN
        RETURN FALSE;
    END IF;

    -- -----------------------------------------------------------------
    -- 1. Nivel 0 = SUPER_ADMIN: excluido (ver cabecera).
    -- -----------------------------------------------------------------
    IF v_nivel = 0 THEN
        RETURN FALSE;
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Capability: lo que el super-admin configura por rol y por
    --    usuario. Si el menu MATRICULA no esta concedido, no hay nada
    --    mas que evaluar.
    -- -----------------------------------------------------------------
    IF NOT academico_test.fn_usuario_puede_en_menu(p_pk_usuario, 'MATRICULA', p_accion) THEN
        RETURN FALSE;
    END IF;

    -- -----------------------------------------------------------------
    -- 3. Scope.
    -- -----------------------------------------------------------------
    -- Nivel 1 (ADMINISTRATIVOS_TERRITORIALES, roles 2-6): alcanzan todos
    -- los establecimientos. Hoy ninguno tiene el menu MATRICULA, asi que
    -- esta rama es inerte hasta que el super-admin se lo conceda.
    IF v_nivel = 1 THEN
        RETURN TRUE;
    END IF;

    -- Nivel 2 (ADMINISTRATIVOS_ESTABLECIMIENTO, roles 7-8-9): solo sus
    -- establecimientos. fn_usuario_ee_accesibles une TSEDE_USUARIO con
    -- los punteros rector/secretaria, asi que cubre las dos formas de
    -- asignacion.
    IF v_nivel = 2 THEN
        RETURN EXISTS (
            SELECT 1
              FROM academico_test.fn_usuario_ee_accesibles(p_pk_usuario) ee
             WHERE ee.establecimiento_id = p_fk_establecimiento
        );
    END IF;

    -- Nivel 3 (ADMINISTRATIVOS_SEDES) y 4 (ESTUDIANTES_FAMILIA): fuera.
    --
    -- El nivel 3 alcanza un par (sede, jornada), no un establecimiento
    -- entero, y esta funcion solo recibe el establecimiento: autorizarlo
    -- aca seria darle todo el EE, mas de lo que le corresponde. Si el
    -- negocio quiere que un coordinador opere matricula, el gate tiene
    -- que recibir sede y jornada -- que es justamente lo que hace
    -- fn_matricula_gate_escritura resolviendolas desde el grupo. Mientras
    -- eso no pase, fail-closed.
    RETURN FALSE;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_matricula_puede_cambiar_estado(BIGINT, BIGINT, VARCHAR)
    IS 'Gate del modulo de matricula. Decide por CAPABILITY (fn_usuario_puede_en_menu sobre el menu MATRICULA: TROL_MENU concede por rol, TUSUARIO_ROL_PERMISO recorta por usuario -- configurable por el super-admin desde PUT /roles/:ROLEID/menus) + SCOPE por establecimiento (fn_usuario_ee_accesibles, que une TSEDE_USUARIO con los punteros rector/secretaria). Nivel 1 territorial alcanza todos los EE; nivel 2 solo los suyos; niveles 3 y 4 quedan fuera porque el scope de nivel 3 es (sede, jornada) y esta funcion solo recibe el EE. El SUPER_ADMIN (nivel 0) se RECHAZA a proposito, a diferencia de fn_assert_permiso_seccion que le hace bypass: las acciones sobre datos academicos de una institucion las hace quien la administra. Sin rol activo en TSEDE_USUARIO tambien se rechaza (fail-closed). p_accion es CREAR|EDITAR|ELIMINAR|VER; hoy los tres de escritura dan el mismo resultado porque fn_usuario_permisos_menu los calcula del mismo bool_or.';
