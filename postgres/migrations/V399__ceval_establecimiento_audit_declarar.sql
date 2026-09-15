-- ============================================================================
-- V399 — cierra otro hueco que V362 dejo documentado como "arranque de
-- cobertura, no el 100%": academico_test.fn_est_crear y fn_est_actualizar
-- (CEVAL) nunca llamaban a fn_audit_declarar, asi que las escrituras sobre
-- el establecimiento en si (crear uno nuevo, editar sus datos) NO quedaban
-- con contexto.establecimiento en auditoria.audit_log -- un CEVAL-RECTOR
-- jamas veia esas operaciones en su propia auditoria filtrada (V362/V398),
-- aunque fueran sobre SU institucion.
--
-- Encontrado en vivo probando el filtro de V398 de punta a punta: se creo
-- un establecimiento de prueba con fn_est_crear real, se actualizo un
-- campo con fn_est_actualizar real (autenticado como el rector de esa
-- institucion), y la fila de auditoria replicada a ClickHouse no tenia
-- "establecimiento" en su contexto -- confirmado consultando
-- auditoria.audit_log directo.
--
-- Mismo patron que V362 ya establecio para pigse.fn_est_crear/
-- fn_est_actualizar: una sola linea nueva por funcion (la llamada a
-- fn_audit_declarar), sin tocar firma ni logica de negocio. CREATE OR
-- REPLACE completo porque no hay forma de "insertar una linea" en una
-- funcion ya definida -- el resto del cuerpo es identico al que ya corria
-- en el servidor, solo se sumaron los comentarios V399 y la llamada.
-- ============================================================================

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

    -- V399: contexto de auditoria para las escrituras que siguen (crear la
    -- sede por defecto, asignar rector/secretaria) -- la fila de creacion
    -- del establecimiento en si misma no queda contextualizada porque
    -- v_id_creado no existia todavia cuando se inserto (mismo limite que
    -- V362 acepto para pigse.fn_est_crear).
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Creacion del establecimiento %s', p_nombre), v_id_creado);

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

    -- V399: declara el contexto de auditoria (quien + a que EE aplica)
    -- ANTES del UPDATE que sigue, para que trg_audit_ctx lo vea. Mismo
    -- patron que V362 uso para pigse.fn_est_actualizar.
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualizacion del establecimiento %s', COALESCE(p_nombre, v_nombre_actual)), p_pk_establecimiento);
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

DO $$
DECLARE
    v_crear_ok BOOLEAN;
    v_actualizar_ok BOOLEAN;
BEGIN
    SELECT prosrc ILIKE '%fn_audit_declarar%' INTO v_crear_ok
      FROM pg_proc WHERE proname = 'fn_est_crear' AND pronamespace = 'academico_test'::regnamespace;
    SELECT prosrc ILIKE '%fn_audit_declarar%' INTO v_actualizar_ok
      FROM pg_proc WHERE proname = 'fn_est_actualizar' AND pronamespace = 'academico_test'::regnamespace;

    IF NOT coalesce(v_crear_ok, false) THEN
        RAISE EXCEPTION 'V399: academico_test.fn_est_crear no quedo llamando a fn_audit_declarar';
    END IF;
    IF NOT coalesce(v_actualizar_ok, false) THEN
        RAISE EXCEPTION 'V399: academico_test.fn_est_actualizar no quedo llamando a fn_audit_declarar';
    END IF;

    RAISE NOTICE 'V399 OK: academico_test.fn_est_crear/fn_est_actualizar declaran contexto de auditoria por establecimiento (mismo patron que V362 en pigse).';
END $$;
