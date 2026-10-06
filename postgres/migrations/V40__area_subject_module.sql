-- ===========================================================================
-- V40 - Helpers de grupo y matricula (alcance por grupo) que nacieron con el
-- modulo de areas y asignaturas: fn_grupo_periodo/_jornada/_establecimiento,
-- fn_matricula_grupo, fn_matricula_gate_escritura, fn_matricula_puede_ver,
-- y el esquema del enfasis por sede (TENFASIS.FK_TSEDE y la copia por sede).
-- El CRUD de area, asignatura y enfasis vive en V40.2 (validaciones),
-- V40.3 (nucleos) y V40.4 (wrappers).
-- ===========================================================================


CREATE OR REPLACE FUNCTION academico_test.fn_grupo_periodo(p_fk_tgrupo BIGINT)
RETURNS BIGINT LANGUAGE sql STABLE AS $$
    SELECT g.FK_TPERIODO_ACADEMICO
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
     WHERE gr.PK_TGRUPO = p_fk_tgrupo;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_jornada(p_fk_tgrupo BIGINT)
RETURNS BIGINT LANGUAGE sql STABLE AS $$
    SELECT gr.FK_TLV_JORNADA
      FROM academico_test.TGRUPO gr
     WHERE gr.PK_TGRUPO = p_fk_tgrupo;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_establecimiento(p_fk_tgrupo BIGINT)
RETURNS BIGINT LANGUAGE sql STABLE AS $$
    SELECT academico_test.fn_periodo_establecimiento(academico_test.fn_grupo_periodo(p_fk_tgrupo));
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_grupo(p_fk_tmatricula BIGINT)
RETURNS BIGINT LANGUAGE sql STABLE AS $$
    SELECT m.FK_TGRUPO
      FROM academico_test.TMATRICULA m
     WHERE m.PK_TMATRICULA = p_fk_tmatricula;
$$;

COMMENT ON FUNCTION academico_test.fn_grupo_jornada(BIGINT)
    IS 'FK_TLV_JORNADA del grupo (NULL si no existe). Es la jornada autoritativa de toda matricula de ese grupo (u_tgrupo_1 = fk_tgrado, fk_tlv_jornada, nombre).';

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_gate_escritura(
    p_pk_usuario  BIGINT,
    p_fk_tgrupo   BIGINT,
    p_accion      VARCHAR DEFAULT 'EDITAR'
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario, 'MATRICULA', p_accion,
        academico_test.fn_grupo_establecimiento(p_fk_tgrupo),
        academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(p_fk_tgrupo)),
        academico_test.fn_grupo_jornada(p_fk_tgrupo));
END;
$$;

COMMENT ON FUNCTION academico_test.fn_matricula_gate_escritura(BIGINT, BIGINT, VARCHAR)
    IS 'Gate de ESCRITURA de la seccion Matricula (estudiante/acudiente al ligarlos, matricula, socioeconomico, archivos, matricula directa). Wrapper de una linea sobre fn_assert_permiso_seccion (V29), menu ''MATRICULA''. Mismo modelo que fn_periodo_gate_escritura: CAPABILITY dinamica (TROL_MENU concede / TUSUARIO_ROL_PERMISO recorta) + SCOPE por categoria de rol (nivel 1 territorial = todos los EE; nivel 2 = fn_usuario_ee_accesibles; nivel 3 = par (sede, jornada) del grupo en fn_usuario_sedes_jornadas_accesibles) + BYPASS del SUPER_ADMIN. El scope se resuelve por el grupo: TMATRICULA -> TGRUPO -> TGRADO -> TPERIODO_ACADEMICO. Con p_fk_tgrupo NULL las tres coordenadas quedan NULL y solo se exige capability (altas de persona sin sede todavia).';

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_puede_ver(
    p_pk_usuario  BIGINT,
    p_fk_tgrupo   BIGINT
)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_nivel INT;
BEGIN
    IF p_pk_usuario IS NULL THEN
        RETURN TRUE;
    END IF;

    v_nivel := COALESCE(academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario), 99);

    IF v_nivel = 0 THEN
        RETURN TRUE;
    END IF;

    IF NOT academico_test.fn_usuario_puede_en_menu(p_pk_usuario, 'MATRICULA', 'VER') THEN
        RETURN FALSE;
    END IF;

    IF v_nivel = 1 THEN
        RETURN TRUE;
    ELSIF v_nivel = 2 THEN
        RETURN academico_test.fn_grupo_establecimiento(p_fk_tgrupo) IN (
                   SELECT establecimiento_id
                     FROM academico_test.fn_usuario_ee_accesibles(p_pk_usuario));
    ELSIF v_nivel = 3 THEN
        RETURN (
                   academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(p_fk_tgrupo)),
                   academico_test.fn_grupo_jornada(p_fk_tgrupo)
               ) IN (
                   SELECT sede_id, jornada_id
                     FROM academico_test.fn_usuario_sedes_jornadas_accesibles(p_pk_usuario));
    END IF;

    RETURN FALSE;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_matricula_puede_ver(BIGINT, BIGINT)
    IS 'Version BOOLEAN de fn_matricula_gate_escritura para el WHERE de fn_matricula_listar (V200): capability ''VER'' sobre el menu MATRICULA + scope por categoria de rol, resuelto por el grupo. p_pk_usuario NULL o SUPER_ADMIN => TRUE. Reemplaza a fn_periodo_usuario_puede_ver en el listado de matricula. No lanza (no subtransaccion por fila).';

-- ------------------------------------------------- enfasis por sede (esquema)
-- El enfasis es de la sede, no del establecimiento. FK_TESTABLECIMIENTO se
-- conserva (lo leen reportes y auditoria) y se llena con el de la sede.
-- Va aqui y no en V40.x: el deploy re-ejecuta las editadas antes de aplicar
-- las pendientes, y la copia tiene que correr antes que los unicos por sede.
ALTER TABLE academico_test.TENFASIS ADD COLUMN IF NOT EXISTS FK_TSEDE BIGINT;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_tenfasis_sede'
                      AND conrelid = 'academico_test.tenfasis'::regclass) THEN
        ALTER TABLE academico_test.TENFASIS
            ADD CONSTRAINT FK_TENFASIS_SEDE FOREIGN KEY (FK_TSEDE) REFERENCES academico_test.TSEDE (PK_TSEDE);
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS IDX_TENFASIS_SEDE ON academico_test.TENFASIS (FK_TSEDE);

-- Los unicos por establecimiento impedirian las copias por sede. Solo se
-- borran si siguen siendo por establecimiento; tras la copia se crean por sede.
ALTER TABLE academico_test.TENFASIS DROP CONSTRAINT IF EXISTS U_TENFASIS_1;
ALTER TABLE academico_test.TENFASIS DROP CONSTRAINT IF EXISTS U_TENFASIS_2;
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT indexname FROM pg_indexes
              WHERE schemaname = 'academico_test' AND indexname IN ('u_tenfasis_1', 'u_tenfasis_2')
                AND indexdef ILIKE '%fk_testablecimiento%' LOOP
        EXECUTE format('DROP INDEX academico_test.%I', r.indexname);
    END LOOP;
END $$;

-- Copia cada enfasis sin sede a cada sede que lo usa (asignaturas, matriculas,
-- convenios) y, si esta activo, a cada sede activa del establecimiento. La
-- primera sede se queda la fila original; las demas reciben una copia y sus
-- usos se reapuntan. Idempotente: solo toca filas con FK_TSEDE NULL.
DO $$
DECLARE
    r        RECORD;
    v_sede   BIGINT;
    v_target BIGINT;
    v_first  BOOLEAN;
BEGIN
    FOR r IN SELECT * FROM academico_test.TENFASIS WHERE FK_TSEDE IS NULL ORDER BY PK_TENFASIS LOOP
        v_first := TRUE;
        FOR v_sede IN
            SELECT u.sede FROM (
                SELECT pa.FK_TSEDE AS sede
                  FROM academico_test.TASIGNATURA a
                  JOIN academico_test.TAREA ar ON ar.PK_TAREA = a.FK_TAREA
                  JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = ar.FK_TPERIODO_ACADEMICO
                 WHERE a.FK_TENFASIS = r.PK_TENFASIS
                UNION
                SELECT academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(m.FK_TGRUPO))
                  FROM academico_test.TMATRICULA m
                 WHERE m.FK_ENFASIS = r.PK_TENFASIS
                UNION
                SELECT academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(c.FK_TGRUPO_DESTINO))
                  FROM academico_test.TSEDE_CONVENIO_MATRICULA c
                 WHERE c.FK_TENFASIS_DESTINO = r.PK_TENFASIS
                UNION
                SELECT s.PK_TSEDE
                  FROM academico_test.TSEDE s
                 WHERE s.FK_TESTABLECIMIENTO = r.FK_TESTABLECIMIENTO AND s.ACTIVE = TRUE AND r.ACTIVE = TRUE
            ) u
             WHERE u.sede IS NOT NULL
             ORDER BY u.sede
        LOOP
            IF v_first THEN
                UPDATE academico_test.TENFASIS SET FK_TSEDE = v_sede WHERE PK_TENFASIS = r.PK_TENFASIS;
                v_first := FALSE;
                CONTINUE;
            END IF;

            INSERT INTO academico_test.TENFASIS
                (CODIGO, NOMBRE, FK_TESPECIALIDAD, FK_TESTABLECIMIENTO, FK_TSEDE, CREATED_BY, ACTIVE)
            SELECT r.CODIGO, r.NOMBRE, r.FK_TESPECIALIDAD, s.FK_TESTABLECIMIENTO, v_sede, 'enfasis_por_sede', r.ACTIVE
              FROM academico_test.TSEDE s WHERE s.PK_TSEDE = v_sede
            RETURNING PK_TENFASIS INTO v_target;

            UPDATE academico_test.TASIGNATURA a SET FK_TENFASIS = v_target
              FROM academico_test.TAREA ar, academico_test.TPERIODO_ACADEMICO pa
             WHERE a.FK_TENFASIS = r.PK_TENFASIS AND ar.PK_TAREA = a.FK_TAREA
               AND pa.PK_TPERIODO_ACADEMICO = ar.FK_TPERIODO_ACADEMICO AND pa.FK_TSEDE = v_sede;
            UPDATE academico_test.TMATRICULA m SET FK_ENFASIS = v_target
             WHERE m.FK_ENFASIS = r.PK_TENFASIS
               AND academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(m.FK_TGRUPO)) = v_sede;
            UPDATE academico_test.TSEDE_CONVENIO_MATRICULA c SET FK_TENFASIS_DESTINO = v_target
             WHERE c.FK_TENFASIS_DESTINO = r.PK_TENFASIS
               AND academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(c.FK_TGRUPO_DESTINO)) = v_sede;
        END LOOP;

        -- Inactivo y sin uso: queda en la primera sede del establecimiento.
        IF v_first THEN
            UPDATE academico_test.TENFASIS
               SET FK_TSEDE = (SELECT min(PK_TSEDE) FROM academico_test.TSEDE
                                WHERE FK_TESTABLECIMIENTO = r.FK_TESTABLECIMIENTO)
             WHERE PK_TENFASIS = r.PK_TENFASIS;
        END IF;
    END LOOP;

    -- Un establecimiento sin sedes deja su enfasis sin sede: ahi no se exige NOT NULL.
    IF NOT EXISTS (SELECT 1 FROM academico_test.TENFASIS WHERE FK_TSEDE IS NULL) THEN
        ALTER TABLE academico_test.TENFASIS ALTER COLUMN FK_TSEDE SET NOT NULL;
    ELSE
        RAISE NOTICE 'TENFASIS: quedan filas sin sede (establecimiento sin sedes); FK_TSEDE sigue admitiendo NULL';
    END IF;
END $$;

-- Nombre y codigo unicos por sede, parciales sobre los activos. V71 los
-- salta en una base limpia (IF NOT EXISTS con el mismo nombre).
CREATE UNIQUE INDEX IF NOT EXISTS u_tenfasis_1 ON academico_test.tenfasis (fk_tsede, codigo) WHERE active = true;
CREATE UNIQUE INDEX IF NOT EXISTS u_tenfasis_2 ON academico_test.tenfasis (fk_tsede, nombre) WHERE active = true;

COMMENT ON COLUMN academico_test.TENFASIS.FK_TSEDE IS 'Sede duena del enfasis; nombre y codigo son unicos por sede';
