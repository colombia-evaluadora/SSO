-- =============================================================================
-- V202 -- Alcance por permisos dinamicos para el planeador.
--
-- Dos funciones:
--   fn_planeador_assert_alcance  -- capability + alcance, levanta 42501
--   fn_planeador_alcanza         -- solo el alcance, como BOOLEAN
--
-- Numero bajo y en un hueco libre (202-211 estaban sin usar y sin registrar en
-- flyway_schema_history) para poder llamarlas desde las migraciones del
-- planeador, que van en el rango alto.
--
-- -----------------------------------------------------------------------------
-- El problema que resuelve
-- -----------------------------------------------------------------------------
-- fn_assert_permiso_seccion YA implementa el modelo dinamico completo: nivel 0
-- pasa, nivel 1 (territoriales) alcanza todos los EE, nivel 2 va por
-- fn_usuario_ee_accesibles y nivel 3 por fn_usuario_sedes_jornadas_accesibles
-- con sede Y jornada. Pero el alcance solo se evalua si se le pasa el objetivo:
--
--   IF p_fk_establecimiento IS NOT NULL OR p_fk_tsede IS NOT NULL THEN
--
-- Y NINGUNA de las 91 funciones del planeador se lo pasa: todas lo llaman con
-- (usuario, 'PLANEADOR', accion) y nada mas. Es decir, el modulo comprueba
-- capability y no alcance.
--
-- Medido, no supuesto: un docente (nivel 3, EE propio 745, EE accesibles = 0,
-- una sola sede accesible) importo una actividad en el EE 877 y exporto las de
-- ese EE. Ni la lectura ni la escritura lo impidieron.
--
-- No ha explotado porque la interfaz manda siempre la asignatura y el grupo del
-- contexto del usuario -- la UI acota y la API no.
--
-- -----------------------------------------------------------------------------
-- Que arregla esta migracion y que NO
-- -----------------------------------------------------------------------------
-- Aqui solo viven las dos funciones. Las usan fn_actividad_exportar (V272) y
-- fn_actividad_importar (V274), que son las que reciben PKs arbitrarias del
-- cliente en lote y por tanto las mas expuestas.
--
-- Las otras 89 funciones del planeador siguen igual: fn_actividad_crear,
-- fn_actividad_actualizar, fn_actividad_eliminar, fn_unidad_crear y las
-- lecturas del modulo no acotan. Queda como deuda conocida del modulo, no
-- resuelta aqui.
--
-- -----------------------------------------------------------------------------
-- Como se resuelve el objetivo
-- -----------------------------------------------------------------------------
-- La cadena da todo lo que el modelo necesita:
--
--   TACTIVIDAD -> TGRUPO -> TGRADO -> TPERIODO_ACADEMICO -> TSEDE
--
-- y TPERIODO_ACADEMICO tiene FK_TSEDE y FK_TLV_JORNADA. Asi que se le puede
-- pasar establecimiento + sede + jornada y el paso 2.c autoriza bien a los
-- docentes, que son los usuarios principales del planeador. No hay reglas
-- nuevas: solo se le entrega el objetivo que ya sabe usar.
--
-- Se acepta grupo, grado o unidad porque no todas las llamadas tienen lo mismo
-- a mano: una actividad tiene grupo (FK_TGRUPO es nullable, hoy 0 de 18 activas
-- lo tienen nulo), una unidad tiene grado, y el importar puede traer solo el
-- pkTunidad en _identificadores. Se prefiere el grupo, que es el mas especifico.
--
-- -----------------------------------------------------------------------------
-- Por que el BOOLEAN envuelve al assert y no repite la regla
-- -----------------------------------------------------------------------------
-- Hacen falta las dos formas: el importar reporta fila por fila (necesita
-- preguntar sin levantar) y el exportar necesita distinguir "no existe" de "no
-- alcanzas". La tentacion es escribir el BOOLEAN mirando el nivel y los helpers
-- de alcance por su cuenta, pero eso serian DOS copias de la misma regla, y dos
-- copias divergen -- es el fallo que este archivo existe para evitar, no para
-- reproducir.
--
-- Asi que fn_planeador_alcanza llama al mismo assert y atrapa el 42501. Control
-- de flujo por excepcion, si, pero con una sola definicion de la regla: el dia
-- que el modelo de alcance cambie, las dos formas cambian juntas.
--
-- -----------------------------------------------------------------------------
-- p_pk_tactividad, y por que hay un DROP antes
-- -----------------------------------------------------------------------------
-- Las dos funciones aceptan la PK de una actividad y de ahi sacan su grupo y su
-- unidad, en vez de obligar a quien llama a resolverlos. Le sirve al exportador,
-- que itera sobre PKs de actividad y antes tenia que hacer dos subconsultas
-- correlacionadas por fila para lo mismo.
--
-- No pisa lo que llegue por parametro: quien manda un grupo explicito esta
-- diciendo A DONDE VA A QUEDAR el objeto, que puede no ser donde esta hoy. Eso
-- importa para el importar, cuyo destino es el grupo recibido y no el de origen.
--
-- El DROP de las firmas de CINCO parametros no es adorno. Una version anterior
-- de esta migracion las creaba sin p_pk_tactividad, y CREATE OR REPLACE con una
-- firma distinta NO reemplaza: crea una SOBRECARGA. Con las dos vivas, cualquier
-- llamada que pase NULLs sin castear queda ambigua y Postgres responde 42725
-- ("function is not unique"). Es la misma trampa que ya costo un dia con
-- fn_usu_empleados_listar.
--
-- Idempotente: los DROP llevan IF EXISTS y las funciones CREATE OR REPLACE.
-- =============================================================================


-- Se van las firmas de cinco parametros, si quedaron de una version anterior.
DROP FUNCTION IF EXISTS academico_test.fn_planeador_alcanza(
    BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_planeador_assert_alcance(
    BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT);


-- -----------------------------------------------------------------------------
-- fn_planeador_assert_alcance
-- -----------------------------------------------------------------------------
-- Comprueba capability Y alcance sobre el objetivo. Levanta 42501 si falla
-- cualquiera de los dos, con el mensaje que ya usa el resto del sistema.
--
-- Si el objetivo no resuelve a una sede -- porque no se paso ninguno de los tres
-- identificadores, o porque la cadena esta incompleta -- se comprueba solo la
-- capability y despues se RECHAZA a todo el que no sea de nivel 0 o 1. No se
-- deja pasar "por si acaso": una actividad cuya sede no se puede determinar es
-- exactamente el caso en el que no se puede saber si el usuario la alcanza, y
-- ahi lo seguro es negar. Nivel 0 y 1 alcanzan cualquier EE de todas formas, asi
-- que para ellos la sede no cambia nada.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_planeador_assert_alcance(
    p_pk_usuario_solicitante BIGINT,
    p_accion                 VARCHAR,
    p_fk_tgrupo              BIGINT DEFAULT NULL,
    p_fk_tgrado              BIGINT DEFAULT NULL,
    p_fk_tunidad             BIGINT DEFAULT NULL,
    p_pk_tactividad          BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $function$
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
$function$;

COMMENT ON FUNCTION academico_test.fn_planeador_assert_alcance(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT)
    IS 'Capability + ALCANCE para el planeador. Resuelve el establecimiento, la sede y la jornada del objetivo por la cadena grupo/unidad -> grado -> periodo academico -> sede, aceptando tambien la PK de una actividad y sacando de ella el grupo y la unidad (sin pisar lo que llegue explicito, porque un grupo explicito dice a donde VA a quedar el objeto y no donde esta hoy), y se los pasa a fn_assert_permiso_seccion, que ya sabe aplicar el modelo dinamico (nivel 1 todos los EE, nivel 2 por fn_usuario_ee_accesibles, nivel 3 por sede+jornada). Existe porque las 91 funciones del planeador llaman a ese assert SIN objetivo, asi que comprueban capability y no alcance: se midio que un docente de nivel 3 podia importar y exportar en un establecimiento ajeno. Si el objetivo no resuelve a una sede, rechaza a todo el que no sea nivel 0 o 1. V202.';


-- -----------------------------------------------------------------------------
-- fn_planeador_alcanza
-- -----------------------------------------------------------------------------
-- La misma pregunta, en forma de BOOLEAN, para quien tiene que decidir sin
-- levantar: el importar la usa para reportar fila por fila y el exportar para
-- distinguir "no existe" de "no alcanzas".
--
-- Envuelve al assert y atrapa el 42501 en vez de repetir la regla -- ver la
-- cabecera. FALSE significa "capability o alcance insuficiente"; cualquier otro
-- error se propaga, porque un fallo inesperado no es un "no".
-- -----------------------------------------------------------------------------
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
AS $function$
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, p_accion, p_fk_tgrupo, p_fk_tgrado, p_fk_tunidad,
        p_pk_tactividad);
    RETURN TRUE;
EXCEPTION
    WHEN insufficient_privilege THEN   -- 42501
        RETURN FALSE;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_planeador_alcanza(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT)
    IS 'Version BOOLEAN de fn_planeador_assert_alcance, para quien decide sin levantar: el importar reporta fila por fila y el exportar distingue "no existe" de "no alcanzas". Envuelve al assert y atrapa el 42501 en vez de reimplementar el modelo de alcance, para que las dos formas no puedan divergir. Cualquier otro error se propaga. V202.';
