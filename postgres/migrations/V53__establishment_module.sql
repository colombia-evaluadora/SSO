-- ===========================================================================
-- V53 — Modulo de Establecimiento Educativo (academico_test).
--
-- Convencion de "package": PostgreSQL no tiene PACKAGE como Oracle/PL-SQL,
-- asi que las funcionalidades se agrupan en un solo archivo de migracion
-- con funciones del esquema `academico_test` y prefijo comun `fn_est_`.
-- Patrones reutilizados de V26 (contexto auditor) y de V22 (idempotencia
-- con DO $$ ... IF NOT EXISTS ... $$).
-- Dependencias:
--   * V50 (utilities): consume fn_puede_afectar_establecimiento desde alli.
--   * V52 (campus):    fn_est_soft_delete delega en fn_sed_soft_delete
--                       para la cascade de sedes (TSEDE, TSEDE_USUARIO,
--                       TSEDE_NIVEL) en lugar de repetirla localmente.
--
-- Alcance de esta primera entrega:
--   * fn_est_crear(...)           — crea un TESTABLECIMIENTO validando campos
--                                    obligatorios y unicidad por NIT/CODIGO.
--   * fn_est_buscar_por_nit(...)  — consulta un establecimiento por NIT
--                                    (incluye inactivos para auditoria).
--   * fn_est_buscar_por_pk(...)   — consulta un establecimiento por PK.
--                                    Solo activos (no incluye inactivos:
--                                    por PK el caller sabe distinguir
--                                    0-fila de "no existe").
--   * fn_est_actualizar(...)      — actualizacion parcial (PATCH) de un
--                                    EE activo. NIT y CODIGO son
--                                    modificables (validando unicidad
--                                    contra el resto de EE activos).
--   * fn_est_soft_delete(...)     — baja logica (ACTIVE=FALSE) en cascada:
--                                    TESTABLECIMIENTO. Para la cascade de
--                                    sus sedes DELEGA en fn_sed_soft_delete
--                                    (V52), que se encarga de TSEDE,
--                                    TSEDE_USUARIO y TSEDE_NIVEL.
--   * fn_est_contar(...)           — total de EE activos post-filtros (para
--                                    totalCount/pageCount del listado paginado).
--   * fn_est_listar(...)           — pagina de EE activos con filtros/orden,
--                                    replicando el contrato del mock de front
--                                    (filtros -> totalCount -> sort -> slice).
--
-- Reglas de negocio implementadas:
--   * Obligatorios NOT NULL del DDL: NOMBRE, FK_TMUNICIPIO,
--     FK_TPROPIEDAD_JURIDICA, CREATED_BY, CREATED_AT, ACTIVE, MODIFIED_BY.
--     Ademas, por requerimiento funcional: NIT (no es NOT NULL en DDL
--     pero el negocio lo exige) y CODIGO (tampoco es NOT NULL en DDL
--     pero se exigira como obligatorio en la UI).
--   * NIT duplicado (entre activos): RAISE EXCEPTION con SQLSTATE '23505'.
--   * CODIGO duplicado (entre activos): RAISE EXCEPTION con SQLSTATE '23505'
--     — la UNIQUE constraint U_TESTABLECIMIENTO_1 ya cubre todos los CODIGO,
--     aqui se valida solo entre activos para mantener simetria con NIT.
--   * Soft delete en cascada: TESTABLECIMIENTO.ACTIVE pasa a FALSE, y
--     luego, por cada TSEDE activa del EE, se delega en
--     academico_test.fn_sed_soft_delete (V52) con el mismo MODIFIED_BY
--     del solicitante y MODIFIED_AT=now. La cascade de TSEDE,
--     TSEDE_USUARIO y TSEDE_NIVEL vive en V52; aqui NO se replica.
--   * Autorizacion: TODO usuario que invoque las funciones MUTADORAS de este
--     modulo (crear/actualizar/soft_delete) debe tener rol de super-admin
--     (TROL.PK_TROL IN 1,2,3). Se valida mediante
--     `fn_puede_afectar_establecimiento(p_pk_usuario)`,
--     definida en V50 (utilities), que retorna TRUE si existe al menos una
--     fila en TSEDE_USUARIO con FK_TROL=1 (y ACTIVE=TRUE) para ese usuario;
--     si no se cumple, SQLSTATE '42501' (insufficient_privilege). Las
--     funciones de solo lectura (fn_est_buscar_por_nit, fn_est_contar,
--     fn_est_listar) NO exigen este gate, igual que el resto de consultas
--     de este modulo.
--   * Listado paginado (fn_est_contar/fn_est_listar): solo establecimientos
--     ACTIVE=TRUE; p_estados/p_departamentos/p_municipios son arrays de
--     BIGINT (PK reales: TLISTA_VALOR/TDEPARTAMENTO/TMUNICIPIO), no strings;
--     p_page_index base 0, p_page_size en (0,100]; sorting resuelto a un
--     unico (campo, desc) por el caller antes de invocar la funcion.
--   * Auditoria: CREATED_BY / MODIFIED_BY = p_pk_usuario::VARCHAR (el
--     PK_TUSUARIO del super-admin que ejecuta la accion). Esta convencion
--     sigue siendo compatible cuando se migre a sesion ligada al package.
--
-- Idempotencia:
--   * DROP IF EXISTS previo al CREATE OR REPLACE FUNCTION para permitir
--     re-ejecutar la migracion (Flyway solo la corre una vez por version,
--     pero el script debe ser seguro si se aplica manualmente).
-- ===========================================================================

SET search_path TO academico_test, public;


-- ---------------------------------------------------------------------------
-- fn_est_crear
--   Inserta un nuevo TESTABLECIMIENTO.
--   Retorna: PK_ESTABLECIMIENTO (BIGINT) del registro creado.
--   Excepciones:
--     SQLSTATE '42501' — El usuario no es super-admin (gate via
--                        fn_puede_afectar_establecimiento).
--     SQLSTATE '23505' — NIT ya existe en un TESTABLECIMIENTO activo.
--     SQLSTATE '22023' — Campo obligatorio nulo/vacio.
--     SQLSTATE '23503' — Alguna FK no existe (municipio, propiedad juridica,
--                        funcionario rector/secretaria, archivo, etc.).
-- ---------------------------------------------------------------------------
-- REV2 (post go-live): esta funcion ya NO recibe p_fk_lv_estado_establecimiento.
-- Antes existia una version con 33 parametros (la ultima era BIGINT, el
-- estado); esa firma quedo huerfana en produccion (distinto conteo de
-- args => CREATE OR REPLACE no la pisa) y debe borrarse explicitamente:
DROP FUNCTION IF EXISTS academico_test.fn_est_crear(
    BIGINT,
    VARCHAR, VARCHAR, BIGINT, BIGINT,
    VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR,
    VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR,
    BIGINT,
    VARCHAR, VARCHAR, DATE,
    BIGINT, BIGINT, BIGINT, BIGINT,
    academico_test.bool_sn, academico_test.bool_sn,
    BIGINT, BIGINT, academico_test.bool_sn,
    BIGINT, BIGINT, BIGINT, BIGINT,
    BIGINT
);

CREATE OR REPLACE FUNCTION academico_test.fn_est_crear(
    -- Auditoria / autorizacion: PK_TUSUARIO del super-admin que crea.
    -- Siempre el primer parametro (mismo patron que V52): evita el 42P13
    -- "args con default deben ir al final" y estandariza el orden.
    p_pk_usuario_solicitante  BIGINT,
    p_nombre                  VARCHAR(130),
    p_nit                     VARCHAR(30),
    p_fk_municipio            BIGINT,
    p_fk_propiedad_juridica   BIGINT,
    p_codigo                  VARCHAR(30),
    -- Datos de ubicacion (todos opcionales salvo que se indiquen NOT NULL)
    p_localidad               VARCHAR(130)    DEFAULT NULL,
    p_comuna                  VARCHAR(130)    DEFAULT NULL,
    p_barrio                  VARCHAR(130)    DEFAULT NULL,
    p_direccion               VARCHAR(130)    DEFAULT NULL,
    p_correo_electronico      VARCHAR(130)    DEFAULT NULL,
    p_telefono                VARCHAR(130)    DEFAULT NULL,
    p_fax                     VARCHAR(130)    DEFAULT NULL,
    p_idecol                  VARCHAR(7)      DEFAULT NULL,
    p_pagina_web              VARCHAR(130)    DEFAULT NULL,
    p_fk_lista_valor_zona     BIGINT          DEFAULT NULL,
    -- Datos administrativos / licencias
    p_resolucion_aprobacion   VARCHAR(130)    DEFAULT NULL,
    p_licencia_funcionamiento VARCHAR(130)    DEFAULT NULL,
    p_fecha_licencia          DATE            DEFAULT NULL,
    p_fk_lv_calendario        BIGINT          DEFAULT NULL,
    p_fk_lv_idioma            BIGINT          DEFAULT NULL,
    p_fk_lv_genero_est        BIGINT          DEFAULT NULL,
    p_fk_discapacidad         BIGINT          DEFAULT NULL,
    p_talento                 academico_test.bool_sn         DEFAULT NULL,
    p_etnias                  academico_test.bool_sn         DEFAULT NULL,
    p_fk_tfuncionario_rector   BIGINT          DEFAULT NULL,
    p_fk_tfuncionario_secretaria BIGINT        DEFAULT NULL,
    p_subsidio                academico_test.bool_sn         DEFAULT NULL,
    p_fk_lv_regimen_catcosto  BIGINT          DEFAULT NULL,
    p_fk_lv_rango_tarifa      BIGINT          DEFAULT NULL,
    p_fk_lv_asociacion_nacional BIGINT        DEFAULT NULL,
    p_fk_archivo              BIGINT          DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
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
    -- 5. REV4 -- Permiso por defecto del rector (rol 7) y de la
    --    secretaria (rol 9, Auxiliar administrativo) en la sede recien
    --    creada. Antes quedaban sin ningun TSEDE_USUARIO hasta que
    --    alguien se lo asignara a mano -- por eso el listado de
    --    funcionarios necesito un tag sintetico para mostrar su rol (ver
    --    fn_usu_empleados_listar). Se usa fn_fun_permisos_actualizar (la
    --    misma funcion que ya usa el front para sincronizar permisos) en
    --    vez de insertar TSEDE_USUARIO a mano.
    --
    --    fn_fun_permisos_actualizar NO lanza excepcion si el permiso no
    --    se pudo crear (devuelve status='error:...' por fila) -- se
    --    captura el resultado y se relanza como excepcion real para que
    --    un problema acá no quede en silencio.
    -- -----------------------------------------------------------------
    IF p_fk_tfuncionario_rector IS NOT NULL THEN
        SELECT * INTO v_perm_result
          FROM academico_test.fn_fun_permisos_actualizar(
              p_pk_usuario_solicitante,
              p_fk_tfuncionario_rector,
              jsonb_build_array(jsonb_build_object(
                  'accion', 'crear',
                  'orden', 1,
                  'fk_rol', c_fk_trol_rector,
                  'fk_sede', v_pk_sede_creada,
                  'fk_jornada', c_fk_tlv_jornada_defecto,
                  'predeterminado', 1
              ))
          );
        IF v_perm_result.status IS DISTINCT FROM 'creado' THEN
            RAISE EXCEPTION 'No se pudo crear el permiso por defecto del rector (TFUNCIONARIO %) en la sede %: %',
                p_fk_tfuncionario_rector, v_pk_sede_creada, v_perm_result.status;
        END IF;
    END IF;

    IF p_fk_tfuncionario_secretaria IS NOT NULL THEN
        SELECT * INTO v_perm_result
          FROM academico_test.fn_fun_permisos_actualizar(
              p_pk_usuario_solicitante,
              p_fk_tfuncionario_secretaria,
              jsonb_build_array(jsonb_build_object(
                  'accion', 'crear',
                  'orden', 1,
                  'fk_rol', c_fk_trol_secretaria,
                  'fk_sede', v_pk_sede_creada,
                  'fk_jornada', c_fk_tlv_jornada_defecto,
                  'predeterminado', 1
              ))
          );
        IF v_perm_result.status IS DISTINCT FROM 'creado' THEN
            RAISE EXCEPTION 'No se pudo crear el permiso por defecto de la secretaria (TFUNCIONARIO %) en la sede %: %',
                p_fk_tfuncionario_secretaria, v_pk_sede_creada, v_perm_result.status;
        END IF;
    END IF;

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
$$;

COMMENT ON FUNCTION academico_test.fn_est_crear(
    BIGINT,
    VARCHAR, VARCHAR, BIGINT, BIGINT,
    VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR,
    VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR,
    BIGINT,
    VARCHAR, VARCHAR, DATE,
    BIGINT, BIGINT, BIGINT, BIGINT,
    academico_test.bool_sn, academico_test.bool_sn,
    BIGINT, BIGINT, academico_test.bool_sn,
    BIGINT, BIGINT, BIGINT,
    BIGINT
) IS 'Crea un TESTABLECIMIENTO validando obligatorios (NOMBRE, NIT, CODIGO, FK_TMUNICIPIO, FK_TPROPIEDAD_JURIDICA) y unicidad por NIT/CODIGO activos. Requiere p_pk_usuario_solicitante con rol 1, 2 o 3 (validado via fn_puede_afectar_establecimiento). p_pk_usuario_solicitante va al inicio sin DEFAULT (obligatorio, mismo patron que V52). Retorna PK_ESTABLECIMIENTO. Ya NO recibe p_fk_lv_estado_establecimiento: el INSERT fija FK_TLV_ESTADO_ESTABLECIMIENTO=533 ("Activo") de forma fija via c_fk_lv_estado_activo. La columna LOGO del DDL NO se escribe desde esta funcion (no hay modulo de archivos todavia); se pobla posteriormente via UPDATE directo. Auditoria: CREATED_BY=p_pk_usuario_solicitante::VARCHAR, CREATED_AT=now. MODIFIED_BY y MODIFIED_AT quedan NULL (se llenan en la primera edicion via fn_est_actualizar). REV4: ademas crea (via fn_sed_crear) una TSEDE por defecto con el mismo CODIGO/NOMBRE del EE y zona "Urbana y Rural" (216), y si vinieron p_fk_tfuncionario_rector/secretaria les crea (via fn_fun_permisos_actualizar) un permiso TSEDE_USUARIO en esa sede -- rector con FK_TROL=7, secretaria con FK_TROL=9 (Auxiliar administrativo), jornada "Completa" (51900), predeterminado=1. Antes rector/secretaria quedaban sin ningun TSEDE_USUARIO hasta que alguien se los asignara a mano.';


-- ---------------------------------------------------------------------------
-- fn_est_buscar_por_nit
--   Busca un TESTABLECIMIENTO por NIT.
--   Por defecto solo retorna activos (ACTIVE=TRUE); pasar p_incluir_inactivos=TRUE
--   para traer tambien registros dados de baja (auditoria).
--   Retorna: SETOF TESTABLECIMIENTO (puede ser 0, 1 o varias filas si el NIT
--            estuviera duplicado en inactivos).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_est_buscar_por_nit(
    p_nit                  VARCHAR(30),
    p_incluir_inactivos    BOOLEAN DEFAULT FALSE
)
RETURNS SETOF academico_test.TESTABLECIMIENTO
LANGUAGE sql
STABLE
AS $$
    SELECT *
    FROM academico_test.TESTABLECIMIENTO
    WHERE NIT = p_nit
      AND (p_incluir_inactivos = TRUE OR ACTIVE = TRUE)
    ORDER BY ACTIVE DESC, PK_ESTABLECIMIENTO;
$$;

COMMENT ON FUNCTION academico_test.fn_est_buscar_por_nit(VARCHAR, BOOLEAN)
    IS 'Busca TESTABLECIMIENTO por NIT. Por defecto solo activos; con p_incluir_inactivos=TRUE trae tambien los dados de baja.';


-- ---------------------------------------------------------------------------
-- fn_est_buscar_por_pk
--   Busca un TESTABLECIMIENTO por PK_ESTABLECIMIENTO.
--   Solo retorna registros activos (ACTIVE=TRUE). Si el PK no existe o
--   esta inactivo (borrado logico), el SETOF viene vacio: mismo contrato
--   que antes, sin p_incluir_inactivos, porque el caller distingue 0-fila
--   de "no existe" sin necesidad de traer inactivos.
--   Retorna: SETOF TESTABLECIMIENTO (0 o 1 fila en la practica).
--
--   Gate de autorizacion (mismo patron que fn_est_listar):
--     (a) super-admin (fn_puede_afectar_establecimiento, roles 1-3): ve
--         cualquier EE activo.
--     (b) rector del EE objetivo: TFUNCIONARIO.ACTIVE=TRUE con
--         FK_TFUNCIONARIO_RECTOR = e.FK_TFUNCIONARIO_RECTOR y
--         FK_TUSUARIO = p_pk_usuario_solicitante.
--     Cualquier otro caso => 42501. La unica diferencia con el listado
--     es que el gate se valida contra el EE concreto que se esta pidiendo
--     (no contra el universo completo): un rector solo puede pedir
--     "su" EE, no uno ajeno.
--
--   Excepciones:
--     SQLSTATE '22023' — p_pk_usuario_solicitante <= 0.
--     SQLSTATE 'P0002' — No existe TESTABLECIMIENTO con ese PK.
--     SQLSTATE '42501' — Existe, esta activo, pero el usuario no pasa
--                        el gate (no es super-admin ni rector del EE).
--     SETOF vacio    — Existe pero esta inactivo (no se distingue de
--                       "no existe"; por convencion del modulo los
--                       inactivos son "borrados logicos").
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_est_buscar_por_pk(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_establecimiento      BIGINT
)
RETURNS SETOF academico_test.TESTABLECIMIENTO
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_active  BOOLEAN;
BEGIN
    -- 0. Validacion de parametro obligatorio.
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;
    IF p_pk_establecimiento IS NULL OR p_pk_establecimiento <= 0 THEN
        RAISE EXCEPTION 'p_pk_establecimiento es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    -- 1. Lectura del EE objetivo (activo o no) para decidir gate / error.
    SELECT e.ACTIVE
      INTO v_active
      FROM academico_test.TESTABLECIMIENTO e
     WHERE e.PK_ESTABLECIMIENTO = p_pk_establecimiento;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe TESTABLECIMIENTO con PK_ESTABLECIMIENTO = %', p_pk_establecimiento
            USING ERRCODE = 'P0002';
    END IF;

    -- 2. Inactivos => SETOF vacio, sin error (consistente con la
    --    semantica de "borrado logico" del modulo).
    IF v_active = FALSE THEN
        RETURN;
    END IF;

    -- 3. Gate de autorizacion. Mismo patron que fn_est_listar:
    --    (a) super-admin => ok;
    --    (b) rector del EE objetivo => ok;
    --    (c) cualquier otro => 42501.
    IF academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TFUNCIONARIO f
         WHERE f.PK_TFUNCIONARIO = (
                   SELECT e2.FK_TFUNCIONARIO_RECTOR
                     FROM academico_test.TESTABLECIMIENTO e2
                    WHERE e2.PK_ESTABLECIMIENTO = p_pk_establecimiento
               )
           AND f.ACTIVE          = TRUE
           AND f.FK_TUSUARIO     = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSE
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- 4. Retorno de la fila completa (todos los campos del DDL).
    RETURN QUERY
    SELECT *
      FROM academico_test.TESTABLECIMIENTO
     WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento
       AND ACTIVE = TRUE;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_est_buscar_por_pk(BIGINT, BIGINT)
    IS 'Busca TESTABLECIMIENTO por PK_ESTABLECIMIENTO con gate de autorizacion (mismo patron que fn_est_listar). Solo registros activos: si el PK no existe => P0002; si existe pero esta inactivo (borrado logico) => SETOF vacio. Gate: super-admin (fn_puede_afectar_establecimiento, roles 1-3) ve cualquier EE activo; cualquier otro solo si es rector activo del EE objetivo (TFUNCIONARIO.ACTIVE=TRUE con FK_TFUNCIONARIO_RECTOR = e.FK_TFUNCIONARIO_RECTOR y FK_TUSUARIO = p_pk_usuario_solicitante); en otro caso => 42501. p_pk_usuario_solicitante va al inicio (obligatorio, mismo patron que V52/V53). Pensada para carga completa de detalle desde la UI: el SELECT expone todos los campos del DDL (incluye datos sensibles no presentes en el listado paginado), por eso el gate es obligatorio.';


-- ---------------------------------------------------------------------------
-- fn_est_contar / fn_est_listar
--   Soportan el listado paginado de TESTABLECIMIENTO para la UI (misma
--   semantica que el mock de front: filtros -> totalCount -> sort -> slice).
--   Division de responsabilidad: fn_est_contar entrega el total post-filtros
--   y fn_est_listar entrega solo la pagina solicitada; el caller (capa Java)
--   calcula pageCount = max(1, ceil(totalCount / pageSize)) y arma la
--   respuesta { rows, pageCount, totalCount }. Se separan en dos funciones
--   para que el conteo (0 filas en la pagina por out-of-range) no impida
--   reportar totalCount/pageCount correctos.
--
--   Filtros (identicos en ambas funciones, ambos arrays vacios/NULL = sin
--   restriccion; OR dentro del mismo array, AND entre filtros distintos):
--     p_search        — ILIKE parcial case-insensitive sobre NOMBRE, CODIGO
--                        (dane), nombre de departamento y nombre de municipio.
--     p_departamentos — filtra por TDEPARTAMENTO.PK_DEPARTAMENTO.
--     p_municipios    — filtra por TMUNICIPIO.PK_TMUNICIPIO.
--     p_estados       — filtra por TESTABLECIMIENTO.FK_TLV_ESTADO_ESTABLECIMIENTO
--                        (son BIGINT, PK de TLISTA_VALOR — no strings).
--   Solo se listan establecimientos activos (ACTIVE=TRUE); los dados de baja
--   no aparecen en este listado (para eso esta fn_est_buscar_por_nit).
--
--   Sorting: se resuelve UN solo (campo, desc) por llamada — el array de
--   TanStack Table ([{id, desc}, ...]) se colapsa en la capa Java antes de
--   invocar la funcion (vacio => p_sort_campo NULL => orden por defecto).
--   Campos ordenables: 'name' (NOMBRE), 'dane' (CODIGO), 'department'
--   (nombre de departamento), 'municipality' (nombre de municipio),
--   'status' (nombre del valor de lista). Un campo desconocido se ignora
--   silenciosamente (cae al orden por defecto) en vez de fallar, porque es
--   una funcion de lectura. Se usa CASE estatico (no EXECUTE dinamico) para
--   evitar SQL dinamico innecesario; NOMBRE + PK_ESTABLECIMIENTO se agregan
--   siempre al final como desempate determinista (asi la paginacion es
--   estable aunque haya nombres repetidos).
--
--   Paginacion: p_page_index es base 0. p_page_size <= 0 cae a 10 (igual
--   que el mock). p_page_index negativo se ajusta a 0. p_page_size se topa
--   en 100 como salvaguarda ante consumo excesivo de recursos; una pagina
--   fuera de rango simplemente retorna 0 filas (LIMIT/OFFSET lo maneja solo).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_est_contar(
    p_pk_usuario_solicitante  BIGINT,
    p_search        VARCHAR DEFAULT NULL,
    p_departamentos BIGINT[] DEFAULT NULL,
    p_municipios    BIGINT[] DEFAULT NULL,
    p_estados       BIGINT[] DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_total BIGINT;
BEGIN
    -- Gate de autorizacion: super-admin ve todo; cualquier otro solo
    -- cuenta EE de los que es rector O secretaria (FK_TFUNCIONARIO_RECTOR /
    -- FK_TFUNCIONARIO_SECRETARIA -> TFUNCIONARIO activo cuyo FK_TUSUARIO =
    -- p_pk_usuario_solicitante). Mismo patron "ee_accesibles" (rector UNION
    -- secretaria) que fn_sed_contar (V52).
    IF NOT academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante) THEN
        WITH ee_accesibles AS (
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO  f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO  f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
        )
        SELECT COUNT(*)
          INTO v_total
          FROM academico_test.TESTABLECIMIENTO e
          JOIN ee_accesibles ee ON ee.PK_ESTABLECIMIENTO = e.PK_ESTABLECIMIENTO
          JOIN academico_test.TMUNICIPIO    m ON m.PK_TMUNICIPIO    = e.FK_TMUNICIPIO
          JOIN academico_test.TDEPARTAMENTO d ON d.PK_DEPARTAMENTO  = m.PK_TDEPARTAMENTO
         WHERE e.ACTIVE = TRUE
           AND (NULLIF(TRIM(p_search), '') IS NULL
                OR e.NOMBRE ILIKE '%' || p_search || '%'
                OR e.CODIGO ILIKE '%' || p_search || '%'
                OR d.NOMBRE ILIKE '%' || p_search || '%'
                OR m.NOMBRE ILIKE '%' || p_search || '%')
           AND (p_departamentos IS NULL OR CARDINALITY(p_departamentos) = 0
                OR d.PK_DEPARTAMENTO = ANY(p_departamentos))
           AND (p_municipios IS NULL OR CARDINALITY(p_municipios) = 0
                OR m.PK_TMUNICIPIO = ANY(p_municipios))
           AND (p_estados IS NULL OR CARDINALITY(p_estados) = 0
                OR e.FK_TLV_ESTADO_ESTABLECIMIENTO = ANY(p_estados));

        IF v_total = 0 AND NOT EXISTS (
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO  f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO  f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
        ) THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
                USING ERRCODE = '42501';
        END IF;

        RETURN v_total;
    END IF;

    -- Camino super-admin: misma query que antes, sin filtro por rector/secretaria.
    SELECT COUNT(*)
      INTO v_total
      FROM academico_test.TESTABLECIMIENTO e
      JOIN academico_test.TMUNICIPIO    m ON m.PK_TMUNICIPIO    = e.FK_TMUNICIPIO
      JOIN academico_test.TDEPARTAMENTO d ON d.PK_DEPARTAMENTO  = m.PK_TDEPARTAMENTO
 LEFT JOIN academico_test.TLISTA_VALOR  tlv ON tlv.PK_LISTA_VALOR = e.FK_TLV_ESTADO_ESTABLECIMIENTO
     WHERE e.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_search), '') IS NULL
            OR e.NOMBRE ILIKE '%' || p_search || '%'
            OR e.CODIGO ILIKE '%' || p_search || '%'
            OR d.NOMBRE ILIKE '%' || p_search || '%'
            OR m.NOMBRE ILIKE '%' || p_search || '%')
       AND (p_departamentos IS NULL OR CARDINALITY(p_departamentos) = 0
            OR d.PK_DEPARTAMENTO = ANY(p_departamentos))
       AND (p_municipios IS NULL OR CARDINALITY(p_municipios) = 0
            OR m.PK_TMUNICIPIO = ANY(p_municipios))
       AND (p_estados IS NULL OR CARDINALITY(p_estados) = 0
            OR e.FK_TLV_ESTADO_ESTABLECIMIENTO = ANY(p_estados));
    RETURN v_total;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_est_contar(BIGINT, VARCHAR, BIGINT[], BIGINT[], BIGINT[])
    IS 'Cuenta TESTABLECIMIENTO activos aplicando los mismos filtros que fn_est_listar (search/departamentos/municipios/estados). Gate de autorizacion: si el usuario pasa fn_puede_afectar_establecimiento cuenta todos los EE activos; en caso contrario solo cuenta los EE donde es rector O secretaria (FK_TFUNCIONARIO_RECTOR / FK_TFUNCIONARIO_SECRETARIA -> TFUNCIONARIO activo con FK_TUSUARIO = p_pk_usuario_solicitante, patron "ee_accesibles" igual que fn_sed_contar en V52). Si no es super-admin y no es rector/secretaria de ningun EE activo => 42501. Usar junto con fn_est_listar para armar { rows, pageCount, totalCount } en la capa Java. p_pk_usuario_solicitante va al inicio (obligatorio, mismo patron que V52).';


-- REV3: revierte el estado_codigo agregado en REV2 -- ya sobraba, el front
-- termino usando fk_estado + estado_nombre directo de la fila (ver
-- use-establishments.ts). Cambia la lista de columnas otra vez, hace falta
-- el DROP explicito antes del CREATE OR REPLACE.
DROP FUNCTION IF EXISTS academico_test.fn_est_listar(BIGINT, VARCHAR, BIGINT[], BIGINT[], BIGINT[], VARCHAR, BOOLEAN, INT, INT);

CREATE OR REPLACE FUNCTION academico_test.fn_est_listar(
    p_pk_usuario_solicitante  BIGINT,
    p_search        VARCHAR DEFAULT NULL,
    p_departamentos BIGINT[] DEFAULT NULL,
    p_municipios    BIGINT[] DEFAULT NULL,
    p_estados       BIGINT[] DEFAULT NULL,
    p_sort_campo    VARCHAR DEFAULT NULL,
    p_sort_desc     BOOLEAN DEFAULT FALSE,
    p_page_index    INT DEFAULT 0,
    p_page_size     INT DEFAULT 10
)
RETURNS TABLE (
    pk_establecimiento  BIGINT,
    codigo              VARCHAR,
    nombre              VARCHAR,
    nit                 VARCHAR,
    fk_departamento     BIGINT,
    departamento_nombre VARCHAR,
    fk_municipio        BIGINT,
    municipio_nombre    VARCHAR,
    fk_estado           BIGINT,
    estado_nombre       VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_page_size  INT := LEAST(CASE WHEN p_page_size > 0 THEN p_page_size ELSE 10 END, 100);
    v_page_index INT := GREATEST(COALESCE(p_page_index, 0), 0);
BEGIN
    -- Gate de autorizacion: super-admin ve todo; cualquier otro solo
    -- ve EE de los que es rector O secretaria (FK_TFUNCIONARIO_RECTOR /
    -- FK_TFUNCIONARIO_SECRETARIA -> TFUNCIONARIO activo cuyo FK_TUSUARIO =
    -- p_pk_usuario_solicitante). Mismo patron "ee_accesibles" (rector UNION
    -- secretaria) que fn_sed_listar (V52).
    IF academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante) THEN
        RETURN QUERY
        SELECT e.PK_ESTABLECIMIENTO, e.CODIGO, e.NOMBRE, e.NIT,
               d.PK_DEPARTAMENTO, d.NOMBRE,
               m.PK_TMUNICIPIO, m.NOMBRE,
               e.FK_TLV_ESTADO_ESTABLECIMIENTO, tlv.NOMBRE
          FROM academico_test.TESTABLECIMIENTO e
          JOIN academico_test.TMUNICIPIO    m ON m.PK_TMUNICIPIO    = e.FK_TMUNICIPIO
          JOIN academico_test.TDEPARTAMENTO d ON d.PK_DEPARTAMENTO  = m.PK_TDEPARTAMENTO
     LEFT JOIN academico_test.TLISTA_VALOR  tlv ON tlv.PK_LISTA_VALOR = e.FK_TLV_ESTADO_ESTABLECIMIENTO
         WHERE e.ACTIVE = TRUE
           AND (NULLIF(TRIM(p_search), '') IS NULL
                OR e.NOMBRE ILIKE '%' || p_search || '%'
                OR e.CODIGO ILIKE '%' || p_search || '%'
                OR d.NOMBRE ILIKE '%' || p_search || '%'
                OR m.NOMBRE ILIKE '%' || p_search || '%')
           AND (p_departamentos IS NULL OR CARDINALITY(p_departamentos) = 0
                OR d.PK_DEPARTAMENTO = ANY(p_departamentos))
           AND (p_municipios IS NULL OR CARDINALITY(p_municipios) = 0
                OR m.PK_TMUNICIPIO = ANY(p_municipios))
           AND (p_estados IS NULL OR CARDINALITY(p_estados) = 0
                OR e.FK_TLV_ESTADO_ESTABLECIMIENTO = ANY(p_estados))
         ORDER BY
            CASE WHEN p_sort_campo = 'name'         AND NOT p_sort_desc THEN e.NOMBRE   END ASC,
            CASE WHEN p_sort_campo = 'name'         AND     p_sort_desc THEN e.NOMBRE   END DESC,
            CASE WHEN p_sort_campo = 'dane'         AND NOT p_sort_desc THEN e.CODIGO   END ASC,
            CASE WHEN p_sort_campo = 'dane'         AND     p_sort_desc THEN e.CODIGO   END DESC,
            CASE WHEN p_sort_campo = 'department'   AND NOT p_sort_desc THEN d.NOMBRE   END ASC,
            CASE WHEN p_sort_campo = 'department'   AND     p_sort_desc THEN d.NOMBRE   END DESC,
            CASE WHEN p_sort_campo = 'municipality' AND NOT p_sort_desc THEN m.NOMBRE   END ASC,
            CASE WHEN p_sort_campo = 'municipality' AND     p_sort_desc THEN m.NOMBRE   END DESC,
            CASE WHEN p_sort_campo = 'status'       AND NOT p_sort_desc THEN tlv.NOMBRE END ASC,
            CASE WHEN p_sort_campo = 'status'       AND     p_sort_desc THEN tlv.NOMBRE END DESC,
            e.NOMBRE ASC,
            e.PK_ESTABLECIMIENTO ASC
         LIMIT v_page_size
        OFFSET v_page_index * v_page_size;
        RETURN;
    END IF;

    -- Camino no-super-admin: filtrar por rector UNION secretaria.
    IF NOT EXISTS (
        WITH ee_accesibles AS (
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO  f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO  f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
        )
        SELECT 1 FROM ee_accesibles
    ) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT e.PK_ESTABLECIMIENTO, e.CODIGO, e.NOMBRE, e.NIT,
           d.PK_DEPARTAMENTO, d.NOMBRE,
           m.PK_TMUNICIPIO, m.NOMBRE,
           e.FK_TLV_ESTADO_ESTABLECIMIENTO, tlv.NOMBRE
      FROM academico_test.TESTABLECIMIENTO e
      JOIN (
          SELECT e2.PK_ESTABLECIMIENTO
            FROM academico_test.TESTABLECIMIENTO e2
            JOIN academico_test.TFUNCIONARIO  f ON f.PK_TFUNCIONARIO = e2.FK_TFUNCIONARIO_RECTOR
           WHERE e2.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
          UNION
          SELECT e2.PK_ESTABLECIMIENTO
            FROM academico_test.TESTABLECIMIENTO e2
            JOIN academico_test.TFUNCIONARIO  f ON f.PK_TFUNCIONARIO = e2.FK_TFUNCIONARIO_SECRETARIA
           WHERE e2.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
      ) ee ON ee.PK_ESTABLECIMIENTO = e.PK_ESTABLECIMIENTO
      JOIN academico_test.TMUNICIPIO    m ON m.PK_TMUNICIPIO    = e.FK_TMUNICIPIO
      JOIN academico_test.TDEPARTAMENTO d ON d.PK_DEPARTAMENTO  = m.PK_TDEPARTAMENTO
 LEFT JOIN academico_test.TLISTA_VALOR  tlv ON tlv.PK_LISTA_VALOR = e.FK_TLV_ESTADO_ESTABLECIMIENTO
     WHERE e.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_search), '') IS NULL
            OR e.NOMBRE ILIKE '%' || p_search || '%'
            OR e.CODIGO ILIKE '%' || p_search || '%'
            OR d.NOMBRE ILIKE '%' || p_search || '%'
            OR m.NOMBRE ILIKE '%' || p_search || '%')
       AND (p_departamentos IS NULL OR CARDINALITY(p_departamentos) = 0
            OR d.PK_DEPARTAMENTO = ANY(p_departamentos))
       AND (p_municipios IS NULL OR CARDINALITY(p_municipios) = 0
            OR m.PK_TMUNICIPIO = ANY(p_municipios))
       AND (p_estados IS NULL OR CARDINALITY(p_estados) = 0
            OR e.FK_TLV_ESTADO_ESTABLECIMIENTO = ANY(p_estados))
     ORDER BY
        CASE WHEN p_sort_campo = 'name'         AND NOT p_sort_desc THEN e.NOMBRE   END ASC,
        CASE WHEN p_sort_campo = 'name'         AND     p_sort_desc THEN e.NOMBRE   END DESC,
        CASE WHEN p_sort_campo = 'dane'         AND NOT p_sort_desc THEN e.CODIGO   END ASC,
        CASE WHEN p_sort_campo = 'dane'         AND     p_sort_desc THEN e.CODIGO   END DESC,
        CASE WHEN p_sort_campo = 'department'   AND NOT p_sort_desc THEN d.NOMBRE   END ASC,
        CASE WHEN p_sort_campo = 'department'   AND     p_sort_desc THEN d.NOMBRE   END DESC,
        CASE WHEN p_sort_campo = 'municipality' AND NOT p_sort_desc THEN m.NOMBRE   END ASC,
        CASE WHEN p_sort_campo = 'municipality' AND     p_sort_desc THEN m.NOMBRE   END DESC,
        CASE WHEN p_sort_campo = 'status'       AND NOT p_sort_desc THEN tlv.NOMBRE END ASC,
        CASE WHEN p_sort_campo = 'status'       AND     p_sort_desc THEN tlv.NOMBRE END DESC,
        e.NOMBRE ASC,
        e.PK_ESTABLECIMIENTO ASC
     LIMIT v_page_size
    OFFSET v_page_index * v_page_size;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_est_listar(BIGINT, VARCHAR, BIGINT[], BIGINT[], BIGINT[], VARCHAR, BOOLEAN, INT, INT)
    IS 'Lista TESTABLECIMIENTO activos paginados. Mismos filtros que fn_est_contar. Gate de autorizacion: si el usuario pasa fn_puede_afectar_establecimiento ve todos los EE activos; en caso contrario solo ve los EE donde es rector O secretaria (FK_TFUNCIONARIO_RECTOR / FK_TFUNCIONARIO_SECRETARIA -> TFUNCIONARIO activo con FK_TUSUARIO = p_pk_usuario_solicitante, patron "ee_accesibles" igual que fn_sed_listar en V52). Si no es super-admin y no es rector/secretaria de ningun EE activo => 42501. p_sort_campo/p_sort_desc representan sorting[0] ya resuelto por el caller (array vacio => NULL => orden por defecto NOMBRE/PK). p_page_index base 0; p_page_size se acota a (0,100]. No calcula totalCount/pageCount: usar junto con fn_est_contar. p_pk_usuario_solicitante va al inicio (obligatorio, mismo patron que V52).';


-- ---------------------------------------------------------------------------
-- fn_est_listar_todos (NUEVO)
--   Variante SIN paginar de fn_est_listar: solo pk_establecimiento + nombre,
--   pensada para alimentar un <select> de establecimiento (alta de sedes,
--   alta de funcionarios) sin tener que recorrer paginas.
--
--   Gate de autorizacion — a diferencia de fn_est_listar/fn_est_contar,
--   ademas de super-admin/rector/secretaria TAMBIEN incluye al jefe de
--   sistema (TROL.PK_TROL=8) de alguna sede del EE, via TSEDE_USUARIO
--   activa. Motivo: este listado lo consumen tambien fn_sed_crear y
--   fn_fun_enlazar_establecimiento (V51), donde el jefe de sistema si
--   tiene permiso de actuar sobre el EE (a diferencia del modulo
--   establecimiento en si, donde fn_puede_afectar_establecimiento sigue
--   sin darle poder — por eso fn_est_listar/fn_est_contar NO lo incluyen).
--
--   Retorna: SETOF (pk_establecimiento, nombre), ordenado por NOMBRE/PK.
--
--   Excepciones:
--     SQLSTATE '42501' — El usuario no es super-admin ni rector, secretaria
--                        o jefe de sistema de ningun EE activo.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_est_listar_todos(
    p_pk_usuario_solicitante  BIGINT
)
RETURNS TABLE (
    pk_establecimiento  BIGINT,
    nombre              VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante) THEN
        RETURN QUERY
        SELECT e.PK_ESTABLECIMIENTO, e.NOMBRE
          FROM academico_test.TESTABLECIMIENTO e
         WHERE e.ACTIVE = TRUE
         ORDER BY e.NOMBRE ASC, e.PK_ESTABLECIMIENTO ASC;
        RETURN;
    END IF;

    IF NOT EXISTS (
        WITH ee_accesibles AS (
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO  f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO  f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT DISTINCT s.FK_TESTABLECIMIENTO
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 8
               AND su.FK_TUSUARIO = p_pk_usuario_solicitante
        )
        SELECT 1 FROM ee_accesibles
    ) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT DISTINCT e.PK_ESTABLECIMIENTO, e.NOMBRE
      FROM academico_test.TESTABLECIMIENTO e
      JOIN (
          SELECT e2.PK_ESTABLECIMIENTO
            FROM academico_test.TESTABLECIMIENTO e2
            JOIN academico_test.TFUNCIONARIO  f ON f.PK_TFUNCIONARIO = e2.FK_TFUNCIONARIO_RECTOR
           WHERE e2.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
          UNION
          SELECT e2.PK_ESTABLECIMIENTO
            FROM academico_test.TESTABLECIMIENTO e2
            JOIN academico_test.TFUNCIONARIO  f ON f.PK_TFUNCIONARIO = e2.FK_TFUNCIONARIO_SECRETARIA
           WHERE e2.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
          UNION
          SELECT DISTINCT s.FK_TESTABLECIMIENTO
            FROM academico_test.TSEDE_USUARIO su
            JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
           WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 8
             AND su.FK_TUSUARIO = p_pk_usuario_solicitante
      ) ee ON ee.PK_ESTABLECIMIENTO = e.PK_ESTABLECIMIENTO
     WHERE e.ACTIVE = TRUE
     ORDER BY e.NOMBRE ASC, e.PK_ESTABLECIMIENTO ASC;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_est_listar_todos(BIGINT)
    IS 'Lista TODOS los TESTABLECIMIENTO activos que el usuario puede ver, sin paginar: pk_establecimiento + nombre, para alimentar un <select>. Super-admin ve todos; el resto ve rector UNION secretaria UNION jefe de sistema (rol 8) de alguna sede del EE. Si ninguno aplica => 42501.';


-- ---------------------------------------------------------------------------
-- fn_est_listar_paginado
--   Wrapper de conveniencia que combina fn_est_listar + fn_est_contar en
--   una sola llamada, devolviendo en un unico record la pagina de filas
--   mas la metadata de paginacion.
--
--   Por que existe:
--     La capa Java hacia 2 round-trips (uno para las filas, otro para el
--     total) y luego combinaba los resultados a mano. Con esta funcion
--     una sola llamada entrega { rows, totalCount, pageCount, pageIndex,
--     pageSize } listo para serializar a { rows, totalCount, pageCount }
--     en el response del endpoint.
--
--   Como esta implementado:
--     - DELega en fn_est_contar para obtener v_total (BIGINT). Esto
--       re-ejecuta la logica de gate y filtros de contar.
--     - Captura el SETOF de fn_est_listar con un FOR ... IN SELECT LOOP
--       (no necesita TYPE adicional porque fn_est_listar devuelve TABLE,
--       que es anonimo pero consultable como si fuera una vista).
--       Cada fila se agrega a un JSONB via jsonb_build_object y se
--       acumula con el operador || sobre un array JSONB.
--     - Calcula v_page_count = CEIL(v_total / v_page_size). Page count
--       = 0 si total = 0 (asi el cliente sabe "sin datos").
--
--   NO modifica la logica de gate ni filtros: ambas sub-funciones son
--   la fuente de verdad. Si cambian los criterios de busqueda, los
--   ordenes o el gate, solo se tocan fn_est_listar y fn_est_contar.
--
--   Retorna: UN SOLO record con la forma:
--       ( rows JSONB, total_count BIGINT, page_count BIGINT,
--         page_index INT, page_size INT )
--     donde rows es un JSON array de objetos con las mismas 10 columnas
--     que fn_est_listar: pk_establecimiento, codigo, nombre, nit,
--     fk_departamento, departamento_nombre, fk_municipio, municipio_nombre,
--     fk_estado, estado_nombre.
--
--   Excepciones:
--     SQLSTATE '42501' — Propagado desde fn_est_listar/fn_est_contar si
--                        el usuario no es super-admin ni rector de EE.
--     Cualquier otra excepcion 23503/22023/P0002 propagada.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_est_listar_paginado(
    p_pk_usuario_solicitante  BIGINT,
    p_search                  VARCHAR   DEFAULT NULL,
    p_departamentos           BIGINT[]  DEFAULT NULL,
    p_municipios              BIGINT[]  DEFAULT NULL,
    p_estados                 BIGINT[]  DEFAULT NULL,
    p_sort_campo              VARCHAR   DEFAULT NULL,
    p_sort_desc               BOOLEAN   DEFAULT FALSE,
    p_page_index              INT       DEFAULT 0,
    p_page_size               INT       DEFAULT 10
)
RETURNS TABLE (
    rows         JSONB,
    total_count  BIGINT,
    page_count   BIGINT,
    page_index   INT,
    page_size    INT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_rows_json   JSONB   := '[]'::JSONB;
    v_total       BIGINT;
    v_page_size   INT     := LEAST(CASE WHEN p_page_size > 0 THEN p_page_size ELSE 10 END, 100);
    v_page_index  INT     := GREATEST(COALESCE(p_page_index, 0), 0);
    v_page_count  BIGINT;
    v_one_row     JSONB;
BEGIN
    -- 1) Total de filas que cumplen los filtros (con gate aplicado).
    --    fn_est_contar ya aplica el gate de autorizacion (super-admin OR
    --    rector de >=1 EE activo). Si no cumple, lanza 42501.
    v_total := academico_test.fn_est_contar(
        p_pk_usuario_solicitante,
        p_search,
        p_departamentos,
        p_municipios,
        p_estados
    );

    -- 2) Calculo de page_count (0 si no hay resultados).
    v_page_count := CASE WHEN v_total = 0 THEN 0 ELSE CEIL(v_total::NUMERIC / v_page_size)::BIGINT END;

    -- 3) Captura de la pagina via FOR ... IN SELECT ... LOOP sobre
    --    fn_est_listar. fn_est_listar aplica los mismos filtros + gate y
    --    ya respeta p_page_index/p_page_size.
    FOR
        v_one_row IN
        SELECT to_jsonb(t)
          FROM academico_test.fn_est_listar(
              p_pk_usuario_solicitante,
              p_search,
              p_departamentos,
              p_municipios,
              p_estados,
              p_sort_campo,
              p_sort_desc,
              p_page_index,
              p_page_size
          ) AS t(
              pk_establecimiento, codigo, nombre, nit,
              fk_departamento, departamento_nombre,
              fk_municipio, municipio_nombre,
              fk_estado, estado_nombre
          )
    LOOP
        v_rows_json := v_rows_json || jsonb_build_array(v_one_row);
    END LOOP;

    -- 4) Resultado final en un solo record.
    RETURN QUERY
    SELECT v_rows_json, v_total, v_page_count, v_page_index, v_page_size;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_est_listar_paginado(
    BIGINT, VARCHAR, BIGINT[], BIGINT[], BIGINT[], VARCHAR, BOOLEAN, INT, INT
) IS 'Wrapper de paginacion: combina fn_est_listar + fn_est_contar en una sola llamada. Devuelve un unico record con la forma (rows JSONB, total_count BIGINT, page_count BIGINT, page_index INT, page_size INT). rows es un JSON array con las 10 columnas que retorna fn_est_listar (pk_establecimiento, codigo, nombre, nit, fk_departamento, departamento_nombre, fk_municipio, municipio_nombre, fk_estado, estado_nombre). El gate de autorizacion y los filtros se delegan tal cual a fn_est_listar/fn_est_contar (fuente unica de verdad). v_page_size se acota a (0,100] (mismo cap que fn_est_listar). Si v_total=0 => page_count=0 y rows=[]. Pensada para que la capa Java haga un solo SELECT * FROM academico_test.fn_est_listar_paginado(...) y arme { rows, totalCount, pageCount } directamente. p_pk_usuario_solicitante va al inicio (obligatorio, mismo patron que V52).';


-- ---------------------------------------------------------------------------
-- fn_est_soft_delete
--   Baja logica en cascada de un TESTABLECIMIENTO.
--   Marca ACTIVE=FALSE (MODIFIED_BY=p_pk_usuario_solicitante, MODIFIED_AT=now) en:
--     1. TESTABLECIMIENTO identificado por p_pk_establecimiento.
--     2. Para cada TSEDE activa del EE, delega en academico_test.fn_sed_soft_delete
--        (V52), que a su vez marca ACTIVE=FALSE en:
--          a. TSEDE.
--          b. TSEDE_USUARIO con FK_TSEDE = esa sede.
--          c. TSEDE_NIVEL con FK_TSEDE = esa sede.
--        Aqui NO se replican esos UPDATEs: la cascade de sede vive en V52.
--
--   Todo corre en una sola transaccion PL/pgSQL: si fn_sed_soft_delete
--   falla (por ejemplo, FK constraints forzadas) para cualquiera de las
--   sedes, la operacion se revierte entera, incluyendo la baja del EE.
--
--   NOTA: para que esto funcione, V52 (fn_sed_soft_delete) debe estar
--   ejecutada antes que V53 (orden lexicografico de Flyway ya lo
--   garantiza: 52 < 53).
--
--   Retorna: BIGINT con el PK_ESTABLECIMIENTO dado de baja.
--
--   Excepciones:
--     SQLSTATE '42501' — El usuario no es super-admin (gate via
--                        fn_puede_afectar_establecimiento, definida en V50).
--     SQLSTATE 'P0002' — No existe el TESTABLECIMIENTO con ese PK.
--     SQLSTATE '22023' — El TESTABLECIMIENTO ya estaba inactivo.
--     SQLSTATE 'P0002'/'22023'/'42501' propagados desde fn_sed_soft_delete
--                        si una sede no existe, ya estaba inactiva o el
--                        usuario perdio permisos a mitad del cascade.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_est_soft_delete(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_establecimiento      BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado_actual BOOLEAN;
    v_sedes         BIGINT := 0;
    v_pk_sede       BIGINT;
BEGIN
    -- -----------------------------------------------------------------
    -- 0. Gate de autorizacion: solo roles con permiso de establecimiento (1-3).
    -- -----------------------------------------------------------------
    IF NOT academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- -----------------------------------------------------------------
    -- 1. Validaciones previas
    -- -----------------------------------------------------------------
    SELECT ACTIVE
      INTO v_estado_actual
      FROM academico_test.TESTABLECIMIENTO
     WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe TESTABLECIMIENTO con PK_ESTABLECIMIENTO = %', p_pk_establecimiento
            USING ERRCODE = 'P0002';
    END IF;

    IF v_estado_actual = FALSE THEN
        RAISE EXCEPTION 'TESTABLECIMIENTO % ya se encuentra inactivo', p_pk_establecimiento
            USING ERRCODE = '22023',
                  HINT    = 'Use fn_est_buscar_por_nit(..., p_incluir_inactivos=TRUE) para localizar registros dados de baja';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Soft delete del establecimiento.
    --    MODIFIED_BY/MODIFIED_AT se actualizan para reflejar la baja.
    -- -----------------------------------------------------------------
    UPDATE academico_test.TESTABLECIMIENTO
       SET ACTIVE       = FALSE,
           MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT  = CURRENT_TIMESTAMP
     WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;

    -- -----------------------------------------------------------------
    -- 3. Cascade a las sedes del EE.
    --    Recorremos SOLO las sedes que estuvieran activas al momento del
    --    borrado, para evitar re-bajar inactivas (que seria no-op y
    --    ademas pisaria MODIFIED_AT previo). Por cada una, delegamos en
    --    fn_sed_soft_delete (V52), que se encarga de TSEDE, TSEDE_USUARIO
    --    y TSEDE_NIVEL. Usamos PERFORM (no SELECT) porque solo nos
    --    interesa el efecto; el PK devuelto se ignora.
    -- -----------------------------------------------------------------
    FOR v_pk_sede IN
        SELECT PK_TSEDE
          FROM academico_test.TSEDE
         WHERE FK_TESTABLECIMIENTO = p_pk_establecimiento
           AND ACTIVE = TRUE
         ORDER BY PK_TSEDE
    LOOP
        PERFORM academico_test.fn_sed_soft_delete(p_pk_usuario_solicitante, v_pk_sede);
        v_sedes := v_sedes + 1;
    END LOOP;

    -- -----------------------------------------------------------------
    -- 4. Log de auditoria (RAISE NOTICE; no falla la operacion).
    -- -----------------------------------------------------------------
    RAISE NOTICE 'Soft delete TESTABLECIMIENTO=% (autor: %): sedes dadas de baja via V52=%',
        p_pk_establecimiento, p_pk_usuario_solicitante, v_sedes;

    RETURN p_pk_establecimiento;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_est_soft_delete(BIGINT, BIGINT)
    IS 'Baja logica en cascada: marca ACTIVE=FALSE en TESTABLECIMIENTO y delega en academico_test.fn_sed_soft_delete (V52) para cada sede activa del EE. fn_sed_soft_delete se encarga a su vez de TSEDE, TSEDE_USUARIO y TSEDE_NIVEL (cuyo detalle vive en V52). Todo en una sola transaccion: si la delegation falla para cualquier sede, todo el borrado se revierte. Requiere p_pk_usuario_solicitante con rol 1, 2 o 3 (validado via fn_puede_afectar_establecimiento, definida en V50). p_pk_usuario_solicitante va primero en la firma (obligatorio, mismo patron que V52). Retorna PK_ESTABLECIMIENTO dado de baja.';


-- ---------------------------------------------------------------------------
-- fn_est_soft_delete_bulk
--   Variante bulk de fn_est_soft_delete: en lugar de un solo PK_ESTABLE-
--   CIMIENTO recibe un BIGINT[] de PKs y les aplica soft delete (con
--   cascade a sus sedes via fn_sed_soft_delete).
--
--   REV: mismo patron que fn_fun_baja_establecimiento_bulk -- cada PK
--   corre en su propio savepoint (BEGIN/EXCEPTION), asi que un fallo en
--   una fila NO aborta el resto ni deshace lo que ya se dio de baja.
--   Antes era atomico todo-o-nada (un solo FOREACH sin capturar
--   excepciones, devolvia un contador, y el gate de super-admin se
--   validaba una sola vez al inicio); ahora devuelve una fila
--   (pk_establecimiento, status) por cada PK, y el gate se revalida por
--   fila (delegado en fn_est_soft_delete).
--
--   Por cada PK del array se delega en fn_est_soft_delete(p_pk_usuario_
--   solicitante, p_pk_establecimiento), que es la fuente de verdad de la
--   cascade EE -> sedes -> usuarios de sede / niveles. Asi, cualquier
--   cambio futuro en la cascade del single se refleja automaticamente aqui.
--
--   Retorna: TABLE(pk_establecimiento BIGINT, status VARCHAR) -- una fila
--   por cada PK recibido (deduplicados), con status:
--     'eliminado'              — baja exitosa.
--     'error:no_encontrado'    — P0002, no existe ese EE.
--     'error:sin_permiso'      — 42501, el usuario no es super-admin.
--     'error:ya_inactivo'      — 22023, ya estaba inactivo.
--     'error:<mensaje>'        — cualquier otra excepcion no prevista
--                                (incluye fallas propagadas desde la
--                                cascade a fn_sed_soft_delete).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_est_soft_delete_bulk(
    p_pk_usuario_solicitante  BIGINT,
    p_pks                     BIGINT[]
)
RETURNS TABLE(pk_establecimiento BIGINT, status VARCHAR)
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk BIGINT;
BEGIN
    -- -----------------------------------------------------------------
    -- 0. Validacion de parametros de entrada.
    -- -----------------------------------------------------------------
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF p_pks IS NULL OR CARDINALITY(p_pks) = 0 THEN
        RAISE EXCEPTION 'p_pks es obligatorio y debe contener al menos un PK_ESTABLECIMIENTO'
            USING ERRCODE = '22023';
    END IF;

    FOR v_pk IN SELECT DISTINCT x FROM unnest(p_pks) AS x ORDER BY x
    LOOP
        BEGIN
            PERFORM academico_test.fn_est_soft_delete(p_pk_usuario_solicitante, v_pk);
            pk_establecimiento := v_pk;
            status             := 'eliminado';
            RETURN NEXT;
        EXCEPTION
            WHEN SQLSTATE 'P0002' THEN
                pk_establecimiento := v_pk;
                status             := 'error:no_encontrado';
                RETURN NEXT;
            WHEN SQLSTATE '42501' THEN
                pk_establecimiento := v_pk;
                status             := 'error:sin_permiso';
                RETURN NEXT;
            WHEN SQLSTATE '22023' THEN
                pk_establecimiento := v_pk;
                status             := 'error:ya_inactivo';
                RETURN NEXT;
            WHEN OTHERS THEN
                pk_establecimiento := v_pk;
                status             := 'error:' || SQLERRM;
                RETURN NEXT;
        END;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_est_soft_delete_bulk(BIGINT, BIGINT[])
    IS 'REV: baja logica en lote de establecimientos, una fila (pk_establecimiento, status) por PK -- cada uno en su propio savepoint via fn_est_soft_delete, asi que un fallo en uno no aborta ni deshace el resto (antes era todo-o-nada, devolvia un solo total_procesados, con el gate de super-admin validado una sola vez al inicio). status: eliminado | error:no_encontrado (P0002) | error:sin_permiso (42501) | error:ya_inactivo (22023) | error:<mensaje> para cualquier otra excepcion. Mismo patron que fn_fun_baja_establecimiento_bulk.';


-- ---------------------------------------------------------------------------
-- fn_est_actualizar
--   Actualizacion parcial (estilo PATCH) de un TESTABLECIMIENTO activo.
--   SEMANTICA: cada parametro que llegue como NULL NO modifica la columna.
--              cada parametro que llegue con un valor (incluso cadena vacia
--              o FALSE) SI modifica la columna. Esto permite updates
--              granulares desde la UI enviando solo los campos cambiados.
--
--   CAMPOS NO MODIFICABLES en update (no aparecen en la firma):
--     * PK_ESTABLECIMIENTO     — clave primaria, inmutable.
--     * CREATED_BY, CREATED_AT — trazabilidad de creacion, inmutable.
--     * ACTIVE                 — gestionado solo por fn_est_soft_delete
--                                 (y por futuras funciones de reactivacion).
--
--   NIT y CODIGO SON MODIFICABLES: si se envian, se validan contra el
--   resto de EE activos (excluyendo el propio PK) y se aplican. Si no
--   se envian, no cambian. La validacion usa el mismo criterio que en
--   fn_est_crear: solo entre activos (los inactivos pueden reusarse).
--
--   CAMPOS VALIDABLES: si llegan, deben cumplir las mismas reglas que en
--   fn_est_crear (no vacios para obligatorios, FKs validadas por el DDL).
--   Si NINGUN campo llega con valor, la operacion se considera no-operativa,
--   se emite RAISE NOTICE y se retorna el PK sin tocar nada.
--
--   REGLAS:
--     * Requiere p_pk_usuario_solicitante con rol super-admin.
--     * Solo actualiza EE activos (ACTIVE=TRUE). Sobre inactivos -> 22023.
--     * Solo actualiza MODIFIED_BY/MODIFIED_AT si al menos una columna
--       efectiva fue modificada (asi no se contamina auditoria con PATCHes
--       vacios).
--
--   Retorna: BIGINT con el PK_ESTABLECIMIENTO actualizado.
--
--   Excepciones:
--     SQLSTATE '42501' — El usuario no es super-admin.
--     SQLSTATE 'P0002' — No existe el TESTABLECIMIENTO con ese PK.
--     SQLSTATE '22023' — EE inactivo (no se puede actualizar) o un campo
--                        obligatorio llego vacio.
--     SQLSTATE '23503' — Alguna FK nueva no existe.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_est_actualizar(
    -- Auditoria / autorizacion: PK_TUSUARIO del usuario que actualiza.
    -- Siempre el primer parametro (mismo patron que V52): evita el 42P13
    -- "args con default deben ir al final" y estandariza el orden.
    p_pk_usuario_solicitante  BIGINT,
    -- PK del EE a actualizar. Obligatorio. Se coloca inmediatamente
    -- despues de p_pk_usuario_solicitante (mismo patron que V52) y el
    -- resto de parametros mantiene el orden de fn_est_crear, con todos
    -- los campos en DEFAULT NULL (NULL = no cambia; si se envian, se
    -- validan contra el resto de EE activos para evitar colision y
    -- pueden reutilizar valores de EE inactivos).
    p_pk_establecimiento      BIGINT,
    p_nombre                  VARCHAR(130)    DEFAULT NULL,
    p_nit                     VARCHAR(30)     DEFAULT NULL,
    p_fk_municipio            BIGINT          DEFAULT NULL,
    p_fk_propiedad_juridica   BIGINT          DEFAULT NULL,
    p_codigo                  VARCHAR(30)     DEFAULT NULL,
    -- Datos de ubicacion (nullable: NULL = no cambia)
    p_localidad               VARCHAR(130)    DEFAULT NULL,
    p_comuna                  VARCHAR(130)    DEFAULT NULL,
    p_barrio                  VARCHAR(130)    DEFAULT NULL,
    p_direccion               VARCHAR(130)    DEFAULT NULL,
    p_correo_electronico      VARCHAR(130)    DEFAULT NULL,
    p_telefono                VARCHAR(130)    DEFAULT NULL,
    p_fax                     VARCHAR(130)    DEFAULT NULL,
    p_idecol                  VARCHAR(7)      DEFAULT NULL,
    p_pagina_web              VARCHAR(130)    DEFAULT NULL,
    p_fk_lista_valor_zona     BIGINT          DEFAULT NULL,
    -- Datos administrativos / licencias
    p_resolucion_aprobacion   VARCHAR(130)    DEFAULT NULL,
    p_licencia_funcionamiento VARCHAR(130)    DEFAULT NULL,
    p_fecha_licencia          DATE            DEFAULT NULL,
    p_fk_lv_calendario        BIGINT          DEFAULT NULL,
    p_fk_lv_idioma            BIGINT          DEFAULT NULL,
    p_fk_lv_genero_est        BIGINT          DEFAULT NULL,
    p_fk_discapacidad         BIGINT          DEFAULT NULL,
    p_talento                 academico_test.bool_sn         DEFAULT NULL,
    p_etnias                  academico_test.bool_sn         DEFAULT NULL,
    p_FK_TFUNCIONARIO_RECTOR   BIGINT          DEFAULT NULL,
    p_FK_TFUNCIONARIO_SECRETARIA BIGINT        DEFAULT NULL,
    p_subsidio                academico_test.bool_sn         DEFAULT NULL,
    p_fk_lv_regimen_catcosto  BIGINT          DEFAULT NULL,
    p_fk_lv_rango_tarifa      BIGINT          DEFAULT NULL,
    p_fk_lv_asociacion_nacional BIGINT        DEFAULT NULL,
    p_fk_lv_estado_establecimiento BIGINT     DEFAULT NULL,
    p_fk_archivo              BIGINT          DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado_actual  BOOLEAN;
    v_fk_rector     BIGINT;
    v_es_rector     BOOLEAN := FALSE;
    -- V70 — rector/secretaria PREVIOS, capturados antes del UPDATE para
    -- poder sincronizar tambien a quien pierde el rol si cambia.
    v_old_rector      BIGINT;
    v_old_secretaria  BIGINT;
    -- REV4 -- NOMBRE/CODIGO actuales (antes del UPDATE), para ubicar la
    -- sede "por defecto" (misma NOMBRE/CODIGO que el EE, la que arma
    -- fn_est_crear al crear) y darle ahi el permiso a un rector/secretaria
    -- NUEVO. "Completa" (51900): jornada por defecto, mismo criterio que
    -- fn_est_crear.
    v_nombre_actual        VARCHAR;
    v_codigo_actual        VARCHAR;
    v_pk_sede_defecto      BIGINT;
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
    --    capturamos el rector/secretaria PREVIOS (V70) para poder
    --    sincronizar a quien pierde el rol si el UPDATE lo cambia.
    -- -----------------------------------------------------------------
    SELECT ACTIVE, FK_TFUNCIONARIO_RECTOR, FK_TFUNCIONARIO_SECRETARIA, NOMBRE, CODIGO
      INTO v_estado_actual, v_old_rector, v_old_secretaria, v_nombre_actual, v_codigo_actual
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
    -- 3c. REV4 -- si el rector/secretaria cambio a alguien NUEVO (no
    --     nulo, distinto del anterior), se le crea el permiso por
    --     defecto en la sede que coincide en NOMBRE+CODIGO con el EE
    --     (la que arma fn_est_crear) -- si esa sede no existe (EE viejo,
    --     sede renombrada o borrada), v_pk_sede_defecto queda NULL y no
    --     se crea nada, igual que antes de este cambio. Se guarda contra
    --     duplicados: si el funcionario YA tiene un permiso activo en
    --     esa sede con ese rol (p.ej. fue rector, lo sacaron, lo volvieron
    --     a poner), no se crea uno igual encima.
    -- -----------------------------------------------------------------
    SELECT PK_TSEDE INTO v_pk_sede_defecto
      FROM academico_test.TSEDE
     WHERE FK_TESTABLECIMIENTO = p_pk_establecimiento
       AND ACTIVE = TRUE
       AND NOMBRE = v_nombre_actual
       AND CODIGO = v_codigo_actual
     LIMIT 1;

    IF v_pk_sede_defecto IS NOT NULL
       AND p_FK_TFUNCIONARIO_RECTOR IS NOT NULL
       AND p_FK_TFUNCIONARIO_RECTOR IS DISTINCT FROM v_old_rector
       AND NOT EXISTS (
            SELECT 1
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TFUNCIONARIO f ON f.FK_TUSUARIO = su.FK_TUSUARIO
             WHERE f.PK_TFUNCIONARIO = p_FK_TFUNCIONARIO_RECTOR
               AND su.FK_TSEDE = v_pk_sede_defecto
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
                  'fk_sede', v_pk_sede_defecto,
                  'fk_jornada', c_fk_tlv_jornada_defecto,
                  'predeterminado', 1
              ))
          );
        IF v_perm_result.status IS DISTINCT FROM 'creado' THEN
            RAISE EXCEPTION 'No se pudo crear el permiso por defecto del nuevo rector (TFUNCIONARIO %) en la sede %: %',
                p_FK_TFUNCIONARIO_RECTOR, v_pk_sede_defecto, v_perm_result.status;
        END IF;
    END IF;

    IF v_pk_sede_defecto IS NOT NULL
       AND p_FK_TFUNCIONARIO_SECRETARIA IS NOT NULL
       AND p_FK_TFUNCIONARIO_SECRETARIA IS DISTINCT FROM v_old_secretaria
       AND NOT EXISTS (
            SELECT 1
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TFUNCIONARIO f ON f.FK_TUSUARIO = su.FK_TUSUARIO
             WHERE f.PK_TFUNCIONARIO = p_FK_TFUNCIONARIO_SECRETARIA
               AND su.FK_TSEDE = v_pk_sede_defecto
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
                  'fk_sede', v_pk_sede_defecto,
                  'fk_jornada', c_fk_tlv_jornada_defecto,
                  'predeterminado', 1
              ))
          );
        IF v_perm_result.status IS DISTINCT FROM 'creado' THEN
            RAISE EXCEPTION 'No se pudo crear el permiso por defecto de la nueva secretaria (TFUNCIONARIO %) en la sede %: %',
                p_FK_TFUNCIONARIO_SECRETARIA, v_pk_sede_defecto, v_perm_result.status;
        END IF;
    END IF;

    -- -----------------------------------------------------------------
    -- 3d. REV5 -- si el rector/secretaria cambio a alguien NUEVO, se le
    --     quita al que PERDIO el puesto su permiso por defecto (mismo rol,
    --     misma sede "por defecto" de 3c) -- decision de negocio: un
    --     rector/secretaria reemplazado deja de figurar con ese rol en esa
    --     sede, no se queda "duplicado" con el nuevo. Solo toca el permiso
    --     puntual (fk_rol + fk_sede exactos, via fn_sede_usuario_soft_delete
    --     por PK_TSEDE_USUARIO) -- nunca los demas permisos que el saliente
    --     pueda tener en otras sedes/roles, esos no se tocan.
    -- -----------------------------------------------------------------
    IF v_pk_sede_defecto IS NOT NULL
       AND p_FK_TFUNCIONARIO_RECTOR IS NOT NULL
       AND p_FK_TFUNCIONARIO_RECTOR IS DISTINCT FROM v_old_rector
       AND v_old_rector IS NOT NULL
    THEN
        SELECT su.PK_TSEDE_USUARIO INTO v_pk_permiso_a_quitar
          FROM academico_test.TSEDE_USUARIO su
          JOIN academico_test.TFUNCIONARIO f ON f.FK_TUSUARIO = su.FK_TUSUARIO
         WHERE f.PK_TFUNCIONARIO = v_old_rector
           AND su.FK_TSEDE = v_pk_sede_defecto
           AND su.FK_TROL  = c_fk_trol_rector
           AND su.ACTIVE   = TRUE
         LIMIT 1;

        IF v_pk_permiso_a_quitar IS NOT NULL THEN
            PERFORM academico_test.fn_sede_usuario_soft_delete(v_pk_permiso_a_quitar, p_pk_usuario_solicitante);
        END IF;
    END IF;

    IF v_pk_sede_defecto IS NOT NULL
       AND p_FK_TFUNCIONARIO_SECRETARIA IS NOT NULL
       AND p_FK_TFUNCIONARIO_SECRETARIA IS DISTINCT FROM v_old_secretaria
       AND v_old_secretaria IS NOT NULL
    THEN
        SELECT su.PK_TSEDE_USUARIO INTO v_pk_permiso_a_quitar
          FROM academico_test.TSEDE_USUARIO su
          JOIN academico_test.TFUNCIONARIO f ON f.FK_TUSUARIO = su.FK_TUSUARIO
         WHERE f.PK_TFUNCIONARIO = v_old_secretaria
           AND su.FK_TSEDE = v_pk_sede_defecto
           AND su.FK_TROL  = c_fk_trol_secretaria
           AND su.ACTIVE   = TRUE
         LIMIT 1;

        IF v_pk_permiso_a_quitar IS NOT NULL THEN
            PERFORM academico_test.fn_sede_usuario_soft_delete(v_pk_permiso_a_quitar, p_pk_usuario_solicitante);
        END IF;
    END IF;

    -- -----------------------------------------------------------------
    -- 4. Reporte y retorno.
    -- -----------------------------------------------------------------
    RAISE NOTICE 'fn_est_actualizar: TESTABLECIMIENTO=% procesado por usuario=%', p_pk_establecimiento, p_pk_usuario_solicitante;

    RETURN p_pk_establecimiento;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_est_actualizar(
    BIGINT, BIGINT,
    VARCHAR, VARCHAR,
    BIGINT, BIGINT,
    VARCHAR,
    VARCHAR, VARCHAR, VARCHAR, VARCHAR,
    VARCHAR, VARCHAR, VARCHAR, VARCHAR,
    VARCHAR,
    BIGINT,
    VARCHAR, VARCHAR, DATE,
    BIGINT, BIGINT, BIGINT, BIGINT,
    academico_test.bool_sn, academico_test.bool_sn,
    BIGINT, BIGINT, academico_test.bool_sn,
    BIGINT, BIGINT, BIGINT, BIGINT,
    BIGINT
) IS 'Actualizacion parcial (estilo PATCH) de TESTABLECIMIENTO. Cada parametro NULL no modifica su columna; cada valor no NULL se aplica. NIT y CODIGO son modificables: si se envian, se validan contra el resto de EE activos (excluyendo el propio PK) y se aplican. Solo opera sobre EE activos. Actualiza MODIFIED_BY/MODIFIED_AT solo si hay cambios. Gate de autorizacion compuesto: (a) el usuario pasa fn_puede_afectar_establecimiento (roles 1-3) => puede modificar cualquier EE activo; (b) en caso contrario, se valida que el FK_TFUNCIONARIO_RECTOR del EE apunte a un TFUNCIONARIO activo cuyo FK_TUSUARIO coincida con p_pk_usuario_solicitante. Cualquier otro caso => 42501. p_pk_usuario_solicitante y p_pk_establecimiento van al inicio sin DEFAULT (obligatorios, mismo patron que V52). Retorna PK_ESTABLECIMIENTO. V70: si FK_TFUNCIONARIO_RECTOR/SECRETARIA cambia, sincroniza al que gana Y al que pierde el rol en public.role_users (fn_sincronizar_rol_publico). REV4: ademas, si el rector/secretaria cambia a alguien NUEVO (no nulo, distinto del anterior), le crea un permiso TSEDE_USUARIO por defecto (via fn_fun_permisos_actualizar) en la sede cuyo NOMBRE/CODIGO coincide con el EE (la "sede por defecto" que arma fn_est_crear) -- rector con FK_TROL=7, secretaria con FK_TROL=9, jornada "Completa" (51900); si esa sede no existe (EE viejo, sede renombrada/borrada) no crea nada. Con guarda anti-duplicados: si el funcionario ya tiene un permiso activo con ese rol en esa sede, no crea uno igual. REV5: ademas, al que PIERDE el puesto de rector/secretaria (habia alguien antes, distinto del nuevo) se le desactiva (fn_sede_usuario_soft_delete) su permiso por defecto puntual -- mismo rol, misma sede por defecto -- sin tocar ningun otro permiso que tenga en otras sedes/roles.';