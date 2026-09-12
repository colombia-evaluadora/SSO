-- ===========================================================================
-- V256 -- Dominio propio de PIGSE: entes territoriales, establecimientos,
-- usuarios/funcionarios y sus puentes con rol.
--
-- Hasta hoy PIGSE solo tenia schema y TARCHIVO (V148): sus funciones
-- fn_pigse_* leian academico_test.testablecimiento, sincronizado desde
-- coleval. Este DDL le da a PIGSE entidades INDEPENDIENTES para que deje de
-- depender de ese sincronismo. Nada de academico_test se toca.
--
-- PIGSE tiene TAMBIEN sus propios dominios y catalogos (ver mas abajo): no
-- queda ninguna dependencia de academico_test en el DDL. Lo que si se
-- comparte con el SSO: el login en public.users y los roles en public.role.
--
-- Sigue habiendo dos vinculos con academico_test FUERA del DDL, a proposito:
--   * trg_audit_ctx llama a academico_test.fn_audit_ctx (el emisor de
--     contexto del CDC es unico para toda la base -- duplicarlo dejaria a
--     PIGSE fuera de auditoria.log, ver V26/V184).
--   * pigse.v_archivo (V261) lee academico_test.tarchivo para los archivos
--     historicos, que no se movieron. Esa dependencia se agota sola a medida
--     que los documentos se reemplazan.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 0. Dominios y catalogos propios.
--
-- PIGSE deja de depender de academico_test tambien para los tipos y los
-- catalogos. Se copian con los MISMOS pk: los valores de FK que ya existen
-- (y los que copia V259) siguen siendo validos, y los pk_lista_valor no son
-- estables entre entornos, asi que renumerarlos romperia cualquier dato que
-- los referencie.
--
-- CONTRAPARTIDA: quedan dos copias de la division politica y de la lista de
-- valores. Nada las sincroniza -- si coleval agrega un municipio, PIGSE no lo
-- ve hasta que alguien lo inserte aqui.
-- ---------------------------------------------------------------------------
DO $dom$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                    WHERE n.nspname = 'pigse' AND t.typname = 'bool_sn') THEN
        CREATE DOMAIN pigse.bool_sn AS VARCHAR(1) CHECK (VALUE IN ('S', 'N'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                    WHERE n.nspname = 'pigse' AND t.typname = 'estado_ai') THEN
        CREATE DOMAIN pigse.estado_ai AS VARCHAR(1) CHECK (VALUE IN ('A', 'I'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                    WHERE n.nspname = 'pigse' AND t.typname = 'estado_activo_inactivo') THEN
        CREATE DOMAIN pigse.estado_activo_inactivo AS VARCHAR(12)
            CHECK (VALUE IN ('ACTIVO', 'INACTIVO'));
    END IF;
END $dom$;

CREATE TABLE IF NOT EXISTS pigse.tlista_valor (
  PK_LISTA_VALOR BIGINT NOT NULL,
  CATEGORIA VARCHAR(30) NOT NULL,
  NOMBRE VARCHAR(120) NOT NULL,
  VALOR VARCHAR(130),
  ACCION VARCHAR(150),
  CREATED_BY VARCHAR(120) NOT NULL,
  CREATED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
  MODIFIED_BY VARCHAR(120),
  MODIFIED_AT TIMESTAMP,
  ACTIVE BOOLEAN DEFAULT TRUE NOT NULL,
  CONSTRAINT pk_pigse_tlista_valor PRIMARY KEY (PK_LISTA_VALOR)
);
CREATE INDEX IF NOT EXISTS idx_pigse_tlista_valor_categoria
    ON pigse.tlista_valor (CATEGORIA) WHERE ACTIVE = true;

CREATE TABLE IF NOT EXISTS pigse.tdepartamento (
  PK_DEPARTAMENTO BIGINT NOT NULL,
  CODIGO VARCHAR(30) NOT NULL,
  NOMBRE VARCHAR(130) NOT NULL,
  FK_TLV_TPAIS BIGINT NOT NULL,
  CREATED_BY VARCHAR(120) NOT NULL,
  CREATED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
  MODIFIED_BY VARCHAR(120),
  MODIFIED_AT TIMESTAMP,
  ACTIVE BOOLEAN DEFAULT TRUE NOT NULL,
  CONSTRAINT pk_pigse_tdepartamento PRIMARY KEY (PK_DEPARTAMENTO),
  CONSTRAINT fk_pigse_tdepartamento_pais FOREIGN KEY (FK_TLV_TPAIS)
      REFERENCES pigse.tlista_valor (PK_LISTA_VALOR)
);

CREATE TABLE IF NOT EXISTS pigse.tmunicipio (
  PK_TMUNICIPIO BIGINT NOT NULL,
  CODIGO VARCHAR(30) NOT NULL,
  NOMBRE VARCHAR(130) NOT NULL,
  PK_TDEPARTAMENTO BIGINT NOT NULL,
  CREATED_BY VARCHAR(120) NOT NULL,
  CREATED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
  MODIFIED_BY VARCHAR(120),
  MODIFIED_AT TIMESTAMP,
  ACTIVE BOOLEAN DEFAULT TRUE NOT NULL,
  CONSTRAINT pk_pigse_tmunicipio PRIMARY KEY (PK_TMUNICIPIO),
  CONSTRAINT fk_pigse_tmunicipio_depto FOREIGN KEY (PK_TDEPARTAMENTO)
      REFERENCES pigse.tdepartamento (PK_DEPARTAMENTO)
);
CREATE INDEX IF NOT EXISTS idx_pigse_tmunicipio_depto
    ON pigse.tmunicipio (PK_TDEPARTAMENTO);

CREATE TABLE IF NOT EXISTS pigse.tpropiedad_juridica (
  PK_PROPIEDAD_JURIDICA BIGINT NOT NULL,
  CODIGO VARCHAR(30) NOT NULL,
  NOMBRE VARCHAR(130) NOT NULL,
  FK_TLV_ZECTOR BIGINT NOT NULL,
  CREATED_BY VARCHAR(120) NOT NULL,
  CREATED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
  MODIFIED_BY VARCHAR(120),
  MODIFIED_AT TIMESTAMP,
  ACTIVE BOOLEAN DEFAULT TRUE NOT NULL,
  CONSTRAINT pk_pigse_tpropiedad_juridica PRIMARY KEY (PK_PROPIEDAD_JURIDICA),
  CONSTRAINT fk_pigse_tpropjur_zector FOREIGN KEY (FK_TLV_ZECTOR)
      REFERENCES pigse.tlista_valor (PK_LISTA_VALOR)
);

-- Semilla inicial desde coleval, en orden de dependencia. Copia de una sola
-- vez: reejecutarla no duplica ni sobreescribe lo que PIGSE haya editado.
INSERT INTO pigse.tlista_valor (PK_LISTA_VALOR, CATEGORIA, NOMBRE, VALOR, ACCION,
                                CREATED_BY, CREATED_AT, MODIFIED_BY, MODIFIED_AT, ACTIVE)
SELECT o.PK_LISTA_VALOR, o.CATEGORIA, o.NOMBRE, o.VALOR, o.ACCION,
       o.CREATED_BY, o.CREATED_AT, o.MODIFIED_BY, o.MODIFIED_AT, o.ACTIVE
  FROM academico_test.tlista_valor o
 WHERE NOT EXISTS (SELECT 1 FROM pigse.tlista_valor p
                    WHERE p.PK_LISTA_VALOR = o.PK_LISTA_VALOR);

INSERT INTO pigse.tdepartamento (PK_DEPARTAMENTO, CODIGO, NOMBRE, FK_TLV_TPAIS,
                                 CREATED_BY, CREATED_AT, MODIFIED_BY, MODIFIED_AT, ACTIVE)
SELECT o.PK_DEPARTAMENTO, o.CODIGO, o.NOMBRE, o.FK_TLV_TPAIS,
       o.CREATED_BY, o.CREATED_AT, o.MODIFIED_BY, o.MODIFIED_AT, o.ACTIVE
  FROM academico_test.tdepartamento o
 WHERE EXISTS (SELECT 1 FROM pigse.tlista_valor p WHERE p.PK_LISTA_VALOR = o.FK_TLV_TPAIS)
   AND NOT EXISTS (SELECT 1 FROM pigse.tdepartamento p
                    WHERE p.PK_DEPARTAMENTO = o.PK_DEPARTAMENTO);

INSERT INTO pigse.tmunicipio (PK_TMUNICIPIO, CODIGO, NOMBRE, PK_TDEPARTAMENTO,
                              CREATED_BY, CREATED_AT, MODIFIED_BY, MODIFIED_AT, ACTIVE)
SELECT o.PK_TMUNICIPIO, o.CODIGO, o.NOMBRE, o.PK_TDEPARTAMENTO,
       o.CREATED_BY, o.CREATED_AT, o.MODIFIED_BY, o.MODIFIED_AT, o.ACTIVE
  FROM academico_test.tmunicipio o
 WHERE EXISTS (SELECT 1 FROM pigse.tdepartamento p
                WHERE p.PK_DEPARTAMENTO = o.PK_TDEPARTAMENTO)
   AND NOT EXISTS (SELECT 1 FROM pigse.tmunicipio p
                    WHERE p.PK_TMUNICIPIO = o.PK_TMUNICIPIO);

INSERT INTO pigse.tpropiedad_juridica (PK_PROPIEDAD_JURIDICA, CODIGO, NOMBRE, FK_TLV_ZECTOR,
                                       CREATED_BY, CREATED_AT, MODIFIED_BY, MODIFIED_AT, ACTIVE)
SELECT o.PK_PROPIEDAD_JURIDICA, o.CODIGO, o.NOMBRE, o.FK_TLV_ZECTOR,
       o.CREATED_BY, o.CREATED_AT, o.MODIFIED_BY, o.MODIFIED_AT, o.ACTIVE
  FROM academico_test.tpropiedad_juridica o
 WHERE EXISTS (SELECT 1 FROM pigse.tlista_valor p WHERE p.PK_LISTA_VALOR = o.FK_TLV_ZECTOR)
   AND NOT EXISTS (SELECT 1 FROM pigse.tpropiedad_juridica p
                    WHERE p.PK_PROPIEDAD_JURIDICA = o.PK_PROPIEDAD_JURIDICA);

-- ---------------------------------------------------------------------------
-- Tabla: pigse.tente
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pigse.tente (
  PK_ENTE BIGINT GENERATED BY DEFAULT AS IDENTITY NOT NULL,
  NIT VARCHAR(30) NOT NULL,
  NOMBRE VARCHAR(130) NOT NULL,
  ESTADO pigse.estado_ai DEFAULT 'A' NOT NULL,
  FK_TMUNICIPIO BIGINT NOT NULL,
  FK_TENTE_PADRE BIGINT,
  CREATED_BY VARCHAR(120) NOT NULL,
  CREATED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
  MODIFIED_BY VARCHAR(120),
  MODIFIED_AT TIMESTAMP,
  ACTIVE BOOLEAN DEFAULT TRUE NOT NULL,
  CONSTRAINT PK_PIGSE_TENTE PRIMARY KEY (PK_ENTE),
  CONSTRAINT FK_PIGSE_TENTE_PADRE FOREIGN KEY (FK_TENTE_PADRE) REFERENCES pigse.tente (PK_ENTE),
  CONSTRAINT FK_PIGSE_TENTE_MUNICIPIO FOREIGN KEY (FK_TMUNICIPIO) REFERENCES pigse.tmunicipio (PK_TMUNICIPIO)
);

-- Unicidad parcial y no constraint: el borrado es logico (ACTIVE=false) y un
-- NIT/nombre liberado debe poder reusarse. Mismo criterio que V71 en coleval.
CREATE UNIQUE INDEX IF NOT EXISTS U_PIGSE_TENTE_NIT ON pigse.tente (NIT) WHERE ACTIVE = true;
CREATE UNIQUE INDEX IF NOT EXISTS U_PIGSE_TENTE_NOMBRE ON pigse.tente (NOMBRE) WHERE ACTIVE = true;
CREATE INDEX IF NOT EXISTS IDX_PIGSE_TENTE_MUNICIPIO ON pigse.tente (FK_TMUNICIPIO);
CREATE INDEX IF NOT EXISTS IDX_PIGSE_TENTE_PADRE ON pigse.tente (FK_TENTE_PADRE);
CREATE INDEX IF NOT EXISTS IDX_PIGSE_TENTE_ACTIVE ON pigse.tente (PK_ENTE) WHERE ACTIVE = true;

COMMENT ON TABLE pigse.tente IS 'Ente territorial de PIGSE. Jerarquico via FK_TENTE_PADRE.';

-- ---------------------------------------------------------------------------
-- Tabla: pigse.testablecimiento
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pigse.testablecimiento (
  PK_ESTABLECIMIENTO BIGINT GENERATED BY DEFAULT AS IDENTITY NOT NULL,
  CODIGO VARCHAR(30),
  NOMBRE VARCHAR(130) NOT NULL,
  NIT VARCHAR(30),
  FK_TMUNICIPIO BIGINT NOT NULL,
  FK_TLISTA_VALOR_ZONA BIGINT,
  DIRECCION VARCHAR(130),
  CORREO_ELECTRONICO VARCHAR(130),
  TELEFONO VARCHAR(130),
  PAGINA_WEB VARCHAR(130),
  IDECOL VARCHAR(7),
  RESOLUCION_APROBACION VARCHAR(130),
  LICENCIA_FUNCIONAMIENTO VARCHAR(130),
  FECHA_LICENCIA DATE,
  FK_TPROPIEDAD_JURIDICA BIGINT,
  FK_TLV_CALENDARIO BIGINT,
  FK_TLV_ESTADO_ESTABLECIMIENTO BIGINT,
  -- Decide la regla PEI/PEC/PMI: S = etnoeducativo (aplica PEC, PEI no),
  -- N = aplica PEI. NULL deja los tres como PENDIENTE, nunca NO_APLICA.
  ETNIAS pigse.bool_sn,
  ESTADO pigse.estado_ai DEFAULT 'A' NOT NULL,
  FK_TARCHIVO BIGINT,
  -- Procedencia del backfill desde academico_test.testablecimiento (V259).
  -- Sin FK a proposito: los establecimientos de PIGSE son independientes y no
  -- deben quedar atados al ciclo de vida de los de coleval.
  FK_TESTABLECIMIENTO_ORIGEN BIGINT,
  CREATED_BY VARCHAR(120) NOT NULL,
  CREATED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
  MODIFIED_BY VARCHAR(120),
  MODIFIED_AT TIMESTAMP,
  ACTIVE BOOLEAN DEFAULT TRUE NOT NULL,
  CONSTRAINT PK_PIGSE_TESTABLECIMIENTO PRIMARY KEY (PK_ESTABLECIMIENTO),
  CONSTRAINT FK_PIGSE_TESTABLECIMIENTO_MUNICIPIO FOREIGN KEY (FK_TMUNICIPIO) REFERENCES pigse.tmunicipio (PK_TMUNICIPIO),
  CONSTRAINT FK_PIGSE_TESTABLECIMIENTO_ZONA FOREIGN KEY (FK_TLISTA_VALOR_ZONA) REFERENCES pigse.tlista_valor (PK_LISTA_VALOR),
  CONSTRAINT FK_PIGSE_TESTABLECIMIENTO_PROPJUR FOREIGN KEY (FK_TPROPIEDAD_JURIDICA) REFERENCES pigse.tpropiedad_juridica (PK_PROPIEDAD_JURIDICA),
  CONSTRAINT FK_PIGSE_TESTABLECIMIENTO_CALENDARIO FOREIGN KEY (FK_TLV_CALENDARIO) REFERENCES pigse.tlista_valor (PK_LISTA_VALOR),
  CONSTRAINT FK_PIGSE_TESTABLECIMIENTO_ESTADO FOREIGN KEY (FK_TLV_ESTADO_ESTABLECIMIENTO) REFERENCES pigse.tlista_valor (PK_LISTA_VALOR),
  CONSTRAINT FK_PIGSE_TESTABLECIMIENTO_ARCHIVO FOREIGN KEY (FK_TARCHIVO) REFERENCES pigse.tarchivo (pk_tarchivo)
);

CREATE UNIQUE INDEX IF NOT EXISTS U_PIGSE_TESTABLECIMIENTO_CODIGO ON pigse.testablecimiento (CODIGO) WHERE ACTIVE = true;
CREATE INDEX IF NOT EXISTS IDX_PIGSE_TESTABLECIMIENTO_MUNICIPIO ON pigse.testablecimiento (FK_TMUNICIPIO);
CREATE INDEX IF NOT EXISTS IDX_PIGSE_TESTABLECIMIENTO_ZONA ON pigse.testablecimiento (FK_TLISTA_VALOR_ZONA);
CREATE INDEX IF NOT EXISTS IDX_PIGSE_TESTABLECIMIENTO_PROPJUR ON pigse.testablecimiento (FK_TPROPIEDAD_JURIDICA);
CREATE INDEX IF NOT EXISTS IDX_PIGSE_TESTABLECIMIENTO_IDECOL ON pigse.testablecimiento (IDECOL);
CREATE INDEX IF NOT EXISTS IDX_PIGSE_TESTABLECIMIENTO_ORIGEN ON pigse.testablecimiento (FK_TESTABLECIMIENTO_ORIGEN);
CREATE INDEX IF NOT EXISTS IDX_PIGSE_TESTABLECIMIENTO_ACTIVE ON pigse.testablecimiento (PK_ESTABLECIMIENTO) WHERE ACTIVE = true;

COMMENT ON TABLE pigse.testablecimiento IS 'Establecimiento de PIGSE, independiente de academico_test.testablecimiento.';
COMMENT ON COLUMN pigse.testablecimiento.FK_TESTABLECIMIENTO_ORIGEN IS 'Trazabilidad del backfill: PK_ESTABLECIMIENTO de origen en academico_test, sin FK';

-- ---------------------------------------------------------------------------
-- Tabla: pigse.tente_establecimiento
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pigse.tente_establecimiento (
  PK_TENTE_ESTABLECIMIENTO BIGINT GENERATED BY DEFAULT AS IDENTITY NOT NULL,
  FK_TENTE BIGINT NOT NULL,
  FK_TESTABLECIMIENTO BIGINT NOT NULL,
  CREATED_BY VARCHAR(120) NOT NULL,
  CREATED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
  MODIFIED_BY VARCHAR(120),
  MODIFIED_AT TIMESTAMP,
  ACTIVE BOOLEAN DEFAULT TRUE NOT NULL,
  CONSTRAINT PK_PIGSE_TENTE_ESTABLECIMIENTO PRIMARY KEY (PK_TENTE_ESTABLECIMIENTO),
  CONSTRAINT FK_PIGSE_TENTE_EST_1 FOREIGN KEY (FK_TENTE) REFERENCES pigse.tente (PK_ENTE),
  CONSTRAINT FK_PIGSE_TENTE_EST_2 FOREIGN KEY (FK_TESTABLECIMIENTO) REFERENCES pigse.testablecimiento (PK_ESTABLECIMIENTO)
);

CREATE UNIQUE INDEX IF NOT EXISTS U_PIGSE_TENTE_EST ON pigse.tente_establecimiento (FK_TENTE, FK_TESTABLECIMIENTO) WHERE ACTIVE = true;
CREATE INDEX IF NOT EXISTS IDX_PIGSE_TENTE_EST_ENTE ON pigse.tente_establecimiento (FK_TENTE);
CREATE INDEX IF NOT EXISTS IDX_PIGSE_TENTE_EST_EST ON pigse.tente_establecimiento (FK_TESTABLECIMIENTO);
CREATE INDEX IF NOT EXISTS IDX_PIGSE_TENTE_EST_ACTIVE ON pigse.tente_establecimiento (PK_TENTE_ESTABLECIMIENTO) WHERE ACTIVE = true;

-- ---------------------------------------------------------------------------
-- Tabla: pigse.tusuario
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pigse.tusuario (
  PK_TUSUARIO BIGINT GENERATED BY DEFAULT AS IDENTITY NOT NULL,
  -- La credencial vive en public.users; aqui solo el enlace, nullable porque
  -- un funcionario puede registrarse antes de tener cuenta en el SSO.
  FK_ID_USER BIGINT,
  CORREO_ELECTRONICO VARCHAR(120) NOT NULL,
  ESTADO pigse.estado_ai DEFAULT 'A' NOT NULL,
  IDENTIFICACION VARCHAR(30),
  FK_TLV_TIPO_DOCUMENTO BIGINT,
  FK_TMUNICIPIO_DOCUMENTO BIGINT,
  PRIMER_NOMBRE VARCHAR(40) NOT NULL,
  SEGUNDO_NOMBRE VARCHAR(40),
  PRIMER_APELLIDO VARCHAR(40) NOT NULL,
  SEGUNDO_APELLIDO VARCHAR(40),
  FECHA_NACIMIENTO DATE,
  FK_TLV_GENERO BIGINT,
  FK_TMUNICIPIO_RESIDENCIA BIGINT,
  DIRECCION_RESIDENCIA VARCHAR(150),
  TELEFONO VARCHAR(30),
  FK_TARCHIVO BIGINT,
  CREATED_BY VARCHAR(120) NOT NULL,
  CREATED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
  MODIFIED_BY VARCHAR(120),
  MODIFIED_AT TIMESTAMP,
  ACTIVE BOOLEAN DEFAULT TRUE NOT NULL,
  CONSTRAINT PK_PIGSE_TUSUARIO PRIMARY KEY (PK_TUSUARIO),
  CONSTRAINT FK_PIGSE_TUSUARIO_USER FOREIGN KEY (FK_ID_USER) REFERENCES public.users (id_user),
  CONSTRAINT FK_PIGSE_TUSUARIO_TIPO_DOC FOREIGN KEY (FK_TLV_TIPO_DOCUMENTO) REFERENCES pigse.tlista_valor (PK_LISTA_VALOR),
  CONSTRAINT FK_PIGSE_TUSUARIO_MPIO_DOC FOREIGN KEY (FK_TMUNICIPIO_DOCUMENTO) REFERENCES pigse.tmunicipio (PK_TMUNICIPIO),
  CONSTRAINT FK_PIGSE_TUSUARIO_MPIO_RES FOREIGN KEY (FK_TMUNICIPIO_RESIDENCIA) REFERENCES pigse.tmunicipio (PK_TMUNICIPIO),
  CONSTRAINT FK_PIGSE_TUSUARIO_GENERO FOREIGN KEY (FK_TLV_GENERO) REFERENCES pigse.tlista_valor (PK_LISTA_VALOR),
  CONSTRAINT FK_PIGSE_TUSUARIO_ARCHIVO FOREIGN KEY (FK_TARCHIVO) REFERENCES pigse.tarchivo (pk_tarchivo)
);

CREATE UNIQUE INDEX IF NOT EXISTS U_PIGSE_TUSUARIO_CORREO ON pigse.tusuario (LOWER(CORREO_ELECTRONICO)) WHERE ACTIVE = true;
CREATE UNIQUE INDEX IF NOT EXISTS U_PIGSE_TUSUARIO_DOC ON pigse.tusuario (FK_TLV_TIPO_DOCUMENTO, IDENTIFICACION) WHERE ACTIVE = true;
CREATE UNIQUE INDEX IF NOT EXISTS U_PIGSE_TUSUARIO_ID_USER ON pigse.tusuario (FK_ID_USER) WHERE ACTIVE = true AND FK_ID_USER IS NOT NULL;
CREATE INDEX IF NOT EXISTS IDX_PIGSE_TUSUARIO_ACTIVE ON pigse.tusuario (PK_TUSUARIO) WHERE ACTIVE = true;

COMMENT ON COLUMN pigse.tusuario.FK_ID_USER IS 'Enlace a la cuenta del SSO (public.users); NULL mientras no tenga login';

-- ---------------------------------------------------------------------------
-- Tabla: pigse.tfuncionario
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pigse.tfuncionario (
  PK_TFUNCIONARIO BIGINT GENERATED BY DEFAULT AS IDENTITY NOT NULL,
  FK_TUSUARIO BIGINT NOT NULL,
  FK_TESTABLECIMIENTO BIGINT NOT NULL,
  FK_TLV_CARGO BIGINT,
  FK_TLV_TIPO_VINCULACION BIGINT,
  FECHA_VINCULACION DATE,
  TELEFONOS VARCHAR(100),
  AMENAZADO pigse.bool_sn DEFAULT 'N',
  FK_TARCHIVO BIGINT,
  CREATED_BY VARCHAR(120) NOT NULL,
  CREATED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
  MODIFIED_BY VARCHAR(120),
  MODIFIED_AT TIMESTAMP,
  ACTIVE BOOLEAN DEFAULT TRUE NOT NULL,
  CONSTRAINT PK_PIGSE_TFUNCIONARIO PRIMARY KEY (PK_TFUNCIONARIO),
  CONSTRAINT FK_PIGSE_TFUNCIONARIO_USUARIO FOREIGN KEY (FK_TUSUARIO) REFERENCES pigse.tusuario (PK_TUSUARIO),
  CONSTRAINT FK_PIGSE_TFUNCIONARIO_EST FOREIGN KEY (FK_TESTABLECIMIENTO) REFERENCES pigse.testablecimiento (PK_ESTABLECIMIENTO),
  CONSTRAINT FK_PIGSE_TFUNCIONARIO_CARGO FOREIGN KEY (FK_TLV_CARGO) REFERENCES pigse.tlista_valor (PK_LISTA_VALOR),
  CONSTRAINT FK_PIGSE_TFUNCIONARIO_VINC FOREIGN KEY (FK_TLV_TIPO_VINCULACION) REFERENCES pigse.tlista_valor (PK_LISTA_VALOR),
  CONSTRAINT FK_PIGSE_TFUNCIONARIO_ARCHIVO FOREIGN KEY (FK_TARCHIVO) REFERENCES pigse.tarchivo (pk_tarchivo)
);

CREATE UNIQUE INDEX IF NOT EXISTS U_PIGSE_TFUNCIONARIO_USUARIO ON pigse.tfuncionario (FK_TUSUARIO) WHERE ACTIVE = true;
CREATE INDEX IF NOT EXISTS IDX_PIGSE_TFUNCIONARIO_EST ON pigse.tfuncionario (FK_TESTABLECIMIENTO);
CREATE INDEX IF NOT EXISTS IDX_PIGSE_TFUNCIONARIO_CARGO ON pigse.tfuncionario (FK_TLV_CARGO);
CREATE INDEX IF NOT EXISTS IDX_PIGSE_TFUNCIONARIO_ACTIVE ON pigse.tfuncionario (PK_TFUNCIONARIO) WHERE ACTIVE = true;

COMMENT ON TABLE pigse.tfuncionario IS 'Perfil laboral 1:1 con pigse.tusuario, ligado a un establecimiento.';

-- ---------------------------------------------------------------------------
-- Tabla: pigse.tente_usuario
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pigse.tente_usuario (
  PK_TENTE_USUARIO BIGINT GENERATED BY DEFAULT AS IDENTITY NOT NULL,
  FK_TENTE BIGINT NOT NULL,
  FK_TUSUARIO BIGINT NOT NULL,
  -- Rol del SSO (public.role, los PIGSE-* de V148). TROL/TROL_MENU de
  -- academico_test no aplican a esta app.
  FK_ID_ROLE BIGINT NOT NULL,
  TLV_ESTADO pigse.estado_activo_inactivo DEFAULT 'ACTIVO' NOT NULL,
  PREDETERMINADO NUMERIC(6) DEFAULT 0 NOT NULL,
  CREATED_BY VARCHAR(120) NOT NULL,
  CREATED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
  MODIFIED_BY VARCHAR(120),
  MODIFIED_AT TIMESTAMP,
  ACTIVE BOOLEAN DEFAULT TRUE NOT NULL,
  CONSTRAINT PK_PIGSE_TENTE_USUARIO PRIMARY KEY (PK_TENTE_USUARIO),
  CONSTRAINT FK_PIGSE_TENTE_USUARIO_ENTE FOREIGN KEY (FK_TENTE) REFERENCES pigse.tente (PK_ENTE),
  CONSTRAINT FK_PIGSE_TENTE_USUARIO_USUARIO FOREIGN KEY (FK_TUSUARIO) REFERENCES pigse.tusuario (PK_TUSUARIO),
  CONSTRAINT FK_PIGSE_TENTE_USUARIO_ROLE FOREIGN KEY (FK_ID_ROLE) REFERENCES public.role (id_role)
);

CREATE UNIQUE INDEX IF NOT EXISTS U_PIGSE_TENTE_USUARIO ON pigse.tente_usuario (FK_TENTE, FK_TUSUARIO, FK_ID_ROLE) WHERE ACTIVE = true;
CREATE INDEX IF NOT EXISTS IDX_PIGSE_TENTE_USUARIO_USUARIO ON pigse.tente_usuario (FK_TUSUARIO);
CREATE INDEX IF NOT EXISTS IDX_PIGSE_TENTE_USUARIO_ROLE ON pigse.tente_usuario (FK_ID_ROLE);
CREATE INDEX IF NOT EXISTS IDX_PIGSE_TENTE_USUARIO_ACTIVE ON pigse.tente_usuario (PK_TENTE_USUARIO) WHERE ACTIVE = true;

-- ---------------------------------------------------------------------------
-- Tabla: pigse.testablecimiento_usuario
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pigse.testablecimiento_usuario (
  PK_TESTABLECIMIENTO_USUARIO BIGINT GENERATED BY DEFAULT AS IDENTITY NOT NULL,
  FK_TESTABLECIMIENTO BIGINT NOT NULL,
  FK_TUSUARIO BIGINT NOT NULL,
  FK_ID_ROLE BIGINT NOT NULL,
  TLV_ESTADO pigse.estado_activo_inactivo DEFAULT 'ACTIVO' NOT NULL,
  PREDETERMINADO NUMERIC(6) DEFAULT 0 NOT NULL,
  CREATED_BY VARCHAR(120) NOT NULL,
  CREATED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
  MODIFIED_BY VARCHAR(120),
  MODIFIED_AT TIMESTAMP,
  ACTIVE BOOLEAN DEFAULT TRUE NOT NULL,
  CONSTRAINT PK_PIGSE_TEST_USUARIO PRIMARY KEY (PK_TESTABLECIMIENTO_USUARIO),
  CONSTRAINT FK_PIGSE_TEST_USUARIO_EST FOREIGN KEY (FK_TESTABLECIMIENTO) REFERENCES pigse.testablecimiento (PK_ESTABLECIMIENTO),
  CONSTRAINT FK_PIGSE_TEST_USUARIO_USUARIO FOREIGN KEY (FK_TUSUARIO) REFERENCES pigse.tusuario (PK_TUSUARIO),
  CONSTRAINT FK_PIGSE_TEST_USUARIO_ROLE FOREIGN KEY (FK_ID_ROLE) REFERENCES public.role (id_role)
);

CREATE UNIQUE INDEX IF NOT EXISTS U_PIGSE_TEST_USUARIO ON pigse.testablecimiento_usuario (FK_TESTABLECIMIENTO, FK_TUSUARIO, FK_ID_ROLE) WHERE ACTIVE = true;
CREATE INDEX IF NOT EXISTS IDX_PIGSE_TEST_USUARIO_USUARIO ON pigse.testablecimiento_usuario (FK_TUSUARIO);
CREATE INDEX IF NOT EXISTS IDX_PIGSE_TEST_USUARIO_ROLE ON pigse.testablecimiento_usuario (FK_ID_ROLE);
CREATE INDEX IF NOT EXISTS IDX_PIGSE_TEST_USUARIO_ACTIVE ON pigse.testablecimiento_usuario (PK_TESTABLECIMIENTO_USUARIO) WHERE ACTIVE = true;

-- ---------------------------------------------------------------------------
-- Auditoria CDC. V26/V276 solo recorren academico_test, asi que las tablas de
-- pigse nacerian sin emitir contexto; se instala aqui la MISMA definicion.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT t.schemaname, t.tablename
          FROM pg_tables t
         WHERE t.schemaname = 'pigse'
           AND t.tablename IN ('tente', 'testablecimiento', 'tente_establecimiento',
                               'tusuario', 'tfuncionario', 'tente_usuario',
                               'testablecimiento_usuario')
           AND NOT EXISTS (
               SELECT 1
                 FROM pg_trigger tg
                 JOIN pg_class c     ON c.oid = tg.tgrelid
                 JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = t.schemaname
                  AND c.relname = t.tablename
                  AND tg.tgname = 'trg_audit_ctx'
                  AND NOT tg.tgisinternal
           )
         ORDER BY t.tablename
    LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_audit_ctx BEFORE INSERT OR UPDATE OR DELETE ON %I.%I
             FOR EACH STATEMENT EXECUTE FUNCTION academico_test.fn_audit_ctx()',
            r.schemaname, r.tablename
        );
        RAISE NOTICE 'trg_audit_ctx instalado en %.%', r.schemaname, r.tablename;
    END LOOP;
END $$;
