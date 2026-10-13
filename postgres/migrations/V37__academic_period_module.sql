-- ===========================================================================
-- V37 -- Periodo academico: helpers de alcance compartidos y año lectivo
-- ===========================================================================
-- QUE HACE: fn_es_super_admin y fn_periodo_usuario_* (alcance por TSEDE_USUARIO
-- que siguen usando otros modulos) y u_tano_lectivo_1 como indice unico TOTAL,
-- arbitro del upsert del año lectivo (antes V146).
-- POR QUE AQUI: el CRUD del modulo vive en V37.1 / V37.2 / V37.3.
-- DEPENDE DE: V22 (TSEDE_USUARIO, TSEDE, TPERIODO_ACADEMICO, TANO_LECTIVO).
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_es_super_admin(p_pk_usuario BIGINT)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM academico_test.TSEDE_USUARIO
         WHERE FK_TUSUARIO = p_pk_usuario AND FK_TROL = 1 AND ACTIVE = TRUE
    );
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_usuario_global(p_pk_usuario BIGINT)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM academico_test.TSEDE_USUARIO
         WHERE FK_TUSUARIO = p_pk_usuario AND ACTIVE = TRUE AND FK_TROL IN (1, 2, 3)
    );
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_usuario_establecimientos(p_pk_usuario BIGINT)
RETURNS TABLE (establecimiento_id BIGINT) LANGUAGE sql STABLE AS $$
    SELECT DISTINCT s.FK_TESTABLECIMIENTO
      FROM academico_test.TSEDE_USUARIO su
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
     WHERE su.FK_TUSUARIO = p_pk_usuario AND su.ACTIVE = TRUE
       AND su.FK_TROL IN (7, 8, 9);
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_usuario_sedes(p_pk_usuario BIGINT)
RETURNS TABLE (sede_id BIGINT) LANGUAGE sql STABLE AS $$
    SELECT DISTINCT su.FK_TSEDE
      FROM academico_test.TSEDE_USUARIO su
     WHERE su.FK_TUSUARIO = p_pk_usuario AND su.ACTIVE = TRUE
       AND su.FK_TROL IN (11);
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_usuario_puede_ver(
    p_pk_usuario BIGINT, p_fk_periodo BIGINT
)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT academico_test.fn_periodo_usuario_global(p_pk_usuario)
        OR EXISTS (
            SELECT 1
              FROM academico_test.TPERIODO_ACADEMICO pa
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
             WHERE pa.PK_TPERIODO_ACADEMICO = p_fk_periodo
               AND ( s.FK_TESTABLECIMIENTO IN (
                         SELECT establecimiento_id
                           FROM academico_test.fn_periodo_usuario_establecimientos(p_pk_usuario))
                     OR pa.FK_TSEDE IN (
                         SELECT sede_id
                           FROM academico_test.fn_periodo_usuario_sedes(p_pk_usuario)) )
        );
$$;

-- fn_periodo_ano_lectivo_asegurar_interno hace ON CONFLICT (FK_TESTABLECIMIENTO,
-- NOMBRE) sin predicado: solo un unico TOTAL lo arbitra. Va como indice y no
-- como constraint para que V71 (DROP CONSTRAINT + CREATE INDEX IF NOT EXISTS
-- parcial) lo deje como esta. Coste: un año lectivo dado de baja reserva su nombre.
DO $$
DECLARE
    v_es_constraint BOOLEAN;
    v_es_total      BOOLEAN;
    v_duplicados    BIGINT;
BEGIN
    v_es_constraint := EXISTS (SELECT 1 FROM pg_constraint
                                WHERE conname = 'u_tano_lectivo_1'
                                  AND conrelid = 'academico_test.tano_lectivo'::regclass);
    SELECT indexdef NOT ILIKE '%WHERE%' INTO v_es_total
      FROM pg_indexes WHERE schemaname = 'academico_test' AND indexname = 'u_tano_lectivo_1';
    IF v_es_total AND NOT v_es_constraint THEN
        RETURN;
    END IF;

    SELECT count(*) INTO v_duplicados
      FROM (SELECT 1 FROM academico_test.TANO_LECTIVO
             GROUP BY FK_TESTABLECIMIENTO, NOMBRE HAVING count(*) > 1) d;
    IF v_duplicados > 0 THEN
        RAISE EXCEPTION 'TANO_LECTIVO: % combinaciones (FK_TESTABLECIMIENTO, NOMBRE) duplicadas contando inactivas; el indice unico total no se puede crear',
            v_duplicados USING ERRCODE = '23505';
    END IF;

    IF v_es_constraint THEN
        ALTER TABLE academico_test.TANO_LECTIVO DROP CONSTRAINT u_tano_lectivo_1;
    ELSE
        DROP INDEX IF EXISTS academico_test.u_tano_lectivo_1;
    END IF;
    CREATE UNIQUE INDEX u_tano_lectivo_1 ON academico_test.TANO_LECTIVO (FK_TESTABLECIMIENTO, NOMBRE);
END $$;

COMMENT ON INDEX academico_test.u_tano_lectivo_1 IS
    'Unicidad de (FK_TESTABLECIMIENTO, NOMBRE) en TANO_LECTIVO. TOTAL a proposito, no parcial como las otras de V71: es el arbitro del ON CONFLICT de fn_periodo_ano_lectivo_asegurar_interno, que no declara predicado. Contrapartida: un año lectivo inactivo sigue reservando su nombre.';
