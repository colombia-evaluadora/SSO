-- V414 - La zona de la sede se subordina a la del establecimiento:
-- EE Urbana -> sede Urbana; EE Rural -> sede Rural; EE "Urbana y Rural" o
-- sin zona -> sede Urbana o Rural. Ninguna sede puede ser "Urbana y Rural".
-- fn_sed_crear/fn_sed_actualizar validan y la sede automatica de fn_est_crear
-- hereda la zona (fn_est_zona_sede_defecto).

CREATE OR REPLACE FUNCTION academico_test.fn_est_zonas_sede_permitidas(
    p_fk_establecimiento BIGINT
)
RETURNS VARCHAR[]
LANGUAGE sql
STABLE
AS $function$
    SELECT CASE lv.VALOR
               WHEN '1' THEN ARRAY['1']::VARCHAR[]        -- EE Urbana
               WHEN '2' THEN ARRAY['2']::VARCHAR[]        -- EE Rural
               ELSE          ARRAY['1', '2']::VARCHAR[]   -- mixto
           END
      FROM academico_test.TESTABLECIMIENTO e
      LEFT JOIN academico_test.TLISTA_VALOR lv
             ON lv.PK_LISTA_VALOR = e.FK_TLISTA_VALOR_ZONA
            AND lv.CATEGORIA      = 'ZONA'
     WHERE e.PK_ESTABLECIMIENTO = p_fk_establecimiento;
$function$;

COMMENT ON FUNCTION academico_test.fn_est_zonas_sede_permitidas(BIGINT)
    IS 'Los VALOR de ZONA que una sede de ese establecimiento puede tener: {1} si el EE es Urbana, {2} si es Rural, y {1,2} si es "Urbana y Rural" o si no declaro zona. El 3 ("Urbana y Rural") NUNCA sale de aqui: una sede es un edificio y esta en un sitio, mientras que "Urbana y Rural" describe un conjunto de sedes -- que es justo lo que el establecimiento es. El EE sin zona permite las dos en vez de bloquear, porque hay 9 asi en el servidor y exigirles zona dejaria sus sedes sin poder crearse hasta que alguien editara el establecimiento. Se compara por VALOR y no por PK_LISTA_VALOR porque el PK es de esta instalacion y el VALOR es del catalogo. Es el UNICO lugar donde vive la regla: la necesitan crear sede, editar sede, la sede automatica del EE y el catalogo que alimenta el select, y escrita cuatro veces el dia que cambie quedarian tres versiones distintas.';

CREATE OR REPLACE FUNCTION academico_test.fn_est_zona_sede_permitida(
    p_fk_establecimiento  BIGINT,
    p_fk_lista_valor_zona BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $function$
    SELECT COALESCE(
        (SELECT lv.VALOR = ANY (
                    academico_test.fn_est_zonas_sede_permitidas(p_fk_establecimiento))
           FROM academico_test.TLISTA_VALOR lv
          WHERE lv.PK_LISTA_VALOR = p_fk_lista_valor_zona
            AND lv.CATEGORIA      = 'ZONA'),
        FALSE);
$function$;

COMMENT ON FUNCTION academico_test.fn_est_zona_sede_permitida(BIGINT, BIGINT)
    IS 'Si esa zona concreta es valida para una sede de ese establecimiento, segun fn_est_zonas_sede_permitidas. Devuelve FALSE -- no NULL -- cuando la zona no existe, no es de la categoria ZONA o el establecimiento no existe, de modo que el caller no tiene que distinguir "no permitida" de "no se pudo decidir": las dos terminan en el mismo rechazo, y el caso del EE inexistente ya lo cubre la validacion previa de fn_sed_crear.';

CREATE OR REPLACE FUNCTION academico_test.fn_est_zonas_sede_texto(
    p_fk_establecimiento BIGINT
)
RETURNS VARCHAR
LANGUAGE sql
STABLE
AS $function$
    SELECT COALESCE(
        (SELECT lv.NOMBRE
           FROM academico_test.TESTABLECIMIENTO e
           JOIN academico_test.TLISTA_VALOR lv
             ON lv.PK_LISTA_VALOR = e.FK_TLISTA_VALOR_ZONA
            AND lv.CATEGORIA      = 'ZONA'
          WHERE e.PK_ESTABLECIMIENTO = p_fk_establecimiento),
        'sin zona declarada')::VARCHAR;
$function$;

COMMENT ON FUNCTION academico_test.fn_est_zonas_sede_texto(BIGINT)
    IS 'El nombre de la zona del establecimiento, o "sin zona declarada". Existe solo para los mensajes de error: que digan QUE es el establecimiento en vez de limitarse a negar, porque "no corresponde con la del establecimiento (Rural)" se arregla solo mientras que "zona invalida" obliga a ir a mirar.';

CREATE OR REPLACE FUNCTION academico_test.fn_est_zona_sede_defecto(
    p_fk_establecimiento BIGINT
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $function$
    SELECT lv.PK_LISTA_VALOR
      FROM academico_test.TLISTA_VALOR lv
     WHERE lv.CATEGORIA = 'ZONA'
       AND lv.ACTIVE    = TRUE
       AND lv.VALOR     = (
           SELECT CASE WHEN CARDINALITY(z) = 1 THEN z[1] ELSE '1' END
             FROM academico_test.fn_est_zonas_sede_permitidas(p_fk_establecimiento) z
       )
     LIMIT 1;
$function$;

COMMENT ON FUNCTION academico_test.fn_est_zona_sede_defecto(BIGINT)
    IS 'El PK_LISTA_VALOR de la zona que lleva la sede que fn_est_crear crea automaticamente junto al establecimiento: la misma del EE si este es de una sola zona, y URBANA si es mixto o no declaro ninguna. Antes era la constante 216 ("Urbana y Rural"), que con la regla de V414 ya no es un valor valido para una sede. Urbana como desempate y no Rural porque es la mas frecuente en el servidor (20 sedes contra 14) y sobre todo porque la sede automatica esta pensada para editarse: si no aplica, el usuario la corrige.';

CREATE OR REPLACE FUNCTION academico_test.fn_sed_crear(p_pk_usuario_solicitante bigint, p_codigo character varying, p_nombre character varying, p_fk_lista_valor_zona bigint, p_fk_establecimiento bigint, p_localidad character varying DEFAULT NULL::character varying, p_comuna character varying DEFAULT NULL::character varying, p_barrio character varying DEFAULT NULL::character varying, p_direccion character varying DEFAULT NULL::character varying, p_telefono character varying DEFAULT NULL::character varying, p_georeferenciacion character varying DEFAULT NULL::character varying)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_id_creado             BIGINT;
    v_consecutivo           VARCHAR(2);
    v_pk_rector              BIGINT;
    v_pk_secretaria          BIGINT;
    v_fk_usuario_rector      BIGINT;
    v_fk_usuario_secretaria  BIGINT;
    c_fk_trol_rector         CONSTANT BIGINT := 7;
    c_fk_trol_secretaria     CONSTANT BIGINT := 8;
    c_fk_tlv_jornada_defecto CONSTANT BIGINT := 51900;
    v_fk_establecimiento    BIGINT := p_fk_establecimiento;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante,
        'SEDES_EDUCATIVAS',
        'CREAR',
        v_fk_establecimiento
    );

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

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TESTABLECIMIENTO
         WHERE PK_ESTABLECIMIENTO = v_fk_establecimiento
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se encontro un establecimiento activo con ese identificador'
            USING ERRCODE = '22023',
                  HINT    = 'Verifique el establecimiento o use fn_est_buscar_por_nit(..., p_incluir_inactivos=TRUE)';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_lista_valor_zona
           AND ACTIVE         = TRUE
    ) THEN
        RAISE EXCEPTION 'FK_TLV_ZONA (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lista_valor_zona
            USING ERRCODE = '23503';
    END IF;

    IF NOT academico_test.fn_est_zona_sede_permitida(
               p_fk_establecimiento, p_fk_lista_valor_zona) THEN
        IF (SELECT lv.VALOR FROM academico_test.TLISTA_VALOR lv
             WHERE lv.PK_LISTA_VALOR = p_fk_lista_valor_zona) = '3' THEN
            RAISE EXCEPTION 'Una sede no puede ser "Urbana y Rural"'
                USING ERRCODE = '22023',
                      HINT    = 'Esa zona describe al establecimiento, que agrupa varias sedes. Una sede es un edificio: elija Urbana o Rural segun donde este';
        ELSE
            RAISE EXCEPTION 'La zona de la sede no corresponde con la del establecimiento (%)',
                academico_test.fn_est_zonas_sede_texto(p_fk_establecimiento)
                USING ERRCODE = '22023',
                      HINT    = 'Si el establecimiento es de una sola zona, sus sedes deben ser de esa misma';
        END IF;
    END IF;

    IF EXISTS (
        SELECT 1 FROM academico_test.TSEDE
         WHERE CODIGO = p_codigo
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'Ya existe una sede activa con el código %.', p_codigo
            USING ERRCODE = '23505',
                  HINT    = 'Use una consulta directa sobre TSEDE para localizar el registro';
    END IF;

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

    SELECT LPAD(
             (COALESCE(MAX(NULLIF(TRIM(CONSECUTIVO), '')::INT), 0) + 1)::TEXT,
             2, '0'
           )
      INTO v_consecutivo
      FROM academico_test.TSEDE
     WHERE FK_TESTABLECIMIENTO = v_fk_establecimiento
       AND ACTIVE              = TRUE;

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
            RAISE EXCEPTION 'El rector del establecimiento, %, no tiene un usuario activo, así que no se le pudo dar permiso en la sede nueva.',
                (SELECT CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)
                   FROM academico_test.TFUNCIONARIO f
                   JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
                  WHERE f.PK_TFUNCIONARIO = v_pk_rector)
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
            RAISE EXCEPTION 'La secretaria del establecimiento, %, no tiene un usuario activo, así que no se le pudo dar permiso en la sede nueva.',
                (SELECT CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)
                   FROM academico_test.TFUNCIONARIO f
                   JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
                  WHERE f.PK_TFUNCIONARIO = v_pk_secretaria)
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
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_sed_actualizar(p_pk_usuario_solicitante bigint, p_pk_sede bigint, p_codigo character varying DEFAULT NULL::character varying, p_nombre character varying DEFAULT NULL::character varying, p_fk_lista_valor_zona bigint DEFAULT NULL::bigint, p_localidad character varying DEFAULT NULL::character varying, p_comuna character varying DEFAULT NULL::character varying, p_barrio character varying DEFAULT NULL::character varying, p_direccion character varying DEFAULT NULL::character varying, p_telefono character varying DEFAULT NULL::character varying, p_georeferenciacion character varying DEFAULT NULL::character varying)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_estado_actual BOOLEAN;
    v_nombre_actual VARCHAR;
    v_fk_ee        BIGINT;
BEGIN
    SELECT ACTIVE, FK_TESTABLECIMIENTO, NOMBRE
      INTO v_estado_actual, v_fk_ee, v_nombre_actual
      FROM academico_test.TSEDE
     WHERE PK_TSEDE = p_pk_sede;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la sede solicitada'
            USING ERRCODE = 'P0002';
    END IF;

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

    IF p_fk_lista_valor_zona IS NOT NULL
       AND NOT academico_test.fn_est_zona_sede_permitida(
                   v_fk_ee, p_fk_lista_valor_zona) THEN
        IF (SELECT lv.VALOR FROM academico_test.TLISTA_VALOR lv
             WHERE lv.PK_LISTA_VALOR = p_fk_lista_valor_zona) = '3' THEN
            RAISE EXCEPTION 'Una sede no puede ser "Urbana y Rural"'
                USING ERRCODE = '22023',
                      HINT    = 'Esa zona describe al establecimiento, que agrupa varias sedes. Una sede es un edificio: elija Urbana o Rural segun donde este';
        ELSE
            RAISE EXCEPTION 'La zona de la sede no corresponde con la del establecimiento (%)',
                academico_test.fn_est_zonas_sede_texto(v_fk_ee)
                USING ERRCODE = '22023',
                      HINT    = 'Si el establecimiento es de una sola zona, sus sedes deben ser de esa misma';
        END IF;
    END IF;

    IF p_codigo IS NOT NULL AND EXISTS (
        SELECT 1 FROM academico_test.TSEDE
         WHERE CODIGO  = p_codigo
           AND ACTIVE  = TRUE
           AND PK_TSEDE <> p_pk_sede
    ) THEN
        RAISE EXCEPTION 'Ya existe otra sede activa con el código %.', p_codigo
            USING ERRCODE = '23505',
                  HINT    = 'Use una consulta directa sobre TSEDE para localizar el registro que ya lo usa';
    END IF;

    IF p_nombre IS NOT NULL AND EXISTS (
        SELECT 1 FROM academico_test.TSEDE
         WHERE FK_TESTABLECIMIENTO = v_fk_ee
           AND NOMBRE              = p_nombre
           AND ACTIVE              = TRUE
           AND PK_TSEDE           <> p_pk_sede
    ) THEN
        RAISE EXCEPTION 'Ya existe otra sede activa llamada "%" en el establecimiento %.', p_nombre,
            (SELECT e.NOMBRE FROM academico_test.TESTABLECIMIENTO e WHERE e.PK_ESTABLECIMIENTO = v_fk_ee)
            USING ERRCODE = '23505',
                  HINT    = 'Dentro de un EE el NOMBRE de sede debe ser unico entre activas';
    END IF;

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
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_est_crear(p_pk_usuario_solicitante bigint, p_nombre character varying, p_nit character varying, p_fk_municipio bigint, p_fk_propiedad_juridica bigint, p_codigo character varying, p_localidad character varying DEFAULT NULL::character varying, p_comuna character varying DEFAULT NULL::character varying, p_barrio character varying DEFAULT NULL::character varying, p_direccion character varying DEFAULT NULL::character varying, p_correo_electronico character varying DEFAULT NULL::character varying, p_telefono character varying DEFAULT NULL::character varying, p_fax character varying DEFAULT NULL::character varying, p_idecol character varying DEFAULT NULL::character varying, p_pagina_web character varying DEFAULT NULL::character varying, p_fk_lista_valor_zona bigint DEFAULT NULL::bigint, p_resolucion_aprobacion character varying DEFAULT NULL::character varying, p_licencia_funcionamiento character varying DEFAULT NULL::character varying, p_fecha_licencia date DEFAULT NULL::date, p_fk_lv_calendario bigint DEFAULT NULL::bigint, p_fk_lv_idioma bigint DEFAULT NULL::bigint, p_fk_lv_genero_est bigint DEFAULT NULL::bigint, p_fk_discapacidad bigint DEFAULT NULL::bigint, p_talento academico_test.bool_sn DEFAULT NULL::character varying, p_etnias academico_test.bool_sn DEFAULT NULL::character varying, p_fk_tfuncionario_rector bigint DEFAULT NULL::bigint, p_fk_tfuncionario_secretaria bigint DEFAULT NULL::bigint, p_subsidio academico_test.bool_sn DEFAULT NULL::character varying, p_fk_lv_regimen_catcosto bigint DEFAULT NULL::bigint, p_fk_lv_rango_tarifa bigint DEFAULT NULL::bigint, p_fk_lv_asociacion_nacional bigint DEFAULT NULL::bigint, p_fk_archivo bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_id_creado BIGINT;
    c_fk_lv_estado_activo CONSTANT BIGINT := 533;
    v_fk_tlv_zona_sede       BIGINT;
    c_fk_tlv_jornada_defecto CONSTANT BIGINT := 51900;
    c_fk_trol_rector         CONSTANT BIGINT := 7;
    c_fk_trol_secretaria     CONSTANT BIGINT := 8;
    v_pk_sede_creada         BIGINT;
    v_perm_result            RECORD;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'ESTABLECIMIENTO', 'CREAR'
    );

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

    IF EXISTS (
        SELECT 1 FROM academico_test.TESTABLECIMIENTO
        WHERE NIT = p_nit AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'Ya existe un establecimiento activo con el NIT %.', p_nit
            USING ERRCODE = '23505',
                  HINT    = 'Use fn_est_buscar_por_nit('') para obtener el registro existente';
    END IF;

    IF EXISTS (
        SELECT 1 FROM academico_test.TESTABLECIMIENTO
        WHERE CODIGO = p_codigo AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'Ya existe un establecimiento activo con el código DANE %.', p_codigo
            USING ERRCODE = '23505',
                  HINT    = 'Use fn_est_buscar_por_nit('') o un SELECT directo para localizarlo';
    END IF;

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

    IF p_fk_archivo IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TARCHIVO
             WHERE PK_TARCHIVO = p_fk_archivo
          )
    THEN
        RAISE EXCEPTION 'FK_TARCHIVO (%) no existe en TARCHIVO', p_fk_archivo
            USING ERRCODE = '23503';
    END IF;

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

    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Creacion del establecimiento %s', p_nombre), v_id_creado);

    v_fk_tlv_zona_sede := academico_test.fn_est_zona_sede_defecto(v_id_creado);

    v_pk_sede_creada := academico_test.fn_sed_crear(
        p_pk_usuario_solicitante => p_pk_usuario_solicitante,
        p_codigo                 => p_codigo,
        p_nombre                 => p_nombre,
        p_fk_lista_valor_zona    => v_fk_tlv_zona_sede,
        p_fk_establecimiento     => v_id_creado
    );

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
$function$;

DO $$
BEGIN
    EXECUTE format('COMMENT ON FUNCTION %s IS %L',
        'academico_test.fn_est_crear'::REGPROC::OID::REGPROCEDURE,
        'Crea un TESTABLECIMIENTO (mas su sede por defecto y los permisos de rector/secretaria en ella) y sincroniza public.role_users de rector y secretaria. GATE (CU-86e2w4xdt): PERFORM fn_assert_permiso_seccion(solicitante, ''ESTABLECIMIENTO'', ''CREAR'') -- SIN objeto: crear un EE no tiene un EE previo sobre el que evaluar scope, asi que basta la capability del menu ESTABLECIMIENTO (configurable por el super admin via TROL_MENU/TUSUARIO_ROL_PERMISO), con bypass para el SUPER_ADMIN. Reemplaza a fn_puede_afectar_establecimiento (lista fija de roles 1-3). Se conserva la validacion 22023 de p_pk_usuario_solicitante obligatorio y > 0, que corre antes del gate.');
END;
$$;
