-- ===========================================================================
-- V175 - fn_matricula_replicar: copia una matricula a otro grupo/grado.
--
--   Las funciones de lote (mover, promover, reubicar) y el chequeo de estado
--   que nacieron aqui viven hoy en V178 y V233.
-- ===========================================================================


CREATE OR REPLACE FUNCTION academico_test.fn_matricula_replicar(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_tmatricula_origen    BIGINT,
    p_fk_tgrupo_destino       BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $function$
DECLARE
    v_pk_nueva     BIGINT;
    v_pk_cursando  BIGINT;
BEGIN
    SELECT PK_LISTA_VALOR INTO v_pk_cursando
      FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ESTADO_MATRICULA' AND VALOR = '1' AND ACTIVE = TRUE;

    IF v_pk_cursando IS NULL THEN
        RAISE EXCEPTION 'El catalogo ESTADO_MATRICULA no tiene el estado "Cursando" (VALOR ''1'')'
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 1. La matricula nueva.
    -- -----------------------------------------------------------------
    INSERT INTO academico_test.TMATRICULA (
        FK_TESTUDIANTE, FK_TGRUPO, FK_TLV_ESTADO_MATRICULA, ESTUDIANTE_NUEVO,
        FK_ENFASIS, FK_TPADRE, FK_TLV_ACUDIENTE_PARENTESCO,
        FK_TLV_SITUACION_ACADEMICA, ESTADO_CONVIVE_ACUDIENTE, EDICION_ACUDIENTE,
        FK_TMATRICULA_ANTERIOR,
        CREATED_BY, CREATED_AT, ACTIVE
    )
    SELECT m.FK_TESTUDIANTE, p_fk_tgrupo_destino, v_pk_cursando, 'N',
           m.FK_ENFASIS, m.FK_TPADRE, m.FK_TLV_ACUDIENTE_PARENTESCO,
           m.FK_TLV_SITUACION_ACADEMICA, m.ESTADO_CONVIVE_ACUDIENTE, m.EDICION_ACUDIENTE,
           m.PK_TMATRICULA,
           p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
      FROM academico_test.TMATRICULA m
     WHERE m.PK_TMATRICULA = p_pk_tmatricula_origen
    RETURNING PK_TMATRICULA INTO v_pk_nueva;

    IF v_pk_nueva IS NULL THEN
        RAISE EXCEPTION 'No se pudo replicar la matricula % -- no existe', p_pk_tmatricula_origen
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Copia del perfil socioeconomico (1 a 1). Si la matricula vieja
    --    no lo tiene -- datos migrados -- no se inventa una fila vacia.
    -- -----------------------------------------------------------------
    INSERT INTO academico_test.TMATRICULA_SOCIOECONOMICO (
        FK_TMATRICULA, PROVIENE_SECTOR_PRIVADO, PROVIENE_OTRO_MUNICIPIO,
        PROVIENE_OTRO_MUNICIPIO_CUAL, INSTITUCION_ORIGEN,
        FK_TLV_TIPO_INSTITUCION_ORIGEN, FK_TLV_CONDICION_PROMOCION,
        FK_TLV_VICTIMA_CONFLICTO, FK_TMUNICIPIO_VICTIMA,
        SEGURIDAD_SOCIAL_ARS, SEGURIDAD_SOCIAL_EPS, ESTUDIANTE_SUBSIDIADO,
        BENEFICIARIO_CABEZA_FAMILIA, BEN_HIJO_CABEZA_FAMILIA,
        BENEFICIARIO_VETERANO, BENEFICIARIO_HEROE, FK_TLV_FUENTE_RECURSO,
        CREATED_BY, CREATED_AT, ACTIVE
    )
    SELECT v_pk_nueva, se.PROVIENE_SECTOR_PRIVADO, se.PROVIENE_OTRO_MUNICIPIO,
           se.PROVIENE_OTRO_MUNICIPIO_CUAL, se.INSTITUCION_ORIGEN,
           se.FK_TLV_TIPO_INSTITUCION_ORIGEN, se.FK_TLV_CONDICION_PROMOCION,
           se.FK_TLV_VICTIMA_CONFLICTO, se.FK_TMUNICIPIO_VICTIMA,
           se.SEGURIDAD_SOCIAL_ARS, se.SEGURIDAD_SOCIAL_EPS, se.ESTUDIANTE_SUBSIDIADO,
           se.BENEFICIARIO_CABEZA_FAMILIA, se.BEN_HIJO_CABEZA_FAMILIA,
           se.BENEFICIARIO_VETERANO, se.BENEFICIARIO_HEROE, se.FK_TLV_FUENTE_RECURSO,
           p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
      FROM academico_test.TMATRICULA_SOCIOECONOMICO se
     WHERE se.FK_TMATRICULA = p_pk_tmatricula_origen
       AND se.ACTIVE        = TRUE;

    -- -----------------------------------------------------------------
    -- 3. Copia de los enlaces a documentos -- mismo PK_TARCHIVO, no se
    --    duplica nada en S3 (ver cabecera).
    -- -----------------------------------------------------------------
    INSERT INTO academico_test.TMATRICULA_ARCHIVO (
        FK_TMATRICULA, FK_TARCHIVO, FK_TLV_TIPO_ARCHIVO,
        CREATED_BY, CREATED_AT, ACTIVE
    )
    SELECT v_pk_nueva, ma.FK_TARCHIVO, ma.FK_TLV_TIPO_ARCHIVO,
           p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
      FROM academico_test.TMATRICULA_ARCHIVO ma
     WHERE ma.FK_TMATRICULA = p_pk_tmatricula_origen
       AND ma.ACTIVE        = TRUE;

    RETURN v_pk_nueva;
END;
$function$;
