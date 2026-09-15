-- ============================================================================
-- V401 — mismo hueco que V399 cerró para fn_est_crear/fn_est_actualizar,
-- ahora en las funciones de SEDE: fn_sed_crear y fn_sed_actualizar nunca
-- llamaban a fn_audit_declarar, asi que sus filas en auditoria.audit_log
-- nunca llevaban `establecimiento` en el contexto (contexto JSON).
--
-- Efecto visible reportado por el usuario tras V400: el rector SI ve su
-- propia sesion activa (V400), pero al abrir "Operaciones" de esa sesion,
-- o la pestaña "Por tablas" -> Sede -> Detalle, aparecia "Sin resultados"
-- pese a que el conteo agregado (que no filtra por fila) mostraba
-- operaciones > 0 -- porque /audits/sessions/:ID/operations y las
-- consultas de detalle por tabla SI filtran cada fila por
-- JSONExtractString(contexto, 'establecimiento') = :CONTEXT.ESTABLISHMENT
-- (V362), y esas filas de sede nunca tuvieron ese campo.
--
-- FIX: se agrega la misma llamada a fn_audit_declarar que V399 agrego en
-- las funciones de establecimiento, ahora en fn_sed_crear (tras el INSERT)
-- y fn_sed_actualizar (antes del UPDATE) -- usando el parametro p_sede_id
-- de fn_audit_declarar, que resuelve TANTO establecimiento como sede en
-- un solo JOIN (TSEDE.FK_TESTABLECIMIENTO).
--
-- Reconstruidas via pg_get_functiondef desde el estado actual en test,
-- con exactamente una linea nueva insertada en cada una (mismo patron
-- que V399).
-- ============================================================================

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

    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Creacion de la sede %s', p_nombre), NULL, v_id_creado);

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

;

CREATE OR REPLACE FUNCTION academico_test.fn_sed_actualizar(p_pk_usuario_solicitante bigint, p_pk_sede bigint, p_codigo character varying DEFAULT NULL::character varying, p_nombre character varying DEFAULT NULL::character varying, p_fk_lista_valor_zona bigint DEFAULT NULL::bigint, p_localidad character varying DEFAULT NULL::character varying, p_comuna character varying DEFAULT NULL::character varying, p_barrio character varying DEFAULT NULL::character varying, p_direccion character varying DEFAULT NULL::character varying, p_telefono character varying DEFAULT NULL::character varying, p_georeferenciacion character varying DEFAULT NULL::character varying)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_estado_actual BOOLEAN;
    v_nombre_actual VARCHAR;
    v_fk_ee        BIGINT;
BEGIN
    -- -----------------------------------------------------------------
    -- 1. Validaciones de existencia y estado (activo). Se hace ANTES del
    --    gate para conocer el FK_TESTABLECIMIENTO sobre el que se valida
    --    la autorizacion (rector/secretaria/jefe del EE concreto). El
    --    orden elegido (existencia -> gate -> estado) prioriza P0002
    --    sobre 42501: si la sede no existe, no tiene sentido hablar de
    --    permisos. Sobre inactivas -> 22023.
    -- -----------------------------------------------------------------
    SELECT ACTIVE, FK_TESTABLECIMIENTO, NOMBRE
      INTO v_estado_actual, v_fk_ee, v_nombre_actual
      FROM academico_test.TSEDE
     WHERE PK_TSEDE = p_pk_sede;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la sede solicitada'
            USING ERRCODE = 'P0002';
    END IF;

    -- -----------------------------------------------------------------
    -- 0. Gate de autorizacion (CU-86e2w4xdt): capability + scope en UNA
    --    llamada a fn_assert_permiso_seccion (V29), sustituyendo al gate
    --    compuesto anterior (super-admin OR rector OR secretaria OR rol 8).
    --    El objeto es la SEDE: se pasa p_pk_sede y, ademas, v_fk_ee (ya
    --    leido arriba) para que el helper no tenga que resolver el EE otra
    --    vez. Los punteros rector/secretaria y las vinculaciones
    --    TSEDE_USUARIO de nivel establecimiento entran por
    --    fn_usuario_ee_accesibles; los territoriales alcanzan cualquier EE.
    --    Capability = 'EDITAR' sobre el menu SEDES_EDUCATIVAS.
    -- -----------------------------------------------------------------
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante,
        'SEDES_EDUCATIVAS',
        'EDITAR',
        v_fk_ee,
        p_pk_sede
    );

    IF v_estado_actual = FALSE THEN
        RAISE EXCEPTION 'La sede "%" se encuentra inactiva; no se puede actualizar', v_nombre_actual
            USING ERRCODE = '22023',
                  HINT    = 'Localice la sede mediante una consulta directa sobre TSEDE';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Validaciones de valor para los campos que llegaron.
    --    Para CODIGO y NOMBRE: '' o solo espacios se rechaza con 22023.
    --    Para FK_TLV_ZONA: <= 0 se rechaza con 22023 (deuda con
    --    GEOREFERENCIACION: queda como esta, sin validacion adicional).
    -- -----------------------------------------------------------------
    IF p_codigo IS NOT NULL AND NULLIF(TRIM(p_codigo), '') IS NULL THEN
        RAISE EXCEPTION 'Codigo de la sede no puede ser vacio si se envia'
            USING ERRCODE = '22023', HINT = 'p_codigo llego como cadena vacia o solo espacios';
    END IF;

    IF p_nombre IS NOT NULL AND NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'Nombre de la sede no puede ser vacio si se envia'
            USING ERRCODE = '22023', HINT = 'p_nombre llego como cadena vacia o solo espacios';
    END IF;

    IF p_fk_lista_valor_zona IS NOT NULL AND p_fk_lista_valor_zona <= 0 THEN
        RAISE EXCEPTION 'Zona (FK_TLV_ZONA) no puede ser <= 0'
            USING ERRCODE = '22023', HINT = 'p_fk_lista_valor_zona invalido';
    END IF;

    -- -----------------------------------------------------------------
    -- 2a. Validacion de existencia y actividad de FK_TLV_ZONA si llega.
    --     Se hace ANTES del UPDATE para no dejar un cambio parcial si
    --     la FK no existe: con la verificacion previa, la operacion
    --     falla de forma atomica sin escribir nada.
    -- -----------------------------------------------------------------
    IF p_fk_lista_valor_zona IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lista_valor_zona
               AND ACTIVE = TRUE
       )
    THEN
        RAISE EXCEPTION 'FK_TLV_ZONA (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lista_valor_zona
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 2b. Validacion de unicidad de CODIGO contra otras sedes activas.
    --     Se excluye el propio PK para permitir reenviar el mismo CODIGO
    --     (es un no-op, no debe chocar consigo mismo).
    -- -----------------------------------------------------------------
    IF p_codigo IS NOT NULL AND EXISTS (
        SELECT 1 FROM academico_test.TSEDE
         WHERE CODIGO  = p_codigo
           AND ACTIVE  = TRUE
           AND PK_TSEDE <> p_pk_sede
    ) THEN
        RAISE EXCEPTION 'Ya existe otra TSEDE activa con CODIGO %', p_codigo
            USING ERRCODE = '23505',
                  HINT    = 'Use una consulta directa sobre TSEDE para localizar el registro que ya lo usa';
    END IF;

    -- Misma logica para NOMBRE dentro del mismo EE (U_TSEDE_1).
    IF p_nombre IS NOT NULL AND EXISTS (
        SELECT 1 FROM academico_test.TSEDE
         WHERE FK_TESTABLECIMIENTO = v_fk_ee
           AND NOMBRE              = p_nombre
           AND ACTIVE              = TRUE
           AND PK_TSEDE           <> p_pk_sede
    ) THEN
        RAISE EXCEPTION 'Ya existe otra TSEDE activa con NOMBRE % para el EE %', p_nombre, v_fk_ee
            USING ERRCODE = '23505',
                  HINT    = 'Dentro de un EE el NOMBRE de sede debe ser unico entre activas';
    END IF;

    -- -----------------------------------------------------------------
    -- 3. UPDATE unico con deteccion granular de cambios.
    --    Tecnica: se compara cada parametro contra el valor actual usando
    --    IS DISTINCT FROM (NULL-safe). Si el parametro no llego (NULL)
    --    o si coincide con el valor actual, no se cuenta como cambio.
    --    Cualquier cambio efectivo enciende 'chg_*'; el OR de todos los
    --    flags determina si MODIFIED_BY/MODIFIED_AT se actualizan.
    --
    --    Beneficios vs. el patron anterior (un UPDATE por columna):
    --      * Una sola sentencia UPDATE => un solo registro en WAL, una
    --        sola entrada en logs de aplicacion, una sola transaccion.
    --      * MODIFIED_BY/MODIFIED_AT se setean UNA vez (no N veces) y
    --        SOLO si al menos una columna efectiva cambio.
    --      * PATCH vacio o PATCH con mismos valores no toca auditoria.
    -- -----------------------------------------------------------------
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualizacion de la sede %s', COALESCE(p_nombre, v_nombre_actual)), NULL, p_pk_sede);

    WITH current AS (
        SELECT CODIGO, NOMBRE, FK_TLV_ZONA, LOCALIDAD, COMUNA, BARRIO,
               DIRECCION, TELEFONO, GEOREFERENCIACION
          FROM academico_test.TSEDE
         WHERE PK_TSEDE = p_pk_sede
    ),
    cambios AS (
        SELECT
            (p_codigo            IS NOT NULL AND p_codigo            IS DISTINCT FROM current.CODIGO)            AS chg_codigo,
            (p_nombre            IS NOT NULL AND p_nombre            IS DISTINCT FROM current.NOMBRE)            AS chg_nombre,
            (p_fk_lista_valor_zona IS NOT NULL AND p_fk_lista_valor_zona IS DISTINCT FROM current.FK_TLV_ZONA)  AS chg_zona,
            (p_localidad         IS NOT NULL AND p_localidad         IS DISTINCT FROM current.LOCALIDAD)         AS chg_localidad,
            (p_comuna            IS NOT NULL AND p_comuna            IS DISTINCT FROM current.COMUNA)            AS chg_comuna,
            (p_barrio            IS NOT NULL AND p_barrio            IS DISTINCT FROM current.BARRIO)            AS chg_barrio,
            (p_direccion         IS NOT NULL AND p_direccion         IS DISTINCT FROM current.DIRECCION)         AS chg_direccion,
            (p_telefono          IS NOT NULL AND p_telefono          IS DISTINCT FROM current.TELEFONO)          AS chg_telefono,
            (p_georeferenciacion IS NOT NULL AND p_georeferenciacion IS DISTINCT FROM current.GEOREFERENCIACION) AS chg_georeferenciacion
        FROM current
    )
    UPDATE academico_test.TSEDE t
       SET CODIGO             = COALESCE(p_codigo,             t.CODIGO),
           NOMBRE             = COALESCE(p_nombre,             t.NOMBRE),
           FK_TLV_ZONA        = COALESCE(p_fk_lista_valor_zona, t.FK_TLV_ZONA),
           LOCALIDAD          = COALESCE(NULLIF(TRIM(p_localidad), ''),  t.LOCALIDAD),
           COMUNA             = COALESCE(NULLIF(TRIM(p_comuna),    ''),  t.COMUNA),
           BARRIO             = COALESCE(NULLIF(TRIM(p_barrio),    ''),  t.BARRIO),
           DIRECCION          = COALESCE(NULLIF(TRIM(p_direccion), ''),  t.DIRECCION),
           TELEFONO           = COALESCE(NULLIF(TRIM(p_telefono),  ''),  t.TELEFONO),
           GEOREFERENCIACION  = COALESCE(p_georeferenciacion,     t.GEOREFERENCIACION),
           MODIFIED_BY        = CASE
                                  WHEN (SELECT c.chg_codigo OR c.chg_nombre OR c.chg_zona
                                             OR c.chg_localidad OR c.chg_comuna OR c.chg_barrio
                                             OR c.chg_direccion OR c.chg_telefono OR c.chg_georeferenciacion
                                            FROM cambios c)
                                  THEN p_pk_usuario_solicitante::VARCHAR
                                  ELSE t.MODIFIED_BY
                                END,
           MODIFIED_AT        = CASE
                                  WHEN (SELECT c.chg_codigo OR c.chg_nombre OR c.chg_zona
                                             OR c.chg_localidad OR c.chg_comuna OR c.chg_barrio
                                             OR c.chg_direccion OR c.chg_telefono OR c.chg_georeferenciacion
                                            FROM cambios c)
                                  THEN CURRENT_TIMESTAMP
                                  ELSE t.MODIFIED_AT
                                END
      FROM cambios c
     WHERE t.PK_TSEDE = p_pk_sede
       AND t.ACTIVE   = TRUE;

    RAISE NOTICE 'TSEDE actualizada: PK=%, autor=%', p_pk_sede, p_pk_usuario_solicitante;

    RETURN p_pk_sede;
END;
$function$

;

DO $$
DECLARE
    v_crear_ok BOOLEAN;
    v_actualizar_ok BOOLEAN;
BEGIN
    SELECT (prosrc ILIKE '%fn_audit_declarar%') INTO v_crear_ok
      FROM pg_proc WHERE proname = 'fn_sed_crear'
       AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'academico_test');

    SELECT (prosrc ILIKE '%fn_audit_declarar%') INTO v_actualizar_ok
      FROM pg_proc WHERE proname = 'fn_sed_actualizar'
       AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'academico_test');

    IF NOT coalesce(v_crear_ok, false) THEN
        RAISE EXCEPTION 'V401: fn_sed_crear no quedo declarando auditoria de establecimiento/sede';
    END IF;
    IF NOT coalesce(v_actualizar_ok, false) THEN
        RAISE EXCEPTION 'V401: fn_sed_actualizar no quedo declarando auditoria de establecimiento/sede';
    END IF;

    RAISE NOTICE 'V401 OK: fn_sed_crear y fn_sed_actualizar ahora etiquetan sus escrituras con establecimiento/sede via fn_audit_declarar.';
END $$;
