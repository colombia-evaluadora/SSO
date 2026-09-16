-- ===========================================================================
-- V337 - fn_informe_cambios_pendientes: la alerta naranja.
--        "Docentes con cambios pendientes de aprobacion".
--
-- QUE RESPONDE
--   En los grupos y periodos que el usuario tiene seleccionados, quien cambio
--   notas DESPUES de que el periodo se consolidara. Una fila por
--   (grupo, asignatura, docente), con cuantos estudiantes quedaron afectados
--   y cuando fue el ultimo cambio.
--
--   Es lo que alimenta el panel: el boton muestra el total de cambios, el
--   encabezado del panel cuenta los GRUPOS distintos, y cada tarjeta lleva
--   nombre del docente, asignatura, grupo y el boton "Ir" a su planilla --
--   para lo cual necesita las tres FK, no solo los nombres.
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
--      "601 M", "602 M" -- y la alerta habla de todos ellos ("en los grupos
--      seleccionados"). El listado es de UN grupo. El front tendria que
--      llamarlo N veces y sumar, y ademas traerse todas las notas de todos
--      los estudiantes para contar unos pocos cambios.
--
--   Por eso recibe p_fk_tgrupos como ARREGLO. La alerta roja -- docentes que
--   no han registrado ninguna calificacion -- tendra esta misma firma, para
--   que el front trate las dos igual.
--
--
-- COMO SE DETECTA UN CAMBIO
--   Igual que en el listado, por COMPARACION y no por registro: se recalcula
--   la proyeccion de cada (estudiante, asignatura, periodo) y se compara
--   contra TASIGNATURA_NOTA.DEFINITIVA. Si difieren -- o si hay guardada y la
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
-- DE DONDE SALE EL DOCENTE
--   De TACTIVIDAD_NOTA.MODIFIED_BY, que guarda el PK_TUSUARIO de quien
--   califico (fn_actividad_nota_* escribe p_pk_usuario_solicitante::VARCHAR).
--   Es quien REALMENTE digito, que es a quien hay que ir a buscar -- no quien
--   figura asignado a la asignatura en TDOCENTE_ASIGNATURA, que puede ser
--   otra persona.
--
--   Si no se resuelve a un usuario se cae a TDOCENTE_ASIGNATURA, que responde
--   "de quien es esta asignatura en este grupo". Con eso la tarjeta siempre
--   tiene a quien mostrar y el boton "Ir" siempre tiene destino; si tampoco
--   hay, el nombre viaja NULL y el front decide.
--
--   El JOIN a TUSUARIO es DEFENSIVO y va dentro de un CASE, no como un AND
--   previo: MODIFIED_BY es VARCHAR sin FK y otros procesos escriben ahi
--   valores que no son un id ('migracion', 'V330', un correo). En un AND el
--   planificador puede evaluar el cast antes que la expresion regular y
--   reventar la consulta entera con 22P02.
--
--
-- PERMISOS
--   INFORMES/VER, verificado UNA VEZ POR GRUPO. Un grupo al que el usuario no
--   alcanza hace fallar toda la llamada con 42501 en vez de devolver el resto
--   en silencio: la alerta dice "en los grupos seleccionados" y una respuesta
--   incompleta que se ve completa es peor que un error.
--
-- Idempotente: CREATE OR REPLACE. Funcion nueva, sin sobrecarga previa.
-- ===========================================================================


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
    fk_tfuncionario        BIGINT,
    fk_tusuario_docente    BIGINT,
    docente                VARCHAR,
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

    -- Gate por grupo. Se valida ANTES de leer nada: si a uno no se alcanza,
    -- la llamada entera falla en vez de devolver una alerta incompleta que se
    -- ve completa.
    FOR r_g IN
        SELECT UNNEST(p_fk_tgrupos) AS pk
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
               mt.pk           AS matricula,
               d.calificado_por,
               d.calificado_en
          FROM matriculas mt
          CROSS JOIN LATERAL academico_test.fn_informe_estudiante_asignaturas(
                         p_pk_usuario_solicitante, mt.pk,
                         p_fk_periodos_evaluacion, TRUE) d
    ),
    -- Quien digito, resuelto desde TACTIVIDAD_NOTA. Se toma el mas reciente
    -- de cada (grupo, asignatura).
    ultimo AS (
        SELECT c.grupo,
               c.fk_tasignatura,
               c.asignatura_nombre,
               COUNT(DISTINCT c.matricula) AS afectados,
               MAX(c.calificado_en)        AS cuando,
               (ARRAY_AGG(c.calificado_por
                          ORDER BY c.calificado_en DESC NULLS LAST))[1] AS quien
          FROM cambios c
         GROUP BY c.grupo, c.fk_tasignatura, c.asignatura_nombre
    )
    SELECT u.grupo,
           gr.NOMBRE,
           u.fk_tasignatura,
           u.asignatura_nombre,
           -- El funcionario: el que digito si se pudo resolver, y si no el
           -- que tiene asignada la asignatura en ese grupo.
           COALESCE(fdig.PK_TFUNCIONARIO, da.FK_TFUNCIONARIO),
           COALESCE(udig.PK_TUSUARIO, uasig.PK_TUSUARIO),
           NULLIF(TRIM(CONCAT_WS(' ',
               COALESCE(udig.PRIMER_NOMBRE,   uasig.PRIMER_NOMBRE),
               COALESCE(udig.PRIMER_APELLIDO, uasig.PRIMER_APELLIDO))), '')::VARCHAR,
           u.afectados,
           u.cuando
      FROM ultimo u
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = u.grupo
      -- JOIN defensivo: el guard va DENTRO del CASE. En un AND el
      -- planificador puede evaluar el cast antes que la regex y reventar con
      -- 22P02 en cuanto aparezca un MODIFIED_BY no numerico.
      LEFT JOIN academico_test.TUSUARIO udig
             ON udig.PK_TUSUARIO = CASE
                                       WHEN u.quien ~ '^[0-9]+$'
                                       THEN u.quien::BIGINT
                                   END
      LEFT JOIN academico_test.TFUNCIONARIO fdig
             ON fdig.FK_TUSUARIO = udig.PK_TUSUARIO
            AND fdig.ACTIVE = TRUE
      -- Respaldo: de quien es esta asignatura en este grupo.
      LEFT JOIN LATERAL (
            SELECT dax.FK_TFUNCIONARIO
              FROM academico_test.TDOCENTE_ASIGNATURA dax
             WHERE dax.FK_TGRUPO      = u.grupo
               AND dax.FK_TASIGNATURA = u.fk_tasignatura
               AND dax.ACTIVE = TRUE
             ORDER BY dax.PK_TDOCENTE_ASIGNATURA DESC
             LIMIT 1
      ) da ON TRUE
      LEFT JOIN academico_test.TFUNCIONARIO fasig
             ON fasig.PK_TFUNCIONARIO = da.FK_TFUNCIONARIO
      LEFT JOIN academico_test.TUSUARIO uasig
             ON uasig.PK_TUSUARIO = fasig.FK_TUSUARIO
     ORDER BY gr.NOMBRE, u.asignatura_nombre;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_cambios_pendientes(BIGINT, BIGINT[], BIGINT[])
    IS 'La alerta naranja del modulo de informes -- "docentes con cambios pendientes de aprobacion". Devuelve, en los grupos y periodos seleccionados, una fila por (grupo, asignatura, docente) con cuantos estudiantes quedaron afectados y cuando fue el ultimo cambio: el boton de la alerta muestra el total, el encabezado del panel cuenta los grupos distintos, y cada tarjeta lleva docente, asignatura, grupo y las tres FK que el boton "Ir" necesita para armar la ruta a la planilla. NO SALE DEL LISTADO por dos razones independientes: el grano es otro -- el listado es por (estudiante, periodo) y esto por (grupo, asignatura, docente), asi que el front tendria que reagrupar a mano lo que una consulta hace mejor --, y el alcance es otro: la pantalla permite varios grupos en pestanas y la alerta habla de todos ellos, mientras el listado es de uno solo. Por eso recibe p_fk_tgrupos como ARREGLO, y la alerta roja (docentes que no han registrado ninguna calificacion) tendra esta misma firma para que el front trate las dos igual. El cambio se detecta por COMPARACION, reutilizando fn_informe_estudiante_asignaturas con p_solo_cambios en vez de reimplementar la logica, de modo que la alerta no pueda decir 5 cambios mientras la tabla muestra 4; y solo cuentan las asignaturas YA CONSOLIDADAS, porque si el periodo nunca se guardo no hay nada que aprobar -- la nota simplemente aun no se congelo, que es el flujo normal y no una alerta. El docente sale de TACTIVIDAD_NOTA.MODIFIED_BY, que es quien REALMENTE digito y a quien hay que ir a buscar, no quien figura asignado en TDOCENTE_ASIGNATURA, que puede ser otra persona; si no se resuelve se cae a esa asignacion, de modo que la tarjeta siempre tenga a quien mostrar y el boton "Ir" siempre tenga destino. El join a TUSUARIO es defensivo y el guard va dentro de un CASE y no como un AND previo: MODIFIED_BY es VARCHAR sin FK y en un AND el planificador puede evaluar el cast antes que la regex y reventar con 22P02. Gate: INFORMES/VER, verificado una vez por grupo y ANTES de leer nada -- un grupo fuera de alcance hace fallar toda la llamada con 42501 en vez de devolver una alerta incompleta que se ve completa.';
