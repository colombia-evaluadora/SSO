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
    -- 0. Gate de autorizacion: solo roles con permiso de usuarios.
    -- ---------------------------------------------------------------------
    IF NOT academico_test.fn_puede_afectar_usuarios(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

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
        RAISE EXCEPTION 'TSEDE (%) no existe o no esta activa', p_fk_sede
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
BEGIN
    -- ---------------------------------------------------------------------
    -- 0. Gate de autorizacion.
    -- ---------------------------------------------------------------------
    IF NOT academico_test.fn_puede_afectar_usuarios(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- ---------------------------------------------------------------------
    -- 1. Validacion de existencia. (Idempotente: si ya esta inactivo,
    --    retornamos el PK sin error.)
    -- ---------------------------------------------------------------------
    SELECT ACTIVE, FK_TUSUARIO
      INTO v_active, v_pk_tusuario
      FROM academico_test.TSEDE_USUARIO
     WHERE PK_TSEDE_USUARIO = p_pk_sede_usuario;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'no existe TSEDE_USUARIO con PK %', p_pk_sede_usuario
            USING ERRCODE = 'P0002';
    END IF;

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
BEGIN
    -- -----------------------------------------------------------------
    -- 0. Gate de autorizacion: solo roles con permiso de establecimiento (1-3).
    --    p_pk_usuario_solicitante es obligatorio por firma (sin DEFAULT).
    -- -----------------------------------------------------------------
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

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

    -- V111 — refleja al rector/secretaria recien asignado en
    -- public.role_users. Van por FK_TUSUARIO del TFUNCIONARIO, no por
    -- el PK del establecimiento.
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
    v_fk_rector     BIGINT;
    v_es_rector     BOOLEAN := FALSE;
    -- V111 — rector/secretaria PREVIOS, capturados antes del UPDATE para
    -- poder sincronizar tambien a quien pierde el rol si cambia.
    v_old_rector      BIGINT;
    v_old_secretaria  BIGINT;
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
    -- 1. Gate de autorizacion compuesto:
    --    (a) super-admin (rol 1-3) => puede modificar cualquier EE, o
    --    (b) el usuario es el rector activo del EE que se quiere modificar
    --        (TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR -> TFUNCIONARIO activo
    --         cuyo FK_TUSUARIO coincide con p_pk_usuario_solicitante).
    --    Cualquier otro caso => 42501.
    -- -----------------------------------------------------------------
    IF NOT academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante) THEN
        -- No es super-admin: probamos si es rector del EE objetivo.
        SELECT e.FK_TFUNCIONARIO_RECTOR
          INTO v_fk_rector
          FROM academico_test.TESTABLECIMIENTO e
         WHERE e.PK_ESTABLECIMIENTO = p_pk_establecimiento
           AND e.ACTIVE             = TRUE;

        IF v_fk_rector IS NOT NULL THEN
            SELECT EXISTS (
                SELECT 1
                  FROM academico_test.TFUNCIONARIO f
                 WHERE f.PK_TFUNCIONARIO = v_fk_rector
                   AND f.FK_TUSUARIO     = p_pk_usuario_solicitante
                   AND f.ACTIVE          = TRUE
            ) INTO v_es_rector;
        END IF;

        IF NOT v_es_rector THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    -- -----------------------------------------------------------------
    -- 1. Validaciones de existencia y estado (activo). De paso
    --    capturamos el rector/secretaria PREVIOS (V111) para poder
    --    sincronizar a quien pierde el rol si el UPDATE lo cambia.
    -- -----------------------------------------------------------------
    SELECT ACTIVE, FK_TFUNCIONARIO_RECTOR, FK_TFUNCIONARIO_SECRETARIA
      INTO v_estado_actual, v_old_rector, v_old_secretaria
      FROM academico_test.TESTABLECIMIENTO
     WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe TESTABLECIMIENTO con PK_ESTABLECIMIENTO = %', p_pk_establecimiento
            USING ERRCODE = 'P0002';
    END IF;

    IF v_estado_actual = FALSE THEN
        RAISE EXCEPTION 'TESTABLECIMIENTO % se encuentra inactivo; no se puede actualizar', p_pk_establecimiento
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
    -- 3b. V111 — si el rector/secretaria cambio, sincroniza tanto al que
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
    -- 4. Reporte y retorno.
    -- -----------------------------------------------------------------
    RAISE NOTICE 'fn_est_actualizar: TESTABLECIMIENTO=% procesado por usuario=%', p_pk_establecimiento, p_pk_usuario_solicitante;

    RETURN p_pk_establecimiento;
END;
$function$
;

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
