-- ===========================================================================
-- V339 - fn_periodo_evaluacion_listar_ano: los periodos de evaluacion de un
--        ano lectivo, para poblar los checkboxes de la vista de informes.
--
-- POR QUE UNA FUNCION NUEVA SI YA HAY fn_periodo_eval_listar
--   Aquella (V-anteriores) lista los periodos de UN periodo academico
--   concreto: recibe p_fk_periodo y de ahi no se mueve. Sirve para la
--   pantalla de configuracion, donde ya se esta parado en un periodo
--   academico.
--
--   Aca la pregunta es otra: "que periodos hay este ano". El usuario abre
--   informes y todavia no eligio grupo, asi que no hay periodo academico del
--   cual partir -- y cuando lo elija, el periodo academico sale del grupo, no
--   al reves. Ademas los periodos academicos son POR SEDE Y JORNADA: un ano
--   con 21 periodos de evaluacion repartidos en 9 sedes no se puede consultar
--   con una funcion que pide uno solo.
--
--
-- EL ANO ES UN NUMERO, NO UNA FK
--   TANO_LECTIVO.NOMBRE guarda el ano ('2026') y la tabla es POR
--   ESTABLECIMIENTO: 2025 tiene 47 filas para 47 EE distintos, 2026 tiene 16.
--   No existe "el ano lectivo 2026" como registro unico.
--
--   Por eso se recibe el ano como INTEGER y no una FK: pedir un
--   PK_ANO_LECTIVO obligaria al front a resolver primero cual de las 16 filas
--   de 2026 le toca, que es justo lo que esta funcion deberia ahorrarle.
--
--   Si no se indica ano se toma el de HOY, que es lo que pasara al abrir la
--   pantalla.
--
--
-- EL ALCANCE LO PONE EL USUARIO, NO UN PARAMETRO
--   Se devuelven solo los periodos de establecimientos que el usuario alcanza
--   (fn_usuario_ee_accesibles). No hace falta que el front mande el
--   establecimiento: ya esta implicito en quien pregunta, y dejarlo como
--   parametro abriria la puerta a pedir uno ajeno y descubrirlo por la
--   respuesta vacia.
--
--   p_fk_testablecimiento existe solo para ACOTAR cuando el usuario alcanza
--   varios -- un administrativo territorial, por ejemplo -- y nunca para
--   ampliar: si pide uno que no alcanza, no recibe nada.
--
--
-- QUE DEVUELVE DE MAS
--   TERMINO y EN_CURSO, calculados contra CURRENT_DATE. El primero es
--   exactamente la condicion que usa la alerta roja (V338) para decidir si
--   una planilla puede considerarse pendiente, asi que devolverlo evita que
--   el front reimplemente esa regla con otro criterio.
--
--   La sede viaja porque dos periodos pueden llamarse igual -- "Primer
--   periodo" -- en sedes distintas del mismo EE, y sin ella la lista de
--   checkboxes tendria duplicados indistinguibles.
--
-- Idempotente: CREATE OR REPLACE. Funcion nueva, sin sobrecarga previa.
-- ===========================================================================


CREATE OR REPLACE FUNCTION academico_test.fn_periodo_evaluacion_listar_ano(
    p_pk_usuario_solicitante BIGINT,
    p_anio                   INTEGER DEFAULT NULL,
    p_fk_testablecimiento    BIGINT  DEFAULT NULL,
    p_fk_tsede               BIGINT  DEFAULT NULL
)
RETURNS TABLE(
    fk_tperiodo_evaluacion  BIGINT,
    codigo                  VARCHAR,
    nombre                  VARCHAR,
    abreviacion             VARCHAR,
    fecha_inicio            DATE,
    fecha_fin               DATE,
    porcentaje              NUMERIC,
    estado                  VARCHAR,
    calificable             BOOLEAN,
    termino                 BOOLEAN,
    en_curso                BOOLEAN,
    fk_tperiodo_academico   BIGINT,
    fk_tsede                BIGINT,
    sede_nombre             VARCHAR,
    fk_tlv_jornada          BIGINT,
    jornada                 VARCHAR,
    fk_testablecimiento     BIGINT,
    fk_tano_lectivo         BIGINT,
    anio                    INTEGER
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_anio  INTEGER;
    v_nivel INT;
BEGIN
    -- Capability sin alcance: la lista de periodos no es de un objeto
    -- concreto, y el alcance lo aplica el filtro de establecimientos de mas
    -- abajo. Pedir scope aqui obligaria a elegir un EE antes de saber cuales
    -- hay, que es circular.
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER'
    );

    v_anio := COALESCE(p_anio, EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER);

    -- fn_usuario_ee_accesibles NO trae bypass para los niveles altos: a un
    -- SUPER_ADMIN (0) le devuelve CERO establecimientos, igual que a un
    -- ADMINISTRATIVO_TERRITORIAL (1), aunque ambos alcanzan todo. Es la misma
    -- asimetria que fn_assert_permiso_seccion resuelve por fuera, en sus
    -- pasos 0 y 2.a. Filtrar sin replicarla dejaria a esos dos perfiles
    -- viendo una lista VACIA -- y vacia se lee como "no hay periodos", no
    -- como "no tienes permiso", que es el peor tipo de error: silencioso.
    v_nivel := academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante);

    RETURN QUERY
    SELECT pe.PK_TPERIODO_EVALUACION,
           pe.CODIGO,
           pe.NOMBRE,
           pe.ABREVIACION,
           pe.FECHA_INICIO,
           pe.FECHA_FIN,
           pe.PORCENTAJE,
           est.NOMBRE,
           -- El catalogo ESTADOPERIODOEVALUACION usa VALOR '1' para
           -- "Calificable". Se devuelve resuelto para que el front no tenga
           -- que conocer el codigo.
           (est.VALOR = '1'),
           (pe.FECHA_FIN < CURRENT_DATE),
           (CURRENT_DATE BETWEEN pe.FECHA_INICIO AND pe.FECHA_FIN),
           pa.PK_TPERIODO_ACADEMICO,
           s.PK_TSEDE,
           s.NOMBRE,
           pa.FK_TLV_JORNADA,
           jor.NOMBRE,
           s.FK_TESTABLECIMIENTO,
           al.PK_ANO_LECTIVO,
           v_anio
      FROM academico_test.TPERIODO_EVALUACION pe
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = pe.FK_TPERIODO_ACADEMICO
       AND pa.ACTIVE = TRUE
      JOIN academico_test.TANO_LECTIVO al
        ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
       AND al.ACTIVE = TRUE
       -- NOMBRE es VARCHAR y puede traer cualquier cosa: se compara solo
       -- cuando es un ano bien formado, para que un registro sucio no tumbe
       -- la consulta con 22P02.
       AND al.NOMBRE ~ '^[0-9]{4}$'
       AND al.NOMBRE::INTEGER = v_anio
      JOIN academico_test.TSEDE s
        ON s.PK_TSEDE = pa.FK_TSEDE
       AND s.ACTIVE = TRUE
      LEFT JOIN academico_test.TLISTA_VALOR est
             ON est.PK_LISTA_VALOR = pe.FK_TLV_ESTADO
      LEFT JOIN academico_test.TLISTA_VALOR jor
             ON jor.PK_LISTA_VALOR = pa.FK_TLV_JORNADA
     WHERE pe.ACTIVE = TRUE
       -- Alcance: solo lo que el usuario puede ver. Niveles 0 y 1 alcanzan
       -- todo -- ver el comentario de v_nivel arriba.
       AND (v_nivel <= 1
            OR EXISTS (
                 SELECT 1
                   FROM academico_test.fn_usuario_ee_accesibles(p_pk_usuario_solicitante) ee
                  WHERE ee.establecimiento_id = s.FK_TESTABLECIMIENTO
               ))
       -- Los dos parametros solo ACOTAN; nunca amplian.
       AND (p_fk_testablecimiento IS NULL
            OR s.FK_TESTABLECIMIENTO = p_fk_testablecimiento)
       AND (p_fk_tsede IS NULL OR s.PK_TSEDE = p_fk_tsede)
     ORDER BY s.NOMBRE, jor.NOMBRE NULLS FIRST, pe.FECHA_INICIO, pe.NOMBRE;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_periodo_evaluacion_listar_ano(BIGINT, INTEGER, BIGINT, BIGINT)
    IS 'Los periodos de evaluacion de un ano lectivo, para poblar los checkboxes de la vista de informes ("1. Primer periodo", "2. Segundo periodo"...). Existe aparte de fn_periodo_eval_listar porque aquella lista los de UN periodo academico concreto -- util en configuracion, donde ya se esta parado en uno -- y aqui la pregunta es "que periodos hay este ano": el usuario abre informes sin haber elegido grupo todavia, y cuando lo elija el periodo academico saldra del grupo, no al reves; ademas los periodos academicos son POR SEDE Y JORNADA, asi que un ano con 21 periodos repartidos en 9 sedes no se puede consultar con una funcion que pide uno solo. EL ANO SE RECIBE COMO NUMERO Y NO COMO FK porque TANO_LECTIVO es por establecimiento y no existe "el ano lectivo 2026" como registro unico: 2025 tiene 47 filas para 47 EE, 2026 tiene 16; pedir un PK obligaria al front a resolver primero cual le toca, que es justo lo que esta funcion le ahorra. Sin p_anio se toma el ano de hoy, que es lo que pasara al abrir la pantalla. La comparacion del ano valida el formato con una expresion regular antes de castear, para que un TANO_LECTIVO.NOMBRE sucio no tumbe la consulta con 22P02. EL ALCANCE LO PONE QUIEN PREGUNTA: se devuelven solo periodos de establecimientos que el usuario alcanza (fn_usuario_ee_accesibles), sin que el front tenga que mandarlo; p_fk_testablecimiento y p_fk_tsede existen solo para ACOTAR cuando alcanza varios, y nunca para ampliar. Devuelve TERMINO y EN_CURSO calculados contra CURRENT_DATE: TERMINO es exactamente la condicion que usa la alerta roja (V338) para decidir si una planilla puede considerarse pendiente, asi que devolverlo evita que el front reimplemente esa regla con otro criterio. La sede y la jornada viajan porque dos periodos pueden llamarse igual en sedes distintas del mismo EE y sin ellas la lista tendria duplicados indistinguibles. Gate: INFORMES/VER como capability, sin alcance de objeto -- pedir scope aqui obligaria a elegir un EE antes de saber cuales hay, que es circular.';
