-- ===========================================================================
-- V296 - fn_sed_crear: la propagacion del permiso de rector/secretaria a la
--        sede nueva inserta directo, sin pasar por la puerta de
--        autorizacion humana.
--
-- POR QUE ESTA MIGRACION EXISTE
--   El paso 6 de fn_sed_crear (REV4) mantiene el invariante "el rector y la
--   secretaria de un EE tienen permiso en TODAS sus sedes": al crear una
--   sede les crea su TSEDE_USUARIO en ella. Lo hacia llamando a
--   fn_fun_permisos_actualizar, que es la funcion DE CARA AL USUARIO, con
--   todos sus guards de autorizacion. Y ahi choca, porque el que crea la
--   sede es normalmente una de esas dos personas:
--
--     * si la crea el propio RECTOR -> el permiso a propagar es el rol
--       Rector, y fn_assert_rango_rol_otorgable lo rechaza: nadie otorga un
--       rol de su misma autoridad. Correcto como regla de usuario (un rector
--       no nombra a otro rector), fatal como paso interno.
--     * si la crea la SECRETARIA (u otro nivel 2 del EE) -> el objetivo del
--       permiso es el rector, un par suyo, y fn_assert_rango_rol lo rechaza:
--       "no se puede consultar ni afectar".
--
--   Medido en el servidor de test:
--
--     rector del EE 887 crea sede    -> 42501 "El rol "Rector" es de
--                                       categoria igual o superior"
--     secretaria del EE 764/766/875  -> 42501 "El funcionario "..." tiene un
--                                       rol de categoria igual o superior"
--     territorial (nivel 1)          -> OK
--     super admin (nivel 0)          -> OK
--
--   Es decir: ningun rector ni secretaria podia crear una sede de su propio
--   establecimiento -- 125 usuarios de nivel 2, y 73 de los 75 EE activos
--   tienen rector asignado, que es lo que dispara la propagacion.
--
--   Ni V294 (excepcion de si-mismo en fn_assert_rango_rol) ni V295 (peso
--   dentro de la misma categoria en fn_assert_rango_rol_otorgable) lo
--   arreglan, y no deben: se verifico que con las dos aplicadas el rector
--   sigue recibiendo 42501, porque el rol que se propaga es precisamente
--   Rector y esa prohibicion es la que queremos conservar.
--
-- QUE CAMBIA
--   Los dos bloques del paso 6 dejan de llamar a
--   fn_fun_permisos_actualizar y hacen el INSERT en TSEDE_USUARIO ellos
--   mismos, mas fn_sincronizar_rol_publico para que el rol se refleje en
--   public.role_users (que es lo unico que fn_sede_usuario_crear hacia
--   ademas de insertar). La fila escrita es identica a la que producia la
--   cadena anterior -- se capturo ejecutando la propagacion como super
--   admin, que si pasaba los guards:
--
--       FK_TLV_JORNADA 51900, ORDEN 1, TLV_ESTADO 'ACTIVO',
--       PREDETERMINADO 0, ACTIVE TRUE, CREATED_BY = el solicitante
--
--   Nada mas cambia: mismos parametros, mismo gate de entrada del paso 0
--   (fn_assert_permiso_seccion sobre SEDES_EDUCATIVAS + el EE), mismas
--   validaciones, mismo consecutivo de codigo.
--
-- POR QUE ES CORRECTO Y NO ABRE UN HUECO
--   Porque quien decide si esta sede puede crearse ya se comprobo en el paso
--   0: capability 'CREAR' sobre el menu SEDES_EDUCATIVAS y scope sobre el EE
--   destino. Una vez autorizado eso, dar permiso al rector y a la secretaria
--   de ESE MISMO EE en la sede recien creada no es una decision del usuario
--   -- es la consecuencia obligada del invariante, sobre dos personas que el
--   propio EE ya designa por puntero (FK_TFUNCIONARIO_RECTOR /
--   FK_TFUNCIONARIO_SECRETARIA). No hay eleccion que autorizar: ni el
--   objetivo ni el rol los elige quien llama.
--
--   La via de usuario para tocar permisos sigue siendo
--   fn_fun_permisos_actualizar, con sus guards intactos.
--
-- OJO -- fn_est_crear delega en fn_sed_crear para su sede por defecto, asi
--   que esta migracion tambien desbloquea la creacion de establecimientos
--   por esa via.
--
-- Idempotente: CREATE OR REPLACE, misma firma (no crea sobrecarga).
-- ===========================================================================


CREATE OR REPLACE FUNCTION academico_test.fn_sed_crear(p_pk_usuario_solicitante bigint, p_codigo character varying, p_nombre character varying, p_fk_lista_valor_zona bigint, p_fk_establecimiento bigint, p_localidad character varying DEFAULT NULL::character varying, p_comuna character varying DEFAULT NULL::character varying, p_barrio character varying DEFAULT NULL::character varying, p_direccion character varying DEFAULT NULL::character varying, p_telefono character varying DEFAULT NULL::character varying, p_georeferenciacion character varying DEFAULT NULL::character varying)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_id_creado             BIGINT;
    v_consecutivo           VARCHAR(2);
    -- REV4 -- sincroniza al rector/secretaria ACTUAL del EE en la sede que
    -- se esta creando (ver paso 6 mas abajo).
    v_pk_rector              BIGINT;
    v_pk_secretaria          BIGINT;
    -- V296 -- la propagacion inserta directo; ya no recoge el RECORD que
    -- devolvia fn_fun_permisos_actualizar.
    v_fk_usuario_rector      BIGINT;
    v_fk_usuario_secretaria  BIGINT;
    c_fk_trol_rector         CONSTANT BIGINT := 7;
    c_fk_trol_secretaria     CONSTANT BIGINT := 9;
    c_fk_tlv_jornada_defecto CONSTANT BIGINT := 51900;
    -- REV3 -- se quita el fallback "resolver el unico EE" (via
    -- fn_resolver_establecimiento_unico): el select de EE del front ahora
    -- se muestra SIEMPRE en el alta, para cualquier rol (ya no es
    -- exclusivo de super-admin) -- p_fk_establecimiento siempre llega
    -- explicito. Ese fallback ademas se rompia con NULL (=> 22023 "es
    -- obligatorio", enmascarado como 42501 en el gate de mas abajo) para
    -- cualquiera que administrara 2+ EE a la vez (algo que dejo de ser
    -- raro con el cambio de modelo de TFUNCIONARIO, ver V51 REV5/REV6).
    v_fk_establecimiento    BIGINT := p_fk_establecimiento;
BEGIN
    -- -----------------------------------------------------------------
    -- 0. Gate de autorizacion (CU-86e2w4xdt): capability por menu + scope,
    --    en UNA sola llamada a fn_assert_permiso_seccion (V29).
    --
    --    Sustituye al gate compuesto anterior (super-admin via
    --    fn_puede_afectar_establecimiento OR rector OR secretaria OR jefe de
    --    sistema con FK_TROL = 8 hardcodeado). Lo que hace ahora el helper:
    --      * bypass SUPER_ADMIN (categoria de rol nivel 0);
    --      * capability: TROL_MENU concede 'CREAR' sobre el menu
    --        SEDES_EDUCATIVAS y TUSUARIO_ROL_PERMISO no se lo recorto al
    --        usuario (fn_usuario_permisos_menu, V185);
    --      * scope: territoriales (nivel 1) alcanzan cualquier EE; los de
    --        nivel establecimiento (rector / jefe de sistema / auxiliar) solo
    --        los EE de fn_usuario_ee_accesibles, que YA incluye los punteros
    --        FK_TFUNCIONARIO_RECTOR / FK_TFUNCIONARIO_SECRETARIA ademas de
    --        las vinculaciones TSEDE_USUARIO -> por eso los caminos (b), (c)
    --        y (d) de antes siguen cubiertos, sin listas de FK_TROL.
    --
    --    El objeto es el EE donde se crea la sede: se pasa
    --    v_fk_establecimiento (el valor resuelto), no p_fk_establecimiento.
    --    Si llega NULL, el helper solo exige capability y la obligatoriedad
    --    del paso 1 lanza el 22023.
    -- -----------------------------------------------------------------
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante,
        'SEDES_EDUCATIVAS',
        'CREAR',
        v_fk_establecimiento
    );

    -- -----------------------------------------------------------------
    -- 1. Validaciones de obligatoriedad.
    -- -----------------------------------------------------------------
    IF NULLIF(TRIM(p_codigo), '') IS NULL THEN
        RAISE EXCEPTION 'Codigo de la sede es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_codigo no puede ser NULL ni vacio';
    END IF;

    IF NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'Nombre de la sede es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_nombre no puede ser NULL ni vacio';
    END IF;

    IF p_fk_lista_valor_zona IS NULL THEN
        RAISE EXCEPTION 'Zona (FK_TLV_ZONA) es obligatoria'
            USING ERRCODE = '22023', HINT = 'p_fk_lista_valor_zona no puede ser NULL';
    END IF;

    IF v_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'Establecimiento (FK_TESTABLECIMIENTO) es obligatorio'
            USING ERRCODE = '22023',
                  HINT = 'p_fk_establecimiento no puede ser NULL y no se pudo resolver automaticamente (el usuario no esta ligado a exactamente un EE como rector/secretaria/jefe de sistema)';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Verificar que el TESTABLECIMIENTO padre existe y esta activo.
    --    No se permite dar de alta sedes bajo un EE inactivo.
    -- -----------------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TESTABLECIMIENTO
         WHERE PK_ESTABLECIMIENTO = v_fk_establecimiento
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se encontro un establecimiento activo con ese identificador'
            USING ERRCODE = '22023',
                  HINT    = 'Verifique el establecimiento o use fn_est_buscar_por_nit(..., p_incluir_inactivos=TRUE)';
    END IF;

    -- -----------------------------------------------------------------
    -- 2a. Verificar que la FK_TLV_ZONA existe y esta activa en
    --     TLISTA_VALOR. Asi no se delega al INSERT para que el caller
    --     reciba el mensaje claro antes de cualquier escritura.
    -- -----------------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_lista_valor_zona
           AND ACTIVE         = TRUE
    ) THEN
        RAISE EXCEPTION 'FK_TLV_ZONA (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lista_valor_zona
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 3. Validacion de unicidad por CODIGO (solo entre sedes activas).
    -- -----------------------------------------------------------------
    IF EXISTS (
        SELECT 1 FROM academico_test.TSEDE
         WHERE CODIGO = p_codigo
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'Ya existe una TSEDE activa con CODIGO %', p_codigo
            USING ERRCODE = '23505',
                  HINT    = 'Use una consulta directa sobre TSEDE para localizar el registro';
    END IF;

    -- Validacion de NOMBRE unico dentro del mismo EE (U_TSEDE_1).
    -- Aqui tambien se acota a activas para mantener simetria con CODIGO;
    -- la constraint dispara igual si se intenta reusar contra un inactivo.
    IF EXISTS (
        SELECT 1 FROM academico_test.TSEDE
         WHERE FK_TESTABLECIMIENTO = v_fk_establecimiento
           AND NOMBRE              = p_nombre
           AND ACTIVE              = TRUE
    ) THEN
        RAISE EXCEPTION 'Ya existe una sede activa con el nombre "%" en este establecimiento', p_nombre
            USING ERRCODE = '23505',
                  HINT    = 'Dentro de un EE el NOMBRE de sede debe ser unico entre activas';
    END IF;

    -- -----------------------------------------------------------------
    -- 4. Calculo del CONSECUTIVO dentro del EE.
    --    Solo se consideran sedes activas para que la reactivacion de
    --    una sede inactiva no choque con U_TSEDE_2. Se usa LPAD a 2
    --    digitos para preservar el orden "01, 02, ..., 99" tal como
    --    aparecen los datos actuales.
    -- -----------------------------------------------------------------
    SELECT LPAD(
             (COALESCE(MAX(NULLIF(TRIM(CONSECUTIVO), '')::INT), 0) + 1)::TEXT,
             2, '0'
           )
      INTO v_consecutivo
      FROM academico_test.TSEDE
     WHERE FK_TESTABLECIMIENTO = v_fk_establecimiento
       AND ACTIVE              = TRUE;

    -- -----------------------------------------------------------------
    -- 5. INSERT. Las FKs no validadas explicitamente aqui: si alguna no
    --    existe, el INSERT fallara con SQLSTATE '23503'.
    --    Campos NOT NULL del DDL que llegan vacios se persisten como ''.
    -- -----------------------------------------------------------------
    INSERT INTO academico_test.TSEDE (
        CODIGO, NOMBRE, CONSECUTIVO, FK_TLV_ZONA,
        LOCALIDAD, COMUNA, BARRIO, DIRECCION, TELEFONO,
        FK_TESTABLECIMIENTO, GEOREFERENCIACION,
        CREATED_BY, CREATED_AT, MODIFIED_BY, MODIFIED_AT, ACTIVE
    ) VALUES (
        p_codigo, p_nombre, v_consecutivo, p_fk_lista_valor_zona,
        COALESCE(NULLIF(TRIM(p_localidad), ''), ''),
        COALESCE(NULLIF(TRIM(p_comuna),    ''), ''),
        COALESCE(NULLIF(TRIM(p_barrio),    ''), ''),
        COALESCE(NULLIF(TRIM(p_direccion), ''), ''),
        COALESCE(NULLIF(TRIM(p_telefono),  ''), ''),
        v_fk_establecimiento, p_georeferenciacion,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP,
        NULL, NULL,
        TRUE
    )
    RETURNING PK_TSEDE INTO v_id_creado;

    -- -----------------------------------------------------------------
    -- 6. REV4 -- Sincroniza al rector/secretaria ACTUAL del EE en esta
    --    sede: si el EE ya tiene rector y/o secretaria asignados, se les
    --    da su permiso (rol 7/9, jornada "Completa") en la sede recien
    --    creada. Mantiene el invariante "rector/secretaria tiene permiso
    --    en TODAS las sedes de su EE", sin importar si la sede se crea
    --    junto con el EE (fn_est_crear delega aqui para su sede por
    --    defecto) o despues, como una sede adicional agregada a mano.
    --    V296 -- se INSERTA directo en TSEDE_USUARIO en vez de delegar en
    --    fn_fun_permisos_actualizar. Mantener un invariante del sistema no
    --    es un acto discrecional del usuario, y pasar por la funcion de cara
    --    al usuario hacia que ningun rector ni secretaria pudiera crear una
    --    sede de su propio EE (ver la cabecera de V296).
    --
    --    Sin guarda anti-duplicados: la sede es nueva, no puede existir
    --    ya un permiso suyo ahi. predeterminado=0 siempre -- una sede
    --    adicional nunca reemplaza la jornada/sede que el usuario ya
    --    tenia marcada como predeterminada.
    -- -----------------------------------------------------------------
    SELECT FK_TFUNCIONARIO_RECTOR, FK_TFUNCIONARIO_SECRETARIA
      INTO v_pk_rector, v_pk_secretaria
      FROM academico_test.TESTABLECIMIENTO
     WHERE PK_ESTABLECIMIENTO = v_fk_establecimiento;

    IF v_pk_rector IS NOT NULL THEN
        SELECT f.FK_TUSUARIO
          INTO v_fk_usuario_rector
          FROM academico_test.TFUNCIONARIO f
         WHERE f.PK_TFUNCIONARIO = v_pk_rector
           AND f.ACTIVE = TRUE;

        IF v_fk_usuario_rector IS NULL THEN
            RAISE EXCEPTION 'El rector del establecimiento (TFUNCIONARIO %) no tiene un usuario activo; no se le pudo dar permiso en la sede nueva',
                v_pk_rector
                USING ERRCODE = 'P0002';
        END IF;

        INSERT INTO academico_test.TSEDE_USUARIO (
            FK_TSEDE, FK_TROL, FK_TUSUARIO,
            FK_TLV_JORNADA, ORDEN,
            TLV_ESTADO, PREDETERMINADO,
            CREATED_BY, CREATED_AT, ACTIVE
        )
        VALUES (
            v_id_creado, c_fk_trol_rector, v_fk_usuario_rector,
            c_fk_tlv_jornada_defecto, 1,
            'ACTIVO', 0,
            p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
        );

        PERFORM academico_test.fn_sincronizar_rol_publico(v_fk_usuario_rector);
    END IF;

    IF v_pk_secretaria IS NOT NULL THEN
        SELECT f.FK_TUSUARIO
          INTO v_fk_usuario_secretaria
          FROM academico_test.TFUNCIONARIO f
         WHERE f.PK_TFUNCIONARIO = v_pk_secretaria
           AND f.ACTIVE = TRUE;

        IF v_fk_usuario_secretaria IS NULL THEN
            RAISE EXCEPTION 'La secretaria del establecimiento (TFUNCIONARIO %) no tiene un usuario activo; no se le pudo dar permiso en la sede nueva',
                v_pk_secretaria
                USING ERRCODE = 'P0002';
        END IF;

        INSERT INTO academico_test.TSEDE_USUARIO (
            FK_TSEDE, FK_TROL, FK_TUSUARIO,
            FK_TLV_JORNADA, ORDEN,
            TLV_ESTADO, PREDETERMINADO,
            CREATED_BY, CREATED_AT, ACTIVE
        )
        VALUES (
            v_id_creado, c_fk_trol_secretaria, v_fk_usuario_secretaria,
            c_fk_tlv_jornada_defecto, 1,
            'ACTIVO', 0,
            p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
        );

        PERFORM academico_test.fn_sincronizar_rol_publico(v_fk_usuario_secretaria);
    END IF;

    RAISE NOTICE 'TSEDE creada: PK=%, CODIGO=%, CONSECUTIVO=%, EE=%',
        v_id_creado, p_codigo, v_consecutivo, v_fk_establecimiento;

    RETURN v_id_creado;
END;
$function$
