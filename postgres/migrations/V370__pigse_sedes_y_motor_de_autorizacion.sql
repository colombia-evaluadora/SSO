-- ===========================================================================
-- V370 - PIGSE: sedes (TSEDE, TSEDE_USUARIO), categoria de rol y motor de
-- autorizacion (capability por menu + scope por categoria), con sus
-- endpoints. El CRUD de funcionarios y fn_sed_listar que nacieron aqui viven
-- hoy en V386 y V390; el COMMENT de fn_fun_permisos_actualizar, en V517.
-- ===========================================================================


SET search_path TO pigse, academico_test, public;

CREATE TABLE IF NOT EXISTS pigse.role_categoria (
    fk_id_role BIGINT PRIMARY KEY REFERENCES public.role(id_role) ON DELETE CASCADE,
    categoria  SMALLINT NOT NULL,
    peso       SMALLINT NOT NULL DEFAULT 1,
    CREATED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
);

COMMENT ON TABLE pigse.role_categoria IS
    'V370: categoria (0 SUPER_ADMIN bypass total, 1 ADMINISTRATIVOS_TERRITORIALES = todos los EE, 2 ADMINISTRATIVOS_ESTABLECIMIENTO = sus EE, 3 ADMINISTRATIVOS_SEDES = sus (sede,jornada)) y peso (rango DENTRO de la categoria, menor = mayor autoridad) de cada rol PIGSE. Espejo de academico_test.TROL.FK_TLISTA_VALOR_CATEGORIA (V120), pero directo sobre public.role -- PIGSE no tiene una tabla de rol propia separada. Un rol sin fila aqui cae en categoria 4 (fail-closed, ver fn_rol_categoria_nivel).';

INSERT INTO pigse.role_categoria (fk_id_role, categoria, peso)
SELECT r.id_role, v.categoria, v.peso
  FROM public.role r
  JOIN (VALUES
        ('PIGSE-ADMINISTRADOR',                 0, 1),
        ('PIGSE-SECRETARIA_TERRITORIAL',        0, 2),
        ('PIGSE-DIRECTOR_ENTE_TERRITORIAL',     1, 1),
        ('PIGSE-JEFE_SISTEMA_ENTE_TERRITORIAL', 1, 2),
        ('PIGSE-JEFE_AREA_PLANEACION',          1, 3),
        ('PIGSE-JEFE_AREA_COBERTURA',           1, 3),
        ('PIGSE-JEFE_AREA_CALIDAD',             1, 3),
        ('PIGSE-RECTOR',                        2, 1),
        ('PIGSE-JEFE_SISTEMA_ESTABLECIMIENTO',  2, 2),
        ('PIGSE-SECRETARIO',                    2, 2),
        ('PIGSE-AUXILIAR_ADMINISTRATIVO',       2, 3)
       ) AS v(name, categoria, peso)
    ON v.name = r.name
 WHERE NOT EXISTS (SELECT 1 FROM pigse.role_categoria rc WHERE rc.fk_id_role = r.id_role);

ALTER TABLE public.route ADD COLUMN IF NOT EXISTS codigo VARCHAR(60);

UPDATE public.route SET codigo = 'FUNCIONARIOS'
 WHERE path = 'establecimiento-educativo/funcionarios' AND codigo IS NULL;

ALTER TABLE public.role_route
    ADD COLUMN IF NOT EXISTS puede_crear    BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS puede_editar   BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS puede_eliminar BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS puede_ver      BOOLEAN NOT NULL DEFAULT TRUE;

COMMENT ON COLUMN public.route.codigo IS
    'V370: codigo ESTABLE (no cambia si el nombre visible del menu cambia) para gates de autorizacion (fn_assert_permiso_seccion). Solo poblado para rutas que necesitan capability granular -- NULL en el resto, sin efecto.';

COMMENT ON COLUMN public.role_route.puede_crear IS
    'V370: capability granular del rol sobre este menu (equivalente a academico_test.TROL_MENU + SOLO_LECTURA). DEFAULT TRUE en las filas existentes para no restringir nada de golpe -- un role_route ya era "tiene acceso a todo" antes de esta columna.';

INSERT INTO public.route (name, path, menuorder, idparent)
SELECT 'Sedes', 'establecimiento-educativo/sedes', 2, r.idparent
  FROM public.route r
 WHERE r.name = 'Funcionarios' AND r.path = 'establecimiento-educativo/funcionarios'
   AND NOT EXISTS (
       SELECT 1 FROM public.route WHERE name = 'Sedes' AND path = 'establecimiento-educativo/sedes'
   );

UPDATE public.route SET codigo = 'SEDES_EDUCATIVAS'
 WHERE name = 'Sedes' AND path = 'establecimiento-educativo/sedes' AND codigo IS NULL;

INSERT INTO public.app_route (id_app, id_route)
SELECT a.id_app, rt.id_route
  FROM public.app a
  JOIN public.route rt ON rt.name = 'Sedes' AND rt.path = 'establecimiento-educativo/sedes'
 WHERE a.name = 'PIGSE'
   AND NOT EXISTS (SELECT 1 FROM public.app_route ar WHERE ar.id_app = a.id_app AND ar.id_route = rt.id_route);

INSERT INTO public.role_route (route_id, role_id)
SELECT rt.id_route, ro.id_role
  FROM public.route rt
 CROSS JOIN public.role ro
 WHERE rt.name = 'Sedes' AND rt.path = 'establecimiento-educativo/sedes'
   AND ro.name = 'PIGSE-ADMINISTRADOR'
   AND NOT EXISTS (SELECT 1 FROM public.role_route rr WHERE rr.route_id = rt.id_route AND rr.role_id = ro.id_role);

CREATE OR REPLACE FUNCTION pigse.fn_rol_categoria_nivel(p_fk_id_role BIGINT)
RETURNS INT LANGUAGE plpgsql STABLE
SET search_path = pigse, public
AS $$
DECLARE
    v_nivel INT;
BEGIN
    SELECT rc.categoria INTO v_nivel
      FROM pigse.role_categoria rc
     WHERE rc.fk_id_role = p_fk_id_role;

    RETURN COALESCE(v_nivel, 4);
END;
$$;

COMMENT ON FUNCTION pigse.fn_rol_categoria_nivel(BIGINT) IS
    'V370: nivel jerarquico (0=mas alto) de un rol PIGSE via pigse.role_categoria. Rol inexistente o sin fila -> 4 (fail-closed). Nunca NULL.';

CREATE OR REPLACE FUNCTION pigse.fn_usuario_categoria_rol_nivel(p_pk_tusuario BIGINT)
RETURNS INT LANGUAGE plpgsql STABLE
SET search_path = pigse, public
AS $$
DECLARE
    v_nivel INT;
BEGIN
    SELECT MIN(pigse.fn_rol_categoria_nivel(ru.role_id)) INTO v_nivel
      FROM pigse.TUSUARIO u
      JOIN public.role_users ru ON ru.user_id = u.FK_ID_USER
      JOIN pigse.role_categoria rc ON rc.fk_id_role = ru.role_id
     WHERE u.PK_TUSUARIO = p_pk_tusuario
       AND u.ACTIVE = TRUE;

    RETURN v_nivel;
END;
$$;

COMMENT ON FUNCTION pigse.fn_usuario_categoria_rol_nivel(BIGINT) IS
    'V370: nivel jerarquico (0=mas alto) MAS ALTO entre los roles PIGSE activos del usuario (public.role_users, filtrado a roles con fila en pigse.role_categoria -- ignora roles de otras apps). NULL si no tiene ningun rol PIGSE. Simplificacion documentada respecto a CEVAL: se resuelve contra role_users (fuente ya sincronizada del JWT), no recorriendo TENTE_USUARIO/TSEDE_USUARIO aparte.';

CREATE OR REPLACE FUNCTION pigse.fn_usuario_ee_accesibles(p_pk_tusuario BIGINT)
RETURNS TABLE (establecimiento_id BIGINT)
LANGUAGE plpgsql STABLE
SET search_path = pigse, public
AS $$
BEGIN
    RETURN QUERY
    SELECT e.PK_ESTABLECIMIENTO
      FROM pigse.TESTABLECIMIENTO e
      JOIN pigse.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
     WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_tusuario
    UNION
    SELECT e.PK_ESTABLECIMIENTO
      FROM pigse.TESTABLECIMIENTO e
      JOIN pigse.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
     WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_tusuario
    UNION
    SELECT s.FK_TESTABLECIMIENTO
      FROM pigse.TSEDE_USUARIO su
      JOIN pigse.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
      JOIN pigse.TESTABLECIMIENTO e ON e.PK_ESTABLECIMIENTO = s.FK_TESTABLECIMIENTO
     WHERE su.FK_TUSUARIO = p_pk_tusuario
       AND su.ACTIVE = TRUE AND s.ACTIVE = TRUE AND e.ACTIVE = TRUE
       AND pigse.fn_rol_categoria_nivel(su.FK_ID_ROLE) = 2;
END;
$$;

COMMENT ON FUNCTION pigse.fn_usuario_ee_accesibles(BIGINT) IS
    'V370: establecimientos ACTIVE que el usuario alcanza estructuralmente -- rector/secretaria por puntero (TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR/SECRETARIA, V360) o un TSEDE_USUARIO ACTIVE de categoria 2 (ADMINISTRATIVOS_ESTABLECIMIENTO). Espejo de academico_test.fn_usuario_ee_accesibles. Los territoriales (nivel 1) alcanzan TODOS los EE y se resuelven aparte en fn_assert_permiso_seccion, sin materializar esta tabla.';

CREATE OR REPLACE FUNCTION pigse.fn_usuario_sedes_jornadas_accesibles(p_pk_tusuario BIGINT)
RETURNS TABLE (sede_id BIGINT, jornada_id BIGINT)
LANGUAGE plpgsql STABLE
SET search_path = pigse, public
AS $$
BEGIN
    RETURN QUERY
    SELECT DISTINCT su.FK_TSEDE, su.FK_TLV_JORNADA
      FROM pigse.TSEDE_USUARIO su
      JOIN pigse.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
     WHERE su.FK_TUSUARIO = p_pk_tusuario
       AND su.ACTIVE = TRUE AND s.ACTIVE = TRUE
       AND pigse.fn_rol_categoria_nivel(su.FK_ID_ROLE) = 3;
END;
$$;

COMMENT ON FUNCTION pigse.fn_usuario_sedes_jornadas_accesibles(BIGINT) IS
    'V370: pares (sede,jornada) de un usuario con rol de categoria 3 (ADMINISTRATIVOS_SEDES). PIGSE no tiene hoy ningun rol clasificado en categoria 3 -- el mecanismo queda listo para cuando se agregue uno (INSERT en pigse.role_categoria), sin tocar SQL. Espejo de academico_test.fn_usuario_sedes_jornadas_accesibles.';

CREATE OR REPLACE FUNCTION pigse.fn_usuario_puede_en_menu(
    p_pk_tusuario BIGINT, p_codigo_menu VARCHAR, p_accion VARCHAR
)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE
SET search_path = pigse, public
AS $$
DECLARE
    v_puede BOOLEAN;
BEGIN
    SELECT bool_or(
        CASE UPPER(TRIM(COALESCE(p_accion, '')))
            WHEN 'CREAR'    THEN rr.puede_crear
            WHEN 'EDITAR'   THEN rr.puede_editar
            WHEN 'ELIMINAR' THEN rr.puede_eliminar
            WHEN 'VER'      THEN rr.puede_ver
            ELSE FALSE
        END
    ) INTO v_puede
      FROM pigse.TUSUARIO u
      JOIN public.role_users ru ON ru.user_id = u.FK_ID_USER
      JOIN public.role_route rr ON rr.role_id = ru.role_id
      JOIN public.route rt     ON rt.id_route = rr.route_id
     WHERE u.PK_TUSUARIO = p_pk_tusuario
       AND rt.codigo = p_codigo_menu;

    RETURN COALESCE(v_puede, FALSE);
END;
$$;

COMMENT ON FUNCTION pigse.fn_usuario_puede_en_menu(BIGINT, VARCHAR, VARCHAR) IS
    'V370: TRUE si alguno de los roles PIGSE activos del usuario (public.role_users) tiene, en public.role_route para el public.route de ese codigo, la capability p_accion (CREAR|EDITAR|ELIMINAR|VER) en TRUE. Accion desconocida/NULL -> FALSE (fail-closed). Espejo de academico_test.fn_usuario_puede_en_menu, sin la capa de recorte por usuario (TUSUARIO_ROL_PERMISO) -- simplificacion documentada en el encabezado de V370.';

CREATE OR REPLACE FUNCTION pigse.fn_assert_permiso_seccion(
    p_pk_tusuario        BIGINT,
    p_codigo_menu        VARCHAR,
    p_accion             VARCHAR,
    p_fk_establecimiento BIGINT DEFAULT NULL,
    p_fk_tsede           BIGINT DEFAULT NULL,
    p_fk_tlv_jornada     BIGINT DEFAULT NULL
)
RETURNS void LANGUAGE plpgsql STABLE
SET search_path = pigse, public
AS $$
DECLARE
    v_nivel INT;
    v_ee    BIGINT;
BEGIN
    v_nivel := pigse.fn_usuario_categoria_rol_nivel(p_pk_tusuario);

    IF v_nivel = 0 THEN
        RETURN;
    END IF;

    IF NOT pigse.fn_usuario_puede_en_menu(p_pk_tusuario, p_codigo_menu, p_accion) THEN
        RAISE EXCEPTION 'El usuario no tiene permiso para % en el modulo %',
            LOWER(TRIM(COALESCE(p_accion, '(sin accion)'))),
            COALESCE(p_codigo_menu, '(sin modulo)')
            USING ERRCODE = '42501';
    END IF;

    IF p_fk_establecimiento IS NOT NULL OR p_fk_tsede IS NOT NULL THEN
        IF v_nivel = 1 THEN
            RETURN;
        END IF;

        v_ee := COALESCE(
            p_fk_establecimiento,
            (SELECT s.FK_TESTABLECIMIENTO FROM pigse.TSEDE s WHERE s.PK_TSEDE = p_fk_tsede)
        );

        IF v_ee IS NOT NULL AND EXISTS (
            SELECT 1 FROM pigse.fn_usuario_ee_accesibles(p_pk_tusuario) ee
             WHERE ee.establecimiento_id = v_ee
        ) THEN
            RETURN;
        END IF;

        IF p_fk_tsede IS NOT NULL AND p_fk_tlv_jornada IS NOT NULL AND EXISTS (
            SELECT 1 FROM pigse.fn_usuario_sedes_jornadas_accesibles(p_pk_tusuario) sj
             WHERE sj.sede_id = p_fk_tsede AND sj.jornada_id = p_fk_tlv_jornada
        ) THEN
            RETURN;
        END IF;

        -- Secciones SIN jornada (ESTABLECIMIENTO/SEDES_EDUCATIVAS): un rol
        -- de categoria 3 alcanza sus propias sedes / el EE de esas sedes
        -- sin que se le pueda exigir jornada (una sede no tiene jornada).
        IF v_nivel = 3 AND UPPER(TRIM(COALESCE(p_codigo_menu, ''))) IN ('ESTABLECIMIENTO', 'SEDES_EDUCATIVAS') THEN
            IF p_fk_tsede IS NOT NULL THEN
                IF EXISTS (SELECT 1 FROM pigse.fn_usuario_sedes_jornadas_accesibles(p_pk_tusuario) sj
                            WHERE sj.sede_id = p_fk_tsede) THEN
                    RETURN;
                END IF;
            ELSIF v_ee IS NOT NULL THEN
                IF EXISTS (
                    SELECT 1 FROM pigse.fn_usuario_sedes_jornadas_accesibles(p_pk_tusuario) sj
                      JOIN pigse.TSEDE s ON s.PK_TSEDE = sj.sede_id
                     WHERE s.FK_TESTABLECIMIENTO = v_ee
                ) THEN
                    RETURN;
                END IF;
            END IF;
        END IF;

        RAISE EXCEPTION 'El usuario no tiene alcance sobre el establecimiento, sede o jornada objetivo'
            USING ERRCODE = '42501';
    END IF;

    RETURN;
END;
$$;

COMMENT ON FUNCTION pigse.fn_assert_permiso_seccion(BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT) IS
    'V370: espejo de academico_test.fn_assert_permiso_seccion. (0) bypass SUPER_ADMIN; (1) capability (fn_usuario_puede_en_menu); (2) scope SOLO si llega EE o sede: nivel 1 = todos los EE; el EE objetivo en fn_usuario_ee_accesibles; el par (sede,jornada) en fn_usuario_sedes_jornadas_accesibles; para ESTABLECIMIENTO/SEDES_EDUCATIVAS un nivel 3 alcanza sus sedes propias sin jornada. Sin objeto (los 3 p_fk_* NULL), la capability basta.';

CREATE OR REPLACE FUNCTION pigse.fn_assert_rango_rol(
    p_pk_solicitante BIGINT, p_pk_funcionario_objetivo BIGINT
)
RETURNS void LANGUAGE plpgsql STABLE
SET search_path = pigse, public
AS $$
DECLARE
    v_nivel_solicitante INT;
    v_nivel_objetivo    INT;
    v_nombre_objetivo   TEXT;
BEGIN
    v_nivel_solicitante := pigse.fn_usuario_categoria_rol_nivel(p_pk_solicitante);

    IF v_nivel_solicitante = 0 THEN
        RETURN;
    END IF;

    SELECT MIN(pigse.fn_rol_categoria_nivel(ru.role_id)) INTO v_nivel_objetivo
      FROM pigse.TFUNCIONARIO f
      JOIN pigse.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
      JOIN public.role_users ru ON ru.user_id = u.FK_ID_USER
      JOIN pigse.role_categoria rc ON rc.fk_id_role = ru.role_id
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario_objetivo;

    IF v_nivel_objetivo IS NULL THEN
        RETURN;
    END IF;

    IF v_nivel_solicitante IS NULL OR v_nivel_solicitante >= v_nivel_objetivo THEN
        SELECT TRIM(COALESCE(u.PRIMER_NOMBRE, '') || ' ' || COALESCE(u.PRIMER_APELLIDO, ''))
          INTO v_nombre_objetivo
          FROM pigse.TFUNCIONARIO f
          JOIN pigse.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
         WHERE f.PK_TFUNCIONARIO = p_pk_funcionario_objetivo;

        RAISE EXCEPTION 'El funcionario "%" tiene un rol de categoria igual o superior a la del usuario; no se puede consultar ni afectar',
            COALESCE(NULLIF(v_nombre_objetivo, ''), 'objetivo')
            USING ERRCODE = '42501';
    END IF;
END;
$$;

COMMENT ON FUNCTION pigse.fn_assert_rango_rol(BIGINT, BIGINT) IS
    'V370: espejo de academico_test.fn_assert_rango_rol. Un usuario no puede ver/afectar a un funcionario cuya categoria de rol (MIN de sus roles PIGSE activos) sea igual o superior a la propia. Objetivo sin rol activo -> pasa (nada que proteger). Solicitante SUPER_ADMIN -> bypass.';

CREATE OR REPLACE FUNCTION pigse.fn_assert_rango_rol_otorgable(
    p_pk_solicitante BIGINT, p_fk_id_role BIGINT
)
RETURNS void LANGUAGE plpgsql STABLE
SET search_path = pigse, public
AS $$
DECLARE
    v_nivel_solicitante INT;
    v_nivel_rol         INT;
    v_nombre_rol        TEXT;
BEGIN
    v_nivel_solicitante := pigse.fn_usuario_categoria_rol_nivel(p_pk_solicitante);

    IF v_nivel_solicitante = 0 THEN
        RETURN;
    END IF;

    v_nivel_rol := pigse.fn_rol_categoria_nivel(p_fk_id_role);

    IF v_nivel_solicitante IS NULL OR v_nivel_solicitante >= v_nivel_rol THEN
        SELECT r.description INTO v_nombre_rol FROM public.role r WHERE r.id_role = p_fk_id_role;

        RAISE EXCEPTION 'El rol "%" es de categoria igual o superior a la del usuario; no se puede otorgar',
            COALESCE(NULLIF(TRIM(COALESCE(v_nombre_rol, '')), ''), p_fk_id_role::TEXT)
            USING ERRCODE = '42501';
    END IF;
END;
$$;

COMMENT ON FUNCTION pigse.fn_assert_rango_rol_otorgable(BIGINT, BIGINT) IS
    'V370: espejo de academico_test.fn_assert_rango_rol_otorgable. Nadie puede otorgar un rol de categoria igual o superior a la propia. SUPER_ADMIN otorga cualquiera; sin rol activo, ninguno.';

CREATE OR REPLACE FUNCTION pigse.fn_assert_permiso_funcionario(
    p_pk_tusuario             BIGINT,
    p_accion                  VARCHAR,
    p_pk_funcionario_objetivo BIGINT DEFAULT NULL
)
RETURNS void LANGUAGE plpgsql STABLE
SET search_path = pigse, public
AS $$
DECLARE
    v_nivel           INT;
    v_nombre_objetivo TEXT;
BEGIN
    PERFORM pigse.fn_assert_permiso_seccion(p_pk_tusuario, 'FUNCIONARIOS', p_accion);

    v_nivel := pigse.fn_usuario_categoria_rol_nivel(p_pk_tusuario);

    IF v_nivel = 0 THEN
        RETURN;
    END IF;

    IF p_pk_funcionario_objetivo IS NULL THEN
        RETURN;
    END IF;

    IF v_nivel IS DISTINCT FROM 1 THEN
        IF NOT EXISTS (
            SELECT 1 FROM pigse.TESTABLECIMIENTO e
             WHERE e.ACTIVE = TRUE
               AND (e.FK_TFUNCIONARIO_RECTOR = p_pk_funcionario_objetivo
                    OR e.FK_TFUNCIONARIO_SECRETARIA = p_pk_funcionario_objetivo)
               AND EXISTS (SELECT 1 FROM pigse.fn_usuario_ee_accesibles(p_pk_tusuario) ee
                            WHERE ee.establecimiento_id = e.PK_ESTABLECIMIENTO)
            UNION ALL
            SELECT 1 FROM pigse.TFUNCIONARIO f
              JOIN pigse.TSEDE_USUARIO su ON su.FK_TUSUARIO = f.FK_TUSUARIO AND su.ACTIVE = TRUE
              JOIN pigse.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE AND s.ACTIVE = TRUE
             WHERE f.PK_TFUNCIONARIO = p_pk_funcionario_objetivo
               AND EXISTS (SELECT 1 FROM pigse.fn_usuario_ee_accesibles(p_pk_tusuario) ee
                            WHERE ee.establecimiento_id = s.FK_TESTABLECIMIENTO)
            UNION ALL
            SELECT 1 FROM pigse.TFUNCIONARIO f
              JOIN pigse.TSEDE_USUARIO su ON su.FK_TUSUARIO = f.FK_TUSUARIO AND su.ACTIVE = TRUE
             WHERE f.PK_TFUNCIONARIO = p_pk_funcionario_objetivo
               AND EXISTS (SELECT 1 FROM pigse.fn_usuario_sedes_jornadas_accesibles(p_pk_tusuario) sj
                            WHERE sj.sede_id = su.FK_TSEDE)
        ) THEN
            SELECT TRIM(COALESCE(u.PRIMER_NOMBRE, '') || ' ' || COALESCE(u.PRIMER_APELLIDO, ''))
              INTO v_nombre_objetivo
              FROM pigse.TFUNCIONARIO f JOIN pigse.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
             WHERE f.PK_TFUNCIONARIO = p_pk_funcionario_objetivo;

            RAISE EXCEPTION 'El usuario no tiene alcance sobre el funcionario "%"',
                COALESCE(NULLIF(v_nombre_objetivo, ''), 'objetivo')
                USING ERRCODE = '42501';
        END IF;
    END IF;

    PERFORM pigse.fn_assert_rango_rol(p_pk_tusuario, p_pk_funcionario_objetivo);
END;
$$;

COMMENT ON FUNCTION pigse.fn_assert_permiso_funcionario(BIGINT, VARCHAR, BIGINT) IS
    'V370: espejo de academico_test.fn_assert_permiso_funcionario. Capability (FUNCIONARIOS) + scope (rector/secretaria por puntero, o TSEDE_USUARIO categoria 2 en un EE accesible, o categoria 3 en una sede accesible) + rango (fn_assert_rango_rol). Nivel 1 (territorial) alcanza cualquier funcionario.';

CREATE TABLE IF NOT EXISTS pigse.TSEDE (
    PK_TSEDE            BIGINT GENERATED BY DEFAULT AS IDENTITY NOT NULL,
    CODIGO              VARCHAR(30) NOT NULL,
    NOMBRE              VARCHAR(130) NOT NULL,
    CONSECUTIVO         VARCHAR(2) NOT NULL,
    FK_TLV_ZONA         BIGINT NOT NULL,
    LOCALIDAD           VARCHAR(130),
    COMUNA              VARCHAR(130),
    BARRIO              VARCHAR(130),
    DIRECCION           VARCHAR(130),
    TELEFONO            VARCHAR(60),
    FK_TESTABLECIMIENTO BIGINT NOT NULL,
    GEOREFERENCIACION   VARCHAR(400),
    CREATED_BY          VARCHAR(120) NOT NULL,
    CREATED_AT          TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    MODIFIED_BY         VARCHAR(120),
    MODIFIED_AT         TIMESTAMP,
    ACTIVE              BOOLEAN DEFAULT TRUE NOT NULL,
    CONSTRAINT PK_PIGSE_TSEDE PRIMARY KEY (PK_TSEDE),
    CONSTRAINT FK_PIGSE_TSEDE_EST FOREIGN KEY (FK_TESTABLECIMIENTO) REFERENCES pigse.TESTABLECIMIENTO (PK_ESTABLECIMIENTO),
    CONSTRAINT FK_PIGSE_TSEDE_ZONA FOREIGN KEY (FK_TLV_ZONA) REFERENCES pigse.TLISTA_VALOR (PK_LISTA_VALOR)
);

CREATE UNIQUE INDEX IF NOT EXISTS U_PIGSE_TSEDE_CODIGO ON pigse.TSEDE (CODIGO) WHERE ACTIVE = true;

CREATE UNIQUE INDEX IF NOT EXISTS U_PIGSE_TSEDE_EST_NOMBRE ON pigse.TSEDE (FK_TESTABLECIMIENTO, NOMBRE) WHERE ACTIVE = true;

CREATE UNIQUE INDEX IF NOT EXISTS U_PIGSE_TSEDE_EST_CONSEC ON pigse.TSEDE (FK_TESTABLECIMIENTO, CONSECUTIVO) WHERE ACTIVE = true;

CREATE INDEX IF NOT EXISTS IDX_PIGSE_TSEDE_EST ON pigse.TSEDE (FK_TESTABLECIMIENTO);

COMMENT ON TABLE pigse.TSEDE IS 'V370: sede de un establecimiento PIGSE. Espejo de academico_test.TSEDE (V22).';

CREATE TABLE IF NOT EXISTS pigse.TSEDE_USUARIO (
    PK_TSEDE_USUARIO BIGINT GENERATED BY DEFAULT AS IDENTITY NOT NULL,
    FK_TSEDE         BIGINT NOT NULL,
    FK_ID_ROLE       BIGINT NOT NULL,
    FK_TLV_JORNADA   BIGINT NOT NULL,
    FK_TUSUARIO      BIGINT NOT NULL,
    ORDEN            NUMERIC(4) NOT NULL,
    TLV_ESTADO       pigse.estado_activo_inactivo DEFAULT 'ACTIVO' NOT NULL,
    PREDETERMINADO   NUMERIC(6) DEFAULT 0 NOT NULL,
    CREATED_BY       VARCHAR(120) NOT NULL,
    CREATED_AT       TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    MODIFIED_BY      VARCHAR(120),
    MODIFIED_AT      TIMESTAMP,
    ACTIVE           BOOLEAN DEFAULT TRUE NOT NULL,
    CONSTRAINT PK_PIGSE_TSEDE_USUARIO PRIMARY KEY (PK_TSEDE_USUARIO),
    CONSTRAINT UK_PIGSE_TSEDE_USUARIO_1 UNIQUE (FK_TSEDE, FK_ID_ROLE, FK_TUSUARIO, FK_TLV_JORNADA),
    CONSTRAINT UK_PIGSE_TSEDE_USUARIO_2 UNIQUE (FK_TSEDE, FK_ID_ROLE, FK_TUSUARIO, ORDEN),
    CONSTRAINT FK_PIGSE_TSEDE_USUARIO_SEDE FOREIGN KEY (FK_TSEDE) REFERENCES pigse.TSEDE (PK_TSEDE) ON DELETE CASCADE,
    CONSTRAINT FK_PIGSE_TSEDE_USUARIO_ROLE FOREIGN KEY (FK_ID_ROLE) REFERENCES public.role (id_role) ON DELETE CASCADE,
    CONSTRAINT FK_PIGSE_TSEDE_USUARIO_USUARIO FOREIGN KEY (FK_TUSUARIO) REFERENCES pigse.TUSUARIO (PK_TUSUARIO) ON DELETE CASCADE,
    CONSTRAINT FK_PIGSE_TSEDE_USUARIO_JORNADA FOREIGN KEY (FK_TLV_JORNADA) REFERENCES pigse.TLISTA_VALOR (PK_LISTA_VALOR)
);

CREATE INDEX IF NOT EXISTS IDX_PIGSE_TSEDE_USUARIO_SEDE ON pigse.TSEDE_USUARIO (FK_TSEDE);

CREATE INDEX IF NOT EXISTS IDX_PIGSE_TSEDE_USUARIO_ROLE ON pigse.TSEDE_USUARIO (FK_ID_ROLE);

CREATE INDEX IF NOT EXISTS IDX_PIGSE_TSEDE_USUARIO_USUARIO ON pigse.TSEDE_USUARIO (FK_TUSUARIO);

CREATE INDEX IF NOT EXISTS IDX_PIGSE_TSEDE_USUARIO_ACTIVE ON pigse.TSEDE_USUARIO (PK_TSEDE_USUARIO) WHERE ACTIVE = true;

COMMENT ON TABLE pigse.TSEDE_USUARIO IS
    'V370: permiso rol+jornada+estado de un usuario en una sede -- reemplaza a pigse.TESTABLECIMIENTO_USUARIO (rol directo por establecimiento, sin jornada/estado) como fuente de verdad de "que rol tiene un funcionario". Espejo de academico_test.TSEDE_USUARIO (V22), FK_ID_ROLE contra public.role en vez de una TROL propia.';

CREATE OR REPLACE FUNCTION pigse.fn_sede_usuario_crear(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tsede               BIGINT,
    p_fk_id_role             BIGINT,
    p_pk_usuario             BIGINT,
    p_orden                  NUMERIC,
    p_fk_tlv_jornada         BIGINT,
    p_tlv_estado             VARCHAR DEFAULT 'ACTIVO',
    p_predeterminado         NUMERIC DEFAULT 0
)
RETURNS BIGINT
LANGUAGE plpgsql
SET search_path = pigse, public
AS $$
DECLARE
    v_id_user BIGINT;
    v_pk      BIGINT;
BEGIN
    SELECT u.FK_ID_USER INTO v_id_user FROM pigse.TUSUARIO u WHERE u.PK_TUSUARIO = p_pk_usuario;

    SELECT PK_TSEDE_USUARIO INTO v_pk
      FROM pigse.TSEDE_USUARIO
     WHERE FK_TSEDE = p_fk_tsede AND FK_ID_ROLE = p_fk_id_role
       AND FK_TUSUARIO = p_pk_usuario AND FK_TLV_JORNADA = p_fk_tlv_jornada
       AND ACTIVE = TRUE;

    IF v_pk IS NULL THEN
        UPDATE pigse.TSEDE_USUARIO
           SET ACTIVE = TRUE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TSEDE = p_fk_tsede AND FK_ID_ROLE = p_fk_id_role
           AND FK_TUSUARIO = p_pk_usuario AND FK_TLV_JORNADA = p_fk_tlv_jornada
           AND ACTIVE = FALSE
        RETURNING PK_TSEDE_USUARIO INTO v_pk;
    END IF;

    IF v_pk IS NULL THEN
        INSERT INTO pigse.TSEDE_USUARIO (
            FK_TSEDE, FK_ID_ROLE, FK_TLV_JORNADA, FK_TUSUARIO, ORDEN,
            TLV_ESTADO, PREDETERMINADO, CREATED_BY, CREATED_AT, ACTIVE
        ) VALUES (
            p_fk_tsede, p_fk_id_role, p_fk_tlv_jornada, p_pk_usuario, p_orden,
            COALESCE(p_tlv_estado, 'ACTIVO')::pigse.estado_activo_inactivo, COALESCE(p_predeterminado, 0),
            p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
        )
        RETURNING PK_TSEDE_USUARIO INTO v_pk;
    END IF;

    IF v_id_user IS NOT NULL THEN
        INSERT INTO public.role_users (user_id, role_id)
        SELECT v_id_user, p_fk_id_role
         WHERE NOT EXISTS (SELECT 1 FROM public.role_users ru WHERE ru.user_id = v_id_user AND ru.role_id = p_fk_id_role);
    END IF;

    RETURN v_pk;
END;
$$;

COMMENT ON FUNCTION pigse.fn_sede_usuario_crear(BIGINT, BIGINT, BIGINT, BIGINT, NUMERIC, BIGINT, VARCHAR, NUMERIC) IS
    'V370: crea (o reactiva) un TSEDE_USUARIO y sincroniza public.role_users. Espejo de academico_test.fn_sede_usuario_crear. No valida gate ni existencia de FKs -- eso corre en el caller (fn_fun_permisos_actualizar, fn_sed_crear).';

CREATE OR REPLACE FUNCTION pigse.fn_sede_usuario_soft_delete(
    p_pk_tsede_usuario BIGINT,
    p_pk_usuario_solicitante BIGINT
)
RETURNS void
LANGUAGE plpgsql
SET search_path = pigse, public
AS $$
DECLARE
    v_fk_usuario BIGINT;
    v_fk_id_role BIGINT;
    v_id_user    BIGINT;
BEGIN
    SELECT su.FK_TUSUARIO, su.FK_ID_ROLE, u.FK_ID_USER
      INTO v_fk_usuario, v_fk_id_role, v_id_user
      FROM pigse.TSEDE_USUARIO su
      JOIN pigse.TUSUARIO u ON u.PK_TUSUARIO = su.FK_TUSUARIO
     WHERE su.PK_TSEDE_USUARIO = p_pk_tsede_usuario;

    UPDATE pigse.TSEDE_USUARIO
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TSEDE_USUARIO = p_pk_tsede_usuario;

    -- Si el usuario no le queda ningun otro TSEDE_USUARIO activo con ese
    -- mismo rol (en cualquier sede), el rol deja de aplicarle -> se retira
    -- de public.role_users para que el JWT deje de reflejarlo.
    IF v_id_user IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM pigse.TSEDE_USUARIO su
         WHERE su.FK_TUSUARIO = v_fk_usuario AND su.FK_ID_ROLE = v_fk_id_role AND su.ACTIVE = TRUE
    ) THEN
        DELETE FROM public.role_users WHERE user_id = v_id_user AND role_id = v_fk_id_role;
    END IF;
END;
$$;

COMMENT ON FUNCTION pigse.fn_sede_usuario_soft_delete(BIGINT, BIGINT) IS
    'V370: baja logica de un TSEDE_USUARIO; si el usuario no le queda otro TSEDE_USUARIO activo con ese rol, lo retira de public.role_users. Espejo de academico_test.fn_sede_usuario_soft_delete.';

CREATE OR REPLACE FUNCTION pigse.fn_sed_crear(
    p_pk_usuario_solicitante BIGINT,
    p_codigo                 VARCHAR,
    p_nombre                 VARCHAR,
    p_fk_lista_valor_zona    BIGINT,
    p_fk_establecimiento     BIGINT,
    p_localidad              VARCHAR DEFAULT NULL,
    p_comuna                 VARCHAR DEFAULT NULL,
    p_barrio                 VARCHAR DEFAULT NULL,
    p_direccion              VARCHAR DEFAULT NULL,
    p_telefono               VARCHAR DEFAULT NULL,
    p_georeferenciacion      VARCHAR DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
SET search_path = pigse, public
AS $$
DECLARE
    v_id_creado      BIGINT;
    v_consecutivo    VARCHAR(2);
    v_pk_rector      BIGINT;
    v_pk_secretaria  BIGINT;
    v_fk_usu_rector     BIGINT;
    v_fk_usu_secretaria BIGINT;
    v_jornada_completa  BIGINT;
BEGIN
    PERFORM pigse.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'SEDES_EDUCATIVAS', 'CREAR', p_fk_establecimiento);

    IF NULLIF(TRIM(p_codigo), '') IS NULL THEN
        RAISE EXCEPTION 'Codigo de la sede es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'Nombre de la sede es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_lista_valor_zona IS NULL THEN
        RAISE EXCEPTION 'Zona (FK_TLV_ZONA) es obligatoria' USING ERRCODE = '22023';
    END IF;
    IF p_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'Establecimiento (FK_TESTABLECIMIENTO) es obligatorio' USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pigse.TESTABLECIMIENTO WHERE PK_ESTABLECIMIENTO = p_fk_establecimiento AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No se encontro un establecimiento activo con ese identificador' USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pigse.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_lista_valor_zona AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'FK_TLV_ZONA (%) no existe o no esta activa', p_fk_lista_valor_zona USING ERRCODE = '23503';
    END IF;

    IF EXISTS (SELECT 1 FROM pigse.TSEDE WHERE CODIGO = p_codigo AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'Ya existe una sede activa con CODIGO %', p_codigo USING ERRCODE = '23505';
    END IF;
    IF EXISTS (SELECT 1 FROM pigse.TSEDE WHERE FK_TESTABLECIMIENTO = p_fk_establecimiento AND NOMBRE = p_nombre AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'Ya existe una sede activa con el nombre "%" en este establecimiento', p_nombre USING ERRCODE = '23505';
    END IF;

    SELECT LPAD((COALESCE(MAX(NULLIF(TRIM(CONSECUTIVO), '')::INT), 0) + 1)::TEXT, 2, '0')
      INTO v_consecutivo
      FROM pigse.TSEDE
     WHERE FK_TESTABLECIMIENTO = p_fk_establecimiento AND ACTIVE = TRUE;

    INSERT INTO pigse.TSEDE (
        CODIGO, NOMBRE, CONSECUTIVO, FK_TLV_ZONA, LOCALIDAD, COMUNA, BARRIO, DIRECCION, TELEFONO,
        FK_TESTABLECIMIENTO, GEOREFERENCIACION, CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        p_codigo, p_nombre, v_consecutivo, p_fk_lista_valor_zona,
        NULLIF(TRIM(p_localidad), ''), NULLIF(TRIM(p_comuna), ''), NULLIF(TRIM(p_barrio), ''),
        NULLIF(TRIM(p_direccion), ''), NULLIF(TRIM(p_telefono), ''),
        p_fk_establecimiento, p_georeferenciacion,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TSEDE INTO v_id_creado;

    -- Sincroniza al rector/secretaria ACTUAL del EE en la sede nueva -- mismo
    -- invariante que CEVAL: "rector/secretaria tiene permiso en TODAS las
    -- sedes de su EE".
    SELECT FK_TFUNCIONARIO_RECTOR, FK_TFUNCIONARIO_SECRETARIA
      INTO v_pk_rector, v_pk_secretaria
      FROM pigse.TESTABLECIMIENTO WHERE PK_ESTABLECIMIENTO = p_fk_establecimiento;

    SELECT PK_LISTA_VALOR INTO v_jornada_completa
      FROM pigse.TLISTA_VALOR WHERE CATEGORIA = 'JORNADA' AND NOMBRE = 'Completa' AND ACTIVE = TRUE
     LIMIT 1;

    IF v_pk_rector IS NOT NULL AND v_jornada_completa IS NOT NULL THEN
        SELECT FK_TUSUARIO INTO v_fk_usu_rector FROM pigse.TFUNCIONARIO WHERE PK_TFUNCIONARIO = v_pk_rector;
        IF v_fk_usu_rector IS NOT NULL THEN
            PERFORM pigse.fn_sede_usuario_crear(
                p_pk_usuario_solicitante, v_id_creado,
                (SELECT id_role FROM public.role WHERE name = 'PIGSE-RECTOR'),
                v_fk_usu_rector, 1, v_jornada_completa, 'ACTIVO', 0
            );
        END IF;
    END IF;

    IF v_pk_secretaria IS NOT NULL AND v_jornada_completa IS NOT NULL THEN
        SELECT FK_TUSUARIO INTO v_fk_usu_secretaria FROM pigse.TFUNCIONARIO WHERE PK_TFUNCIONARIO = v_pk_secretaria;
        IF v_fk_usu_secretaria IS NOT NULL THEN
            PERFORM pigse.fn_sede_usuario_crear(
                p_pk_usuario_solicitante, v_id_creado,
                (SELECT id_role FROM public.role WHERE name = 'PIGSE-SECRETARIO'),
                v_fk_usu_secretaria, 1, v_jornada_completa, 'ACTIVO', 0
            );
        END IF;
    END IF;

    RETURN v_id_creado;
END;
$$;

COMMENT ON FUNCTION pigse.fn_sed_crear(BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR) IS
    'V370: crea una TSEDE. Espejo de academico_test.fn_sed_crear, incluido el auto-grant de rector/secretaria en la sede nueva (jornada "Completa").';

CREATE OR REPLACE FUNCTION pigse.fn_sed_actualizar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_sede                BIGINT,
    p_codigo                 VARCHAR DEFAULT NULL,
    p_nombre                 VARCHAR DEFAULT NULL,
    p_fk_lista_valor_zona    BIGINT  DEFAULT NULL,
    p_localidad              VARCHAR DEFAULT NULL,
    p_comuna                 VARCHAR DEFAULT NULL,
    p_barrio                 VARCHAR DEFAULT NULL,
    p_direccion              VARCHAR DEFAULT NULL,
    p_telefono               VARCHAR DEFAULT NULL,
    p_georeferenciacion      VARCHAR DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
SET search_path = pigse, public
AS $$
DECLARE
    v_estado_actual BOOLEAN;
    v_fk_ee         BIGINT;
BEGIN
    SELECT ACTIVE, FK_TESTABLECIMIENTO INTO v_estado_actual, v_fk_ee
      FROM pigse.TSEDE WHERE PK_TSEDE = p_pk_sede;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la sede solicitada' USING ERRCODE = 'P0002';
    END IF;

    PERFORM pigse.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'SEDES_EDUCATIVAS', 'EDITAR', v_fk_ee, p_pk_sede);

    IF v_estado_actual = FALSE THEN
        RAISE EXCEPTION 'La sede se encuentra inactiva; no se puede actualizar' USING ERRCODE = '22023';
    END IF;

    IF p_codigo IS NOT NULL AND NULLIF(TRIM(p_codigo), '') IS NULL THEN
        RAISE EXCEPTION 'Codigo de la sede no puede ser vacio si se envia' USING ERRCODE = '22023';
    END IF;
    IF p_nombre IS NOT NULL AND NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'Nombre de la sede no puede ser vacio si se envia' USING ERRCODE = '22023';
    END IF;

    IF p_fk_lista_valor_zona IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM pigse.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_lista_valor_zona AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'FK_TLV_ZONA (%) no existe o no esta activa', p_fk_lista_valor_zona USING ERRCODE = '23503';
    END IF;

    IF p_codigo IS NOT NULL AND EXISTS (
        SELECT 1 FROM pigse.TSEDE WHERE CODIGO = p_codigo AND ACTIVE = TRUE AND PK_TSEDE <> p_pk_sede
    ) THEN
        RAISE EXCEPTION 'Ya existe otra sede activa con CODIGO %', p_codigo USING ERRCODE = '23505';
    END IF;
    IF p_nombre IS NOT NULL AND EXISTS (
        SELECT 1 FROM pigse.TSEDE WHERE FK_TESTABLECIMIENTO = v_fk_ee AND NOMBRE = p_nombre AND ACTIVE = TRUE AND PK_TSEDE <> p_pk_sede
    ) THEN
        RAISE EXCEPTION 'Ya existe otra sede activa con NOMBRE % en este establecimiento', p_nombre USING ERRCODE = '23505';
    END IF;

    UPDATE pigse.TSEDE
       SET CODIGO            = COALESCE(p_codigo, CODIGO),
           NOMBRE            = COALESCE(p_nombre, NOMBRE),
           FK_TLV_ZONA       = COALESCE(p_fk_lista_valor_zona, FK_TLV_ZONA),
           LOCALIDAD         = COALESCE(NULLIF(TRIM(p_localidad), ''), LOCALIDAD),
           COMUNA            = COALESCE(NULLIF(TRIM(p_comuna), ''), COMUNA),
           BARRIO            = COALESCE(NULLIF(TRIM(p_barrio), ''), BARRIO),
           DIRECCION         = COALESCE(NULLIF(TRIM(p_direccion), ''), DIRECCION),
           TELEFONO          = COALESCE(NULLIF(TRIM(p_telefono), ''), TELEFONO),
           GEOREFERENCIACION = COALESCE(p_georeferenciacion, GEOREFERENCIACION),
           MODIFIED_BY       = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT       = CURRENT_TIMESTAMP
     WHERE PK_TSEDE = p_pk_sede;

    RETURN p_pk_sede;
END;
$$;

COMMENT ON FUNCTION pigse.fn_sed_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR) IS
    'V370: PATCH parcial de una TSEDE activa (NULL = no cambia). Espejo de academico_test.fn_sed_actualizar. FK_TESTABLECIMIENTO/CONSECUTIVO inmutables.';

CREATE OR REPLACE FUNCTION pigse.fn_sed_soft_delete(
    p_pk_usuario_solicitante BIGINT,
    p_pk_sede                BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
SET search_path = pigse, public
AS $$
DECLARE
    v_estado_actual BOOLEAN;
    v_fk_ee         BIGINT;
BEGIN
    SELECT ACTIVE, FK_TESTABLECIMIENTO INTO v_estado_actual, v_fk_ee
      FROM pigse.TSEDE WHERE PK_TSEDE = p_pk_sede;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la sede solicitada' USING ERRCODE = 'P0002';
    END IF;

    PERFORM pigse.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'SEDES_EDUCATIVAS', 'ELIMINAR', v_fk_ee, p_pk_sede);

    IF v_estado_actual = FALSE THEN
        RAISE EXCEPTION 'La sede ya se encuentra inactiva' USING ERRCODE = '22023';
    END IF;

    UPDATE pigse.TSEDE
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TSEDE = p_pk_sede;

    UPDATE pigse.TSEDE_USUARIO
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TSEDE = p_pk_sede AND ACTIVE = TRUE;

    RETURN p_pk_sede;
END;
$$;

COMMENT ON FUNCTION pigse.fn_sed_soft_delete(BIGINT, BIGINT) IS
    'V370: baja logica en cascada de una TSEDE + sus TSEDE_USUARIO activos. Espejo de academico_test.fn_sed_soft_delete (sin TSEDE_NIVEL, que PIGSE no tiene).';

CREATE OR REPLACE FUNCTION pigse.fn_sed_soft_delete_bulk(
    p_pk_usuario_solicitante BIGINT,
    p_pks                    BIGINT[]
)
RETURNS TABLE(pk_sede BIGINT, status VARCHAR)
LANGUAGE plpgsql
SET search_path = pigse, public
AS $$
DECLARE
    v_pk BIGINT;
BEGIN
    IF p_pks IS NULL OR CARDINALITY(p_pks) = 0 THEN
        RAISE EXCEPTION 'p_pks es obligatorio y debe contener al menos un PK_TSEDE' USING ERRCODE = '22023';
    END IF;

    FOREACH v_pk IN ARRAY p_pks LOOP
        BEGIN
            PERFORM pigse.fn_sed_soft_delete(p_pk_usuario_solicitante, v_pk);
            pk_sede := v_pk; status := 'eliminado';
            RETURN NEXT;
        EXCEPTION
            WHEN sqlstate 'P0002' THEN
                pk_sede := v_pk; status := 'error:no_encontrado'; RETURN NEXT;
            WHEN sqlstate '42501' THEN
                pk_sede := v_pk; status := 'error:sin_permiso'; RETURN NEXT;
            WHEN sqlstate '22023' THEN
                pk_sede := v_pk; status := 'error:ya_inactivo'; RETURN NEXT;
            WHEN OTHERS THEN
                pk_sede := v_pk; status := 'error:' || SQLERRM; RETURN NEXT;
        END;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION pigse.fn_sed_soft_delete_bulk(BIGINT, BIGINT[]) IS
    'V370: baja logica bulk de sedes -- cada PK en su propio savepoint (un fallo no aborta el resto). Espejo de academico_test.fn_sed_soft_delete_bulk.';

CREATE OR REPLACE FUNCTION pigse.fn_sed_buscar_por_pk(
    p_pk_usuario_solicitante BIGINT,
    p_pk_sede                BIGINT
)
RETURNS TABLE (
    pk_sede BIGINT, codigo VARCHAR, nombre VARCHAR, consecutivo VARCHAR,
    fk_tlv_zona BIGINT, localidad VARCHAR, comuna VARCHAR, barrio VARCHAR,
    direccion VARCHAR, telefono VARCHAR, fk_establecimiento BIGINT,
    establecimiento_nombre VARCHAR, georeferenciacion VARCHAR
)
LANGUAGE plpgsql STABLE
SET search_path = pigse, public
AS $$
BEGIN
    PERFORM pigse.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'SEDES_EDUCATIVAS', 'VER');

    RETURN QUERY
    SELECT s.PK_TSEDE, s.CODIGO, s.NOMBRE, s.CONSECUTIVO, s.FK_TLV_ZONA,
           s.LOCALIDAD, s.COMUNA, s.BARRIO, s.DIRECCION, s.TELEFONO,
           s.FK_TESTABLECIMIENTO, e.NOMBRE, s.GEOREFERENCIACION
      FROM pigse.TSEDE s
      JOIN pigse.TESTABLECIMIENTO e ON e.PK_ESTABLECIMIENTO = s.FK_TESTABLECIMIENTO
     WHERE s.PK_TSEDE = p_pk_sede AND s.ACTIVE = TRUE;
END;
$$;

COMMENT ON FUNCTION pigse.fn_sed_buscar_por_pk(BIGINT, BIGINT) IS 'V370: lookup por PK_TSEDE (solo activas).';

DROP FUNCTION IF EXISTS pigse.fn_fun_crear(BIGINT, BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION pigse.fn_fun_soft_delete(
    p_pk_usuario_solicitante BIGINT,
    p_pk_funcionario         BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SET search_path = pigse, public
AS $$
DECLARE
    v_pk_usuario BIGINT;
    v_active     BOOLEAN;
BEGIN
    SELECT f.FK_TUSUARIO, f.ACTIVE INTO v_pk_usuario, v_active
      FROM pigse.TFUNCIONARIO f WHERE f.PK_TFUNCIONARIO = p_pk_funcionario;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el funcionario solicitado (%)', p_pk_funcionario USING ERRCODE = 'P0002';
    END IF;

    PERFORM pigse.fn_assert_permiso_funcionario(p_pk_usuario_solicitante, 'ELIMINAR', p_pk_funcionario);

    IF v_active = FALSE THEN
        RAISE EXCEPTION 'El funcionario (%) ya se encuentra inactivo', p_pk_funcionario USING ERRCODE = '22023';
    END IF;

    UPDATE pigse.TFUNCIONARIO
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TFUNCIONARIO = p_pk_funcionario;

    UPDATE pigse.TSEDE_USUARIO
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TUSUARIO = v_pk_usuario AND ACTIVE = TRUE;

    RETURN TRUE;
END;
$$;

COMMENT ON FUNCTION pigse.fn_fun_soft_delete(BIGINT, BIGINT) IS
    'V370: baja logica en cascada sobre TSEDE_USUARIO (reemplaza TESTABLECIMIENTO_USUARIO). Gate por fn_assert_permiso_funcionario.';

INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types)
SELECT 'pigse-sedes-query',
       $q$SELECT * FROM pigse.fn_sed_listar(
              public.fn_get_pigse_usuario_id(CAST(:CONTEXT.USER_ID AS BIGINT)),
              CAST(:BODY.FILTERS.SEARCH AS VARCHAR), CAST(:BODY.FILTERS.ESTABLECIMIENTO AS BIGINT),
              CAST(:BODY.SORTING.ID AS VARCHAR), CAST(:BODY.SORTING.DESC AS BOOLEAN),
              CAST(:BODY.PAGEINDEX AS INTEGER), CAST(:BODY.PAGESIZE AS INTEGER)
          )$q$,
       'postgres', m.id_microservice, '/sedes/query', 'SELECT', 'POST',
       '{"BODY.FILTERS.SEARCH": "VARCHAR", "BODY.FILTERS.ESTABLECIMIENTO": "BIGINT",
         "BODY.SORTING.ID": "VARCHAR", "BODY.SORTING.DESC": "BOOLEAN",
         "BODY.PAGEINDEX": "INTEGER", "BODY.PAGESIZE": "INTEGER"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-sedes-query');

INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types)
SELECT 'pigse-sedes-buscar-pk',
       $q$SELECT * FROM pigse.fn_sed_buscar_por_pk(public.fn_get_pigse_usuario_id(CAST(:CONTEXT.USER_ID AS BIGINT)), CAST(:PARAM.ID AS BIGINT))$q$,
       'postgres', m.id_microservice, '/sedes/:ID', 'SELECT', 'GET', '{"PARAM.ID": "BIGINT!"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-sedes-buscar-pk');

INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types)
SELECT 'pigse-sedes-crear',
       $q$SELECT pigse.fn_sed_crear(
              public.fn_get_pigse_usuario_id(CAST(:CONTEXT.USER_ID AS BIGINT)),
              CAST(:BODY.CODIGO AS VARCHAR), CAST(:BODY.NOMBRE AS VARCHAR),
              CAST(:BODY.FK_TLV_ZONA AS BIGINT), CAST(:BODY.FK_ESTABLECIMIENTO AS BIGINT),
              CAST(:BODY.LOCALIDAD AS VARCHAR), CAST(:BODY.COMUNA AS VARCHAR), CAST(:BODY.BARRIO AS VARCHAR),
              CAST(:BODY.DIRECCION AS VARCHAR), CAST(:BODY.TELEFONO AS VARCHAR), CAST(:BODY.GEOREFERENCIACION AS VARCHAR)
          ) AS pk_sede$q$,
       'postgres', m.id_microservice, '/sedes', 'SELECT', 'POST',
       '{"BODY.CODIGO": "VARCHAR!", "BODY.NOMBRE": "VARCHAR!", "BODY.FK_TLV_ZONA": "BIGINT!",
         "BODY.FK_ESTABLECIMIENTO": "BIGINT!", "BODY.LOCALIDAD": "VARCHAR", "BODY.COMUNA": "VARCHAR",
         "BODY.BARRIO": "VARCHAR", "BODY.DIRECCION": "VARCHAR", "BODY.TELEFONO": "VARCHAR",
         "BODY.GEOREFERENCIACION": "VARCHAR"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-sedes-crear');

INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types)
SELECT 'pigse-sedes-actualizar',
       $q$SELECT pigse.fn_sed_actualizar(
              public.fn_get_pigse_usuario_id(CAST(:CONTEXT.USER_ID AS BIGINT)), CAST(:PARAM.ID AS BIGINT),
              CAST(:BODY.CODIGO AS VARCHAR), CAST(:BODY.NOMBRE AS VARCHAR), CAST(:BODY.FK_TLV_ZONA AS BIGINT),
              CAST(:BODY.LOCALIDAD AS VARCHAR), CAST(:BODY.COMUNA AS VARCHAR), CAST(:BODY.BARRIO AS VARCHAR),
              CAST(:BODY.DIRECCION AS VARCHAR), CAST(:BODY.TELEFONO AS VARCHAR), CAST(:BODY.GEOREFERENCIACION AS VARCHAR)
          ) AS actualizado$q$,
       'postgres', m.id_microservice, '/sedes/:ID', 'SELECT', 'PUT',
       '{"PARAM.ID": "BIGINT!", "BODY.CODIGO": "VARCHAR", "BODY.NOMBRE": "VARCHAR", "BODY.FK_TLV_ZONA": "BIGINT",
         "BODY.LOCALIDAD": "VARCHAR", "BODY.COMUNA": "VARCHAR", "BODY.BARRIO": "VARCHAR",
         "BODY.DIRECCION": "VARCHAR", "BODY.TELEFONO": "VARCHAR", "BODY.GEOREFERENCIACION": "VARCHAR"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-sedes-actualizar');

INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types)
SELECT 'pigse-sedes-eliminar',
       $q$SELECT pigse.fn_sed_soft_delete(public.fn_get_pigse_usuario_id(CAST(:CONTEXT.USER_ID AS BIGINT)), CAST(:PARAM.ID AS BIGINT)) AS eliminado$q$,
       'postgres', m.id_microservice, '/sedes/:ID', 'SELECT', 'PATCH', '{"PARAM.ID": "BIGINT!"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-sedes-eliminar');

INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types)
SELECT 'pigse-sedes-eliminar-multiple',
       $q$SELECT * FROM pigse.fn_sed_soft_delete_bulk(public.fn_get_pigse_usuario_id(CAST(:CONTEXT.USER_ID AS BIGINT)), CAST(:BODY.PKS AS BIGINT[]))$q$,
       'postgres', m.id_microservice, '/sedes/eliminar-multiple', 'SELECT', 'PUT', '{"BODY.PKS": "BIGINT[]!"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-sedes-eliminar-multiple');

INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types)
SELECT 'pigse-funcionario-permisos-actualizar',
       $q$SELECT * FROM pigse.fn_fun_permisos_actualizar(
              public.fn_get_pigse_usuario_id(CAST(:CONTEXT.USER_ID AS BIGINT)), CAST(:PARAM.ID AS BIGINT), CAST(:BODY.PERMISOS AS JSONB)
          )$q$,
       'postgres', m.id_microservice, '/funcionario/:ID/permisos', 'SELECT', 'PUT',
       '{"PARAM.ID": "BIGINT!", "BODY.PERMISOS": "JSONB!"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-funcionario-permisos-actualizar');

INSERT INTO public.role_query (query_id, role_id)
SELECT q.id_query, ro.id_role
  FROM public.query q CROSS JOIN public.role ro
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'pigse'
 WHERE q.uuid IN ('pigse-sedes-query', 'pigse-sedes-buscar-pk', 'pigse-sedes-crear',
                  'pigse-sedes-actualizar', 'pigse-sedes-eliminar', 'pigse-sedes-eliminar-multiple',
                  'pigse-funcionario-permisos-actualizar')
   AND ro.name IN ('PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL')
   AND NOT EXISTS (SELECT 1 FROM public.role_query rq WHERE rq.query_id = q.id_query AND rq.role_id = ro.id_role);

INSERT INTO public.role_query (query_id, role_id)
SELECT q.id_query, ro.id_role
  FROM public.query q CROSS JOIN public.role ro
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'pigse'
 WHERE q.uuid IN ('pigse-sedes-query', 'pigse-sedes-buscar-pk')
   AND ro.name IN ('PIGSE-DIRECTOR_ENTE_TERRITORIAL', 'PIGSE-JEFE_SISTEMA_ENTE_TERRITORIAL',
                   'PIGSE-JEFE_AREA_PLANEACION', 'PIGSE-JEFE_AREA_COBERTURA', 'PIGSE-JEFE_AREA_CALIDAD',
                   'PIGSE-RECTOR', 'PIGSE-JEFE_SISTEMA_ESTABLECIMIENTO', 'PIGSE-AUXILIAR_ADMINISTRATIVO')
   AND NOT EXISTS (SELECT 1 FROM public.role_query rq WHERE rq.query_id = q.id_query AND rq.role_id = ro.id_role);

INSERT INTO public.role_query (query_id, role_id)
SELECT q.id_query, ro.id_role
  FROM public.query q CROSS JOIN public.role ro
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'pigse'
 WHERE q.uuid = 'pigse-funcionario-permisos-actualizar'
   AND ro.name IN ('PIGSE-RECTOR', 'PIGSE-JEFE_SISTEMA_ESTABLECIMIENTO')
   AND NOT EXISTS (SELECT 1 FROM public.role_query rq WHERE rq.query_id = q.id_query AND rq.role_id = ro.id_role);
