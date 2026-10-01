-- ===========================================================================
-- V29 — Helpers de autorizacion: capability (menu) + scope (EE / sede+jornada)
-- + categoria de rol. Son los ladrillos de fn_assert_permiso_seccion, de los
-- gates de funcionarios y de los de Periodo Academico.
--
-- Viven en otras migraciones: fn_usuario_categoria_rol_nivel (V302; aqui solo
-- se crea si falta, porque V40 y V224 la ejecutan al migrar) y
-- fn_assert_rango_rol / fn_assert_rango_rol_otorgable (V298).
--
-- Depende de: V185 (fn_usuario_permisos_menu, enlazada en tiempo de
-- ejecucion) y V120 (TROL.FK_TLISTA_VALOR_CATEGORIA).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 1) fn_rol_categoria_nivel — nivel jerarquico (0..4) de UN rol.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_rol_categoria_nivel(
    p_pk_trol  BIGINT
)
RETURNS INT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_nivel  INT;
BEGIN
    SELECT CASE UPPER(TRIM(lv.VALOR))
               WHEN 'SUPER_ADMIN'                     THEN 0
               WHEN 'ADMINISTRATIVOS_TERRITORIALES'   THEN 1
               WHEN 'ADMINISTRATIVOS_ESTABLECIMIENTO' THEN 2
               WHEN 'ADMINISTRATIVOS_SEDES'           THEN 3
               WHEN 'ESTUDIANTES_FAMILIA'             THEN 4
               ELSE NULL
           END
      INTO v_nivel
      FROM academico_test.TROL r
      JOIN academico_test.TLISTA_VALOR lv
        ON lv.PK_LISTA_VALOR = r.FK_TLISTA_VALOR_CATEGORIA
       AND lv.CATEGORIA      = 'CATEGORIA_ROL'
     WHERE r.PK_TROL = p_pk_trol;

    -- Rol inexistente, sin categoria o con un VALOR desconocido -> 4.
    RETURN COALESCE(v_nivel, 4);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_rol_categoria_nivel(BIGINT)
    IS 'Nivel jerarquico (0 = mas alto) de la categoria de un rol, derivado de TROL.FK_TLISTA_VALOR_CATEGORIA -> TLISTA_VALOR (CATEGORIA=''CATEGORIA_ROL'', V120): 0 SUPER_ADMIN, 1 ADMINISTRATIVOS_TERRITORIALES, 2 ADMINISTRATIVOS_ESTABLECIMIENTO, 3 ADMINISTRATIVOS_SEDES, 4 ESTUDIANTES_FAMILIA. El mapeo se resuelve por el TEXTO de TLISTA_VALOR.VALOR, no por pk_lista_valor (varia por ambiente). Rol inexistente, sin categoria asignada (NULL) o con un VALOR desconocido -> 4 (el nivel mas bajo, fail-closed). Nunca devuelve NULL. LANGUAGE plpgsql (no sql) a proposito: se define en V29, antes de que V120 cree FK_TLISTA_VALOR_CATEGORIA, y solo plpgsql difiere la resolucion de nombres a tiempo de ejecucion.';

-- ---------------------------------------------------------------------------
-- 2) fn_usuario_categoria_rol_nivel — nivel MAS ALTO (numero MAS BAJO) de
--    entre las categorias de todos los roles activos del usuario.
-- ---------------------------------------------------------------------------
DO $guarda$
BEGIN
    IF to_regprocedure('academico_test.fn_usuario_categoria_rol_nivel(bigint)') IS NULL THEN
        EXECUTE $crear$CREATE OR REPLACE FUNCTION academico_test.fn_usuario_categoria_rol_nivel(
    p_pk_tusuario  BIGINT
)
RETURNS INT
LANGUAGE plpgsql
STABLE
AS $fnucrn$
DECLARE
    v_nivel  INT;
BEGIN
    SELECT MIN(academico_test.fn_rol_categoria_nivel(su.FK_TROL))
      INTO v_nivel
      FROM academico_test.TSEDE_USUARIO su
     WHERE su.FK_TUSUARIO = p_pk_tusuario
       AND su.ACTIVE      = TRUE;

    -- NULL si el usuario no tiene ningun rol activo (MIN sobre 0 filas).
    RETURN v_nivel;
END;
$fnucrn$
$crear$;
    END IF;
END
$guarda$;

COMMENT ON FUNCTION academico_test.fn_usuario_categoria_rol_nivel(BIGINT)
    IS 'Nivel jerarquico (0 = mas alto) de la categoria de rol MAS ALTA que tiene el usuario entre sus TSEDE_USUARIO ACTIVE (multi-rol -> MIN del nivel). Devuelve NULL si el usuario no tiene ningun rol activo. Mismo criterio "solo ACTIVE" que fn_usuario_permisos_menu (V185), sin filtrar ademas por TLV_ESTADO. 0 = SUPER_ADMIN (bypass), 1 = territorial (todos los EE), 2 = establecimiento, 3 = sedes (sede+jornada), 4 = estudiantes/familia.';

-- ---------------------------------------------------------------------------
-- 2.b) fn_usuario_es_docente_puro — el usuario no administra nada, asi que
--      dentro de su alcance solo le corresponde SU propio contenido.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_usuario_es_docente_puro(
    p_pk_tusuario  BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_nivel  INT;
    v_peso   INT;
BEGIN
    SELECT MIN(academico_test.fn_rol_categoria_nivel(su.FK_TROL))
      INTO v_nivel
      FROM academico_test.TSEDE_USUARIO su
     WHERE su.FK_TUSUARIO = p_pk_tusuario
       AND su.ACTIVE      = TRUE;

    -- Sin rol activo -> fail-closed (solo lo propio, que para un usuario sin
    -- funcionario es nada).
    IF v_nivel IS NULL OR v_nivel >= 4 THEN
        RETURN TRUE;
    END IF;
    IF v_nivel <= 2 THEN
        RETURN FALSE;
    END IF;

    -- Nivel 3 (ADMINISTRATIVOS_SEDES) mete en la MISMA categoria al
    -- coordinador (peso 1), al jefe de area (2) y al director de grupo (3)
    -- junto al docente (4): dentro de la categoria solo PESO_CATEGORIA los
    -- separa, por eso el nivel por si solo no alcanza aqui.
    SELECT MIN(COALESCE(r.PESO_CATEGORIA, 4))
      INTO v_peso
      FROM academico_test.TSEDE_USUARIO su
      JOIN academico_test.TROL r ON r.PK_TROL = su.FK_TROL
     WHERE su.FK_TUSUARIO = p_pk_tusuario
       AND su.ACTIVE      = TRUE
       AND academico_test.fn_rol_categoria_nivel(su.FK_TROL) = 3;

    RETURN COALESCE(v_peso, 4) >= 4;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_usuario_es_docente_puro(BIGINT)
    IS 'TRUE cuando el usuario NO tiene alcance administrativo y por tanto solo le corresponde su propio contenido (sus unidades, las actividades que dicta), aunque su rol le de alcance territorial de LECTURA sobre una sede. Resuelve el caso que fn_usuario_categoria_rol_nivel no puede: DOCENTE y PSICO_ORIENTADOR comparten la categoria ADMINISTRATIVOS_SEDES (nivel 3) con COORDINADOR, JEFE_AREA y DIRECTOR_GRUPO, que si administran; dentro de esa categoria solo TROL.PESO_CATEGORIA (V120) los distingue, y los dos primeros son peso 4. Multi-rol -> gana el rol mas alto: basta un rol de nivel <= 2 (rector, secretaria, territorial, super admin) o un peso < 4 dentro del nivel 3 para que devuelva FALSE. Fail-closed: usuario sin ningun rol activo, sin categoria o con peso NULL -> TRUE. Pensado para acompanar a fn_usuario_sedes_lectura, no para reemplazarla: la sede sigue acotando QUE se ve, y esta funcion decide si ademas se acota a lo propio.';

-- ---------------------------------------------------------------------------
-- 3) fn_usuario_ee_accesibles — establecimientos que alcanza el usuario.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_usuario_ee_accesibles(
    p_pk_tusuario  BIGINT
)
RETURNS TABLE (establecimiento_id BIGINT)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    -- (a) EE donde el usuario es RECTOR por puntero.
    SELECT e.PK_ESTABLECIMIENTO
      FROM academico_test.TESTABLECIMIENTO e
      JOIN academico_test.TFUNCIONARIO f
        ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
     WHERE e.ACTIVE = TRUE
       AND f.ACTIVE = TRUE
       AND f.FK_TUSUARIO = p_pk_tusuario
    UNION
    -- (b) EE donde el usuario es SECRETARIA por puntero.
    SELECT e.PK_ESTABLECIMIENTO
      FROM academico_test.TESTABLECIMIENTO e
      JOIN academico_test.TFUNCIONARIO f
        ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
     WHERE e.ACTIVE = TRUE
       AND f.ACTIVE = TRUE
       AND f.FK_TUSUARIO = p_pk_tusuario
    UNION
    -- (c) EE de las sedes donde tiene un TSEDE_USUARIO activo cuyo rol es
    --     de categoria ADMINISTRATIVOS_ESTABLECIMIENTO (nivel 2).
    SELECT s.FK_TESTABLECIMIENTO
      FROM academico_test.TSEDE_USUARIO su
      JOIN academico_test.TSEDE s
        ON s.PK_TSEDE = su.FK_TSEDE
      JOIN academico_test.TESTABLECIMIENTO e
        ON e.PK_ESTABLECIMIENTO = s.FK_TESTABLECIMIENTO
     WHERE su.FK_TUSUARIO = p_pk_tusuario
       AND su.ACTIVE = TRUE
       AND s.ACTIVE  = TRUE
       AND e.ACTIVE  = TRUE
       AND academico_test.fn_rol_categoria_nivel(su.FK_TROL) = 2;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_usuario_ee_accesibles(BIGINT)
    IS 'Establecimientos (ACTIVE) que un usuario alcanza por su scope estructural: UNION de (a) EE donde es rector por TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR, (b) EE donde es secretaria por FK_TFUNCIONARIO_SECRETARIA (ambos via un TFUNCIONARIO ACTIVE suyo, sin necesitar TSEDE_USUARIO), y (c) el FK_TESTABLECIMIENTO de las sedes ACTIVE donde tiene un TSEDE_USUARIO ACTIVE con un rol de categoria ADMINISTRATIVOS_ESTABLECIMIENTO (nivel 2). Sustituye los bloques "ee_accesibles" inline de V51/V52/V53/V72. NO incluye a los roles territoriales (nivel 1): su scope es "todos los EE" y se resuelve en fn_assert_permiso_seccion para no materializar la tabla entera. El nivel sale de la categoria del rol (V120), nunca de una lista de pk_trol. Es plpgsql (no sql) por el orden del historial, asi que NO se inline-a en un IN (SELECT ...): llamarla una vez por request esta bien, por fila de un listado no.';

-- ---------------------------------------------------------------------------
-- 4) fn_usuario_sedes_jornadas_accesibles — pares (sede, jornada).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_usuario_sedes_jornadas_accesibles(
    p_pk_tusuario  BIGINT
)
RETURNS TABLE (sede_id BIGINT, jornada_id BIGINT)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT DISTINCT su.FK_TSEDE, su.FK_TLV_JORNADA
      FROM academico_test.TSEDE_USUARIO su
      JOIN academico_test.TSEDE s
        ON s.PK_TSEDE = su.FK_TSEDE
     WHERE su.FK_TUSUARIO = p_pk_tusuario
       AND su.ACTIVE = TRUE
       AND s.ACTIVE  = TRUE
       AND academico_test.fn_rol_categoria_nivel(su.FK_TROL) = 3;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_usuario_sedes_jornadas_accesibles(BIGINT)
    IS 'Pares (sede, jornada) que alcanza un usuario cuyo rol es de categoria ADMINISTRATIVOS_SEDES (nivel 3): SELECT DISTINCT FK_TSEDE, FK_TLV_JORNADA de sus TSEDE_USUARIO ACTIVE sobre sedes ACTIVE. El alcance es por PAR: un usuario de la jornada Mañana de la sede X NO alcanza la jornada Tarde de esa misma sede. Reemplaza a fn_periodo_usuario_sedes (V37), que devolvia solo la sede (dejaba escapar las demas jornadas) y solo para el rol 11 literal.';

-- ---------------------------------------------------------------------------
-- 4bis) fn_usuario_ee_lectura — scope de LECTURA de las secciones
--       Establecimiento / Sedes. Mas amplio que fn_usuario_ee_accesibles
--       (que es el scope de ESCRITURA, solo niveles 0-2): aqui el nivel 3
--       (ADMINISTRATIVOS_SEDES / coordinador) SI ve -en solo lectura- el EE
--       al que pertenece(n) su(s) sede(s), aunque no pueda editarlo.
--         nivel 0 (SUPER_ADMIN)        -> todos los EE activos
--         nivel 1 (TERRITORIALES)      -> todos los EE activos
--         nivel 2 (ESTABLECIMIENTO)    -> fn_usuario_ee_accesibles
--         nivel 3 (SEDES)              -> EE de las sedes de fn_usuario_sedes_jornadas_accesibles
--         nivel 4 / sin categoria      -> ninguno (fail-closed)
--       La CAPABILITY (si puede o no VER la seccion) se comprueba aparte con
--       fn_usuario_puede_en_menu; esta funcion solo resuelve QUE EE alcanza.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_usuario_ee_lectura(
    p_pk_tusuario  BIGINT
)
RETURNS TABLE (establecimiento_id BIGINT)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_nivel INT := COALESCE(academico_test.fn_usuario_categoria_rol_nivel(p_pk_tusuario), 99);
BEGIN
    IF v_nivel <= 1 THEN
        RETURN QUERY
        SELECT e.PK_ESTABLECIMIENTO
          FROM academico_test.TESTABLECIMIENTO e
         WHERE e.ACTIVE = TRUE;
    ELSIF v_nivel = 2 THEN
        RETURN QUERY
        SELECT ee.establecimiento_id
          FROM academico_test.fn_usuario_ee_accesibles(p_pk_tusuario) ee;
    ELSIF v_nivel = 3 THEN
        RETURN QUERY
        SELECT DISTINCT s.FK_TESTABLECIMIENTO
          FROM academico_test.TSEDE s
          JOIN academico_test.fn_usuario_sedes_jornadas_accesibles(p_pk_tusuario) sj
            ON sj.sede_id = s.PK_TSEDE
         WHERE s.ACTIVE = TRUE
           AND s.FK_TESTABLECIMIENTO IS NOT NULL;
    END IF;
    -- nivel 4 / sin categoria: no devuelve filas.
END;
$$;

COMMENT ON FUNCTION academico_test.fn_usuario_ee_lectura(BIGINT)
    IS 'EE que un usuario alcanza EN LECTURA para las secciones Establecimiento / Sedes: niveles 0-1 -> todos; nivel 2 -> fn_usuario_ee_accesibles; nivel 3 (coordinador) -> el EE de sus sedes (fn_usuario_sedes_jornadas_accesibles), que NO esta en el scope de escritura. La capability se valida por separado con fn_usuario_puede_en_menu(u, ''ESTABLECIMIENTO''/''SEDES_EDUCATIVAS'', ''VER'').';

-- ---------------------------------------------------------------------------
-- 4ter) fn_usuario_sedes_lectura — scope de LECTURA a nivel de SEDE para el
--       listado de Sedes. Igual que fn_usuario_ee_lectura pero devolviendo
--       PK_TSEDE, y para el nivel 3 se queda SOLO en las sedes propias del
--       coordinador (no todas las del EE):
--         nivel 0-1  -> todas las sedes activas
--         nivel 2    -> sedes de los EE de fn_usuario_ee_accesibles
--         nivel 3    -> SOLO sus sedes (fn_usuario_sedes_jornadas_accesibles)
--         nivel 4 /  -> ninguna
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_usuario_sedes_lectura(
    p_pk_tusuario  BIGINT
)
RETURNS TABLE (sede_id BIGINT)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_nivel INT := COALESCE(academico_test.fn_usuario_categoria_rol_nivel(p_pk_tusuario), 99);
BEGIN
    IF v_nivel <= 1 THEN
        RETURN QUERY SELECT s.PK_TSEDE FROM academico_test.TSEDE s WHERE s.ACTIVE = TRUE;
    ELSIF v_nivel = 2 THEN
        RETURN QUERY
        SELECT s.PK_TSEDE
          FROM academico_test.TSEDE s
          JOIN academico_test.fn_usuario_ee_accesibles(p_pk_tusuario) ee
            ON ee.establecimiento_id = s.FK_TESTABLECIMIENTO
         WHERE s.ACTIVE = TRUE;
    ELSIF v_nivel = 3 THEN
        RETURN QUERY
        SELECT DISTINCT sj.sede_id
          FROM academico_test.fn_usuario_sedes_jornadas_accesibles(p_pk_tusuario) sj;
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_usuario_sedes_lectura(BIGINT)
    IS 'Sedes que un usuario alcanza EN LECTURA para el listado de Sedes. Niveles 0-1 -> todas; nivel 2 -> las de sus EE (fn_usuario_ee_accesibles); nivel 3 (coordinador) -> SOLO sus propias sedes (fn_usuario_sedes_jornadas_accesibles), no todas las del EE. La capability se valida aparte con fn_usuario_puede_en_menu(u, ''SEDES_EDUCATIVAS'', ''VER'').';

-- ---------------------------------------------------------------------------
-- 5) fn_usuario_puede_en_menu — capability.
-- ---------------------------------------------------------------------------
-- La UI de menus deriva el CODIGO del nombre, asi que un mismo menu puede
-- quedar como MATRICULA o MATRÍCULA segun el ambiente. Se compara siempre en
-- forma canonica. translate() porque unaccent no esta instalada.
CREATE OR REPLACE FUNCTION academico_test.fn_menu_codigo_canonico(
    p_codigo VARCHAR
)
RETURNS VARCHAR
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT UPPER(TRIM(translate(
        COALESCE(p_codigo, ''),
        'ÁÀÄÂáàäâÉÈËÊéèëêÍÌÏÎíìïîÓÒÖÔóòöôÚÙÜÛúùüûÑñÇç',
        'AAAAaaaaEEEEeeeeIIIIiiiiOOOOooooUUUUuuuuNnCc'
    )))::VARCHAR;
$$;

COMMENT ON FUNCTION academico_test.fn_menu_codigo_canonico(VARCHAR)
    IS 'Forma canonica de un TMENU.CODIGO: UPPER + TRIM + sin tildes/dieresis/cedilla. La usan el gate (fn_usuario_puede_en_menu), la resolucion de grupo (fn_menu_grupo_de) y la derivacion y unicidad de codigos al crear o editar menus (fn_upsert_menu).';

CREATE OR REPLACE FUNCTION academico_test.fn_usuario_puede_en_menu(
    p_pk_tusuario  BIGINT,
    p_codigo_menu  VARCHAR,
    p_accion       VARCHAR
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_puede  BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1
          FROM academico_test.fn_usuario_permisos_menu(p_pk_tusuario) pm
         WHERE academico_test.fn_menu_codigo_canonico(pm.codigo)
             = academico_test.fn_menu_codigo_canonico(p_codigo_menu)
           AND CASE UPPER(TRIM(COALESCE(p_accion, '')))
                   WHEN 'CREAR'    THEN pm.puede_crear
                   WHEN 'EDITAR'   THEN pm.puede_editar
                   WHEN 'ELIMINAR' THEN pm.puede_eliminar
                   WHEN 'VER'      THEN pm.puede_ver
                   ELSE FALSE          -- accion desconocida/NULL -> fail-closed
               END
    ) INTO v_puede;

    RETURN COALESCE(v_puede, FALSE);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_usuario_puede_en_menu(BIGINT, VARCHAR, VARCHAR)
    IS 'TRUE si el usuario puede ejecutar p_accion (''CREAR''|''EDITAR''|''ELIMINAR''|''VER'', comparada con UPPER(TRIM(...)), case-insensitive) sobre el TMENU de codigo p_codigo_menu, comparado en forma canonica (fn_menu_codigo_canonico: MATRICULA = MATRÍCULA). Envuelve fn_usuario_permisos_menu (V185), asi que hereda gratis la semantica "TROL_MENU concede (techo del rol) / TUSUARIO_ROL_PERMISO recorta (restriccion del usuario)". DECISION: una accion desconocida o NULL devuelve FALSE (fail-closed) en vez de lanzar 22023 — el caller de estos helpers es siempre codigo del repo con literales fijos, y un FALSE se traduce en el 42501 normal de capability en fn_assert_permiso_seccion; asi ningun typo abre acceso. Si el menu no esta concedido por ningun rol activo del usuario, tambien FALSE. Requiere fn_usuario_permisos_menu (V185) en tiempo de ejecucion: por eso es plpgsql y no sql (V29 es anterior a V185).';

-- ---------------------------------------------------------------------------
-- 6) fn_assert_permiso_seccion — capability + scope, en una llamada.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_assert_permiso_seccion(
    p_pk_tusuario         BIGINT,
    p_codigo_menu         VARCHAR,
    p_accion              VARCHAR,
    p_fk_establecimiento  BIGINT DEFAULT NULL,
    p_fk_tsede            BIGINT DEFAULT NULL,
    p_fk_tlv_jornada      BIGINT DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_nivel  INT;
    v_ee     BIGINT;
BEGIN
    v_nivel := academico_test.fn_usuario_categoria_rol_nivel(p_pk_tusuario);

    -- 0. Bypass: SUPER_ADMIN (nivel 0). Ni capability ni scope.
    IF v_nivel = 0 THEN
        RETURN;
    END IF;

    -- 1. Capability: posibilidad del rol (TROL_MENU) - restriccion del
    --    usuario (TUSUARIO_ROL_PERMISO).
    IF NOT academico_test.fn_usuario_puede_en_menu(p_pk_tusuario, p_codigo_menu, p_accion) THEN
        RAISE EXCEPTION 'El usuario no tiene permiso para % en el modulo %',
            LOWER(TRIM(COALESCE(p_accion, '(sin accion)'))),
            COALESCE(p_codigo_menu, '(sin modulo)')
            USING ERRCODE = '42501';
    END IF;

    -- 2. Scope: solo si la accion apunta a un objeto concreto.
    IF p_fk_establecimiento IS NOT NULL OR p_fk_tsede IS NOT NULL THEN

        -- 2.a nivel 1 (ADMINISTRATIVOS_TERRITORIALES): alcanza todos los EE.
        IF v_nivel = 1 THEN
            RETURN;
        END IF;

        -- 2.b alcance por establecimiento (nivel 2 + punteros rector /
        --     secretaria). Si p_fk_tsede no resuelve a un EE (sede
        --     inexistente), v_ee queda NULL y este paso se salta: solo 2.c
        --     podria autorizar. No se valida existencia/estado del objeto
        --     -- eso es responsabilidad del caller.
        v_ee := COALESCE(
            p_fk_establecimiento,
            (SELECT s.FK_TESTABLECIMIENTO
               FROM academico_test.TSEDE s
              WHERE s.PK_TSEDE = p_fk_tsede)
        );

        IF v_ee IS NOT NULL
           AND EXISTS (
               SELECT 1
                 FROM academico_test.fn_usuario_ee_accesibles(p_pk_tusuario) ee
                WHERE ee.establecimiento_id = v_ee
           ) THEN
            RETURN;
        END IF;

        -- 2.c alcance sede + jornada (nivel 3). Requiere AMBOS parametros:
        --     sin jornada no se puede distinguir una jornada de otra y
        --     autorizar seria mas permisivo que el modelo.
        IF p_fk_tsede IS NOT NULL AND p_fk_tlv_jornada IS NOT NULL
           AND EXISTS (
               SELECT 1
                 FROM academico_test.fn_usuario_sedes_jornadas_accesibles(p_pk_tusuario) sj
                WHERE sj.sede_id    = p_fk_tsede
                  AND sj.jornada_id = p_fk_tlv_jornada
           ) THEN
            RETURN;
        END IF;

        -- 2.d Secciones SIN jornada (ESTABLECIMIENTO / SEDES_EDUCATIVAS): un
        --     establecimiento o una sede no tienen jornada, asi que a un rol
        --     de nivel 3 (ADMINISTRATIVOS_SEDES) NO se le puede exigir la
        --     jornada de 2.c. Si el super admin le concedio la capability
        --     (paso 1 ya paso), su scope de escritura para ESTAS DOS
        --     secciones es:
        --       (i)  con SEDE objetivo concreta (editar / eliminar una sede)
        --            -> SOLO sus propias sedes (no las hermanas del EE).
        --       (ii) sin sede objetivo (editar el EE, o crear una sede)
        --            -> el EE al que pertenece(n) su(s) sede(s).
        --     Para PERIODOS / MATRICULA / cascada academica 2.d NO aplica --
        --     ahi la jornada SI distingue y manda 2.c.
        IF v_nivel = 3
           AND UPPER(TRIM(COALESCE(p_codigo_menu, ''))) IN ('ESTABLECIMIENTO', 'SEDES_EDUCATIVAS') THEN
            IF p_fk_tsede IS NOT NULL THEN
                IF EXISTS (
                    SELECT 1 FROM academico_test.fn_usuario_sedes_jornadas_accesibles(p_pk_tusuario) sj
                     WHERE sj.sede_id = p_fk_tsede
                ) THEN
                    RETURN;
                END IF;
            ELSIF v_ee IS NOT NULL THEN
                IF EXISTS (
                    SELECT 1
                      FROM academico_test.fn_usuario_sedes_jornadas_accesibles(p_pk_tusuario) sj
                      JOIN academico_test.TSEDE s ON s.PK_TSEDE = sj.sede_id
                     WHERE s.FK_TESTABLECIMIENTO = v_ee
                ) THEN
                    RETURN;
                END IF;
            END IF;
        END IF;

        RAISE EXCEPTION 'El usuario no tiene alcance sobre el establecimiento, sede o jornada objetivo'
            USING ERRCODE = '42501';
    END IF;

    -- Accion sin objeto (p.ej. crear un EE): la capability ya alcanzo.
    RETURN;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_assert_permiso_seccion(BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT)
    IS 'Assertion de autorizacion para las funciones CRUD de establecimiento / sedes / funcionarios / periodos academicos: PERFORM al inicio del cuerpo. Orden: (0) bypass si fn_usuario_categoria_rol_nivel = 0 (SUPER_ADMIN); (1) capability -- fn_usuario_puede_en_menu(u, menu, accion) debe ser TRUE, si no 42501 nombrando accion y modulo; (2) scope, SOLO si p_fk_establecimiento o p_fk_tsede no son NULL: (2.a) nivel 1 (territorial) alcanza todos los EE; (2.b) el EE objetivo (p_fk_establecimiento, o el FK_TESTABLECIMIENTO de p_fk_tsede) debe estar en fn_usuario_ee_accesibles; (2.c) el par (p_fk_tsede, p_fk_tlv_jornada) debe estar en fn_usuario_sedes_jornadas_accesibles; (2.d) SOLO para los menus ESTABLECIMIENTO y SEDES_EDUCATIVAS -- que no tienen jornada -- un rol nivel 3 (ADMINISTRATIVOS_SEDES) con la capability concedida alcanza su(s) sede(s) propia(s) (p_fk_tsede en fn_usuario_sedes_jornadas_accesibles) y el EE al que pertenecen, SIN exigir jornada; para PERIODOS/MATRICULA/cascada academica 2.d NO aplica y manda 2.c. Si nada aplica, 42501 con un mensaje DISTINTO al de capability. Si todos los p_fk_* son NULL (accion sin objeto, p.ej. crear un EE) la capability basta. NO valida existencia ni estado de los objetos (eso lo hace el caller). Es de solo lectura: llamarla N veces es equivalente a llamarla una.';

-- ---------------------------------------------------------------------------
-- 9) fn_assert_permiso_funcionario — capability + scope + rango, modulo
--    FUNCIONARIOS.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_assert_permiso_funcionario(
    p_pk_tusuario              BIGINT,
    p_accion                   VARCHAR,
    p_pk_funcionario_objetivo  BIGINT DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_nivel            INT;
    v_nombre_objetivo  TEXT;
BEGIN
    -- Bypass (nivel 0) + capability por el menu FUNCIONARIOS, sin objeto:
    -- el modulo funcionarios no encaja en "un solo EE objetivo".
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_tusuario, 'FUNCIONARIOS', p_accion);

    v_nivel := academico_test.fn_usuario_categoria_rol_nivel(p_pk_tusuario);

    -- El super admin ya paso; no tiene scope ni rango.
    IF v_nivel = 0 THEN
        RETURN;
    END IF;

    -- 'CREAR' u otras acciones sin objetivo: el EE se valida al vincular.
    IF p_pk_funcionario_objetivo IS NULL THEN
        RETURN;
    END IF;

    -- (a) SCOPE: el objetivo debe ser alcanzable. Los territoriales
    --     (nivel 1) alcanzan cualquier funcionario.
    IF v_nivel IS DISTINCT FROM 1 THEN
        IF NOT EXISTS (
            -- es rector/secretaria de un EE accesible
            SELECT 1
              FROM academico_test.TESTABLECIMIENTO e
             WHERE e.ACTIVE = TRUE
               AND (e.FK_TFUNCIONARIO_RECTOR       = p_pk_funcionario_objetivo
                    OR e.FK_TFUNCIONARIO_SECRETARIA = p_pk_funcionario_objetivo)
               AND EXISTS (
                   SELECT 1
                     FROM academico_test.fn_usuario_ee_accesibles(p_pk_tusuario) ee
                    WHERE ee.establecimiento_id = e.PK_ESTABLECIMIENTO
               )
            UNION ALL
            -- tiene un TSEDE_USUARIO activo en una sede de un EE accesible
            -- (nivel 2 + punteros).
            SELECT 1
              FROM academico_test.TFUNCIONARIO f
              JOIN academico_test.TSEDE_USUARIO su
                ON su.FK_TUSUARIO = f.FK_TUSUARIO AND su.ACTIVE = TRUE
              JOIN academico_test.TSEDE s
                ON s.PK_TSEDE = su.FK_TSEDE AND s.ACTIVE = TRUE
             WHERE f.PK_TFUNCIONARIO = p_pk_funcionario_objetivo
               AND EXISTS (
                   SELECT 1
                     FROM academico_test.fn_usuario_ee_accesibles(p_pk_tusuario) ee
                    WHERE ee.establecimiento_id = s.FK_TESTABLECIMIENTO
               )
            UNION ALL
            -- (nivel 3, ADMINISTRATIVOS_SEDES) tiene un TSEDE_USUARIO activo
            -- en una SEDE del scope del solicitante. Dinamico: si el super
            -- admin le da la capability de FUNCIONARIOS a un rol de esa
            -- categoria (coordinador, docente, jefe de area, ...), alcanza a
            -- los funcionarios de sus sedes. fn_usuario_sedes_jornadas_
            -- accesibles solo devuelve filas para nivel 3, asi que esta rama
            -- no aplica a los demas niveles. El rango (capa 3, abajo) sigue
            -- protegiendo a los funcionarios de su misma categoria o superior.
            SELECT 1
              FROM academico_test.TFUNCIONARIO f
              JOIN academico_test.TSEDE_USUARIO su
                ON su.FK_TUSUARIO = f.FK_TUSUARIO AND su.ACTIVE = TRUE
             WHERE f.PK_TFUNCIONARIO = p_pk_funcionario_objetivo
               AND EXISTS (
                   SELECT 1
                     FROM academico_test.fn_usuario_sedes_jornadas_accesibles(p_pk_tusuario) sj
                    WHERE sj.sede_id = su.FK_TSEDE
               )
        ) THEN
            SELECT TRIM(COALESCE(u.PRIMER_NOMBRE, '') || ' ' || COALESCE(u.PRIMER_APELLIDO, ''))
              INTO v_nombre_objetivo
              FROM academico_test.TFUNCIONARIO f
              JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
             WHERE f.PK_TFUNCIONARIO = p_pk_funcionario_objetivo;

            RAISE EXCEPTION 'El usuario no tiene alcance sobre el funcionario "%"',
                COALESCE(NULLIF(v_nombre_objetivo, ''), 'objetivo')
                USING ERRCODE = '42501';
        END IF;
    END IF;

    -- (b) RANGO: ni iguales ni superiores.
    PERFORM academico_test.fn_assert_rango_rol(p_pk_tusuario, p_pk_funcionario_objetivo);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_assert_permiso_funcionario(BIGINT, VARCHAR, BIGINT)
    IS 'Assertion de autorizacion del modulo FUNCIONARIOS: combina las 3 capas. (1) capability -- delega en fn_assert_permiso_seccion(u, ''FUNCIONARIOS'', accion) sin objeto, lo que tambien resuelve el bypass del SUPER_ADMIN (nivel 0). (2) scope -- si p_pk_funcionario_objetivo no es NULL y el solicitante no es de nivel 1 (territorial, alcanza a cualquiera), el funcionario objetivo debe: ser rector/secretaria de un EE de fn_usuario_ee_accesibles(u), O tener un TSEDE_USUARIO ACTIVE en una sede ACTIVE de uno de esos EE (nivel 2 + punteros), O -- para un solicitante de categoria ADMINISTRATIVOS_SEDES (nivel 3) -- tener un TSEDE_USUARIO ACTIVE en una SEDE de fn_usuario_sedes_jornadas_accesibles(u); si nada aplica, 42501 nombrando al funcionario. Es dinamico: basta con que el super admin conceda la capability de FUNCIONARIOS a un rol de nivel 3 para que ese rol alcance a los funcionarios de sus sedes. (3) rango -- PERFORM fn_assert_rango_rol(u, objetivo): no se alcanza a funcionarios de categoria igual o superior (esto sigue protegiendo a los pares del nivel 3 entre si). p_pk_funcionario_objetivo NULL (p.ej. ''CREAR'') solo exige capability: el EE se valida al vincular. Los tres 42501 llevan mensajes distintos.';

-- ===========================================================================
-- 10-14) Gate de permisos (capability + scope) para la cascada de Periodo
-- Académico. Fusionado aqui (antes V30 aparte) porque sus unicas
-- dependencias -- los helpers de arriba y TPERIODO_ACADEMICO/TSEDE
-- (creadas en V22, anterior a este archivo) -- ya existen en este mismo
-- punto del historial; no hacia falta un numero de version propio.
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_establecimiento(p_fk_periodo BIGINT)
RETURNS BIGINT LANGUAGE sql STABLE AS $$
    SELECT s.FK_TESTABLECIMIENTO
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE pa.PK_TPERIODO_ACADEMICO = p_fk_periodo;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_sede(p_fk_periodo BIGINT)
RETURNS BIGINT LANGUAGE sql STABLE AS $$
    SELECT pa.FK_TSEDE
      FROM academico_test.TPERIODO_ACADEMICO pa
     WHERE pa.PK_TPERIODO_ACADEMICO = p_fk_periodo;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_jornada(p_fk_periodo BIGINT)
RETURNS BIGINT LANGUAGE sql STABLE AS $$
    SELECT pa.FK_TLV_JORNADA
      FROM academico_test.TPERIODO_ACADEMICO pa
     WHERE pa.PK_TPERIODO_ACADEMICO = p_fk_periodo;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_sede(BIGINT)
    IS 'FK_TSEDE del periodo academico (NULL si no existe). Para pasar el par (sede, jornada) a fn_periodo_gate_escritura, que es lo que el scope de nivel 3 (ADMINISTRATIVOS_SEDES) necesita.';
COMMENT ON FUNCTION academico_test.fn_periodo_jornada(BIGINT)
    IS 'FK_TLV_JORNADA del periodo academico (NULL si no existe). Todo lo que cuelga de un periodo hereda su jornada.';

-- Reemplaza la firma vieja (BIGINT, BIGINT), que autorizaba por
-- fn_periodo_usuario_puede_gestionar / _puede_escribir (listas fijas de
-- FK_TROL, eliminadas — DROP formal en V211). Ahora es un wrapper de una
-- linea sobre fn_assert_permiso_seccion (arriba), menu 'PERIODOS_ACADEMICOS'.
-- La firma posicional vieja (usuario, EE) se conserva; sede/jornada/accion
-- se agregan AL FINAL con DEFAULT, asi que los call sites de 2 argumentos
-- que quedan sin tocar en varios módulos (grado/grupo, plan de estudio,
-- horario, asignacion academica, escala de valoracion, criterio de
-- evaluacion) siguen funcionando: heredan capability + scope de
-- establecimiento, pero un usuario de nivel 3 (ADMINISTRATIVOS_SEDES) no
-- satisface el scope sin sede+jornada y queda denegado (fallo seguro).
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_gate_escritura(
    p_pk_usuario          BIGINT,
    p_fk_establecimiento  BIGINT,
    p_fk_tsede            BIGINT  DEFAULT NULL,
    p_fk_tlv_jornada      BIGINT  DEFAULT NULL,
    p_accion              VARCHAR DEFAULT 'EDITAR'
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario, 'PERIODOS_ACADEMICOS', p_accion,
        p_fk_establecimiento, p_fk_tsede, p_fk_tlv_jornada);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_gate_escritura(BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR)
    IS 'Gate de ESCRITURA de la cascada academica (areas, asignaturas, enfasis, criterios, escalas, grados, grupos, planes, horarios, asignaciones) y de periodos / periodos de evaluacion / descansos. Wrapper de una linea sobre fn_assert_permiso_seccion, menu ''PERIODOS_ACADEMICOS''. CAPABILITY: TROL_MENU concede / TUSUARIO_ROL_PERMISO recorta. SCOPE: nivel 1 territorial = todos los EE; nivel 2 = fn_usuario_ee_accesibles; nivel 3 = par (sede, jornada) en fn_usuario_sedes_jornadas_accesibles. BYPASS: SUPER_ADMIN. Ya NO usa fn_periodo_usuario_puede_gestionar / _puede_escribir ni listas de FK_TROL. FALLO SEGURO: sin sede+jornada un usuario de nivel 3 no satisface el scope y se le deniega. Con los tres NULL solo se exige capability (bulk_delete).';

-- Gate de LECTURA de la cascada academica de Periodo Academico. Motivo: el
-- unico control real de que, por ejemplo, un docente no vea la
-- configuracion completa de un periodo academico era que el front oculte
-- el item de menu; contra el endpoint directo, fn_periodo_usuario_puede_ver
-- (V37, la version vieja) solo mira el scope de establecimiento por
-- TSEDE_USUARIO, sin revisar la capability del menu -- no distingue un rol
-- al que el super admin le quito PERIODOS_ACADEMICOS de uno al que se lo
-- dejo. fn_periodo_puede_ver es la version booleana (no lanza) del mismo
-- modelo capability + scope de fn_periodo_gate_escritura, pero para la
-- accion 'VER' -- mismo patron que fn_matricula_puede_ver (V40) para el
-- modulo Matricula. Reemplaza a fn_periodo_usuario_puede_ver en los
-- listados/reportes propios del modulo Periodo Academico (V37 a V46, V135,
-- V186-V190); fn_periodo_usuario_puede_ver NO se toca ni se elimina, porque
-- la siguen usando Matricula (V162) y otros modulos fuera de este alcance.
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_puede_ver(
    p_pk_usuario  BIGINT,
    p_fk_periodo  BIGINT
)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_nivel INT;
    v_est   BIGINT;
BEGIN
    -- Llamada interna (p.ej. reportes en modo administrador) sin usuario que
    -- scopear: pasa. Mismo criterio que fn_matricula_puede_ver.
    IF p_pk_usuario IS NULL THEN
        RETURN TRUE;
    END IF;

    v_nivel := COALESCE(academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario), 99);

    -- SUPER_ADMIN: bypass total, no se le exige ni capability ni scope.
    IF v_nivel = 0 THEN
        RETURN TRUE;
    END IF;

    -- Capability: sin el menu PERIODOS_ACADEMICOS en modo VER (por TROL_MENU
    -- o recortado por TUSUARIO_ROL_PERMISO), no ve nada de la cascada.
    IF NOT academico_test.fn_usuario_puede_en_menu(p_pk_usuario, 'PERIODOS_ACADEMICOS', 'VER') THEN
        RETURN FALSE;
    END IF;

    IF v_nivel = 1 THEN
        -- Territorial: todos los EE.
        RETURN TRUE;
    ELSIF v_nivel = 2 THEN
        v_est := academico_test.fn_periodo_establecimiento(p_fk_periodo);
        RETURN v_est IS NOT NULL AND v_est IN (
            SELECT establecimiento_id
              FROM academico_test.fn_usuario_ee_accesibles(p_pk_usuario)
        );
    ELSIF v_nivel = 3 THEN
        -- Nivel sede+jornada (coordinador/docente/etc.): exige AMBAS
        -- coordenadas del periodo, igual que el scope de escritura.
        RETURN (academico_test.fn_periodo_sede(p_fk_periodo), academico_test.fn_periodo_jornada(p_fk_periodo))
               IN (
                   SELECT sj.sede_id, sj.jornada_id
                     FROM academico_test.fn_usuario_sedes_jornadas_accesibles(p_pk_usuario) sj
               );
    END IF;

    -- Nivel 4 (estudiantes/familia) o sin categoria: fail-closed.
    RETURN FALSE;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_puede_ver(BIGINT, BIGINT)
    IS 'Version BOOLEAN (no lanza) del gate de LECTURA de la cascada academica de Periodo Academico, para el WHERE de listados/reportes: capability ''VER'' sobre el menu PERIODOS_ACADEMICOS (fn_usuario_puede_en_menu) + scope por categoria de rol del periodo indicado (nivel 1 territorial = todos los EE; nivel 2 = EE del periodo en fn_usuario_ee_accesibles; nivel 3 = par (sede, jornada) del periodo en fn_usuario_sedes_jornadas_accesibles). p_pk_usuario NULL o SUPER_ADMIN (nivel 0) => TRUE. Reemplaza a fn_periodo_usuario_puede_ver (que NO revisaba capability, solo scope por rol) en los listados/obtener del modulo Periodo Academico.';
