-- ===========================================================================
-- V299 - fn_get_academico_usuario_id: al resolver la identidad academica de
--        una cuenta de login, preferir el TUSUARIO ACTIVO.
--
-- POR QUE ESTA MIGRACION EXISTE
--   El puente (V48) traduce public.users.id_user -> academico_test.TUSUARIO
--   buscando por CUENTA = correo de login. Y lo hacia asi:
--
--       SELECT PK_TUSUARIO INTO v_tusuario_pk
--         FROM academico_test.TUSUARIO
--        WHERE CUENTA = v_email
--        ORDER BY PK_TUSUARIO
--        LIMIT 1;
--
--   Sin filtrar por ACTIVE, y desempatando por el PK MAS BAJO -- es decir,
--   por el TUSUARIO mas ANTIGUO. Si una misma CUENTA tiene un TUSUARIO
--   inactivo (viejo) y uno activo (nuevo), el puente devuelve el INACTIVO, y
--   con el se resuelven el p_pk_usuario_solicitante de todo el catalogo de
--   endpoints y la respuesta de /register/funcionario. Identidad equivocada:
--   permisos equivocados.
--
--   Hoy no hay ninguna CUENTA en esa situacion (0 casos medidos), asi que el
--   fallo esta latente. Lo que lo activa es el arreglo del 409
--   DUPLICATE_EMAIL en auth-center (FuncionarioRegistrationService): a partir
--   de ahi, el correo de un usuario dado de baja se puede volver a usar, con
--   lo cual convivir un TUSUARIO inactivo y otro activo con la misma CUENTA
--   pasa a ser el caso NORMAL, no la excepcion. Se verifico creando el
--   escenario a mano: con el inactivo 196969 y un nuevo activo, el puente
--   devolvia 196969.
--
--   Los indices unicos de TUSUARIO ya declaran esa convivencia como legitima
--   -- son parciales: `(cuenta) WHERE active` y
--   `(tipo_doc, identificacion) WHERE active` -- asi que el que estaba mal
--   era el puente, no los datos.
--
-- QUE CAMBIA
--   Solo el desempate del paso 1: se ordena por ACTIVE primero (los activos
--   antes que los inactivos) y luego por PK. Un correo con un solo TUSUARIO
--   -- el 100% de los casos de hoy -- resuelve exactamente igual que antes,
--   este activo o no; solo cambia el resultado cuando hay mas de uno, que es
--   precisamente el escenario que abre el arreglo del 409.
--
--   Deliberadamente NO se filtra `WHERE ACTIVE` a secas: si la unica
--   identidad academica de esa cuenta esta inactiva, devolver su PK sigue
--   siendo mejor que devolver NULL -- NULL hace que el gate compare contra
--   nada y responda 403 sin explicacion, mientras que con el PK el gate
--   dice, correctamente, que ese usuario no tiene roles activos. Se conserva
--   el comportamiento actual para ese caso.
--
--   El paso 2 (estudiantes, que resuelven por CORREO_ELECTRONICO) ya filtraba
--   ACTIVE = TRUE y no se toca.
--
-- Idempotente: CREATE OR REPLACE, misma firma (no crea sobrecarga).
-- ===========================================================================


CREATE OR REPLACE FUNCTION public.fn_get_academico_usuario_id(
    p_user_id  BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_email       VARCHAR(200);
    v_tusuario_pk BIGINT;
BEGIN
    SELECT email INTO v_email FROM public.users WHERE id_user = p_user_id;
    IF v_email IS NULL THEN
        RETURN NULL;
    END IF;

    -- 1. Funcionario / acudiente: CUENTA espeja el correo de login.
    --
    --    V299 -- el ACTIVE manda en el desempate. Antes se ordenaba solo por
    --    PK_TUSUARIO, o sea por el mas antiguo, asi que una cuenta reutilizada
    --    resolvia al TUSUARIO viejo (inactivo) en vez de al nuevo. No se
    --    filtra ACTIVE del todo a proposito: si la unica identidad academica
    --    de la cuenta esta inactiva, se devuelve igual -- es mas util para el
    --    gate que un NULL.
    SELECT PK_TUSUARIO INTO v_tusuario_pk
      FROM academico_test.TUSUARIO
     WHERE CUENTA = v_email
     ORDER BY ACTIVE DESC, PK_TUSUARIO
     LIMIT 1;

    -- 2. Estudiante: CUENTA es el documento; la identidad se resuelve por
    --    el correo de negocio.
    IF v_tusuario_pk IS NULL THEN
        SELECT PK_TUSUARIO INTO v_tusuario_pk
          FROM academico_test.TUSUARIO
         WHERE UPPER(CORREO_ELECTRONICO) = UPPER(v_email)
           AND ACTIVE = TRUE
         ORDER BY PK_TUSUARIO
         LIMIT 1;
    END IF;

    RETURN v_tusuario_pk;
END;
$$;

COMMENT ON FUNCTION public.fn_get_academico_usuario_id(BIGINT)
    IS 'Puente public.users.id_user -> academico_test.TUSUARIO.PK_TUSUARIO (V48). Paso 1: por CUENTA = correo de login (funcionarios y acudientes). Paso 2, si el anterior no resuelve: por CORREO_ELECTRONICO entre los activos (estudiantes, cuya CUENTA es el documento). NULL si la cuenta no existe o no tiene identidad academica. V299: el paso 1 desempata por ACTIVE DESC antes que por PK_TUSUARIO. Antes ordenaba solo por PK, es decir por el TUSUARIO mas ANTIGUO, asi que una CUENTA con un TUSUARIO inactivo viejo y uno activo nuevo resolvia al inactivo -- y con ese PK se resuelve el p_pk_usuario_solicitante de todo el catalogo, o sea identidad y permisos equivocados. Estaba latente (0 CUENTAS con ambos hoy) y lo activa el arreglo del 409 DUPLICATE_EMAIL en auth-center, que permite reutilizar el correo de un usuario dado de baja y convierte esa convivencia en el caso normal; los indices unicos parciales de TUSUARIO ((cuenta) WHERE active) ya la declaraban legitima. No se filtra ACTIVE del todo: si la unica identidad de la cuenta esta inactiva se devuelve igual, porque para el gate es mas util que un NULL.';
