-- Agrega la columna bloqueado_preescolar a fn_asignacion_pool (V46).
--
-- Contexto: en preescolar el director de grupo se auto-asigna como docente
-- de todas las dimensiones del plan (fn_docente_director_grupo_sync /
-- fn_docente_grado_directores_sync, V285). Esas asignaciones se recalculan
-- automaticamente en cada guardado de plan/grupo, asi que no deben poder
-- quitarse a mano desde el transfer-list de Asignaciones Academicas: el
-- front usa bloqueado_preescolar para desactivar el boton de "quitar" en
-- esas filas puntuales.
--
-- Por que esta migracion existe (y no el cambio en V46 directamente):
-- este mismo cambio se probo primero como edicion in-place de V46, y
-- Flyway lo rechazo en un despliegue real -- V46 corre ANTES que V285 en
-- el orden de migraciones, y CREATE FUNCTION ... LANGUAGE sql SI valida en
-- el momento de creacion que las funciones referenciadas en el cuerpo ya
-- existan (a diferencia de lo asumido antes: no es resolucion diferida a
-- tiempo de ejecucion). El error real fue:
--   ERROR: function academico_test.fn_grado_es_preescolar(bigint) does not exist
-- Por eso el cambio va en una migracion aparte, numerada DESPUES de V285
-- (donde vive fn_grado_es_preescolar), en vez de tocar V46 in-place.
--
-- CREATE OR REPLACE es aditivo sobre el RETURNS TABLE: mismos parametros,
-- mismo WHERE, mismo ORDER BY; el registro en public.query usa
-- "SELECT * FROM academico_test.fn_asignacion_pool(...)" (V92), asi que no
-- requiere cambios.
DROP FUNCTION IF EXISTS academico_test.fn_asignacion_pool(BIGINT, TEXT, BOOLEAN, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_pool(
    p_academic_period_id BIGINT,
    p_filtro             TEXT    DEFAULT NULL,
    p_solo_sin_docente   BOOLEAN DEFAULT FALSE,
    p_pk_usuario         BIGINT  DEFAULT NULL
)
RETURNS TABLE (
    id TEXT, nombre VARCHAR, grado_grupo TEXT, jornada VARCHAR, jornada_name VARCHAR,
    funcionario_id BIGINT, bloqueado_preescolar BOOLEAN
)
LANGUAGE sql STABLE AS $$
    SELECT gr.PK_TGRUPO || ':' || s.PK_TASIGNATURA, s.NOMBRE,
           g.NOMBRE || ' ' || gr.NOMBRE, jor.VALOR, jor.NOMBRE, da.FK_TFUNCIONARIO,
           da.FK_TFUNCIONARIO IS NOT NULL
               AND academico_test.fn_grado_es_preescolar(g.PK_TGRADO)
               AND da.FK_TFUNCIONARIO = gr.FK_TFUNCIONARIO
      FROM academico_test.TGRADO g
      JOIN academico_test.TGRUPO gr            ON gr.FK_TGRADO = g.PK_TGRADO AND gr.ACTIVE = TRUE
      JOIN academico_test.TPLAN p              ON p.FK_TGRADO = g.PK_TGRADO AND p.ACTIVE = TRUE
      JOIN academico_test.TASIGNATURA_PLAN ap  ON ap.FK_TPLAN = p.PK_TPLAN AND ap.ACTIVE = TRUE
      JOIN academico_test.TASIGNATURA s        ON s.PK_TASIGNATURA = ap.FK_TASIGNATURA AND s.ACTIVE = TRUE
      LEFT JOIN academico_test.TLISTA_VALOR jor ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
      LEFT JOIN academico_test.TDOCENTE_ASIGNATURA da
             ON da.FK_TGRUPO = gr.PK_TGRUPO AND da.FK_TASIGNATURA = s.PK_TASIGNATURA
            AND da.FK_TPERIODO_ACADEMICO = p_academic_period_id AND da.ACTIVE = TRUE
     WHERE g.FK_TPERIODO_ACADEMICO = p_academic_period_id AND g.ACTIVE = TRUE
       AND academico_test.fn_periodo_puede_ver(p_pk_usuario, p_academic_period_id)
       AND (NULLIF(TRIM(p_filtro),'') IS NULL
            OR s.NOMBRE  ILIKE '%' || p_filtro || '%'
            OR g.NOMBRE  ILIKE '%' || p_filtro || '%'
            OR gr.NOMBRE ILIKE '%' || p_filtro || '%'
            OR jor.VALOR ILIKE '%' || p_filtro || '%')
       -- Se conserva por compatibilidad: TRUE sigue significando "solo
       -- libres". El front ya no lo manda -- filtra "libre vs. de otro
       -- docente" con `funcionario_id` en el cliente.
       AND (NOT COALESCE(p_solo_sin_docente, FALSE) OR da.FK_TFUNCIONARIO IS NULL)
     ORDER BY g.NOMBRE, gr.NOMBRE, s.NOMBRE;
$$;
