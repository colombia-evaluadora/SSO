-- ===========================================================================
-- V506 - Prematricula (5/9): el INSERT, en crudo.
--
--   fn_prematricula_crear(...) -> PK_TPREMATRICULA
--
--   Sin permisos, sin reglas de negocio, sin resolver destinos. Recibe todo
--   ya decidido y escribe la fila. Lo unico que comprueba es lo que el DDL no
--   puede: que el estudiante y el grupo existan y esten activos, para no
--   dejar una FK apuntando a algo dado de baja.
--
--
-- POR QUE SEPARADA
--   Mismo criterio que el modulo de matricula: el alta cruda es una cosa y
--   la orquestacion es otra. Asi la funcion general (V508) se lee como lo que
--   hace -- decidir a donde va cada uno -- y no como un INSERT gigante, y
--   esta se puede reusar el dia que haya un alta de prematricula individual
--   desde pantalla, que hoy no existe.
--
--
-- LO QUE SE ARRASTRA DE LA MATRICULA ANTERIOR
--   El acudiente (FK_TPADRE + FK_TLV_ACUDIENTE_PARENTESCO) y la bandera
--   EDICION_ACUDIENTE viajan desde la matricula de origen. Cambiar esos datos
--   NO es parte de este proceso: quien tenga que corregirlos lo hara despues,
--   sobre la prematricula ya creada. Por eso son parametros y no se leen aca
--   -- esta funcion no sabe de donde vienen.
--
-- Idempotente: CREATE OR REPLACE.
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_prematricula_crear(
    p_fk_testudiante               BIGINT,
    p_fk_tgrupo                    BIGINT,
    p_fk_tlv_estado_prematricula   BIGINT,
    p_fk_tpadre                    BIGINT  DEFAULT NULL,
    p_fk_tlv_acudiente_parentesco  BIGINT  DEFAULT NULL,
    p_edicion_acudiente            VARCHAR DEFAULT 'S',
    p_fecha_vencimiento            DATE    DEFAULT NULL,
    p_created_by                   VARCHAR DEFAULT 'fn_prematricula_crear'
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk  BIGINT;
BEGIN
    IF p_fk_testudiante IS NULL OR p_fk_tgrupo IS NULL
       OR p_fk_tlv_estado_prematricula IS NULL THEN
        RAISE EXCEPTION 'fn_prematricula_crear: estudiante, grupo y estado son obligatorios'
            USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM academico_test.TESTUDIANTE
                    WHERE PK_TESTUDIANTE = p_fk_testudiante AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El estudiante % no existe o no esta activo', p_fk_testudiante
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM academico_test.TGRUPO
                    WHERE PK_TGRUPO = p_fk_tgrupo AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El grupo % no existe o no esta activo', p_fk_tgrupo
            USING ERRCODE = '23503';
    END IF;

    INSERT INTO academico_test.TPREMATRICULA (
        FK_TESTUDIANTE, FK_TGRUPO, FK_TLV_ESTADO_PREMATRICULA,
        FK_TPADRE, FK_TLV_ACUDIENTE_PARENTESCO,
        EDICION_ACUDIENTE, FECHA_VENCIMIENTO, CREATED_BY
    ) VALUES (
        p_fk_testudiante, p_fk_tgrupo, p_fk_tlv_estado_prematricula,
        p_fk_tpadre, p_fk_tlv_acudiente_parentesco,
        COALESCE(p_edicion_acudiente, 'S'), p_fecha_vencimiento, p_created_by
    )
    RETURNING PK_TPREMATRICULA INTO v_pk;

    RETURN v_pk;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_prematricula_crear(BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, DATE, VARCHAR)
    IS 'INSERT crudo en TPREMATRICULA. NO valida permisos, ni cupo, ni si el estudiante ya estaba prematriculado, ni resuelve a que grupo va: recibe todo decidido. Solo comprueba lo que el DDL no alcanza -- estudiante y grupo existentes y ACTIVE --, para no dejar una FK apuntando a algo dado de baja. El acudiente y EDICION_ACUDIENTE llegan por parametro porque los arrastra quien orquesta (fn_prematricula_grupo_procesar) desde la matricula de origen; cambiarlos no es parte de este proceso. Separada del resto con el mismo criterio que el modulo de matricula: el alta cruda es reusable, la orquestacion no.';
