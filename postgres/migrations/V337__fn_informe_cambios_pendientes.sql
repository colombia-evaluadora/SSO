-- ===========================================================================
-- V337 - fn_informe_cambios_pendientes: la alerta NARANJA.
--        "Docentes con cambios pendientes de aprobacion".
--
-- QUE RESPONDE
--   En los grupos y periodos que el usuario tiene seleccionados, donde se
--   cambiaron notas DESPUES de que el periodo se consolidara. Una fila por
--   (grupo, asignatura, PERIODO), con cuantos estudiantes quedaron afectados
--   y cuando fue el ultimo cambio.
--
--   EL PERIODO ES PARTE DEL GRANO
--   Un mismo grupo con cambios en dos periodos sale DOS veces, una por cada
--   uno. No es cosmetica: el boton "Ir" lleva a la planilla, y la planilla
--   carga las actividades DEL PERIODO correspondiente, no todas. Sin este
--   dato el front no sabria a cual mandar, y mandaria a la planilla completa
--   -- que es justo lo que no sirve para revisar un cambio puntual.
--
--   Es lo que alimenta el panel: el boton muestra el total de cambios, el
--   encabezado cuenta los GRUPOS distintos, y cada tarjeta lleva nombre del
--   docente, asignatura, grupo y el boton "Ir" a su planilla -- para lo cual
--   necesita las tres FK, no solo los nombres.
--
--
-- POR QUE NO SALE DE fn_informe_grupo_listar
--   Dos razones, y cualquiera bastaria.
--
--   1. GRANO. El listado es por (estudiante, periodo); esto es por
--      (grupo, asignatura, docente). Sacarlo de alli obligaria a que el front
--      recorriera todos los estudiantes y reagrupara por docente, que es
--      justo el trabajo que una consulta hace mejor.
--
--   2. ALCANCE. La pantalla permite varios grupos a la vez -- son pestanas,
--      "601 M", "602 M" -- y la alerta habla de todos ellos. El listado es de
--      UN grupo: el front tendria que llamarlo N veces, sumar, y traerse
--      todas las notas de todos los estudiantes para contar unos pocos
--      cambios.
--
--   Por eso p_fk_tgrupos es un ARREGLO, igual que en la alerta roja
--   (fn_informe_planillas_pendientes, V338), para que el front trate las dos
--   igual.
--
--
-- COMO SE DETECTA UN CAMBIO
--   Por COMPARACION, no por registro: se recalcula la proyeccion de cada
--   (estudiante, asignatura, periodo) y se compara contra
--   TASIGNATURA_NOTA.DEFINITIVA. Si difieren -- o si hay guardada y la
--   proyeccion ya no existe porque el docente dio de baja las actividades --
--   hay cambio pendiente.
--
--   Se reutiliza fn_informe_estudiante_asignaturas (V334) con
--   p_solo_cambios = TRUE en vez de reimplementar la comparacion. Asi la
--   alerta no puede decir "hay 5 cambios" mientras la tabla muestra 4.
--
--   SOLO cuentan las asignaturas YA CONSOLIDADAS. Si el periodo nunca se
--   guardo no hay nada que "aprobar": la nota simplemente aun no se congelo,
--   y eso es el flujo normal, no una alerta. Por eso el estado que dispara es
--   'cambio_propuesto' y no 'proyectada'.
--
--
-- DE DONDE SALE EL DOCENTE: DE TDOCENTE_ASIGNATURA, Y PUNTO
--   Del docente asignado a esa asignatura en ese grupo.
--
--   Una version anterior resolvia primero por TACTIVIDAD_NOTA.MODIFIED_BY --
--   quien REALMENTE digito -- y solo caia a la asignacion si eso no resolvia.
--   Era mas riguroso y es peor: en la practica no califica actividades de una
--   asignatura alguien distinto del docente de esa asignatura, asi que el
--   camino "riguroso" casi nunca aporta algo distinto, y a cambio metia una
--   dependencia fragil -- MODIFIED_BY es un VARCHAR sin FK donde otros
--   procesos escriben 'migracion', 'V330' o un correo -- que obligaba a un
--   JOIN defensivo con el guard dentro de un CASE para no reventar con 22P02.
--
--   Ademas la alerta no existe para senalar culpables sino para LLEVAR A LA
--   PLANILLA, y la planilla es de la asignatura: el destino correcto del
--   boton "Ir" es siempre el docente asignado, resolviera o no el MODIFIED_BY.
--
--   La FECHA del ultimo cambio si se sigue tomando de TACTIVIDAD_NOTA, porque
--   esa no tiene sustituto y no depende de resolver a nadie.
--
--
-- PERMISOS
--   INFORMES/VER, verificado UNA VEZ POR GRUPO y ANTES de leer nada. Un grupo
--   al que el usuario no alcanza hace fallar toda la llamada con 42501 en vez
--   de devolver el resto en silencio: la alerta dice "en los grupos
--   seleccionados", y una respuesta incompleta que se ve completa es peor que
--   un error.
--
-- Idempotente: CREATE OR REPLACE. DROP previo porque la version anterior --
-- la que resolvia el docente por MODIFIED_BY -- no traia docentes_asignados,
-- y CREATE OR REPLACE no puede cambiar el tipo de retorno.
-- ===========================================================================


DROP FUNCTION IF EXISTS academico_test.fn_informe_cambios_pendientes(BIGINT, BIGINT[], BIGINT[]);


CREATE OR REPLACE FUNCTION academico_test.fn_informe_cambios_pendientes(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupos             BIGINT[],
    p_fk_periodos_evaluacion BIGINT[] DEFAULT NULL
)
RETURNS TABLE(
    fk_tgrupo              BIGINT,
    grupo_nombre           VARCHAR,
    fk_tasignatura         BIGINT,
    asignatura_nombre      VARCHAR,
    fk_tperiodo_evaluacion BIGINT,
    periodo_nombre         VARCHAR,
    periodo_abreviacion    VARCHAR,
    fk_tfuncionario        BIGINT,
    fk_tusuario_docente    BIGINT,
    docente                VARCHAR,
    docentes_asignados     BIGINT,
    estudiantes_afectados  BIGINT,
    ultimo_cambio          TIMESTAMP
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
    WITH matriculas AS (
        SELECT m.PK_TMATRICULA AS pk,
               m.FK_TGRUPO     AS grupo
          FROM academico_test.TMATRICULA m
         WHERE m.FK_TGRUPO = ANY (p_fk_tgrupos)
           AND m.ACTIVE = TRUE
    ),
    -- Se reutiliza el detalle con p_solo_cambios para que la alerta no pueda
    -- contradecir a la tabla.
    cambios AS (
        SELECT mt.grupo,
               d.fk_tasignatura,
               d.asignatura_nombre,
               d.fk_tperiodo_evaluacion,
               d.periodo_nombre,
               d.periodo_inicio,
               mt.pk          AS matricula,
               d.calificado_en
          FROM matriculas mt
          CROSS JOIN LATERAL academico_test.fn_informe_estudiante_asignaturas(
                         p_pk_usuario_solicitante, mt.pk,
                         p_fk_periodos_evaluacion, TRUE) d
    ),
    -- El PERIODO entra en el agrupamiento: ver la cabecera. Un mismo grupo
    -- con cambios en dos periodos produce DOS filas.
    agrupado AS (
        SELECT c.grupo,
               c.fk_tasignatura,
               c.asignatura_nombre,
               c.fk_tperiodo_evaluacion,
               c.periodo_nombre,
               c.periodo_inicio,
               COUNT(DISTINCT c.matricula) AS afectados,
               MAX(c.calificado_en)        AS cuando
          FROM cambios c
         GROUP BY c.grupo, c.fk_tasignatura, c.asignatura_nombre,
                  c.fk_tperiodo_evaluacion, c.periodo_nombre, c.periodo_inicio
    )
    SELECT a.grupo,
           gr.NOMBRE,
           a.fk_tasignatura,
           a.asignatura_nombre,
           a.fk_tperiodo_evaluacion,
           a.periodo_nombre,
           pe.ABREVIACION,
           da.FK_TFUNCIONARIO,
           ud.PK_TUSUARIO,
           NULLIF(TRIM(CONCAT_WS(' ', ud.PRIMER_NOMBRE, ud.PRIMER_APELLIDO)), '')::VARCHAR,
           COALESCE(da.cuantos, 0),
           a.afectados,
           a.cuando
      FROM agrupado a
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = a.grupo
      JOIN academico_test.TPERIODO_EVALUACION pe
        ON pe.PK_TPERIODO_EVALUACION = a.fk_tperiodo_evaluacion
      -- El docente de la asignatura en ese grupo. Directo, sin pasar por
      -- MODIFIED_BY: ver la cabecera.
      --
      -- Se devuelve UNO -- la asignacion mas reciente -- pero tambien CUANTOS
      -- hay, porque la asignatura puede estar compartida: en el servidor hay
      -- 397 combinaciones (grupo, asignatura) con mas de un docente activo
      -- (374 con dos, 22 con tres, una con cuatro). Sin ese conteo el front
      -- mostraria un nombre sin saber que hay otros, y "Ir" llevaria a la
      -- planilla de uno solo sin avisar. Con docentes_asignados > 1 puede
      -- indicar que se comparte.
      LEFT JOIN LATERAL (
            SELECT (ARRAY_AGG(dax.FK_TFUNCIONARIO
                              ORDER BY dax.PK_TDOCENTE_ASIGNATURA DESC))[1] AS FK_TFUNCIONARIO,
                   COUNT(DISTINCT dax.FK_TFUNCIONARIO)                      AS cuantos
              FROM academico_test.TDOCENTE_ASIGNATURA dax
             WHERE dax.FK_TGRUPO      = a.grupo
               AND dax.FK_TASIGNATURA = a.fk_tasignatura
               AND dax.ACTIVE = TRUE
      ) da ON TRUE
      LEFT JOIN academico_test.TFUNCIONARIO fd
             ON fd.PK_TFUNCIONARIO = da.FK_TFUNCIONARIO
      LEFT JOIN academico_test.TUSUARIO ud
             ON ud.PK_TUSUARIO = fd.FK_TUSUARIO
     ORDER BY gr.NOMBRE, a.periodo_inicio, a.asignatura_nombre;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_cambios_pendientes(BIGINT, BIGINT[], BIGINT[])
    IS 'La alerta NARANJA del modulo de informes -- "docentes con cambios pendientes de aprobacion". Devuelve, en los grupos y periodos seleccionados, una fila por (grupo, asignatura, docente) con cuantos estudiantes quedaron afectados y cuando fue el ultimo cambio: el boton de la alerta muestra el total, el encabezado del panel cuenta los grupos distintos, y cada tarjeta lleva docente, asignatura, grupo y las tres FK que el boton "Ir" necesita para armar la ruta a la planilla. NO SALE DEL LISTADO por dos razones independientes: el grano es otro -- el listado es por (estudiante, periodo) y esto por (grupo, asignatura, docente) --, y el alcance tambien, porque la pantalla permite varios grupos en pestanas y la alerta habla de todos ellos mientras el listado es de uno solo; por eso p_fk_tgrupos es un ARREGLO, igual que en la alerta roja (V338). El cambio se detecta por COMPARACION, reutilizando fn_informe_estudiante_asignaturas con p_solo_cambios en vez de reimplementar la logica, de modo que la alerta no pueda decir 5 cambios mientras la tabla muestra 4; y solo cuentan las asignaturas YA CONSOLIDADAS, porque si el periodo nunca se guardo no hay nada que aprobar -- la nota simplemente aun no se congelo, que es el flujo normal y no una alerta. EL DOCENTE SALE DE TDOCENTE_ASIGNATURA, el asignado a esa asignatura en ese grupo. Una version anterior resolvia primero por TACTIVIDAD_NOTA.MODIFIED_BY (quien realmente digito) y solo caia a la asignacion si eso fallaba: era mas riguroso y peor, porque en la practica no califica actividades de una asignatura alguien distinto de su docente, asi que ese camino casi nunca aportaba algo distinto y a cambio metia una dependencia fragil -- MODIFIED_BY es VARCHAR sin FK donde otros procesos escriben migracion, V330 o un correo -- que obligaba a un JOIN defensivo con el guard dentro de un CASE para no reventar con 22P02. Ademas la alerta no existe para senalar culpables sino para LLEVAR A LA PLANILLA, y la planilla es de la asignatura: el destino correcto del boton siempre es el docente asignado. La FECHA del ultimo cambio si se sigue tomando de TACTIVIDAD_NOTA, porque no tiene sustituto y no depende de resolver a nadie. Gate: INFORMES/VER, verificado una vez por grupo y ANTES de leer nada -- un grupo fuera de alcance hace fallar toda la llamada con 42501 en vez de devolver una alerta incompleta que se ve completa.';
