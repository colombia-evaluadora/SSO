-- ===========================================================================
-- V277 — ALCANCE TERRITORIAL EN LAS ESCRITURAS DEL PLANEADOR.
--
-- ---------------------------------------------------------------------------
-- 1. EL AGUJERO
--
-- fn_assert_permiso_seccion aplica DOS cosas: capability (que el rol pueda
-- hacer la accion en el menu) y alcance territorial (que el objeto este en un
-- establecimiento/sede que el usuario alcanza). Pero el alcance solo se evalua
-- si el caller le pasa el objetivo:
--
--     IF p_fk_establecimiento IS NOT NULL OR p_fk_tsede IS NOT NULL THEN ...
--
-- Las funciones del Planeador lo llamaban con tres argumentos
-- (usuario, 'PLANEADOR', accion), asi que ese IF nunca entraba: 69 funciones
-- con capability y CERO con alcance.
--
-- Verificado explotandolo en el servidor de test: un docente cuyo unico
-- establecimiento es el 877 creo, via POST /planeador/actividades, una
-- actividad en el grupo 10332, que pertenece al establecimiento 528. Respuesta
-- 200. La actividad de prueba quedo inactivada.
--
-- ---------------------------------------------------------------------------
-- 2. POR QUE ESTA MIGRACION RECREA DOS FUNCIONES QUE YA EXISTEN
--
-- fn_planeador_assert_alcance y fn_planeador_alcanza YA estaban en la base del
-- servidor de test, y bien escritas. Pero NO estan en las migraciones de
-- ninguna rama: se buscaron en el repo y en todas las de origin. Sus COMMENT
-- dicen "V202" y esa migracion no existe en ningun sitio. Es decir, se
-- aplicaron a mano contra la base y nunca se commitearon: en el proximo
-- despliegue limpio desaparecen, y con ellas el alcance del importar/exportar,
-- que hoy son las dos unicas funciones que las usan.
--
-- Se recuperan aqui TAL CUAL estaban (misma logica, mismos mensajes) para que
-- el repositorio vuelva a ser la fuente de verdad. Lo unico que se les agrega
-- es el parametro del punto 3.
--
-- ---------------------------------------------------------------------------
-- 3. EL PARAMETRO NUEVO: p_pk_tactividad
--
-- El helper original resuelve el objetivo por grupo, grado o unidad. Pero la
-- mayoria de las escrituras del Planeador no reciben ninguno de los tres:
-- reciben la ACTIVIDAD (editar, eliminar, definir instrumento, vincular...).
-- Sin este parametro cada una tendria que repetir el mismo subselect a
-- TACTIVIDAD antes de llamar, que es justo la duplicacion que el helper
-- existe para evitar.
--
-- Va al final y con DEFAULT NULL, asi que las llamadas actuales de
-- fn_actividad_importar / fn_actividad_exportar siguen resolviendo igual.
--
-- La actividad aporta grupo Y unidad, y se dejan competir con lo que venga por
-- parametro: el COALESCE ya prefiere el grupo, que es lo mas especifico. Una
-- actividad huerfana sin grupo no resuelve nada por si sola, y entonces manda
-- la rama "sin objetivo" de abajo, que es el comportamiento correcto -- no hay
-- sede contra la que comparar.
--
-- ---------------------------------------------------------------------------
-- 4. DONDE ESTA EL CABLEADO
--
-- Esta migracion solo define el helper. Las 32 funciones de escritura se
-- editaron EN SITIO, en la migracion donde cada una vive, cambiando
--
--     PERFORM fn_assert_permiso_seccion(usuario, 'PLANEADOR', accion);
-- por
--     PERFORM fn_planeador_assert_alcance(usuario, accion, <objetivo>);
--
--   V214.1  enunciados de unidad, criterios y evidencias de actividad (6)
--   V216  unidad crear / actualizar / eliminar, criterio agregar (4)
--   V222  rubrica de unidad: asegurar, criterio actualizar / eliminar (3)
--   V223  desvincular actividad, ponderacion inline (2)
--   V224  actividad crear / actualizar / eliminar (3)
--   V226  instrumentos rubrica / cotejo / escala (3)
--   V227  las 7 funciones de calificacion (4 individuales + 3 bulk)
--   V240  instrumento "otro" (1)
--   V243  observar grupal y por estudiante (2)
--   V244  vincular actividad a unidad (1)
--
-- Las que reciben p_pk_tactividad_estudiante resuelven la actividad con
-- fn_actividad_estudiante_actividad, que ya existia; las que reciben el PK de
-- una relacion (criterio de rubrica, enunciado de unidad, evidencia de
-- actividad) lo resuelven con un subselect en el propio argumento.
--
-- fn_actividad_nota_calificar (la fachada de V243) NO se cablea y no es un
-- olvido: no tiene gate propio, delega en las cuatro funciones por instrumento
-- y queda cubierta por ellas.
--
-- ORDEN DE EJECUCION: estas migraciones son ANTERIORES a V277, asi que en un
-- despliegue limpio crean funciones que llaman a un helper que todavia no
-- existe. No es un problema -- PL/pgSQL resuelve las llamadas en tiempo de
-- ejecucion, no al crear la funcion -- y es el mismo patron ya documentado en
-- V220/V227 para las dependencias entre ramas.
--
-- DEPENDENCIA ENTRE RAMAS: fn_assert_permiso_seccion, fn_usuario_ee_accesibles
-- y fn_usuario_categoria_rol_nivel viven en la rama de permisos
-- (CU-86e2w4xdt, PR #100), no aqui. No es una dependencia NUEVA: el Planeador
-- entero ya llamaba a fn_assert_permiso_seccion desde V216. Lo que cambia es
-- que ahora se usa tambien su rama de alcance, que antes quedaba muerta por
-- llamarla con tres argumentos.
--
-- ---------------------------------------------------------------------------
-- 5. DRIFT QUE QUEDA PENDIENTE Y NO SE TOCA AQUI
--
-- Al buscar de donde salian estos helpers aparecio que el import/export
-- completo del Planeador tambien es drift: fn_actividad_importar,
-- fn_actividad_exportar y sus dos endpoints existen en la base del servidor de
-- test pero NO en las migraciones de ninguna rama. Son la unica escritura que
-- sigue llamando al gate pelado, aunque comprueban alcance fila por fila con
-- fn_planeador_alcanza, asi que no quedan desprotegidas.
--
-- No se recuperan aqui porque son una funcionalidad entera de otro autor y
-- reconstruirla desde la base seria adivinar su intencion. Queda reportado.
--
-- ---------------------------------------------------------------------------
-- 6. LAS LECTURAS
--
-- Tambien quedan acotadas. El criterio NO se inventa aqui: ya estaba definido
-- en el sistema de rol/menu, y se aplica tal cual via fn_usuario_sedes_lectura
--
--     nivel 0 (super admin) y 1 (territoriales)  todas las sedes
--     nivel 2 (administrativos establecimiento)  las de sus EE accesibles
--     nivel 3 (administrativos sedes, DOCENTE)   las suyas
--     nivel 4 (estudiantes / familia)            ninguna
--
-- Un docente es nivel 3, asi que ve lo de SUS sedes -- ni solo lo suyo ni todo
-- el establecimiento. Eso ya estaba decidido; aqui solo se conecta.
--
-- Dos patrones distintos, porque el problema no es el mismo:
--
--   a) DETALLE de un objeto (18 funciones: buscar_por_pk, campos_disponibles,
--      objetivos, contenidos, criterios, referente, valoraciones, nota,
--      instrumento, configuracion...). Se resuelve igual que las escrituras,
--      cambiando el gate por fn_planeador_assert_alcance con el objeto pedido:
--      pedir algo fuera de alcance da 403.
--
--   b) LISTADOS (fn_unidad_listar, fn_actividad_listar,
--      fn_actividad_huerfanas_listar). Aqui no vale un 403: hay que FILTRAR
--      filas. Se resuelven las sedes del usuario UNA vez por llamada, en un
--      array, y cada fila se compara contra el -- no una funcion por fila.
--
-- DOS REGLAS QUE SE CRUZAN, Y NO SON LA MISMA:
--
--   * ALCANCE: nivel 0/1 no se filtran por sede (v_alcance_total).
--   * BORRADO LOGICO: una sede ACTIVE = FALSE se oculta a TODOS, tambien al
--     super admin. Por eso el ACTIVE de TSEDE va en el JOIN, que aplica
--     siempre, y v_alcance_total solo exime del ANY(v_sedes_lectura).
--
-- Confundirlas fue un error real durante la implementacion: al principio el
-- bypass de nivel 0/1 se puso sobre todo el predicado, y eso les habria
-- mostrado unidades de sedes dadas de baja.
--
-- ACTIVIDAD SIN ANCLA: una actividad sin grupo y sin unidad no esta en ninguna
-- sede, asi que no hay alcance que aplicarle. La ven su autor (CREATED_BY, que
-- es VARCHAR: columna de auditoria de texto libre, de ahi el cast) y los
-- niveles 0/1. En cuanto se le asigna grupo o unidad pasa a filtrarse como
-- todas.
--
-- LO QUE FALTA. Quedan sin acotar los listados restantes -- calendario,
-- resumen de estados, planilla, disponibles/candidatas y los selects del
-- docente. Los que son "del docente" (fn_actividad_listar_docente,
-- fn_actividad_calendario_docente, fn_docente_grupos_listar) ya se atan al
-- funcionario autenticado, asi que no filtran de mas; los demas siguen
-- abiertos y son el siguiente paso.
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- fn_planeador_assert_alcance — capability + alcance territorial.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_planeador_assert_alcance(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_planeador_assert_alcance(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_planeador_assert_alcance(
    p_pk_usuario_solicitante BIGINT,
    p_accion                 VARCHAR,
    p_fk_tgrupo              BIGINT DEFAULT NULL,
    p_fk_tgrado              BIGINT DEFAULT NULL,
    p_fk_tunidad             BIGINT DEFAULT NULL,
    p_pk_tactividad          BIGINT DEFAULT NULL,
    p_permitir_sin_ancla     BOOLEAN DEFAULT FALSE
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
    v_nivel   INT;
    v_ee      BIGINT;
    v_sede    BIGINT;
    v_jornada BIGINT;
    v_grado   BIGINT;
    v_grupo   BIGINT := p_fk_tgrupo;
    v_unidad  BIGINT := p_fk_tunidad;
BEGIN
    -- Si viene la actividad, aporta su grupo y su unidad. No pisa lo que ya
    -- venga por parametro: el caller que manda un grupo explicito esta
    -- diciendo a donde va a quedar el objeto, que puede no ser donde esta hoy.
    IF p_pk_tactividad IS NOT NULL THEN
        SELECT COALESCE(v_grupo, a.FK_TGRUPO), COALESCE(v_unidad, a.FK_TUNIDAD)
          INTO v_grupo, v_unidad
          FROM academico_test.TACTIVIDAD a
         WHERE a.PK_TACTIVIDAD = p_pk_tactividad;
    END IF;

    -- El grado sale del grupo, de la unidad, o llega directo. Se prefiere el
    -- grupo por ser el mas especifico de los tres.
    v_grado := COALESCE(
        (SELECT gr.FK_TGRADO FROM academico_test.TGRUPO gr
          WHERE gr.PK_TGRUPO = v_grupo AND gr.ACTIVE),
        (SELECT u.FK_TGRADO FROM academico_test.TUNIDAD u
          WHERE u.PK_TUNIDAD = v_unidad AND u.ACTIVE),
        p_fk_tgrado
    );

    SELECT s.FK_TESTABLECIMIENTO, s.PK_TSEDE, pa.FK_TLV_JORNADA
      INTO v_ee, v_sede, v_jornada
      FROM academico_test.TGRADO g
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s
        ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE g.PK_TGRADO = v_grado;

    IF v_sede IS NULL THEN
        -- Sin objetivo no hay alcance que comprobar: solo capability.
        PERFORM academico_test.fn_assert_permiso_seccion(
            p_pk_usuario_solicitante, 'PLANEADOR', p_accion);

        -- p_permitir_sin_ancla: hay UN caso legitimo de objeto sin ancla
        -- territorial, la actividad huerfana (se crea sin grupo y sin unidad,
        -- para vincularla despues). No se le puede comprobar alcance porque no
        -- esta en ninguna sede todavia, y exigir nivel 0/1 romperia el flujo:
        -- un docente dejaria de poder crearlas. Es seguro dejarla pasar con
        -- solo capability porque una actividad sin ancla no esta en el
        -- establecimiento de nadie, y las dos operaciones que luego la anclan
        -- -- vincularla a una unidad y editarle el grupo -- SI comprueban
        -- alcance. La bandera va en FALSE por defecto a proposito: quien la
        -- active tiene que poder justificar por que su objeto puede existir
        -- sin sede.
        IF p_permitir_sin_ancla THEN
            RETURN;
        END IF;

        v_nivel := academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante);
        IF v_nivel IS DISTINCT FROM 0 AND v_nivel IS DISTINCT FROM 1 THEN
            RAISE EXCEPTION 'No se pudo determinar la sede de la actividad, asi que no se '
                            'puede verificar el alcance del usuario'
                USING ERRCODE = '42501',
                      HINT    = 'Indique grupo, grado o unidad, y verifique que el grado tenga '
                             || 'periodo academico y sede';
        END IF;
        RETURN;
    END IF;

    -- Con objetivo: capability + alcance en una sola llamada, la misma que usa
    -- el resto del sistema.
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', p_accion, v_ee, v_sede, v_jornada);
END;
$fn$;

COMMENT ON FUNCTION academico_test.fn_planeador_assert_alcance(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BOOLEAN)
    IS 'Capability + ALCANCE para el planeador. Resuelve el establecimiento, la sede y la jornada del objetivo por la cadena actividad/grupo/unidad -> grado -> periodo academico -> sede, y se los pasa a fn_assert_permiso_seccion, que ya sabe aplicar el modelo dinamico (nivel 1 todos los EE, nivel 2 por fn_usuario_ee_accesibles, nivel 3 por sede+jornada). Existe porque las funciones del planeador llamaban a ese assert con tres argumentos, y en esa forma el bloque de alcance no se ejecuta: quedaba solo la capability. p_pk_tactividad (V277) se agrego porque la mayoria de las escrituras reciben la actividad y no el grupo/grado/unidad; aporta el grupo y la unidad de la actividad SIN pisar los que lleguen por parametro, porque un caller que manda grupo explicito esta declarando a donde va a quedar el objeto, que puede no ser donde esta hoy. Si no se puede resolver una sede (actividad huerfana sin grupo, grado sin periodo) se exige capability y, para todo el que no sea nivel 0 o 1, se rechaza con 42501 en vez de dejar pasar. p_permitir_sin_ancla (FALSE por defecto) cubre el unico objeto legitimamente sin sede, la actividad huerfana: sin el un docente no podria crearlas, y dejarla pasar es seguro porque una actividad sin ancla no esta en el establecimiento de nadie y las dos operaciones que luego la anclan (vincular a unidad, editarle el grupo) si comprueban alcance. Recuperada al repositorio en V277: existia solo en la base del servidor, aplicada a mano y sin commitear en ninguna rama.';

-- ---------------------------------------------------------------------------
-- fn_planeador_alcanza — la misma comprobacion, en forma de BOOLEAN.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_planeador_alcanza(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_planeador_alcanza(
    p_pk_usuario_solicitante BIGINT,
    p_accion                 VARCHAR,
    p_fk_tgrupo              BIGINT DEFAULT NULL,
    p_fk_tgrado              BIGINT DEFAULT NULL,
    p_fk_tunidad             BIGINT DEFAULT NULL,
    p_pk_tactividad          BIGINT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
AS $fn$
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, p_accion, p_fk_tgrupo, p_fk_tgrado, p_fk_tunidad, p_pk_tactividad);
    RETURN TRUE;
EXCEPTION
    WHEN insufficient_privilege THEN   -- 42501
        RETURN FALSE;
END;
$fn$;

COMMENT ON FUNCTION academico_test.fn_planeador_alcanza(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT)
    IS 'Version BOOLEAN de fn_planeador_assert_alcance, para quien decide sin levantar: el importar reporta fila por fila y el exportar distingue "no existe" de "no alcanzas". Envuelve al assert y atrapa el 42501 en vez de reimplementar el modelo de alcance, para que las dos formas no puedan divergir. Cualquier otro error se propaga. Recuperada al repositorio en V277.';
