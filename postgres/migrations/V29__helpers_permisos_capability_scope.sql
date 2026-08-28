-- ===========================================================================
-- V29 — Helpers de autorizacion: capability (menu) + scope (EE / sede+
-- jornada) + rango de rol (categoria). Piezas base del modelo descrito en
-- docs/gate-permisos-por-menu-analysis.md (§3.1 a §3.6).
--
-- CU-86e2w4xdt — Permisos segun rol.
--
-- QUE HACE
--   Crea 9 funciones nuevas y NO modifica ninguna existente. Son los
--   ladrillos que consumen los gates de establecimiento / sedes /
--   funcionarios / periodos academicos.
--
-- POR QUE ESTE NUMERO TAN BAJO (V29)
--   Los gates de esas secciones NO se reescriben en migraciones nuevas: se
--   EDITAN IN-PLACE las migraciones originales (V37 periodos, V40
--   fn_periodo_gate_escritura, V50 utilities, V51 funcionarios, V52 sedes,
--   V53 establecimiento, V72, V100, V101, V111). Para que esas ediciones
--   puedan llamar a estos helpers sin una referencia "hacia adelante" en el
--   historial de Flyway, los helpers tienen que estar DEFINIDOS ANTES que
--   todas ellas. V29 es un hueco libre del historial, posterior a V22 (que
--   crea el esquema academico_test y las tablas TROL, TSEDE_USUARIO, TMENU,
--   TROL_MENU, TESTABLECIMIENTO, TSEDE, TLISTA_VALOR) y anterior a V37, la
--   primera que los usa.
--
-- POR QUE TODAS SON `LANGUAGE plpgsql` Y NINGUNA `LANGUAGE sql`  <-- CLAVE
--   En el punto V29 del historial varias dependencias TODAVIA NO EXISTEN:
--     * academico_test.fn_usuario_permisos_menu        -> se crea en V185
--     * academico_test.TROL_MENU.SOLO_LECTURA          -> se añade en V99
--     * academico_test.TROL.FK_TLISTA_VALOR_CATEGORIA  -> se añade en V120
--     * las filas TLISTA_VALOR con CATEGORIA='CATEGORIA_ROL'
--       (SUPER_ADMIN / ADMINISTRATIVOS_TERRITORIALES /
--        ADMINISTRATIVOS_ESTABLECIMIENTO / ADMINISTRATIVOS_SEDES /
--        ESTUDIANTES_FAMILIA)                          -> se siembran en V120
--   PostgreSQL VALIDA EL CUERPO de las funciones `LANGUAGE sql` al crearlas
--   (resuelve tablas, columnas y funciones referenciadas), asi que un helper
--   `sql` que mencione cualquiera de esas cosas HARIA FALLAR EL CREATE aqui
--   en V29. Los cuerpos `plpgsql`, en cambio, solo se comprueban
--   sintacticamente al crear y resuelven nombres en tiempo de EJECUCION —
--   que es cuando ya existe todo (post-V185). De ahi que hasta las que
--   devuelven un escalar o una tabla, y que naturalmente serian `sql`, esten
--   escritas como plpgsql (RETURN / RETURN QUERY). Todas siguen siendo
--   STABLE.
--
--   NOTA DE RENDIMIENTO derivada de lo anterior: fn_usuario_ee_accesibles en
--   plpgsql ya NO puede inline-arse dentro de un `IN (SELECT ...)`; se
--   evalua como una llamada por invocacion. Es aceptable en el uso previsto
--   (una vez por request, dentro de un assert), pero si algun LISTADO acaba
--   llamandola POR FILA hay que revisarlo (materializarla en un CTE/array al
--   inicio de la funcion que lista).
--
-- POR QUE ESTOS HELPERS
--   Hoy cada funcion CRUD autoriza con allowlists de numeros de rol
--   (FK_TROL IN (1,2,3), IN (1,2,3,7,8,9), ...) copiadas inline en cada
--   cuerpo (ver el bloque "0. Gate" de fn_fun_permisos_actualizar, V51
--   ~L1260). Eso: (a) ignora por completo la configuracion de menus
--   (TROL_MENU / TUSUARIO_ROL_PERMISO) que el super admin administra, y
--   (b) no es reutilizable ni auditable. Estos helpers concentran las tres
--   decisiones en un solo lugar.
--
-- MODELO DE 3 CAPAS
--   1. CAPABILITY — ¿que acciones (crear/editar/eliminar/ver) puede hacer
--      este usuario en esta seccion? DINAMICA: sale de
--      fn_usuario_permisos_menu (V185), es decir TROL_MENU concede (techo
--      del rol, via SOLO_LECTURA de V99) y TUSUARIO_ROL_PERMISO recorta
--      (restriccion del usuario, escrita por V199). Nunca amplia.
--      -> fn_usuario_puede_en_menu.
--   2. SCOPE — ¿sobre QUE establecimiento / sede / jornada puede actuar?
--      FIJA Y ESTRUCTURAL: se deriva de la categoria del rol y de las
--      filas TSEDE_USUARIO + los punteros TESTABLECIMIENTO.
--      FK_TFUNCIONARIO_RECTOR / FK_TFUNCIONARIO_SECRETARIA.
--      -> fn_usuario_ee_accesibles, fn_usuario_sedes_jornadas_accesibles.
--   3. RANGO DE ROL — un usuario no puede ver ni afectar a funcionarios de
--      su MISMA categoria de rol o superior, ni otorgar un rol de
--      categoria igual o superior a la propia.
--      -> fn_assert_rango_rol, fn_assert_rango_rol_otorgable.
--
-- NIVELES DE CATEGORIA (TROL.FK_TLISTA_VALOR_CATEGORIA -> TLISTA_VALOR
-- CATEGORIA='CATEGORIA_ROL', columna y seed de V120). 0 = mas alto:
--
--   nivel | VALOR de TLISTA_VALOR              | roles de hoy | scope
--   ------+------------------------------------+--------------+---------------------
--     0   | SUPER_ADMIN                        | 1            | bypass total
--     1   | ADMINISTRATIVOS_TERRITORIALES      | 2,3,4,5,6    | TODOS los EE
--     2   | ADMINISTRATIVOS_ESTABLECIMIENTO    | 7,8,9        | su(s) EE
--     3   | ADMINISTRATIVOS_SEDES              | 10..14       | su(s) (sede, jornada)
--     4   | ESTUDIANTES_FAMILIA                | 15,16        | n/a en estas secciones
--
-- POR QUE NO SE HARDCODEAN pk_trol
--   Los numeros de rol de la tabla de arriba son SOLO documentacion: la
--   unica fuente de verdad de la logica es la CATEGORIA del rol. Si mañana
--   se crea un rol 17 y el super admin lo clasifica como
--   ADMINISTRATIVOS_SEDES, hereda el scope de sede+jornada sin tocar una
--   sola linea de SQL. Ademas, el mapeo se resuelve por el TEXTO de
--   TLISTA_VALOR.VALOR y NO por el pk_lista_valor literal (51951/51953/
--   51949/51952/51950 en el servidor de test) porque esos pk varian por
--   ambiente — mismo criterio que V185/V198 al resolver el microservicio
--   por serviceid='eval-col' en vez de por id numerico.
--
-- ROL SIN CATEGORIA (FK_TLISTA_VALOR_CATEGORIA NULL)
--   DECISION: se trata como nivel 4 (el MAS BAJO). Fail-closed: un rol sin
--   clasificar no gana scope ni alcanza a nadie por rango; en cambio, si se
--   tratara como NULL "desconocido" propagaria NULLs a las comparaciones y
--   las volveria permisivas por accidente. Un rol nuevo sin categoria
--   asignada por el super admin queda inofensivo hasta que la reciba.
--   (Antes de V120 la columna FK_TLISTA_VALOR_CATEGORIA ni siquiera existe;
--   por eso estas funciones solo son INVOCABLES a partir de V120/V185 —
--   definirlas antes es seguro, ejecutarlas antes no.)
--
-- ERRORES
--   Todos los asserts lanzan SQLSTATE '42501' (-> HTTP 403 via
--   PostgresErrorMapper), con MENSAJES DISTINTOS para poder diferenciar
--   "no puedes esta accion" (capability) de "no alcanzas este objeto"
--   (scope) de "ese funcionario/rol es de tu rango o superior" (rango).
--   Los mensajes nombran al funcionario o al rol de forma legible, no solo
--   por su PK.
--
-- IDEMPOTENCIA
--   Solo CREATE OR REPLACE FUNCTION + COMMENT ON FUNCTION; ninguna firma
--   cambia respecto a algo ya existente (las 9 son nuevas), asi que no hace
--   falta DROP previo. Reaplicar el archivo N veces es un no-op.
--
-- NOTA plpgsql (bug real de V199): en fn_fun_filtros_permiso_listar un OUT
--   param fk_tsede choco con un SELECT FK_TSEDE de un subquery del gate
--   copiado. Aqui TODAS las columnas de subqueries van con alias de tabla.
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
CREATE OR REPLACE FUNCTION academico_test.fn_usuario_categoria_rol_nivel(
    p_pk_tusuario  BIGINT
)
RETURNS INT
LANGUAGE plpgsql
STABLE
AS $$
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
$$;

COMMENT ON FUNCTION academico_test.fn_usuario_categoria_rol_nivel(BIGINT)
    IS 'Nivel jerarquico (0 = mas alto) de la categoria de rol MAS ALTA que tiene el usuario entre sus TSEDE_USUARIO ACTIVE (multi-rol -> MIN del nivel). Devuelve NULL si el usuario no tiene ningun rol activo. Mismo criterio "solo ACTIVE" que fn_usuario_permisos_menu (V185), sin filtrar ademas por TLV_ESTADO. 0 = SUPER_ADMIN (bypass), 1 = territorial (todos los EE), 2 = establecimiento, 3 = sedes (sede+jornada), 4 = estudiantes/familia.';

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
         WHERE pm.codigo = p_codigo_menu
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
    IS 'TRUE si el usuario puede ejecutar p_accion (''CREAR''|''EDITAR''|''ELIMINAR''|''VER'', comparada con UPPER(TRIM(...)), case-insensitive) sobre el TMENU de codigo p_codigo_menu. Envuelve fn_usuario_permisos_menu (V185), asi que hereda gratis la semantica "TROL_MENU concede (techo del rol) / TUSUARIO_ROL_PERMISO recorta (restriccion del usuario)". DECISION: una accion desconocida o NULL devuelve FALSE (fail-closed) en vez de lanzar 22023 — el caller de estos helpers es siempre codigo del repo con literales fijos, y un FALSE se traduce en el 42501 normal de capability en fn_assert_permiso_seccion; asi ningun typo abre acceso. Si el menu no esta concedido por ningun rol activo del usuario, tambien FALSE. Requiere fn_usuario_permisos_menu (V185) en tiempo de ejecucion: por eso es plpgsql y no sql (V29 es anterior a V185).';

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

        RAISE EXCEPTION 'El usuario no tiene alcance sobre el establecimiento, sede o jornada objetivo'
            USING ERRCODE = '42501';
    END IF;

    -- Accion sin objeto (p.ej. crear un EE): la capability ya alcanzo.
    RETURN;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_assert_permiso_seccion(BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT)
    IS 'Assertion de autorizacion para las funciones CRUD de establecimiento / sedes / funcionarios / periodos academicos: PERFORM al inicio del cuerpo. Orden: (0) bypass si fn_usuario_categoria_rol_nivel = 0 (SUPER_ADMIN); (1) capability -- fn_usuario_puede_en_menu(u, menu, accion) debe ser TRUE, si no 42501 nombrando accion y modulo; (2) scope, SOLO si p_fk_establecimiento o p_fk_tsede no son NULL: nivel 1 (territorial) alcanza todos los EE; si no, el EE objetivo (p_fk_establecimiento, o el FK_TESTABLECIMIENTO de p_fk_tsede) debe estar en fn_usuario_ee_accesibles; si no, el par (p_fk_tsede, p_fk_tlv_jornada) debe estar en fn_usuario_sedes_jornadas_accesibles; si nada aplica, 42501 con un mensaje DISTINTO al de capability. Si todos los p_fk_* son NULL (accion sin objeto, p.ej. crear un EE) la capability basta. NO valida existencia ni estado de los objetos (eso lo hace el caller); si p_fk_tsede no resuelve a un EE, el paso por establecimiento se salta y solo el par sede+jornada puede autorizar. Es de solo lectura: llamarla N veces es equivalente a llamarla una.';

-- ---------------------------------------------------------------------------
-- 7) fn_assert_rango_rol — no ver ni afectar a iguales o superiores.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_assert_rango_rol(
    p_pk_solicitante           BIGINT,
    p_pk_funcionario_objetivo  BIGINT
)
RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_nivel_solicitante  INT;
    v_nivel_objetivo     INT;
    v_nombre_objetivo    TEXT;
BEGIN
    v_nivel_solicitante := academico_test.fn_usuario_categoria_rol_nivel(p_pk_solicitante);

    -- SUPER_ADMIN: sin rango que lo limite.
    IF v_nivel_solicitante = 0 THEN
        RETURN;
    END IF;

    SELECT MIN(academico_test.fn_rol_categoria_nivel(su.FK_TROL))
      INTO v_nivel_objetivo
      FROM academico_test.TFUNCIONARIO f
      JOIN academico_test.TSEDE_USUARIO su
        ON su.FK_TUSUARIO = f.FK_TUSUARIO
       AND su.ACTIVE = TRUE
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario_objetivo;

    -- El objetivo no tiene roles activos: no hay rango que proteger.
    IF v_nivel_objetivo IS NULL THEN
        RETURN;
    END IF;

    -- Solicitante sin rol activo (NULL): la comparacion nunca autoriza.
    IF v_nivel_solicitante IS NULL OR v_nivel_solicitante >= v_nivel_objetivo THEN
        SELECT TRIM(COALESCE(u.PRIMER_NOMBRE, '') || ' ' || COALESCE(u.PRIMER_APELLIDO, ''))
          INTO v_nombre_objetivo
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
         WHERE f.PK_TFUNCIONARIO = p_pk_funcionario_objetivo;

        RAISE EXCEPTION 'El funcionario "%" tiene un rol de categoria igual o superior a la del usuario; no se puede consultar ni afectar',
            COALESCE(NULLIF(v_nombre_objetivo, ''), 'objetivo')
            USING ERRCODE = '42501';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_assert_rango_rol(BIGINT, BIGINT)
    IS 'Assertion de RANGO DE ROL (capa 3): un usuario no puede ver ni afectar a funcionarios cuya categoria de rol sea la MISMA o SUPERIOR a la suya. nivel_objetivo = MIN(fn_rol_categoria_nivel) de los TSEDE_USUARIO ACTIVE del funcionario objetivo (via su FK_TUSUARIO); si fn_usuario_categoria_rol_nivel(solicitante) >= nivel_objetivo -> 42501 nombrando al funcionario. Un solicitante de nivel 0 (SUPER_ADMIN) pasa siempre. DECISION: si el objetivo no tiene ningun rol activo, nivel_objetivo es NULL y la funcion PASA -- no hay rango que proteger (un funcionario sin rol no es "superior" a nadie); el alcance sobre el sigue gobernado por el scope de EE. Un solicitante sin rol activo (nivel NULL) nunca pasa.';

-- ---------------------------------------------------------------------------
-- 8) fn_assert_rango_rol_otorgable — no otorgar iguales ni superiores.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_assert_rango_rol_otorgable(
    p_pk_solicitante  BIGINT,
    p_pk_trol         BIGINT
)
RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_nivel_solicitante  INT;
    v_nivel_rol          INT;
    v_nombre_rol         TEXT;
BEGIN
    v_nivel_solicitante := academico_test.fn_usuario_categoria_rol_nivel(p_pk_solicitante);

    IF v_nivel_solicitante = 0 THEN
        RETURN;
    END IF;

    v_nivel_rol := academico_test.fn_rol_categoria_nivel(p_pk_trol);

    IF v_nivel_solicitante IS NULL OR v_nivel_solicitante >= v_nivel_rol THEN
        SELECT r.NOMBRE INTO v_nombre_rol
          FROM academico_test.TROL r
         WHERE r.PK_TROL = p_pk_trol;

        RAISE EXCEPTION 'El rol "%" es de categoria igual o superior a la del usuario; no se puede otorgar',
            COALESCE(NULLIF(TRIM(COALESCE(v_nombre_rol, '')), ''), p_pk_trol::TEXT)
            USING ERRCODE = '42501';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_assert_rango_rol_otorgable(BIGINT, BIGINT)
    IS 'Assertion de RANGO al OTORGAR un rol: nadie puede asignar a otro un rol cuya categoria sea igual o superior a la propia. Si fn_usuario_categoria_rol_nivel(solicitante) >= fn_rol_categoria_nivel(p_pk_trol) -> 42501 nombrando el rol (TROL.NOMBRE, no solo el pk). Un solicitante de nivel 0 (SUPER_ADMIN) puede otorgar cualquier rol; uno sin rol activo (nivel NULL) no puede otorgar ninguno. Pensada para fn_sede_usuario_crear / fn_fun_permisos_actualizar. Ejemplo: un Rector (nivel 2) no puede otorgar Rector ni Jefe de Sistema territorial (nivel 1), pero si Coordinador (nivel 3).';

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
    IS 'Assertion de autorizacion del modulo FUNCIONARIOS: combina las 3 capas. (1) capability -- delega en fn_assert_permiso_seccion(u, ''FUNCIONARIOS'', accion) sin objeto, lo que tambien resuelve el bypass del SUPER_ADMIN (nivel 0). (2) scope -- si p_pk_funcionario_objetivo no es NULL y el solicitante no es de nivel 1 (territorial, alcanza a cualquiera), el funcionario objetivo debe ser rector/secretaria de un EE de fn_usuario_ee_accesibles(u) o tener un TSEDE_USUARIO ACTIVE en una sede ACTIVE de uno de esos EE; si no, 42501 nombrando al funcionario. (3) rango -- PERFORM fn_assert_rango_rol(u, objetivo): no se alcanza a funcionarios de categoria igual o superior. p_pk_funcionario_objetivo NULL (p.ej. ''CREAR'') solo exige capability: el EE se valida al vincular. Los tres 42501 llevan mensajes distintos.';
