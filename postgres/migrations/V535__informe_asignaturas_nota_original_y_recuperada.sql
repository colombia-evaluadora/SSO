-- ===========================================================================
-- V535 - Informes: la celda muestra la nota original (C) y la recuperada (R).
--
--   Regla 68: un informe que muestra la nota del periodo de una asignatura
--   con Habilitacion/Nivelacion (recuperacion con destino NOTA_FINAL) debe
--   mostrar las dos, original y resultante, aunque el promedio y la
--   aprobacion usen solo la resultante.
--
--   fn_actividad_recuperacion_consolidar_interno (del modulo de
--   recuperacion, no se toca) ya deja las dos en TASIGNATURA_NOTA:
--     CALIFICACION  = nota original del periodo (la base)
--     RECUPERACION  = nota de la actividad de recuperacion
--     DEFINITIVA    = la resultante segun REEMPLAZAR / COMPUTAR
--
--   Cambios en fn_informe_estudiante_asignaturas:
--     1) Cinco columnas al final: NOTA_ORIGINAL, su homologada, valoracion y
--        simbolo, y CON_RECUPERACION. Van al final y todos los llamadores
--        leen por nombre (o d.*), asi que ninguno cambia de comportamiento.
--     2) ESTADO_NOTA, con recuperacion, compara proyectada contra la ORIGINAL.
--        Antes la comparaba contra la definitiva y una asignatura recuperada
--        quedaba en "cambio_propuesto" para siempre.
--
--   Cambia el RETURNS TABLE, por eso DROP + CREATE (42P13), y se repone el
--   COMMENT. No hay dependencias duras ni GRANTs propios (ACL por defecto).
--
-- Depende de: V428 (ultimo cuerpo), V496.23 (proyectada sin recuperaciones).
-- ===========================================================================

DROP FUNCTION IF EXISTS academico_test.fn_informe_estudiante_asignaturas(BIGINT, BIGINT, BIGINT[], BOOLEAN);

CREATE OR REPLACE FUNCTION academico_test.fn_informe_estudiante_asignaturas(p_pk_usuario_solicitante bigint, p_fk_tmatricula bigint, p_fk_periodos_evaluacion bigint[], p_solo_cambios boolean DEFAULT false)
 RETURNS TABLE(fk_tasignatura bigint, asignatura_nombre character varying, area_nombre character varying, fk_tperiodo_evaluacion bigint, periodo_nombre character varying, periodo_inicio date, nota_guardada numeric, nota_proyectada numeric, estado_nota character varying, es_numerico boolean, nota_homologada numeric, nota_proyectada_homologada numeric, nota_maxima numeric, formato_valor character varying, valoracion_nombre character varying, valoracion_simbolo character varying, aprobada boolean, desempeno_minimo numeric, calificado_por character varying, calificado_en timestamp without time zone, nota_original numeric, nota_original_homologada numeric, nota_original_valoracion character varying, nota_original_simbolo character varying, con_recuperacion boolean)
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
               -- V535 -- Recuperacion con destino NOTA_FINAL (Regla 68). La
               -- escribe fn_actividad_recuperacion_consolidar_interno sobre esta
               -- misma fila: CALIFICACION queda como la nota original del
               -- periodo, RECUPERACION la de la actividad de recuperacion y
               -- DEFINITIVA la resultante. RECUPERACION no nula es la marca.
               (sn.RECUPERACION IS NOT NULL AND sn.DEFINITIVA IS NOT NULL) AS f_con_recup,
               CASE WHEN sn.RECUPERACION IS NOT NULL AND sn.DEFINITIVA IS NOT NULL
                    THEN sn.CALIFICACION END AS f_original,
               academico_test.fn_asignatura_definitiva_proyectada_periodo(
                   p_fk_tmatricula, asg.fk_tasignatura, p.pk) AS f_proyectada,
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
                   WHEN b.f_guardada IS NULL AND b.f_proyectada IS NULL THEN 'sin_nota'
                   WHEN b.f_guardada IS NULL                            THEN 'proyectada'
                   -- V535 -- La proyectada se recalcula desde las actividades y
                   -- excluye la de recuperacion (V496.23), asi que con una
                   -- recuperacion de NOTA_FINAL se compara contra la ORIGINAL,
                   -- no contra la definitiva: compararla con la definitiva la
                   -- dejaba en cambio_propuesto para siempre. Sin recuperacion
                   -- es identico a antes (proyectada NULL con guardada = cambio).
                   WHEN b.f_proyectada IS NOT DISTINCT FROM
                        CASE WHEN b.f_con_recup THEN b.f_original ELSE b.f_guardada END
                                                                        THEN 'guardada'
                   ELSE 'cambio_propuesto'
               END::VARCHAR AS f_estado,
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
           -- *** PARCHE V410 ***
           -- Del CRITERIO, no de homologar la nota: fn_nota_homologar devuelve
           -- todo NULL cuando no hay porcentaje, y eso hacia que una
           -- asignatura numerica sin nota saliera como cualitativa -- y con
           -- ella el periodo entero, confundiendolo con preescolar.
           COALESCE(fmt.es_numerico, FALSE),
           h.nota_homologada,
           hp.nota_homologada,
           fmt.nota_maxima,
           fmt.formato_valor,
           -- Estas SI dependen del valor: son la banda de la escala en la que
           -- cae la nota, y sin nota no existen.
           h.valoracion_nombre,
           h.valoracion_simbolo,
           CASE WHEN v_minimo IS NULL OR cal.f_visible IS NULL THEN NULL
                ELSE cal.f_visible >= v_minimo
           END,
           v_minimo,
           NULLIF(TRIM(CONCAT_WS(' ', uc.PRIMER_NOMBRE, uc.PRIMER_APELLIDO)), '')::VARCHAR,
           cal.f_cuando,
           -- V535 -- la nota original (C) solo viaja si hubo recuperacion de
           -- NOTA_FINAL; la R es NOTA_GUARDADA / NOTA_HOMOLOGADA de arriba.
           cal.f_original,
           ho.nota_homologada,
           ho.valoracion_nombre,
           ho.valoracion_simbolo,
           cal.f_con_recup
      FROM calificado cal
      JOIN academico_test.TASIGNATURA asg ON asg.PK_TASIGNATURA = cal.f_asig
      LEFT JOIN academico_test.TAREA are  ON are.PK_TAREA = asg.FK_TAREA
      LEFT JOIN academico_test.TAREA_ASIGNATURA ar
             ON ar.PK_TAREA_ASIGNATURA = are.FK_TAREA_ASIGNATURA
      -- V428 -- el tipo (numerico o cualitativo) sale de la cadena
      -- referente -> plan de estudio -> criterio, no solo del criterio. Las
      -- columnas se llaman igual, asi que el SELECT de abajo no cambia.
      LEFT JOIN LATERAL academico_test.fn_asignatura_tipo_evaluacion(
                    cal.f_asig, v_fk_grado) fmt ON TRUE
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                    cal.f_visible, cal.f_asig, v_fk_grado) h ON TRUE
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                    cal.f_proyectada, cal.f_asig, v_fk_grado) hp ON TRUE
      -- V535 -- el filtro constante evita homologar en las filas sin recuperacion.
      LEFT JOIN LATERAL (
                SELECT x.* FROM academico_test.fn_nota_homologar(
                    cal.f_original, cal.f_asig, v_fk_grado) x
                 WHERE cal.f_original IS NOT NULL) ho ON TRUE
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
    IS 'La grilla NUMERICA del informe para un estudiante: una fila por (asignatura, periodo de evaluacion) de los periodos pedidos (NULL o vacio = todos los del periodo academico de su matricula). Devuelve LAS DOS notas a la vez, que es lo que la vista necesita para pintar gris sobre negro: NOTA_GUARDADA es TASIGNATURA_NOTA.DEFINITIVA (el consolidado) y NOTA_PROYECTADA se recalcula siempre desde las actividades con fn_asignatura_definitiva_proyectada_periodo. Ya NO devuelve la observacion de la IA: la llevaba mientras el resumen era por asignatura, y al pasar a ser del estudiante y el periodo (V330) dejo de tener lugar en una grilla por asignatura -- vive en fn_informe_grupo_listar, donde el grano coincide. ESTADO_NOTA es el contrato con el front: sin_nota / proyectada (gris) / guardada (negro) / cambio_propuesto (negro + gris). cambio_propuesto es el docente que califico despues de consolidar el periodo, y por eso NO se creo ninguna tabla de "notas pendientes de aprobar": el docente nunca deja de escribir en TACTIVIDAD_NOTA, el consolidado esta en TASIGNATURA_NOTA, y la propuesta es la diferencia entre recalcular y lo guardado. INCLUYE UN CASO QUE ANTES SE ESCAPABA: si hay nota guardada y la proyectada pasa a NULL -- el docente dio de baja las actividades que la sustentaban -- eso tambien es cambio_propuesto, con NOTA_PROYECTADA en NULL y la propuesta siendo "ya no hay nota"; la version anterior lo reportaba como guardada y la bandera del listado no se encendia, de modo que el cambio pasaba en silencio. CALIFICADO_POR y CALIFICADO_EN dicen quien toco por ultima vez las notas de esa asignatura en ese periodo, desde TACTIVIDAD_NOTA.MODIFIED_BY/MODIFIED_AT; el join es defensivo porque MODIFIED_BY es VARCHAR sin FK y otros procesos escriben ahi valores que no son un id, asi que solo se resuelve cuando es numerico y la fecha se devuelve resuelva o no. p_solo_cambios reduce la salida a las filas con cambio propuesto. Lo cualitativo no se fuerza a numero: NOTA_HOMOLOGADA y la valoracion salen de fn_nota_homologar, que decide por (asignatura, grado) si el colegio califica con numero (CINCO/DIEZ/CIEN) o con valoracion (LITERAL/SIMBOLO/CARITA); ES_NUMERICO se devuelve explicito. APROBADA es NULL (desconocida) cuando el grado no tiene DESEMPENHO_MINIMO configurado, nunca FALSE. El universo de asignaturas son las que tienen nota guardada o actividades asignadas -- no el plan de estudios, que llenaria el boletin de filas vacias por configuracion incompleta. En preescolar devolvera filas en NULL o ninguna, y es correcto: alli el informe se arma con TESTUDIANTE_PERIODO_OBSERVACION. Gate: INFORMES/VER. V535: con una recuperacion de destino NOTA_FINAL (TASIGNATURA_NOTA.RECUPERACION no nula, Regla 68) devuelve ademas NOTA_ORIGINAL -- TASIGNATURA_NOTA.CALIFICACION, la nota del periodo antes de recuperar -- con su homologacion, valoracion y simbolo, y CON_RECUPERACION = TRUE; NOTA_GUARDADA sigue siendo la DEFINITIVA, o sea la resultante, que es la que promedia y aprueba. En ese caso ESTADO_NOTA compara la proyectada contra la ORIGINAL y no contra la definitiva: la proyectada excluye la actividad de recuperacion (V496.23), asi que compararla contra la resultante la dejaba en cambio_propuesto para siempre. Sin recuperacion el estado es identico al anterior.';
