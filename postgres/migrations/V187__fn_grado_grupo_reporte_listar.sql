-- Reporte "Grados y grupos" (RN-06/RN-07/RN-10): la pantalla de edicion tiene
-- DOS funciones separadas -- fn_grado_listar (todos los grados de un
-- periodo) y fn_grupo_listar (los grupos de UN grado a la vez) -- porque son
-- dos niveles de un mismo arbol que se editan por separado. El reporte pide
-- una sola exportacion con grado + numero de grado + nivel de ensenanza +
-- grupo + jornada + director de grupo + plan de estudio, para TODOS los
-- grados del periodo (RN-10: "reportes completos de todos los grados").
--
-- Un grado sin grupos todavia (recien creado) sigue apareciendo en el
-- reporte (LEFT JOIN a TGRUPO) -- "estructura academica vigente del periodo"
-- (RN-06) incluye grados aunque aun no tengan grupos armados.
CREATE OR REPLACE FUNCTION academico_test.fn_grado_grupo_reporte_listar(
    p_fk_periodo BIGINT,
    p_fk_grado   BIGINT[] DEFAULT NULL,
    p_pk_usuario BIGINT   DEFAULT NULL,
    p_page_index INT      DEFAULT 0,
    p_page_size  INT      DEFAULT 10
)
RETURNS TABLE (
    grado_id BIGINT, grado_name VARCHAR, grado_codigo VARCHAR,
    teaching_level_id BIGINT, teaching_level_name VARCHAR,
    grupo_id BIGINT, grupo_name VARCHAR,
    jornada_id BIGINT, jornada_name VARCHAR,
    director_id BIGINT, director_name TEXT,
    plan_estudio_name VARCHAR, total_count BIGINT
)
LANGUAGE sql STABLE AS $$
    SELECT g.PK_TGRADO, g.NOMBRE, g.CODIGO,
           g.FK_TNIVEL_ENSENANZA, ne.NOMBRE,
           gr.PK_TGRUPO, gr.NOMBRE,
           jor.PK_LISTA_VALOR, jor.NOMBRE,
           df.PK_TFUNCIONARIO,
           NULLIF(TRIM(regexp_replace(
               concat_ws(' ', du.PRIMER_NOMBRE, du.SEGUNDO_NOMBRE, du.PRIMER_APELLIDO, du.SEGUNDO_APELLIDO),
               '\s+', ' ', 'g')), ''),
           plan.NOMBRE,
           count(*) OVER()::BIGINT
      FROM academico_test.TGRADO g
      JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
 LEFT JOIN academico_test.TGRUPO gr            ON gr.FK_TGRADO = g.PK_TGRADO AND gr.ACTIVE = TRUE
 LEFT JOIN academico_test.TLISTA_VALOR jor     ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
 LEFT JOIN academico_test.TFUNCIONARIO df      ON df.PK_TFUNCIONARIO = gr.FK_TFUNCIONARIO
 LEFT JOIN academico_test.TUSUARIO du          ON du.PK_TUSUARIO = df.FK_TUSUARIO
 LEFT JOIN LATERAL (
       SELECT p.NOMBRE
         FROM academico_test.TPLAN p
        WHERE p.FK_TGRADO = g.PK_TGRADO AND p.ACTIVE = TRUE
        ORDER BY p.PK_TPLAN
        LIMIT 1
 ) plan ON TRUE
     WHERE g.FK_TPERIODO_ACADEMICO = p_fk_periodo AND g.ACTIVE = TRUE
       AND academico_test.fn_periodo_usuario_puede_ver(p_pk_usuario, p_fk_periodo)
       AND (p_fk_grado IS NULL OR CARDINALITY(p_fk_grado) = 0 OR g.PK_TGRADO = ANY(p_fk_grado))
     ORDER BY g.NOMBRE, gr.NOMBRE
     LIMIT NULLIF(p_page_size, 0)
    OFFSET COALESCE(p_page_index, 0) * COALESCE(NULLIF(p_page_size, 0), 0);
$$;
