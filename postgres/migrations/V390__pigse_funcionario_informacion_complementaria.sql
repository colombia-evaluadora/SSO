-- ============================================================================
-- V390 — varios arreglos consolidados en Funcionarios, encontrados en vivo
-- probando PIGSE de punta a punta:
--
-- 1. POST /funcionarios (crear) estaba ROTO: el catalogo llama
--    pigse.fn_fun_crear(...) con 12 argumentos posicionales (incluye
--    BODY.FK_ID_ROLE al final), pero la funcion real solo acepta 11 -- un
--    desajuste real de firma ("function does not exist"). Se revierte el
--    catalogo a los 11 argumentos que la funcion SI acepta (asignar rol es
--    tarea de fn_fun_permisos_actualizar, no de la creacion -- V370 ya
--    documenta por que).
--
-- 2. Los binds multi-palabra de POST /funcionarios y PUT /funcionarios/:ID
--    se declararon con guion bajo (BODY.FK_ESTABLECIMIENTO) pero el front
--    manda JSON camelCase (fkEstablecimiento) y query-service normaliza a
--    MAYUSCULAS SIN insertar guion bajo (fkEstablecimiento -> FKESTABLECIMIENTO,
--    no FK_ESTABLECIMIENTO) -- mismo bug de sedes (V388), aca en funcionarios.
--    Se renombran todos los binds multi-palabra a la forma sin guion bajo.
--
-- 3. Decision de producto: el establecimiento y el cargo de un funcionario
--    YA NO se piden a mano en el formulario (como en CEVAL, que tampoco los
--    pide pese a tener las mismas columnas) -- el establecimiento se DERIVA
--    de la sede la primera vez que se le asigna un permiso
--    (fn_fun_permisos_actualizar ahora sincroniza TFUNCIONARIO.FK_TESTABLECIMIENTO
--    con la sede recien asignada en cada 'crear'), y el cargo lo cubre el
--    rol que ya se asigna via permisos. fn_fun_crear pasa p_fk_establecimiento
--    a opcional (un funcionario puede nacer sin establecimiento hasta que se
--    le asigna la primera sede).
--
-- 4. "Informacion complementaria" (CEVAL: form-employee-additional-info.tsx,
--    8 campos) nunca se termino de portar a PIGSE -- P2 de la auditoria de
--    paridad. Los catalogos YA estaban sembrados en pigse.TLISTA_VALOR
--    (CLASE_FUNCIONARIO, NIVEL_ENSENANZA, ESCALAFON, ULT_NIVEL,
--    FUENTE_DE_RECURSO, NOMBRE_CARGO, TIPO_VINCULACION) y el endpoint
--    generico GET /select/:CATEGORIA ya los sirve sin cambios -- solo
--    faltaban las columnas en pigse.TFUNCIONARIO y los binds en
--    fn_fun_actualizar/fn_fun_buscar_por_pk. "Cargo funcional" (categoria
--    NOMBRE_CARGO) es un catalogo DISTINTO del FK_TLV_CARGO ya existente
--    (categoria CARGO, el que alimentaba el combo "Cargo" que este mismo
--    commit saca del formulario principal porque "el cargo es el rol") --
--    por eso se agrega una columna nueva en vez de reusar esa.
-- ============================================================================

ALTER TABLE pigse.TFUNCIONARIO
    ADD COLUMN IF NOT EXISTS FK_TLV_CLASE_FUNCIONARIO bigint,
    ADD COLUMN IF NOT EXISTS FK_TLV_NIVEL_ENSENANZA bigint,
    ADD COLUMN IF NOT EXISTS FK_TLV_GRADO_ESCALAFON bigint,
    ADD COLUMN IF NOT EXISTS FK_TLV_NIVEL_EDUCATIVO bigint,
    ADD COLUMN IF NOT EXISTS FK_TLV_FUENTE_RECURSO bigint,
    ADD COLUMN IF NOT EXISTS FK_TLV_CARGO_FUNCIONAL bigint,
    ADD COLUMN IF NOT EXISTS DIRECCION character varying(130);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pigse_tfuncionario_clase') THEN
        ALTER TABLE pigse.TFUNCIONARIO ADD CONSTRAINT fk_pigse_tfuncionario_clase
            FOREIGN KEY (FK_TLV_CLASE_FUNCIONARIO) REFERENCES pigse.TLISTA_VALOR(PK_LISTA_VALOR);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pigse_tfuncionario_nivel_ens') THEN
        ALTER TABLE pigse.TFUNCIONARIO ADD CONSTRAINT fk_pigse_tfuncionario_nivel_ens
            FOREIGN KEY (FK_TLV_NIVEL_ENSENANZA) REFERENCES pigse.TLISTA_VALOR(PK_LISTA_VALOR);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pigse_tfuncionario_escalafon') THEN
        ALTER TABLE pigse.TFUNCIONARIO ADD CONSTRAINT fk_pigse_tfuncionario_escalafon
            FOREIGN KEY (FK_TLV_GRADO_ESCALAFON) REFERENCES pigse.TLISTA_VALOR(PK_LISTA_VALOR);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pigse_tfuncionario_nivel_edu') THEN
        ALTER TABLE pigse.TFUNCIONARIO ADD CONSTRAINT fk_pigse_tfuncionario_nivel_edu
            FOREIGN KEY (FK_TLV_NIVEL_EDUCATIVO) REFERENCES pigse.TLISTA_VALOR(PK_LISTA_VALOR);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pigse_tfuncionario_fuente') THEN
        ALTER TABLE pigse.TFUNCIONARIO ADD CONSTRAINT fk_pigse_tfuncionario_fuente
            FOREIGN KEY (FK_TLV_FUENTE_RECURSO) REFERENCES pigse.TLISTA_VALOR(PK_LISTA_VALOR);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pigse_tfuncionario_cargo_func') THEN
        ALTER TABLE pigse.TFUNCIONARIO ADD CONSTRAINT fk_pigse_tfuncionario_cargo_func
            FOREIGN KEY (FK_TLV_CARGO_FUNCIONAL) REFERENCES pigse.TLISTA_VALOR(PK_LISTA_VALOR);
    END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 1/3. fn_fun_crear: p_fk_establecimiento pasa a opcional (al final, con
-- DEFAULT NULL) -- Postgres exige que los params con default vayan despues
-- de los que no lo tienen, así que se reordena.
-- ----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS pigse.fn_fun_crear(bigint, bigint, character varying, character varying, character varying, character varying, character varying, character varying, character varying, bigint, bigint);

CREATE OR REPLACE FUNCTION pigse.fn_fun_crear(
    p_pk_usuario_solicitante bigint,
    p_correo_electronico character varying,
    p_identificacion character varying,
    p_primer_nombre character varying,
    p_primer_apellido character varying,
    p_segundo_nombre character varying DEFAULT NULL::character varying,
    p_segundo_apellido character varying DEFAULT NULL::character varying,
    p_telefono character varying DEFAULT NULL::character varying,
    p_fk_tlv_tipo_documento bigint DEFAULT NULL::bigint,
    p_fk_tlv_cargo bigint DEFAULT NULL::bigint,
    p_fk_establecimiento bigint DEFAULT NULL::bigint
)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'pigse', 'public'
AS $function$
DECLARE
    v_pk_usuario BIGINT;
    v_pk_funcionario BIGINT;
BEGIN
    PERFORM pigse.fn_assert_permiso_funcionario(p_pk_usuario_solicitante, 'CREAR', NULL);

    IF p_fk_establecimiento IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TESTABLECIMIENTO WHERE PK_ESTABLECIMIENTO = p_fk_establecimiento AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El establecimiento (%) no existe o no esta activo', p_fk_establecimiento USING ERRCODE = '23503';
    END IF;

    IF EXISTS (SELECT 1 FROM pigse.TUSUARIO WHERE UPPER(CORREO_ELECTRONICO) = UPPER(TRIM(p_correo_electronico)) AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'Ya existe otro usuario activo con el correo %', p_correo_electronico USING ERRCODE = '23505';
    END IF;

    INSERT INTO pigse.TUSUARIO (
        CORREO_ELECTRONICO, IDENTIFICACION, FK_TLV_TIPO_DOCUMENTO,
        PRIMER_NOMBRE, SEGUNDO_NOMBRE, PRIMER_APELLIDO, SEGUNDO_APELLIDO, TELEFONO,
        CREATED_BY
    ) VALUES (
        TRIM(p_correo_electronico), TRIM(p_identificacion), p_fk_tlv_tipo_documento,
        TRIM(p_primer_nombre), p_segundo_nombre, TRIM(p_primer_apellido), p_segundo_apellido, p_telefono,
        p_pk_usuario_solicitante::VARCHAR
    ) RETURNING PK_TUSUARIO INTO v_pk_usuario;

    INSERT INTO pigse.TFUNCIONARIO (FK_TUSUARIO, FK_TESTABLECIMIENTO, FK_TLV_CARGO, CREATED_BY)
    VALUES (v_pk_usuario, p_fk_establecimiento, p_fk_tlv_cargo, p_pk_usuario_solicitante::VARCHAR)
    RETURNING PK_TFUNCIONARIO INTO v_pk_funcionario;

    RETURN v_pk_funcionario;
END;
$function$;

UPDATE public.query q
   SET query = $Q$SELECT pigse.fn_fun_crear(
    public.fn_get_pigse_usuario_id(CAST(:CONTEXT.USER_ID AS BIGINT)),
    CAST(:BODY.CORREOELECTRONICO AS VARCHAR),
    CAST(:BODY.IDENTIFICACION AS VARCHAR),
    CAST(:BODY.PRIMERNOMBRE AS VARCHAR),
    CAST(:BODY.PRIMERAPELLIDO AS VARCHAR),
    CAST(:BODY.SEGUNDONOMBRE AS VARCHAR),
    CAST(:BODY.SEGUNDOAPELLIDO AS VARCHAR),
    CAST(:BODY.TELEFONO AS VARCHAR),
    CAST(:BODY.FKTLVTIPODOCUMENTO AS BIGINT),
    CAST(:BODY.FKTLVCARGO AS BIGINT),
    CAST(:BODY.FKESTABLECIMIENTO AS BIGINT)
) AS pk_funcionario
$Q$,
       param_types = '{"BODY.TELEFONO": "VARCHAR", "BODY.PRIMERNOMBRE": "VARCHAR!", "BODY.IDENTIFICACION": "VARCHAR!", "BODY.SEGUNDONOMBRE": "VARCHAR", "BODY.PRIMERAPELLIDO": "VARCHAR!", "BODY.SEGUNDOAPELLIDO": "VARCHAR", "BODY.CORREOELECTRONICO": "VARCHAR!", "BODY.FKESTABLECIMIENTO": "BIGINT", "BODY.FKTLVTIPODOCUMENTO": "BIGINT", "BODY.FKTLVCARGO": "BIGINT"}'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid = 'pigse'
   AND q.path_template = '/funcionarios'
   AND q.http_method = 'POST';

-- ----------------------------------------------------------------------------
-- 2/4. fn_fun_actualizar: informacion complementaria + nombres de bind sin
-- guion bajo.
-- ----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS pigse.fn_fun_actualizar(bigint, bigint, character varying, character varying, character varying, character varying, character varying, character varying, character varying, bigint, bigint, bigint);

CREATE OR REPLACE FUNCTION pigse.fn_fun_actualizar(
    p_pk_usuario_solicitante bigint,
    p_pk_funcionario bigint,
    p_correo_electronico character varying DEFAULT NULL::character varying,
    p_identificacion character varying DEFAULT NULL::character varying,
    p_primer_nombre character varying DEFAULT NULL::character varying,
    p_segundo_nombre character varying DEFAULT NULL::character varying,
    p_primer_apellido character varying DEFAULT NULL::character varying,
    p_segundo_apellido character varying DEFAULT NULL::character varying,
    p_telefono character varying DEFAULT NULL::character varying,
    p_fk_tlv_tipo_documento bigint DEFAULT NULL::bigint,
    p_fk_tlv_cargo bigint DEFAULT NULL::bigint,
    p_fk_establecimiento bigint DEFAULT NULL::bigint,
    p_fk_tlv_clase_funcionario bigint DEFAULT NULL::bigint,
    p_fk_tlv_nivel_ensenanza bigint DEFAULT NULL::bigint,
    p_fk_tlv_grado_escalafon bigint DEFAULT NULL::bigint,
    p_fk_tlv_nivel_educativo bigint DEFAULT NULL::bigint,
    p_fk_tlv_fuente_recurso bigint DEFAULT NULL::bigint,
    p_fk_tlv_tipo_vinculacion bigint DEFAULT NULL::bigint,
    p_fk_tlv_cargo_funcional bigint DEFAULT NULL::bigint,
    p_direccion character varying DEFAULT NULL::character varying
)
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO 'pigse', 'public'
AS $function$
DECLARE
    v_pk_usuario BIGINT;
BEGIN
    SELECT f.FK_TUSUARIO INTO v_pk_usuario
      FROM pigse.TFUNCIONARIO f WHERE f.PK_TFUNCIONARIO = p_pk_funcionario AND f.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el funcionario solicitado (%)', p_pk_funcionario USING ERRCODE = 'P0002';
    END IF;

    PERFORM pigse.fn_assert_permiso_funcionario(p_pk_usuario_solicitante, 'EDITAR', p_pk_funcionario);

    IF p_fk_establecimiento IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TESTABLECIMIENTO WHERE PK_ESTABLECIMIENTO = p_fk_establecimiento AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El establecimiento (%) no existe o no esta activo', p_fk_establecimiento USING ERRCODE = '23503';
    END IF;

    IF p_correo_electronico IS NOT NULL AND EXISTS (
        SELECT 1 FROM pigse.TUSUARIO WHERE UPPER(CORREO_ELECTRONICO) = UPPER(TRIM(p_correo_electronico)) AND ACTIVE = TRUE AND PK_TUSUARIO <> v_pk_usuario
    ) THEN
        RAISE EXCEPTION 'Ya existe otro usuario activo con el correo %', p_correo_electronico USING ERRCODE = '23505';
    END IF;

    UPDATE pigse.TUSUARIO
       SET CORREO_ELECTRONICO = COALESCE(TRIM(p_correo_electronico), CORREO_ELECTRONICO),
           IDENTIFICACION     = COALESCE(TRIM(p_identificacion), IDENTIFICACION),
           FK_TLV_TIPO_DOCUMENTO = COALESCE(p_fk_tlv_tipo_documento, FK_TLV_TIPO_DOCUMENTO),
           PRIMER_NOMBRE      = COALESCE(TRIM(p_primer_nombre), PRIMER_NOMBRE),
           SEGUNDO_NOMBRE     = COALESCE(p_segundo_nombre, SEGUNDO_NOMBRE),
           PRIMER_APELLIDO    = COALESCE(TRIM(p_primer_apellido), PRIMER_APELLIDO),
           SEGUNDO_APELLIDO   = COALESCE(p_segundo_apellido, SEGUNDO_APELLIDO),
           TELEFONO           = COALESCE(p_telefono, TELEFONO),
           MODIFIED_BY        = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TUSUARIO = v_pk_usuario;

    UPDATE pigse.TFUNCIONARIO
       SET FK_TESTABLECIMIENTO     = COALESCE(p_fk_establecimiento, FK_TESTABLECIMIENTO),
           FK_TLV_CARGO            = COALESCE(p_fk_tlv_cargo, FK_TLV_CARGO),
           FK_TLV_CLASE_FUNCIONARIO = COALESCE(p_fk_tlv_clase_funcionario, FK_TLV_CLASE_FUNCIONARIO),
           FK_TLV_NIVEL_ENSENANZA  = COALESCE(p_fk_tlv_nivel_ensenanza, FK_TLV_NIVEL_ENSENANZA),
           FK_TLV_GRADO_ESCALAFON  = COALESCE(p_fk_tlv_grado_escalafon, FK_TLV_GRADO_ESCALAFON),
           FK_TLV_NIVEL_EDUCATIVO  = COALESCE(p_fk_tlv_nivel_educativo, FK_TLV_NIVEL_EDUCATIVO),
           FK_TLV_FUENTE_RECURSO   = COALESCE(p_fk_tlv_fuente_recurso, FK_TLV_FUENTE_RECURSO),
           FK_TLV_TIPO_VINCULACION = COALESCE(p_fk_tlv_tipo_vinculacion, FK_TLV_TIPO_VINCULACION),
           FK_TLV_CARGO_FUNCIONAL = COALESCE(p_fk_tlv_cargo_funcional, FK_TLV_CARGO_FUNCIONAL),
           DIRECCION               = COALESCE(p_direccion, DIRECCION),
           MODIFIED_BY             = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TFUNCIONARIO = p_pk_funcionario;

    RETURN TRUE;
END;
$function$;

UPDATE public.query q
   SET query = $Q$SELECT pigse.fn_fun_actualizar(
    public.fn_get_pigse_usuario_id(CAST(:CONTEXT.USER_ID AS BIGINT)),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.CORREOELECTRONICO AS VARCHAR),
    CAST(:BODY.IDENTIFICACION AS VARCHAR),
    CAST(:BODY.PRIMERNOMBRE AS VARCHAR),
    CAST(:BODY.SEGUNDONOMBRE AS VARCHAR),
    CAST(:BODY.PRIMERAPELLIDO AS VARCHAR),
    CAST(:BODY.SEGUNDOAPELLIDO AS VARCHAR),
    CAST(:BODY.TELEFONO AS VARCHAR),
    CAST(:BODY.FKTLVTIPODOCUMENTO AS BIGINT),
    CAST(:BODY.FKTLVCARGO AS BIGINT),
    CAST(:BODY.FKESTABLECIMIENTO AS BIGINT),
    CAST(:BODY.FKTLVCLASEFUNCIONARIO AS BIGINT),
    CAST(:BODY.FKTLVNIVELENSENANZA AS BIGINT),
    CAST(:BODY.FKTLVGRADOESCALAFON AS BIGINT),
    CAST(:BODY.FKTLVNIVELEDUCATIVO AS BIGINT),
    CAST(:BODY.FKTLVFUENTERECURSO AS BIGINT),
    CAST(:BODY.FKTLVTIPOVINCULACION AS BIGINT),
    CAST(:BODY.FKTLVCARGOFUNCIONAL AS BIGINT),
    CAST(:BODY.DIRECCION AS VARCHAR)
) AS actualizado
$Q$,
       param_types = '{"PARAM.ID": "BIGINT!", "BODY.TELEFONO": "VARCHAR", "BODY.FKTLVCARGO": "BIGINT", "BODY.PRIMERNOMBRE": "VARCHAR", "BODY.IDENTIFICACION": "VARCHAR", "BODY.SEGUNDONOMBRE": "VARCHAR", "BODY.PRIMERAPELLIDO": "VARCHAR", "BODY.SEGUNDOAPELLIDO": "VARCHAR", "BODY.CORREOELECTRONICO": "VARCHAR", "BODY.FKESTABLECIMIENTO": "BIGINT", "BODY.FKTLVTIPODOCUMENTO": "BIGINT", "BODY.FKTLVCLASEFUNCIONARIO": "BIGINT", "BODY.FKTLVNIVELENSENANZA": "BIGINT", "BODY.FKTLVGRADOESCALAFON": "BIGINT", "BODY.FKTLVNIVELEDUCATIVO": "BIGINT", "BODY.FKTLVFUENTERECURSO": "BIGINT", "BODY.FKTLVTIPOVINCULACION": "BIGINT", "BODY.FKTLVCARGOFUNCIONAL": "BIGINT", "BODY.DIRECCION": "VARCHAR"}'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid = 'pigse'
   AND q.path_template = '/funcionarios/:ID'
   AND q.http_method = 'PUT';

-- ----------------------------------------------------------------------------
-- 3/4. fn_fun_buscar_por_pk: informacion complementaria en la salida.
-- ----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS pigse.fn_fun_buscar_por_pk(bigint, bigint);

CREATE OR REPLACE FUNCTION pigse.fn_fun_buscar_por_pk(p_pk_usuario_solicitante bigint, p_pk_funcionario bigint)
 RETURNS TABLE(
    pk_funcionario bigint, pk_usuario bigint, fk_id_user bigint,
    identificacion character varying, fk_tlv_tipo_documento bigint,
    primer_nombre character varying, segundo_nombre character varying,
    primer_apellido character varying, segundo_apellido character varying,
    correo_electronico character varying, telefono character varying,
    fk_establecimiento bigint, establecimiento_nombre character varying,
    fk_tlv_cargo bigint, permisos jsonb,
    fk_tlv_clase_funcionario bigint, fk_tlv_nivel_ensenanza bigint,
    fk_tlv_grado_escalafon bigint, fk_tlv_nivel_educativo bigint,
    fk_tlv_fuente_recurso bigint, fk_tlv_tipo_vinculacion bigint,
    fk_tlv_cargo_funcional bigint,
    direccion character varying,
    created_by character varying, created_at timestamp without time zone,
    modified_by character varying, modified_at timestamp without time zone
 )
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pigse', 'public'
AS $function$
DECLARE
    v_active BOOLEAN;
BEGIN
    SELECT f.ACTIVE INTO v_active FROM pigse.TFUNCIONARIO f WHERE f.PK_TFUNCIONARIO = p_pk_funcionario;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el funcionario solicitado (%)', p_pk_funcionario USING ERRCODE = 'P0002';
    END IF;

    PERFORM pigse.fn_assert_permiso_funcionario(p_pk_usuario_solicitante, 'VER', p_pk_funcionario);

    IF v_active = FALSE THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT f.PK_TFUNCIONARIO, u.PK_TUSUARIO, u.FK_ID_USER,
           u.IDENTIFICACION, u.FK_TLV_TIPO_DOCUMENTO,
           u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO,
           u.CORREO_ELECTRONICO, u.TELEFONO,
           f.FK_TESTABLECIMIENTO, e.NOMBRE, f.FK_TLV_CARGO,
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'id', su.PK_TSEDE_USUARIO, 'orden', su.ORDEN,
                          'idRole', r.id_role, 'nombre', r.name,
                          'idSede', s.PK_TSEDE, 'sede', s.NOMBRE,
                          'idJornada', su.FK_TLV_JORNADA, 'jornada', jr.NOMBRE,
                          'estado', su.TLV_ESTADO)
                        ORDER BY su.ORDEN)
                 FROM pigse.TSEDE_USUARIO su
                 JOIN public.role r ON r.id_role = su.FK_ID_ROLE
                 JOIN pigse.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
                 JOIN pigse.TLISTA_VALOR jr ON jr.PK_LISTA_VALOR = su.FK_TLV_JORNADA
                WHERE su.FK_TUSUARIO = u.PK_TUSUARIO AND su.ACTIVE = TRUE
           ), '[]'::JSONB),
           f.FK_TLV_CLASE_FUNCIONARIO, f.FK_TLV_NIVEL_ENSENANZA,
           f.FK_TLV_GRADO_ESCALAFON, f.FK_TLV_NIVEL_EDUCATIVO,
           f.FK_TLV_FUENTE_RECURSO, f.FK_TLV_TIPO_VINCULACION,
           f.FK_TLV_CARGO_FUNCIONAL,
           f.DIRECCION,
           f.CREATED_BY, f.CREATED_AT, f.MODIFIED_BY, f.MODIFIED_AT
      FROM pigse.TFUNCIONARIO f
      JOIN pigse.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
      LEFT JOIN pigse.TESTABLECIMIENTO e ON e.PK_ESTABLECIMIENTO = f.FK_TESTABLECIMIENTO
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario;
END;
$function$;

-- ----------------------------------------------------------------------------
-- 4/4. fn_fun_permisos_actualizar: al crear un permiso, sincroniza
-- TFUNCIONARIO.FK_TESTABLECIMIENTO con el establecimiento de la sede recien
-- asignada -- ya no se pide a mano en el formulario (decision de producto,
-- ver cabecera).
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pigse.fn_fun_permisos_actualizar(p_pk_usuario_solicitante bigint, p_pk_funcionario bigint, p_permisos jsonb)
 RETURNS TABLE(accion character varying, id bigint, status character varying)
 LANGUAGE plpgsql
 SET search_path TO 'pigse', 'public'
AS $function$
DECLARE
    v_pk_usuario    BIGINT;
    v_active_fun    BOOLEAN;
    v_es_super      BOOLEAN;
    v_sedes_plenas  BIGINT[];
    v_sedes_coord   BIGINT[];
    v_perm          RECORD;
    v_fk_sede_op    BIGINT;
    v_fk_rol_op     BIGINT;
BEGIN
    SELECT f.ACTIVE, f.FK_TUSUARIO INTO v_active_fun, v_pk_usuario
      FROM pigse.TFUNCIONARIO f WHERE f.PK_TFUNCIONARIO = p_pk_funcionario;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el funcionario solicitado' USING ERRCODE = 'P0002';
    END IF;
    IF v_active_fun = FALSE THEN
        RAISE EXCEPTION 'El funcionario esta inactivo; no se puede actualizar' USING ERRCODE = '22023';
    END IF;

    PERFORM pigse.fn_assert_permiso_funcionario(p_pk_usuario_solicitante, 'EDITAR', p_pk_funcionario);

    v_es_super := (pigse.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante) <= 1);

    IF p_permisos IS NULL OR jsonb_typeof(p_permisos) <> 'array' THEN
        RAISE EXCEPTION 'p_permisos debe ser un JSON array' USING ERRCODE = '22023';
    END IF;

    IF NOT v_es_super THEN
        SELECT ARRAY(
            SELECT s.PK_TSEDE FROM pigse.TSEDE s
             WHERE s.ACTIVE = TRUE
               AND s.FK_TESTABLECIMIENTO IN (SELECT establecimiento_id FROM pigse.fn_usuario_ee_accesibles(p_pk_usuario_solicitante))
        ) INTO v_sedes_plenas;

        SELECT ARRAY(SELECT DISTINCT sede_id FROM pigse.fn_usuario_sedes_jornadas_accesibles(p_pk_usuario_solicitante))
          INTO v_sedes_coord;
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
        accion := v_perm.accion; id := v_perm.id; status := NULL;

        IF v_perm.accion = 'crear' THEN
            IF v_perm.orden IS NULL OR v_perm.fk_rol IS NULL OR v_perm.fk_sede IS NULL OR v_perm.fk_jornada IS NULL THEN
                status := 'error:faltan_campos_obligatorios'; RETURN NEXT; CONTINUE;
            END IF;

            PERFORM pigse.fn_assert_rango_rol_otorgable(p_pk_usuario_solicitante, v_perm.fk_rol);

            IF NOT v_es_super
               AND NOT (v_perm.fk_sede = ANY(v_sedes_plenas))
               AND NOT (v_perm.fk_sede = ANY(v_sedes_coord) AND pigse.fn_rol_categoria_nivel(v_perm.fk_rol) = 3)
            THEN
                status := 'error:sin_permiso_en_sede'; RETURN NEXT; CONTINUE;
            END IF;

            id := pigse.fn_sede_usuario_crear(
                p_pk_usuario_solicitante, v_perm.fk_sede, v_perm.fk_rol, v_pk_usuario,
                v_perm.orden, v_perm.fk_jornada, v_perm.fk_estado, v_perm.predeterminado
            );

            -- V390: el establecimiento ya no se pide a mano en el
            -- formulario -- se deriva de la sede recien asignada, igual
            -- que CEVAL (que tiene la misma columna pero tampoco la pide).
            UPDATE pigse.TFUNCIONARIO tf
               SET FK_TESTABLECIMIENTO = s.FK_TESTABLECIMIENTO,
                   MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
              FROM pigse.TSEDE s
             WHERE s.PK_TSEDE = v_perm.fk_sede
               AND tf.PK_TFUNCIONARIO = p_pk_funcionario;

            status := 'creado'; RETURN NEXT;

        ELSIF v_perm.accion = 'eliminar' THEN
            IF v_perm.id IS NULL THEN
                status := 'error:falta_id'; RETURN NEXT; CONTINUE;
            END IF;

            SELECT FK_TSEDE, FK_ID_ROLE INTO v_fk_sede_op, v_fk_rol_op
              FROM pigse.TSEDE_USUARIO WHERE PK_TSEDE_USUARIO = v_perm.id;

            IF FOUND AND NOT v_es_super
               AND NOT (v_fk_sede_op = ANY(v_sedes_plenas))
               AND NOT (v_fk_sede_op = ANY(v_sedes_coord) AND pigse.fn_rol_categoria_nivel(v_fk_rol_op) = 3)
            THEN
                status := 'error:sin_permiso_en_sede'; RETURN NEXT; CONTINUE;
            END IF;

            PERFORM pigse.fn_sede_usuario_soft_delete(v_perm.id, p_pk_usuario_solicitante);
            status := 'eliminado'; RETURN NEXT;
        ELSE
            status := 'sin_cambios'; RETURN NEXT;
        END IF;
    END LOOP;
END;
$function$;

DO $$
DECLARE
    v_ok BOOLEAN;
BEGIN
    SELECT (
        (SELECT count(*) FROM pg_proc WHERE proname = 'fn_fun_crear' AND pronamespace = 'pigse'::regnamespace) = 1
        AND (SELECT q.param_types ? 'BODY.FKESTABLECIMIENTO' AND NOT (q.param_types ? 'BODY.FK_ESTABLECIMIENTO')
               FROM public.query q JOIN public.microservice m ON m.id_microservice = q.microservice_id
              WHERE m.serviceid = 'pigse' AND q.path_template = '/funcionarios' AND q.http_method = 'POST')
        AND (SELECT q.param_types ? 'BODY.FKTLVCLASEFUNCIONARIO'
               FROM public.query q JOIN public.microservice m ON m.id_microservice = q.microservice_id
              WHERE m.serviceid = 'pigse' AND q.path_template = '/funcionarios/:ID' AND q.http_method = 'PUT')
    ) INTO v_ok;

    IF NOT coalesce(v_ok, false) THEN
        RAISE EXCEPTION 'V390: alguna de las verificaciones fallo';
    END IF;

    RAISE NOTICE 'V390 OK: fn_fun_crear arreglada (11 args, establecimiento opcional), binds sin guion bajo, informacion complementaria agregada, establecimiento se deriva de la sede al crear un permiso.';
END $$;
