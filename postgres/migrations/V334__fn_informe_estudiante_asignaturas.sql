-- ===========================================================================
-- V334 - El detalle del informe: que tiene cada estudiante en cada asignatura
--        y cada periodo seleccionado.
--
--   fn_grado_desempeno_minimo          umbral de aprobacion del grado
--   fn_informe_estudiante_asignaturas  la grilla del estudiante
--
--
-- (1) EL UMBRAL DE APROBACION
--   Sale de TCRITERIO_PROMOCION.DESEMPENHO_MINIMO, que V22 documenta como
--   "Porcentaje minimo por area o asignatura para la aprobacion por
--   promedio". Es un PORCENTAJE, asi que se compara directo contra la nota
--   proyectada, que tambien lo es. No hay que homologar para decidir si algo
--   esta aprobado.
--
--   Resolucion: primero la fila del GRADO exacto, si no la fila POR_DEFECTO
--   del mismo periodo academico. Mismo escalonado que
--   fn_asignatura_criterio_evaluacion_vigente.
--
--   OJO CON LOS DATOS: de las 742 filas activas, 425 tienen DESEMPENHO_MINIMO
--   en NULL y unas pocas traen 1 o 2, que parecen capturadas en escala 0-5.
--   Cuando el umbral no se puede resolver esta funcion devuelve NULL y quien
--   la use debe tratar "aprobada" como DESCONOCIDA, no como falsa: inventar
--   un 60 por defecto reprobaria gente por una configuracion que el colegio
--   nunca hizo.
--
--
-- (2) LA GRILLA -- SOLO EL MUNDO NUMERICO
--   Una fila por (asignatura, periodo de evaluacion), con las DOS notas a la
--   vez, que es lo que la vista necesita para pintar gris sobre negro:
--
--     GUARDADA    TASIGNATURA_NOTA.DEFINITIVA -- el consolidado, el "negro".
--     PROYECTADA  fn_asignatura_definitiva_proyectada_periodo -- el "gris",
--                 recalculado siempre desde las actividades.
--
--   Esta funcion ya NO devuelve la observacion de la IA. La llevaba mientras
--   el resumen era por asignatura; al pasar a ser del ESTUDIANTE y el periodo
--   (V330) dejo de tener lugar en una grilla por asignatura, y vive en
--   fn_informe_grupo_listar, que es donde el grano coincide.
--
--
-- (3) ESTADO_NOTA, EL CONTRATO CON EL FRONT
--     sin_nota          no hay ninguna de las dos.
--     proyectada        hay proyectada y no se ha guardado nunca (gris).
--     guardada          hay guardada y la proyectada coincide (negro).
--     cambio_propuesto  hay guardada y la proyectada DIFIERE (negro + gris).
--
--   'cambio_propuesto' es exactamente el caso del docente que califica
--   despues de que el periodo se consolido. No hace falta ninguna tabla para
--   detectarlo -- y por eso no se creo: el docente nunca deja de escribir en
--   TACTIVIDAD_NOTA, el consolidado esta en TASIGNATURA_NOTA, y la propuesta
--   es la diferencia entre recalcular y lo guardado. Una tabla de "notas
--   pendientes de aprobar" seria un tercer lugar donde la misma verdad podria
--   desincronizarse.
--
--   OJO CON UN CASO QUE ANTES SE ESCAPABA: si hay nota guardada y la
--   proyectada pasa a ser NULL -- el docente dio de baja las actividades que
--   la sustentaban -- eso TAMBIEN es un cambio propuesto, y la propuesta es
--   "ya no hay nota". La version anterior lo reportaba como 'guardada' y la
--   bandera del listado no se encendia, asi que el cambio pasaba
--   silenciosamente. Ahora cae en 'cambio_propuesto' con NOTA_PROYECTADA en
--   NULL.
--
--   Se distingue de 'sin_nota' porque alli tampoco hay guardada: nunca hubo
--   nada, que es distinto de "habia y ya no".
--
--
-- (4) QUIEN PROPUSO EL CAMBIO
--   Cuando hay cambio propuesto interesa saber quien lo hizo y cuando.
--   TACTIVIDAD_NOTA.MODIFIED_BY guarda el PK_TUSUARIO de quien califico
--   (fn_actividad_nota_* escribe p_pk_usuario_solicitante::VARCHAR) y
--   MODIFIED_AT cuando. Se toma la mas reciente de la asignatura en el
--   periodo.
--
--   El JOIN es DEFENSIVO: MODIFIED_BY es un VARCHAR sin FK, y otros procesos
--   escriben ahi cosas que no son un id ('migracion', 'V330', un correo). Se
--   intenta resolver solo cuando el valor es numerico, y si no resuelve se
--   devuelve NULL en el nombre pero SI la fecha, que sigue siendo util.
--
--
-- (5) LO CUALITATIVO NO SE FUERZA A NUMERO
--   NOTA_HOMOLOGADA y la valoracion salen de fn_nota_homologar, que ya decide
--   por (asignatura, grado) si ese colegio califica con numero -- formatos
--   CINCO/DIEZ/CIEN -- o con valoracion -- LITERAL/SIMBOLO/CARITA. Cuando no
--   es numerico NOTA_HOMOLOGADA viene NULL y lo que vale es
--   VALORACION_NOMBRE. ES_NUMERICO se devuelve explicito para que el front no
--   tenga que deducirlo del formato.
--
--
-- (6) QUE ASIGNATURAS APARECEN
--   Las que tienen nota guardada o actividades asignadas al estudiante en los
--   periodos pedidos: aquello de lo que hay ALGO numerico que informar.
--
--   No se parte del plan de estudios (TASIGNATURA_PLAN) a proposito: eso
--   mostraria asignaturas vacias por configuracion incompleta y llenaria el
--   boletin de filas sin contenido. Si hace falta el plan completo, es un
--   LEFT JOIN desde el plan contra esta funcion, no al reves.
--
--   En preescolar esto normalmente devolvera filas con todo en NULL, o
--   ninguna. Es lo correcto: alli el informe no se arma con esta funcion sino
--   con el resumen de TESTUDIANTE_PERIODO_OBSERVACION.
--
-- Idempotente: CREATE OR REPLACE. DROP previo porque cambia el RETURNS TABLE.
-- ===========================================================================


-- El RETURNS TABLE cambia (se van tres columnas de observacion, entran dos de
-- autoria), y CREATE OR REPLACE no puede cambiar el tipo de retorno.
DROP FUNCTION IF EXISTS academico_test.fn_informe_estudiante_asignaturas(BIGINT, BIGINT, BIGINT[], BOOLEAN);


-- ---------------------------------------------------------------------------
-- 1. Umbral de aprobacion del grado.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_grado_desempeno_minimo(
    p_fk_tgrado BIGINT
)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $function$
    SELECT cp.DESEMPENHO_MINIMO
      FROM academico_test.TGRADO g
      JOIN academico_test.TCRITERIO_PROMOCION cp
        ON cp.ACTIVE = TRUE
       AND cp.DESEMPENHO_MINIMO IS NOT NULL
       AND (cp.FK_TGRADO = g.PK_TGRADO
            OR (cp.POR_DEFECTO = 'S'
                AND cp.FK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO))
     WHERE g.PK_TGRADO = p_fk_tgrado
     -- El override del grado exacto antes que la fila por defecto. FALSE
     -- ordena antes que TRUE, asi que "no es del grado" cae al final.
     ORDER BY (cp.FK_TGRADO IS DISTINCT FROM g.PK_TGRADO),
              cp.PK_TCRITERIO_PROMOCION DESC
     LIMIT 1;
$function$;

COMMENT ON FUNCTION academico_test.fn_grado_desempeno_minimo(BIGINT)
    IS 'Porcentaje minimo para dar por aprobada una asignatura en un grado, desde TCRITERIO_PROMOCION.DESEMPENHO_MINIMO ("Porcentaje minimo por area o asignatura", V22). Es un PORCENTAJE, asi que se compara directo contra la nota proyectada sin homologar. Resuelve primero la fila del grado exacto y si no la fila POR_DEFECTO del mismo periodo academico, el mismo escalonado de fn_asignatura_criterio_evaluacion_vigente. Devuelve NULL cuando el colegio no lo configuro -- 425 de las 742 filas activas lo tienen en NULL -- y en ese caso "aprobada" debe tratarse como DESCONOCIDA, no como falsa: inventar un 60 por defecto reprobaria gente por una configuracion que nadie hizo.';


-- ---------------------------------------------------------------------------
-- 2. La grilla del estudiante.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_estudiante_asignaturas(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tmatricula          BIGINT,
    p_fk_periodos_evaluacion BIGINT[],
    p_solo_cambios           BOOLEAN DEFAULT FALSE
)
RETURNS TABLE(
    fk_tasignatura          BIGINT,
    asignatura_nombre       VARCHAR,
    area_nombre             VARCHAR,
    fk_tperiodo_evaluacion  BIGINT,
    periodo_nombre          VARCHAR,
    periodo_inicio          DATE,
    nota_guardada           NUMERIC,
    nota_proyectada         NUMERIC,
    estado_nota             VARCHAR,
    es_numerico             BOOLEAN,
    nota_homologada         NUMERIC,
    nota_proyectada_homologada NUMERIC,
    nota_maxima             NUMERIC,
    formato_valor           VARCHAR,
    valoracion_nombre       VARCHAR,
    valoracion_simbolo      VARCHAR,
    aprobada                BOOLEAN,
    desempeno_minimo        NUMERIC,
    calificado_por          VARCHAR,
    calificado_en           TIMESTAMP
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_fk_grado   BIGINT;
    v_fk_peraca  BIGINT;
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
    v_minimo     NUMERIC;
BEGIN
    SELECT gd.PK_TGRADO, gd.FK_TPERIODO_ACADEMICO,
           s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO
      INTO v_fk_grado, v_fk_peraca, v_fk_sede, v_fk_jornada, v_fk_ee
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE m.PK_TMATRICULA = p_fk_tmatricula
       AND m.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la matricula solicitada'
            USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

    v_minimo := academico_test.fn_grado_desempeno_minimo(v_fk_grado);

    RETURN QUERY
    WITH periodos AS (
        -- Solo periodos del MISMO periodo academico de la matricula. Un
        -- periodo de otro ano o de otra sede no tiene nada que decir sobre
        -- este estudiante y colarlo produciria filas fantasma.
        SELECT pe.PK_TPERIODO_EVALUACION AS pk,
               pe.NOMBRE                 AS nombre,
               pe.FECHA_INICIO           AS inicio
          FROM academico_test.TPERIODO_EVALUACION pe
         WHERE pe.ACTIVE = TRUE
           AND pe.FK_TPERIODO_ACADEMICO = v_fk_peraca
           AND (p_fk_periodos_evaluacion IS NULL
                OR CARDINALITY(p_fk_periodos_evaluacion) = 0
                OR pe.PK_TPERIODO_EVALUACION = ANY (p_fk_periodos_evaluacion))
    ),
    -- (6) El universo: de lo que hay ALGO numerico que informar.
    asignaturas AS (
        SELECT DISTINCT x.fk_tasignatura
          FROM (
                SELECT sn.FK_TASIGNATURA
                  FROM academico_test.TASIGNATURA_NOTA sn
                  JOIN periodos p ON p.pk = sn.FK_TPERIODO_EVALUACION
                 WHERE sn.FK_TMATRICULA = p_fk_tmatricula AND sn.ACTIVE = TRUE
                UNION
                SELECT a.FK_TASIGNATURA
                  FROM academico_test.TACTIVIDAD a
                  JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
                    ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
                   AND ae.FK_TMATRICULA = p_fk_tmatricula
                   AND ae.ACTIVE = TRUE
                  JOIN periodos p
                    ON academico_test.fn_actividad_en_periodo_eval(a.PK_TACTIVIDAD, p.pk) = TRUE
                 WHERE a.ACTIVE = TRUE
               ) x(fk_tasignatura)
    ),
    base AS (
        SELECT asg.fk_tasignatura AS f_asig,
               p.pk               AS f_pe,
               p.nombre           AS f_pe_nombre,
               p.inicio           AS f_pe_inicio,
               sn.DEFINITIVA      AS f_guardada,
               academico_test.fn_asignatura_definitiva_proyectada_periodo(
                   p_fk_tmatricula, asg.fk_tasignatura, p.pk) AS f_proyectada,
               -- (4) Quien califico por ultima vez esta asignatura en este
               -- periodo. MODIFIED_BY es VARCHAR sin FK: se resuelve mas
               -- abajo solo si es numerico, y la fecha vale igual.
               ult.quien  AS f_quien,
               ult.cuando AS f_cuando
          FROM asignaturas asg
          CROSS JOIN periodos p
          LEFT JOIN academico_test.TASIGNATURA_NOTA sn
                 ON sn.FK_TMATRICULA          = p_fk_tmatricula
                AND sn.FK_TASIGNATURA         = asg.fk_tasignatura
                AND sn.FK_TPERIODO_EVALUACION = p.pk
                AND sn.ACTIVE = TRUE
          LEFT JOIN LATERAL (
                SELECT COALESCE(n.MODIFIED_BY, n.CREATED_BY) AS quien,
                       COALESCE(n.MODIFIED_AT, n.CREATED_AT) AS cuando
                  FROM academico_test.TACTIVIDAD a3
                  JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae3
                    ON ae3.FK_TACTIVIDAD = a3.PK_TACTIVIDAD
                   AND ae3.FK_TMATRICULA = p_fk_tmatricula
                   AND ae3.ACTIVE = TRUE
                  JOIN academico_test.TACTIVIDAD_NOTA n
                    ON n.FK_TACTIVIDAD_ESTUDIANTE = ae3.PK_TACTIVIDAD_ESTUDIANTE
                   AND n.ACTIVE = TRUE
                 WHERE a3.ACTIVE = TRUE
                   AND a3.FK_TASIGNATURA = asg.fk_tasignatura
                   AND academico_test.fn_actividad_en_periodo_eval(a3.PK_TACTIVIDAD, p.pk) = TRUE
                 ORDER BY COALESCE(n.MODIFIED_AT, n.CREATED_AT) DESC
                 LIMIT 1
          ) ult ON TRUE
    ),
    calificado AS (
        SELECT b.*,
               CASE
                   -- Nunca hubo nada.
                   WHEN b.f_guardada IS NULL AND b.f_proyectada IS NULL THEN 'sin_nota'
                   -- Hay proyeccion y nunca se consolido.
                   WHEN b.f_guardada IS NULL                            THEN 'proyectada'
                   -- (3) Habia y ya no: el docente dio de baja lo que la
                   -- sustentaba. Tambien es propuesta -- "ya no hay nota".
                   WHEN b.f_proyectada IS NULL                          THEN 'cambio_propuesto'
                   WHEN b.f_proyectada = b.f_guardada                   THEN 'guardada'
                   ELSE 'cambio_propuesto'
               END::VARCHAR AS f_estado,
               -- Lo que se muestra: manda lo guardado, y si no hay, la
               -- proyeccion. Se homologa siempre el mismo valor que se pinta.
               COALESCE(b.f_guardada, b.f_proyectada) AS f_visible
          FROM base b
    )
    SELECT cal.f_asig,
           asg.NOMBRE,
           ar.NOMBRE,
           cal.f_pe,
           cal.f_pe_nombre,
           cal.f_pe_inicio,
           cal.f_guardada,
           cal.f_proyectada,
           cal.f_estado,
           COALESCE(h.formato_valor IN ('CINCO', 'DIEZ', 'CIEN'), FALSE),
           h.nota_homologada,
           -- La proyectada TAMBIEN homologada. Sin esto el front no puede
           -- pintar "2,5 / 2,3": tendria la guardada en la escala del colegio
           -- y la proyectada en porcentaje, que no se comparan entre si. Y es
           -- lo que permite que la flecha de subida/bajada se decida sobre lo
           -- que se DIBUJA: si dos porcentajes distintos redondean a la misma
           -- nota, no debe salir flecha.
           hp.nota_homologada,
           h.nota_maxima,
           h.formato_valor,
           h.valoracion_nombre,
           h.valoracion_simbolo,
           -- (1) Sin umbral configurado la aprobacion es DESCONOCIDA (NULL),
           -- no falsa. Sin nota visible, tampoco hay nada que juzgar.
           CASE WHEN v_minimo IS NULL OR cal.f_visible IS NULL THEN NULL
                ELSE cal.f_visible >= v_minimo
           END,
           v_minimo,
           NULLIF(TRIM(CONCAT_WS(' ', uc.PRIMER_NOMBRE, uc.PRIMER_APELLIDO)), '')::VARCHAR,
           cal.f_cuando
      FROM calificado cal
      JOIN academico_test.TASIGNATURA asg ON asg.PK_TASIGNATURA = cal.f_asig
      LEFT JOIN academico_test.TAREA are  ON are.PK_TAREA = asg.FK_TAREA
      LEFT JOIN academico_test.TAREA_ASIGNATURA ar
             ON ar.PK_TAREA_ASIGNATURA = are.FK_TAREA_ASIGNATURA
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                    cal.f_visible, cal.f_asig, v_fk_grado) h ON TRUE
      -- Segunda homologacion, solo para la proyectada. Se llama aparte y no
      -- se reutiliza h porque homologan valores distintos: h convierte lo que
      -- se muestra, esta convierte lo que se propone.
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                    cal.f_proyectada, cal.f_asig, v_fk_grado) hp ON TRUE
      -- (4) JOIN defensivo. El guard va DENTRO de un CASE y no como un AND
      -- previo: en un AND el planificador puede evaluar el cast antes que la
      -- expresion regular, y entonces un MODIFIED_BY no numerico -- que los
      -- hay: 'migracion', 'V330', correos -- revienta la consulta entera con
      -- 22P02. El CASE si garantiza el orden, y devuelve NULL en vez de
      -- fallar, que es lo que este LEFT JOIN necesita.
      LEFT JOIN academico_test.TUSUARIO uc
             ON uc.PK_TUSUARIO = CASE
                                     WHEN cal.f_quien ~ '^[0-9]+$'
                                     THEN cal.f_quien::BIGINT
                                 END
     WHERE NOT COALESCE(p_solo_cambios, FALSE)
        OR cal.f_estado = 'cambio_propuesto'
     ORDER BY cal.f_pe_inicio, ar.NOMBRE NULLS LAST, asg.NOMBRE, cal.f_asig;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_estudiante_asignaturas(BIGINT, BIGINT, BIGINT[], BOOLEAN)
    IS 'La grilla NUMERICA del informe para un estudiante: una fila por (asignatura, periodo de evaluacion) de los periodos pedidos (NULL o vacio = todos los del periodo academico de su matricula). Devuelve LAS DOS notas a la vez, que es lo que la vista necesita para pintar gris sobre negro: NOTA_GUARDADA es TASIGNATURA_NOTA.DEFINITIVA (el consolidado) y NOTA_PROYECTADA se recalcula siempre desde las actividades con fn_asignatura_definitiva_proyectada_periodo. Ya NO devuelve la observacion de la IA: la llevaba mientras el resumen era por asignatura, y al pasar a ser del estudiante y el periodo (V330) dejo de tener lugar en una grilla por asignatura -- vive en fn_informe_grupo_listar, donde el grano coincide. ESTADO_NOTA es el contrato con el front: sin_nota / proyectada (gris) / guardada (negro) / cambio_propuesto (negro + gris). cambio_propuesto es el docente que califico despues de consolidar el periodo, y por eso NO se creo ninguna tabla de "notas pendientes de aprobar": el docente nunca deja de escribir en TACTIVIDAD_NOTA, el consolidado esta en TASIGNATURA_NOTA, y la propuesta es la diferencia entre recalcular y lo guardado. INCLUYE UN CASO QUE ANTES SE ESCAPABA: si hay nota guardada y la proyectada pasa a NULL -- el docente dio de baja las actividades que la sustentaban -- eso tambien es cambio_propuesto, con NOTA_PROYECTADA en NULL y la propuesta siendo "ya no hay nota"; la version anterior lo reportaba como guardada y la bandera del listado no se encendia, de modo que el cambio pasaba en silencio. CALIFICADO_POR y CALIFICADO_EN dicen quien toco por ultima vez las notas de esa asignatura en ese periodo, desde TACTIVIDAD_NOTA.MODIFIED_BY/MODIFIED_AT; el join es defensivo porque MODIFIED_BY es VARCHAR sin FK y otros procesos escriben ahi valores que no son un id, asi que solo se resuelve cuando es numerico y la fecha se devuelve resuelva o no. p_solo_cambios reduce la salida a las filas con cambio propuesto. Lo cualitativo no se fuerza a numero: NOTA_HOMOLOGADA y la valoracion salen de fn_nota_homologar, que decide por (asignatura, grado) si el colegio califica con numero (CINCO/DIEZ/CIEN) o con valoracion (LITERAL/SIMBOLO/CARITA); ES_NUMERICO se devuelve explicito. APROBADA es NULL (desconocida) cuando el grado no tiene DESEMPENHO_MINIMO configurado, nunca FALSE. El universo de asignaturas son las que tienen nota guardada o actividades asignadas -- no el plan de estudios, que llenaria el boletin de filas vacias por configuracion incompleta. En preescolar devolvera filas en NULL o ninguna, y es correcto: alli el informe se arma con TESTUDIANTE_PERIODO_OBSERVACION. Gate: INFORMES/VER.';
