-- ===========================================================================
-- V417 - La cascada de selects de informes: sede -> año -> jornada.
--
--   fn_informe_alcanza_sede_jornada  el alcance, en un solo sitio
--   fn_informe_sedes_listar          primer select
--   fn_informe_anos_listar           segundo select
--   fn_informe_jornadas_listar       tercer select
--   POST /informes/sedes  /informes/anos  /informes/jornadas
--
--
-- DE DONDE SALE ESTO
--   La pantalla de informes listaba los periodos de evaluacion de TODO el
--   año dentro del alcance del usuario: todas las sedes y todas las jornadas
--   a la vez. Medido en el servidor de test, un usuario con alcance total ve
--   8 periodos de evaluacion repartidos en 5 sedes de 3 establecimientos,
--   con solo 4 nombres distintos -- media lista son "Primer periodo"
--   repetidos, indistinguibles salvo por la sede que viaja en la fila.
--
--   El diseño nuevo antepone tres selects. Elegida la sede, el año y la
--   jornada queda determinado un solo periodo academico, y de ahi cuelgan
--   los periodos de evaluacion (V418) y los grupos (V419).
--
--
-- POR QUE FUNCIONES PROPIAS Y NO LAS QUE YA EXISTEN
--   Existen listados parecidos -- fn_periodo_sedes_listar,
--   fn_periodo_jornadas_listar, fn_periodo_anos_lectivos_listar -- pero son
--   del modulo de periodos academicos, que alimenta sus propias pantallas y
--   es de otro dueño. Reutilizarlos ataria esta vista a decisiones que no
--   controlamos, y ademas ninguno encaja del todo:
--
--     fn_periodo_anos_lectivos_listar tiene clavado
--       al.NOMBRE = to_char(CURRENT_DATE,'YYYY')
--     asi que solo devuelve el año en curso y no puede alimentar un select
--     de año.
--
--     fn_periodo_jornadas_listar agrupa por NOMBRE y devuelve MIN(pk). Hoy
--     no hace daño -- el catalogo JORNADA tiene 6 nombres y 6 PK -- pero es
--     un contrato que no queremos heredar para resolver un periodo.
--
--   El otro motivo es el que hizo falta arreglar: la vista venia usando
--   GET /planeador/docentes/grupos, cuya funcion asserta PLANEADOR/VER. Un
--   usuario con permiso de INFORMES y sin PLANEADOR no podia abrir la
--   pantalla. Endpoints propios con gate propio evitan repetir eso.
--
--
-- EL ALCANCE VIVE EN UNA SOLA FUNCION
--   fn_informe_alcanza_sede_jornada replica, para filtrar listas, exactamente
--   las cuatro reglas que fn_assert_permiso_seccion aplica para autorizar:
--
--     nivel 0 (super admin)          todo
--     nivel 1 (adm. territorial)     todo
--     nivel 2 (+ rector/secretaria)  por establecimiento
--     nivel 3 (adm. de sede)         por (sede, jornada)
--
--   Se replican en vez de llamarse porque aquella LEVANTA EXCEPCION y aqui
--   hace falta un booleano: un select no puede fallar por cada sede que el
--   usuario no alcanza, tiene que no mostrarla. Y se escriben una sola vez
--   porque las tres listas -- y las dos migraciones siguientes -- necesitan
--   el mismo criterio; en cuatro copias, el dia que cambie quedarian tres
--   versiones distintas.
--
--   La consecuencia practica: un rol de nivel 3 con una sola jornada ve su
--   sede en el primer select y UNA sola opcion en el tercero, en vez de ver
--   jornadas que luego le responderian 403.
--
--
-- EL AÑO: EL EN CURSO Y LOS ANTERIORES
--   Nunca los futuros. En el servidor ya hay periodos academicos creados
--   para 2027, 2028 y 2029: son configuracion adelantada, no años sobre los
--   que tenga sentido pedir informes. Los anteriores si se ofrecen -- un
--   boletin de un año cerrado es una consulta legitima.
--
--   El año se compara como numero y validando el formato antes de castear
--   (TANO_LECTIVO.NOMBRE es VARCHAR y guarda '2026'), para que un registro
--   sucio no tumbe la consulta con 22P02.
--
-- Idempotente: CREATE OR REPLACE, funciones nuevas sin sobrecarga previa, e
-- INSERT ... ON CONFLICT DO NOTHING para los endpoints y los permisos.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 0. El año lectivo como numero, sin poder reventar.
--
--    TANO_LECTIVO.NOMBRE es VARCHAR y guarda '2026'. Lo natural seria
--    escribir "NOMBRE ~ '^[0-9]{4}$' AND NOMBRE::INTEGER = x", pero las dos
--    condiciones viven en la misma calificacion y el planificador puede
--    evaluar el cast ANTES del guard: una fila sucia tumba la consulta
--    entera con 22P02. Ya paso en este esquema.
--
--    Dentro de un CASE el orden si esta garantizado, y una fila sucia sale
--    como NULL -- que en cualquier comparacion posterior es simplemente una
--    fila que no entra.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_anio_lectivo_numero(
    p_nombre VARCHAR
)
RETURNS INTEGER
LANGUAGE sql
IMMUTABLE
AS $function$
    SELECT CASE WHEN p_nombre ~ '^[0-9]{4}$' THEN p_nombre::INTEGER END;
$function$;

COMMENT ON FUNCTION academico_test.fn_anio_lectivo_numero(VARCHAR)
    IS 'TANO_LECTIVO.NOMBRE como numero, o NULL si no es un año de cuatro digitos. Existe porque escribir el guard y el cast como dos condiciones de la misma calificacion ("NOMBRE ~ ... AND NOMBRE::INTEGER = x") no garantiza el orden de evaluacion: el planificador puede hacer el cast primero y una sola fila sucia tumba la consulta con 22P02, cosa que ya paso en este esquema. Dentro de un CASE el orden si esta garantizado y la fila sucia sale como NULL, que en cualquier comparacion es simplemente una fila que no entra. IMMUTABLE para que se pueda usar en indices y el planificador la pliegue. V417.';


-- ---------------------------------------------------------------------------
-- 1. El alcance, en un solo sitio.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_alcanza_sede_jornada(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tsede               BIGINT,
    p_fk_tlv_jornada         BIGINT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $function$
    SELECT
        -- niveles 0 y 1 alcanzan todo. Ojo: fn_usuario_ee_accesibles les
        -- devuelve CERO establecimientos, asi que sin esta rama verian las
        -- listas VACIAS -- y vacia se lee como "no hay nada configurado", no
        -- como "no tienes permiso", que es el peor error: el silencioso.
        academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante) <= 1
        -- nivel 2: todo lo que cuelgue de un establecimiento suyo.
        OR EXISTS (
            SELECT 1
              FROM academico_test.TSEDE s
              JOIN academico_test.fn_usuario_ee_accesibles(p_pk_usuario_solicitante) ee
                ON ee.establecimiento_id = s.FK_TESTABLECIMIENTO
             WHERE s.PK_TSEDE = p_fk_tsede
        )
        -- nivel 3: su sede Y su jornada. Sin jornada concreta basta con que
        -- tenga alguna en esa sede -- es la pregunta del primer select, donde
        -- la jornada todavia no se eligio.
        OR EXISTS (
            SELECT 1
              FROM academico_test.fn_usuario_sedes_jornadas_accesibles(p_pk_usuario_solicitante) sj
             WHERE sj.sede_id = p_fk_tsede
               AND (p_fk_tlv_jornada IS NULL OR sj.jornada_id = p_fk_tlv_jornada)
        );
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_alcanza_sede_jornada(BIGINT, BIGINT, BIGINT)
    IS 'TRUE si ese usuario alcanza esa sede (y esa jornada, cuando se indica). Replica como BOOLEANO las cuatro reglas de scope que fn_assert_permiso_seccion aplica levantando excepcion: nivel 0 y 1 alcanzan todo, nivel 2 por establecimiento (fn_usuario_ee_accesibles), nivel 3 por (sede, jornada) (fn_usuario_sedes_jornadas_accesibles). Se replican y no se llama a aquella porque un select no puede fallar por cada sede que el usuario no alcanza: tiene que no mostrarla. Sin jornada concreta basta con tener alguna en la sede, que es la pregunta del primer select. La usan las tres listas de la cascada de informes (V417) y los listados de periodos de evaluacion y grupos (V418, V419), para que el criterio no quede escrito cuatro veces. V417.';


-- ---------------------------------------------------------------------------
-- 2. Primer select: las sedes.
--
--    Solo sedes que tengan al menos un periodo academico activo del año en
--    curso o anterior: una sede sin periodos no da informes, y ofrecerla
--    solo lleva a un segundo select vacio.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_sedes_listar(
    p_pk_usuario_solicitante BIGINT
)
RETURNS TABLE(
    fk_tsede               BIGINT,
    sede_nombre            VARCHAR,
    fk_testablecimiento    BIGINT,
    establecimiento_nombre VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $function$
BEGIN
    -- Capability sin alcance: la lista no es de un objeto concreto, y el
    -- alcance lo pone el filtro de abajo. Pedir scope aqui obligaria a
    -- elegir una sede antes de saber cuales hay, que es circular.
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER'
    );

    RETURN QUERY
    SELECT DISTINCT
           s.PK_TSEDE,
           s.NOMBRE,
           e.PK_ESTABLECIMIENTO,
           e.NOMBRE
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s
        ON s.PK_TSEDE = pa.FK_TSEDE
       AND s.ACTIVE = TRUE
      JOIN academico_test.TESTABLECIMIENTO e
        ON e.PK_ESTABLECIMIENTO = s.FK_TESTABLECIMIENTO
       AND e.ACTIVE = TRUE
      JOIN academico_test.TANO_LECTIVO al
        ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
       AND al.ACTIVE = TRUE
       AND academico_test.fn_anio_lectivo_numero(al.NOMBRE)
           <= EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
     WHERE pa.ACTIVE = TRUE
       AND academico_test.fn_informe_alcanza_sede_jornada(
               p_pk_usuario_solicitante, s.PK_TSEDE, pa.FK_TLV_JORNADA)
     ORDER BY e.NOMBRE, s.NOMBRE;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_sedes_listar(BIGINT)
    IS 'Primer select de la pantalla de informes: las sedes que el usuario alcanza y que tienen al menos un periodo academico activo del año en curso o anterior -- una sede sin periodos no da informes y ofrecerla solo lleva a un segundo select vacio. Viaja el establecimiento porque dos sedes de EE distintos pueden llamarse parecido y quien alcanza varios necesita distinguirlas. Gate: INFORMES/VER como capability, sin alcance de objeto (pedir scope aqui obligaria a elegir una sede antes de saber cuales hay); el alcance lo aplica fn_informe_alcanza_sede_jornada. Existe en vez de reutilizar fn_periodo_sedes_listar porque aquella es del modulo de periodos academicos, con su propia nocion de visibilidad, y porque el endpoint propio evita que esta pantalla dependa del permiso de otro menu -- que es justo lo que pasaba con GET /planeador/docentes/grupos. V417.';


-- ---------------------------------------------------------------------------
-- 3. Segundo select: los años.
--
--    El en curso y los anteriores, nunca los futuros: en el servidor ya hay
--    periodos academicos creados para 2027, 2028 y 2029 y son configuracion
--    adelantada, no años sobre los que pedir informes.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_anos_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tsede               BIGINT DEFAULT NULL
)
RETURNS TABLE(
    anio      INTEGER,
    es_actual BOOLEAN
)
LANGUAGE plpgsql
STABLE
AS $function$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER'
    );

    RETURN QUERY
    SELECT DISTINCT
           academico_test.fn_anio_lectivo_numero(al.NOMBRE),
           (academico_test.fn_anio_lectivo_numero(al.NOMBRE)
            = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER)
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s
        ON s.PK_TSEDE = pa.FK_TSEDE
       AND s.ACTIVE = TRUE
      JOIN academico_test.TANO_LECTIVO al
        ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
       AND al.ACTIVE = TRUE
       -- El <= descarta los años futuros y, de paso, las filas sucias: para
       -- ellas fn_anio_lectivo_numero devuelve NULL y la comparacion no se
       -- cumple. Ver el paso 0 para por que no es un cast a secas.
       AND academico_test.fn_anio_lectivo_numero(al.NOMBRE)
           <= EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
     WHERE pa.ACTIVE = TRUE
       -- Acota, nunca amplia: una sede que el usuario no alcanza devuelve
       -- lista vacia, no los años de los demas.
       AND (p_fk_tsede IS NULL OR pa.FK_TSEDE = p_fk_tsede)
       AND academico_test.fn_informe_alcanza_sede_jornada(
               p_pk_usuario_solicitante, s.PK_TSEDE, pa.FK_TLV_JORNADA)
     ORDER BY 1 DESC;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_anos_listar(BIGINT, BIGINT)
    IS 'Segundo select de la pantalla de informes: los años lectivos con periodos academicos activos, dentro del alcance del usuario y de la sede indicada. Devuelve EL AÑO EN CURSO Y LOS ANTERIORES, nunca los futuros: en el servidor ya hay periodos creados para 2027, 2028 y 2029, que son configuracion adelantada y no años sobre los que pedir informes; los anteriores si, porque consultar un boletin de un año cerrado es legitimo. Se devuelve el año como NUMERO y no como FK porque TANO_LECTIVO es por establecimiento y no existe "el año lectivo 2026" como registro unico -- 2025 tiene 47 filas, una por EE. El formato del nombre se valida con una expresion regular antes de castear para que un registro sucio no tumbe la consulta con 22P02. es_actual viaja para que el front pueda preseleccionar sin volver a calcular la fecha. p_fk_tsede acota y nunca amplia. V417.';


-- ---------------------------------------------------------------------------
-- 4. Tercer select: las jornadas.
--
--    Una fila por PERIODO ACADEMICO de esa (sede, año), no por jornada
--    distinta. Hoy es lo mismo: entre sedes y establecimientos ACTIVOS la
--    tripleta (sede, año, jornada) identifica un solo periodo, medido.
--
--    Se devuelve por periodo igual, por dos razones. La primera es que nada
--    lo garantiza: el unico indice unico de TPERIODO_ACADEMICO es
--    (FK_TANO_LECTIVO, FK_TSEDE, NOMBRE) WHERE active, y la jornada no
--    entra. La segunda es que en el historico si paso, 24 veces -- todas en
--    sedes ya inactivas, y varias por colegios organizados en CICLOS:
--    "2015" y "2015BH CICLO VI", misma sede y misma jornada. Si los ciclos
--    vuelven, el caso vuelve.
--
--    Con una fila por periodo, ese caso se ve en pantalla en vez de que el
--    backend elija en silencio, y de paso el front se lleva el PK del
--    periodo sin una llamada extra.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_jornadas_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tsede               BIGINT,
    p_anio                   INTEGER DEFAULT NULL
)
RETURNS TABLE(
    fk_tlv_jornada        BIGINT,
    jornada_nombre        VARCHAR,
    fk_tperiodo_academico BIGINT,
    periodo_nombre        VARCHAR,
    fecha_inicio          DATE,
    fecha_fin             DATE,
    en_curso              BOOLEAN
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_anio INTEGER;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER'
    );

    v_anio := COALESCE(p_anio, EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER);

    RETURN QUERY
    SELECT jor.PK_LISTA_VALOR,
           jor.NOMBRE,
           pa.PK_TPERIODO_ACADEMICO,
           pa.NOMBRE,
           pa.FECHA_INICIO,
           pa.FECHA_FIN,
           (CURRENT_DATE BETWEEN pa.FECHA_INICIO AND pa.FECHA_FIN)
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s
        ON s.PK_TSEDE = pa.FK_TSEDE
       AND s.ACTIVE = TRUE
      JOIN academico_test.TANO_LECTIVO al
        ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
       AND al.ACTIVE = TRUE
       AND academico_test.fn_anio_lectivo_numero(al.NOMBRE) = v_anio
      LEFT JOIN academico_test.TLISTA_VALOR jor
             ON jor.PK_LISTA_VALOR = pa.FK_TLV_JORNADA
     WHERE pa.ACTIVE = TRUE
       AND pa.FK_TSEDE = p_fk_tsede
       AND academico_test.fn_informe_alcanza_sede_jornada(
               p_pk_usuario_solicitante, s.PK_TSEDE, pa.FK_TLV_JORNADA)
     ORDER BY jor.NOMBRE NULLS FIRST, pa.FECHA_INICIO, pa.PK_TPERIODO_ACADEMICO;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_jornadas_listar(BIGINT, BIGINT, INTEGER)
    IS 'Tercer select de la pantalla de informes: las jornadas con periodo academico activo en esa sede y ese año, dentro del alcance del usuario. Devuelve UNA FILA POR PERIODO ACADEMICO y no una por jornada distinta. Hoy da igual: medido, entre sedes y establecimientos activos la tripleta (sede, año, jornada) identifica un solo periodo. Se hace asi de todos modos porque nada lo garantiza -- el unico indice unico de TPERIODO_ACADEMICO es (FK_TANO_LECTIVO, FK_TSEDE, NOMBRE) WHERE active, sin la jornada -- y porque en el historico paso 24 veces, todas en sedes ya inactivas y varias por colegios organizados en CICLOS ("2015" y "2015BH CICLO VI", misma sede y jornada). Una fila por periodo hace que ese caso se vea en pantalla en vez de que el backend elija en silencio, y de paso el front recibe el PK del periodo academico sin una llamada extra, por si prefiere mandarlo el mismo en vez de la tripleta. Sin año se toma el en curso. Gate: INFORMES/VER como capability; el alcance lo aplica fn_informe_alcanza_sede_jornada, de modo que un rol de nivel 3 ve aqui unicamente su jornada en vez de opciones que luego le responderian 403. V417.';


-- ---------------------------------------------------------------------------
-- 5. Endpoints.
--
--    Propios de informes aunque existan rutas parecidas en otros modulos: el
--    permiso se concede por endpoint (public.role_query) y la funcion asserta
--    su propio menu, asi que compartir la ruta de otra pantalla obligaria a
--    tener permiso en las dos -- exactamente el problema que tenia esta vista
--    con GET /planeador/docentes/grupos.
--
--    POST y no GET por coherencia con el resto del modulo, donde /informes/*
--    ya recibe el cuerpo por BODY.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-sedes-listar-001',
    'SELECT * FROM academico_test.fn_informe_sedes_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/sedes', 'SELECT', 'POST',
    '{}'::jsonb,
    NULL,
    'Primer select de la pantalla de informes: las sedes que el usuario alcanza y que tienen algun periodo academico activo del año en curso o anterior. No recibe parametros -- el alcance sale de quien pregunta, no del cuerpo, para que no se pueda pedir una sede ajena y descubrirla por la respuesta vacia. Devuelve tambien el establecimiento, porque quien alcanza varios necesita distinguir sedes de nombre parecido.',
    'informes-sedes-listar', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;


INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-anos-listar-001',
    'SELECT * FROM academico_test.fn_informe_anos_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TSEDE AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/anos', 'SELECT', 'POST',
    '{"BODY.FK_TSEDE": "BIGINT"}'::jsonb,
    NULL,
    'Segundo select de la pantalla de informes: los años lectivos con periodos academicos activos en esa sede, del año en curso hacia atras. Los años futuros no se ofrecen aunque existan periodos creados (hay para 2027, 2028 y 2029): son configuracion adelantada, no años sobre los que pedir informes. FK_TSEDE acota y nunca amplia -- una sede fuera del alcance devuelve lista vacia. Sin FK_TSEDE devuelve los años de todo el alcance, util si el front quiere precargar.',
    'informes-anos-listar', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;


INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-jornadas-listar-001',
    'SELECT * FROM academico_test.fn_informe_jornadas_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TSEDE AS BIGINT),
    CAST(:BODY.ANIO AS INTEGER)
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/jornadas', 'SELECT', 'POST',
    '{"BODY.FK_TSEDE": "BIGINT", "BODY.ANIO": "INTEGER"}'::jsonb,
    NULL,
    'Tercer select de la pantalla de informes: las jornadas con periodo academico activo en esa sede y ese año. Devuelve una fila por PERIODO ACADEMICO, no una por jornada distinta: hoy la tripleta (sede, año, jornada) identifica un solo periodo entre las sedes activas, pero ningun indice lo garantiza y en el historico paso 24 veces, asi que ese caso se ve en pantalla en vez de resolverse en silencio. Cada fila trae FK_TPERIODO_ACADEMICO, por si el front prefiere mandar esa PK directamente en vez de la tripleta. Sin ANIO se toma el año en curso.',
    'informes-jornadas-listar', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;


-- ---------------------------------------------------------------------------
-- 6. Roles: el mismo reparto de lectura que ya tienen los demas /informes/*
--    (V342), que son los mismos del planeador menos ESTUDIANTE y ACUDIENTE.
-- ---------------------------------------------------------------------------
INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN (
        'CEVAL-AUXILIAR_ADMINISTRATIVO',
        'CEVAL-COORDINADOR',
        'CEVAL-DIRECTOR_GRUPO',
        'CEVAL-DOCENTE',
        'CEVAL-JEFE_AREA',
        'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL',
        'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO',
        'CEVAL-PSICO_ORIENTADOR',
        'CEVAL-RECTOR',
        'CEVAL-SUPER_ADMINISTRADOR',
        'SSO-ADMIN')
 WHERE m.serviceid   = 'eval-col'
   AND q.http_method = 'POST'
   AND q.path_template IN ('/informes/sedes',
                           '/informes/anos',
                           '/informes/jornadas')
ON CONFLICT DO NOTHING;
