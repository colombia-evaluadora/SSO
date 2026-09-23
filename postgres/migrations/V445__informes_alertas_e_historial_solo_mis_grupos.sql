-- ===========================================================================
-- V445 - Las alertas y el historial dejan de mostrar grupos ajenos.
--
--   fn_informe_planillas_pendientes   la alerta roja
--   fn_informe_cambios_pendientes     la alerta naranja
--   fn_informe_historial_listar       el modal de historial
--
--
-- QUE FALTABA
--   V444 dejo estas tres fuera a proposito: reciben un ARREGLO de grupos y
--   son agregados, no accesos -- devuelven alertas y registros de lo que ya
--   paso, no los datos del informe --, asi que no abrian nada que el
--   usuario no pudiera pedir por otro lado.
--
--   Pero si producian RUIDO: un docente veia alertas e historial de grupos
--   que no puede abrir. Eso es lo que se corrige aca. No es un agujero de
--   seguridad que se cierra, es una pantalla que deja de mentir.
--
--
-- SE DESCARTA, NO SE FALLA -- Y NO ES LO MISMO QUE EN V444
--   En V444 pedir por id un grupo ajeno responde 42501, porque ahi el
--   usuario eligio ese grupo: es una peticion equivocada y decirlo es lo
--   correcto.
--
--   Aca no. El front manda la lista de PESTAÑAS ABIERTAS, que el usuario no
--   escribio: salen de la URL y de lo que quedo guardado de la sesion
--   anterior. Si una de ellas ya no le corresponde, fallar tumbaria las
--   alertas de todos los grupos que SI puede ver -- por un grupo que el ni
--   siquiera pidio. Asi que ese se descarta y el resto se responde.
--
--   El gate TERRITORIAL de adentro del bucle se conserva tal cual, fallando:
--   pedir un grupo de otra sede si es un error de quien llama, y ahi callar
--   seria esconder un problema real.
--
-- Idempotente: solo CREATE OR REPLACE, ninguna cambia de firma.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- fn_informe_planillas_pendientes
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_planillas_pendientes(p_pk_usuario_solicitante bigint, p_fk_tgrupos bigint[], p_fk_periodos_evaluacion bigint[] DEFAULT NULL::bigint[])
 RETURNS TABLE(fk_tgrupo bigint, grupo_nombre character varying, fk_tasignatura bigint, asignatura_nombre character varying, fk_tfuncionario bigint, fk_tusuario_docente bigint, docente character varying, docentes_asignados bigint, fk_tperiodo_evaluacion bigint, periodo_nombre character varying, periodo_abreviacion character varying, periodo_fin date, estudiantes bigint, actividades bigint)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    r_g          RECORD;
    -- V445 -- los grupos que de verdad se van a consultar: los pedidos
    -- menos los que el usuario no puede ver por no dirigirlos.
    v_grupos     BIGINT[] := ARRAY[]::BIGINT[];
    v_solo_mios  BOOLEAN;
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
BEGIN
    IF p_fk_tgrupos IS NULL OR CARDINALITY(p_fk_tgrupos) = 0 THEN
        RAISE EXCEPTION 'Debe indicar al menos un grupo'
            USING ERRCODE = '22023';
    END IF;

    v_solo_mios := academico_test.fn_usuario_solo_sus_grupos(p_pk_usuario_solicitante);

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

        -- V445 -- el recorte por grupo DESCARTA en silencio, no falla.
        -- Es la diferencia con el gate de arriba y es deliberada: pedir
        -- un grupo de otra sede es un error de quien llama, pero pedir
        -- uno de la propia sede que no se dirige es lo que hace el front
        -- solo, con las pestañas que quedaron abiertas. Fallar ahi
        -- tumbaria las alertas de los grupos que SI puede ver.
        IF NOT v_solo_mios
           OR EXISTS (SELECT 1
                        FROM academico_test.fn_usuario_grupos_dirigidos(
                                 p_pk_usuario_solicitante) g
                       WHERE g.grupo_id = r_g.pk) THEN
            v_grupos := v_grupos || r_g.pk;
        END IF;
    END LOOP;

    RETURN QUERY
    WITH grupos AS (
        SELECT gr.PK_TGRUPO            AS pk,
               gr.NOMBRE               AS nombre,
               gd.FK_TPERIODO_ACADEMICO AS peraca
          FROM academico_test.TGRUPO gr
          JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
         WHERE gr.PK_TGRUPO = ANY (v_grupos)
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
$function$
;

-- ---------------------------------------------------------------------------
-- fn_informe_cambios_pendientes
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_cambios_pendientes(p_pk_usuario_solicitante bigint, p_fk_tgrupos bigint[], p_fk_periodos_evaluacion bigint[] DEFAULT NULL::bigint[])
 RETURNS TABLE(fk_tgrupo bigint, grupo_nombre character varying, fk_tasignatura bigint, asignatura_nombre character varying, fk_tperiodo_evaluacion bigint, periodo_nombre character varying, periodo_abreviacion character varying, fk_tfuncionario bigint, fk_tusuario_docente bigint, docente character varying, docentes_asignados bigint, estudiantes_afectados bigint, ultimo_cambio timestamp without time zone)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    r_g          RECORD;
    -- V445 -- los grupos que de verdad se van a consultar: los pedidos
    -- menos los que el usuario no puede ver por no dirigirlos.
    v_grupos     BIGINT[] := ARRAY[]::BIGINT[];
    v_solo_mios  BOOLEAN;
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
BEGIN
    IF p_fk_tgrupos IS NULL OR CARDINALITY(p_fk_tgrupos) = 0 THEN
        RAISE EXCEPTION 'Debe indicar al menos un grupo'
            USING ERRCODE = '22023';
    END IF;

    v_solo_mios := academico_test.fn_usuario_solo_sus_grupos(p_pk_usuario_solicitante);

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

        -- V445 -- el recorte por grupo DESCARTA en silencio, no falla.
        -- Es la diferencia con el gate de arriba y es deliberada: pedir
        -- un grupo de otra sede es un error de quien llama, pero pedir
        -- uno de la propia sede que no se dirige es lo que hace el front
        -- solo, con las pestañas que quedaron abiertas. Fallar ahi
        -- tumbaria las alertas de los grupos que SI puede ver.
        IF NOT v_solo_mios
           OR EXISTS (SELECT 1
                        FROM academico_test.fn_usuario_grupos_dirigidos(
                                 p_pk_usuario_solicitante) g
                       WHERE g.grupo_id = r_g.pk) THEN
            v_grupos := v_grupos || r_g.pk;
        END IF;
    END LOOP;

    RETURN QUERY
    WITH matriculas AS (
        SELECT m.PK_TMATRICULA AS pk,
               m.FK_TGRUPO     AS grupo
          FROM academico_test.TMATRICULA m
         WHERE m.FK_TGRUPO = ANY (v_grupos)
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
$function$
;

-- ---------------------------------------------------------------------------
-- fn_informe_historial_listar
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_historial_listar(p_pk_usuario_solicitante bigint, p_fk_tgrupos bigint[] DEFAULT NULL::bigint[], p_fk_periodos_evaluacion bigint[] DEFAULT NULL::bigint[], p_anio integer DEFAULT NULL::integer, p_limite integer DEFAULT 100)
 RETURNS TABLE(pk_tinforme_guardado bigint, fecha date, momento timestamp without time zone, fk_tgrupo bigint, grupo_nombre character varying, fk_tasignatura bigint, asignatura_nombre character varying, origen character varying, fk_tperiodo_evaluacion bigint, periodo_nombre character varying, periodo_abreviacion character varying, fk_tusuario bigint, guardado_por character varying, estudiantes bigint, detalle jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_anio  INTEGER;
    v_nivel INT;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER');

    v_anio  := COALESCE(p_anio, EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER);
    v_nivel := academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante);

    RETURN QUERY
    SELECT ig.PK_TINFORME_GUARDADO,
           ig.CREATED_AT::DATE,
           ig.CREATED_AT,
           ig.FK_TGRUPO,
           gr.NOMBRE,
           ig.FK_TASIGNATURA,
           asg.NOMBRE,
           ig.ORIGEN,
           ig.FK_TPERIODO_EVALUACION,
           pe.NOMBRE,
           pe.ABREVIACION,
           ig.FK_TUSUARIO,
           NULLIF(TRIM(CONCAT_WS(' ', uq.PRIMER_NOMBRE, uq.PRIMER_APELLIDO)), '')::VARCHAR,
           ig.ESTUDIANTES::BIGINT,
           COALESCE(det.detalle, '[]'::JSONB)
      FROM academico_test.TINFORME_GUARDADO ig
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = ig.FK_TGRUPO
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
      JOIN academico_test.TANO_LECTIVO al
        ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
       -- NOMBRE es VARCHAR: se valida el formato antes de castear para que un
       -- registro sucio no tumbe la consulta con 22P02.
       AND al.NOMBRE ~ '^[0-9]{4}$'
       AND al.NOMBRE::INTEGER = v_anio
      JOIN academico_test.TPERIODO_EVALUACION pe
        ON pe.PK_TPERIODO_EVALUACION = ig.FK_TPERIODO_EVALUACION
      LEFT JOIN academico_test.TASIGNATURA asg
             ON asg.PK_TASIGNATURA = ig.FK_TASIGNATURA
      LEFT JOIN academico_test.TUSUARIO uq
             ON uq.PK_TUSUARIO = ig.FK_TUSUARIO
      LEFT JOIN LATERAL (
            SELECT JSONB_AGG(
                       JSONB_BUILD_OBJECT(
                           'matricula',   ige.FK_TMATRICULA,
                           'estudiante',  NULLIF(TRIM(CONCAT_WS(' ',
                                              ue.PRIMER_NOMBRE, ue.SEGUNDO_NOMBRE,
                                              ue.PRIMER_APELLIDO, ue.SEGUNDO_APELLIDO)), ''),
                           'documento',   ue.IDENTIFICACION,
                           -- Copiado al guardar, NO recalculado: el historial
                           -- dice que paso ese dia. Ver V348.
                           'promedio',    ige.PROMEDIO,
                           'asignaturas', ige.ASIGNATURAS_AFECTADAS
                       ) ORDER BY NULLIF(TRIM(CONCAT_WS(' ',
                              ue.PRIMER_NOMBRE, ue.PRIMER_APELLIDO)), '')
                   ) AS detalle
              FROM academico_test.TINFORME_GUARDADO_ESTUDIANTE ige
              JOIN academico_test.TMATRICULA m ON m.PK_TMATRICULA = ige.FK_TMATRICULA
              LEFT JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
              LEFT JOIN academico_test.TUSUARIO ue     ON ue.PK_TUSUARIO   = es.FK_TUSUARIO
             WHERE ige.FK_TINFORME_GUARDADO = ig.PK_TINFORME_GUARDADO
               AND ige.ACTIVE = TRUE
      ) det ON TRUE
     WHERE ig.ACTIVE = TRUE
       -- Alcance. Niveles 0 y 1 alcanzan todo; fn_usuario_ee_accesibles no
       -- trae ese bypass y sin replicarlo verian el historial vacio.
       AND (v_nivel <= 1
            OR EXISTS (
                 SELECT 1
                   FROM academico_test.fn_usuario_ee_accesibles(p_pk_usuario_solicitante) ee
                  WHERE ee.establecimiento_id = s.FK_TESTABLECIMIENTO
               )
            -- V445 -- faltaba la rama de NIVEL 3. fn_usuario_ee_accesibles
            -- devuelve CERO establecimientos para ellos -- su alcance es por
            -- (sede, jornada) --, asi que sin esto el historial salia VACIO
            -- para todo docente, coordinador y psico-orientador, incluso
            -- para sus propios grupos. Es el mismo descuido que el comentario
            -- de fn_informe_alcanza_sede_jornada advierte para los niveles 0
            -- y 1: vacio se lee como "no hay nada", no como "no tenes permiso".
            OR EXISTS (
                 SELECT 1
                   FROM academico_test.fn_usuario_sedes_jornadas_accesibles(
                            p_pk_usuario_solicitante) sj
                  WHERE sj.sede_id    = pa.FK_TSEDE
                    AND sj.jornada_id = pa.FK_TLV_JORNADA
               ))
       AND (p_fk_tgrupos IS NULL
            OR CARDINALITY(p_fk_tgrupos) = 0
            OR ig.FK_TGRUPO = ANY (p_fk_tgrupos))
       -- V445 -- y ademas, quien solo alcanza sus grupos ve solo los
       -- suyos. Aca se filtra en vez de fallar por lo mismo que en las
       -- alertas: el historial se pide con las pestañas abiertas, no con
       -- un grupo que el usuario eligio a mano.
       AND (NOT academico_test.fn_usuario_solo_sus_grupos(p_pk_usuario_solicitante)
            OR ig.FK_TGRUPO IN (SELECT g2.grupo_id
                                  FROM academico_test.fn_usuario_grupos_dirigidos(
                                           p_pk_usuario_solicitante) g2))
       AND (p_fk_periodos_evaluacion IS NULL
            OR CARDINALITY(p_fk_periodos_evaluacion) = 0
            OR ig.FK_TPERIODO_EVALUACION = ANY (p_fk_periodos_evaluacion))
     ORDER BY ig.CREATED_AT DESC, ig.PK_TINFORME_GUARDADO DESC
     LIMIT GREATEST(COALESCE(p_limite, 100), 1);
END;
$function$
;
