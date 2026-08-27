-- ===========================================================================
--  Cobertura Matricula (CU-86e2z8aff) -- funciones de configuracion,
--  configuracion por defecto al crear un establecimiento y candado de
--  campos no editables.
--
--  --------------------------------------------------------------------------
--  Revision de constraints de las tablas involucradas (V157 / V158):
--
--   TMATRICULA_CAMPO
--     * PK_MATRICULA_CAMPO identity.
--     * NOMBRE NOT NULL (sin UNIQUE -- el seed de V158 se protege por NOMBRE).
--     * U_TMATRICULA_CAMPO_1 UNIQUE (TABLA, CAMPO_DESTINO): hoy inerte
--       porque las 61 filas tienen TABLA/CAMPO_DESTINO NULL.
--     * EDITABLE bool_sn NOT NULL DEFAULT 'S'.
--
--   TMATRICULA_CONFIG
--     * PK_MATRICULA_CONFIG identity.
--     * FK_TESTABLECIMIENTO NOT NULL -> TESTABLECIMIENTO(PK_ESTABLECIMIENTO).
--     * U_TMATRICULA_CONFIG_1 UNIQUE (FK_TESTABLECIMIENTO)  <-- CLAVE:
--       hay COMO MUCHO UNA configuracion por establecimiento. Por eso "la
--       configuracion por defecto" ES la configuracion del EE, y se puede
--       sembrar con INSERT ... ON CONFLICT (FK_TESTABLECIMIENTO) DO NOTHING.
--
--   TMATRICULA_VALOR
--     * PK_MATRICULA_VALOR identity.
--     * REQUERIDO bool_sn NOT NULL DEFAULT 'N', VISIBLE bool_sn NOT NULL
--       DEFAULT 'S'.
--     * FK_TMATRICULA_CONFIG NOT NULL -> TMATRICULA_CONFIG, ON DELETE CASCADE
--       (borrar la config se lleva sus valores).
--     * FK_TMATRICULA_CAMPO  NOT NULL -> TMATRICULA_CAMPO.
--     * U_TMATRICULA_VALOR_1 UNIQUE (FK_TMATRICULA_CONFIG, FK_TMATRICULA_CAMPO)
--       <-- CLAVE: una fila por (config, campo). Habilita el upsert
--       ON CONFLICT de fn_matricula_config_actualizar y hace idempotente
--       el sembrado (re-ejecutar solo agrega los campos que falten).
--
--  --------------------------------------------------------------------------
--  Que agrega esta migracion:
--
--   0. TMATRICULA_CONFIG.FK_TESTABLECIMIENTO -> ON DELETE CASCADE.
--   1. TMATRICULA_CAMPO.REQUERIDO_DEFECTO / VISIBLE_DEFECTO: la "definicion
--      de configuracion por defecto" vive en el catalogo de campos -- cada
--      campo dice como entra en una config recien creada. POR AHORA todos
--      entran en 'S'/'S' (default de columna), asi que no hay seed por campo.
--   2. Campos NO editables (columna destino NOT NULL en la BD) -> EDITABLE = 'N'.
--      Su REQUERIDO/VISIBLE no se puede cambiar desde la config del EE.
--   3. fn_matricula_config_crear_interno(fk_est, created_by): motor sin gate
--      de permisos. Crea (o reutiliza) la config del EE y siembra un
--      TMATRICULA_VALOR por cada campo activo copiando *_DEFECTO. Idempotente.
--   4. fn_matricula_config_crear(usuario, fk_est): API con gate
--      (fn_puede_afectar_establecimiento). Falla 23505 si el EE ya tiene
--      config. Delega en el motor interno.
--   5. fn_matricula_config_actualizar(usuario, fk_est, valores JSONB): con
--      gate. Upsert de REQUERIDO/VISIBLE por campo. Autocrea la config si
--      no existiera (una config por EE es un invariante).
--   6. Candado de campos no editables: si TMATRICULA_CAMPO.EDITABLE = 'N',
--      su fila en TMATRICULA_VALOR SIEMPRE sale REQUERIDO='S' y VISIBLE='S'
--      para cualquier establecimiento, sin posibilidad de edicion. Se
--      aplica por trigger BEFORE en TMATRICULA_VALOR (coacciona en toda via
--      de escritura) + trigger en TMATRICULA_CAMPO (propaga si un campo
--      pasa a no editable).
--   7. Trigger AFTER INSERT en TESTABLECIMIENTO -> siembra la config por
--      defecto en cada alta, por cualquier via (fn_est_crear o INSERT
--      directo).
--   8. Backfill para los EE que ya existen + normalizacion de los valores
--      de campos no editables que ya existieran.
-- ===========================================================================

SET client_min_messages TO WARNING;
SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 0) TMATRICULA_CONFIG.FK_TESTABLECIMIENTO -> ON DELETE CASCADE.
--    V157 lo creo sin accion de borrado, asi que ahora que TODO EE tiene
--    config (trigger + backfill) un DELETE fisico de TESTABLECIMIENTO queda
--    bloqueado por la FK. Se alinea con TMATRICULA_VALOR.FK_TMATRICULA_CONFIG
--    (que ya es ON DELETE CASCADE): borrar el EE se lleva su config y, en
--    cadena, sus valores. El borrado normal del modulo es logico
--    (ACTIVE=FALSE) y no se ve afectado.
-- ---------------------------------------------------------------------------
ALTER TABLE TMATRICULA_CONFIG DROP CONSTRAINT IF EXISTS FK_TMATRICULA_CONFIG_1;
ALTER TABLE TMATRICULA_CONFIG
    ADD CONSTRAINT FK_TMATRICULA_CONFIG_1
        FOREIGN KEY (FK_TESTABLECIMIENTO)
        REFERENCES TESTABLECIMIENTO (PK_ESTABLECIMIENTO)
        ON DELETE CASCADE;

-- ---------------------------------------------------------------------------
-- 1) Definicion de configuracion por defecto en el catalogo de campos.
--    POR AHORA la config inicial de todo EE es: TODOS los campos en
--    REQUERIDO='S' y VISIBLE='S'. Por eso ambas columnas nacen con
--    DEFAULT 'S' y no hay UPDATE de seed por campo -- las 61 filas de V158
--    heredan 'S' del ADD COLUMN. Cuando el negocio quiera un default mas
--    fino, se cambia el valor de estas columnas por campo.
-- ---------------------------------------------------------------------------
ALTER TABLE TMATRICULA_CAMPO
    ADD COLUMN IF NOT EXISTS REQUERIDO_DEFECTO bool_sn DEFAULT 'S' NOT NULL;
ALTER TABLE TMATRICULA_CAMPO
    ADD COLUMN IF NOT EXISTS VISIBLE_DEFECTO   bool_sn DEFAULT 'S' NOT NULL;

COMMENT ON COLUMN TMATRICULA_CAMPO.REQUERIDO_DEFECTO IS
    'S/N: valor de REQUERIDO con el que este campo entra en una TMATRICULA_CONFIG recien creada (por ahora siempre S)';
COMMENT ON COLUMN TMATRICULA_CAMPO.VISIBLE_DEFECTO IS
    'S/N: valor de VISIBLE con el que este campo entra en una TMATRICULA_CONFIG recien creada (por ahora siempre S)';

-- ---------------------------------------------------------------------------
-- 2) Campos NO editables: su columna destino en la BD tiene constraint
--    NOT NULL (no se puede crear una TMATRICULA sin ese dato), asi que su
--    REQUERIDO / VISIBLE no se pueden cambiar desde la config del EE
--    (quedan siempre en 'S' -- ver el candado de la seccion 6).
--
--    Mapeo campo -> columna NOT NULL (verificado contra information_schema):
--      Grupo                          tmatricula.fk_tgrupo
--      Estado de la matricula         tmatricula.fk_tlv_estado_matricula
--      Documento estudiante           tusuario.cuenta
--      Nombre del estudiante          tusuario.primer_nombre
--      Primer apellido del estudiante tusuario.primer_apellido
--      Genero del estudiante          tusuario.fk_tlv_genero
--      Fecha de nacimiento            tusuario.fecha_nacimiento
--      Parentesco                     tnucleo_familiar.fk_tlv_parentesco
--    + Sede / Jornada / Grado: selectores en cascada obligatorios para
--      poder elegir el Grupo (fk_tgrupo NOT NULL).
--
--    TABLA / CAMPO_DESTINO se dejan NULL por ahora (se cablearan aparte).
-- ---------------------------------------------------------------------------
UPDATE TMATRICULA_CAMPO
   SET EDITABLE = 'N'
 WHERE NOMBRE IN (
        'Sede',
        'Jornada',
        'Grado',
        'Grupo',
        'Estado de la matricula',
        'Documento estudiante',
        'Nombre del estudiante',
        'Primer apellido del estudiante',
        'Genero del estudiante',
        'Fecha de nacimiento',
        'Parentesco'
   )
   AND EDITABLE <> 'N';

-- ---------------------------------------------------------------------------
-- 3) fn_matricula_config_crear_interno -- motor sin gate de permisos.
--    Lo usan la API con gate, el trigger y el backfill.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_matricula_config_crear_interno(
    p_fk_establecimiento BIGINT,
    p_created_by         VARCHAR
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_config BIGINT;
    v_created   VARCHAR := COALESCE(NULLIF(TRIM(p_created_by), ''), 'SYSTEM');
BEGIN
    IF p_fk_establecimiento IS NULL OR p_fk_establecimiento <= 0 THEN
        RAISE EXCEPTION 'p_fk_establecimiento es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TESTABLECIMIENTO
         WHERE PK_ESTABLECIMIENTO = p_fk_establecimiento
    ) THEN
        RAISE EXCEPTION 'FK_TESTABLECIMIENTO (%) no existe en TESTABLECIMIENTO', p_fk_establecimiento
            USING ERRCODE = '23503';
    END IF;

    -- Una config por EE (U_TMATRICULA_CONFIG_1). Si ya existe, la reutiliza.
    INSERT INTO academico_test.TMATRICULA_CONFIG (FK_TESTABLECIMIENTO, CREATED_BY)
    VALUES (p_fk_establecimiento, v_created)
    ON CONFLICT (FK_TESTABLECIMIENTO) DO NOTHING
    RETURNING PK_MATRICULA_CONFIG INTO v_pk_config;

    IF v_pk_config IS NULL THEN
        SELECT PK_MATRICULA_CONFIG
          INTO v_pk_config
          FROM academico_test.TMATRICULA_CONFIG
         WHERE FK_TESTABLECIMIENTO = p_fk_establecimiento;
    END IF;

    -- Siembra un valor por cada campo activo con la definicion por defecto
    -- del catalogo. ON CONFLICT DO NOTHING => idempotente y sirve para
    -- "rellenar" configs viejas cuando aparecen campos nuevos en el catalogo.
    INSERT INTO academico_test.TMATRICULA_VALOR (
        REQUERIDO, VISIBLE, FK_TMATRICULA_CONFIG, FK_TMATRICULA_CAMPO, CREATED_BY
    )
    SELECT c.REQUERIDO_DEFECTO, c.VISIBLE_DEFECTO, v_pk_config, c.PK_MATRICULA_CAMPO, v_created
      FROM academico_test.TMATRICULA_CAMPO c
     WHERE c.ACTIVE = TRUE
    ON CONFLICT (FK_TMATRICULA_CONFIG, FK_TMATRICULA_CAMPO) DO NOTHING;

    RETURN v_pk_config;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_matricula_config_crear_interno(BIGINT, VARCHAR) IS
    'Motor sin gate de permisos: crea (o reutiliza, por U_TMATRICULA_CONFIG_1) la TMATRICULA_CONFIG del establecimiento y siembra un TMATRICULA_VALOR por cada TMATRICULA_CAMPO activo copiando REQUERIDO_DEFECTO/VISIBLE_DEFECTO. Idempotente (ON CONFLICT DO NOTHING en ambos INSERT). Usado por fn_matricula_config_crear, el trigger de TESTABLECIMIENTO y el backfill. Retorna PK_MATRICULA_CONFIG.';

-- ---------------------------------------------------------------------------
-- 4) fn_matricula_config_crear -- API con gate de permisos.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_matricula_config_crear(
    p_pk_usuario_solicitante BIGINT,
    p_fk_establecimiento     BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_active BOOLEAN;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    IF p_fk_establecimiento IS NULL OR p_fk_establecimiento <= 0 THEN
        RAISE EXCEPTION 'p_fk_establecimiento es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    SELECT ACTIVE INTO v_active
      FROM academico_test.TESTABLECIMIENTO
     WHERE PK_ESTABLECIMIENTO = p_fk_establecimiento;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe TESTABLECIMIENTO con PK_ESTABLECIMIENTO = %', p_fk_establecimiento
            USING ERRCODE = 'P0002';
    END IF;

    IF v_active = FALSE THEN
        RAISE EXCEPTION 'TESTABLECIMIENTO % esta inactivo; no se puede crear su configuracion de matricula',
            p_fk_establecimiento
            USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1 FROM academico_test.TMATRICULA_CONFIG
         WHERE FK_TESTABLECIMIENTO = p_fk_establecimiento
    ) THEN
        RAISE EXCEPTION 'El establecimiento % ya tiene una configuracion de matricula', p_fk_establecimiento
            USING ERRCODE = '23505',
                  HINT    = 'Use fn_matricula_config_actualizar(usuario, fk_establecimiento, valores) para modificarla';
    END IF;

    RETURN academico_test.fn_matricula_config_crear_interno(
        p_fk_establecimiento,
        p_pk_usuario_solicitante::VARCHAR
    );
END;
$$;

COMMENT ON FUNCTION academico_test.fn_matricula_config_crear(BIGINT, BIGINT) IS
    'Crea la configuracion de matricula de un establecimiento. Requiere p_pk_usuario_solicitante con permiso de establecimiento (fn_puede_afectar_establecimiento). Falla 23505 si el EE ya tiene config (una por EE, U_TMATRICULA_CONFIG_1) -- en ese caso usar fn_matricula_config_actualizar. Delega el trabajo real en fn_matricula_config_crear_interno. Retorna PK_MATRICULA_CONFIG.';

-- ---------------------------------------------------------------------------
-- 5) fn_matricula_config_actualizar -- upsert de REQUERIDO/VISIBLE por campo.
--
--    p_valores: JSONB array de objetos
--      [{ "fk_campo": <PK_MATRICULA_CAMPO>, "requerido": "S"|"N", "visible": "S"|"N" }, ...]
--    'requerido' y 'visible' son opcionales por elemento: si falta uno, esa
--    columna no se toca (COALESCE con el valor actual).
--
--    Los campos con EDITABLE = 'N' no necesitan tratamiento especial aqui:
--    el trigger trg_matricula_valor_no_editable (seccion 6) coacciona su
--    REQUERIDO/VISIBLE a 'S' antes de persistir cualquier cambio.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_matricula_config_actualizar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_establecimiento     BIGINT,
    p_valores                JSONB
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_active     BOOLEAN;
    v_pk_config  BIGINT;
    v_actor      VARCHAR := p_pk_usuario_solicitante::VARCHAR;
    v_item       JSONB;
    v_fk_campo   BIGINT;
    v_requerido  academico_test.bool_sn;
    v_visible    academico_test.bool_sn;
    v_afectados  INT := 0;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    IF p_fk_establecimiento IS NULL OR p_fk_establecimiento <= 0 THEN
        RAISE EXCEPTION 'p_fk_establecimiento es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF p_valores IS NULL OR jsonb_typeof(p_valores) <> 'array' THEN
        RAISE EXCEPTION 'p_valores debe ser un arreglo JSON de { fk_campo, requerido, visible }'
            USING ERRCODE = '22023';
    END IF;

    SELECT ACTIVE INTO v_active
      FROM academico_test.TESTABLECIMIENTO
     WHERE PK_ESTABLECIMIENTO = p_fk_establecimiento;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe TESTABLECIMIENTO con PK_ESTABLECIMIENTO = %', p_fk_establecimiento
            USING ERRCODE = 'P0002';
    END IF;

    IF v_active = FALSE THEN
        RAISE EXCEPTION 'TESTABLECIMIENTO % esta inactivo; no se puede actualizar su configuracion de matricula',
            p_fk_establecimiento
            USING ERRCODE = '22023';
    END IF;

    -- Una config por EE es invariante: si por lo que sea no existe, se crea.
    v_pk_config := academico_test.fn_matricula_config_crear_interno(p_fk_establecimiento, v_actor);

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_valores)
    LOOP
        IF jsonb_typeof(v_item) <> 'object' OR (v_item ? 'fk_campo') = FALSE THEN
            RAISE EXCEPTION 'Cada elemento de p_valores requiere "fk_campo": %', v_item
                USING ERRCODE = '22023';
        END IF;

        v_fk_campo  := (v_item ->> 'fk_campo')::BIGINT;
        v_requerido := NULLIF(v_item ->> 'requerido', '')::academico_test.bool_sn;
        v_visible   := NULLIF(v_item ->> 'visible',   '')::academico_test.bool_sn;

        IF v_requerido IS NULL AND v_visible IS NULL THEN
            CONTINUE;  -- nada que cambiar para este campo
        END IF;

        IF NOT EXISTS (
            SELECT 1 FROM academico_test.TMATRICULA_CAMPO
             WHERE PK_MATRICULA_CAMPO = v_fk_campo
               AND ACTIVE = TRUE
        ) THEN
            RAISE EXCEPTION 'FK_TMATRICULA_CAMPO (%) no existe o no esta activo', v_fk_campo
                USING ERRCODE = '23503';
        END IF;

        INSERT INTO academico_test.TMATRICULA_VALOR AS mv (
            REQUERIDO, VISIBLE, FK_TMATRICULA_CONFIG, FK_TMATRICULA_CAMPO, CREATED_BY
        )
        VALUES (
            COALESCE(v_requerido, 'N'),
            COALESCE(v_visible,   'S'),
            v_pk_config, v_fk_campo, v_actor
        )
        ON CONFLICT (FK_TMATRICULA_CONFIG, FK_TMATRICULA_CAMPO) DO UPDATE
           SET REQUERIDO   = COALESCE(v_requerido, mv.REQUERIDO),
               VISIBLE     = COALESCE(v_visible,   mv.VISIBLE),
               MODIFIED_BY = v_actor,
               MODIFIED_AT = CURRENT_TIMESTAMP;

        v_afectados := v_afectados + 1;
    END LOOP;

    UPDATE academico_test.TMATRICULA_CONFIG
       SET MODIFIED_BY = v_actor,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_MATRICULA_CONFIG = v_pk_config
       AND v_afectados > 0;

    RETURN v_pk_config;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_matricula_config_actualizar(BIGINT, BIGINT, JSONB) IS
    'Actualiza REQUERIDO/VISIBLE de campos en la configuracion de matricula de un establecimiento. Requiere permiso de establecimiento (fn_puede_afectar_establecimiento). p_valores: arreglo JSON de { fk_campo, requerido?, visible? } (S/N); si falta requerido o visible en un elemento, esa columna no se toca. Upsert por U_TMATRICULA_VALOR_1 (config, campo). Los campos EDITABLE=''N'' quedan siempre en S/S por el trigger trg_matricula_valor_no_editable. Autocrea la config si no existiera (invariante: una por EE). Retorna PK_MATRICULA_CONFIG.';

-- ---------------------------------------------------------------------------
-- 6) Candado de campos no editables.
--    EDITABLE='N' => su TMATRICULA_VALOR siempre REQUERIDO='S'/VISIBLE='S'
--    para cualquier establecimiento, sin posibilidad de edicion.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_matricula_valor_forzar_no_editable()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
          FROM academico_test.TMATRICULA_CAMPO
         WHERE PK_MATRICULA_CAMPO = NEW.FK_TMATRICULA_CAMPO
           AND EDITABLE = 'N'
    ) THEN
        NEW.REQUERIDO := 'S';
        NEW.VISIBLE   := 'S';
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_matricula_valor_forzar_no_editable() IS
    'Trigger BEFORE INSERT/UPDATE de TMATRICULA_VALOR: si el TMATRICULA_CAMPO referenciado tiene EDITABLE=''N'', fuerza REQUERIDO=''S'' y VISIBLE=''S''. Hace que un campo no editable sea siempre requerido y visible sin importar la via de escritura.';

DROP TRIGGER IF EXISTS trg_matricula_valor_no_editable ON academico_test.TMATRICULA_VALOR;
CREATE TRIGGER trg_matricula_valor_no_editable
    BEFORE INSERT OR UPDATE OF REQUERIDO, VISIBLE, FK_TMATRICULA_CAMPO
    ON academico_test.TMATRICULA_VALOR
    FOR EACH ROW
    EXECUTE FUNCTION academico_test.fn_matricula_valor_forzar_no_editable();

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_campo_sync_no_editable()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.EDITABLE = 'N' THEN
        UPDATE academico_test.TMATRICULA_VALOR
           SET REQUERIDO   = 'S',
               VISIBLE     = 'S',
               MODIFIED_BY  = 'SYSTEM',
               MODIFIED_AT  = CURRENT_TIMESTAMP
         WHERE FK_TMATRICULA_CAMPO = NEW.PK_MATRICULA_CAMPO
           AND (REQUERIDO <> 'S' OR VISIBLE <> 'S');
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_matricula_campo_sync_no_editable() IS
    'Trigger AFTER UPDATE OF EDITABLE de TMATRICULA_CAMPO: cuando un campo pasa a EDITABLE=''N'', normaliza a REQUERIDO=''S''/VISIBLE=''S'' todas sus filas TMATRICULA_VALOR existentes.';

DROP TRIGGER IF EXISTS trg_matricula_campo_sync_no_editable ON academico_test.TMATRICULA_CAMPO;
CREATE TRIGGER trg_matricula_campo_sync_no_editable
    AFTER UPDATE OF EDITABLE ON academico_test.TMATRICULA_CAMPO
    FOR EACH ROW
    WHEN (NEW.EDITABLE = 'N' AND OLD.EDITABLE IS DISTINCT FROM 'N')
    EXECUTE FUNCTION academico_test.fn_matricula_campo_sync_no_editable();

-- ---------------------------------------------------------------------------
-- 7) Trigger: cada alta de TESTABLECIMIENTO siembra su config por defecto.
--    AFTER INSERT para que exista ya el PK y cualquier FK; se dispara tanto
--    desde fn_est_crear como desde un INSERT directo.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_matricula_config_trg_establecimiento()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_matricula_config_crear_interno(
        NEW.PK_ESTABLECIMIENTO,
        COALESCE(NEW.CREATED_BY, 'SYSTEM')
    );
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_matricula_config_trg_establecimiento() IS
    'Trigger AFTER INSERT en TESTABLECIMIENTO: crea la configuracion de matricula por defecto (fn_matricula_config_crear_interno) para el EE recien insertado. Idempotente.';

DROP TRIGGER IF EXISTS trg_matricula_config_establecimiento ON academico_test.TESTABLECIMIENTO;
CREATE TRIGGER trg_matricula_config_establecimiento
    AFTER INSERT ON academico_test.TESTABLECIMIENTO
    FOR EACH ROW
    EXECUTE FUNCTION academico_test.fn_matricula_config_trg_establecimiento();

-- ---------------------------------------------------------------------------
-- 8) Backfill: los establecimientos que ya existen tambien deben tener su
--    config por defecto. fn_matricula_config_crear_interno es idempotente.
--    Luego normaliza cualquier TMATRICULA_VALOR de campo no editable que
--    ya existiera con un valor distinto de 'S' (idempotente).
-- ---------------------------------------------------------------------------
DO $backfill$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT PK_ESTABLECIMIENTO, CREATED_BY
          FROM academico_test.TESTABLECIMIENTO
    LOOP
        PERFORM academico_test.fn_matricula_config_crear_interno(
            r.PK_ESTABLECIMIENTO,
            COALESCE(r.CREATED_BY, 'SYSTEM')
        );
    END LOOP;
END
$backfill$;

UPDATE academico_test.TMATRICULA_VALOR mv
   SET REQUERIDO   = 'S',
       VISIBLE     = 'S',
       MODIFIED_BY  = 'V159',
       MODIFIED_AT  = CURRENT_TIMESTAMP
  FROM academico_test.TMATRICULA_CAMPO mc
 WHERE mc.PK_MATRICULA_CAMPO = mv.FK_TMATRICULA_CAMPO
   AND mc.EDITABLE = 'N'
   AND (mv.REQUERIDO <> 'S' OR mv.VISIBLE <> 'S');
