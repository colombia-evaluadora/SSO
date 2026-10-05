-- V536 — Informes por capas (2 de 4): núcleos _interno, sin permisos.
--
-- Qué hace: la lógica reutilizable de informes, sin gate: detalle por
-- asignatura, nota requerida, métricas, historial, el listado de grupo, el
-- lazo de los dos guardados y la escritura única de la nota del periodo, que
-- con una Habilitación (Regla 68) guarda la base y recombina la definitiva con
-- el módulo de recuperación. Los que se renombran a _interno se dropean con su
-- nombre viejo: solo los usaba informes.
-- Por qué aquí: estructura por capas; un cambio futuro edita esta migración.
-- Depende de: V535, V496.19 (fn_actividad_recuperacion_consolidar_interno), V496.24.

-- Los nucleos se renombran a _interno; nadie fuera de informes los llamaba.
DROP FUNCTION IF EXISTS academico_test.fn_informe_estudiante_asignaturas(BIGINT, BIGINT, BIGINT[], BOOLEAN);
DROP FUNCTION IF EXISTS academico_test.fn_informe_periodo_requerido(BIGINT, BIGINT, BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_informe_metricas_recalcular(BIGINT, BIGINT, BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_informe_historial_registrar(BIGINT, BIGINT, BIGINT, BIGINT, CHARACTER VARYING, JSONB);

CREATE OR REPLACE FUNCTION academico_test.fn_informe_estudiante_asignaturas_interno(p_fk_tmatricula bigint, p_fk_periodos_evaluacion bigint[], p_solo_cambios boolean DEFAULT false)
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
               -- Habilitacion (Regla 68): CALIFICACION es la original, DEFINITIVA
               -- la resultante; RECUPERACION no nula es la marca.
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
                   -- La proyectada excluye la actividad de recuperacion, asi que con
                   -- recuperacion se compara contra la original, no la resultante.
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
COMMENT ON FUNCTION academico_test.fn_informe_estudiante_asignaturas_interno(BIGINT, BIGINT[], BOOLEAN)
    IS 'INTERNO: La grilla NUMERICA del informe para un estudiante: una fila por (asignatura, periodo de evaluacion) de los periodos pedidos (NULL o vacio = todos los del periodo academico de su matricula). Devuelve LAS DOS notas a la vez, que es lo que la vista necesita para pintar gris sobre negro: NOTA_GUARDADA es TASIGNATURA_NOTA.DEFINITIVA (el consolidado) y NOTA_PROYECTADA se recalcula siempre desde las actividades con fn_asignatura_definitiva_proyectada_periodo. Ya NO devuelve la observacion de la IA: la llevaba mientras el resumen era por asignatura, y al pasar a ser del estudiante y el periodo (V330) dejo de tener lugar en una grilla por asignatura -- vive en fn_informe_grupo_listar, donde el grano coincide. ESTADO_NOTA es el contrato con el front: sin_nota / proyectada (gris) / guardada (negro) / cambio_propuesto (negro + gris). cambio_propuesto es el docente que califico despues de consolidar el periodo, y por eso NO se creo ninguna tabla de "notas pendientes de aprobar": el docente nunca deja de escribir en TACTIVIDAD_NOTA, el consolidado esta en TASIGNATURA_NOTA, y la propuesta es la diferencia entre recalcular y lo guardado. INCLUYE UN CASO QUE ANTES SE ESCAPABA: si hay nota guardada y la proyectada pasa a NULL -- el docente dio de baja las actividades que la sustentaban -- eso tambien es cambio_propuesto, con NOTA_PROYECTADA en NULL y la propuesta siendo "ya no hay nota"; la version anterior lo reportaba como guardada y la bandera del listado no se encendia, de modo que el cambio pasaba en silencio. CALIFICADO_POR y CALIFICADO_EN dicen quien toco por ultima vez las notas de esa asignatura en ese periodo, desde TACTIVIDAD_NOTA.MODIFIED_BY/MODIFIED_AT; el join es defensivo porque MODIFIED_BY es VARCHAR sin FK y otros procesos escriben ahi valores que no son un id, asi que solo se resuelve cuando es numerico y la fecha se devuelve resuelva o no. p_solo_cambios reduce la salida a las filas con cambio propuesto. Lo cualitativo no se fuerza a numero: NOTA_HOMOLOGADA y la valoracion salen de fn_nota_homologar, que decide por (asignatura, grado) si el colegio califica con numero (CINCO/DIEZ/CIEN) o con valoracion (LITERAL/SIMBOLO/CARITA); ES_NUMERICO se devuelve explicito. APROBADA es NULL (desconocida) cuando el grado no tiene DESEMPENHO_MINIMO configurado, nunca FALSE. El universo de asignaturas son las que tienen nota guardada o actividades asignadas -- no el plan de estudios, que llenaria el boletin de filas vacias por configuracion incompleta. En preescolar devolvera filas en NULL o ninguna, y es correcto: alli el informe se arma con TESTUDIANTE_PERIODO_OBSERVACION. Con una recuperacion de destino NOTA_FINAL (TASIGNATURA_NOTA.RECUPERACION no nula, Regla 68) devuelve ademas NOTA_ORIGINAL (CALIFICACION, la nota antes de recuperar) con su homologacion, valoracion y simbolo, y CON_RECUPERACION; NOTA_GUARDADA sigue siendo la DEFINITIVA resultante, la que promedia y aprueba, y ESTADO_NOTA compara la proyectada contra la original. Sin gate: lo aplican fn_informe_grupo_listar, fn_informe_cambios_pendientes y los guardados; la reutilizan tambien fn_informe_periodo_requerido_interno y fn_informe_metricas_recalcular_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_periodo_requerido_interno(p_fk_tmatricula bigint, p_fk_tperiodo_evaluacion bigint)
 RETURNS TABLE(fk_tasignatura bigint, asignatura_nombre character varying, abreviacion character varying, area_nombre character varying, orden_reporte numeric, requerido numeric, requerido_homologado numeric, es_numerico boolean, nota_maxima numeric, formato_valor character varying, ya_asegurado boolean, alcanzable boolean)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_fk_grado BIGINT;
BEGIN
    SELECT gd.PK_TGRADO
      INTO v_fk_grado
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
     WHERE m.PK_TMATRICULA = p_fk_tmatricula
       AND m.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la matricula solicitada'
            USING ERRCODE = 'P0002';
    END IF;

    RETURN QUERY
    -- El universo NO puede salir del periodo pedido: justamente no tiene
    -- nada. Sale del AÑO COMPLETO -- se llama al detalle con periodos NULL --
    -- de modo que las asignaturas son las mismas que el estudiante cursa en
    -- los periodos que si tienen notas.
    WITH universo AS (
        SELECT DISTINCT d.fk_tasignatura AS asig
          FROM academico_test.fn_informe_estudiante_asignaturas_interno(
                   p_fk_tmatricula, NULL) d
    ),
    calculado AS (
        SELECT u.asig,
               academico_test.fn_asignatura_nota_requerida_periodo(
                   p_fk_tmatricula, u.asig, p_fk_tperiodo_evaluacion) AS req
          FROM universo u
    )
    SELECT c.asig,
           asg.NOMBRE,
           asg.ABREVIACION,
           ar.NOMBRE,
           asg.ORDEN_REPORTE,
           c.req,
           -- Se homologa el requerido con las mismas reglas que una nota real,
           -- para que se pueda leer en la escala del colegio. Si el requerido
           -- se sale del rango, fn_nota_homologar igual convierte la parte
           -- numerica; la valoracion cualitativa puede venir NULL y esta bien.
           hr.nota_homologada,
           COALESCE(fmt.es_numerico, FALSE),
           fmt.nota_maxima,
           fmt.formato_valor,
           CASE WHEN c.req IS NULL THEN NULL ELSE c.req <= 0   END,
           CASE WHEN c.req IS NULL THEN NULL ELSE c.req <= 100 END
      FROM calculado c
      JOIN academico_test.TASIGNATURA asg ON asg.PK_TASIGNATURA = c.asig
      LEFT JOIN academico_test.TAREA are  ON are.PK_TAREA = asg.FK_TAREA
      LEFT JOIN academico_test.TAREA_ASIGNATURA ar
             ON ar.PK_TAREA_ASIGNATURA = are.FK_TAREA_ASIGNATURA
      -- V428 -- misma cadena que el detalle: referente -> plan -> criterio.
      LEFT JOIN LATERAL academico_test.fn_asignatura_tipo_evaluacion(
                    c.asig, v_fk_grado) fmt ON TRUE
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                    c.req, c.asig, v_fk_grado) hr ON TRUE
     ORDER BY asg.ORDEN_REPORTE NULLS LAST, asg.NOMBRE, c.asig;
END;
$function$;
COMMENT ON FUNCTION academico_test.fn_informe_periodo_requerido_interno(BIGINT, BIGINT)
    IS 'INTERNO: Las filas de un periodo SIN CALIFICACIONES: una por asignatura del estudiante, con la nota que NECESITA en ese periodo para no perder la asignatura en el ano (fn_asignatura_nota_requerida_periodo), tanto en porcentaje como homologada a la escala del colegio. El universo de asignaturas NO sale del periodo pedido -- justamente no tiene nada -- sino del AÑO COMPLETO, llamando al detalle con periodos NULL, de modo que son las mismas asignaturas que el estudiante cursa en los periodos que si tienen notas; el gate de permisos lo aplica esa llamada. YA_ASEGURADO es TRUE cuando el requerido es <= 0: lo que lleva ya le alcanza y no necesita nada en este periodo. ALCANZABLE es FALSE cuando supera el maximo de la escala: ya perdio la asignatura pase lo que pase, y el valor se devuelve igual porque ESA es la informacion. Ambos vienen NULL cuando no se pudo calcular, que pasa si el grado no tiene DESEMPENHO_MINIMO configurado. ES_NUMERICO y NOTA_MAXIMA salen del criterio de evaluacion por (asignatura, grado) y no de homologar un valor, de modo que valen aunque no haya ninguna nota -- esa es la diferencia que permite distinguir un periodo numerico vacio de uno cualitativo (preescolar). Sin gate: lo aplica fn_informe_grupo_listar, que es quien la usa.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_recuperacion_nota_final_vigente(
    p_fk_tmatricula          BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fk_tperiodo_evaluacion BIGINT
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $function$
    SELECT ae.PK_TACTIVIDAD_ESTUDIANTE
      FROM academico_test.TASIGNATURA_NOTA sn
      JOIN academico_test.TACTIVIDAD a
        ON a.FK_TASIGNATURA  = sn.FK_TASIGNATURA
       AND a.ES_RECUPERACION = 'S'
       AND a.ACTIVE = TRUE
      JOIN academico_test.TACTIVIDAD_RECUPERACION r
        ON r.FK_TACTIVIDAD = a.PK_TACTIVIDAD
       AND r.ACTIVE = TRUE
      JOIN academico_test.TLISTA_VALOR lv
        ON lv.PK_LISTA_VALOR = r.FK_TLV_DESTINO_RECUPERACION
       AND lv.VALOR = 'NOTA_FINAL'
      JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
        ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
       AND ae.FK_TMATRICULA = sn.FK_TMATRICULA
       AND ae.ACTIVE = TRUE
      JOIN academico_test.TACTIVIDAD_NOTA n
        ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
       AND n.ACTIVE = TRUE
       -- Solo la que produjo la RECUPERACION vigente: una nota cambiada despues
       -- espera aprobacion (Regla 70) y usarla seria saltarsela.
       AND n.CALIFICACION = sn.RECUPERACION
     WHERE sn.FK_TMATRICULA          = p_fk_tmatricula
       AND sn.FK_TASIGNATURA         = p_fk_tasignatura
       AND sn.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
       AND sn.ACTIVE = TRUE
       AND sn.RECUPERACION IS NOT NULL
       AND academico_test.fn_actividad_periodo_evaluacion(a.PK_TACTIVIDAD, sn.FK_TMATRICULA)
           = sn.FK_TPERIODO_EVALUACION
     ORDER BY COALESCE(n.MODIFIED_AT, n.CREATED_AT) DESC, ae.PK_TACTIVIDAD_ESTUDIANTE DESC
     LIMIT 1;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_recuperacion_nota_final_vigente(BIGINT, BIGINT, BIGINT)
    IS 'INTERNO: PK_TACTIVIDAD_ESTUDIANTE de la recuperacion con destino NOTA_FINAL que produjo la RECUPERACION vigente de (matricula, asignatura, periodo): actividad ES_RECUPERACION de la misma asignatura y periodo (fn_actividad_periodo_evaluacion) cuya nota es IGUAL a TASIGNATURA_NOTA.RECUPERACION, de modo que una nota cambiada despues y pendiente de aprobacion no cuenta. Si hay varias, la calificada mas recientemente; NULL si no hay recuperacion o no se ubica. Sin gate. La usa fn_informe_nota_periodo_escribir_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_nota_periodo_escribir_interno(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tmatricula          BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fk_tperiodo_evaluacion BIGINT,
    p_nota                   NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_pk_nota    BIGINT;
    v_recup      NUMERIC;
    v_pk_ae      BIGINT;
    v_res        JSONB;
    v_definitiva NUMERIC;
BEGIN
    SELECT sn.PK_TASIGNATURA_NOTA, sn.RECUPERACION
      INTO v_pk_nota, v_recup
      FROM academico_test.TASIGNATURA_NOTA sn
     WHERE sn.FK_TMATRICULA          = p_fk_tmatricula
       AND sn.FK_TASIGNATURA         = p_fk_tasignatura
       AND sn.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
       AND sn.ACTIVE = TRUE;

    IF v_recup IS NULL THEN
        INSERT INTO academico_test.TASIGNATURA_NOTA (
            FK_TMATRICULA, FK_TASIGNATURA, FK_TPERIODO_EVALUACION,
            CALIFICACION, DEFINITIVA, CREATED_BY, CREATED_AT, ACTIVE
        ) VALUES (
            p_fk_tmatricula, p_fk_tasignatura, p_fk_tperiodo_evaluacion,
            p_nota, p_nota,
            p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
        )
        ON CONFLICT (FK_TMATRICULA, FK_TPERIODO_EVALUACION, FK_TASIGNATURA)
            WHERE ACTIVE
        DO UPDATE SET CALIFICACION = EXCLUDED.CALIFICACION,
                      DEFINITIVA   = EXCLUDED.DEFINITIVA,
                      MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
                      MODIFIED_AT  = CURRENT_TIMESTAMP;

        RETURN JSONB_BUILD_OBJECT('definitiva', p_nota, 'con_recuperacion', FALSE);
    END IF;

    -- Con Habilitacion la nota nueva es la nueva BASE y la definitiva la
    -- recombina el modulo de recuperacion. El _interno y no el publico: la
    -- recuperacion ya esta aprobada, y el publico abriria otra solicitud.
    UPDATE academico_test.TASIGNATURA_NOTA
       SET CALIFICACION = p_nota,
           MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT  = CURRENT_TIMESTAMP
     WHERE PK_TASIGNATURA_NOTA = v_pk_nota;

    v_pk_ae := academico_test.fn_informe_recuperacion_nota_final_vigente(
                   p_fk_tmatricula, p_fk_tasignatura, p_fk_tperiodo_evaluacion);
    IF v_pk_ae IS NULL THEN
        v_res := JSONB_BUILD_OBJECT('aplicada', FALSE, 'motivo', 'RECUPERACION_NO_UBICADA');
    ELSE
        v_res := academico_test.fn_actividad_recuperacion_consolidar_interno(
                     p_pk_usuario_solicitante, v_pk_ae, NULL);
    END IF;

    SELECT sn.DEFINITIVA INTO v_definitiva
      FROM academico_test.TASIGNATURA_NOTA sn
     WHERE sn.PK_TASIGNATURA_NOTA = v_pk_nota;

    RETURN JSONB_BUILD_OBJECT(
        'definitiva',       v_definitiva,
        'con_recuperacion', TRUE,
        'recombinada',      COALESCE((v_res->>'aplicada')::BOOLEAN, FALSE),
        'motivo',           v_res->'motivo');
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_nota_periodo_escribir_interno(BIGINT, BIGINT, BIGINT, BIGINT, NUMERIC)
    IS 'INTERNO: escritura unica de la nota consolidada de (matricula, asignatura, periodo). Sin recuperacion de NOTA_FINAL: CALIFICACION = DEFINITIVA = p_nota. Con recuperacion (RECUPERACION no nula), p_nota es la nueva BASE: va a CALIFICACION y la DEFINITIVA se recombina con fn_actividad_recuperacion_consolidar_interno sobre la recuperacion que la produjo, con las reglas de ese modulo (REEMPLAZAR/COMPUTAR, ponderacion, piso, tope, redondeo). Se usa el _interno porque la recuperacion ya esta aprobada; el publico abriria una solicitud por cada guardado. Si no se puede recombinar, la DEFINITIVA conserva la resultante vigente. Devuelve {definitiva, con_recuperacion, recombinada, motivo}. Sin gate; el usuario es solo para auditoria. La usan fn_informe_periodo_guardar_interno y fn_informe_planilla_guardar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_metricas_recalcular_interno(p_pk_usuario_solicitante bigint, p_fk_tmatricula bigint, p_fk_tperiodo_evaluacion bigint)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_grado BIGINT;
    v_minimo   NUMERIC;
    v_total    BIGINT  := 0;
    v_conNota  BIGINT  := 0;
    v_suma     NUMERIC := 0;
    v_aprob    BIGINT  := 0;
    v_reprob   BIGINT  := 0;
    v_sindef   BIGINT  := 0;
    r          RECORD;
BEGIN
    SELECT gd.PK_TGRADO
      INTO v_fk_grado
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
     WHERE m.PK_TMATRICULA = p_fk_tmatricula;

    v_minimo := academico_test.fn_grado_desempeno_minimo(v_fk_grado);

    -- El universo sale del detalle -- el mismo que ve el usuario -- pero se
    -- lee NOTA_GUARDADA y no la proyectada: las metricas describen lo
    -- consolidado, no lo que se estaba por consolidar.
    FOR r IN
        SELECT d.nota_guardada
          FROM academico_test.fn_informe_estudiante_asignaturas_interno(
                   p_fk_tmatricula,
                   ARRAY[p_fk_tperiodo_evaluacion]::BIGINT[]) d
    LOOP
        v_total := v_total + 1;

        IF r.nota_guardada IS NULL THEN
            v_sindef := v_sindef + 1;
        ELSE
            v_conNota := v_conNota + 1;
            v_suma    := v_suma + r.nota_guardada;

            IF v_minimo IS NULL THEN
                -- Sin umbral configurado la aprobacion es DESCONOCIDA, no
                -- falsa: 425 de las 742 filas activas de TCRITERIO_PROMOCION
                -- no lo tienen, y contar eso como reprobado seria reprobar
                -- gente por una configuracion que el colegio nunca hizo.
                v_sindef := v_sindef + 1;
            ELSIF r.nota_guardada >= v_minimo THEN
                v_aprob := v_aprob + 1;
            ELSE
                v_reprob := v_reprob + 1;
            END IF;
        END IF;
    END LOOP;

    IF v_conNota = 0 THEN
        -- Nada consolidado: la fila se da de BAJA, no se deja en cero. Un
        -- promedio 0 se leeria como "saco cero"; lo que pasa es que el
        -- periodo no esta consolidado. Con la fila inactiva el listado vuelve
        -- a calcular al vuelo y CONSOLIDADO vuelve a FALSE, que es la verdad.
        UPDATE academico_test.TINFORME_PERIODO_MATRICULA
           SET ACTIVE      = FALSE,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TMATRICULA          = p_fk_tmatricula
           AND FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
           AND ACTIVE = TRUE;
        RETURN;
    END IF;

    INSERT INTO academico_test.TINFORME_PERIODO_MATRICULA (
        FK_TMATRICULA, FK_TPERIODO_EVALUACION,
        PROMEDIO, ASIGNATURAS, APROBADAS, REPROBADAS, SIN_DEFINIR,
        CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        p_fk_tmatricula, p_fk_tperiodo_evaluacion,
        ROUND(v_suma / v_conNota, 2), v_total, v_aprob, v_reprob, v_sindef,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    ON CONFLICT (FK_TMATRICULA, FK_TPERIODO_EVALUACION)
    DO UPDATE SET PROMEDIO    = EXCLUDED.PROMEDIO,
                  ASIGNATURAS = EXCLUDED.ASIGNATURAS,
                  APROBADAS   = EXCLUDED.APROBADAS,
                  REPROBADAS  = EXCLUDED.REPROBADAS,
                  SIN_DEFINIR = EXCLUDED.SIN_DEFINIR,
                  ACTIVE      = TRUE,
                  MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
                  MODIFIED_AT = CURRENT_TIMESTAMP;
END;
$function$;
COMMENT ON FUNCTION academico_test.fn_informe_metricas_recalcular_interno(BIGINT, BIGINT, BIGINT)
    IS 'INTERNO: Recalcula y persiste la fila de TINFORME_PERIODO_MATRICULA de un (estudiante, periodo) a partir de lo que HAY GUARDADO en TASIGNATURA_NOTA. Es el punto UNICO de ese calculo y lo llaman los dos guardados -- el del informe completo y el de una sola asignatura desde la planilla -- porque esa fila agrega TODAS las asignaturas: guardar una sola y no recalcularla la deja describiendo un estado que ya no existe, en silencio y de forma consistente consigo misma (medido: notas 70 y 20, promedio real 45, fila diciendo 77.71). Calcula DESPUES de escribir y solo desde lo guardado, no desde lo que se iba a guardar: la version anterior acumulaba dentro del bucle leyendo la aprobacion del detalle, que la decide sobre la nota VISIBLE -- COALESCE(guardada, proyectada), es decir la VIEJA -- mientras escribia la proyectada, de modo que las metricas podian describir un numero distinto del que quedaba en la tabla (reproducido: re-guardar sin cambiar nada movia aprobadas de 2 a 1). El universo de asignaturas sale de fn_informe_estudiante_asignaturas, el mismo que ve el usuario, asi que una asignatura sin nota guardada cuenta en SIN_DEFINIR en vez de desaparecer del total; y una nota guardada cuyo grado no tiene DESEMPENHO_MINIMO tambien va a SIN_DEFINIR, nunca a reprobadas. Si no queda NINGUNA nota guardada la fila se da de BAJA en vez de quedar en cero: un promedio 0 se leeria como "saco cero" cuando lo que pasa es que el periodo no esta consolidado, y con la fila inactiva el listado vuelve a calcular al vuelo y CONSOLIDADO vuelve a FALSE. Sin gate; el usuario es para auditoria. Lo llaman los dos guardados despues de escribir.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_historial_registrar_interno(p_pk_usuario_solicitante bigint, p_fk_tgrupo bigint, p_fk_tasignatura bigint, p_fk_tperiodo_evaluacion bigint, p_origen character varying, p_estudiantes jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_pk BIGINT;
BEGIN
    -- Sin estudiantes no hay nada que registrar. Se devuelve NULL en vez de
    -- crear una cabecera en cero: ver el punto (2) de la cabecera.
    IF p_estudiantes IS NULL OR JSONB_ARRAY_LENGTH(p_estudiantes) = 0 THEN
        RETURN NULL;
    END IF;

    INSERT INTO academico_test.TINFORME_GUARDADO (
        FK_TGRUPO, FK_TASIGNATURA, FK_TPERIODO_EVALUACION, FK_TUSUARIO,
        ORIGEN, ESTUDIANTES, CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        p_fk_tgrupo, p_fk_tasignatura, p_fk_tperiodo_evaluacion,
        p_pk_usuario_solicitante, p_origen,
        JSONB_ARRAY_LENGTH(p_estudiantes),
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TINFORME_GUARDADO INTO v_pk;

    INSERT INTO academico_test.TINFORME_GUARDADO_ESTUDIANTE (
        FK_TINFORME_GUARDADO, FK_TMATRICULA, PROMEDIO, ASIGNATURAS_AFECTADAS,
        CREATED_BY, CREATED_AT, ACTIVE
    )
    SELECT v_pk,
           (e ->> 'matricula')::BIGINT,
           NULLIF(e ->> 'promedio', '')::NUMERIC,
           NULLIF(e ->> 'asignaturas', '')::NUMERIC,
           p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
      FROM JSONB_ARRAY_ELEMENTS(p_estudiantes) e;

    RETURN v_pk;
END;
$function$;
COMMENT ON FUNCTION academico_test.fn_informe_historial_registrar_interno(BIGINT, BIGINT, BIGINT, BIGINT, CHARACTER VARYING, JSONB)
    IS 'INTERNO: Punto UNICO de escritura del historial de guardados: crea la cabecera en TINFORME_GUARDADO y una fila por estudiante en TINFORME_GUARDADO_ESTUDIANTE. Lo llaman los dos guardados -- el del informe completo y el de una asignatura desde la planilla -- para que la forma del historial no dependa de por donde se guardo. Recibe los estudiantes como JSONB ([{"matricula":1,"promedio":77.71,"asignaturas":2}]) porque ambos los acumulan dentro de su bucle, y recibirlos de una vez evita abrir la cabecera antes de saber si hubo algo que registrar. Con arreglo vacio o NULL devuelve NULL sin escribir nada: una cabecera en cero ensuciaria un historial que se agrupa por dia y solo muestra los dias con movimiento. p_fk_tasignatura NULL indica guardado del informe completo. Sin gate; el usuario es para auditoria. Lo llaman los dos guardados al terminar.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_grupo_listar_interno(p_fk_tgrupo bigint, p_fk_periodos_evaluacion bigint[] DEFAULT NULL::bigint[], p_search character varying DEFAULT NULL::character varying)
 RETURNS TABLE(fk_tmatricula bigint, estudiante character varying, documento character varying, fk_tperiodo_evaluacion bigint, periodo_nombre character varying, periodo_abreviacion character varying, periodo_inicio date, modo_periodo character varying, formato character varying, es_cualitativo boolean, consolidado boolean, promedio_guardado numeric, promedio_proyectado numeric, puesto bigint, asignaturas_total bigint, aprobadas bigint, reprobadas bigint, sin_definir bigint, tiene_cambios_propuestos boolean, asignaturas jsonb, observacion text, observacion_estado character varying, observacion_desactualizada boolean, evidencias bigint, total_count bigint, promedio_valoracion character varying, promedio_simbolo character varying, promedio_proyectado_valoracion character varying, promedio_proyectado_simbolo character varying, promedio_formato character varying)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_fk_sede     BIGINT;
    v_fk_jornada  BIGINT;
    v_fk_ee       BIGINT;
    v_fk_peraca   BIGINT;
    v_fk_grado    BIGINT;
    v_minimo         NUMERIC;
    v_n_periodos     INTEGER;
    v_incluir_final  BOOLEAN;
BEGIN
    SELECT s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO,
           gd.FK_TPERIODO_ACADEMICO, gd.PK_TGRADO
      INTO v_fk_sede, v_fk_jornada, v_fk_ee, v_fk_peraca, v_fk_grado
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE gr.PK_TGRUPO = p_fk_tgrupo
       AND gr.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el grupo solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    v_minimo := academico_test.fn_grado_desempeno_minimo(v_fk_grado);

    -- *** V439 *** El Final ya no es un parametro aparte: es un id mas de la
    -- lista de periodos, el mismo -1 con el que la fila viaja. Que sea un
    -- elemento y no una bandera es lo que permite pedir "solo el Final":
    -- ARRAY[-1] no matchea ningun periodo real, asi que la CTE de periodos
    -- queda vacia sin que haya que inventar un segundo significado para el
    -- arreglo vacio. NULL o vacio siguen siendo TODOS los periodos reales,
    -- sin Final, exactamente como antes.
    v_incluir_final := p_fk_periodos_evaluacion IS NOT NULL
                      AND (-1) = ANY (p_fk_periodos_evaluacion);

    SELECT COUNT(*)
      INTO v_n_periodos
      FROM academico_test.TPERIODO_EVALUACION pe
     WHERE pe.ACTIVE = TRUE
       AND pe.FK_TPERIODO_ACADEMICO = v_fk_peraca;

    RETURN QUERY
    WITH periodos AS (
        SELECT pe.PK_TPERIODO_EVALUACION AS pk,
               pe.NOMBRE                 AS nombre,
               pe.ABREVIACION            AS abrev,
               pe.FECHA_INICIO           AS inicio
          FROM academico_test.TPERIODO_EVALUACION pe
         WHERE pe.ACTIVE = TRUE
           AND pe.FK_TPERIODO_ACADEMICO = v_fk_peraca
           AND (p_fk_periodos_evaluacion IS NULL
                OR CARDINALITY(p_fk_periodos_evaluacion) = 0
                OR pe.PK_TPERIODO_EVALUACION = ANY (p_fk_periodos_evaluacion))
    ),
    estudiantes AS (
        SELECT m.PK_TMATRICULA AS pk,
               NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                          u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)),
                      '')::VARCHAR AS nombre,
               u.IDENTIFICACION::VARCHAR AS doc
          FROM academico_test.TMATRICULA m
          LEFT JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          LEFT JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO     = es.FK_TUSUARIO
         WHERE m.FK_TGRUPO = p_fk_tgrupo
           AND m.ACTIVE = TRUE
    ),
    detalle AS (
        SELECT e.pk AS mat, d.*
          FROM estudiantes e
          CROSS JOIN LATERAL academico_test.fn_informe_estudiante_asignaturas_interno(
                         e.pk, p_fk_periodos_evaluacion) d
    ),
    observaciones AS (
        SELECT e.pk AS mat,
               p.pk AS pe,
               (SELECT COUNT(*)
                  FROM academico_test.TACTIVIDAD a2
                  JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae2
                    ON ae2.FK_TACTIVIDAD = a2.PK_TACTIVIDAD
                   AND ae2.FK_TMATRICULA = e.pk
                   AND ae2.ACTIVE = TRUE
                  JOIN academico_test.TACTIVIDAD_NOTA n2
                    ON n2.FK_TACTIVIDAD_ESTUDIANTE = ae2.PK_TACTIVIDAD_ESTUDIANTE
                   AND n2.ACTIVE = TRUE
                 WHERE a2.ACTIVE = TRUE
                   AND NULLIF(TRIM(COALESCE(n2.OBSERVACION, '')), '') IS NOT NULL
                   AND academico_test.fn_actividad_en_periodo_eval(a2.PK_TACTIVIDAD, p.pk) = TRUE
               ) AS n
          FROM estudiantes e
          CROSS JOIN periodos p
    ),
    evidencias_periodo AS (
        SELECT e.pk AS mat,
               p.pk AS pe,
               (SELECT COUNT(*)
                  FROM academico_test.TACTIVIDAD_SOPORTE so
                  JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae3
                    ON ae3.PK_TACTIVIDAD_ESTUDIANTE = so.FK_TACTIVIDAD_ESTUDIANTE
                   AND ae3.FK_TMATRICULA = e.pk
                   AND ae3.ACTIVE = TRUE
                  JOIN academico_test.TACTIVIDAD a4
                    ON a4.PK_TACTIVIDAD = ae3.FK_TACTIVIDAD
                   AND a4.ACTIVE = TRUE
                 WHERE so.ACTIVE = TRUE
                   AND so.FK_TARCHIVO IS NOT NULL
                   AND academico_test.fn_actividad_en_periodo_eval(a4.PK_TACTIVIDAD, p.pk) = TRUE
               ) AS n
          FROM estudiantes e
          CROSS JOIN periodos p
    ),
    por_periodo AS (
        SELECT e.pk   AS mat,
               e.nombre,
               e.doc,
               p.pk     AS pe,
               p.nombre AS pe_nombre,
               p.abrev  AS pe_abrev,
               p.inicio AS pe_inicio,
               COALESCE(BOOL_OR(COALESCE(d.nota_guardada, d.nota_proyectada)
                                IS NOT NULL), FALSE)             AS tiene_notas,
               COUNT(d.fk_tasignatura)                           AS calc_total,
               AVG(d.nota_guardada)                              AS calc_prom_guardado,
               AVG(COALESCE(d.nota_guardada, d.nota_proyectada)) AS calc_prom_visible,
               -- La proyectada excluye la recuperacion: en una asignatura
               -- recuperada lo vigente es la resultante.
               AVG(CASE WHEN d.con_recuperacion THEN d.nota_guardada
                        ELSE COALESCE(d.nota_proyectada, d.nota_guardada) END) AS calc_prom_proyectado,
               COUNT(*) FILTER (WHERE d.aprobada IS TRUE)        AS calc_aprob,
               COUNT(*) FILTER (WHERE d.aprobada IS FALSE)       AS calc_reprob,
               COUNT(*) FILTER (WHERE d.fk_tasignatura IS NOT NULL
                                  AND d.aprobada IS NULL)        AS calc_sindef,
               COALESCE(BOOL_OR(d.es_numerico), FALSE)           AS hay_numerico,
               COALESCE(BOOL_OR(d.estado_nota = 'cambio_propuesto'), FALSE) AS cambios,
               COALESCE(
                   JSONB_AGG(
                       JSONB_BUILD_OBJECT(
                           'asignatura',  d.fk_tasignatura,
                           'nombre',      d.asignatura_nombre,
                           'abreviacion', asg.ABREVIACION,
                           'area',        d.area_nombre,
                           'orden',       asg.ORDEN_REPORTE,
                           'nota',        d.nota_homologada,
                           'nota_propuesta',
                               CASE WHEN d.estado_nota = 'cambio_propuesto'
                                    THEN d.nota_proyectada_homologada END,
                           'estado',      d.estado_nota,
                           'es_numerico', d.es_numerico,
                           'valoracion',  d.valoracion_nombre,
                           'simbolo',     d.valoracion_simbolo,
                           'aprobada',    d.aprobada,
                           -- Regla 68: 'nota' es la resultante (R); estas, la original (C).
                           'con_recuperacion',    COALESCE(d.con_recuperacion, FALSE),
                           'nota_original',       d.nota_original_homologada,
                           'valoracion_original', d.nota_original_valoracion,
                           'simbolo_original',    d.nota_original_simbolo
                       ) ORDER BY asg.ORDEN_REPORTE NULLS LAST, d.asignatura_nombre
                   ) FILTER (WHERE d.fk_tasignatura IS NOT NULL),
                   '[]'::JSONB
               ) AS asigs
          FROM estudiantes e
          CROSS JOIN periodos p
          LEFT JOIN detalle d
                 ON d.mat = e.pk
                AND d.fk_tperiodo_evaluacion = p.pk
          LEFT JOIN academico_test.TASIGNATURA asg
                 ON asg.PK_TASIGNATURA = d.fk_tasignatura
         GROUP BY e.pk, e.nombre, e.doc, p.pk, p.nombre, p.abrev, p.inicio
    ),
    base AS (
        SELECT pp.*,
               COALESCE(ob.n, 0) AS obs_hoy,
               COALESCE(ev.n, 0) AS evid
          FROM por_periodo pp
          LEFT JOIN observaciones      ob ON ob.mat = pp.mat AND ob.pe = pp.pe
          LEFT JOIN evidencias_periodo ev ON ev.mat = pp.mat AND ev.pe = pp.pe
    ),
    requeridos AS (
        SELECT b.mat,
               b.pe,
               COALESCE(BOOL_OR(r.es_numerico), FALSE) AS hay_numerico,
               COUNT(*)                                AS total,
               COALESCE(
                   JSONB_AGG(
                       JSONB_BUILD_OBJECT(
                           'asignatura',   r.fk_tasignatura,
                           'nombre',       r.asignatura_nombre,
                           'abreviacion',  r.abreviacion,
                           'area',         r.area_nombre,
                           'orden',        r.orden_reporte,
                           'nota',         r.requerido_homologado,
                           'porcentaje',   r.requerido,
                           'estado',       'requerido',
                           'es_numerico',  r.es_numerico,
                           'ya_asegurado', r.ya_asegurado,
                           'alcanzable',   r.alcanzable
                       ) ORDER BY r.orden_reporte NULLS LAST, r.asignatura_nombre
                   ),
                   '[]'::JSONB
               ) AS asigs
          FROM base b
          CROSS JOIN LATERAL academico_test.fn_informe_periodo_requerido_interno(
                         b.mat, b.pe) r
         WHERE NOT b.tiene_notas
           AND b.obs_hoy = 0
         GROUP BY b.mat, b.pe
    ),
    resuelto AS (
        SELECT b.*,
               (NOT b.tiene_notas
                AND COALESCE(rq.hay_numerico, FALSE))  AS es_requerido,
               rq.total AS req_total,
               rq.asigs AS req_asigs,
               COALESCE(rq.hay_numerico, b.hay_numerico) AS es_num_final
          FROM base b
          LEFT JOIN requeridos rq ON rq.mat = b.mat AND rq.pe = b.pe
    ),
    con_metricas AS (
        SELECT rs.*,
               (ipm.PK_TINFORME_PERIODO_MATRICULA IS NOT NULL) AS esta_consolidado,
               COALESCE(ipm.PROMEDIO,    ROUND(rs.calc_prom_guardado, 2)) AS prom_guardado,
               COALESCE(ipm.ASIGNATURAS, rs.calc_total)                   AS total_asig,
               COALESCE(ipm.APROBADAS,   rs.calc_aprob)                   AS aprob,
               COALESCE(ipm.REPROBADAS,  rs.calc_reprob)                  AS reprob,
               COALESCE(ipm.SIN_DEFINIR, rs.calc_sindef)                  AS sindef,
               ob.OBSERVACION                                             AS obs,
               lv.VALOR                                                   AS obs_estado,
               CASE WHEN ob.PK_TESTUDIANTE_PERIODO_OBSERVACION IS NULL THEN NULL
                    ELSE rs.obs_hoy > COALESCE(ob.OBSERVACIONES_ORIGEN, 0)
               END                                                        AS obs_vieja
          FROM resuelto rs
          LEFT JOIN academico_test.TINFORME_PERIODO_MATRICULA ipm
                 ON ipm.FK_TMATRICULA          = rs.mat
                AND ipm.FK_TPERIODO_EVALUACION = rs.pe
                AND ipm.ACTIVE = TRUE
          LEFT JOIN academico_test.TESTUDIANTE_PERIODO_OBSERVACION ob
                 ON ob.FK_TMATRICULA          = rs.mat
                AND ob.FK_TPERIODO_EVALUACION = rs.pe
                AND ob.ACTIVE = TRUE
          LEFT JOIN academico_test.TLISTA_VALOR lv
                 ON lv.PK_LISTA_VALOR = ob.FK_TLV_ESTADO_OBSERVACION
    ),
    con_puesto AS (
        SELECT cm.*,
               CASE WHEN cm.es_requerido OR cm.calc_prom_visible IS NULL THEN NULL
                    ELSE RANK() OVER (PARTITION BY cm.pe
                                          ORDER BY cm.calc_prom_visible DESC NULLS LAST)
               END AS pos
          FROM con_metricas cm
    ),

    -- =======================================================================
    -- La fila Final (V431).
    -- =======================================================================
    estudiantes_final AS (
        SELECT e.* FROM estudiantes e WHERE v_incluir_final
    ),
    detalle_ano AS (
        SELECT e.pk AS mat, d.*
          FROM estudiantes_final e
          CROSS JOIN LATERAL academico_test.fn_informe_estudiante_asignaturas_interno(
                         e.pk, NULL) d
    ),
    final_asig AS (
        SELECT d.mat                                    AS mat,
               d.fk_tasignatura                         AS asig,
               MAX(d.asignatura_nombre)                 AS nombre,
               MAX(asg.ABREVIACION)                     AS abrev,
               MAX(d.area_nombre)                       AS area,
               MAX(asg.ORDEN_REPORTE)                   AS orden,
               COALESCE(BOOL_OR(d.es_numerico), FALSE)  AS es_numerico,
               MAX(d.desempeno_minimo)                  AS minimo,
               academico_test.fn_asignatura_definitiva_anual_interno(d.mat, d.fk_tasignatura) AS nota
          FROM detalle_ano d
          JOIN academico_test.TASIGNATURA asg ON asg.PK_TASIGNATURA = d.fk_tasignatura
         WHERE d.fk_tasignatura IS NOT NULL
         GROUP BY d.mat, d.fk_tasignatura
    ),
    final_agregado AS (
        SELECT fa.mat,
               COALESCE(BOOL_OR(fa.es_numerico), FALSE) AS hay_numerico,
               COUNT(*)                                 AS total,
               COUNT(*) FILTER (
                   WHERE fa.nota >= COALESCE(fa.minimo, v_minimo))         AS aprob,
               COUNT(*) FILTER (
                   WHERE fa.nota <  COALESCE(fa.minimo, v_minimo))         AS reprob,
               COUNT(*) FILTER (
                   WHERE fa.nota IS NULL
                      OR COALESCE(fa.minimo, v_minimo) IS NULL)            AS sindef,
               ROUND(AVG(fa.nota), 2)                   AS promedio,
               JSONB_AGG(
                   JSONB_BUILD_OBJECT(
                       'asignatura',  fa.asig,
                       'nombre',      fa.nombre,
                       'abreviacion', fa.abrev,
                       'area',        fa.area,
                       'orden',       fa.orden,
                       'nota',        h.nota_homologada,
                       'estado',      'final',
                       'es_numerico', fa.es_numerico,
                       'valoracion',  h.valoracion_nombre,
                       'simbolo',     h.valoracion_simbolo,
                       'aprobada',    CASE
                                          WHEN fa.nota IS NULL
                                            OR COALESCE(fa.minimo, v_minimo) IS NULL
                                          THEN NULL
                                          ELSE fa.nota >= COALESCE(fa.minimo, v_minimo)
                                      END
                   ) ORDER BY fa.orden NULLS LAST, fa.nombre
               )                                        AS asigs
          FROM final_asig fa
          LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                        fa.nota, fa.asig, v_fk_grado) h ON TRUE
         GROUP BY fa.mat
    ),
    -- *** V435 *** Cuantos resumenes de periodo hay HOY. Es lo que se compara
    -- contra PERIODOS_ORIGEN para saber si el texto del año quedo viejo: lo
    -- que lo envejece es que se cierre un periodo nuevo, no que el docente
    -- escriba una observacion mas.
    final_periodos_hoy AS (
        SELECT e.pk AS mat,
               (SELECT COUNT(*)
                  FROM academico_test.TESTUDIANTE_PERIODO_OBSERVACION ob2
                  JOIN academico_test.TPERIODO_EVALUACION pe3
                    ON pe3.PK_TPERIODO_EVALUACION = ob2.FK_TPERIODO_EVALUACION
                   AND pe3.ACTIVE = TRUE
                   AND pe3.FK_TPERIODO_ACADEMICO = v_fk_peraca
                 WHERE ob2.FK_TMATRICULA = e.pk
                   AND ob2.ACTIVE = TRUE
                   AND NULLIF(TRIM(COALESCE(ob2.OBSERVACION, '')), '') IS NOT NULL
               ) AS n
          FROM estudiantes_final e
    ),
    final_evidencias AS (
        SELECT e.pk AS mat,
               (SELECT COUNT(*)
                  FROM academico_test.TACTIVIDAD_SOPORTE so
                  JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae5
                    ON ae5.PK_TACTIVIDAD_ESTUDIANTE = so.FK_TACTIVIDAD_ESTUDIANTE
                   AND ae5.FK_TMATRICULA = e.pk
                   AND ae5.ACTIVE = TRUE
                  JOIN academico_test.TACTIVIDAD a6
                    ON a6.PK_TACTIVIDAD = ae5.FK_TACTIVIDAD
                   AND a6.ACTIVE = TRUE
                 WHERE so.ACTIVE = TRUE
                   AND so.FK_TARCHIVO IS NOT NULL
                   AND EXISTS (SELECT 1
                                 FROM academico_test.TPERIODO_EVALUACION pe2
                                WHERE pe2.ACTIVE = TRUE
                                  AND pe2.FK_TPERIODO_ACADEMICO = v_fk_peraca
                                  AND academico_test.fn_actividad_en_periodo_eval(
                                          a6.PK_TACTIVIDAD, pe2.PK_TPERIODO_EVALUACION) = TRUE)
               ) AS n
          FROM estudiantes_final e
    ),
    final_fila AS (
        SELECT e.pk AS mat,
               e.nombre,
               e.doc,
               COALESCE(fg.hay_numerico, FALSE) AS hay_numerico,
               COALESCE(fg.total,  0)           AS total,
               COALESCE(fg.aprob,  0)           AS aprob,
               COALESCE(fg.reprob, 0)           AS reprob,
               COALESCE(fg.sindef, 0)           AS sindef,
               fg.promedio,
               COALESCE(fg.asigs, '[]'::JSONB)  AS asigs,
               -- *** V435 *** Lo GUARDADO, no el concatenado. El concatenado
               -- pasa a ser el borrador que devuelve generar, asi que la fila
               -- arranca vacia como los periodos hasta que alguien lo acepte.
               ao.OBSERVACION                   AS obs,
               lva.VALOR                        AS obs_estado,
               CASE WHEN ao.PK_TESTUDIANTE_ANIO_OBSERVACION IS NULL THEN NULL
                    ELSE COALESCE(fph.n, 0) > COALESCE(ao.PERIODOS_ORIGEN, 0)
               END                              AS obs_vieja,
               COALESCE(fe.n, 0)                AS evid
          FROM estudiantes_final e
          LEFT JOIN final_agregado     fg  ON fg.mat  = e.pk
          LEFT JOIN final_evidencias   fe  ON fe.mat  = e.pk
          LEFT JOIN final_periodos_hoy fph ON fph.mat = e.pk
          LEFT JOIN academico_test.TESTUDIANTE_ANIO_OBSERVACION ao
                 ON ao.FK_TMATRICULA = e.pk
                AND ao.ACTIVE = TRUE
          LEFT JOIN academico_test.TLISTA_VALOR lva
                 ON lva.PK_LISTA_VALOR = ao.FK_TLV_ESTADO_OBSERVACION
    ),
    final_puesto AS (
        SELECT ff.*,
               CASE WHEN ff.hay_numerico IS TRUE AND ff.promedio IS NOT NULL
                    THEN RANK() OVER (ORDER BY ff.promedio DESC NULLS LAST)
               END AS pos
          FROM final_fila ff
    ),

    salida AS (
        SELECT cp.mat                    AS o_mat,
               cp.nombre                 AS o_nombre,
               cp.doc                    AS o_doc,
               cp.pe                     AS o_pe,
               cp.pe_nombre              AS o_pe_nombre,
               cp.pe_abrev               AS o_pe_abrev,
               cp.pe_inicio              AS o_pe_inicio,
               CASE WHEN cp.es_requerido THEN 'requerido' ELSE 'real' END::VARCHAR
                                         AS o_modo,
               CASE WHEN cp.es_num_final THEN 'numerico' ELSE 'cualitativo' END::VARCHAR
                                         AS o_formato,
               NOT cp.es_num_final       AS o_cualitativo,
               CASE WHEN cp.es_requerido THEN FALSE ELSE cp.esta_consolidado END
                                         AS o_consolidado,
               CASE WHEN cp.es_requerido THEN NULL ELSE cp.prom_guardado END
                                         AS o_prom_guardado,
               CASE WHEN cp.es_requerido THEN v_minimo
                    ELSE ROUND(cp.calc_prom_proyectado, 2) END
                                         AS o_prom_proyectado,
               cp.pos                    AS o_puesto,
               CASE WHEN cp.es_requerido THEN cp.req_total ELSE cp.total_asig END::BIGINT
                                         AS o_total,
               CASE WHEN cp.es_requerido THEN 0 ELSE cp.aprob  END::BIGINT AS o_aprob,
               CASE WHEN cp.es_requerido THEN 0 ELSE cp.reprob END::BIGINT AS o_reprob,
               CASE WHEN cp.es_requerido THEN cp.req_total ELSE cp.sindef END::BIGINT
                                         AS o_sindef,
               cp.cambios                AS o_cambios,
               CASE WHEN cp.es_requerido THEN cp.req_asigs ELSE cp.asigs END
                                         AS o_asigs,
               cp.obs                    AS o_obs,
               cp.obs_estado             AS o_obs_estado,
               cp.obs_vieja              AS o_obs_vieja,
               cp.evid::BIGINT           AS o_evidencias
          FROM con_puesto cp

        UNION ALL

        SELECT fp.mat,
               fp.nombre,
               fp.doc,
               (-1)::BIGINT,
               'Final'::VARCHAR,
               'FIN'::VARCHAR,
               '9999-12-31'::DATE,
               'final'::VARCHAR,
               CASE WHEN fp.hay_numerico THEN 'numerico' ELSE 'cualitativo' END::VARCHAR,
               NOT fp.hay_numerico,
               FALSE,
               CASE WHEN fp.hay_numerico THEN fp.promedio END,
               CASE WHEN fp.hay_numerico THEN fp.promedio END,
               fp.pos,
               CASE WHEN fp.hay_numerico THEN fp.total  ELSE 0 END::BIGINT,
               CASE WHEN fp.hay_numerico THEN fp.aprob  ELSE 0 END::BIGINT,
               CASE WHEN fp.hay_numerico THEN fp.reprob ELSE 0 END::BIGINT,
               CASE WHEN fp.hay_numerico THEN fp.sindef ELSE 0 END::BIGINT,
               FALSE,
               CASE WHEN fp.hay_numerico THEN fp.asigs ELSE '[]'::JSONB END,
               fp.obs,
               fp.obs_estado,
               fp.obs_vieja,
               fp.evid::BIGINT
          FROM final_puesto fp
    )
    SELECT s.o_mat,
           s.o_nombre,
           s.o_doc,
           s.o_pe,
           s.o_pe_nombre,
           s.o_pe_abrev,
           s.o_pe_inicio,
           s.o_modo,
           s.o_formato,
           s.o_cualitativo,
           s.o_consolidado,
           -- V474 -- el promedio ya no sale en porcentaje: se homologa con el
           -- formato del criterio general del periodo academico, el mismo
           -- criterio con el que la pantalla pinta cada asignatura. En un
           -- formato no numerico estos dos vienen NULL y lo que vale es la
           -- valoracion, al final de la fila.
           hg.promedio,
           hp.promedio,
           s.o_puesto,
           s.o_total,
           s.o_aprob,
           s.o_reprob,
           s.o_sindef,
           s.o_cambios,
           s.o_asigs,
           s.o_obs,
           s.o_obs_estado,
           s.o_obs_vieja,
           s.o_evidencias,
           COUNT(*) OVER ()::BIGINT,
           hg.valoracion_nombre,
           hg.valoracion_simbolo,
           hp.valoracion_nombre,
           hp.valoracion_simbolo,
           COALESCE(hg.formato_valor, hp.formato_valor)
      FROM salida s
      -- Las dos laterales devuelven SIEMPRE una fila -- con todo en NULL si no
      -- hay porcentaje --, asi que no pueden perder estudiantes.
      LEFT JOIN LATERAL academico_test.fn_promedio_homologar(
                    s.o_prom_guardado, v_fk_peraca, v_fk_grado) hg ON TRUE
      LEFT JOIN LATERAL academico_test.fn_promedio_homologar(
                    s.o_prom_proyectado, v_fk_peraca, v_fk_grado) hp ON TRUE
     WHERE NULLIF(TRIM(COALESCE(p_search, '')), '') IS NULL
        OR s.o_nombre ILIKE '%' || TRIM(p_search) || '%'
        OR s.o_doc    ILIKE '%' || TRIM(p_search) || '%'
     ORDER BY s.o_nombre NULLS LAST, s.o_mat, s.o_pe_inicio;
END;
$function$;
COMMENT ON FUNCTION academico_test.fn_informe_grupo_listar_interno(BIGINT, BIGINT[], CHARACTER VARYING)
    IS 'INTERNO: Listado principal de informes: una fila por (estudiante, periodo) del grupo. EL FINAL SE PIDE METIENDO -1 EN PERIODOS (V439), que es el mismo centinela con el que esa fila viaja en FK_TPERIODO_EVALUACION; antes era el parametro p_incluir_final, que se retira. El cambio no es cosmetico: como -1 no matchea ningun periodo real, ARRAY[-1] deja la CTE de periodos vacia y por fin se puede pedir SOLO el Final -- con la bandera era imposible, porque un arreglo vacio significa (y sigue significando) TODOS los periodos reales, de modo que no habia forma de decir "ninguno". La fila Final llega con FK_TPERIODO_EVALUACION = -1, modo_periodo "final", consolidado false y asignaturas con estado "final"; su nota se calcula al vuelo sobre TODOS los periodos del año, el periodo sin nota guardada vale cero y el promedio general sale de esas mismas asignaturas (V431). EVIDENCIAS cuenta las imagenes adjuntas a observaciones de la fila, y en el Final las del año (V434). Su observacion es la que este GUARDADA en TESTUDIANTE_ANIO_OBSERVACION, con su estado y su marca de desactualizado, que se dispara cuando se CONSOLIDA UN PERIODO NUEVO y no cuando el docente escribe una observacion mas (V435). V335, V411, V412, V428, V431, V434, V435, V439. V474: PROMEDIO_GUARDADO y PROMEDIO_PROYECTADO ya NO salen en porcentaje -- se homologan con fn_promedio_homologar al formato del criterio de evaluacion GENERAL del periodo academico, el mismo con el que se pintan las asignaturas de la fila; antes la columna PR mostraba 70,0 al lado de asignaturas en 3,3. En un formato no numerico los dos vienen NULL y lo que vale son PROMEDIO_VALORACION / PROMEDIO_SIMBOLO y sus gemelas del proyectado; sin criterio configurado se sigue devolviendo el porcentaje crudo. PROMEDIO_FORMATO dice con cual se homologo. Cubre tambien el promedio de la fila Final y la nota requerida que viaja en PROMEDIO_PROYECTADO, porque la conversion esta en un solo punto de la salida. El PUESTO se sigue calculando sobre el porcentaje: la conversion es monotona y redondear antes de ordenar crearia empates que no existen. Cada asignatura del JSON trae CON_RECUPERACION y, con recuperacion de destino NOTA_FINAL, NOTA_ORIGINAL / VALORACION_ORIGINAL / SIMBOLO_ORIGINAL (la nota antes de recuperar); NOTA sigue siendo la resultante (Regla 68), y el PROMEDIO_PROYECTADO usa la resultante en las recuperadas. Sin gate: lo aplica fn_informe_grupo_listar (POST /informes/grupo); es el nucleo que reutiliza el boletin.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_periodo_guardar_interno(p_pk_usuario_solicitante bigint, p_fk_tgrupo bigint, p_fk_tperiodo_evaluacion bigint, p_fk_tmatriculas bigint[] DEFAULT NULL::bigint[])
 RETURNS TABLE(fk_tmatricula bigint, estudiante character varying, guardadas bigint, actualizadas bigint, sin_proyeccion bigint, sin_cambio bigint, promedio numeric, aprobadas bigint, reprobadas bigint, detalle jsonb)
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
DECLARE
    r_mat        RECORD;
    r_asig       RECORD;
    v_prev       NUMERIC;
    v_existe     BOOLEAN;
    v_g          BIGINT;
    v_a          BIGINT;
    v_s          BIGINT;
    v_n          BIGINT;
    v_det        JSONB;
    v_m          RECORD;
    v_hist       JSONB := '[]'::JSONB;
    v_esc        JSONB;
    v_extra      JSONB;
BEGIN
    FOR r_mat IN
        SELECT m.PK_TMATRICULA AS pk,
               NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.PRIMER_APELLIDO)), '')::VARCHAR AS nombre
          FROM academico_test.TMATRICULA m
          LEFT JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          LEFT JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO     = es.FK_TUSUARIO
         WHERE m.FK_TGRUPO = p_fk_tgrupo
           AND m.ACTIVE = TRUE
           AND (p_fk_tmatriculas IS NULL
                OR CARDINALITY(p_fk_tmatriculas) = 0
                OR m.PK_TMATRICULA = ANY (p_fk_tmatriculas))
         ORDER BY 2, 1
    LOOP
        v_g := 0; v_a := 0; v_s := 0; v_n := 0; v_det := '[]'::JSONB;

        FOR r_asig IN
            SELECT d.fk_tasignatura, d.asignatura_nombre, d.nota_proyectada
              FROM academico_test.fn_informe_estudiante_asignaturas_interno(
                       r_mat.pk,
                       ARRAY[p_fk_tperiodo_evaluacion]::BIGINT[]) d
        LOOP
            IF r_asig.nota_proyectada IS NULL THEN
                v_s := v_s + 1;
                v_det := v_det || JSONB_BUILD_OBJECT(
                    'asignatura', r_asig.asignatura_nombre,
                    'resultado',  'sin_proyeccion');
                CONTINUE;
            END IF;

            -- Con Habilitacion lo comparable es la original, no la resultante.
            SELECT CASE WHEN sn.RECUPERACION IS NOT NULL AND sn.DEFINITIVA IS NOT NULL
                        THEN sn.CALIFICACION ELSE sn.DEFINITIVA END, TRUE
              INTO v_prev, v_existe
              FROM academico_test.TASIGNATURA_NOTA sn
             WHERE sn.FK_TMATRICULA          = r_mat.pk
               AND sn.FK_TASIGNATURA         = r_asig.fk_tasignatura
               AND sn.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
               AND sn.ACTIVE = TRUE;

            IF COALESCE(v_existe, FALSE) AND v_prev = r_asig.nota_proyectada THEN
                v_n := v_n + 1;
                v_det := v_det || JSONB_BUILD_OBJECT(
                    'asignatura', r_asig.asignatura_nombre,
                    'resultado',  'sin_cambio',
                    'nota',       r_asig.nota_proyectada);
                v_existe := NULL;
                CONTINUE;
            END IF;

            v_esc := academico_test.fn_informe_nota_periodo_escribir_interno(
                         p_pk_usuario_solicitante, r_mat.pk, r_asig.fk_tasignatura,
                         p_fk_tperiodo_evaluacion, r_asig.nota_proyectada);
            v_extra := CASE WHEN (v_esc->>'con_recuperacion')::BOOLEAN
                            THEN JSONB_BUILD_OBJECT('definitiva',  v_esc->'definitiva',
                                                    'recombinada', v_esc->'recombinada')
                            ELSE '{}'::JSONB END;

            IF COALESCE(v_existe, FALSE) THEN
                v_a := v_a + 1;
                v_det := v_det || (JSONB_BUILD_OBJECT(
                    'asignatura', r_asig.asignatura_nombre,
                    'resultado',  'actualizada',
                    'nota',       r_asig.nota_proyectada,
                    'anterior',   v_prev) || v_extra);
            ELSE
                v_g := v_g + 1;
                v_det := v_det || (JSONB_BUILD_OBJECT(
                    'asignatura', r_asig.asignatura_nombre,
                    'resultado',  'guardada',
                    'nota',       r_asig.nota_proyectada) || v_extra);
            END IF;

            v_existe := NULL;
        END LOOP;

        PERFORM academico_test.fn_informe_metricas_recalcular_interno(
            p_pk_usuario_solicitante, r_mat.pk, p_fk_tperiodo_evaluacion);

        SELECT ipm.PROMEDIO, ipm.APROBADAS, ipm.REPROBADAS
          INTO v_m
          FROM academico_test.TINFORME_PERIODO_MATRICULA ipm
         WHERE ipm.FK_TMATRICULA          = r_mat.pk
           AND ipm.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
           AND ipm.ACTIVE = TRUE;

        -- Al historial SOLO si se escribio algo. Ver el punto (2).
        IF v_g + v_a > 0 THEN
            v_hist := v_hist || JSONB_BUILD_OBJECT(
                'matricula',   r_mat.pk,
                'promedio',    v_m.PROMEDIO,
                'asignaturas', v_g + v_a);
        END IF;

        fk_tmatricula  := r_mat.pk;
        estudiante     := r_mat.nombre;
        guardadas      := v_g;
        actualizadas   := v_a;
        sin_proyeccion := v_s;
        sin_cambio     := v_n;
        promedio       := v_m.PROMEDIO;
        aprobadas      := COALESCE(v_m.APROBADAS, 0)::BIGINT;
        reprobadas     := COALESCE(v_m.REPROBADAS, 0)::BIGINT;
        detalle        := v_det;
        RETURN NEXT;
    END LOOP;

    PERFORM academico_test.fn_informe_historial_registrar_interno(
        p_pk_usuario_solicitante, p_fk_tgrupo, NULL,
        p_fk_tperiodo_evaluacion, 'INFORME', v_hist);
END;
$function$;
COMMENT ON FUNCTION academico_test.fn_informe_periodo_guardar_interno(BIGINT, BIGINT, BIGINT, BIGINT[])
    IS 'INTERNO: Consolida un periodo COMPLETO: congela la nota proyectada de cada asignatura en TASIGNATURA_NOTA para el grupo (o solo las matriculas indicadas; NULL o vacio = todas), deja las metricas al dia via fn_informe_metricas_recalcular y registra el guardado en el historial via fn_informe_historial_registrar con FK_TASIGNATURA NULL, que es lo que marca "informe completo". Al historial solo entran los estudiantes a los que se les ESCRIBIO alguna nota: los sin_cambio y sin_proyeccion no cuentan, y si ninguno cambio no se crea cabecera, para que volver a pulsar guardar no deje entradas vacias. Convive sin pisarse con fn_informe_planilla_guardar, que congela una sola asignatura: TASIGNATURA_NOTA es por (matricula, periodo, asignatura) y ambas terminan en el mismo recalculo y el mismo registrador, asi que son idempotentes y su efecto final no depende del orden. Lo ya guardado con el mismo valor se reporta sin_cambio y no se toca, para no borrar el MODIFIED_AT que dice cuando se consolido. DEFINITIVA se guarda en PORCENTAJE, no homologada, porque la escala depende de TCRITERIO_EVALUACION por (asignatura, grado) y puede cambiar. Preescolar no usa este endpoint: alli todo sale sin_proyeccion porque las observaciones se guardan con CALIFICABLE=N y no promedian. Escribe con fn_informe_nota_periodo_escribir_interno: con una recuperacion de destino NOTA_FINAL la proyectada es la nueva base y la definitiva se recombina; sin_cambio compara contra esa base, y en el DETALLE NOTA y ANTERIOR son la base y se agregan DEFINITIVA y RECOMBINADA. Sin gate ni validaciones: los aplica fn_informe_periodo_guardar (POST /informes/guardar). El usuario es para auditoria y para el historial.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_planilla_guardar_interno(p_pk_usuario_solicitante bigint, p_fk_tgrupo bigint, p_fk_tasignatura bigint, p_fk_tperiodo_evaluacion bigint, p_fk_tmatriculas bigint[] DEFAULT NULL::bigint[])
 RETURNS TABLE(fk_tmatricula bigint, estudiante character varying, resultado character varying, nota_anterior numeric, nota_guardada numeric, promedio_periodo numeric, aprobadas bigint, reprobadas bigint)
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
DECLARE
    r_mat        RECORD;
    v_proy       NUMERIC;
    v_prev       NUMERIC;
    v_existe     BOOLEAN;
    v_res        VARCHAR;
    v_m          RECORD;
    v_hist       JSONB := '[]'::JSONB;
BEGIN
    FOR r_mat IN
        SELECT m.PK_TMATRICULA AS pk,
               NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.PRIMER_APELLIDO)), '')::VARCHAR AS nombre
          FROM academico_test.TMATRICULA m
          LEFT JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          LEFT JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO     = es.FK_TUSUARIO
         WHERE m.FK_TGRUPO = p_fk_tgrupo
           AND m.ACTIVE = TRUE
           AND (p_fk_tmatriculas IS NULL
                OR CARDINALITY(p_fk_tmatriculas) = 0
                OR m.PK_TMATRICULA = ANY (p_fk_tmatriculas))
         ORDER BY 2, 1
    LOOP
        v_proy := academico_test.fn_asignatura_definitiva_proyectada_periodo(
                      r_mat.pk, p_fk_tasignatura, p_fk_tperiodo_evaluacion);

        -- Con Habilitacion lo comparable es la original, no la resultante.
        SELECT CASE WHEN sn.RECUPERACION IS NOT NULL AND sn.DEFINITIVA IS NOT NULL
                        THEN sn.CALIFICACION ELSE sn.DEFINITIVA END, TRUE
          INTO v_prev, v_existe
          FROM academico_test.TASIGNATURA_NOTA sn
         WHERE sn.FK_TMATRICULA          = r_mat.pk
           AND sn.FK_TASIGNATURA         = p_fk_tasignatura
           AND sn.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
           AND sn.ACTIVE = TRUE;

        IF v_proy IS NULL THEN
            v_res := 'sin_proyeccion';
        ELSIF COALESCE(v_existe, FALSE) AND v_prev = v_proy THEN
            v_res := 'sin_cambio';
        ELSE
            PERFORM academico_test.fn_informe_nota_periodo_escribir_interno(
                        p_pk_usuario_solicitante, r_mat.pk, p_fk_tasignatura,
                        p_fk_tperiodo_evaluacion, v_proy);

            v_res := CASE WHEN COALESCE(v_existe, FALSE) THEN 'actualizada'
                          ELSE 'guardada' END;
        END IF;

        PERFORM academico_test.fn_informe_metricas_recalcular_interno(
            p_pk_usuario_solicitante, r_mat.pk, p_fk_tperiodo_evaluacion);

        SELECT ipm.PROMEDIO, ipm.APROBADAS, ipm.REPROBADAS
          INTO v_m
          FROM academico_test.TINFORME_PERIODO_MATRICULA ipm
         WHERE ipm.FK_TMATRICULA          = r_mat.pk
           AND ipm.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
           AND ipm.ACTIVE = TRUE;

        -- Al historial SOLO si se escribio. Una asignatura por estudiante,
        -- de ahi el 1.
        IF v_res IN ('guardada', 'actualizada') THEN
            v_hist := v_hist || JSONB_BUILD_OBJECT(
                'matricula',   r_mat.pk,
                'promedio',    v_m.PROMEDIO,
                'asignaturas', 1);
        END IF;

        fk_tmatricula    := r_mat.pk;
        estudiante       := r_mat.nombre;
        resultado        := v_res;
        nota_anterior    := v_prev;
        nota_guardada    := CASE WHEN v_res IN ('guardada', 'actualizada', 'sin_cambio')
                                 THEN v_proy END;
        promedio_periodo := v_m.PROMEDIO;
        aprobadas        := COALESCE(v_m.APROBADAS, 0)::BIGINT;
        reprobadas       := COALESCE(v_m.REPROBADAS, 0)::BIGINT;
        RETURN NEXT;

        v_prev := NULL; v_existe := NULL;
    END LOOP;

    PERFORM academico_test.fn_informe_historial_registrar_interno(
        p_pk_usuario_solicitante, p_fk_tgrupo, p_fk_tasignatura,
        p_fk_tperiodo_evaluacion, 'PLANILLA', v_hist);
END;
$function$;
COMMENT ON FUNCTION academico_test.fn_informe_planilla_guardar_interno(BIGINT, BIGINT, BIGINT, BIGINT, BIGINT[])
    IS 'INTERNO: Congela la definitiva de UNA asignatura desde la planilla de informes, para el grupo o solo las matriculas indicadas (NULL o vacio = todas), recalcula las metricas del periodo y registra el guardado en el historial con FK_TASIGNATURA puesta, que es lo que lo distingue del guardado del informe completo. Al historial solo entran los estudiantes a los que se les escribio (guardada o actualizada); sin_cambio y sin_proyeccion no cuentan, y si ninguno cambio no se crea cabecera. Es el hermano acotado de fn_informe_periodo_guardar y NO SE PISAN: TASIGNATURA_NOTA es por (matricula, periodo, asignatura), y ambas terminan llamando al mismo recalculo de metricas y al mismo registrador, de modo que el resultado no depende del orden y las dos son idempotentes. El recalculo corre SIEMPRE, incluso en sin_cambio, porque otra asignatura pudo haberse movido desde el ultimo y esa fila las agrega a todas. En sin_proyeccion lo ya guardado NO se borra: quitar un consolidado por una ausencia no es decision de un boton de guardar. Devuelve ademas el promedio y los conteos del periodo ya recalculados, para que la pantalla refresque sin volver a consultar. Escribe con fn_informe_nota_periodo_escribir_interno: con una recuperacion de destino NOTA_FINAL la proyectada es la nueva base y la definitiva se recombina; sin_cambio, NOTA_ANTERIOR y NOTA_GUARDADA se expresan sobre esa base. Sin gate ni validaciones: los aplica fn_informe_planilla_guardar (POST /informes/planilla/guardar). El usuario es para auditoria y para el historial.';
