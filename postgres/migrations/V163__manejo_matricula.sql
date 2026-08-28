-- =============================================================================
-- V163 -- Manejo de TMATRICULA: alta directa de una matricula.
--
-- Alcance de este pase: SOLO fn_matricula_crear. Es una funcion de
-- creacion "plana" -- inserta con los campos que llegan del formulario
-- (ver .txt "Agregar estudiante", secciones "Informacion de matricula" e
-- "Informacion academica del año anterior") mas los NOT NULL del DDL que
-- no vienen del formulario (estado de la matricula, bandera de estudiante
-- nuevo). NO invoca las validaciones ya construidas en V162
-- (fn_periodo_resolver_matricula, fn_matricula_validar_cupo,
-- fn_matricula_validar_estudiante_disponible) -- esas las orquestara mas
-- adelante una funcion mayor que unifique todo el proceso (estudiante,
-- padre, matricula, socioeconomico).
--
-- Campos del DDL que se dejan fuera de esta pasada (no estan en el
-- formulario ni son NOT NULL): FK_TINSCRIPCION, FK_TPREMATRICULA (no
-- aplican a matricula directa, que salta inscripcion/prematricula),
-- FK_TPADRE, FK_TLV_ACUDIENTE_PARENTESCO, ESTUDIANTE_REPITENTE,
-- PROMOCION_ANTICIPADA, ESTADO_CONVIVE_ACUDIENTE,
-- LISTA_MENSAJE_PROMOCION, FK_TMATRICULA_ANTERIOR, EDICION_ACUDIENTE.
--
-- Gate: mismo patron usado en V160/V161 (super-admin / rector / secretaria
-- / jefe de sistema), resuelto aqui a partir del grupo recibido
-- (TGRUPO -> TGRADO -> TPERIODO_ACADEMICO -> TSEDE -> TESTABLECIMIENTO).
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_crear(
    p_pk_usuario_solicitante        BIGINT,
    p_fk_testudiante                BIGINT,
    p_fk_tgrupo                     BIGINT,
    p_fk_tlv_estado_matricula       BIGINT,
    p_estudiante_nuevo              VARCHAR,
    p_fk_enfasis                    BIGINT  DEFAULT NULL,
    p_fk_tlv_situacion_academica    BIGINT  DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_establecimiento BIGINT;
    v_id_creado          BIGINT;
BEGIN
    -- -----------------------------------------------------------------
    -- 0. Resolver el EE del grupo recibido (para el gate).
    -- -----------------------------------------------------------------
    SELECT s.FK_TESTABLECIMIENTO
      INTO v_fk_establecimiento
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO g              ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa  ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s                ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE gr.PK_TGRUPO = p_fk_tgrupo
       AND gr.ACTIVE    = TRUE
       AND g.ACTIVE     = TRUE
       AND pa.ACTIVE    = TRUE
       AND s.ACTIVE     = TRUE;

    IF v_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'No se encontro un grupo activo con ese identificador'
            USING ERRCODE = '22023', HINT = 'p_fk_tgrupo debe apuntar a un TGRUPO activo, con grado/periodo/sede activos';
    END IF;

    -- -----------------------------------------------------------------
    -- 1. Gate de autorizacion COMPUESTO -- mismo patron de fn_sed_crear /
    --    fn_estudiante_crear / fn_padre_crear.
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
    -- 2. Validaciones de obligatoriedad (los NOT NULL del DDL).
    -- -----------------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TESTUDIANTE WHERE PK_TESTUDIANTE = p_fk_testudiante AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se encontro un estudiante activo con ese identificador'
            USING ERRCODE = '22023', HINT = 'p_fk_testudiante debe apuntar a un TESTUDIANTE activo';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_tlv_estado_matricula AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'estado de matricula (%) no existe o no esta activo', p_fk_tlv_estado_matricula
            USING ERRCODE = '23503';
    END IF;

    IF UPPER(COALESCE(p_estudiante_nuevo, '')) NOT IN ('S', 'N') THEN
        RAISE EXCEPTION 'estudiante_nuevo debe ser ''S'' o ''N''' USING ERRCODE = '23502';
    END IF;

    -- -----------------------------------------------------------------
    -- 3. Validacion de FKs opcionales, solo si llegan no-NULL.
    -- -----------------------------------------------------------------
    IF p_fk_enfasis IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TENFASIS WHERE PK_TENFASIS = p_fk_enfasis AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'enfasis (%) no existe o no esta activo', p_fk_enfasis USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_situacion_academica IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_tlv_situacion_academica AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'situacion academica (%) no existe o no esta activa', p_fk_tlv_situacion_academica USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 4. INSERT.
    -- -----------------------------------------------------------------
    INSERT INTO academico_test.TMATRICULA (
        FK_TESTUDIANTE, FK_TGRUPO, FK_TLV_ESTADO_MATRICULA, ESTUDIANTE_NUEVO,
        FK_ENFASIS, FK_TLV_SITUACION_ACADEMICA,
        CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        p_fk_testudiante, p_fk_tgrupo, p_fk_tlv_estado_matricula, UPPER(p_estudiante_nuevo),
        p_fk_enfasis, p_fk_tlv_situacion_academica,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TMATRICULA INTO v_id_creado;

    RAISE NOTICE 'TMATRICULA creada: PK=%, FK_TESTUDIANTE=%, FK_TGRUPO=%', v_id_creado, p_fk_testudiante, p_fk_tgrupo;

    RETURN v_id_creado;
END;
$function$;

-- =============================================================================
-- fn_matricula_obtener_por_id -- GET granular de UNA TMATRICULA, con los
-- nombres de catalogo resueltos y el contexto academico completo
-- (grupo -> grado -> periodo -> sede/jornada/año lectivo), que es lo que
-- el front necesita para reconstruir los selects encadenados del
-- formulario sin pedir cada nivel por separado.
--
-- Gate: estricto (sede-especifico), a diferencia de los obtener_por_id de
-- estudiante/acudiente -- aca SI se conoce la sede (via el grupo de la
-- matricula), asi que no hay razon para relajarlo: ver el comentario de
-- fn_estudiante_obtener_por_id (V160) sobre por que aquellos no pueden
-- escalar por sede y este si.
--
-- 0 filas si el PK no existe / esta inactivo (no lanza excepcion) -- solo
-- el gate y una matricula fuera de alcance producen error.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_obtener_por_id(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_tmatricula           BIGINT
)
RETURNS TABLE (
    pk_tmatricula                 BIGINT,
    fk_testudiante                BIGINT,
    fk_tgrupo                     BIGINT,
    grupo_nombre                  VARCHAR,
    fk_tgrado                     BIGINT,
    grado_nombre                  VARCHAR,
    fk_tperiodo_academico         BIGINT,
    periodo_nombre                VARCHAR,
    fk_tsede                      BIGINT,
    sede_nombre                   VARCHAR,
    fk_testablecimiento           BIGINT,
    fk_tlv_jornada                BIGINT,
    jornada_nombre                VARCHAR,
    fk_tano_lectivo               BIGINT,
    ano_lectivo_nombre            VARCHAR,
    fk_enfasis                    BIGINT,
    enfasis_nombre                VARCHAR,
    fk_tlv_estado_matricula       BIGINT,
    estado_matricula_nombre       VARCHAR,
    fk_tlv_situacion_academica    BIGINT,
    situacion_academica_nombre    VARCHAR,
    estudiante_nuevo              academico_test.bool_sn,
    estudiante_repitente          academico_test.bool_sn,
    promocion_anticipada          academico_test.bool_sn,
    fk_tpadre                     BIGINT,
    fk_tlv_acudiente_parentesco   BIGINT,
    fk_tinscripcion               BIGINT,
    fk_tprematricula              BIGINT,
    fk_tmatricula_anterior        BIGINT,
    created_at                    TIMESTAMP
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_fk_establecimiento BIGINT;
BEGIN
    -- -----------------------------------------------------------------
    -- 0. Resolver el EE de la matricula (para el gate). Si no resuelve,
    --    la matricula no existe o esta inactiva -> 0 filas, sin error.
    -- -----------------------------------------------------------------
    SELECT s.FK_TESTABLECIMIENTO
      INTO v_fk_establecimiento
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr              ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO g               ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa   ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s                 ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE m.PK_TMATRICULA = p_pk_tmatricula
       AND m.ACTIVE        = TRUE
       AND gr.ACTIVE       = TRUE
       AND g.ACTIVE        = TRUE
       AND pa.ACTIVE       = TRUE
       AND s.ACTIVE        = TRUE;

    IF v_fk_establecimiento IS NULL THEN
        RETURN;
    END IF;

    -- -----------------------------------------------------------------
    -- 1. Gate de autorizacion COMPUESTO -- mismo patron de V163/V164/V165.
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

    RETURN QUERY
    SELECT
        m.PK_TMATRICULA,
        m.FK_TESTUDIANTE,
        m.FK_TGRUPO, gr.NOMBRE,
        gr.FK_TGRADO, g.NOMBRE,
        g.FK_TPERIODO_ACADEMICO, pa.NOMBRE,
        pa.FK_TSEDE, s.NOMBRE,
        s.FK_TESTABLECIMIENTO,
        pa.FK_TLV_JORNADA, jor.NOMBRE,
        pa.FK_TANO_LECTIVO, al.NOMBRE,
        m.FK_ENFASIS, enf.NOMBRE,
        m.FK_TLV_ESTADO_MATRICULA, est.NOMBRE,
        m.FK_TLV_SITUACION_ACADEMICA, sit.NOMBRE,
        m.ESTUDIANTE_NUEVO,
        m.ESTUDIANTE_REPITENTE,
        m.PROMOCION_ANTICIPADA,
        m.FK_TPADRE,
        m.FK_TLV_ACUDIENTE_PARENTESCO,
        m.FK_TINSCRIPCION,
        m.FK_TPREMATRICULA,
        m.FK_TMATRICULA_ANTERIOR,
        m.CREATED_AT
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr              ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO g               ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa   ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s                 ON s.PK_TSEDE = pa.FK_TSEDE
      JOIN academico_test.TANO_LECTIVO al         ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
 LEFT JOIN academico_test.TLISTA_VALOR jor        ON jor.PK_LISTA_VALOR = pa.FK_TLV_JORNADA
 LEFT JOIN academico_test.TENFASIS enf            ON enf.PK_TENFASIS = m.FK_ENFASIS
 LEFT JOIN academico_test.TLISTA_VALOR est        ON est.PK_LISTA_VALOR = m.FK_TLV_ESTADO_MATRICULA
 LEFT JOIN academico_test.TLISTA_VALOR sit        ON sit.PK_LISTA_VALOR = m.FK_TLV_SITUACION_ACADEMICA
     WHERE m.PK_TMATRICULA = p_pk_tmatricula
       AND m.ACTIVE        = TRUE
     LIMIT 1;
END;
$function$;
