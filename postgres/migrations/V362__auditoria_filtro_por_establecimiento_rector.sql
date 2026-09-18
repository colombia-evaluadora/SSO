-- ============================================================================
-- V362 — filtro de auditoría por establecimiento para rectores.
--
-- REQUISITO DE NEGOCIO
--   Super-admin (CEVAL-SUPER_ADMINISTRADOR / PIGSE-ADMINISTRADOR /
--   PIGSE-SECRETARIA_TERRITORIAL) sigue viendo TODA la auditoría de su
--   app. CEVAL-RECTOR / PIGSE-RECTOR (sin acceso HOY, ver V87/V358) pasan
--   a ver únicamente las operaciones de su propio establecimiento —
--   incluyendo las de docentes/secretaría/jefes/funcionarios de ese EE,
--   no solo las suyas: el filtro es por establecimiento de la fila, no
--   por autor.
--
-- POR QUE EL DATO VIAJA POR JWT Y NO SE RESUELVE EN CADA QUERY
--   Las instancias de query-service dedicadas a auditoría
--   (audit-clickhouse-cval/-pigse) solo tienen conexión a ClickHouse, no a
--   Postgres (ver docs/auditoria/auditoria-api-gap-analysis-clickhouse.md
--   §9.1) — no pueden llamar academico_test.fn_matricula_config_ee_solicitante
--   ni nada equivalente. Por eso el establecimiento del rector se resuelve
--   UNA vez en auth-center (login/refresh, ver EstablishmentResolver) y
--   viaja como claim `est` del JWT hasta query-service, que lo expone
--   como :CONTEXT.ESTABLISHMENT (ver QueryService#injectContextParams).
--
-- POR QUE SE COMPARA POR NOMBRE Y NO POR PK
--   auditoria.audit_log no tiene columna de establecimiento dedicada
--   (ver V66 fn_audit_declarar): el dato vive sin índice, como texto,
--   dentro de la columna JSON `contexto` — JSONExtractString(contexto,
--   'establecimiento'). Comparar por nombre evita tener que tocar el
--   pipeline CDC (cdc-sync, fuera de este repo) para agregar una columna
--   nueva; es la misma limitación que V66 ya documentó como pendiente.
--
-- QUE HACE ESTA MIGRACION
--   1. academico_test.fn_mi_establecimiento_para_auditoria(p_id_user):
--      bridgea public.users.id_user -> TUSUARIO vía
--      public.fn_get_academico_usuario_id, reusa
--      fn_matricula_config_ee_solicitante (V180) para el PK del EE, y
--      devuelve su NOMBRE. NULL (nunca RAISE) para cualquier caso que no
--      sea "administra exactamente un EE" -- login nunca debe fallar por
--      esto.
--   2. pigse.fn_resolver_actor + pigse.fn_audit_declarar: mismo patrón
--      que academico_test (V66), adaptado a pigse.TUSUARIO/TESTABLECIMIENTO
--      (sin sede -- pigse no tiene ese nivel). pigse NUNCA declaraba
--      contexto de auditoría hasta esta migración -- sus filas de
--      audit_log no tenían establecimiento en absoluto.
--   3. pigse.fn_mi_establecimiento_para_auditoria(p_id_user): mismo
--      patrón que el de CEVAL, usando TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR
--      / FK_TFUNCIONARIO_SECRETARIA (V360) en vez de fn_matricula_config_ee_solicitante.
--   4. Conecta pigse.fn_audit_declarar a fn_est_crear/fn_est_actualizar
--      (arranque de cobertura -- mismo criterio gradual que CEVAL, que
--      hoy solo cubre ~44 de sus funciones de escritura, no el 100%).
--   5. role_query: CEVAL-RECTOR -> audit-clickhouse-cval,
--      PIGSE-RECTOR -> audit-clickhouse-pigse (hoy sin ningún bind).
--   6. UPDATE de las 4 queries que leen audit_log a nivel de fila
--      (operations/query y sessions/:id/operations, cval + pigse):
--      agrega "AND (es-super-admin OR establecimiento-coincide)".
--      Las de sesiones (audits/query, audits/stats) NO se tocan --
--      leen tsesion_web, que no tiene noción de establecimiento; queda
--      fuera de alcance de esta migración.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. academico_test.fn_mi_establecimiento_para_auditoria
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_mi_establecimiento_para_auditoria(
    p_id_user BIGINT
)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pk_tusuario BIGINT;
    v_fk_est      BIGINT;
    v_nombre      TEXT;
BEGIN
    IF p_id_user IS NULL THEN
        RETURN NULL;
    END IF;

    v_pk_tusuario := public.fn_get_academico_usuario_id(p_id_user);
    IF v_pk_tusuario IS NULL THEN
        RETURN NULL;
    END IF;

    -- fn_matricula_config_ee_solicitante lanza 42501 (no es rector/
    -- secretaria/jefe de sistema de ningun EE) o 22023 (2+ EE) -- ambos
    -- casos son "sin scope unico" para efectos de auditoria, no un error
    -- que deba propagarse (esta función la llama el login).
    BEGIN
        v_fk_est := academico_test.fn_matricula_config_ee_solicitante(v_pk_tusuario);
    EXCEPTION WHEN OTHERS THEN
        RETURN NULL;
    END;

    SELECT NOMBRE INTO v_nombre
      FROM academico_test.TESTABLECIMIENTO
     WHERE PK_ESTABLECIMIENTO = v_fk_est;

    RETURN v_nombre;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_mi_establecimiento_para_auditoria(BIGINT) IS
    'V362: nombre del unico establecimiento que este usuario (public.users.id_user) administra como rector/secretaria/jefe de sistema, o NULL si no aplica (super-admin, sin rol de EE, o 2+ EE). Usado por auth-center (EstablishmentResolver) para el claim `est` del JWT que alimenta el filtro de auditoria por establecimiento.';

-- ---------------------------------------------------------------------------
-- 2. pigse.fn_resolver_actor + pigse.fn_audit_declarar
--    Espejo de academico_test (V66) -- pigse nunca declaraba contexto de
--    auditoria hasta ahora, así que sus filas de audit_log no tenían
--    establecimiento en absoluto.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pigse.fn_resolver_actor(p_usuario_id BIGINT)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
               NULLIF(TRIM(concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                      u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)), ''),
               u.CORREO_ELECTRONICO
           )
      FROM pigse.TUSUARIO u
     WHERE u.PK_TUSUARIO = p_usuario_id
$$;

COMMENT ON FUNCTION pigse.fn_resolver_actor IS
    'Resuelve el PK de pigse.TUSUARIO a un nombre legible (nombre completo > correo), '
    'o NULL si no existe. Espejo de academico_test.fn_resolver_actor (V66) sin CUENTA '
    '(pigse.TUSUARIO no tiene esa columna -- CORREO_ELECTRONICO hace sus veces).';

-- pigse no tiene concepto de "sede" (solo establecimiento), así que este
-- helper toma un solo nivel de ubicación -- p_establecimiento_id -- en vez
-- de los dos (p_sede_id/p_establecimiento_id) que academico_test soporta.
CREATE OR REPLACE FUNCTION pigse.fn_audit_declarar(
    p_usuario_id         BIGINT,
    p_etiqueta           TEXT,
    p_establecimiento_id BIGINT  DEFAULT NULL,
    p_etiquetas          TEXT[]  DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_actor           TEXT;
    v_establecimiento TEXT;
    v_ctx_existente   JSONB;
    v_ctx_nuevo       JSONB;
BEGIN
    IF p_usuario_id IS NOT NULL THEN
        v_actor := pigse.fn_resolver_actor(p_usuario_id);

        PERFORM set_config('app.user_id', COALESCE(v_actor, p_usuario_id::TEXT), true);
        PERFORM set_config('app.user_pk', p_usuario_id::TEXT, true);
    END IF;

    IF p_establecimiento_id IS NOT NULL THEN
        SELECT NOMBRE INTO v_establecimiento
          FROM pigse.TESTABLECIMIENTO
         WHERE PK_ESTABLECIMIENTO = p_establecimiento_id;
    END IF;

    IF v_establecimiento IS NOT NULL OR p_etiquetas IS NOT NULL THEN
        v_ctx_existente := NULLIF(current_setting('app.contexto', true), '')::JSONB;
        v_ctx_nuevo := jsonb_strip_nulls(jsonb_build_object(
            'establecimiento', v_establecimiento,
            'etiquetas',       CASE WHEN p_etiquetas IS NULL THEN NULL ELSE to_jsonb(p_etiquetas) END
        ));
        PERFORM set_config('app.contexto',
            (COALESCE(v_ctx_existente, '{}'::JSONB) || v_ctx_nuevo)::TEXT, true);
    END IF;

    IF p_etiqueta IS NOT NULL THEN
        PERFORM set_config('app.etiqueta', p_etiqueta, true);
    END IF;
END;
$$;

COMMENT ON FUNCTION pigse.fn_audit_declarar IS
    'V362: espejo de academico_test.fn_audit_declarar (V66) para pigse -- declara '
    'atribucion (quien), etiqueta de negocio (que) y establecimiento (cuando aplica) '
    'para trg_audit_ctx (instalado en tablas pigse desde V256, mismo emisor '
    'academico_test.fn_audit_ctx compartido por toda la base). Llamar justo antes '
    'del INSERT/UPDATE/DELETE, dentro de la misma funcion de escritura.';

-- ---------------------------------------------------------------------------
-- 3. pigse.fn_mi_establecimiento_para_auditoria
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pigse.fn_mi_establecimiento_para_auditoria(
    p_id_user BIGINT
)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pk_tusuario BIGINT;
    v_n           INT;
    v_nombre      TEXT;
BEGIN
    IF p_id_user IS NULL THEN
        RETURN NULL;
    END IF;

    v_pk_tusuario := public.fn_get_pigse_usuario_id(p_id_user);
    IF v_pk_tusuario IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT COUNT(*), MIN(NOMBRE)
      INTO v_n, v_nombre
      FROM pigse.TESTABLECIMIENTO e
     WHERE e.ACTIVE = TRUE
       AND (e.FK_TFUNCIONARIO_RECTOR IN (
                SELECT f.PK_TFUNCIONARIO FROM pigse.TFUNCIONARIO f
                 WHERE f.FK_TUSUARIO = v_pk_tusuario AND f.ACTIVE = TRUE)
         OR e.FK_TFUNCIONARIO_SECRETARIA IN (
                SELECT f.PK_TFUNCIONARIO FROM pigse.TFUNCIONARIO f
                 WHERE f.FK_TUSUARIO = v_pk_tusuario AND f.ACTIVE = TRUE));

    IF v_n <> 1 THEN
        RETURN NULL;
    END IF;

    RETURN v_nombre;
END;
$$;

COMMENT ON FUNCTION pigse.fn_mi_establecimiento_para_auditoria(BIGINT) IS
    'V362: nombre del unico establecimiento del que este usuario (public.users.id_user) es rector o secretaria (TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR/SECRETARIA, V360), o NULL si no aplica. Contraparte PIGSE de academico_test.fn_mi_establecimiento_para_auditoria.';

-- ---------------------------------------------------------------------------
-- 4. Conectar pigse.fn_audit_declarar a fn_est_crear / fn_est_actualizar
--    (arranque de cobertura -- ver nota de alcance al inicio del archivo).
--    CREATE OR REPLACE completo en ambas (no se puede "delegar" en la
--    version V360: un CREATE OR REPLACE no deja una version anterior
--    invocable bajo otro nombre) -- cuerpo copiado tal cual de V360, con
--    una sola linea nueva por funcion (la llamada a fn_audit_declarar).
--    Firmas y tipos de retorno sin cambios frente a V360.
-- ---------------------------------------------------------------------------

-- 4.1 — fn_est_crear: el establecimiento no tiene PK todavia al momento
-- de crearse (fn_audit_declarar necesita el PK, no el nombre), asi que
-- esa fila de creacion queda sin contexto de establecimiento -- mismo
-- limite que academico_test acepta para sus propias entidades raiz. Las
-- escrituras SIGUIENTES en la misma transaccion (enlazar ente, enlazar
-- rector/secretaria pendientes) SI quedan contextualizadas, porque para
-- entonces v_pk_establecimiento ya existe.
CREATE OR REPLACE FUNCTION pigse.fn_est_crear(
    p_pk_usuario_solicitante     BIGINT,
    p_fk_ente                    BIGINT,
    p_nombre                     VARCHAR,
    p_nit                        VARCHAR,
    p_fk_tmunicipio              BIGINT,
    p_codigo                     VARCHAR,
    p_fk_tpropiedad_juridica     BIGINT  DEFAULT NULL,
    p_direccion                  VARCHAR DEFAULT NULL,
    p_telefono                   VARCHAR DEFAULT NULL,
    p_correo_electronico         VARCHAR DEFAULT NULL,
    p_fk_tlista_valor_zona       BIGINT  DEFAULT NULL,
    p_fk_testablecimiento_origen BIGINT  DEFAULT NULL,
    p_fk_tfuncionario_rector     BIGINT  DEFAULT NULL,
    p_fk_tfuncionario_secretaria BIGINT  DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_pk_establecimiento BIGINT;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante,
            ARRAY['PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL']::VARCHAR[]) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    IF NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'Nombre del establecimiento es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF NULLIF(TRIM(p_nit), '') IS NULL THEN
        RAISE EXCEPTION 'NIT del establecimiento es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF NULLIF(TRIM(p_codigo), '') IS NULL THEN
        RAISE EXCEPTION 'Codigo del establecimiento es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_tmunicipio IS NULL THEN
        RAISE EXCEPTION 'Municipio (FK_TMUNICIPIO) es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_ente IS NULL THEN
        RAISE EXCEPTION 'Ente territorial (FK_TENTE) es obligatorio' USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pigse.TENTE e
                    WHERE e.PK_ENTE = p_fk_ente AND e.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El ente territorial (%) no existe o no esta activo', p_fk_ente
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pigse.TMUNICIPIO m
                    WHERE m.PK_TMUNICIPIO = p_fk_tmunicipio) THEN
        RAISE EXCEPTION 'El municipio (%) no existe', p_fk_tmunicipio USING ERRCODE = '23503';
    END IF;

    IF p_fk_tpropiedad_juridica IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TPROPIEDAD_JURIDICA pj
                        WHERE pj.PK_PROPIEDAD_JURIDICA = p_fk_tpropiedad_juridica
                          AND pj.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'La propiedad juridica (%) no existe o no esta activa', p_fk_tpropiedad_juridica
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlista_valor_zona IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TLISTA_VALOR lv
                        WHERE lv.PK_LISTA_VALOR = p_fk_tlista_valor_zona
                          AND lv.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'La zona (%) no existe o no esta activa en TLISTA_VALOR', p_fk_tlista_valor_zona
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tfuncionario_rector IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TFUNCIONARIO f
                        WHERE f.PK_TFUNCIONARIO = p_fk_tfuncionario_rector) THEN
        RAISE EXCEPTION 'El funcionario rector (%) no existe', p_fk_tfuncionario_rector
            USING ERRCODE = '23503';
    END IF;
    IF p_fk_tfuncionario_secretaria IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TFUNCIONARIO f
                        WHERE f.PK_TFUNCIONARIO = p_fk_tfuncionario_secretaria) THEN
        RAISE EXCEPTION 'El funcionario secretaria (%) no existe', p_fk_tfuncionario_secretaria
            USING ERRCODE = '23503';
    END IF;

    IF EXISTS (SELECT 1 FROM pigse.TESTABLECIMIENTO e
                WHERE e.NIT = TRIM(p_nit) AND e.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'Ya existe un establecimiento activo con NIT %', p_nit
            USING ERRCODE = '23505';
    END IF;
    IF EXISTS (SELECT 1 FROM pigse.TESTABLECIMIENTO e
                WHERE e.CODIGO = TRIM(p_codigo) AND e.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'Ya existe un establecimiento activo con CODIGO %', p_codigo
            USING ERRCODE = '23505';
    END IF;

    INSERT INTO pigse.TESTABLECIMIENTO (
        NOMBRE, NIT, CODIGO, FK_TMUNICIPIO, FK_TPROPIEDAD_JURIDICA,
        DIRECCION, TELEFONO, CORREO_ELECTRONICO, FK_TLISTA_VALOR_ZONA,
        FK_TESTABLECIMIENTO_ORIGEN, FK_TFUNCIONARIO_RECTOR, FK_TFUNCIONARIO_SECRETARIA,
        CREATED_BY, CREATED_AT, ACTIVE
    )
    VALUES (
        TRIM(p_nombre), TRIM(p_nit), TRIM(p_codigo), p_fk_tmunicipio, p_fk_tpropiedad_juridica,
        p_direccion, p_telefono, p_correo_electronico, p_fk_tlista_valor_zona,
        p_fk_testablecimiento_origen, p_fk_tfuncionario_rector, p_fk_tfuncionario_secretaria,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_ESTABLECIMIENTO INTO v_pk_establecimiento;

    -- V362: contexto de auditoria para las escrituras que siguen (enlazar
    -- ente, enlazar rector/secretaria pendientes) -- la fila de creacion
    -- del establecimiento en si misma no queda contextualizada porque
    -- v_pk_establecimiento no existia todavia cuando se insertó.
    PERFORM pigse.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Creacion del establecimiento %s', TRIM(p_nombre)), v_pk_establecimiento);

    INSERT INTO pigse.TENTE_ESTABLECIMIENTO (
        FK_TENTE, FK_TESTABLECIMIENTO, CREATED_BY, CREATED_AT, ACTIVE
    )
    SELECT p_fk_ente, v_pk_establecimiento, p_pk_usuario_solicitante::VARCHAR,
           CURRENT_TIMESTAMP, TRUE
     WHERE NOT EXISTS (
        SELECT 1 FROM pigse.TENTE_ESTABLECIMIENTO te
         WHERE te.FK_TENTE = p_fk_ente
           AND te.FK_TESTABLECIMIENTO = v_pk_establecimiento
           AND te.ACTIVE = TRUE
     );

    IF p_fk_tfuncionario_rector IS NOT NULL THEN
        UPDATE pigse.TFUNCIONARIO
           SET FK_TESTABLECIMIENTO = v_pk_establecimiento,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TFUNCIONARIO = p_fk_tfuncionario_rector
           AND FK_TESTABLECIMIENTO IS NULL;
    END IF;
    IF p_fk_tfuncionario_secretaria IS NOT NULL THEN
        UPDATE pigse.TFUNCIONARIO
           SET FK_TESTABLECIMIENTO = v_pk_establecimiento,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TFUNCIONARIO = p_fk_tfuncionario_secretaria
           AND FK_TESTABLECIMIENTO IS NULL;
    END IF;

    RETURN v_pk_establecimiento;
END;
$$;

COMMENT ON FUNCTION pigse.fn_est_crear(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, VARCHAR, BIGINT, VARCHAR, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT)
    IS 'V362: agrega pigse.fn_audit_declarar tras crear el establecimiento (arranque de cobertura de auditoria por establecimiento). Sin cambios de firma ni de logica de negocio frente a V360.';

-- 4.2 — fn_est_actualizar
CREATE OR REPLACE FUNCTION pigse.fn_est_actualizar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_establecimiento     BIGINT,
    p_nombre                 VARCHAR DEFAULT NULL,
    p_nit                    VARCHAR DEFAULT NULL,
    p_codigo                 VARCHAR DEFAULT NULL,
    p_fk_tmunicipio          BIGINT  DEFAULT NULL,
    p_fk_tpropiedad_juridica BIGINT  DEFAULT NULL,
    p_direccion              VARCHAR DEFAULT NULL,
    p_telefono               VARCHAR DEFAULT NULL,
    p_correo_electronico     VARCHAR DEFAULT NULL,
    p_fk_tlista_valor_zona   BIGINT  DEFAULT NULL,
    p_fk_ente                BIGINT  DEFAULT NULL,
    p_fk_tfuncionario_rector     BIGINT DEFAULT NULL,
    p_fk_tfuncionario_secretaria BIGINT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_nombre_actual VARCHAR;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante,
            ARRAY['PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL']::VARCHAR[]) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    SELECT e.NOMBRE INTO v_nombre_actual
      FROM pigse.TESTABLECIMIENTO e
     WHERE e.PK_ESTABLECIMIENTO = p_pk_establecimiento AND e.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el establecimiento solicitado (%)', p_pk_establecimiento
            USING ERRCODE = 'P0002';
    END IF;

    -- V362: declara el contexto de auditoria (quien + a que EE aplica)
    -- ANTES del UPDATE que sigue, para que trg_audit_ctx lo vea. Unica
    -- linea nueva de esta migracion frente al cuerpo de V360.
    PERFORM pigse.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualizacion del establecimiento %s', COALESCE(TRIM(p_nombre), v_nombre_actual)),
        p_pk_establecimiento);

    IF p_nit IS NOT NULL AND EXISTS (
        SELECT 1 FROM pigse.TESTABLECIMIENTO e
         WHERE e.NIT = TRIM(p_nit) AND e.ACTIVE = TRUE
           AND e.PK_ESTABLECIMIENTO <> p_pk_establecimiento
    ) THEN
        RAISE EXCEPTION 'Ya existe otro establecimiento activo con NIT %', p_nit
            USING ERRCODE = '23505';
    END IF;

    IF p_codigo IS NOT NULL AND EXISTS (
        SELECT 1 FROM pigse.TESTABLECIMIENTO e
         WHERE e.CODIGO = TRIM(p_codigo) AND e.ACTIVE = TRUE
           AND e.PK_ESTABLECIMIENTO <> p_pk_establecimiento
    ) THEN
        RAISE EXCEPTION 'Ya existe otro establecimiento activo con CODIGO %', p_codigo
            USING ERRCODE = '23505';
    END IF;

    IF p_fk_tmunicipio IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TMUNICIPIO m
                        WHERE m.PK_TMUNICIPIO = p_fk_tmunicipio) THEN
        RAISE EXCEPTION 'El municipio (%) no existe', p_fk_tmunicipio USING ERRCODE = '23503';
    END IF;

    IF p_fk_tpropiedad_juridica IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TPROPIEDAD_JURIDICA pj
                        WHERE pj.PK_PROPIEDAD_JURIDICA = p_fk_tpropiedad_juridica
                          AND pj.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'La propiedad juridica (%) no existe o no esta activa', p_fk_tpropiedad_juridica
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlista_valor_zona IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TLISTA_VALOR lv
                        WHERE lv.PK_LISTA_VALOR = p_fk_tlista_valor_zona
                          AND lv.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'La zona (%) no existe o no esta activa en TLISTA_VALOR', p_fk_tlista_valor_zona
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tfuncionario_rector IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TFUNCIONARIO f
                        WHERE f.PK_TFUNCIONARIO = p_fk_tfuncionario_rector) THEN
        RAISE EXCEPTION 'El funcionario rector (%) no existe', p_fk_tfuncionario_rector
            USING ERRCODE = '23503';
    END IF;
    IF p_fk_tfuncionario_secretaria IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TFUNCIONARIO f
                        WHERE f.PK_TFUNCIONARIO = p_fk_tfuncionario_secretaria) THEN
        RAISE EXCEPTION 'El funcionario secretaria (%) no existe', p_fk_tfuncionario_secretaria
            USING ERRCODE = '23503';
    END IF;

    UPDATE pigse.TESTABLECIMIENTO
       SET NOMBRE                 = COALESCE(TRIM(p_nombre), NOMBRE),
           NIT                    = COALESCE(TRIM(p_nit), NIT),
           CODIGO                 = COALESCE(TRIM(p_codigo), CODIGO),
           FK_TMUNICIPIO          = COALESCE(p_fk_tmunicipio, FK_TMUNICIPIO),
           FK_TPROPIEDAD_JURIDICA = COALESCE(p_fk_tpropiedad_juridica, FK_TPROPIEDAD_JURIDICA),
           DIRECCION              = COALESCE(p_direccion, DIRECCION),
           TELEFONO               = COALESCE(p_telefono, TELEFONO),
           CORREO_ELECTRONICO     = COALESCE(p_correo_electronico, CORREO_ELECTRONICO),
           FK_TLISTA_VALOR_ZONA   = COALESCE(p_fk_tlista_valor_zona, FK_TLISTA_VALOR_ZONA),
           FK_TFUNCIONARIO_RECTOR     = COALESCE(p_fk_tfuncionario_rector, FK_TFUNCIONARIO_RECTOR),
           FK_TFUNCIONARIO_SECRETARIA = COALESCE(p_fk_tfuncionario_secretaria, FK_TFUNCIONARIO_SECRETARIA),
           MODIFIED_BY            = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT            = CURRENT_TIMESTAMP
     WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;

    IF p_fk_tfuncionario_rector IS NOT NULL THEN
        UPDATE pigse.TFUNCIONARIO
           SET FK_TESTABLECIMIENTO = p_pk_establecimiento,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TFUNCIONARIO = p_fk_tfuncionario_rector
           AND FK_TESTABLECIMIENTO IS NULL;
    END IF;
    IF p_fk_tfuncionario_secretaria IS NOT NULL THEN
        UPDATE pigse.TFUNCIONARIO
           SET FK_TESTABLECIMIENTO = p_pk_establecimiento,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TFUNCIONARIO = p_fk_tfuncionario_secretaria
           AND FK_TESTABLECIMIENTO IS NULL;
    END IF;

    IF p_fk_ente IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM pigse.TENTE e
                        WHERE e.PK_ENTE = p_fk_ente AND e.ACTIVE = TRUE) THEN
            RAISE EXCEPTION 'El ente territorial (%) no existe o no esta activo', p_fk_ente
                USING ERRCODE = '23503';
        END IF;

        UPDATE pigse.TENTE_ESTABLECIMIENTO
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TESTABLECIMIENTO = p_pk_establecimiento
           AND FK_TENTE <> p_fk_ente
           AND ACTIVE = TRUE;

        INSERT INTO pigse.TENTE_ESTABLECIMIENTO (
            FK_TENTE, FK_TESTABLECIMIENTO, CREATED_BY, CREATED_AT, ACTIVE
        )
        SELECT p_fk_ente, p_pk_establecimiento, p_pk_usuario_solicitante::VARCHAR,
               CURRENT_TIMESTAMP, TRUE
         WHERE NOT EXISTS (
            SELECT 1 FROM pigse.TENTE_ESTABLECIMIENTO te
             WHERE te.FK_TENTE = p_fk_ente
               AND te.FK_TESTABLECIMIENTO = p_pk_establecimiento
               AND te.ACTIVE = TRUE
         );
    END IF;

    RETURN TRUE;
END;
$$;

COMMENT ON FUNCTION pigse.fn_est_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, VARCHAR, BIGINT, BIGINT, VARCHAR, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT)
    IS 'V362: agrega pigse.fn_audit_declarar antes del UPDATE (arranque de cobertura de auditoria por establecimiento). Sin cambios de firma ni de logica de negocio frente a V360.';

-- ---------------------------------------------------------------------------
-- 5. role_query: CEVAL-RECTOR / PIGSE-RECTOR contra las queries de
--    auditoria de su propio microservicio -- hoy sin ningun bind (V87/V358
--    solo cubrieron los roles de fiscalizacion, no de operacion).
-- ---------------------------------------------------------------------------
INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  CROSS JOIN public.role r
 WHERE q.microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse-cval')
   AND r.name = 'CEVAL-RECTOR'
ON CONFLICT DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  CROSS JOIN public.role r
 WHERE q.microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse-pigse')
   AND r.name = 'PIGSE-RECTOR'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 6. Filtro de fila en las 4 queries que leen audit_log por
--    tabla/sesion (las 2 que quedan de auditoria a nivel de sesion --
--    audits/query, audits/stats -- leen tsesion_web, sin nocion de
--    establecimiento, y quedan fuera de alcance).
--
--    Patron agregado al final del WHERE existente:
--      AND ( <rol-de-fiscalizacion-ve-todo> OR <fila-es-de-mi-EE> )
--    Con delimitadores de coma a ambos lados de :CONTEXT.ROLES para
--    evitar falsos positivos por substring (p.ej. "ADMIN" adentro de
--    "SUPER_ADMINISTRADOR").
-- ---------------------------------------------------------------------------

-- 6.1 — /audit-tables/:SLUG/operations/query (CEVAL)
UPDATE public.query
SET query = 'SELECT
    concat(toString(lsn), ''-'', toString(seq)) AS id,
    CASE operacion WHEN ''c'' THEN ''INSERT'' WHEN ''u'' THEN ''UPDATE'' WHEN ''d'' THEN ''DELETE'' ELSE ''SNAPSHOT'' END AS operation,
    app_user AS authorName,
    NULL AS authorAvatarUrl,
    false AS authorVerified,
    toString(client_ip) AS ip,
    etiqueta AS entityName,
    pk AS entityId,
    ts AS occurredAt,
    fila_new_raw AS entityFieldsRaw,
    count() OVER() AS totalCount
FROM auditoria.audit_log
WHERE tabla = concat(''academico_test.t'', substring(lower(replaceRegexpAll(substring(:PARAM.SLUG, 2), ''([A-Z])'', ''_\1'')), 2))
  AND operacion != ''r''
  AND (coalesce(:BODY.FILTERS.AUTHOR, '''') = '''' OR positionCaseInsensitive(app_user, :BODY.FILTERS.AUTHOR) > 0
                                   OR positionCaseInsensitive(toString(client_ip), :BODY.FILTERS.AUTHOR) > 0)
  AND (coalesce(:BODY.FILTERS.OPERATIONCH, '''') = '''' OR operacion = :BODY.FILTERS.OPERATIONCH)
  AND ts >= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDFROM = '''', ''1970-01-01'', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDTO = '''', ''2999-12-31'', :BODY.FILTERS.OCCURREDTO))
  AND (
      position(concat('','', :CONTEXT.ROLES, '',''), '',CEVAL-SUPER_ADMINISTRADOR,'') > 0
      OR (:CONTEXT.ESTABLISHMENT != '''' AND JSONExtractString(contexto, ''establecimiento'') = :CONTEXT.ESTABLISHMENT)
  )
ORDER BY ts DESC
LIMIT 100;',
    detail = 'V362 — audit-tables/{slug}/operations/query (CEVAL): agrega filtro de fila -- super-admin ve todo, CEVAL-RECTOR solo su establecimiento (comparado contra contexto.establecimiento, ver V66/V362).'
WHERE path_template = '/audit-tables/:SLUG/operations/query'
  AND http_method = 'POST'
  AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse-cval');

-- 6.2 — /audit-tables/:SLUG/operations/query (PIGSE)
UPDATE public.query
SET query = 'SELECT
    concat(toString(lsn), ''-'', toString(seq)) AS id,
    CASE operacion WHEN ''c'' THEN ''INSERT'' WHEN ''u'' THEN ''UPDATE'' WHEN ''d'' THEN ''DELETE'' ELSE ''SNAPSHOT'' END AS operation,
    app_user AS authorName,
    NULL AS authorAvatarUrl,
    false AS authorVerified,
    toString(client_ip) AS ip,
    etiqueta AS entityName,
    pk AS entityId,
    ts AS occurredAt,
    fila_new_raw AS entityFieldsRaw,
    count() OVER() AS totalCount
FROM auditoria.audit_log
WHERE tabla = concat(''pigse.t'', substring(lower(replaceRegexpAll(substring(:PARAM.SLUG, 2), ''([A-Z])'', ''_\1'')), 2))
  AND operacion != ''r''
  AND (coalesce(:BODY.FILTERS.AUTHOR, '''') = '''' OR positionCaseInsensitive(app_user, :BODY.FILTERS.AUTHOR) > 0
                                   OR positionCaseInsensitive(toString(client_ip), :BODY.FILTERS.AUTHOR) > 0)
  AND (coalesce(:BODY.FILTERS.OPERATIONCH, '''') = '''' OR operacion = :BODY.FILTERS.OPERATIONCH)
  AND ts >= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDFROM = '''', ''1970-01-01'', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDTO = '''', ''2999-12-31'', :BODY.FILTERS.OCCURREDTO))
  AND (
      position(concat('','', :CONTEXT.ROLES, '',''), '',PIGSE-ADMINISTRADOR,'') > 0
      OR position(concat('','', :CONTEXT.ROLES, '',''), '',PIGSE-SECRETARIA_TERRITORIAL,'') > 0
      OR (:CONTEXT.ESTABLISHMENT != '''' AND JSONExtractString(contexto, ''establecimiento'') = :CONTEXT.ESTABLISHMENT)
  )
ORDER BY ts DESC
LIMIT 100;',
    detail = 'V362 — audit-tables/{slug}/operations/query (PIGSE): agrega filtro de fila -- PIGSE-ADMINISTRADOR/SECRETARIA_TERRITORIAL ven todo, PIGSE-RECTOR solo su establecimiento. NOTA: pigse nunca declaraba contexto.establecimiento hasta V362 -- filas anteriores a esta migracion no tienen ese dato y no le apareceran a ningun rector.'
WHERE path_template = '/audit-tables/:SLUG/operations/query'
  AND http_method = 'POST'
  AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse-pigse');

-- 6.3 — /audits/sessions/:SESSIONID/operations (CEVAL)
UPDATE public.query
SET query = 'SELECT
    concat(toString(lsn), ''-'', toString(seq)) AS id,
    tabla AS tableSlug,
    CASE operacion WHEN ''c'' THEN ''INSERT'' WHEN ''u'' THEN ''UPDATE'' WHEN ''d'' THEN ''DELETE'' ELSE ''SNAPSHOT'' END AS operation,
    etiqueta AS entityName,
    pk AS entityId,
    ts AS occurredAt,
    count() OVER() AS totalCount
FROM auditoria.audit_log
WHERE sesion_id = :PARAM.SESSIONID
  AND operacion != ''r''
  AND tabla LIKE ''academico_test.%''
  AND (coalesce(:BODY.FILTERS.TABLESLUG, '''') = '''' OR tabla = :BODY.FILTERS.TABLESLUG)
  AND (coalesce(:BODY.FILTERS.OPERATIONCH, '''') = '''' OR operacion = :BODY.FILTERS.OPERATIONCH)
  AND ts >= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDFROM = '''', ''1970-01-01'', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDTO = '''', ''2999-12-31'', :BODY.FILTERS.OCCURREDTO))
  AND (
      position(concat('','', :CONTEXT.ROLES, '',''), '',CEVAL-SUPER_ADMINISTRADOR,'') > 0
      OR (:CONTEXT.ESTABLISHMENT != '''' AND JSONExtractString(contexto, ''establecimiento'') = :CONTEXT.ESTABLISHMENT)
  )
ORDER BY ts DESC
LIMIT 100;',
    detail = 'V362 — audits/sessions/{sessionId}/operations (CEVAL): mismo filtro de fila que 6.1.'
WHERE path_template = '/audits/sessions/:SESSIONID/operations'
  AND http_method = 'POST'
  AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse-cval');

-- 6.4 — /audits/sessions/:SESSIONID/operations (PIGSE)
UPDATE public.query
SET query = 'SELECT
    concat(toString(lsn), ''-'', toString(seq)) AS id,
    tabla AS tableSlug,
    CASE operacion WHEN ''c'' THEN ''INSERT'' WHEN ''u'' THEN ''UPDATE'' WHEN ''d'' THEN ''DELETE'' ELSE ''SNAPSHOT'' END AS operation,
    etiqueta AS entityName,
    pk AS entityId,
    ts AS occurredAt,
    count() OVER() AS totalCount
FROM auditoria.audit_log
WHERE sesion_id = :PARAM.SESSIONID
  AND operacion != ''r''
  AND tabla LIKE ''pigse.%''
  AND (coalesce(:BODY.FILTERS.TABLESLUG, '''') = '''' OR tabla = :BODY.FILTERS.TABLESLUG)
  AND (coalesce(:BODY.FILTERS.OPERATIONCH, '''') = '''' OR operacion = :BODY.FILTERS.OPERATIONCH)
  AND ts >= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDFROM = '''', ''1970-01-01'', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDTO = '''', ''2999-12-31'', :BODY.FILTERS.OCCURREDTO))
  AND (
      position(concat('','', :CONTEXT.ROLES, '',''), '',PIGSE-ADMINISTRADOR,'') > 0
      OR position(concat('','', :CONTEXT.ROLES, '',''), '',PIGSE-SECRETARIA_TERRITORIAL,'') > 0
      OR (:CONTEXT.ESTABLISHMENT != '''' AND JSONExtractString(contexto, ''establecimiento'') = :CONTEXT.ESTABLISHMENT)
  )
ORDER BY ts DESC
LIMIT 100;',
    detail = 'V362 — audits/sessions/{sessionId}/operations (PIGSE): mismo filtro de fila que 6.2.'
WHERE path_template = '/audits/sessions/:SESSIONID/operations'
  AND http_method = 'POST'
  AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse-pigse');

-- ---------------------------------------------------------------------------
-- 7. Verificacion
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_ceval_rector_binds BIGINT;
    v_pigse_rector_binds BIGINT;
    v_filtered_queries   BIGINT;
BEGIN
    SELECT count(*) INTO v_ceval_rector_binds
      FROM public.role_query rq
      JOIN public.role r ON r.id_role = rq.role_id
      JOIN public.query q ON q.id_query = rq.query_id
     WHERE r.name = 'CEVAL-RECTOR'
       AND q.microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse-cval');

    SELECT count(*) INTO v_pigse_rector_binds
      FROM public.role_query rq
      JOIN public.role r ON r.id_role = rq.role_id
      JOIN public.query q ON q.id_query = rq.query_id
     WHERE r.name = 'PIGSE-RECTOR'
       AND q.microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse-pigse');

    SELECT count(*) INTO v_filtered_queries
      FROM public.query
     WHERE path_template IN ('/audit-tables/:SLUG/operations/query', '/audits/sessions/:SESSIONID/operations')
       AND http_method = 'POST'
       AND query LIKE '%CONTEXT.ESTABLISHMENT%';

    RAISE NOTICE 'V362: CEVAL-RECTOR bind a % queries de audit-clickhouse-cval', v_ceval_rector_binds;
    RAISE NOTICE 'V362: PIGSE-RECTOR bind a % queries de audit-clickhouse-pigse', v_pigse_rector_binds;
    RAISE NOTICE 'V362: % queries con filtro de establecimiento (esperado 4)', v_filtered_queries;

    -- WARNING, no EXCEPTION -- mismo criterio que V284/V305 con este
    -- mismo rol: el ambiente donde corre flyway (CI, un entorno nuevo
    -- sin seed completo de roles) puede no tener 'CEVAL-RECTOR'/
    -- 'PIGSE-RECTOR' creados todavia -- el CROSS JOIN de la sección 5
    -- simplemente no aporta filas en ese caso, no es un error de esta
    -- migración. Bloquear el deploy entero por un rol ausente en un
    -- ambiente de prueba sería peor que dejarlo pasar con un aviso.
    IF v_ceval_rector_binds = 0 THEN
        RAISE WARNING 'V362: CEVAL-RECTOR quedo sin ningun bind a audit-clickhouse-cval. Revisa que el rol exista con ese nombre exacto en public.role.';
    END IF;
    IF v_pigse_rector_binds = 0 THEN
        RAISE WARNING 'V362: PIGSE-RECTOR quedo sin ningun bind a audit-clickhouse-pigse. Revisa que el rol exista con ese nombre exacto en public.role.';
    END IF;
    IF v_filtered_queries != 4 THEN
        RAISE EXCEPTION 'V362 fallo: se esperaban 4 queries con filtro de establecimiento, se encontraron %', v_filtered_queries;
    END IF;

    IF to_regprocedure('academico_test.fn_mi_establecimiento_para_auditoria(bigint)') IS NULL THEN
        RAISE EXCEPTION 'V362 fallo: academico_test.fn_mi_establecimiento_para_auditoria no quedo registrada';
    END IF;
    IF to_regprocedure('pigse.fn_mi_establecimiento_para_auditoria(bigint)') IS NULL THEN
        RAISE EXCEPTION 'V362 fallo: pigse.fn_mi_establecimiento_para_auditoria no quedo registrada';
    END IF;
    IF to_regprocedure('pigse.fn_audit_declarar(bigint,text,bigint,text[])') IS NULL THEN
        RAISE EXCEPTION 'V362 fallo: pigse.fn_audit_declarar no quedo registrada';
    END IF;

    RAISE NOTICE 'V362 OK';
END $$;
