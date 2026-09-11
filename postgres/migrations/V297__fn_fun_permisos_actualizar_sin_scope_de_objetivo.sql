-- ===========================================================================
-- V297 - fn_fun_permisos_actualizar: asignar permisos deja de exigir que el
--        funcionario YA sea de un establecimiento del solicitante.
--
-- POR QUE ESTA MIGRACION EXISTE
--   El gate de esta funcion se bifurcaba asi:
--
--     * el funcionario objetivo tiene algun TSEDE_USUARIO activo, o es
--       rector/secretaria por puntero -> fn_assert_permiso_funcionario
--       ('EDITAR'), que es capability + SCOPE SOBRE EL OBJETIVO + rango;
--     * el funcionario no tiene nada -> solo capability (la excepcion
--       "chicken-and-egg" de la primera asignacion de rol).
--
--   El scope sobre el objetivo exige que el funcionario ya sea alcanzable en
--   un EE del solicitante. Consecuencia: a alguien que YA trabaja en OTRO
--   establecimiento no se le puede dar un permiso en el mio, ni siquiera de
--   Docente. Medido en el servidor de test: el rector del EE 887 asignando
--   Docente en su sede 1664 a JOSE ALVAREZ (funcionario del EE 745, nivel 3)
--   -> 42501 "El usuario no tiene alcance sobre el funcionario JOSE ALVAREZ".
--
--   No es un retroceso -- se comprobo que el gate anterior al modelo
--   dinamico exigia lo mismo (su variable v_visible) -- es un flujo que
--   nunca existio y que el negocio si necesita: un funcionario puede
--   trabajar en varios establecimientos a la vez segun las jornadas, y el
--   front ya lo insinua al autocompletar por documento y habilitar el boton
--   de permisos.
--
-- QUE CAMBIA
--   La bifurcacion desaparece. El gate queda, para todos los casos:
--
--       fn_assert_permiso_seccion(solicitante, 'FUNCIONARIOS', 'EDITAR')
--       fn_assert_rango_rol(solicitante, p_pk_funcionario)
--
--   Es decir: se conserva la capability por menu y se conserva el RANGO --
--   nadie toca los permisos de un par de su misma categoria -- y se retira
--   unicamente el "el objetivo ya tiene que ser mio".
--
-- POR QUE ES SEGURO
--   Porque la autoridad sobre la SEDE se valida operacion por operacion, y
--   eso no cambia. Tanto al crear como al eliminar, la funcion comprueba que
--   la sede implicada este en v_sedes_plenas (fn_usuario_ee_accesibles) o en
--   v_sedes_coord (fn_usuario_sedes_jornadas_accesibles) y, si no, devuelve
--   'error:sin_permiso_en_sede' sin escribir:
--
--       crear:    v_perm.fk_sede    contra v_sedes_plenas / v_sedes_coord
--       eliminar: v_fk_sede_op      (la sede de la fila que se borra)
--
--   Asi que un rector puede dar a un docente ajeno un permiso EN SUS SEDES,
--   y sigue sin poder tocar los permisos que ese docente tiene en el EE de
--   otro: al intentar borrarlos, la sede de esa fila no esta en su scope.
--   El objeto que de verdad importa aqui es la SEDE, no el historial del
--   funcionario -- el mismo razonamiento con el que
--   fn_fun_enlazar_establecimiento ya se saltaba este scope (ver su DECISION
--   documentada en V51).
--
--   Y el EDITAR de la ficha del funcionario NO se toca: eso vive en
--   fn_fun_actualizar (PATCH /establecimientos/funcionarios/:ID), que
--   conserva fn_assert_permiso_funcionario con su scope. Cambiarle datos
--   basicos a alguien que no es tuyo sigue prohibido, que era la razon
--   original del gate. Son dos endpoints distintos: el front llama a
--   PUT /funcionario/:ID/permisos por separado al cerrar el dialogo de
--   permisos, sin encadenarlo con el PATCH, asi que no hay que desarmar
--   nada del editar.
--
-- QUE NO ARREGLA
--   Los objetivos de NIVEL 2 (Jefe De Sistema (Establecimiento), Auxiliar
--   administrativo). Ahi el que bloquea es el rango, no el scope:
--   fn_assert_rango_rol compara solo la CATEGORIA, asi que un Rector es
--   "igual" a su propio auxiliar y no puede gestionarlo -- medido: 67
--   funcionarios de nivel 2, y el rector del EE 745 recibe 42501 sobre su
--   Jefe De Sistema y sobre su Auxiliar administrativo. Lo coherente seria
--   que el rango use PESO_CATEGORIA dentro de la misma categoria, como ya
--   hace fn_assert_rango_rol_otorgable desde V295 (Rector peso 1 manda sobre
--   Jefe De Sistema 2 y Auxiliar 3, y no sobre otro Rector). Queda pendiente
--   de decision, no se toca aqui.
--
-- Idempotente: CREATE OR REPLACE, misma firma (no crea sobrecarga).
-- ===========================================================================


CREATE OR REPLACE FUNCTION academico_test.fn_fun_permisos_actualizar(p_pk_usuario_solicitante bigint, p_pk_funcionario bigint, p_permisos jsonb)
 RETURNS TABLE(accion character varying, id bigint, status character varying)
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_pk_usuario     BIGINT;
    v_active_fun     BOOLEAN;
    v_nombre_actual  VARCHAR;
    v_es_super       BOOLEAN;
    -- REV3 -- sedes donde el actor tiene autoridad PLENA (cualquier rol:
    -- rector/secretaria/jefe de sistema de ese EE), y sedes donde el actor
    -- es coordinador (autoridad LIMITADA: solo roles 9-14, nunca rector/
    -- jefe de sistema). Se materializan una vez antes del loop para poder
    -- validar cada operacion individual contra la sede que afecta.
    v_sedes_plenas   BIGINT[];
    v_sedes_coord    BIGINT[];
    v_perm           RECORD;
    v_fk_sede_op     BIGINT;
    v_fk_rol_op      BIGINT;
BEGIN
    -- =====================================================================
    -- 1. Validar existencia y estado del TFUNCIONARIO. Resolver PK_TUSUARIO
    --    y un nombre legible para mensajes.
    -- =====================================================================
    SELECT f.ACTIVE, f.FK_TUSUARIO,
           TRIM(COALESCE(u.PRIMER_NOMBRE,'') || ' ' || COALESCE(u.PRIMER_APELLIDO,''))
      INTO v_active_fun, v_pk_usuario, v_nombre_actual
      FROM academico_test.TFUNCIONARIO f
      JOIN academico_test.TUSUARIO      u ON u.PK_TUSUARIO = f.FK_TUSUARIO
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el funcionario solicitado'
            USING ERRCODE = 'P0002';
    END IF;
    IF v_active_fun = FALSE THEN
        RAISE EXCEPTION 'El funcionario "%" esta inactivo; no se puede actualizar', v_nombre_actual
            USING ERRCODE = '22023';
    END IF;

    -- =====================================================================
    -- 0. Gate de autorizacion.
    --
    --    V297 -- capability por menu + RANGO, igual para todos los casos.
    --
    --    Antes esto se bifurcaba: si el funcionario YA tenia algun
    --    TSEDE_USUARIO activo, o era rector/secretaria por puntero, se
    --    exigia fn_assert_permiso_funcionario('EDITAR') -- capability +
    --    SCOPE SOBRE EL OBJETIVO + rango --; y si no tenia nada, solo la
    --    capability, para no bloquear la primera asignacion de rol de un
    --    funcionario recien creado (chicken-and-egg: el scope pedia que el
    --    objetivo fuera alcanzable, y solo lo es cuando ya tiene un rol).
    --
    --    Esa excepcion cubria al recien creado pero no a quien YA trabaja en
    --    OTRO establecimiento: a ese no se le podia dar un permiso aqui ni
    --    de Docente, aunque el negocio lo necesita (un funcionario puede
    --    estar en varios EE segun las jornadas). Asi que el scope sobre el
    --    objetivo se retira del todo y la excepcion sobra.
    --
    --    Lo que NO se retira: el rango (nadie toca los permisos de un par de
    --    su misma categoria) ni la autoridad sobre la SEDE, que el bucle de
    --    abajo valida operacion por operacion contra v_sedes_plenas /
    --    v_sedes_coord -- al crear con v_perm.fk_sede y al eliminar con la
    --    sede de la fila que se borra. La sede es el objeto que importa
    --    aqui, no el historial del funcionario; es el mismo razonamiento por
    --    el que fn_fun_enlazar_establecimiento ya se saltaba este scope.
    --
    --    El EDITAR de la ficha vive en fn_fun_actualizar y conserva su scope
    --    intacto: cambiarle los datos a alguien que no es tuyo sigue
    --    prohibido.
    -- =====================================================================
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'FUNCIONARIOS', 'EDITAR');
    PERFORM academico_test.fn_assert_rango_rol(
        p_pk_usuario_solicitante, p_pk_funcionario);

    -- v_es_super sigue siendo necesario mas abajo: distingue "sin
    -- restriccion de sede" del resto para la validacion POR OPERACION del
    -- array (v_sedes_plenas / v_sedes_coord), que NO es parte del gate.
    -- CU-86e2w4xdt: se resuelve por CATEGORIA_ROL (nivel 0 SUPER_ADMIN o
    -- nivel 1 ADMINISTRATIVOS_TERRITORIALES) en vez de la lista fija
    -- fn_puede_afectar_establecimiento (FK_TROL IN (1,2,3)).
    v_es_super := (academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante) <= 1);

    IF p_permisos IS NULL OR jsonb_typeof(p_permisos) <> 'array' THEN
        RAISE EXCEPTION 'p_permisos debe ser un JSON array'
            USING ERRCODE = '22023';
    END IF;

    -- REV3 -- materializa las sedes donde el actor tiene autoridad, para
    -- validar cada operacion del array contra la sede que afecta (crear
    -- en una sede que no administra, o eliminar un permiso de una sede
    -- ajena, quedan bloqueados aunque haya pasado el gate general de
    -- arriba -- ese gate solo confirma que puede VER/gestionar a este
    -- funcionario en general, no que pueda tocar CUALQUIER sede suya).
    -- CU-86e2w4xdt: ambos conjuntos se derivan de los helpers de categoria
    -- (V29), no de listas fijas de FK_TROL.
    --   * v_sedes_plenas  = sedes activas de los EE que el actor administra
    --     (fn_usuario_ee_accesibles: rector/secretaria por puntero + roles
    --     de categoria ADMINISTRATIVOS_ESTABLECIMIENTO por TSEDE_USUARIO).
    --   * v_sedes_coord    = sedes del scope de coordinador del actor
    --     (fn_usuario_sedes_jornadas_accesibles: solo devuelve algo si el
    --     actor tiene un rol de categoria ADMINISTRATIVOS_SEDES).
    IF NOT v_es_super THEN
        SELECT ARRAY(
            SELECT s.PK_TSEDE
              FROM academico_test.TSEDE s
             WHERE s.ACTIVE = TRUE
               AND s.FK_TESTABLECIMIENTO IN (
                   SELECT establecimiento_id
                     FROM academico_test.fn_usuario_ee_accesibles(p_pk_usuario_solicitante)
               )
        ) INTO v_sedes_plenas;

        SELECT ARRAY(
            SELECT DISTINCT sede_id
              FROM academico_test.fn_usuario_sedes_jornadas_accesibles(p_pk_usuario_solicitante)
        ) INTO v_sedes_coord;
    END IF;

    FOR v_perm IN
        SELECT
            NULLIF(TRIM(elem->>'accion'), '')                       AS accion,
            (elem->>'id')::BIGINT                                    AS id,
            NULLIF(TRIM(elem->>'orden'), '')::NUMERIC(4)             AS orden,
            NULLIF(TRIM(elem->>'fk_rol'), '')::BIGINT                AS fk_rol,
            NULLIF(TRIM(elem->>'fk_sede'), '')::BIGINT               AS fk_sede,
            NULLIF(TRIM(elem->>'fk_jornada'), '')::BIGINT            AS fk_jornada,
            COALESCE(NULLIF(TRIM(elem->>'fk_estado'), ''), 'ACTIVO') AS fk_estado,
            COALESCE(NULLIF(TRIM(elem->>'predeterminado'), '')::NUMERIC(6), 0) AS predeterminado
        FROM jsonb_array_elements(p_permisos) AS elem
    LOOP
        accion := v_perm.accion;
        id     := v_perm.id;
        status := NULL;

        IF v_perm.accion = 'crear' THEN
            IF v_perm.orden IS NULL OR v_perm.fk_rol IS NULL
               OR v_perm.fk_sede IS NULL OR v_perm.fk_jornada IS NULL THEN
                status := 'error:faltan_campos_obligatorios';
                RETURN NEXT;
                CONTINUE;
            END IF;

            -- Capa 3 (CU-86e2w4xdt): no se puede OTORGAR un rol de
            -- categoria igual o superior a la propia. Lanza 42501 y aborta
            -- la llamada completa -- a diferencia de los 'error:*' de
            -- abajo, esto no es un dato invalido de una fila sino un
            -- intento de escalada de privilegios. El super admin (nivel 0)
            -- pasa siempre.
            PERFORM academico_test.fn_assert_rango_rol_otorgable(
                p_pk_usuario_solicitante, v_perm.fk_rol);

            IF NOT v_es_super
               AND NOT (v_perm.fk_sede = ANY(v_sedes_plenas))
               AND NOT (v_perm.fk_sede = ANY(v_sedes_coord)
                        AND academico_test.fn_rol_categoria_nivel(v_perm.fk_rol) = 3)
            THEN
                status := 'error:sin_permiso_en_sede';
                RETURN NEXT;
                CONTINUE;
            END IF;

            id := academico_test.fn_sede_usuario_crear(
                p_pk_usuario_solicitante,
                v_perm.fk_sede,
                v_perm.fk_rol,
                v_pk_usuario,
                v_perm.orden,
                v_perm.fk_jornada,
                v_perm.fk_estado,
                v_perm.predeterminado
            );
            status := 'creado';
            RETURN NEXT;

        ELSIF v_perm.accion = 'eliminar' THEN
            IF v_perm.id IS NULL THEN
                status := 'error:falta_id';
                RETURN NEXT;
                CONTINUE;
            END IF;

            SELECT FK_TSEDE, FK_TROL INTO v_fk_sede_op, v_fk_rol_op
              FROM academico_test.TSEDE_USUARIO
             WHERE PK_TSEDE_USUARIO = v_perm.id;

            IF FOUND AND NOT v_es_super
               AND NOT (v_fk_sede_op = ANY(v_sedes_plenas))
               AND NOT (v_fk_sede_op = ANY(v_sedes_coord)
                        AND academico_test.fn_rol_categoria_nivel(v_fk_rol_op) = 3)
            THEN
                status := 'error:sin_permiso_en_sede';
                RETURN NEXT;
                CONTINUE;
            END IF;

            PERFORM academico_test.fn_sede_usuario_soft_delete(v_perm.id, p_pk_usuario_solicitante);
            status := 'eliminado';
            RETURN NEXT;

        ELSE
            -- Sin accion (o una no reconocida): ya existia, no se toca.
            status := 'sin_cambios';
            RETURN NEXT;
        END IF;
    END LOOP;
END;
$function$
