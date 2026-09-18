-- ===========================================================================
-- V418 - Los periodos de evaluacion salen de UN periodo academico, no del año.
--
--   fn_informe_periodo_academico_resolver  la tripleta -> el periodo
--   fn_informe_periodos_evaluacion_listar  los periodos de ese periodo
--   POST /informes/periodos                cambia de contrato
--   fn_periodo_evaluacion_listar_ano       se elimina (V339)
--
--
-- QUE CAMBIA
--   Hasta ahora /informes/periodos devolvia los periodos de evaluacion de
--   TODO el año dentro del alcance de quien preguntaba: todas las sedes y
--   todas las jornadas juntas. De ahi venia la queja -- a un usuario con
--   alcance amplio le salian muchos, y la mitad con el mismo nombre.
--
--   Ahora recibe la tripleta que eligen los tres selects de V417 (sede, año,
--   jornada), resuelve con ella el periodo academico y devuelve unicamente
--   los periodos de evaluacion de ESE periodo.
--
--
-- POR QUE UNA FUNCION NUEVA Y NO UN PARAMETRO MAS
--   Porque no es la misma pregunta con un filtro extra: cambia la unidad de
--   respuesta. La anterior respondia "que periodos de evaluacion hay este
--   año" -- una lista heterogenea, donde cada fila tenia que cargar su sede y
--   su jornada para poder distinguirse. Esta responde "cuales son los
--   periodos de ESTE periodo academico", que es una lista homogenea y
--   ordenable, la que el usuario realmente quiere marcar.
--
--   fn_periodo_evaluacion_listar_ano (V339) se elimina en vez de quedar como
--   variante: no la llama ninguna otra funcion del esquema y su unico
--   endpoint es el que aqui se reapunta, asi que dejarla seria codigo muerto
--   con un nombre lo bastante razonable como para que alguien lo reutilice
--   sin darse cuenta de que trae todas las sedes.
--
--
-- LA TRIPLETA Y EL CASO AMBIGUO
--   Entre sedes y establecimientos activos, (sede, año, jornada) identifica
--   hoy un solo periodo academico -- medido. Pero ningun indice lo garantiza:
--   el unico unico de TPERIODO_ACADEMICO es (FK_TANO_LECTIVO, FK_TSEDE,
--   NOMBRE) WHERE active, y la jornada no entra. En el historico hay 24
--   tripletas con dos o mas periodos, todas en sedes ya inactivas y varias de
--   colegios por CICLOS ("2015" y "2015BH CICLO VI", misma sede y jornada).
--
--   Si vuelve a pasar, el resolvedor toma el de FECHA_INICIO mas reciente y
--   desempata por PK. No falla: un informe no puede quedar inaccesible
--   porque alguien creo dos periodos el mismo año. Y el front tiene la
--   salida limpia -- fn_informe_jornadas_listar (V417) devuelve una fila por
--   periodo academico con su PK, asi que puede ofrecer los dos y mandar el
--   que el usuario elija en vez de la tripleta.
--
--
-- EL GATE AHORA SI LLEVA ALCANCE
--   V339 solo podia pedir la capability INFORMES/VER: no sabia de que sede
--   hablaba hasta despues de consultar. Aqui la sede y la jornada llegan como
--   parametro, asi que se pasan a fn_assert_permiso_seccion y la funcion
--   responde 42501 ANTES de leer nada. Es mas estricto que antes, y es lo
--   correcto: pedir los periodos de una sede ajena debe ser un error, no una
--   lista vacia que se confunde con "no hay nada configurado".
--
-- Idempotente: CREATE OR REPLACE para lo nuevo, DROP IF EXISTS para lo que se
-- elimina y UPDATE para el endpoint, que conserva ruta y metodo.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. La tripleta -> el periodo academico.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_periodo_academico_resolver(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tsede               BIGINT,
    p_anio                   INTEGER,
    p_fk_tlv_jornada         BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_anio    INTEGER;
    v_periodo BIGINT;
BEGIN
    IF p_fk_tsede IS NULL OR p_fk_tlv_jornada IS NULL THEN
        RAISE EXCEPTION 'Faltan la sede o la jornada para resolver el periodo academico'
            USING ERRCODE = '22023',
                  HINT    = 'La pantalla de informes resuelve el periodo con sede, año y jornada -- ver fn_informe_jornadas_listar';
    END IF;

    -- Alcance ANTES de leer: la sede y la jornada ya llegaron, asi que pedir
    -- una ajena es 42501 y no una lista vacia que se lea como "no hay nada".
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER',
        NULL, p_fk_tsede, p_fk_tlv_jornada
    );

    v_anio := COALESCE(p_anio, EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER);

    SELECT pa.PK_TPERIODO_ACADEMICO
      INTO v_periodo
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TANO_LECTIVO al
        ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
       AND al.ACTIVE = TRUE
       AND academico_test.fn_anio_lectivo_numero(al.NOMBRE) = v_anio
      JOIN academico_test.TSEDE s
        ON s.PK_TSEDE = pa.FK_TSEDE
       AND s.ACTIVE = TRUE
     WHERE pa.ACTIVE = TRUE
       AND pa.FK_TSEDE = p_fk_tsede
       AND pa.FK_TLV_JORNADA = p_fk_tlv_jornada
     -- Desempate para el caso que hoy no ocurre entre sedes activas pero que
     -- nada impide: el mas reciente, y el PK como ultimo criterio para que la
     -- respuesta sea siempre la misma. Ver la cabecera.
     ORDER BY pa.FECHA_INICIO DESC NULLS LAST, pa.PK_TPERIODO_ACADEMICO DESC
     LIMIT 1;

    IF v_periodo IS NULL THEN
        RAISE EXCEPTION 'No hay un periodo academico activo para esa sede, jornada y año (%)', v_anio
            USING ERRCODE = 'P0002',
                  HINT    = 'Verifique que la sede tenga un periodo academico configurado para esa jornada en ese año';
    END IF;

    RETURN v_periodo;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_periodo_academico_resolver(BIGINT, BIGINT, INTEGER, BIGINT)
    IS 'El periodo academico que corresponde a (sede, año, jornada), que es lo que eligen los tres selects de la pantalla de informes (V417). Levanta P0002 si no hay ninguno y 42501 si el usuario no alcanza esa sede y jornada -- el alcance se valida ANTES de leer, con fn_assert_permiso_seccion, para que pedir una sede ajena sea un error y no una lista vacia que se confunde con "no hay nada configurado". Entre sedes y establecimientos activos la tripleta identifica hoy un solo periodo, medido, pero ningun indice lo garantiza: el unico unico de TPERIODO_ACADEMICO es (FK_TANO_LECTIVO, FK_TSEDE, NOMBRE) WHERE active y la jornada no entra, y en el historico hay 24 tripletas con dos o mas periodos, todas en sedes inactivas y varias de colegios por CICLOS. Si reaparece, se devuelve el de FECHA_INICIO mas reciente desempatando por PK, en vez de fallar: un informe no puede quedar inaccesible porque alguien creo dos periodos el mismo año. El front tiene la salida limpia -- fn_informe_jornadas_listar devuelve una fila por periodo con su PK. V418.';


-- ---------------------------------------------------------------------------
-- 2. Los periodos de evaluacion de ese periodo academico.
--
--    Mismas columnas que devolvia fn_periodo_evaluacion_listar_ano, para que
--    el front solo cambie lo que manda y no lo que lee. Se conservan la sede
--    y la jornada aunque ahora sean siempre las mismas: cuestan nada y
--    permiten al front rotular la pestaña sin arrastrar lo que eligio.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_periodos_evaluacion_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tsede               BIGINT,
    p_anio                   INTEGER,
    p_fk_tlv_jornada         BIGINT
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
    periodo_academico       VARCHAR,
    fk_tsede                BIGINT,
    sede_nombre             VARCHAR,
    fk_tlv_jornada          BIGINT,
    jornada                 VARCHAR,
    fk_testablecimiento     BIGINT,
    anio                    INTEGER
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_periodo BIGINT;
BEGIN
    -- El resolvedor ya valida el alcance y levanta P0002 si no existe.
    v_periodo := academico_test.fn_informe_periodo_academico_resolver(
        p_pk_usuario_solicitante, p_fk_tsede, p_anio, p_fk_tlv_jornada);

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
           pa.NOMBRE,
           s.PK_TSEDE,
           s.NOMBRE,
           pa.FK_TLV_JORNADA,
           jor.NOMBRE,
           s.FK_TESTABLECIMIENTO,
           academico_test.fn_anio_lectivo_numero(al.NOMBRE)
      FROM academico_test.TPERIODO_EVALUACION pe
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = pe.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TANO_LECTIVO al
        ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
      JOIN academico_test.TSEDE s
        ON s.PK_TSEDE = pa.FK_TSEDE
      LEFT JOIN academico_test.TLISTA_VALOR est
             ON est.PK_LISTA_VALOR = pe.FK_TLV_ESTADO
      LEFT JOIN academico_test.TLISTA_VALOR jor
             ON jor.PK_LISTA_VALOR = pa.FK_TLV_JORNADA
     WHERE pe.ACTIVE = TRUE
       AND pe.FK_TPERIODO_ACADEMICO = v_periodo
     ORDER BY pe.FECHA_INICIO, pe.NOMBRE;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_periodos_evaluacion_listar(BIGINT, BIGINT, INTEGER, BIGINT)
    IS 'Los periodos de evaluacion del periodo academico que resuelven (sede, año, jornada) -- los checkboxes de la pantalla de informes. Sustituye a fn_periodo_evaluacion_listar_ano (V339), que devolvia los de TODO el año dentro del alcance del usuario: todas las sedes y jornadas juntas, de donde venia que a un usuario con alcance amplio le salieran muchos y la mitad con el mismo nombre. No es la misma pregunta con un filtro mas: cambia la unidad de respuesta, de una lista heterogenea donde cada fila cargaba su sede para poder distinguirse, a una lista homogenea y ordenable. El alcance y la existencia del periodo los valida fn_informe_periodo_academico_resolver, que responde 42501 o P0002 antes de leer. Devuelve TERMINO y EN_CURSO calculados contra CURRENT_DATE: TERMINO es exactamente la condicion que usa la alerta roja (V338) para decidir si una planilla puede considerarse pendiente, asi que devolverlo evita que el front reimplemente esa regla con otro criterio. Conserva las columnas de la funcion anterior -- sede, jornada, establecimiento -- aunque ahora sean siempre las mismas, para que el front cambie lo que manda y no lo que lee. V418.';


-- ---------------------------------------------------------------------------
-- 3. Fuera la anterior. No la llama ninguna funcion del esquema y su unico
--    endpoint es el que se reapunta abajo.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_periodo_evaluacion_listar_ano(BIGINT, INTEGER, BIGINT, BIGINT);


-- ---------------------------------------------------------------------------
-- 4. El endpoint conserva ruta y metodo, cambia el cuerpo.
--
--    Se ACTUALIZA en vez de crear otro: es la misma pregunta de la misma
--    pantalla, y dejar la ruta vieja funcionando "como antes" solo sirve para
--    que alguien siga pidiendo la lista de todas las sedes sin enterarse.
--    Los permisos ya concedidos sobre esta fila (V342) se conservan.
-- ---------------------------------------------------------------------------
UPDATE public.query q
   SET query = 'SELECT * FROM academico_test.fn_informe_periodos_evaluacion_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TSEDE AS BIGINT),
    CAST(:BODY.ANIO AS INTEGER),
    CAST(:BODY.FK_TLV_JORNADA AS BIGINT)
);',
       param_types = '{"BODY.FK_TSEDE": "BIGINT", "BODY.ANIO": "INTEGER", "BODY.FK_TLV_JORNADA": "BIGINT"}'::jsonb,
       detail = 'Los periodos de evaluacion del periodo academico que resuelven la sede, el año y la jornada elegidos en los tres selects de la pantalla (POST /informes/sedes, /informes/anos, /informes/jornadas). Antes devolvia los de todo el año dentro del alcance del usuario -- todas las sedes y jornadas juntas --, que es de donde venia que a un usuario con alcance amplio le salieran muchos y repetidos. FK_TSEDE y FK_TLV_JORNADA son obligatorios; sin ANIO se toma el año en curso. Responde 42501 si el usuario no alcanza esa sede y jornada, y P0002 si no hay periodo academico para esa combinacion -- un error explicito en vez de una lista vacia que se confunde con "no hay nada configurado". Cada fila trae CALIFICABLE, TERMINO y EN_CURSO ya resueltos; TERMINO es la misma condicion con la que la alerta roja decide si una planilla esta pendiente.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/informes/periodos'
   AND q.http_method     = 'POST';
