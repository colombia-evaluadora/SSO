-- =============================================================================
-- V164 -- Manejo de TMATRICULA_SOCIOECONOMICO: alta del detalle
-- socioeconomico de una TMATRICULA ya existente.
--
-- Alcance de este pase: SOLO fn_matricula_socioeconomico_crear. Igual que
-- V163, es una funcion de creacion "plana" con los campos del formulario
-- (.txt "Agregar estudiante", secciones "Informacion academica del año
-- anterior" [parcial -- lo que no fue a TMATRICULA], "Sector de origen",
-- "Victima conflicto armado", "Informacion complementaria" [parcial -- lo
-- que no fue a TUSUARIO/TESTUDIANTE] y "Subsidio o beneficios"). No
-- invoca las validaciones de V162 -- eso lo hara la funcion orquestadora
-- mayor, mas adelante.
--
-- NOTA: FK_TLV_CONDICION_PROMOCION ("Condicion del estudiante fin del año
-- anterior") se incluye porque el DDL la tiene y el .txt la mapea aqui,
-- pero el propio .txt marca ese mapeo "de momento, en duda" -- se deja
-- disponible como parametro opcional, sin mas.
--
-- Es 1-a-1 con TMATRICULA (FK_TMATRICULA, sin UNIQUE a nivel de DDL pero
-- con ON DELETE CASCADE) -- esta funcion valida esa unicidad a mano.
--
-- Gate: mismo patron que V163, resuelto un salto mas arriba
-- (TMATRICULA -> TGRUPO -> TGRADO -> TPERIODO_ACADEMICO -> TSEDE ->
-- TESTABLECIMIENTO).
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_socioeconomico_crear(
    p_pk_usuario_solicitante             BIGINT,
    p_fk_tmatricula                      BIGINT,
    p_proviene_sector_privado            VARCHAR DEFAULT NULL,
    p_proviene_otro_municipio            VARCHAR DEFAULT NULL,
    p_proviene_otro_municipio_cual       VARCHAR DEFAULT NULL,
    p_institucion_origen                 VARCHAR DEFAULT NULL,
    p_fk_tlv_tipo_institucion_origen     BIGINT  DEFAULT NULL,
    p_fk_tlv_condicion_promocion         BIGINT  DEFAULT NULL,
    p_fk_tlv_victima_conflicto           BIGINT  DEFAULT NULL,
    p_fk_tmunicipio_victima              BIGINT  DEFAULT NULL,
    p_seguridad_social_ars               VARCHAR DEFAULT NULL,
    p_seguridad_social_eps               VARCHAR DEFAULT NULL,
    p_estudiante_subsidiado              VARCHAR DEFAULT NULL,
    p_fk_tlv_fuente_recurso              BIGINT  DEFAULT NULL,
    p_beneficiario_cabeza_familia        VARCHAR DEFAULT NULL,
    p_ben_hijo_cabeza_familia            VARCHAR DEFAULT NULL,
    p_beneficiario_veterano              VARCHAR DEFAULT NULL,
    p_beneficiario_heroe                 VARCHAR DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_establecimiento BIGINT;
    v_id_creado          BIGINT;
BEGIN
    -- -----------------------------------------------------------------
    -- 0. Resolver el EE de la matricula recibida (para el gate).
    -- -----------------------------------------------------------------
    SELECT s.FK_TESTABLECIMIENTO
      INTO v_fk_establecimiento
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr              ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO g               ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa   ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s                 ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE m.PK_TMATRICULA = p_fk_tmatricula
       AND m.ACTIVE        = TRUE
       AND gr.ACTIVE       = TRUE
       AND g.ACTIVE        = TRUE
       AND pa.ACTIVE       = TRUE
       AND s.ACTIVE        = TRUE;

    IF v_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'No se encontro una matricula activa con ese identificador'
            USING ERRCODE = '22023', HINT = 'p_fk_tmatricula debe apuntar a un TMATRICULA activo, con grupo/grado/periodo/sede activos';
    END IF;

    -- -----------------------------------------------------------------
    -- 1. Gate de autorizacion COMPUESTO -- mismo patron de V163.
    -- -----------------------------------------------------------------
    IF academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TESTABLECIMIENTO e
            ON e.FK_TFUNCIONARIO_RECTOR = f.PK_TFUNCIONARIO
         WHERE e.PK_ESTABLECIMIENTO = v_fk_establecimiento
           AND e.ACTIVE             = TRUE
           AND f.ACTIVE             = TRUE
           AND f.FK_TUSUARIO        = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TESTABLECIMIENTO e
            ON e.FK_TFUNCIONARIO_SECRETARIA = f.PK_TFUNCIONARIO
         WHERE e.PK_ESTABLECIMIENTO = v_fk_establecimiento
           AND e.ACTIVE             = TRUE
           AND f.ACTIVE             = TRUE
           AND f.FK_TUSUARIO        = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TSEDE_USUARIO su
          JOIN academico_test.TSEDE s
            ON s.PK_TSEDE = su.FK_TSEDE
         WHERE s.FK_TESTABLECIMIENTO = v_fk_establecimiento
           AND s.ACTIVE              = TRUE
           AND su.ACTIVE             = TRUE
           AND su.FK_TROL            = 8
           AND su.FK_TUSUARIO        = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSE
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Evitar duplicados: la matricula ya no puede tener otro registro
    --    socioeconomico activo (relacion 1-a-1, no forzada por UNIQUE en
    --    el DDL).
    -- -----------------------------------------------------------------
    IF EXISTS (
        SELECT 1 FROM academico_test.TMATRICULA_SOCIOECONOMICO
         WHERE FK_TMATRICULA = p_fk_tmatricula AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'Esta matricula ya tiene un registro socioeconomico activo'
            USING ERRCODE = '23505',
                  HINT    = 'Use la funcion de actualizacion (cuando exista) para modificar el registro existente';
    END IF;

    -- -----------------------------------------------------------------
    -- 3. Validaciones de los campos S/N (sin dominio bool_sn a nivel de
    --    DDL en estas columnas, pero con el mismo significado -- se
    --    valida igual).
    -- -----------------------------------------------------------------
    IF p_proviene_sector_privado IS NOT NULL AND UPPER(p_proviene_sector_privado) NOT IN ('S', 'N') THEN
        RAISE EXCEPTION 'proviene_sector_privado debe ser ''S'' o ''N''' USING ERRCODE = '22023';
    END IF;
    IF p_proviene_otro_municipio IS NOT NULL AND UPPER(p_proviene_otro_municipio) NOT IN ('S', 'N') THEN
        RAISE EXCEPTION 'proviene_otro_municipio debe ser ''S'' o ''N''' USING ERRCODE = '22023';
    END IF;
    IF p_estudiante_subsidiado IS NOT NULL AND UPPER(p_estudiante_subsidiado) NOT IN ('S', 'N') THEN
        RAISE EXCEPTION 'estudiante_subsidiado debe ser ''S'' o ''N''' USING ERRCODE = '22023';
    END IF;
    IF p_beneficiario_cabeza_familia IS NOT NULL AND UPPER(p_beneficiario_cabeza_familia) NOT IN ('S', 'N') THEN
        RAISE EXCEPTION 'beneficiario_cabeza_familia debe ser ''S'' o ''N''' USING ERRCODE = '22023';
    END IF;
    IF p_ben_hijo_cabeza_familia IS NOT NULL AND UPPER(p_ben_hijo_cabeza_familia) NOT IN ('S', 'N') THEN
        RAISE EXCEPTION 'ben_hijo_cabeza_familia debe ser ''S'' o ''N''' USING ERRCODE = '22023';
    END IF;
    IF p_beneficiario_veterano IS NOT NULL AND UPPER(p_beneficiario_veterano) NOT IN ('S', 'N') THEN
        RAISE EXCEPTION 'beneficiario_veterano debe ser ''S'' o ''N''' USING ERRCODE = '22023';
    END IF;
    IF p_beneficiario_heroe IS NOT NULL AND UPPER(p_beneficiario_heroe) NOT IN ('S', 'N') THEN
        RAISE EXCEPTION 'beneficiario_heroe debe ser ''S'' o ''N''' USING ERRCODE = '22023';
    END IF;

    -- -----------------------------------------------------------------
    -- 4. Validacion de FKs de catalogo, solo si llegan no-NULL.
    -- -----------------------------------------------------------------
    IF p_fk_tlv_tipo_institucion_origen IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_tlv_tipo_institucion_origen AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'tipo de institucion de origen (%) no existe o no esta activo', p_fk_tlv_tipo_institucion_origen USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_condicion_promocion IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_tlv_condicion_promocion AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'condicion de promocion (%) no existe o no esta activa', p_fk_tlv_condicion_promocion USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_victima_conflicto IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_tlv_victima_conflicto AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'victima de conflicto (%) no existe o no esta activa', p_fk_tlv_victima_conflicto USING ERRCODE = '23503';
    END IF;

    IF p_fk_tmunicipio_victima IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TMUNICIPIO WHERE PK_TMUNICIPIO = p_fk_tmunicipio_victima AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'municipio expulsor (%) no existe o no esta activo', p_fk_tmunicipio_victima USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_fuente_recurso IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_tlv_fuente_recurso AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'fuente de recurso (%) no existe o no esta activa', p_fk_tlv_fuente_recurso USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 5. INSERT.
    -- -----------------------------------------------------------------
    INSERT INTO academico_test.TMATRICULA_SOCIOECONOMICO (
        FK_TMATRICULA,
        PROVIENE_SECTOR_PRIVADO, PROVIENE_OTRO_MUNICIPIO, PROVIENE_OTRO_MUNICIPIO_CUAL,
        INSTITUCION_ORIGEN, FK_TLV_TIPO_INSTITUCION_ORIGEN, FK_TLV_CONDICION_PROMOCION,
        FK_TLV_VICTIMA_CONFLICTO, FK_TMUNICIPIO_VICTIMA,
        SEGURIDAD_SOCIAL_ARS, SEGURIDAD_SOCIAL_EPS,
        ESTUDIANTE_SUBSIDIADO, FK_TLV_FUENTE_RECURSO,
        BENEFICIARIO_CABEZA_FAMILIA, BEN_HIJO_CABEZA_FAMILIA,
        BENEFICIARIO_VETERANO, BENEFICIARIO_HEROE,
        CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        p_fk_tmatricula,
        UPPER(p_proviene_sector_privado), UPPER(p_proviene_otro_municipio), NULLIF(TRIM(p_proviene_otro_municipio_cual), ''),
        NULLIF(TRIM(p_institucion_origen), ''), p_fk_tlv_tipo_institucion_origen, p_fk_tlv_condicion_promocion,
        p_fk_tlv_victima_conflicto, p_fk_tmunicipio_victima,
        NULLIF(TRIM(p_seguridad_social_ars), ''), NULLIF(TRIM(p_seguridad_social_eps), ''),
        UPPER(p_estudiante_subsidiado), p_fk_tlv_fuente_recurso,
        UPPER(p_beneficiario_cabeza_familia), UPPER(p_ben_hijo_cabeza_familia),
        UPPER(p_beneficiario_veterano), UPPER(p_beneficiario_heroe),
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TMATRICULA_SOCIOECONOMICO INTO v_id_creado;

    RAISE NOTICE 'TMATRICULA_SOCIOECONOMICO creado: PK=%, FK_TMATRICULA=%', v_id_creado, p_fk_tmatricula;

    RETURN v_id_creado;
END;
$function$;

-- =============================================================================
-- fn_matricula_socioeconomico_obtener_por_matricula -- GET granular del
-- detalle socioeconomico de UNA matricula. Se busca por FK_TMATRICULA (no
-- por su propio PK): la relacion es 1-a-1 y el caller siempre parte de la
-- matricula, nunca del PK del socioeconomico.
--
-- Gate: estricto (sede-especifico), mismo patron que
-- fn_matricula_obtener_por_id (V163) -- resuelto un salto mas arriba, via
-- la matricula recibida.
--
-- 0 filas si la matricula no tiene socioeconomico activo (no lanza
-- excepcion) -- una matricula sin ese detalle es un estado posible, no un
-- error.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_socioeconomico_obtener_por_matricula(
    p_pk_usuario_solicitante  BIGINT,
    p_fk_tmatricula           BIGINT
)
RETURNS TABLE (
    pk_tmatricula_socioeconomico       BIGINT,
    fk_tmatricula                      BIGINT,
    proviene_sector_privado            academico_test.bool_sn,
    proviene_otro_municipio            academico_test.bool_sn,
    proviene_otro_municipio_cual       VARCHAR,
    institucion_origen                 VARCHAR,
    fk_tlv_tipo_institucion_origen     BIGINT,
    tipo_institucion_origen_nombre     VARCHAR,
    fk_tlv_condicion_promocion         BIGINT,
    condicion_promocion_nombre         VARCHAR,
    fk_tlv_victima_conflicto           BIGINT,
    victima_conflicto_nombre           VARCHAR,
    fk_tmunicipio_victima              BIGINT,
    municipio_victima_nombre           VARCHAR,
    seguridad_social_ars               VARCHAR,
    seguridad_social_eps               VARCHAR,
    estudiante_subsidiado              academico_test.bool_sn,
    fk_tlv_fuente_recurso              BIGINT,
    fuente_recurso_nombre              VARCHAR,
    beneficiario_cabeza_familia        academico_test.bool_sn,
    ben_hijo_cabeza_familia            academico_test.bool_sn,
    beneficiario_veterano              academico_test.bool_sn,
    beneficiario_heroe                 academico_test.bool_sn
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_fk_establecimiento BIGINT;
BEGIN
    SELECT s.FK_TESTABLECIMIENTO
      INTO v_fk_establecimiento
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr              ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO g               ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa   ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s                 ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE m.PK_TMATRICULA = p_fk_tmatricula
       AND m.ACTIVE        = TRUE
       AND gr.ACTIVE       = TRUE
       AND g.ACTIVE        = TRUE
       AND pa.ACTIVE       = TRUE
       AND s.ACTIVE        = TRUE;

    IF v_fk_establecimiento IS NULL THEN
        RETURN;
    END IF;

    IF academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TESTABLECIMIENTO e
            ON e.FK_TFUNCIONARIO_RECTOR = f.PK_TFUNCIONARIO
         WHERE e.PK_ESTABLECIMIENTO = v_fk_establecimiento
           AND e.ACTIVE             = TRUE
           AND f.ACTIVE             = TRUE
           AND f.FK_TUSUARIO        = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TESTABLECIMIENTO e
            ON e.FK_TFUNCIONARIO_SECRETARIA = f.PK_TFUNCIONARIO
         WHERE e.PK_ESTABLECIMIENTO = v_fk_establecimiento
           AND e.ACTIVE             = TRUE
           AND f.ACTIVE             = TRUE
           AND f.FK_TUSUARIO        = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TSEDE_USUARIO su
          JOIN academico_test.TSEDE s
            ON s.PK_TSEDE = su.FK_TSEDE
         WHERE s.FK_TESTABLECIMIENTO = v_fk_establecimiento
           AND s.ACTIVE              = TRUE
           AND su.ACTIVE             = TRUE
           AND su.FK_TROL            = 8
           AND su.FK_TUSUARIO        = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSE
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT
        se.PK_TMATRICULA_SOCIOECONOMICO,
        se.FK_TMATRICULA,
        se.PROVIENE_SECTOR_PRIVADO,
        se.PROVIENE_OTRO_MUNICIPIO,
        se.PROVIENE_OTRO_MUNICIPIO_CUAL,
        se.INSTITUCION_ORIGEN,
        se.FK_TLV_TIPO_INSTITUCION_ORIGEN, tio.NOMBRE,
        se.FK_TLV_CONDICION_PROMOCION, cp.NOMBRE,
        se.FK_TLV_VICTIMA_CONFLICTO, vc.NOMBRE,
        se.FK_TMUNICIPIO_VICTIMA, mv.NOMBRE,
        se.SEGURIDAD_SOCIAL_ARS,
        se.SEGURIDAD_SOCIAL_EPS,
        se.ESTUDIANTE_SUBSIDIADO,
        se.FK_TLV_FUENTE_RECURSO, fr.NOMBRE,
        se.BENEFICIARIO_CABEZA_FAMILIA,
        se.BEN_HIJO_CABEZA_FAMILIA,
        se.BENEFICIARIO_VETERANO,
        se.BENEFICIARIO_HEROE
      FROM academico_test.TMATRICULA_SOCIOECONOMICO se
 LEFT JOIN academico_test.TLISTA_VALOR tio ON tio.PK_LISTA_VALOR = se.FK_TLV_TIPO_INSTITUCION_ORIGEN
 LEFT JOIN academico_test.TLISTA_VALOR cp  ON cp.PK_LISTA_VALOR  = se.FK_TLV_CONDICION_PROMOCION
 LEFT JOIN academico_test.TLISTA_VALOR vc  ON vc.PK_LISTA_VALOR  = se.FK_TLV_VICTIMA_CONFLICTO
 LEFT JOIN academico_test.TMUNICIPIO mv    ON mv.PK_TMUNICIPIO   = se.FK_TMUNICIPIO_VICTIMA
 LEFT JOIN academico_test.TLISTA_VALOR fr  ON fr.PK_LISTA_VALOR  = se.FK_TLV_FUENTE_RECURSO
     WHERE se.FK_TMATRICULA = p_fk_tmatricula
       AND se.ACTIVE        = TRUE
     LIMIT 1;
END;
$function$;

-- =============================================================================
-- fn_matricula_socioeconomico_soft_delete -- baja logica del detalle
-- socioeconomico de una matricula.
--
-- Es una de las dos unicas entidades que se van EN CASCADA con la matricula
-- (la otra es TMATRICULA_ARCHIVO, V165): no bloquea la baja, se desactiva con
-- ella. Por eso no valida dependencias -- nada cuelga de esta tabla.
--
-- Sin gate propio: la llama fn_matricula_directa_eliminar (V166), que ya valido
-- el gate estricto sede-especifico antes de tocar nada. Darle gate propio
-- invitaria a usarla suelta, y una matricula sin su detalle socioeconomico es
-- un estado que el modelo no contempla.
--
-- Devuelve cuantas filas desactivo (0 si la matricula no tenia detalle, que es
-- un estado posible y no un error).
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_socioeconomico_soft_delete(
    p_pk_usuario_solicitante  BIGINT,
    p_fk_tmatricula           BIGINT
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $function$
DECLARE
    v_n INTEGER;
BEGIN
    UPDATE academico_test.TMATRICULA_SOCIOECONOMICO
       SET ACTIVE      = FALSE,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TMATRICULA = p_fk_tmatricula
       AND ACTIVE        = TRUE;

    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END;
$function$;
