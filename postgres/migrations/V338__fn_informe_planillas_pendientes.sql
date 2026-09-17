-- ===========================================================================
-- V338 - fn_informe_planillas_pendientes: la alerta ROJA.
--        "Docentes con planillas pendientes de calificar".
--
-- QUE RESPONDE
--   En los grupos y periodos seleccionados, que planillas NO TIENEN NADA
--   registrado. Una fila por (grupo, asignatura, periodo) pendiente, con el
--   docente al que hay que ir a buscar.
--
--   Es la gemela de la alerta naranja (V337) y comparte firma a proposito --
--   mismo p_fk_tgrupos como ARREGLO, mismo p_fk_periodos_evaluacion -- para
--   que el front trate las dos igual. La diferencia es que aquella busca
--   cambios DESPUES de consolidar y esta busca ausencia de calificacion.
--
--
-- EL GRANO INCLUYE EL PERIODO
--   "No califico el primer periodo" y "no califico el segundo" son dos
--   planillas pendientes distintas, y el docente puede tener una al dia y la
--   otra no. Colapsarlas perderia esa informacion y el conteo del boton
--   mentiria.
--
--   La alerta naranja (V337) tambien lo incluye, por una razon adicional: su
--   boton "Ir" lleva a la planilla, y la planilla carga las actividades DEL
--   PERIODO. Sin el dato no se sabria a cual mandar.
--
--   DONDE SI SE SEPARAN LAS DOS: EN LA FECHA. Esta solo mira periodos que ya
--   TERMINARON -- ver el comentario en la CTE de periodos.
--
--
-- QUE CUENTA COMO "YA CALIFICO"
--   Que exista AL MENOS UNA TACTIVIDAD_NOTA activa del periodo, de una
--   actividad activa de esa asignatura, ligada a una matricula de ese grupo,
--   con CALIFICACION, DEFINITIVA u OBSERVACION.
--
--   La OBSERVACION cuenta igual que la nota. Es lo que hace que esto sirva en
--   preescolar: alli el docente no pone numeros, deja comentarios por
--   actividad (fn_actividad_observar_estudiante / _grupal, que guardan con
--   CALIFICABLE='N'), y un docente que dejo veinte observaciones ha trabajado
--   su planilla. Mirar solo CALIFICACION lo habria reportado a todos ellos
--   como morosos.
--
--   El vinculo con el grupo se hace por TACTIVIDAD_ESTUDIANTE -> TMATRICULA
--   -> FK_TGRUPO y no por TACTIVIDAD.FK_TGRUPO, que es NULLABLE y por lo
--   tanto no se puede usar para decidir a que grupo pertenece el trabajo.
--
--
-- EL UNIVERSO SON LAS ASIGNACIONES, NO LAS ASIGNATURAS
--   Se parte de TDOCENTE_ASIGNATURA (grupo + asignatura + funcionario) del
--   mismo periodo academico del grupo. Es lo correcto para una alerta que
--   habla de DOCENTES: sin asignacion no hay a quien mostrar ni a donde
--   llevar el boton "Ir".
--
--   Consecuencia que conviene conocer: una asignatura del grupo SIN docente
--   asignado no aparece aqui, aunque este igual de vacia. Eso es un problema
--   distinto -- falta la asignacion academica, no la calificacion -- y
--   mezclarlo haria que la alerta no supiera que decir en la tarjeta. Si hace
--   falta vigilarlo, es otra consulta.
--
--   ACTIVIDADES dice cuantas actividades existen en ese periodo para esa
--   planilla. Distingue dos situaciones que la alerta trata igual pero el
--   colegio no: 0 significa que el docente ni siquiera armo las actividades;
--   mayor que 0, que las armo y no las califico.
--
--
-- ASIGNATURAS COMPARTIDAS
--   Se devuelve UN docente -- la asignacion mas reciente -- y tambien CUANTOS
--   hay, porque en el servidor hay 397 combinaciones (grupo, asignatura) con
--   mas de un docente activo: 374 con dos, 22 con tres, una con cuatro. Se
--   emite UNA fila por planilla y no una por docente, para que el conteo del
--   boton siga siendo "planillas pendientes" y no se infle; docentes_asignados
--   mayor que 1 le dice al front que la planilla se comparte.
--
--
-- PERMISOS
--   INFORMES/VER, verificado UNA VEZ POR GRUPO y ANTES de leer nada, igual
--   que en la naranja: un grupo fuera de alcance hace fallar toda la llamada
--   con 42501 en vez de devolver una alerta incompleta que se ve completa.
--
-- Idempotente: CREATE OR REPLACE, con DROP previo porque una version anterior
-- de esta misma migracion no traia PERIODO_FIN y CREATE OR REPLACE no puede
-- cambiar el tipo de retorno.
-- ===========================================================================


DROP FUNCTION IF EXISTS academico_test.fn_informe_planillas_pendientes(BIGINT, BIGINT[], BIGINT[]);


CREATE OR REPLACE FUNCTION academico_test.fn_informe_planillas_pendientes(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupos             BIGINT[],
    p_fk_periodos_evaluacion BIGINT[] DEFAULT NULL
)
RETURNS TABLE(
    fk_tgrupo               BIGINT,
    grupo_nombre            VARCHAR,
    fk_tasignatura          BIGINT,
    asignatura_nombre       VARCHAR,
    fk_tfuncionario         BIGINT,
    fk_tusuario_docente     BIGINT,
    docente                 VARCHAR,
    docentes_asignados      BIGINT,
    fk_tperiodo_evaluacion  BIGINT,
    periodo_nombre          VARCHAR,
    periodo_abreviacion     VARCHAR,
    periodo_fin             DATE,
    estudiantes             BIGINT,
    actividades             BIGINT
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    r_g          RECORD;
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
BEGIN
    IF p_fk_tgrupos IS NULL OR CARDINALITY(p_fk_tgrupos) = 0 THEN
        RAISE EXCEPTION 'Debe indicar al menos un grupo'
            USING ERRCODE = '22023';
    END IF;

    -- Gate por grupo, ANTES de leer nada.
    FOR r_g IN SELECT UNNEST(p_fk_tgrupos) AS pk
    LOOP
        SELECT s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO
          INTO v_fk_sede, v_fk_jornada, v_fk_ee
          FROM academico_test.TGRUPO gr
          JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
          JOIN academico_test.TPERIODO_ACADEMICO pa
            ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
         WHERE gr.PK_TGRUPO = r_g.pk
           AND gr.ACTIVE = TRUE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'No se encontro el grupo %', r_g.pk
                USING ERRCODE = 'P0002';
        END IF;

        PERFORM academico_test.fn_assert_permiso_seccion(
            p_pk_usuario_solicitante, 'INFORMES', 'VER',
            v_fk_ee, v_fk_sede, v_fk_jornada
        );
    END LOOP;

    RETURN QUERY
    WITH grupos AS (
        SELECT gr.PK_TGRUPO            AS pk,
               gr.NOMBRE               AS nombre,
               gd.FK_TPERIODO_ACADEMICO AS peraca
          FROM academico_test.TGRUPO gr
          JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
         WHERE gr.PK_TGRUPO = ANY (p_fk_tgrupos)
           AND gr.ACTIVE = TRUE
    ),
    periodos AS (
        SELECT pe.PK_TPERIODO_EVALUACION AS pk,
               pe.NOMBRE                 AS nombre,
               pe.ABREVIACION            AS abrev,
               pe.FECHA_INICIO           AS inicio,
               pe.FECHA_FIN              AS fin,
               pe.FK_TPERIODO_ACADEMICO  AS peraca
          FROM academico_test.TPERIODO_EVALUACION pe
         WHERE pe.ACTIVE = TRUE
           AND pe.FK_TPERIODO_ACADEMICO IN (SELECT g.peraca FROM grupos g)
           -- *** SOLO PERIODOS QUE YA TERMINARON ***
           -- Un periodo en curso NO puede tener planillas "pendientes": el
           -- docente esta dentro de su plazo y nadie le esta incumpliendo
           -- nada. Marcarlo llenaria la alerta de rojo el primer dia de cada
           -- periodo y la volveria ruido que se aprende a ignorar.
           --
           -- Es la diferencia de fondo con la alerta naranja, que no mira
           -- fechas: aquella se dispara por un HECHO -- alguien cambio una
           -- nota ya consolidada -- y ese hecho es igual de relevante ocurra
           -- cuando ocurra. Esta se dispara por una OMISION, y una omision
           -- solo existe una vez vencido el plazo.
           AND pe.FECHA_FIN < CURRENT_DATE
           AND (p_fk_periodos_evaluacion IS NULL
                OR CARDINALITY(p_fk_periodos_evaluacion) = 0
                OR pe.PK_TPERIODO_EVALUACION = ANY (p_fk_periodos_evaluacion))
    ),
    -- El universo: las planillas que alguien tiene a cargo.
    planillas AS (
        SELECT g.pk                              AS grupo,
               g.nombre                          AS grupo_nombre,
               da.FK_TASIGNATURA                 AS asignatura,
               (ARRAY_AGG(da.FK_TFUNCIONARIO
                          ORDER BY da.PK_TDOCENTE_ASIGNATURA DESC))[1] AS funcionario,
               COUNT(DISTINCT da.FK_TFUNCIONARIO)                      AS cuantos
          FROM grupos g
          JOIN academico_test.TDOCENTE_ASIGNATURA da
            ON da.FK_TGRUPO = g.pk
           AND da.ACTIVE = TRUE
           AND da.FK_TPERIODO_ACADEMICO = g.peraca
         GROUP BY g.pk, g.nombre, da.FK_TASIGNATURA
    ),
    candidatas AS (
        SELECT p.*, pe.pk AS periodo, pe.nombre AS periodo_nombre,
               pe.abrev AS periodo_abrev, pe.inicio AS periodo_inicio, pe.fin AS periodo_fin
          FROM planillas p
          JOIN grupos g  ON g.pk = p.grupo
          JOIN periodos pe ON pe.peraca = g.peraca
    )
    SELECT c.grupo,
           c.grupo_nombre,
           c.asignatura,
           asg.NOMBRE,
           c.funcionario,
           ud.PK_TUSUARIO,
           NULLIF(TRIM(CONCAT_WS(' ', ud.PRIMER_NOMBRE, ud.PRIMER_APELLIDO)), '')::VARCHAR,
           c.cuantos,
           c.periodo,
           c.periodo_nombre,
           c.periodo_abrev,
           c.periodo_fin,
           (SELECT COUNT(*)
              FROM academico_test.TMATRICULA m
             WHERE m.FK_TGRUPO = c.grupo AND m.ACTIVE = TRUE),
           -- Actividades de esa planilla en ese periodo. 0 significa que el
           -- docente ni siquiera las armo, que no es lo mismo que tenerlas
           -- sin calificar.
           (SELECT COUNT(DISTINCT a.PK_TACTIVIDAD)
              FROM academico_test.TACTIVIDAD a
              JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
                ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
               AND ae.ACTIVE = TRUE
              JOIN academico_test.TMATRICULA m
                ON m.PK_TMATRICULA = ae.FK_TMATRICULA
               AND m.FK_TGRUPO = c.grupo
               AND m.ACTIVE = TRUE
             WHERE a.ACTIVE = TRUE
               AND a.FK_TASIGNATURA = c.asignatura
               AND academico_test.fn_actividad_en_periodo_eval(a.PK_TACTIVIDAD, c.periodo) = TRUE)
      FROM candidatas c
      JOIN academico_test.TASIGNATURA asg ON asg.PK_TASIGNATURA = c.asignatura
      LEFT JOIN academico_test.TFUNCIONARIO fd
             ON fd.PK_TFUNCIONARIO = c.funcionario
      LEFT JOIN academico_test.TUSUARIO ud
             ON ud.PK_TUSUARIO = fd.FK_TUSUARIO
     -- La condicion de la alerta: NADA registrado. Nota u observacion, porque
     -- en preescolar el trabajo del docente son los comentarios.
     WHERE NOT EXISTS (
           SELECT 1
             FROM academico_test.TACTIVIDAD a
             JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
               ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
              AND ae.ACTIVE = TRUE
             JOIN academico_test.TMATRICULA m
               ON m.PK_TMATRICULA = ae.FK_TMATRICULA
              AND m.FK_TGRUPO = c.grupo
              AND m.ACTIVE = TRUE
             JOIN academico_test.TACTIVIDAD_NOTA n
               ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
              AND n.ACTIVE = TRUE
            WHERE a.ACTIVE = TRUE
              AND a.FK_TASIGNATURA = c.asignatura
              AND academico_test.fn_actividad_en_periodo_eval(a.PK_TACTIVIDAD, c.periodo) = TRUE
              AND (n.CALIFICACION IS NOT NULL
                   OR n.DEFINITIVA IS NOT NULL
                   OR NULLIF(TRIM(COALESCE(n.OBSERVACION, '')), '') IS NOT NULL)
     )
     ORDER BY c.grupo_nombre, c.periodo_inicio, asg.NOMBRE;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_planillas_pendientes(BIGINT, BIGINT[], BIGINT[])
    IS 'La alerta ROJA del modulo de informes -- "docentes con planillas pendientes de calificar". Devuelve, en los grupos y periodos seleccionados, una fila por (grupo, asignatura, periodo) donde NO hay NADA registrado, con el docente al que hay que ir a buscar y las FK que el boton "Ir" necesita para armar la ruta a la planilla. Es la gemela de fn_informe_cambios_pendientes (V337) y comparte firma a proposito -- mismo arreglo de grupos, mismos periodos -- para que el front trate las dos alertas igual; la diferencia es que aquella busca cambios DESPUES de consolidar y esta busca ausencia de calificacion. EL GRANO INCLUYE EL PERIODO, a diferencia de la naranja: un cambio es un cambio se haya hecho cuando sea, pero "no califico el primer periodo" y "no califico el segundo" son dos planillas pendientes distintas, y colapsarlas haria mentir al conteo del boton. CUENTA COMO YA CALIFICO que exista al menos una TACTIVIDAD_NOTA activa del periodo, de una actividad activa de esa asignatura, ligada a una matricula de ese grupo, con CALIFICACION, DEFINITIVA u OBSERVACION: la observacion cuenta igual que la nota, y eso es lo que hace que sirva en preescolar, donde el docente no pone numeros sino comentarios por actividad (guardados con CALIFICABLE=N) -- mirar solo CALIFICACION habria reportado como morosos a todos esos docentes. El vinculo con el grupo se hace por TACTIVIDAD_ESTUDIANTE -> TMATRICULA -> FK_TGRUPO y no por TACTIVIDAD.FK_TGRUPO, que es NULLABLE y por lo tanto no sirve para decidir a que grupo pertenece el trabajo. EL UNIVERSO SON LAS ASIGNACIONES (TDOCENTE_ASIGNATURA del mismo periodo academico), no las asignaturas, que es lo correcto para una alerta que habla de docentes: sin asignacion no hay a quien mostrar ni a donde llevar el boton. Consecuencia a conocer: una asignatura del grupo SIN docente asignado no aparece aunque este igual de vacia -- eso es falta de asignacion academica, no de calificacion, y mezclarlo dejaria la tarjeta sin que decir. ACTIVIDADES distingue dos situaciones que la alerta trata igual pero el colegio no: 0 significa que el docente ni siquiera armo las actividades; mayor que 0, que las armo y no las califico. Se devuelve UN docente -- la asignacion mas reciente -- y tambien cuantos hay, porque en el servidor hay 397 combinaciones (grupo, asignatura) con mas de un docente activo (374 con dos, 22 con tres, una con cuatro); se emite una fila por PLANILLA y no por docente para que el conteo del boton siga siendo "planillas pendientes" y no se infle, y docentes_asignados mayor que 1 avisa que se comparte. Gate: INFORMES/VER, verificado una vez por grupo y ANTES de leer nada.';
