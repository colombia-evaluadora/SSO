-- ===========================================================================
-- V420 - Exportar el informe de un periodo: la misma tabla, en filas planas.
--
--   fn_informe_grupo_reporte   envoltorio plano de fn_informe_grupo_listar
--   POST /informes/reporte     la fila public.query que consume reporting-service
--
--
-- COMO FUNCIONA UNA EXPORTACION EN ESTE SISTEMA
--   No hay SQL de reporte ni plantillas por modulo. reporting-service recibe
--   POST /reportes/<clave>, busca esa clave en su application.yml, y de ahi
--   saca dos cosas: el `path` de una fila de public.query -- que llama a la
--   funcion del listado SIN paginar -- y el mapa `columns`, que fija que
--   columnas salen, en que orden y con que titulo. Con eso arma el PDF o el
--   Excel. Agregar un reporte = esta migracion + una entrada en ese yml.
--
--
-- POR QUE UN ENVOLTORIO Y NO LA FUNCION DEL LISTADO DIRECTAMENTE
--   La regla del servicio es que un reporte reuse la MISMA funcion del
--   listado, para que no diverjan el WHERE ni el alcance territorial y nadie
--   exporte filas que en pantalla no puede ver. Eso se respeta: esta funcion
--   no consulta ninguna tabla, LLAMA a fn_informe_grupo_listar con los mismos
--   parametros y se limita a aplanar lo que devuelve.
--
--   Hace falta aplanar porque el listado devuelve las asignaturas en una
--   columna JSONB -- una celda con un arreglo de objetos -- y eso en una
--   tabla de PDF no es una columna: el renderer imprimiria el nombre de la
--   primera asignatura y perderia el resto. La grilla de la pantalla tiene
--   una columna por asignatura, pero las asignaturas cambian por grado, y las
--   columnas de un reporte se declaran fijas en el yml.
--
--   Asi que el reporte va en formato LARGO: una fila por (estudiante,
--   periodo, asignatura). Es la unica forma estable con columnas fijas, y
--   ademas es la que sirve para filtrar y sumar en Excel, que es lo que la
--   gente termina haciendo con un export.
--
--
-- SOLO SALE LO CONSOLIDADO. ESTO ES UN BOLETIN, NO UN VOLCADO
--   La pantalla muestra tres cosas distintas con la misma pinta de numero:
--
--     en negro  la nota GUARDADA        -- el informe de ese periodo ya se
--                                          consolido
--     en gris   la nota PROYECTADA      -- todavia no se guardo; es lo que
--                                          daria el calculo de hoy
--     y cuando el periodo no tiene ninguna calificacion, el listado cambia de
--     modo entero y lo que muestra es lo que al estudiante le FALTA para
--     ganar el area en el año
--
--   Un boletin solo puede decir la primera. Una proyeccion impresa deja de
--   parecer una proyeccion en cuanto sale del sistema, y una nota requerida
--   impresa se lee como si el estudiante la hubiera sacado.
--
--   Por eso el reporte se queda unicamente con las filas CONSOLIDADAS y, de
--   ellas, con las asignaturas que tienen nota guardada. Se filtra en dos
--   niveles porque el estado es de cada asignatura, no de la fila: un periodo
--   consolidado puede tener una asignatura que no se alcanzo a guardar y cuya
--   nota sigue siendo una proyeccion.
--
--   `cambio_propuesto` SI entra: es una nota guardada a la que el docente le
--   propuso un cambio despues. Lo que se exporta es la guardada -- la
--   propuesta no viaja en este reporte --, que es justamente el numero que el
--   boletin debe decir hasta que alguien acepte el cambio.
--
--   En preescolar "cerrado" no significa consolidado sino con la observacion
--   guardada -- ver mas abajo, porque ahi el informe se cierra por otra via.
--
--   Consecuencia a tener presente: un grupo sin nada cerrado exporta CERO
--   filas. Es correcto -- no hay boletin que emitir todavia -- pero conviene
--   que el front avise antes de mandar a generar el archivo, o el usuario
--   recibe un PDF que dice "sin datos" y no sabe por que.
--
--
-- ESTO NO ROMPE LA REGLA DEL REPORTING-SERVICE
--   La regla es que un reporte no tenga su propio WHERE, para que nadie
--   exporte filas que en pantalla no puede ver. Aca el filtro va en la otra
--   direccion: se exporta un SUBCONJUNTO de lo que la pantalla muestra, con
--   el mismo gate y los mismos filtros del usuario. Lo que no puede ver,
--   sigue sin poder exportarlo.
--
--
-- PREESCOLAR: AHI EL INFORME SE CIERRA DE OTRA MANERA
--   Un periodo cualitativo no trae asignaturas sino una observacion, y eso
--   cambia dos cosas.
--
--   La primera es de forma: el LEFT JOIN LATERAL conserva esa fila con la
--   asignatura vacia y el texto en `observacion`, en vez de desaparecerla --
--   que es lo que haria un JOIN normal contra un arreglo vacio.
--
--   La segunda es de fondo, y es la que hay que mirar dos veces. "Estar
--   consolidado" significa tener fila en TINFORME_PERIODO_MATRICULA, y esa
--   fila la escribe fn_informe_metricas_recalcular, a la que solo llaman los
--   dos guardados de NOTAS. En preescolar no hay notas que guardar: lo que
--   cierra el informe es guardar la OBSERVACION, por su propio endpoint, que
--   no toca esa tabla. Con el filtro solo por `consolidado`, el boletin de un
--   preescolar habria salido VACIO aunque el docente ya hubiera revisado y
--   aceptado el texto de cada estudiante.
--
--   Por eso la condicion tiene dos ramas: consolidado, O cualitativo con
--   observacion guardada. Y una observacion guardada ya es, por definicion,
--   una revisada: TESTUDIANTE_PERIODO_OBSERVACION solo admite APROBADA y
--   MODIFICADA -- el estado PENDIENTE esta desactivado en el catalogo a
--   proposito (V330), justamente para que no exista el caso "la IA escribio
--   y nadie leyo". No hay riesgo de imprimir un borrador.
--
--   Lo que SI puede pasar es que el docente haya dejado observaciones nuevas
--   despues de guardar el resumen, y entonces el texto sea viejo. El listado
--   lo marca con `observacion_desactualizada` y la pantalla lo avisa; el
--   boletin imprime el texto aceptado, que es el unico que alguien reviso.
--
--
-- LOS FILTROS SON LOS DE LA PANTALLA
--   Mismos nombres de bind que el listado (FK_TGRUPO, PERIODOS, SEARCH), asi
--   que el archivo respeta la busqueda y los periodos que el usuario tenga
--   marcados. Sin filtros, el grupo entero -- consolidado.
--
-- Idempotente: CREATE OR REPLACE, e INSERT ... WHERE NOT EXISTS / ON CONFLICT
-- DO NOTHING para el endpoint y los roles.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. El envoltorio plano.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_grupo_reporte(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_periodos_evaluacion BIGINT[] DEFAULT NULL,
    p_search                 VARCHAR  DEFAULT NULL
)
RETURNS TABLE(
    estudiante   VARCHAR,
    documento    VARCHAR,
    periodo      VARCHAR,
    asignatura   VARCHAR,
    area         VARCHAR,
    nota         NUMERIC,
    desempeno    VARCHAR,
    estado       VARCHAR,
    aprobada     BOOLEAN,
    promedio     NUMERIC,
    puesto       BIGINT,
    observacion  TEXT
)
LANGUAGE sql
STABLE
AS $function$
    WITH filas AS (
        -- La MISMA funcion de la pantalla: mismo gate, mismos filtros, mismo
        -- calculo del puesto. Aqui no se decide nada, solo se aplana.
        SELECT *
          FROM academico_test.fn_informe_grupo_listar(
                   p_pk_usuario_solicitante,
                   p_fk_tgrupo,
                   p_fk_periodos_evaluacion,
                   p_search)
    )
    SELECT f.estudiante,
           f.documento,
           f.periodo_nombre,
           a.nombre,
           a.area,
           a.nota,
           -- En lo cualitativo la nota no es un numero: lo que vale es el
           -- desempeno, y algunos formatos solo tienen simbolo.
           COALESCE(a.valoracion, a.simbolo)::VARCHAR,
           -- Solo quedan dos estados posibles tras el filtro de abajo. El de
           -- cambio propuesto se distingue porque la nota impresa es la
           -- guardada y hay una propuesta esperando: si alguien compara el
           -- boletin con la pantalla, esto explica la diferencia.
           CASE a.estado
               WHEN 'guardada'         THEN 'Guardada'
               WHEN 'cambio_propuesto' THEN 'Guardada (con cambio propuesto)'
               ELSE a.estado
           END::VARCHAR,
           a.aprobada,
           -- Consolidado: el promedio guardado es el del informe. No se cae
           -- al proyectado a proposito -- si no hay guardado, esta fila no
           -- deberia estar aca.
           f.promedio_guardado,
           f.puesto,
           f.observacion
      FROM filas f
      -- LEFT ... ON TRUE: un periodo de preescolar trae el arreglo vacio y su
      -- fila tiene que sobrevivir igual, con la observacion. Un JOIN normal
      -- la borraria, que es justo el estudiante que mas interesa en ese caso.
      LEFT JOIN LATERAL JSONB_TO_RECORDSET(f.asignaturas) AS a(
               asignatura   BIGINT,
               nombre       VARCHAR,
               abreviacion  VARCHAR,
               area         VARCHAR,
               orden        INTEGER,
               nota         NUMERIC,
               estado       VARCHAR,
               es_numerico  BOOLEAN,
               valoracion   VARCHAR,
               simbolo      VARCHAR,
               aprobada     BOOLEAN,
               ya_asegurado BOOLEAN,
               alcanzable   BOOLEAN
           ) ON TRUE
     -- Los dos niveles del filtro: la fila tiene que estar cerrada, y de sus
     -- asignaturas solo salen las que tienen nota GUARDADA. Un periodo
     -- consolidado puede arrastrar una asignatura que no se alcanzo a
     -- guardar, y esa nota sigue siendo una proyeccion. Ver la cabecera.
     WHERE (
             f.consolidado IS TRUE
             -- En lo cualitativo el informe se cierra guardando la
             -- OBSERVACION, no consolidando notas que no existen: sin esta
             -- rama, el boletin de un preescolar saldria vacio aunque el
             -- docente ya hubiera aceptado el texto. Ver la cabecera.
             OR (f.es_cualitativo IS TRUE AND f.observacion_estado IS NOT NULL)
           )
       AND (a.estado IS NULL                              -- cualitativo: la
                                                          -- fila no tiene
                                                          -- asignaturas
            OR a.estado IN ('guardada', 'cambio_propuesto'))
     ORDER BY f.periodo_inicio,
              f.estudiante,
              a.orden NULLS LAST,
              a.nombre;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_grupo_reporte(BIGINT, BIGINT, BIGINT[], VARCHAR)
    IS 'El informe de un grupo aplanado para exportar a PDF o Excel: una fila por (estudiante, periodo, asignatura). No consulta ninguna tabla -- llama a fn_informe_grupo_listar con los mismos parametros y expande su columna JSONB de asignaturas --, asi que hereda el gate y los filtros de la pantalla. Se aplana porque una celda con un arreglo de objetos no es una columna de PDF y porque las columnas del reporte se declaran fijas en el application.yml mientras que las asignaturas cambian por grado. EXPORTA UNICAMENTE LO CONSOLIDADO: la pantalla pinta con la misma forma de numero la nota guardada (negro), la proyectada (gris) y, cuando el periodo no tiene ninguna calificacion, lo que al estudiante le FALTA para ganar; un boletin solo puede decir la primera, porque una proyeccion impresa deja de parecer una proyeccion en cuanto sale del sistema. El filtro va en dos niveles -- la fila consolidada y, de sus asignaturas, las que tienen nota guardada -- porque el estado es de cada asignatura y un periodo consolidado puede arrastrar una que no se alcanzo a guardar. cambio_propuesto SI entra: es una nota guardada con un cambio esperando aprobacion, y lo que se imprime es la guardada. Esto no contradice la regla del reporting-service de no darle un WHERE propio a un reporte: ese riesgo es exportar MAS de lo que se ve, y aqui se exporta un subconjunto. Un grupo sin nada cerrado exporta cero filas. PREESCOLAR entra por otra puerta: ahi no hay notas que consolidar -- lo que cierra el informe es guardar la OBSERVACION, por un endpoint que no escribe TINFORME_PERIODO_MATRICULA --, asi que la condicion tiene dos ramas, consolidado O cualitativo con observacion guardada; con solo la primera, el boletin de un preescolar salia vacio aunque el docente ya hubiera aceptado el texto. Una observacion guardada es por definicion una revisada: el catalogo solo admite APROBADA y MODIFICADA, con PENDIENTE desactivado a proposito (V330). V420.';


-- ---------------------------------------------------------------------------
-- 2. La fila de public.query que consume reporting-service.
--
--    Los binds van bajo BODY.FILTERS.* y con los MISMOS nombres que el
--    listado: es el contrato unico de POST /reportes/<clave> y permite que el
--    front mande el objeto de filtros que ya tiene armado para la tabla.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-reporte-001',
    'SELECT * FROM academico_test.fn_informe_grupo_reporte(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.FK_TGRUPO AS BIGINT),
    CAST(:BODY.FILTERS.PERIODOS AS BIGINT[]),
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR)
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/reporte', 'SELECT', 'POST',
    '{"BODY.FILTERS.FK_TGRUPO": "BIGINT", "BODY.FILTERS.PERIODOS": "BIGINT[]", "BODY.FILTERS.SEARCH": "VARCHAR"}'::jsonb,
    NULL,
    'El informe de un grupo aplanado para exportar: una fila por (estudiante, periodo, asignatura). Lo consume reporting-service bajo la clave "informes" (POST /reportes/informes), no el front directamente. Llama a la misma fn_informe_grupo_listar de la pantalla, con los mismos filtros y el mismo gate, y expande su columna JSONB de asignaturas. EXPORTA SOLO LO CONSOLIDADO -- las notas guardadas --: las proyecciones (las que la pantalla pinta en gris) y las notas requeridas para aprobar quedan fuera, porque impresas en un boletin se leerian como calificaciones reales. Una asignatura con cambio propuesto si sale, con su nota guardada. Un grupo sin nada cerrado devuelve cero filas. PREESCOLAR entra por otra puerta: ahi el informe se cierra guardando la OBSERVACION y no consolidando notas, asi que esas filas salen con la asignatura vacia y su texto -- que siempre es uno que un docente aprobo o edito, porque el estado PENDIENTE no existe.',
    'informes-reporte', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;


-- ---------------------------------------------------------------------------
-- 3. Roles: se COPIAN los del listado, no se escriben a mano.
--
--    "Quien ve el listado puede exportarlo". A mano se desincronizan el dia
--    que alguien agregue un rol a la pantalla y se olvide del reporte.
-- ---------------------------------------------------------------------------
INSERT INTO public.role_query (query_id, role_id)
SELECT reporte.id_query, rq.role_id
  FROM public.query reporte
  JOIN public.microservice m ON m.id_microservice = reporte.microservice_id
  JOIN public.query listado  ON listado.microservice_id = reporte.microservice_id
                            AND listado.path_template   = '/informes/grupo'
                            AND listado.http_method     = 'POST'
  JOIN public.role_query rq  ON rq.query_id = listado.id_query
 WHERE reporte.uuid = 'eval-col-informes-reporte-001'
ON CONFLICT DO NOTHING;
