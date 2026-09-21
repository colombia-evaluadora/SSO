-- ===========================================================================
-- V464 -- asistencia: no se toma a futuro y lo retrasado empieza ayer.
-- Que hace: (1) fn_asistencia_registrar_bulk rechaza con 22023 una p_fecha
--   posterior a hoy; (2) en fn_asistencia_calendario el estado RETRASADA pasa
--   de "fecha <= hoy" a "fecha < hoy", de modo que la sesion del dia que se
--   esta viendo sigue en PENDIENTE y solo vence al dia siguiente.
-- Por que aqui: nada impedia registrar la clase de la semana que viene, y el
--   calendario pintaba en rojo la clase de hoy desde la primera hora de la
--   manana, antes de que hubiera ocurrido. Las tarjetas del encabezado
--   (fn_asistencia_resumen_horas) delegan el conteo en el calendario, asi que
--   se corrigen solas. Migracion nueva para no re-ejecutar V220 entera.
-- Depende de: V220 (ambas definiciones), V457 (recorte de la proyeccion).
-- ===========================================================================

SET search_path TO academico_test, public;

-- Firmas y tipos de retorno intactos en las dos: CREATE OR REPLACE, sin DROP.

CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_registrar_bulk(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fecha                  DATE,
    p_bloque                 NUMERIC DEFAULT NULL,
    -- [{"fkMatricula":1,"tipoAsistencia":1,"observacion":null,"fkArchivo":null}, ...]
    p_registros              JSONB   DEFAULT NULL,
    -- valor de TIPO_ASISTENCIA aplicado a TODO el grupo cuando p_registros
    -- viene NULL/vacio ("Marcar todo como Asistio" -> 1).
    p_marcar_todos_valor     NUMERIC DEFAULT NULL,
    -- Sesion FORMATIVA (preescolar): la clase es una ACTIVIDAD, no una
    -- asignatura + bloque. Va al final para no mover las posiciones que ya
    -- usan los llamadores. Con actividad, p_fk_tasignatura puede ser NULL.
    p_fk_tactividad          BIGINT  DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_afectados  INTEGER := 0;
    v_fk_periodo BIGINT;
    v_entrada    JSONB;
    v_invalido   TEXT;
    v_estado     RECORD;
    v_fk_tsede   BIGINT;
BEGIN
    -- 0. Obligatorios de forma (antes del gate: no filtran informacion).
    --    La asignatura dejo de ser obligatoria: en preescolar la sesion se
    --    identifica por ACTIVIDAD. Se exige al menos uno de los dos, que es
    --    la misma regla que hace cumplir CK_TASISTENCIA_CONTEXTO en la
    --    tabla -- aqui se valida antes para dar un mensaje util en vez de
    --    un error de constraint.
    IF p_fk_tgrupo IS NULL OR p_fecha IS NULL THEN
        RAISE EXCEPTION 'grupo y fecha son obligatorios' USING ERRCODE = '23502';
    END IF;

    -- V464 -- no se toma asistencia de una clase que no ha ocurrido. El dia
    -- de HOY si se permite: la toma normal es durante la clase.
    IF p_fecha > CURRENT_DATE THEN
        RAISE EXCEPTION 'no se puede registrar asistencia en una fecha futura (%); la fecha maxima es hoy (%)',
            p_fecha, CURRENT_DATE
            USING ERRCODE = '22023',
                  HINT = 'Registre la asistencia el dia de la clase o despues.';
    END IF;
    IF p_fk_tasignatura IS NULL AND p_fk_tactividad IS NULL THEN
        RAISE EXCEPTION 'debe enviar la asignatura (sesion por horario) o la actividad (sesion formativa)'
            USING ERRCODE = '23502';
    END IF;

    -- 1. Gate de capability + scope (menu ASISTENCIAS, accion CREAR).
    PERFORM academico_test.fn_asistencia_gate_escritura(
        p_pk_usuario_solicitante, p_fk_tgrupo, 'CREAR');

    IF (p_registros IS NULL OR jsonb_array_length(COALESCE(p_registros, '[]'::jsonb)) = 0)
       AND p_marcar_todos_valor IS NULL THEN
        RAISE EXCEPTION 'debe enviar p_registros o p_marcar_todos_valor' USING ERRCODE = '22023';
    END IF;

    -- 2. FKs de entidad activas.
    IF NOT EXISTS (SELECT 1 FROM academico_test.TGRUPO
                    WHERE PK_TGRUPO = p_fk_tgrupo AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'grupo (%) no existe o no esta activo', p_fk_tgrupo USING ERRCODE = '23503';
    END IF;
    IF p_fk_tasignatura IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM academico_test.TASIGNATURA
                        WHERE PK_TASIGNATURA = p_fk_tasignatura AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'asignatura (%) no existe o no esta activa', p_fk_tasignatura USING ERRCODE = '23503';
    END IF;
    -- La actividad debe existir, estar activa y ser DE ESTE GRUPO: sin el
    -- chequeo de grupo se podria colgar la asistencia de un alumno de una
    -- actividad de otro curso (el gate autoriza sobre el grupo, no sobre la
    -- actividad, asi que esto no lo cubre la autorizacion).
    IF p_fk_tactividad IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD
                        WHERE PK_TACTIVIDAD = p_fk_tactividad AND ACTIVE = TRUE
                          AND FK_TGRUPO = p_fk_tgrupo) THEN
        RAISE EXCEPTION 'la actividad (%) no existe, no esta activa o no pertenece al grupo %',
            p_fk_tactividad, p_fk_tgrupo USING ERRCODE = '23503';
    END IF;

    -- 2b. Periodo academico CERRADO -> no se registra asistencia. Se comprueba
    --     por VALOR (no por pk: varia por ambiente). Otros estados
    --     (Nivelaciones / Inscripciones / Promociones / sin estado) se
    --     permiten; solo 'C' (Cerrado) bloquea.
    SELECT * INTO v_estado FROM academico_test.fn_asistencia_periodo_estado(p_fk_tgrupo);
    IF v_estado.estado_valor = 'C' THEN
        RAISE EXCEPTION 'el periodo academico del grupo % esta %; no se puede registrar asistencia',
            p_fk_tgrupo, COALESCE(v_estado.estado_nombre, 'Cerrado')
            USING ERRCODE = '22023',
                  HINT = 'Reabrir el periodo academico para permitir cambios de asistencia.';
    END IF;

    -- 3. Periodo de evaluacion (NOT NULL en TASISTENCIA): se resuelve.
    v_fk_periodo := academico_test.fn_asistencia_periodo_eval(p_fk_tgrupo, p_fecha);
    IF v_fk_periodo IS NULL THEN
        RAISE EXCEPTION 'no hay periodo de evaluacion activo para el grupo % que contenga la fecha %',
            p_fk_tgrupo, p_fecha USING ERRCODE = '22023';
    END IF;

    -- 3b. Sede del grupo, para acotar el soporte (fkArchivo) del paso 5:
    -- TARCHIVO.FK_TSEDE es la "sede propietaria del archivo" (V22). Sin esto,
    -- cualquier archivo ACTIVE de CUALQUIER sede del sistema pasaba la
    -- validacion -- un docente de la sede A podia adjuntar como soporte un
    -- TARCHIVO que pertenece a la sede B (fuera de su scope).
    v_fk_tsede := academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(p_fk_tgrupo));

    -- 4. Entrada normalizada a JSONB. "Marcar todo": se construye el arreglo
    --    desde las matriculas activas del grupo.
    IF p_registros IS NOT NULL AND jsonb_array_length(p_registros) > 0 THEN
        v_entrada := p_registros;
    ELSE
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'fkMatricula',    m.PK_TMATRICULA,
                   'tipoAsistencia', p_marcar_todos_valor)), '[]'::jsonb)
          INTO v_entrada
          FROM academico_test.TMATRICULA m
         WHERE m.FK_TGRUPO = p_fk_tgrupo AND m.ACTIVE = TRUE;
    END IF;

    -- 5. Validacion de las filas. Un solo recorrido que devuelve el PRIMER
    --    motivo de rechazo (o NULL si todo esta bien), en vez de 4 EXISTS
    --    independientes sobre una tabla temporal.
    SELECT motivo INTO v_invalido
      FROM (
        SELECT CASE
                 WHEN e.fk_matricula IS NULL
                   THEN 'fkMatricula es obligatorio en cada registro'
                 WHEN NOT EXISTS (SELECT 1 FROM academico_test.TMATRICULA m
                                   WHERE m.PK_TMATRICULA = e.fk_matricula
                                     AND m.ACTIVE = TRUE
                                     AND m.FK_TGRUPO = p_fk_tgrupo)
                   THEN format('la matricula %s no existe, no esta activa o no pertenece al grupo %s',
                               e.fk_matricula, p_fk_tgrupo)
                 WHEN e.valor_tipo IS NULL
                   THEN 'falta tipoAsistencia en algun registro y no se envio p_marcar_todos_valor'
                 WHEN academico_test.fn_asistencia_tipo_pk(e.valor_tipo) IS NULL
                   THEN format('tipoAsistencia %s invalido (validos de TIPO_ASISTENCIA: 1,2,3,5,6)',
                               e.valor_tipo)
                 WHEN e.fk_archivo IS NOT NULL
                      AND NOT EXISTS (SELECT 1 FROM academico_test.TARCHIVO ar
                                       WHERE ar.PK_TARCHIVO = e.fk_archivo AND ar.ACTIVE = TRUE
                                         AND (ar.FK_TSEDE IS NULL OR ar.FK_TSEDE = v_fk_tsede))
                   THEN format('el archivo de soporte %s no existe, no esta activo, o no pertenece a la sede del grupo',
                               e.fk_archivo)
                 ELSE NULL
               END AS motivo
          FROM jsonb_array_elements(v_entrada) r
          CROSS JOIN LATERAL (
              SELECT (r->>'fkMatricula')::BIGINT                             AS fk_matricula,
                     COALESCE((r->>'tipoAsistencia')::NUMERIC,
                              p_marcar_todos_valor)                          AS valor_tipo,
                     NULLIF(r->>'fkArchivo', '')::BIGINT                     AS fk_archivo
          ) e
      ) v
     WHERE v.motivo IS NOT NULL
     LIMIT 1;

    IF v_invalido IS NOT NULL THEN
        RAISE EXCEPTION '%', v_invalido USING ERRCODE = '23503';
    END IF;

    -- 6. Upsert (solo columnas de V22).
    WITH entrada AS (
        SELECT (r->>'fkMatricula')::BIGINT                                   AS fk_matricula,
               academico_test.fn_asistencia_tipo_pk(
                   COALESCE((r->>'tipoAsistencia')::NUMERIC,
                            p_marcar_todos_valor))                           AS fk_tlv_tipo,
               NULLIF(TRIM(r->>'observacion'), '')                           AS observacion,
               NULLIF(r->>'fkArchivo', '')::BIGINT                           AS fk_archivo
          FROM jsonb_array_elements(v_entrada) r
    ), up AS (
        INSERT INTO academico_test.TASISTENCIA (
            FECHA, FK_TLV_TIPO_ASISTENCIA, FK_TASIGNATURA, FK_TACTIVIDAD,
            FK_TPERIODO_EVALUACION,
            FK_TMATRICULA, OBSERVACION, FK_SOPORTE_ARCHIVO, BLOQUE,
            CREATED_BY, CREATED_AT, ACTIVE
        )
        SELECT p_fecha, e.fk_tlv_tipo, p_fk_tasignatura, p_fk_tactividad,
               v_fk_periodo,
               e.fk_matricula, e.observacion, e.fk_archivo, p_bloque,
               p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
          FROM entrada e
        -- Target = UQ_TASISTENCIA_SESION (seccion 2), el indice combinado
        -- que cubre las dos identidades de sesion. La lista debe coincidir
        -- EXACTAMENTE con la del indice, COALESCE incluido.
        ON CONFLICT (FK_TMATRICULA,
                     COALESCE(FK_TASIGNATURA, 0),
                     COALESCE(FK_TACTIVIDAD, 0),
                     FECHA,
                     COALESCE(BLOQUE, 0))
                 WHERE ACTIVE = true
        DO UPDATE SET
            FK_TLV_TIPO_ASISTENCIA = EXCLUDED.FK_TLV_TIPO_ASISTENCIA,
            FK_TPERIODO_EVALUACION = EXCLUDED.FK_TPERIODO_EVALUACION,
            OBSERVACION            = EXCLUDED.OBSERVACION,
            FK_SOPORTE_ARCHIVO     = EXCLUDED.FK_SOPORTE_ARCHIVO,
            MODIFIED_BY            = p_pk_usuario_solicitante::VARCHAR,
            MODIFIED_AT            = CURRENT_TIMESTAMP
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_afectados FROM up;

    RETURN v_afectados;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_registrar_bulk(
    BIGINT, BIGINT, BIGINT, DATE, NUMERIC, JSONB, NUMERIC, BIGINT
) IS 'Registro/actualizacion masiva de la asistencia de un grupo en una sesion. La sesion se identifica de dos formas segun el mundo: EVALUATIVO por (asignatura, FECHA, BLOQUE) y FORMATIVO/preescolar por (p_fk_tactividad, FECHA) -- hay que enviar asignatura o actividad (al menos una; la actividad debe ser del mismo grupo). p_registros = JSONB [{fkMatricula,tipoAsistencia,observacion,fkArchivo}]. Si viene vacio y p_marcar_todos_valor no es NULL, aplica ese estado a todas las matriculas activas del grupo ("Marcar todo como Asistio" -> 1). Upsert por (FK_TMATRICULA,FK_TASIGNATURA,FECHA,COALESCE(BLOQUE,0)) sobre filas ACTIVE (UQ_TASISTENCIA_SESION). FK_TPERIODO_EVALUACION resuelto por fn_asistencia_periodo_eval; la franja horaria NO se guarda (se deriva de THORARIO al leer). Gate: fn_asistencia_gate_escritura(usuario, grupo, ''CREAR''). fkArchivo (soporte) debe ser un TARCHIVO ACTIVE cuyo FK_TSEDE sea NULL (generico) o igual a la sede del grupo -- rechaza adjuntar el soporte de otra sede aunque el archivo este activo. Valida todas las filas de entrada en un solo recorrido y lanza con el primer motivo concreto. Retorna # de registros afectados.';


CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_calendario(
    p_pk_usuario      BIGINT,
    p_fk_tsede        BIGINT,
    p_anio            INTEGER,
    p_mes             INTEGER,
    p_fk_tgrupo       BIGINT DEFAULT NULL,
    p_fk_tasignatura  BIGINT DEFAULT NULL,
    p_fecha_hoy       DATE   DEFAULT CURRENT_DATE,
    p_fk_tfuncionario BIGINT DEFAULT NULL
)
RETURNS TABLE (
    fecha             DATE,
    fk_tgrupo         BIGINT,
    grupo             VARCHAR,
    fk_tgrado         BIGINT,
    grado             VARCHAR,
    grado_valor       VARCHAR,
    fk_tlv_jornada    BIGINT,
    jornada           VARCHAR,
    jornada_valor     VARCHAR,
    fk_tasignatura    BIGINT,
    asignatura        VARCHAR,
    -- Sesion FORMATIVA (preescolar): el punto del calendario es una
    -- ACTIVIDAD. es_formativa le dice al front cual de las dos etiquetas
    -- pintar sin tener que adivinar por el NULL.
    fk_tactividad     BIGINT,
    actividad         VARCHAR,
    es_formativa      BOOLEAN,
    bloque            NUMERIC,
    hora_inicio       TIMESTAMP,
    hora_fin          TIMESTAMP,
    horas             NUMERIC,
    -- total_estudiantes = PADRON del grupo (matriculas activas), NO el
    -- numero de filas de asistencia. Antes era lo segundo, y una sesion sin
    -- tomar reportaba 0 estudiantes aunque el grupo tuviera 5 -- ademas de
    -- chocar con fn_asistencia_estudiantes_sesion, que usa ESE MISMO nombre
    -- para el padron. Un solo significado en todo el modulo; lo registrado
    -- va aparte en `registrados`, asi el front puede pintar "3 de 5".
    total_estudiantes BIGINT,
    registrados       BIGINT,
    a_tiempo          BIGINT,
    tarde             BIGINT,
    ausentes          BIGINT,
    estado_sesion     TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_ini DATE := make_date(p_anio, p_mes, 1);
    v_fin DATE := (make_date(p_anio, p_mes, 1) + INTERVAL '1 month')::date;  -- exclusivo
BEGIN
    -- sede, anio y mes son obligatorios: sin ellos el calendario no tiene
    -- ventana. (El endpoint tambien los marca requeridos con "!" en param_types.)
    IF p_fk_tsede IS NULL OR p_anio IS NULL OR p_mes IS NULL THEN
        RAISE EXCEPTION 'sede, anio y mes son obligatorios para el calendario' USING ERRCODE = '22023';
    END IF;
    IF p_mes NOT BETWEEN 1 AND 12 THEN
        RAISE EXCEPTION 'mes invalido: % (1..12)', p_mes USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    -- (a) Sesiones PROGRAMADAS del mes. Dos fuentes EXCLUYENTES (ver
    --     cabecera): horario para los grupos normales, actividades para los
    --     formativos. El filtro NOT fn_asistencia_grupo_es_formativo en la
    --     primera rama es lo que impide que un grupo de preescolar CON
    --     horario cargado aparezca por las dos.
    WITH programadas AS (
        SELECT sp.fecha, sp.fk_tgrupo, sp.grupo, sp.fk_tgrado, sp.grado, sp.grado_valor,
               sp.fk_tlv_jornada, sp.jornada, sp.jornada_valor, sp.fk_tasignatura, sp.asignatura,
               NULL::BIGINT  AS fk_tactividad,
               NULL::VARCHAR AS actividad,
               sp.bloque, sp.hora_inicio, sp.hora_fin, sp.horas
          FROM academico_test.fn_asistencia_sesiones_programadas(
                   p_pk_usuario, p_fk_tsede, v_ini, v_fin - 1,
                   p_fk_tgrupo, p_fk_tasignatura, p_fk_tfuncionario) sp
         WHERE NOT academico_test.fn_asistencia_grupo_es_formativo(sp.fk_tgrupo)
        UNION ALL
        SELECT ap.fecha, ap.fk_tgrupo, ap.grupo, ap.fk_tgrado, ap.grado, ap.grado_valor,
               ap.fk_tlv_jornada, ap.jornada, ap.jornada_valor, ap.fk_tasignatura, ap.asignatura,
               ap.fk_tactividad, ap.actividad,
               -- Una actividad no cuelga de un bloque de horario ni tiene
               -- franja: el front pinta la etiqueta de la actividad.
               NULL::NUMERIC   AS bloque,
               NULL::TIMESTAMP AS hora_inicio,
               NULL::TIMESTAMP AS hora_fin,
               ap.horas
          FROM academico_test.fn_asistencia_actividades_programadas(
                   p_pk_usuario, p_fk_tsede, v_ini, v_fin - 1,
                   p_fk_tgrupo, p_fk_tfuncionario) ap
         WHERE p_fk_tasignatura IS NULL OR ap.fk_tasignatura = p_fk_tasignatura
    ),
    -- (b) Sesiones REGISTRADAS del mes, ya agregadas por sesion.
    registradas AS (
        SELECT d.fecha, d.fk_tgrupo, d.grupo, d.fk_tgrado, d.grado, d.grado_valor,
               d.fk_tlv_jornada, d.jornada, d.jornada_valor, d.fk_tasignatura, d.asignatura,
               d.fk_tactividad, d.actividad,
               d.bloque,
               MIN(d.hora_inicio)                            AS hora_inicio,
               MIN(d.hora_fin)                               AS hora_fin,
               MIN(d.horas)                                  AS horas,
               COUNT(*)                                      AS n_total,
               COUNT(*) FILTER (WHERE d.tipo_valor = 1)      AS n_a_tiempo,
               COUNT(*) FILTER (WHERE d.es_tarde)            AS n_tarde,
               COUNT(*) FILTER (WHERE d.es_ausente)          AS n_ausentes
          FROM academico_test.v_asistencia_detalle d
         WHERE d.fecha >= v_ini AND d.fecha < v_fin
           AND d.fk_tsede = p_fk_tsede
           AND (p_fk_tgrupo      IS NULL OR d.fk_tgrupo = p_fk_tgrupo)
           AND (p_fk_tasignatura IS NULL OR d.fk_tasignatura = p_fk_tasignatura)
           AND (p_fk_tfuncionario IS NULL OR EXISTS (
                   SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
                    WHERE da.FK_TFUNCIONARIO = p_fk_tfuncionario
                      AND da.FK_TGRUPO       = d.fk_tgrupo
                      AND da.FK_TASIGNATURA  = d.fk_tasignatura
                      AND da.ACTIVE = TRUE))
           AND academico_test.fn_asistencia_puede_ver(p_pk_usuario, d.fk_tgrupo)
         GROUP BY d.fecha, d.fk_tgrupo, d.grupo, d.fk_tgrado, d.grado, d.grado_valor,
                  d.fk_tlv_jornada, d.jornada, d.jornada_valor, d.fk_tasignatura, d.asignatura,
                  d.fk_tactividad, d.actividad, d.bloque
    ),
    -- Padron por grupo, resuelto UNA vez: una subconsulta correlacionada por
    -- fila costaria una pasada por cada sesion del mes de toda la sede.
    padron AS (
        SELECT m.FK_TGRUPO AS fk_tgrupo, COUNT(*)::BIGINT AS matriculas
          FROM academico_test.TMATRICULA m
         WHERE m.ACTIVE = TRUE
         GROUP BY m.FK_TGRUPO
    )
    SELECT
        COALESCE(p.fecha, r.fecha),
        COALESCE(p.fk_tgrupo, r.fk_tgrupo),
        COALESCE(p.grupo, r.grupo),
        COALESCE(p.fk_tgrado, r.fk_tgrado),
        COALESCE(p.grado, r.grado),
        COALESCE(p.grado_valor, r.grado_valor),
        COALESCE(p.fk_tlv_jornada, r.fk_tlv_jornada),
        COALESCE(p.jornada, r.jornada),
        COALESCE(p.jornada_valor, r.jornada_valor),
        COALESCE(p.fk_tasignatura, r.fk_tasignatura),
        COALESCE(p.asignatura, r.asignatura),
        COALESCE(p.fk_tactividad, r.fk_tactividad),
        COALESCE(p.actividad, r.actividad),
        (COALESCE(p.fk_tactividad, r.fk_tactividad) IS NOT NULL),
        COALESCE(p.bloque, r.bloque),
        COALESCE(p.hora_inicio, r.hora_inicio),
        COALESCE(p.hora_fin, r.hora_fin),
        -- Reusa la duracion YA calculada (con reserva de jornada) por cada
        -- CTE -- no se recalcula desde hora_inicio/hora_fin, que es lo que
        -- antes tiraba a 0h cuando THORARIO no las traia.
        COALESCE(p.horas, r.horas, 0),
        COALESCE(pad.matriculas, 0)::BIGINT,
        COALESCE(r.n_total, 0)::BIGINT,
        COALESCE(r.n_a_tiempo, 0)::BIGINT,
        COALESCE(r.n_tarde, 0)::BIGINT,
        COALESCE(r.n_ausentes, 0)::BIGINT,
        CASE WHEN r.n_total IS NOT NULL                       THEN 'REGISTRADA'
             -- V464 -- el dia que se esta viendo NO cuenta como retrasado:
             -- su clase aun se puede tomar. Lo es desde el dia siguiente.
             WHEN COALESCE(p.fecha, r.fecha) <  p_fecha_hoy   THEN 'RETRASADA'
             ELSE 'PENDIENTE'
        END
      FROM programadas p
      FULL OUTER JOIN registradas r
        ON r.fecha          = p.fecha
       AND r.fk_tgrupo      = p.fk_tgrupo
       -- La ACTIVIDAD entra en la clave, y cuando esta presente es lo UNICO
       -- que identifica la sesion: ni la asignatura ni el bloque cuentan.
       --
       --   *** POR QUE (bug real, visto en el servidor) ***
       --   Una sesion formativa se GUARDA con FK_TASIGNATURA NULL (asi lo
       --   escribe fn_asistencia_registrar_bulk cuando el cliente manda solo
       --   ACTIVIDAD), pero la PROYECCION la trae con la asignatura de la
       --   actividad (TACTIVIDAD.FK_TASIGNATURA es NOT NULL). Comparando la
       --   asignatura, esos dos lados NUNCA casaban y la misma sesion salia
       --   DOS veces: una REGISTRADA con sus alumnos y otra RETRASADA con 0.
       --   Ademas hay filas sembradas por el Planeador que traen asignatura
       --   Y actividad, asi que tampoco sirve forzar NULL en la proyeccion:
       --   la unica clave estable en el mundo formativo es la actividad.
       AND COALESCE(r.fk_tactividad, -1) = COALESCE(p.fk_tactividad, -1)
       AND (p.fk_tactividad IS NOT NULL
            OR (COALESCE(r.fk_tasignatura, -1) = COALESCE(p.fk_tasignatura, -1)
                AND COALESCE(r.bloque, -1) = COALESCE(p.bloque, -1)))
      LEFT JOIN padron pad ON pad.fk_tgrupo = COALESCE(p.fk_tgrupo, r.fk_tgrupo)
     ORDER BY 1, 3, 11, 15;  -- fecha, grupo, asignatura, bloque
                             -- (15 y no 14: fk_tactividad/actividad/
                             --  es_formativa entraron antes de bloque)
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_calendario(
    BIGINT, BIGINT, INTEGER, INTEGER, BIGINT, BIGINT, DATE, BIGINT
) IS 'Pantalla Asistencia (calendario mensual por sede). Una fila por SESION del mes: las PROGRAMADAS (fn_asistencia_sesiones_programadas) en FULL OUTER JOIN con las REGISTRADAS, de modo que tambien aparecen las tomas manuales sin bloque programado. Incluye grado (fk_tgrado/grado/grado_valor -- CODIGO de TGRADO) y jornada (fk_tlv_jornada/jornada/jornada_valor -- NOMBRE/VALOR de TLISTA_VALOR CATEGORIA=''JORNADA'') del grupo de cada sesion. estado_sesion = REGISTRADA (hay registro) | RETRASADA (fecha < p_fecha_hoy sin registro -- se cuenta desde el DIA ANTERIOR, V464: la sesion de hoy todavia se puede tomar y no se pinta vencida) | PENDIENTE (hoy o futuro, sin registro) -- los 3 contadores del encabezado. p_fk_tfuncionario no NULL acota a las asignaturas asignadas a ese docente en TDOCENTE_ASIGNATURA (vista "mis clases"). Rango de fechas sargable. Alcance por rol via fn_asistencia_puede_ver.';
