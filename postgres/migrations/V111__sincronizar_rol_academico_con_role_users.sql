-- V111 — vincula los roles academicos con public.role_users, para que
-- realmente lleguen al JWT. Dos mecanismos independientes de "rol
-- academico" quedan cubiertos:
--
--   (a) academico_test.TROL via TSEDE_USUARIO (rol por sede/jornada,
--       asignado desde el dialog de permisos de un funcionario).
--   (b) TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR / FK_TFUNCIONARIO_SECRETARIA
--       (quien es el rector/secretaria de un EE, asignado desde
--       fn_est_crear/fn_est_actualizar).
--
-- Ninguno de los dos tenia jamas escrito en public.role_users, que es
-- lo unico que EffectiveRolesResolver lee para armar el claim "roles"
-- del JWT — public.role (CEVAL-<codigo>) y academico_test.TROL
-- (<codigo>) son catalogos independientes, emparejados solo por
-- convencion de nombre (17/17 TROL.codigo calzan con un CEVAL-<codigo>
-- de public.role). Resultado real: un funcionario con TROL o con
-- rector/secretaria asignado seguia con el JWT sin roles CEVAL-*, y
-- cualquier gate de role_endpoint/role_query/role_app lo rechazaba sin
-- importar su rol academico.
--
-- Decision de negocio (explicita, no por convencion de nombre): el
-- campo "secretaria" de TESTABLECIMIENTO mapea al rol
-- CEVAL-AUXILIAR_ADMINISTRATIVO, NO a CEVAL-SECRETARIA — por ahora solo
-- rector y auxiliar administrativo se derivan de TESTABLECIMIENTO;
-- CEVAL-SECRETARIA queda reservado para cuando exista una fuente
-- explicita para ese rol (TSEDE_USUARIO con TROL.codigo='SECRETARIA').
--
-- academico_test.fn_sincronizar_rol_publico(pk_tusuario) recalcula el
-- set COMPLETO de roles CEVAL-* de ese usuario (agrega los que falten,
-- quita los que ya no correspondan) a partir de TSEDE_USUARIO + su
-- condicion de rector/secretaria en TESTABLECIMIENTO — full-resync en
-- cada llamada en vez de sumar/restar incrementalmente, para no tener
-- que rastrear "¿sigue habiendo otra fuente que de este mismo rol?" a
-- mano. Solo toca filas de role_users cuyo public.role.name empiece
-- con 'CEVAL-': SSO-ADMIN/SSO-USER y cualquier rol no-academico quedan
-- intactos.
--
-- Se llama desde los 4 puntos de escritura relevantes:
--   fn_sede_usuario_crear / fn_sede_usuario_soft_delete (TSEDE_USUARIO,
--   los unicos dos que existen hoy — TENTE_USUARIO no tiene ninguna
--   funcion que la use todavia), y fn_est_crear / fn_est_actualizar
--   (rector/secretaria), sincronizando tanto al TUSUARIO que GANA el
--   rol como al que lo pierde cuando el rector/secretaria cambia.
--
-- NOTA (2026-08, CU-86e2w4xdt — Permisos segun rol): las 4 funciones que
-- este archivo redefine (fn_sede_usuario_crear, fn_sede_usuario_soft_delete,
-- fn_est_crear, fn_est_actualizar) son la definicion VIGENTE de cada una
-- (las de V51/V53 quedaron obsoletas), asi que su gate de autorizacion se
-- migro AQUI, in-place. Cada bloque de gate hardcodeado
-- (fn_puede_afectar_usuarios / fn_puede_afectar_establecimiento + "rol 11 de
-- la sede" + "es el rector del EE") se sustituye por una sola llamada a
-- academico_test.fn_assert_permiso_seccion (V29): capability configurable
-- por menu (TROL_MENU + TUSUARIO_ROL_PERMISO, administrada por el super
-- admin) + scope estructural por categoria de rol (todos los EE / sus EE /
-- su par sede+jornada). fn_sede_usuario_crear lleva ademas
-- fn_assert_rango_rol_otorgable: nadie otorga un rol de categoria igual o
-- superior a la suya. Motivo: sacar la autorizacion de listas fijas de
-- FK_TROL quemadas en el cuerpo de cada funcion. Nada mas del cuerpo cambia
-- (validaciones, ERRCODEs, la sincronizacion a public.role_users y la sede
-- por defecto siguen igual). Ver docs/gate-permisos-por-menu-analysis.md.
--
-- Backfill al final: sincroniza todo TUSUARIO con una TSEDE_USUARIO
-- activa hoy, o que sea rector/secretaria de un EE activo hoy, para
-- que el fix no dependa de que alguien vuelva a tocar esos datos para
-- que su JWT se corrija.

CREATE OR REPLACE FUNCTION academico_test.fn_sincronizar_rol_publico(p_pk_tusuario BIGINT)
 RETURNS VOID
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_id_user BIGINT;
BEGIN
    IF p_pk_tusuario IS NULL THEN
        RETURN;
    END IF;

    -- Bridge inverso de public.fn_get_academico_usuario_id: en vez de
    -- id_user -> email -> PK_TUSUARIO, aca vamos PK_TUSUARIO -> CUENTA
    -- -> email -> id_user. Mismo criterio (match por email/CUENTA,
    -- sin tabla puente dedicada).
    SELECT u.id_user
      INTO v_id_user
      FROM academico_test.TUSUARIO t
      JOIN public.users u ON UPPER(u.email) = UPPER(t.CUENTA)
     WHERE t.PK_TUSUARIO = p_pk_tusuario
     LIMIT 1;

    IF v_id_user IS NULL THEN
        -- TUSUARIO sin fila espejo en public.users (dato legado o cuenta
        -- que no calza con ningun email) — nada que sincronizar.
        RETURN;
    END IF;

    -- 1. Agregar los CEVAL-<codigo> que falten. El set deseado es la
    --    UNION de: (a) un codigo por cada TROL con TSEDE_USUARIO activa,
    --    (b) 'RECTOR' si este TUSUARIO es el rector activo de algun EE
    --    activo, (c) 'AUXILIAR_ADMINISTRATIVO' si lo es de la
    --    "secretaria" de algun EE activo.
    INSERT INTO public.role_users (user_id, role_id)
    SELECT v_id_user, r.id_role
      FROM (
            SELECT tr.CODIGO
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TROL tr ON tr.PK_TROL = su.FK_TROL
             WHERE su.FK_TUSUARIO = p_pk_tusuario
               AND su.ACTIVE      = TRUE
            UNION
            SELECT 'RECTOR'
             WHERE EXISTS (
                    SELECT 1
                      FROM academico_test.TESTABLECIMIENTO e
                      JOIN academico_test.TFUNCIONARIO f
                        ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
                     WHERE f.FK_TUSUARIO = p_pk_tusuario
                       AND f.ACTIVE       = TRUE
                       AND e.ACTIVE       = TRUE
                  )
            UNION
            SELECT 'AUXILIAR_ADMINISTRATIVO'
             WHERE EXISTS (
                    SELECT 1
                      FROM academico_test.TESTABLECIMIENTO e
                      JOIN academico_test.TFUNCIONARIO f
                        ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
                     WHERE f.FK_TUSUARIO = p_pk_tusuario
                       AND f.ACTIVE       = TRUE
                       AND e.ACTIVE       = TRUE
                  )
           ) deseados(CODIGO)
      JOIN public.role r ON r.name = 'CEVAL-' || deseados.CODIGO
     WHERE NOT EXISTS (
            SELECT 1 FROM public.role_users ru
             WHERE ru.user_id = v_id_user AND ru.role_id = r.id_role
           );

    -- 2. Quitar los CEVAL-* que ya no tengan ninguna fuente detras
    --    (ni TSEDE_USUARIO activa, ni rector/secretaria de un EE
    --    activo). Filtro "r.name LIKE 'CEVAL-%'" es lo que evita tocar
    --    SSO-ADMIN/SSO-USER u otros roles no derivados del modulo
    --    academico.
    DELETE FROM public.role_users ru
     USING public.role r
     WHERE ru.user_id = v_id_user
       AND ru.role_id = r.id_role
       AND r.name LIKE 'CEVAL-%'
       AND NOT EXISTS (
            SELECT 1
              FROM (
                    SELECT tr.CODIGO
                      FROM academico_test.TSEDE_USUARIO su
                      JOIN academico_test.TROL tr ON tr.PK_TROL = su.FK_TROL
                     WHERE su.FK_TUSUARIO = p_pk_tusuario
                       AND su.ACTIVE      = TRUE
                    UNION
                    SELECT 'RECTOR'
                     WHERE EXISTS (
                            SELECT 1
                              FROM academico_test.TESTABLECIMIENTO e
                              JOIN academico_test.TFUNCIONARIO f
                                ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
                             WHERE f.FK_TUSUARIO = p_pk_tusuario
                               AND f.ACTIVE       = TRUE
                               AND e.ACTIVE       = TRUE
                          )
                    UNION
                    SELECT 'AUXILIAR_ADMINISTRATIVO'
                     WHERE EXISTS (
                            SELECT 1
                              FROM academico_test.TESTABLECIMIENTO e
                              JOIN academico_test.TFUNCIONARIO f
                                ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
                             WHERE f.FK_TUSUARIO = p_pk_tusuario
                               AND f.ACTIVE       = TRUE
                               AND e.ACTIVE       = TRUE
                          )
                   ) deseados(CODIGO)
             WHERE 'CEVAL-' || deseados.CODIGO = r.name
           );
END;
$function$
;

-- fn_sede_usuario_crear — igual al cuerpo vigente, mas la llamada a
-- fn_sincronizar_rol_publico justo antes del RETURN.
CREATE OR REPLACE FUNCTION academico_test.fn_sede_usuario_crear(p_pk_usuario_solicitante bigint, p_fk_sede bigint, p_fk_rol bigint, p_fk_usuario bigint, p_orden numeric DEFAULT NULL::numeric, p_fk_tlv_jornada bigint DEFAULT NULL::bigint, p_tlv_estado character varying DEFAULT 'ACTIVO'::character varying, p_predeterminado numeric DEFAULT 0)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_pk_sede_usuario  BIGINT;
BEGIN
    -- ---------------------------------------------------------------------
    -- 0. Gate de autorizacion (CU-86e2w4xdt): capability por el menu
    --    FUNCIONARIOS (accion EDITAR, configurable via TROL_MENU /
    --    TUSUARIO_ROL_PERMISO) + scope sobre la SEDE objetivo -- que es el
    --    objeto real de esta funcion: su EE para los niveles 1/2, o el par
    --    (sede, jornada) para el nivel 3 (coordinador y demas roles de
    --    sede). Sustituye al gate hardcodeado anterior (fn_puede_afectar_
    --    usuarios, es decir roles 1-3/7/8/9, O "rol 11 de esta sede y solo
    --    para roles 9-14"). El caller de mas arriba
    --    (fn_fun_permisos_actualizar) ya valida lo suyo, pero esta funcion
    --    conserva gate propio porque otros callers (fn_est_crear,
    --    fn_sed_crear) la invocan directo.
    -- ---------------------------------------------------------------------
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'FUNCIONARIOS', 'EDITAR',
        NULL, p_fk_sede, p_fk_tlv_jornada
    );

    -- ---------------------------------------------------------------------
    -- 1. Validaciones de obligatoriedad.
    -- ---------------------------------------------------------------------
    IF p_fk_sede IS NULL THEN
        RAISE EXCEPTION 'sede (fk_sede) es obligatoria' USING ERRCODE = '23502';
    END IF;
    IF p_fk_rol IS NULL THEN
        RAISE EXCEPTION 'rol (fk_rol) es obligatorio' USING ERRCODE = '23502';
    END IF;
    IF p_fk_usuario IS NULL THEN
        RAISE EXCEPTION 'usuario (fk_usuario) es obligatorio' USING ERRCODE = '23502';
    END IF;
    IF p_orden IS NULL THEN
        RAISE EXCEPTION 'orden es obligatorio' USING ERRCODE = '23502';
    END IF;
    IF p_fk_tlv_jornada IS NULL THEN
        RAISE EXCEPTION 'jornada (fk_tlv_jornada) es obligatoria' USING ERRCODE = '23502';
    END IF;

    IF p_tlv_estado NOT IN ('ACTIVO', 'INACTIVO') THEN
        RAISE EXCEPTION 'TLV_ESTADO (%) no es valido; se esperaba ACTIVO o INACTIVO',
            p_tlv_estado
            USING ERRCODE = '22023';
    END IF;

    -- ---------------------------------------------------------------------
    -- 2. Validacion de FKs: TSEDE, TROL, TUSUARIO, TLISTA_VALOR (jornada).
    -- ---------------------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TSEDE
         WHERE PK_TSEDE = p_fk_sede
           AND ACTIVE   = TRUE
    ) THEN
        RAISE EXCEPTION 'La sede indicada no existe o no esta activa'
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TROL
         WHERE PK_TROL = p_fk_rol
           AND ACTIVE  = TRUE
    ) THEN
        RAISE EXCEPTION 'TROL (%) no existe o no esta activo', p_fk_rol
            USING ERRCODE = '23503';
    END IF;

    -- Capa 3 (CU-86e2w4xdt): no se puede OTORGAR un rol de categoria igual
    -- o superior a la propia (V29). Va aqui, despues de validar que el rol
    -- existe y esta activo, para que un p_fk_rol invalido siga devolviendo
    -- su 23502/23503 de siempre y no un 42501 enganoso.
    PERFORM academico_test.fn_assert_rango_rol_otorgable(
        p_pk_usuario_solicitante, p_fk_rol
    );

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TUSUARIO
         WHERE PK_TUSUARIO = p_fk_usuario
           AND ACTIVE       = TRUE
    ) THEN
        RAISE EXCEPTION 'TUSUARIO (%) no existe o no esta activo', p_fk_usuario
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_tlv_jornada
           AND ACTIVE         = TRUE
    ) THEN
        RAISE EXCEPTION 'jornada/TLV (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_tlv_jornada
            USING ERRCODE = '23503';
    END IF;

    -- ---------------------------------------------------------------------
    -- 3. Validacion de unicidad contra TSEDE_USUARIO activos.
    --    UK_TSEDE_USUARIO_1: (FK_TSEDE, FK_TROL, FK_TUSUARIO, FK_TLV_JORNADA).
    --    UK_TSEDE_USUARIO_2: (FK_TSEDE, FK_TROL, FK_TUSUARIO, ORDEN).
    --    Como la UNIQUE constraint cubre TODOS los registros (incluyendo
    --    inactivos), validamos solo entre activos para permitir reusar
    --    combinaciones previamente dadas de baja.
    -- ---------------------------------------------------------------------
    IF EXISTS (
        SELECT 1 FROM academico_test.TSEDE_USUARIO
         WHERE FK_TSEDE       = p_fk_sede
           AND FK_TROL        = p_fk_rol
           AND FK_TUSUARIO    = p_fk_usuario
           AND FK_TLV_JORNADA = p_fk_tlv_jornada
           AND ACTIVE         = TRUE
    ) THEN
        RAISE EXCEPTION 'ya existe un TSEDE_USUARIO activo para (sede=%, rol=%, usuario=%, jornada=%)',
            p_fk_sede, p_fk_rol, p_fk_usuario, p_fk_tlv_jornada
            USING ERRCODE = '23505';
    END IF;

    IF EXISTS (
        SELECT 1 FROM academico_test.TSEDE_USUARIO
         WHERE FK_TSEDE    = p_fk_sede
           AND FK_TROL     = p_fk_rol
           AND FK_TUSUARIO = p_fk_usuario
           AND ORDEN       = p_orden
           AND ACTIVE      = TRUE
    ) THEN
        RAISE EXCEPTION 'ya existe un TSEDE_USUARIO activo para (sede=%, rol=%, usuario=%, orden=%)',
            p_fk_sede, p_fk_rol, p_fk_usuario, p_orden
            USING ERRCODE = '23505';
    END IF;

    -- ---------------------------------------------------------------------
    -- 4. INSERT.
    -- ---------------------------------------------------------------------
    INSERT INTO academico_test.TSEDE_USUARIO (
        FK_TSEDE, FK_TROL, FK_TUSUARIO,
        FK_TLV_JORNADA, ORDEN,
        TLV_ESTADO, PREDETERMINADO,
        CREATED_BY, CREATED_AT, ACTIVE
    )
    VALUES (
        p_fk_sede, p_fk_rol, p_fk_usuario,
        p_fk_tlv_jornada, p_orden,
        p_tlv_estado, p_predeterminado,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TSEDE_USUARIO INTO v_pk_sede_usuario;

    -- V111 — refleja el rol recien asignado en public.role_users, para
    -- que el JWT del usuario lo vea sin esperar a su proximo login.
    PERFORM academico_test.fn_sincronizar_rol_publico(p_fk_usuario);

    RETURN v_pk_sede_usuario;
END;
$function$
;

-- fn_sede_usuario_soft_delete — igual al cuerpo vigente, mas capturar
-- FK_TUSUARIO en el SELECT inicial y llamar a
-- fn_sincronizar_rol_publico despues del UPDATE.
CREATE OR REPLACE FUNCTION academico_test.fn_sede_usuario_soft_delete(p_pk_sede_usuario bigint, p_pk_usuario_solicitante bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_active       BOOLEAN;
    v_pk_tusuario  BIGINT;
    v_fk_sede      BIGINT;
    v_fk_rol       BIGINT;
    -- CU-86e2w4xdt -- la jornada de la fila que se da de baja: el scope de
    -- los roles de categoria ADMINISTRATIVOS_SEDES (nivel 3) es el PAR
    -- (sede, jornada), no la sede sola.
    v_fk_jornada   BIGINT;
BEGIN
    -- ---------------------------------------------------------------------
    -- 1. Validacion de existencia primero -- el gate (paso 0 mas abajo)
    --    necesita saber la sede/jornada de este permiso puntual para poder
    --    evaluar el scope del solicitante. (Idempotente: si ya esta
    --    inactivo, retornamos el PK sin error, sin pasar por el gate --
    --    ver mas abajo.)
    --    Columnas con alias de tabla a proposito (bug real de V199: un OUT
    --    param choco con un SELECT sin alias).
    -- ---------------------------------------------------------------------
    SELECT su.ACTIVE, su.FK_TUSUARIO, su.FK_TSEDE, su.FK_TROL, su.FK_TLV_JORNADA
      INTO v_active, v_pk_tusuario, v_fk_sede, v_fk_rol, v_fk_jornada
      FROM academico_test.TSEDE_USUARIO su
     WHERE su.PK_TSEDE_USUARIO = p_pk_sede_usuario;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el permiso solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    -- ---------------------------------------------------------------------
    -- 0. Gate de autorizacion (CU-86e2w4xdt): capability EDITAR sobre el
    --    menu FUNCIONARIOS + scope sobre la sede/jornada de ESTE permiso
    --    puntual (V29). Sustituye al gate hardcodeado anterior
    --    (fn_puede_afectar_usuarios O "rol 11 de esta sede, y solo para
    --    roles 9-14"): quien alcanza la sede ahora sale de la categoria del
    --    rol, no de una lista de FK_TROL.
    -- ---------------------------------------------------------------------
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'FUNCIONARIOS', 'EDITAR',
        NULL, v_fk_sede, v_fk_jornada
    );

    IF v_active = FALSE THEN
        -- ya estaba inactivo: idempotente, no error. Ya se sincronizo la
        -- vez que se dio de baja, no hace falta repetirlo.
        RETURN p_pk_sede_usuario;
    END IF;

    -- ---------------------------------------------------------------------
    -- 2. UPDATE: ACTIVE=FALSE + auditoria.
    -- ---------------------------------------------------------------------
    UPDATE academico_test.TSEDE_USUARIO
       SET ACTIVE      = FALSE,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TSEDE_USUARIO = p_pk_sede_usuario;

    -- V111 — si esta era la ultima sede activa que le daba este TROL al
    -- usuario, fn_sincronizar_rol_publico le quita el CEVAL-<codigo> de
    -- public.role_users. Si le queda otra sede con el mismo rol, no pasa
    -- nada (full-resync, no resta a ciegas).
    PERFORM academico_test.fn_sincronizar_rol_publico(v_pk_tusuario);

    RETURN p_pk_sede_usuario;
END;
$function$
;

-- fn_est_crear — igual al cuerpo vigente, mas sincronizar al rector y/o
-- secretaria si llegaron en la creacion.
CREATE OR REPLACE FUNCTION academico_test.fn_est_crear(p_pk_usuario_solicitante bigint, p_nombre character varying, p_nit character varying, p_fk_municipio bigint, p_fk_propiedad_juridica bigint, p_codigo character varying, p_localidad character varying DEFAULT NULL::character varying, p_comuna character varying DEFAULT NULL::character varying, p_barrio character varying DEFAULT NULL::character varying, p_direccion character varying DEFAULT NULL::character varying, p_correo_electronico character varying DEFAULT NULL::character varying, p_telefono character varying DEFAULT NULL::character varying, p_fax character varying DEFAULT NULL::character varying, p_idecol character varying DEFAULT NULL::character varying, p_pagina_web character varying DEFAULT NULL::character varying, p_fk_lista_valor_zona bigint DEFAULT NULL::bigint, p_resolucion_aprobacion character varying DEFAULT NULL::character varying, p_licencia_funcionamiento character varying DEFAULT NULL::character varying, p_fecha_licencia date DEFAULT NULL::date, p_fk_lv_calendario bigint DEFAULT NULL::bigint, p_fk_lv_idioma bigint DEFAULT NULL::bigint, p_fk_lv_genero_est bigint DEFAULT NULL::bigint, p_fk_discapacidad bigint DEFAULT NULL::bigint, p_talento academico_test.bool_sn DEFAULT NULL::character varying, p_etnias academico_test.bool_sn DEFAULT NULL::character varying, p_fk_tfuncionario_rector bigint DEFAULT NULL::bigint, p_fk_tfuncionario_secretaria bigint DEFAULT NULL::bigint, p_subsidio academico_test.bool_sn DEFAULT NULL::character varying, p_fk_lv_regimen_catcosto bigint DEFAULT NULL::bigint, p_fk_lv_rango_tarifa bigint DEFAULT NULL::bigint, p_fk_lv_asociacion_nacional bigint DEFAULT NULL::bigint, p_fk_archivo bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_id_creado BIGINT;
    -- Estado "Activo" del catalogo de estados de establecimiento. Ya no se
    -- recibe por parametro: toda alta arranca activa.
    c_fk_lv_estado_activo CONSTANT BIGINT := 533;
    -- REV4 -- sede por defecto (mismo CODIGO/NOMBRE que el EE) + permiso
    -- de rector/secretaria en ella. "Urbana y Rural" (216): zona por
    -- defecto pedida para esta sede -- no hay info real de zona todavia
    -- al momento de crear el EE. "Completa" (51900): jornada por defecto
    -- para el permiso de rector/secretaria -- son cargos administrativos,
    -- no atados a una jornada de aula; ajustar si el negocio prefiere otra.
    c_fk_tlv_zona_defecto    CONSTANT BIGINT := 216;
    c_fk_tlv_jornada_defecto CONSTANT BIGINT := 51900;
    c_fk_trol_rector         CONSTANT BIGINT := 7;
    c_fk_trol_secretaria     CONSTANT BIGINT := 9;
    v_pk_sede_creada         BIGINT;
    v_perm_result            RECORD;
BEGIN
    -- -----------------------------------------------------------------
    -- 0. Gate de autorizacion (CU-86e2w4xdt): capability CREAR sobre el
    --    menu ESTABLECIMIENTO (V29). SIN objeto: crear un EE no tiene un EE
    --    previo sobre el que evaluar scope, asi que la capability basta --
    --    igual que antes, cuando bastaba con fn_puede_afectar_
    --    establecimiento. La diferencia es que ahora quien puede crear lo
    --    configura el super admin por TROL_MENU en vez de ser la lista fija
    --    de roles 1-3.
    --    p_pk_usuario_solicitante es obligatorio por firma (sin DEFAULT).
    -- -----------------------------------------------------------------
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'ESTABLECIMIENTO', 'CREAR'
    );

    -- -----------------------------------------------------------------
    -- 1. Validaciones de obligatoriedad (DDL NOT NULL + NIT funcional)
    -- -----------------------------------------------------------------
    IF NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'Nombre del establecimiento es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_nombre no puede ser NULL ni vacio';
    END IF;

    IF NULLIF(TRIM(p_nit), '') IS NULL THEN
        RAISE EXCEPTION 'NIT del establecimiento es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_nit no puede ser NULL ni vacio';
    END IF;

    IF NULLIF(TRIM(p_codigo), '') IS NULL THEN
        RAISE EXCEPTION 'Codigo del establecimiento es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_codigo no puede ser NULL ni vacio';
    END IF;

    IF p_fk_municipio IS NULL THEN
        RAISE EXCEPTION 'Municipio (FK_TMUNICIPIO) es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_fk_municipio no puede ser NULL';
    END IF;

    IF p_fk_propiedad_juridica IS NULL THEN
        RAISE EXCEPTION 'Propiedad juridica (FK_TPROPIEDAD_JURIDICA) es obligatoria'
            USING ERRCODE = '22023', HINT = 'p_fk_propiedad_juridica no puede ser NULL';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Validacion de unicidad por NIT (solo activos)
    --    CODIGO ya tiene UNIQUE constraint en el DDL (U_TESTABLECIMIENTO_1).
    -- -----------------------------------------------------------------
    IF EXISTS (
        SELECT 1 FROM academico_test.TESTABLECIMIENTO
        WHERE NIT = p_nit AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'Ya existe un TESTABLECIMIENTO activo con NIT %', p_nit
            USING ERRCODE = '23505',
                  HINT    = 'Use fn_est_buscar_por_nit('') para obtener el registro existente';
    END IF;

    -- Validacion de CODIGO solo entre activos: la UNIQUE constraint
    -- U_TESTABLECIMIENTO_1 cubre TODOS los CODIGO (incluyendo inactivos).
    -- Aqui forzamos la misma semantica que NIT: un CODIGO inactivo puede
    -- reutilizarse, uno activo no.
    IF EXISTS (
        SELECT 1 FROM academico_test.TESTABLECIMIENTO
        WHERE CODIGO = p_codigo AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'Ya existe un TESTABLECIMIENTO activo con CODIGO %', p_codigo
            USING ERRCODE = '23505',
                  HINT    = 'Use fn_est_buscar_por_nit('') o un SELECT directo para localizarlo';
    END IF;

    -- -----------------------------------------------------------------
    -- 2a. Validacion de FKs obligatorias (no se delega al INSERT para
    --     dar un mensaje claro al caller en vez del SQLSTATE '23503'
    --     generico del DDL).
    -- -----------------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TMUNICIPIO
         WHERE PK_TMUNICIPIO = p_fk_municipio
    ) THEN
        RAISE EXCEPTION 'FK_TMUNICIPIO (%) no existe en TMUNICIPIO', p_fk_municipio
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TPROPIEDAD_JURIDICA
         WHERE PK_PROPIEDAD_JURIDICA = p_fk_propiedad_juridica
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'FK_TPROPIEDAD_JURIDICA (%) no existe o no esta activa en TPROPIEDAD_JURIDICA',
            p_fk_propiedad_juridica
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 2b. Validacion de FKs opcionales contra TLISTA_VALOR.
    --     Solo se validan las que llegaron con valor (no NULL).
    --     Se valida existencia + ACTIVE=TRUE para mantener consistencia
    --     con el resto de las funciones del modulo academico.
    -- -----------------------------------------------------------------
    IF p_fk_lista_valor_zona IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lista_valor_zona
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLISTA_VALOR_ZONA (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lista_valor_zona
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_lv_calendario IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lv_calendario
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLV_CALENDARIO (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lv_calendario
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_lv_idioma IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lv_idioma
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLV_IDIOMA (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lv_idioma
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_lv_genero_est IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lv_genero_est
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLV_GENERO_EST (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lv_genero_est
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_lv_regimen_catcosto IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lv_regimen_catcosto
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLV_REGIMEN_CATCOSTO (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lv_regimen_catcosto
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_lv_rango_tarifa IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lv_rango_tarifa
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLV_RANGO_TARIFA (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lv_rango_tarifa
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_lv_asociacion_nacional IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lv_asociacion_nacional
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLV_ASOCIACION_NACIONAL (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lv_asociacion_nacional
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 2c. Validacion de FK_TDISCAPACIDAD opcional.
    -- -----------------------------------------------------------------
    IF p_fk_discapacidad IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TDISCAPACIDAD
             WHERE PK_DISCAPACIDAD = p_fk_discapacidad
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TDISCAPACIDAD (%) no existe o no esta activa en TDISCAPACIDAD',
            p_fk_discapacidad
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 2d. Validacion de FK_TFUNCIONARIO_RECTOR / SECRETARIA opcionales.
    --     Ambos deben ser funcionarios activos.
    -- -----------------------------------------------------------------
    IF p_fk_tfuncionario_rector IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TFUNCIONARIO
             WHERE PK_TFUNCIONARIO = p_fk_tfuncionario_rector
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TFUNCIONARIO_RECTOR (%) no existe o no esta activo en TFUNCIONARIO',
            p_fk_tfuncionario_rector
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tfuncionario_secretaria IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TFUNCIONARIO
             WHERE PK_TFUNCIONARIO = p_fk_tfuncionario_secretaria
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TFUNCIONARIO_SECRETARIA (%) no existe o no esta activo en TFUNCIONARIO',
            p_fk_tfuncionario_secretaria
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 2e. Validacion de FK_TARCHIVO opcional.
    -- -----------------------------------------------------------------
    IF p_fk_archivo IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TARCHIVO
             WHERE PK_TARCHIVO = p_fk_archivo
          )
    THEN
        RAISE EXCEPTION 'FK_TARCHIVO (%) no existe en TARCHIVO', p_fk_archivo
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 3. INSERT. Las FKs no validadas explicitamente aqui: si alguna no
    --    existe, el INSERT fallara con SQLSTATE '23503' (FK violation)
    --    y ese mensaje sera suficientemente claro para el caller.
    --    FK_TLV_ESTADO_ESTABLECIMIENTO ya no llega por parametro: todo
    --    alta se crea con c_fk_lv_estado_activo (533, "Activo").
    -- -----------------------------------------------------------------
    INSERT INTO academico_test.TESTABLECIMIENTO (
        CODIGO, NOMBRE, NIT,
        FK_TMUNICIPIO, FK_TLISTA_VALOR_ZONA,
        LOCALIDAD, COMUNA, BARRIO, DIRECCION,
        CORREO_ELECTRONICO, TELEFONO, FAX, IDECOL, PAGINA_WEB,
        RESOLUCION_APROBACION, LICENCIA_FUNCIONAMIENTO, FECHA_LICENCIA,
        FK_TPROPIEDAD_JURIDICA,
        FK_TLV_CALENDARIO, FK_TLV_IDIOMA, FK_TLV_GENERO_EST, FK_TDISCAPACIDAD,
        TALENTO, ETNIAS,
        FK_TFUNCIONARIO_RECTOR, FK_TFUNCIONARIO_SECRETARIA, SUBSIDIO,
        FK_TLV_REGIMEN_CATCOSTO, FK_TLV_RANGO_TARIFA,
        FK_TLV_ASOCIACION_NACIONAL, FK_TLV_ESTADO_ESTABLECIMIENTO,
        FK_TARCHIVO,
        CREATED_BY, CREATED_AT, MODIFIED_BY, MODIFIED_AT, ACTIVE
    ) VALUES (
        p_codigo, p_nombre, p_nit,
        p_fk_municipio, p_fk_lista_valor_zona,
        p_localidad, p_comuna, p_barrio, p_direccion,
        p_correo_electronico, p_telefono, p_fax, p_idecol, p_pagina_web,
        p_resolucion_aprobacion, p_licencia_funcionamiento, p_fecha_licencia,
        p_fk_propiedad_juridica,
        p_fk_lv_calendario, p_fk_lv_idioma, p_fk_lv_genero_est, p_fk_discapacidad,
        p_talento, p_etnias,
        p_fk_tfuncionario_rector, p_fk_tfuncionario_secretaria, p_subsidio,
        p_fk_lv_regimen_catcosto, p_fk_lv_rango_tarifa,
        p_fk_lv_asociacion_nacional, c_fk_lv_estado_activo,
        p_fk_archivo,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP,
        NULL, NULL,
        TRUE
    )
    RETURNING PK_ESTABLECIMIENTO INTO v_id_creado;

    -- -----------------------------------------------------------------
    -- 4. REV4 -- Sede por defecto: mismo CODIGO/NOMBRE que el EE recien
    --    creado, zona c_fk_tlv_zona_defecto ("Urbana y Rural"). Se delega
    --    en fn_sed_crear (mismas validaciones/consecutivo/auditoria que
    --    una sede creada a mano) en vez de duplicar el INSERT -- el gate
    --    de fn_sed_crear siempre deja pasar a quien ya paso el gate de
    --    este mismo fn_est_crear (solo super-admin llega hasta aca).
    -- -----------------------------------------------------------------
    v_pk_sede_creada := academico_test.fn_sed_crear(
        p_pk_usuario_solicitante => p_pk_usuario_solicitante,
        p_codigo                 => p_codigo,
        p_nombre                 => p_nombre,
        p_fk_lista_valor_zona    => c_fk_tlv_zona_defecto,
        p_fk_establecimiento     => v_id_creado
    );

    -- -----------------------------------------------------------------
    -- 5. REV5 -- El permiso por defecto del rector (rol 7) y de la
    --    secretaria (rol 9, Auxiliar administrativo) en la sede recien
    --    creada YA NO se hace aca: fn_sed_crear (llamado en el paso 4) lo
    --    hace solo, leyendo el rector/secretaria directo de TESTABLECIMIENTO
    --    (que ya quedo con esos valores en el INSERT del paso 3, antes de
    --    llegar aca) -- ver su paso 6. Asi el mismo comportamiento aplica
    --    tambien cuando se agrega una sede adicional despues, no solo a
    --    la sede por defecto del alta.
    -- -----------------------------------------------------------------

    -- V70 — refleja al rector/secretaria recien asignado en
    -- public.role_users. Van por FK_TUSUARIO del TFUNCIONARIO, no por
    -- el PK del establecimiento. (Sincronizado a la migracion junto con
    -- REV4 -- vivia aplicado en la base pero no se habia escrito aca.)
    IF p_fk_tfuncionario_rector IS NOT NULL THEN
        PERFORM academico_test.fn_sincronizar_rol_publico(
            (SELECT FK_TUSUARIO FROM academico_test.TFUNCIONARIO
              WHERE PK_TFUNCIONARIO = p_fk_tfuncionario_rector)
        );
    END IF;
    IF p_fk_tfuncionario_secretaria IS NOT NULL THEN
        PERFORM academico_test.fn_sincronizar_rol_publico(
            (SELECT FK_TUSUARIO FROM academico_test.TFUNCIONARIO
              WHERE PK_TFUNCIONARIO = p_fk_tfuncionario_secretaria)
        );
    END IF;

    RETURN v_id_creado;
END;
$function$
;

-- fn_est_actualizar — igual al cuerpo vigente, mas capturar el rector/
-- secretaria PREVIOS antes del UPDATE, y sincronizar tanto al que gana
-- el rol como al que lo pierde cuando cambian.
CREATE OR REPLACE FUNCTION academico_test.fn_est_actualizar(p_pk_usuario_solicitante bigint, p_pk_establecimiento bigint, p_nombre character varying DEFAULT NULL::character varying, p_nit character varying DEFAULT NULL::character varying, p_fk_municipio bigint DEFAULT NULL::bigint, p_fk_propiedad_juridica bigint DEFAULT NULL::bigint, p_codigo character varying DEFAULT NULL::character varying, p_localidad character varying DEFAULT NULL::character varying, p_comuna character varying DEFAULT NULL::character varying, p_barrio character varying DEFAULT NULL::character varying, p_direccion character varying DEFAULT NULL::character varying, p_correo_electronico character varying DEFAULT NULL::character varying, p_telefono character varying DEFAULT NULL::character varying, p_fax character varying DEFAULT NULL::character varying, p_idecol character varying DEFAULT NULL::character varying, p_pagina_web character varying DEFAULT NULL::character varying, p_fk_lista_valor_zona bigint DEFAULT NULL::bigint, p_resolucion_aprobacion character varying DEFAULT NULL::character varying, p_licencia_funcionamiento character varying DEFAULT NULL::character varying, p_fecha_licencia date DEFAULT NULL::date, p_fk_lv_calendario bigint DEFAULT NULL::bigint, p_fk_lv_idioma bigint DEFAULT NULL::bigint, p_fk_lv_genero_est bigint DEFAULT NULL::bigint, p_fk_discapacidad bigint DEFAULT NULL::bigint, p_talento academico_test.bool_sn DEFAULT NULL::character varying, p_etnias academico_test.bool_sn DEFAULT NULL::character varying, p_fk_tfuncionario_rector bigint DEFAULT NULL::bigint, p_fk_tfuncionario_secretaria bigint DEFAULT NULL::bigint, p_subsidio academico_test.bool_sn DEFAULT NULL::character varying, p_fk_lv_regimen_catcosto bigint DEFAULT NULL::bigint, p_fk_lv_rango_tarifa bigint DEFAULT NULL::bigint, p_fk_lv_asociacion_nacional bigint DEFAULT NULL::bigint, p_fk_lv_estado_establecimiento bigint DEFAULT NULL::bigint, p_fk_archivo bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_estado_actual  BOOLEAN;
    v_nombre_actual  VARCHAR;
    -- (v_fk_rector / v_es_rector eliminadas en CU-86e2w4xdt: el gate ya no
    --  resuelve "es el rector de este EE" inline; lo hace V29 via
    --  fn_usuario_ee_accesibles.)
    -- V70 — rector/secretaria PREVIOS, capturados antes del UPDATE para
    -- poder sincronizar tambien a quien pierde el rol si cambia.
    v_old_rector      BIGINT;
    v_old_secretaria  BIGINT;
    -- REV6 -- ya no se ubica "la sede por defecto" por NOMBRE/CODIGO: se
    -- sincroniza el permiso del rector/secretaria en TODAS las sedes
    -- activas del EE (ver 3c/3d mas abajo). "Completa" (51900): jornada
    -- por defecto, mismo criterio que fn_est_crear.
    v_pk_sede_loop         BIGINT;
    v_perm_result          RECORD;
    c_fk_tlv_jornada_defecto CONSTANT BIGINT := 51900;
    c_fk_trol_rector         CONSTANT BIGINT := 7;
    c_fk_trol_secretaria     CONSTANT BIGINT := 9;
    -- REV5 -- PK_TSEDE_USUARIO del permiso por defecto que hay que quitar
    -- a quien PIERDE el puesto de rector/secretaria (reusado entre los dos
    -- bloques de abajo).
    v_pk_permiso_a_quitar    BIGINT;
BEGIN
    -- -----------------------------------------------------------------
    -- 0. Validacion de parametros clave (obligatorios por firma).
    -- -----------------------------------------------------------------
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;
    IF p_pk_establecimiento IS NULL OR p_pk_establecimiento <= 0 THEN
        RAISE EXCEPTION 'p_pk_establecimiento es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    -- -----------------------------------------------------------------
    -- 1. Gate de autorizacion (CU-86e2w4xdt): capability EDITAR sobre el
    --    menu ESTABLECIMIENTO + scope sobre el EE objetivo (V29). Una sola
    --    llamada sustituye al gate compuesto anterior
    --    (fn_puede_afectar_establecimiento -- roles 1-3 -- O "es el rector
    --    activo de ESTE EE" resuelto inline): el caso del rector lo cubre
    --    ahora fn_usuario_ee_accesibles, que ademas incluye a la secretaria
    --    por puntero y a los roles de categoria ESTABLECIMIENTO por
    --    TSEDE_USUARIO. Capability y scope fallan con 42501 y mensajes
    --    distintos.
    -- -----------------------------------------------------------------
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'ESTABLECIMIENTO', 'EDITAR', p_pk_establecimiento
    );

    -- -----------------------------------------------------------------
    -- 1. Validaciones de existencia y estado (activo). De paso
    --    capturamos el rector/secretaria PREVIOS (V70) para poder
    --    sincronizar a quien pierde el rol si el UPDATE lo cambia.
    -- -----------------------------------------------------------------
    SELECT ACTIVE, FK_TFUNCIONARIO_RECTOR, FK_TFUNCIONARIO_SECRETARIA, NOMBRE
      INTO v_estado_actual, v_old_rector, v_old_secretaria, v_nombre_actual
      FROM academico_test.TESTABLECIMIENTO
     WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el establecimiento solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    IF v_estado_actual = FALSE THEN
        RAISE EXCEPTION 'El establecimiento "%" se encuentra inactivo; no se puede actualizar', v_nombre_actual
            USING ERRCODE = '22023',
                  HINT    = 'Use fn_est_buscar_por_nit(..., p_incluir_inactivos=TRUE) para localizar registros dados de baja';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Validaciones de valor para los campos que llegaron.
    --    Solo aquellos que no son NULL se validan: los NULL no cambian nada.
    --    Para VARCHAR obligatorios, '' o solo espacios se considera vacio
    --    y se rechaza con 22023 (mismo criterio que en fn_est_crear).
    -- -----------------------------------------------------------------
    IF p_nombre IS NOT NULL AND NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'Nombre del establecimiento no puede ser vacio si se envia'
            USING ERRCODE = '22023', HINT = 'p_nombre llego como cadena vacia o solo espacios';
    END IF;

    IF p_fk_municipio IS NOT NULL AND p_fk_municipio <= 0 THEN
        RAISE EXCEPTION 'Municipio (FK_TMUNICIPIO) no puede ser <= 0'
            USING ERRCODE = '22023', HINT = 'p_fk_municipio invalido';
    END IF;

    IF p_fk_propiedad_juridica IS NOT NULL AND p_fk_propiedad_juridica <= 0 THEN
        RAISE EXCEPTION 'Propiedad juridica (FK_TPROPIEDAD_JURIDICA) no puede ser <= 0'
            USING ERRCODE = '22023', HINT = 'p_fk_propiedad_juridica invalido';
    END IF;

    -- -----------------------------------------------------------------
    -- 2b. Validaciones de valor para NIT y CODIGO si se enviaron.
    --     Mismo criterio que en fn_est_crear: cadena vacia o solo
    --     espacios se rechaza con 22023.
    -- -----------------------------------------------------------------
    IF p_nit IS NOT NULL AND NULLIF(TRIM(p_nit), '') IS NULL THEN
        RAISE EXCEPTION 'NIT del establecimiento no puede ser vacio si se envia'
            USING ERRCODE = '22023', HINT = 'p_nit llego como cadena vacia o solo espacios';
    END IF;

    IF p_codigo IS NOT NULL AND NULLIF(TRIM(p_codigo), '') IS NULL THEN
        RAISE EXCEPTION 'Codigo del establecimiento no puede ser vacio si se envia'
            USING ERRCODE = '22023', HINT = 'p_codigo llego como cadena vacia o solo espacios';
    END IF;

    -- -----------------------------------------------------------------
    -- 2c. Validacion de unicidad de NIT contra el resto de EE activos.
    --     Se excluye el propio PK para permitir reenviar el mismo NIT
    --     (es un no-op, no debe chocar consigo mismo).
    -- -----------------------------------------------------------------
    IF p_nit IS NOT NULL AND EXISTS (
        SELECT 1 FROM academico_test.TESTABLECIMIENTO
        WHERE NIT = p_nit
          AND ACTIVE = TRUE
          AND PK_ESTABLECIMIENTO <> p_pk_establecimiento
    ) THEN
        RAISE EXCEPTION 'Ya existe otro TESTABLECIMIENTO activo con NIT %', p_nit
            USING ERRCODE = '23505',
                  HINT    = 'Use fn_est_buscar_por_nit('') para localizar el registro que ya lo usa';
    END IF;

    -- Misma logica para CODIGO: la UNIQUE constraint U_TESTABLECIMIENTO_1
    -- cubre TODOS los CODIGO (activos e inactivos), por lo que esta
    -- validacion explicita es solo entre activos (mismo criterio que
    -- en fn_est_crear: CODIGO inactivo puede reutilizarse).
    IF p_codigo IS NOT NULL AND EXISTS (
        SELECT 1 FROM academico_test.TESTABLECIMIENTO
        WHERE CODIGO = p_codigo
          AND ACTIVE = TRUE
          AND PK_ESTABLECIMIENTO <> p_pk_establecimiento
    ) THEN
        RAISE EXCEPTION 'Ya existe otro TESTABLECIMIENTO activo con CODIGO %', p_codigo
            USING ERRCODE = '23505',
                  HINT    = 'Use una consulta directa sobre TESTABLECIMIENTO para localizar el registro que ya lo usa';
    END IF;

    -- -----------------------------------------------------------------
    -- 2d. Validacion de FKs (solo si llegaron con valor no NULL).
    --     Se hace ANTES del UPDATE para evitar cambios parciales: si
    --     una FK nueva no existe, la operacion falla sin escribir
    --     nada y con mensaje claro.
    -- -----------------------------------------------------------------
    IF p_fk_municipio IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TMUNICIPIO
             WHERE PK_TMUNICIPIO = p_fk_municipio
          )
    THEN
        RAISE EXCEPTION 'FK_TMUNICIPIO (%) no existe en TMUNICIPIO', p_fk_municipio
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_propiedad_juridica IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TPROPIEDAD_JURIDICA
             WHERE PK_PROPIEDAD_JURIDICA = p_fk_propiedad_juridica
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TPROPIEDAD_JURIDICA (%) no existe o no esta activa en TPROPIEDAD_JURIDICA',
            p_fk_propiedad_juridica
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_lista_valor_zona IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lista_valor_zona
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLISTA_VALOR_ZONA (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lista_valor_zona
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_lv_calendario IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lv_calendario
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLV_CALENDARIO (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lv_calendario
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_lv_idioma IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lv_idioma
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLV_IDIOMA (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lv_idioma
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_lv_genero_est IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lv_genero_est
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLV_GENERO_EST (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lv_genero_est
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_discapacidad IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TDISCAPACIDAD
             WHERE PK_DISCAPACIDAD = p_fk_discapacidad
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TDISCAPACIDAD (%) no existe o no esta activa en TDISCAPACIDAD',
            p_fk_discapacidad
            USING ERRCODE = '23503';
    END IF;

    IF p_FK_TFUNCIONARIO_RECTOR IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TFUNCIONARIO
             WHERE PK_TFUNCIONARIO = p_FK_TFUNCIONARIO_RECTOR
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TFUNCIONARIO_RECTOR (%) no existe o no esta activo en TFUNCIONARIO',
            p_FK_TFUNCIONARIO_RECTOR
            USING ERRCODE = '23503';
    END IF;

    IF p_FK_TFUNCIONARIO_SECRETARIA IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TFUNCIONARIO
             WHERE PK_TFUNCIONARIO = p_FK_TFUNCIONARIO_SECRETARIA
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TFUNCIONARIO_SECRETARIA (%) no existe o no esta activo en TFUNCIONARIO',
            p_FK_TFUNCIONARIO_SECRETARIA
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_lv_regimen_catcosto IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lv_regimen_catcosto
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLV_REGIMEN_CATCOSTO (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lv_regimen_catcosto
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_lv_rango_tarifa IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lv_rango_tarifa
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLV_RANGO_TARIFA (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lv_rango_tarifa
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_lv_asociacion_nacional IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lv_asociacion_nacional
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLV_ASOCIACION_NACIONAL (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lv_asociacion_nacional
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_lv_estado_establecimiento IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lv_estado_establecimiento
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLV_ESTADO_ESTABLECIMIENTO (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lv_estado_establecimiento
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_archivo IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TARCHIVO
             WHERE PK_TARCHIVO = p_fk_archivo
          )
    THEN
        RAISE EXCEPTION 'FK_TARCHIVO (%) no existe en TARCHIVO', p_fk_archivo
            USING ERRCODE = '23503';
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
    WITH current_row AS (
        SELECT CODIGO, NIT, NOMBRE,
               FK_TMUNICIPIO, FK_TLISTA_VALOR_ZONA,
               LOCALIDAD, COMUNA, BARRIO, DIRECCION,
               CORREO_ELECTRONICO, TELEFONO, FAX, IDECOL, PAGINA_WEB,
               FK_TPROPIEDAD_JURIDICA,
               RESOLUCION_APROBACION, LICENCIA_FUNCIONAMIENTO, FECHA_LICENCIA,
               FK_TLV_CALENDARIO, FK_TLV_IDIOMA, FK_TLV_GENERO_EST,
               FK_TDISCAPACIDAD, TALENTO, ETNIAS,
               FK_TFUNCIONARIO_RECTOR, FK_TFUNCIONARIO_SECRETARIA, SUBSIDIO,
               FK_TLV_REGIMEN_CATCOSTO, FK_TLV_RANGO_TARIFA,
               FK_TLV_ASOCIACION_NACIONAL, FK_TLV_ESTADO_ESTABLECIMIENTO,
               FK_TARCHIVO
          FROM academico_test.TESTABLECIMIENTO
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento
    ),
    cambios AS (
        SELECT
            (p_nit                     IS NOT NULL AND p_nit                     IS DISTINCT FROM current_row.NIT)                       AS chg_nit,
            (p_codigo                  IS NOT NULL AND p_codigo                  IS DISTINCT FROM current_row.CODIGO)                    AS chg_codigo,
            (p_nombre                  IS NOT NULL AND p_nombre                  IS DISTINCT FROM current_row.NOMBRE)                    AS chg_nombre,
            (p_fk_municipio            IS NOT NULL AND p_fk_municipio            IS DISTINCT FROM current_row.FK_TMUNICIPIO)             AS chg_municipio,
            (p_fk_lista_valor_zona     IS NOT NULL AND p_fk_lista_valor_zona     IS DISTINCT FROM current_row.FK_TLISTA_VALOR_ZONA)      AS chg_zona,
            (p_localidad               IS NOT NULL AND p_localidad               IS DISTINCT FROM current_row.LOCALIDAD)                 AS chg_localidad,
            (p_comuna                  IS NOT NULL AND p_comuna                  IS DISTINCT FROM current_row.COMUNA)                    AS chg_comuna,
            (p_barrio                  IS NOT NULL AND p_barrio                  IS DISTINCT FROM current_row.BARRIO)                    AS chg_barrio,
            (p_direccion               IS NOT NULL AND p_direccion               IS DISTINCT FROM current_row.DIRECCION)                 AS chg_direccion,
            (p_correo_electronico      IS NOT NULL AND p_correo_electronico      IS DISTINCT FROM current_row.CORREO_ELECTRONICO)        AS chg_correo,
            (p_telefono                IS NOT NULL AND p_telefono                IS DISTINCT FROM current_row.TELEFONO)                  AS chg_telefono,
            (p_fax                     IS NOT NULL AND p_fax                     IS DISTINCT FROM current_row.FAX)                       AS chg_fax,
            (p_idecol                  IS NOT NULL AND p_idecol                  IS DISTINCT FROM current_row.IDECOL)                    AS chg_idecol,
            (p_pagina_web              IS NOT NULL AND p_pagina_web              IS DISTINCT FROM current_row.PAGINA_WEB)                AS chg_pagina_web,
            (p_fk_propiedad_juridica   IS NOT NULL AND p_fk_propiedad_juridica   IS DISTINCT FROM current_row.FK_TPROPIEDAD_JURIDICA)    AS chg_propiedad,
            (p_resolucion_aprobacion   IS NOT NULL AND p_resolucion_aprobacion   IS DISTINCT FROM current_row.RESOLUCION_APROBACION)     AS chg_resolucion,
            (p_licencia_funcionamiento IS NOT NULL AND p_licencia_funcionamiento IS DISTINCT FROM current_row.LICENCIA_FUNCIONAMIENTO)   AS chg_licencia,
            (p_fecha_licencia          IS NOT NULL AND p_fecha_licencia          IS DISTINCT FROM current_row.FECHA_LICENCIA)            AS chg_fecha_licencia,
            (p_fk_lv_calendario        IS NOT NULL AND p_fk_lv_calendario        IS DISTINCT FROM current_row.FK_TLV_CALENDARIO)         AS chg_calendario,
            (p_fk_lv_idioma            IS NOT NULL AND p_fk_lv_idioma            IS DISTINCT FROM current_row.FK_TLV_IDIOMA)             AS chg_idioma,
            (p_fk_lv_genero_est        IS NOT NULL AND p_fk_lv_genero_est        IS DISTINCT FROM current_row.FK_TLV_GENERO_EST)         AS chg_genero_est,
            (p_fk_discapacidad         IS NOT NULL AND p_fk_discapacidad         IS DISTINCT FROM current_row.FK_TDISCAPACIDAD)          AS chg_discapacidad,
            (p_talento                 IS NOT NULL AND p_talento                 IS DISTINCT FROM current_row.TALENTO)                   AS chg_talento,
            (p_etnias                  IS NOT NULL AND p_etnias                  IS DISTINCT FROM current_row.ETNIAS)                    AS chg_etnias,
            (p_FK_TFUNCIONARIO_RECTOR   IS NOT NULL AND p_FK_TFUNCIONARIO_RECTOR   IS DISTINCT FROM current_row.FK_TFUNCIONARIO_RECTOR)     AS chg_rector,
            (p_FK_TFUNCIONARIO_SECRETARIA IS NOT NULL AND p_FK_TFUNCIONARIO_SECRETARIA IS DISTINCT FROM current_row.FK_TFUNCIONARIO_SECRETARIA) AS chg_secretaria,
            (p_subsidio                IS NOT NULL AND p_subsidio                IS DISTINCT FROM current_row.SUBSIDIO)                  AS chg_subsidio,
            (p_fk_lv_regimen_catcosto  IS NOT NULL AND p_fk_lv_regimen_catcosto  IS DISTINCT FROM current_row.FK_TLV_REGIMEN_CATCOSTO)   AS chg_regimen,
            (p_fk_lv_rango_tarifa      IS NOT NULL AND p_fk_lv_rango_tarifa      IS DISTINCT FROM current_row.FK_TLV_RANGO_TARIFA)       AS chg_rango,
            (p_fk_lv_asociacion_nacional IS NOT NULL AND p_fk_lv_asociacion_nacional IS DISTINCT FROM current_row.FK_TLV_ASOCIACION_NACIONAL) AS chg_asociacion,
            (p_fk_lv_estado_establecimiento IS NOT NULL AND p_fk_lv_estado_establecimiento IS DISTINCT FROM current_row.FK_TLV_ESTADO_ESTABLECIMIENTO) AS chg_estado_est,
            (p_fk_archivo              IS NOT NULL AND p_fk_archivo              IS DISTINCT FROM current_row.FK_TARCHIVO)               AS chg_archivo
        FROM current_row
    )
    UPDATE academico_test.TESTABLECIMIENTO t
       SET NIT                            = COALESCE(p_nit,                          t.NIT),
           CODIGO                         = COALESCE(p_codigo,                       t.CODIGO),
           NOMBRE                         = COALESCE(p_nombre,                       t.NOMBRE),
           FK_TMUNICIPIO                  = COALESCE(p_fk_municipio,                 t.FK_TMUNICIPIO),
           FK_TLISTA_VALOR_ZONA           = COALESCE(p_fk_lista_valor_zona,          t.FK_TLISTA_VALOR_ZONA),
           LOCALIDAD                      = COALESCE(p_localidad,                    t.LOCALIDAD),
           COMUNA                         = COALESCE(p_comuna,                       t.COMUNA),
           BARRIO                         = COALESCE(p_barrio,                       t.BARRIO),
           DIRECCION                      = COALESCE(p_direccion,                    t.DIRECCION),
           CORREO_ELECTRONICO             = COALESCE(p_correo_electronico,           t.CORREO_ELECTRONICO),
           TELEFONO                       = COALESCE(p_telefono,                     t.TELEFONO),
           FAX                            = COALESCE(p_fax,                          t.FAX),
           IDECOL                         = COALESCE(p_idecol,                       t.IDECOL),
           PAGINA_WEB                     = COALESCE(p_pagina_web,                   t.PAGINA_WEB),
           FK_TPROPIEDAD_JURIDICA         = COALESCE(p_fk_propiedad_juridica,        t.FK_TPROPIEDAD_JURIDICA),
           RESOLUCION_APROBACION          = COALESCE(p_resolucion_aprobacion,        t.RESOLUCION_APROBACION),
           LICENCIA_FUNCIONAMIENTO        = COALESCE(p_licencia_funcionamiento,      t.LICENCIA_FUNCIONAMIENTO),
           FECHA_LICENCIA                 = COALESCE(p_fecha_licencia,               t.FECHA_LICENCIA),
           FK_TLV_CALENDARIO              = COALESCE(p_fk_lv_calendario,             t.FK_TLV_CALENDARIO),
           FK_TLV_IDIOMA                  = COALESCE(p_fk_lv_idioma,                 t.FK_TLV_IDIOMA),
           FK_TLV_GENERO_EST              = COALESCE(p_fk_lv_genero_est,             t.FK_TLV_GENERO_EST),
           FK_TDISCAPACIDAD               = COALESCE(p_fk_discapacidad,              t.FK_TDISCAPACIDAD),
           TALENTO                        = COALESCE(p_talento,                      t.TALENTO),
           ETNIAS                         = COALESCE(p_etnias,                       t.ETNIAS),
           FK_TFUNCIONARIO_RECTOR         = COALESCE(p_FK_TFUNCIONARIO_RECTOR,        t.FK_TFUNCIONARIO_RECTOR),
           FK_TFUNCIONARIO_SECRETARIA     = COALESCE(p_FK_TFUNCIONARIO_SECRETARIA,    t.FK_TFUNCIONARIO_SECRETARIA),
           SUBSIDIO                       = COALESCE(p_subsidio,                     t.SUBSIDIO),
           FK_TLV_REGIMEN_CATCOSTO        = COALESCE(p_fk_lv_regimen_catcosto,       t.FK_TLV_REGIMEN_CATCOSTO),
           FK_TLV_RANGO_TARIFA            = COALESCE(p_fk_lv_rango_tarifa,           t.FK_TLV_RANGO_TARIFA),
           FK_TLV_ASOCIACION_NACIONAL     = COALESCE(p_fk_lv_asociacion_nacional,    t.FK_TLV_ASOCIACION_NACIONAL),
           FK_TLV_ESTADO_ESTABLECIMIENTO  = COALESCE(p_fk_lv_estado_establecimiento, t.FK_TLV_ESTADO_ESTABLECIMIENTO),
           FK_TARCHIVO                    = COALESCE(p_fk_archivo,                   t.FK_TARCHIVO),
           MODIFIED_BY = CASE
                            WHEN (SELECT c.chg_nit OR c.chg_codigo OR c.chg_nombre OR c.chg_municipio
                                       OR c.chg_zona OR c.chg_localidad OR c.chg_comuna OR c.chg_barrio
                                       OR c.chg_direccion OR c.chg_correo OR c.chg_telefono OR c.chg_fax
                                       OR c.chg_idecol OR c.chg_pagina_web OR c.chg_propiedad
                                       OR c.chg_resolucion OR c.chg_licencia OR c.chg_fecha_licencia
                                       OR c.chg_calendario OR c.chg_idioma OR c.chg_genero_est
                                       OR c.chg_discapacidad OR c.chg_talento OR c.chg_etnias
                                       OR c.chg_rector OR c.chg_secretaria OR c.chg_subsidio
                                       OR c.chg_regimen OR c.chg_rango OR c.chg_asociacion
                                       OR c.chg_estado_est OR c.chg_archivo
                                  FROM cambios c)
                            THEN p_pk_usuario_solicitante::VARCHAR
                            ELSE t.MODIFIED_BY
                          END,
           MODIFIED_AT = CASE
                            WHEN (SELECT c.chg_nit OR c.chg_codigo OR c.chg_nombre OR c.chg_municipio
                                       OR c.chg_zona OR c.chg_localidad OR c.chg_comuna OR c.chg_barrio
                                       OR c.chg_direccion OR c.chg_correo OR c.chg_telefono OR c.chg_fax
                                       OR c.chg_idecol OR c.chg_pagina_web OR c.chg_propiedad
                                       OR c.chg_resolucion OR c.chg_licencia OR c.chg_fecha_licencia
                                       OR c.chg_calendario OR c.chg_idioma OR c.chg_genero_est
                                       OR c.chg_discapacidad OR c.chg_talento OR c.chg_etnias
                                       OR c.chg_rector OR c.chg_secretaria OR c.chg_subsidio
                                       OR c.chg_regimen OR c.chg_rango OR c.chg_asociacion
                                       OR c.chg_estado_est OR c.chg_archivo
                                  FROM cambios c)
                            THEN CURRENT_TIMESTAMP
                            ELSE t.MODIFIED_AT
                          END
      FROM cambios c
     WHERE t.PK_ESTABLECIMIENTO = p_pk_establecimiento
       AND t.ACTIVE             = TRUE;

    -- -----------------------------------------------------------------
    -- 3b. V70 — si el rector/secretaria cambio, sincroniza tanto al que
    --     gana el rol como al que lo pierde (si habia alguien antes).
    --     p_FK_TFUNCIONARIO_* NULL significa "no tocar este campo" (ver
    --     COALESCE arriba), asi que solo sincronizamos cuando el
    --     parametro llego Y es distinto al valor previo.
    -- -----------------------------------------------------------------
    IF p_FK_TFUNCIONARIO_RECTOR IS NOT NULL AND p_FK_TFUNCIONARIO_RECTOR IS DISTINCT FROM v_old_rector THEN
        PERFORM academico_test.fn_sincronizar_rol_publico(
            (SELECT FK_TUSUARIO FROM academico_test.TFUNCIONARIO
              WHERE PK_TFUNCIONARIO = p_FK_TFUNCIONARIO_RECTOR)
        );
        IF v_old_rector IS NOT NULL THEN
            PERFORM academico_test.fn_sincronizar_rol_publico(
                (SELECT FK_TUSUARIO FROM academico_test.TFUNCIONARIO
                  WHERE PK_TFUNCIONARIO = v_old_rector)
            );
        END IF;
    END IF;

    IF p_FK_TFUNCIONARIO_SECRETARIA IS NOT NULL AND p_FK_TFUNCIONARIO_SECRETARIA IS DISTINCT FROM v_old_secretaria THEN
        PERFORM academico_test.fn_sincronizar_rol_publico(
            (SELECT FK_TUSUARIO FROM academico_test.TFUNCIONARIO
              WHERE PK_TFUNCIONARIO = p_FK_TFUNCIONARIO_SECRETARIA)
        );
        IF v_old_secretaria IS NOT NULL THEN
            PERFORM academico_test.fn_sincronizar_rol_publico(
                (SELECT FK_TUSUARIO FROM academico_test.TFUNCIONARIO
                  WHERE PK_TFUNCIONARIO = v_old_secretaria)
            );
        END IF;
    END IF;

    -- -----------------------------------------------------------------
    -- 3c/3d. REV6 -- si el rector/secretaria cambio a alguien NUEVO (no
    --     nulo, distinto del anterior), se sincroniza su permiso en TODAS
    --     las sedes ACTIVAS del EE (antes solo en la "sede por defecto"
    --     que coincide en NOMBRE+CODIGO -- REV4/REV5). Mismo criterio que
    --     fn_sed_crear al crear una sede nueva: el invariante es "rector/
    --     secretaria tiene permiso en TODAS las sedes de su EE", asi que
    --     al reasignar el puesto hay que sincronizar cada sede existente,
    --     no solo una. Por cada sede: se crea el permiso del ENTRANTE (si
    --     no lo tenia ya ahi -- guarda anti-duplicados) y se revoca el del
    --     SALIENTE (si lo tenia). predeterminado=0 siempre -- con
    --     potencialmente varias sedes de por medio, ninguna se marca como
    --     la jornada/sede por defecto automaticamente.
    -- -----------------------------------------------------------------
    FOR v_pk_sede_loop IN
        SELECT PK_TSEDE FROM academico_test.TSEDE
         WHERE FK_TESTABLECIMIENTO = p_pk_establecimiento AND ACTIVE = TRUE
    LOOP
        IF p_FK_TFUNCIONARIO_RECTOR IS NOT NULL
           AND p_FK_TFUNCIONARIO_RECTOR IS DISTINCT FROM v_old_rector
           AND NOT EXISTS (
                SELECT 1
                  FROM academico_test.TSEDE_USUARIO su
                  JOIN academico_test.TFUNCIONARIO f ON f.FK_TUSUARIO = su.FK_TUSUARIO
                 WHERE f.PK_TFUNCIONARIO = p_FK_TFUNCIONARIO_RECTOR
                   AND su.FK_TSEDE = v_pk_sede_loop
                   AND su.FK_TROL  = c_fk_trol_rector
                   AND su.ACTIVE   = TRUE
           )
        THEN
            SELECT * INTO v_perm_result
              FROM academico_test.fn_fun_permisos_actualizar(
                  p_pk_usuario_solicitante,
                  p_FK_TFUNCIONARIO_RECTOR,
                  jsonb_build_array(jsonb_build_object(
                      'accion', 'crear',
                      'orden', 1,
                      'fk_rol', c_fk_trol_rector,
                      'fk_sede', v_pk_sede_loop,
                      'fk_jornada', c_fk_tlv_jornada_defecto,
                      'predeterminado', 0
                  ))
              );
            IF v_perm_result.status IS DISTINCT FROM 'creado' THEN
                RAISE EXCEPTION 'No se pudo crear el permiso del nuevo rector (TFUNCIONARIO %) en la sede %: %',
                    p_FK_TFUNCIONARIO_RECTOR, v_pk_sede_loop, v_perm_result.status;
            END IF;
        END IF;

        IF p_FK_TFUNCIONARIO_SECRETARIA IS NOT NULL
           AND p_FK_TFUNCIONARIO_SECRETARIA IS DISTINCT FROM v_old_secretaria
           AND NOT EXISTS (
                SELECT 1
                  FROM academico_test.TSEDE_USUARIO su
                  JOIN academico_test.TFUNCIONARIO f ON f.FK_TUSUARIO = su.FK_TUSUARIO
                 WHERE f.PK_TFUNCIONARIO = p_FK_TFUNCIONARIO_SECRETARIA
                   AND su.FK_TSEDE = v_pk_sede_loop
                   AND su.FK_TROL  = c_fk_trol_secretaria
                   AND su.ACTIVE   = TRUE
           )
        THEN
            SELECT * INTO v_perm_result
              FROM academico_test.fn_fun_permisos_actualizar(
                  p_pk_usuario_solicitante,
                  p_FK_TFUNCIONARIO_SECRETARIA,
                  jsonb_build_array(jsonb_build_object(
                      'accion', 'crear',
                      'orden', 1,
                      'fk_rol', c_fk_trol_secretaria,
                      'fk_sede', v_pk_sede_loop,
                      'fk_jornada', c_fk_tlv_jornada_defecto,
                      'predeterminado', 0
                  ))
              );
            IF v_perm_result.status IS DISTINCT FROM 'creado' THEN
                RAISE EXCEPTION 'No se pudo crear el permiso de la nueva secretaria (TFUNCIONARIO %) en la sede %: %',
                    p_FK_TFUNCIONARIO_SECRETARIA, v_pk_sede_loop, v_perm_result.status;
            END IF;
        END IF;

        IF p_FK_TFUNCIONARIO_RECTOR IS NOT NULL
           AND p_FK_TFUNCIONARIO_RECTOR IS DISTINCT FROM v_old_rector
           AND v_old_rector IS NOT NULL
        THEN
            SELECT su.PK_TSEDE_USUARIO INTO v_pk_permiso_a_quitar
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TFUNCIONARIO f ON f.FK_TUSUARIO = su.FK_TUSUARIO
             WHERE f.PK_TFUNCIONARIO = v_old_rector
               AND su.FK_TSEDE = v_pk_sede_loop
               AND su.FK_TROL  = c_fk_trol_rector
               AND su.ACTIVE   = TRUE
             LIMIT 1;

            IF v_pk_permiso_a_quitar IS NOT NULL THEN
                PERFORM academico_test.fn_sede_usuario_soft_delete(v_pk_permiso_a_quitar, p_pk_usuario_solicitante);
            END IF;
        END IF;

        IF p_FK_TFUNCIONARIO_SECRETARIA IS NOT NULL
           AND p_FK_TFUNCIONARIO_SECRETARIA IS DISTINCT FROM v_old_secretaria
           AND v_old_secretaria IS NOT NULL
        THEN
            SELECT su.PK_TSEDE_USUARIO INTO v_pk_permiso_a_quitar
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TFUNCIONARIO f ON f.FK_TUSUARIO = su.FK_TUSUARIO
             WHERE f.PK_TFUNCIONARIO = v_old_secretaria
               AND su.FK_TSEDE = v_pk_sede_loop
               AND su.FK_TROL  = c_fk_trol_secretaria
               AND su.ACTIVE   = TRUE
             LIMIT 1;

            IF v_pk_permiso_a_quitar IS NOT NULL THEN
                PERFORM academico_test.fn_sede_usuario_soft_delete(v_pk_permiso_a_quitar, p_pk_usuario_solicitante);
            END IF;
        END IF;
    END LOOP;

    -- -----------------------------------------------------------------
    -- 4. Reporte y retorno.
    -- -----------------------------------------------------------------
    RAISE NOTICE 'fn_est_actualizar: TESTABLECIMIENTO=% procesado por usuario=%', p_pk_establecimiento, p_pk_usuario_solicitante;

    RETURN p_pk_establecimiento;
END;
$function$
;

-- ---------------------------------------------------------------------------
-- COMMENT ON FUNCTION de las 4 funciones redefinidas arriba, documentando el
-- gate nuevo (CU-86e2w4xdt). Se aplican por OID en vez de escribir a mano las
-- listas de tipos (fn_est_crear/fn_est_actualizar tienen 33 y 35 parametros;
-- copiarlas seria una fuente de errores y habria que tocarlas cada vez que
-- cambie una firma). El nombre es unico dentro del esquema, asi que el LOOP
-- comenta como mucho una funcion por nombre. Idempotente: reasignar el mismo
-- comentario es un no-op.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_sig  TEXT;
    r      RECORD;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            ('fn_sede_usuario_crear',
             'Crea una fila TSEDE_USUARIO (rol de un funcionario en una sede/jornada) y sincroniza public.role_users via fn_sincronizar_rol_publico para que el rol llegue al JWT sin esperar al siguiente login. GATE (CU-86e2w4xdt, helpers de V29): (1) PERFORM fn_assert_permiso_seccion(solicitante, ''FUNCIONARIOS'', ''EDITAR'', NULL, p_fk_sede, p_fk_tlv_jornada) -- bypass del SUPER_ADMIN, capability configurable por TROL_MENU/TUSUARIO_ROL_PERMISO y scope sobre la sede objetivo (todos los EE para el nivel territorial, fn_usuario_ee_accesibles para el nivel establecimiento, el par (sede, jornada) para el nivel sedes); (2) PERFORM fn_assert_rango_rol_otorgable(solicitante, p_fk_rol) tras validar el rol -- nadie otorga un rol de categoria igual o superior a la propia (p.ej. un Rector puede otorgar Coordinador, pero no Rector ni un rol territorial). Sustituye al gate anterior por lista fija (fn_puede_afectar_usuarios O rol 11 de la sede limitado a roles 9-14). El resto del cuerpo (obligatorios 23502, FKs 23503, unicidad 23505) no cambia.'),
            ('fn_sede_usuario_soft_delete',
             'Baja logica (ACTIVE=FALSE) de una fila TSEDE_USUARIO y resincronizacion de public.role_users via fn_sincronizar_rol_publico (full-resync: si al usuario le queda otra sede con el mismo rol, conserva el CEVAL-<codigo>). Idempotente: si la fila ya estaba inactiva devuelve el PK sin error. GATE (CU-86e2w4xdt): PERFORM fn_assert_permiso_seccion(solicitante, ''FUNCIONARIOS'', ''EDITAR'', NULL, FK_TSEDE, FK_TLV_JORNADA de la fila objetivo, leidas antes de darla de baja) -- capability por menu + scope por sede/jornada de V29, en lugar del gate anterior por lista fija de FK_TROL. La existencia se valida ANTES del gate (P0002) porque el gate necesita la sede/jornada de la fila.'),
            ('fn_est_crear',
             'Crea un TESTABLECIMIENTO (mas su sede por defecto y los permisos de rector/secretaria en ella) y sincroniza public.role_users de rector y secretaria. GATE (CU-86e2w4xdt): PERFORM fn_assert_permiso_seccion(solicitante, ''ESTABLECIMIENTO'', ''CREAR'') -- SIN objeto: crear un EE no tiene un EE previo sobre el que evaluar scope, asi que basta la capability del menu ESTABLECIMIENTO (configurable por el super admin via TROL_MENU/TUSUARIO_ROL_PERMISO), con bypass para el SUPER_ADMIN. Reemplaza a fn_puede_afectar_establecimiento (lista fija de roles 1-3). Se conserva la validacion 22023 de p_pk_usuario_solicitante obligatorio y > 0, que corre antes del gate.'),
            ('fn_est_actualizar',
             'Actualizacion parcial (PATCH) de un TESTABLECIMIENTO activo, incluyendo el mantenimiento de los permisos por defecto de rector/secretaria en las sedes del EE y la sincronizacion de public.role_users de quien gana y de quien pierde el cargo. GATE (CU-86e2w4xdt): PERFORM fn_assert_permiso_seccion(solicitante, ''ESTABLECIMIENTO'', ''EDITAR'', p_pk_establecimiento) -- una sola llamada que sustituye al gate compuesto anterior (fn_puede_afectar_establecimiento, roles 1-3, O "es el rector activo de ESTE EE" resuelto inline): el caso del rector queda cubierto por fn_usuario_ee_accesibles (V29), que ademas incluye a la secretaria por puntero y a los roles de categoria ADMINISTRATIVOS_ESTABLECIMIENTO por TSEDE_USUARIO. Capability y scope lanzan 42501 con mensajes distintos. El resto del cuerpo (P0002 si no existe, 22023 si esta inactivo, validaciones de valor y unicidad) no cambia.')
        ) AS t(proname, descripcion)
    LOOP
        SELECT p.oid::REGPROCEDURE::TEXT
          INTO v_sig
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'academico_test'
           AND p.proname = r.proname
         LIMIT 1;

        IF v_sig IS NOT NULL THEN
            EXECUTE format('COMMENT ON FUNCTION %s IS %L', v_sig, r.descripcion);
        END IF;
    END LOOP;
END;
$$;


-- Backfill: todo TUSUARIO con una TSEDE_USUARIO activa hoy, o que sea
-- rector/secretaria de un EE activo hoy, queda sincronizado sin
-- esperar a que alguien vuelva a tocar esos datos.
DO $$
DECLARE
    v_pk_tusuario BIGINT;
BEGIN
    FOR v_pk_tusuario IN
        SELECT DISTINCT FK_TUSUARIO
          FROM academico_test.TSEDE_USUARIO
         WHERE ACTIVE = TRUE
        UNION
        SELECT DISTINCT f.FK_TUSUARIO
          FROM academico_test.TESTABLECIMIENTO e
          JOIN academico_test.TFUNCIONARIO f
            ON f.PK_TFUNCIONARIO IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA)
         WHERE e.ACTIVE = TRUE
           AND f.ACTIVE = TRUE
    LOOP
        PERFORM academico_test.fn_sincronizar_rol_publico(v_pk_tusuario);
    END LOOP;
END;
$$;
