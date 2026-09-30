-- ===========================================================================
-- V112 - Rendimiento del listado de funcionarios: indices sobre TSEDE_USUARIO y
-- trigram de TUSUARIO, y los helpers que siguen vigentes. Los listados y
-- contadores que nacieron aqui viven hoy en V116/V130; fn_puede_afectar_
-- establecimiento en V302 (COMMENT en V517).
-- ===========================================================================


SET search_path TO academico_test, public;

CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX IF NOT EXISTS idx_tsede_usuario_fk_tusuario_activo
    ON academico_test.TSEDE_USUARIO (FK_TUSUARIO, PREDETERMINADO DESC, ORDEN, PK_TSEDE_USUARIO)
 WHERE ACTIVE = TRUE;

COMMENT ON INDEX academico_test.idx_tsede_usuario_fk_tusuario_activo
    IS 'Soporta (a) lookups puntuales FK_TUSUARIO+ACTIVE de fn_usu_empleados_listar/contar (sedes_agg, estados_agg, roles_agg, EXISTS de roles/campus/work_schedules), y (b) el pick de jornada (LEFT JOIN LATERAL ... ORDER BY PREDETERMINADO DESC, ORDEN, PK_TSEDE_USUARIO LIMIT 1) sin sort externo. V112.';

CREATE INDEX IF NOT EXISTS idx_tusuario_busqueda_trgm
    ON academico_test.TUSUARIO
 USING gin (
    (COALESCE(PRIMER_NOMBRE,'') || ' ' || COALESCE(SEGUNDO_NOMBRE,'') || ' ' ||
     COALESCE(PRIMER_APELLIDO,'') || ' ' || COALESCE(SEGUNDO_APELLIDO,'') || ' ' ||
     COALESCE(IDENTIFICACION,''))
    gin_trgm_ops
 );

COMMENT ON INDEX academico_test.idx_tusuario_busqueda_trgm
    IS 'GIN trigram sobre nombres+apellidos+identificacion concatenados, para que p_search (ILIKE %texto%) de fn_usu_empleados_listar/contar deje de hacer Seq Scan sobre TUSUARIO. El texto de la expresion debe coincidir exacto con el del WHERE de esas funciones. V112.';

CREATE OR REPLACE FUNCTION academico_test.fn_resolver_establecimiento_unico(p_pk_usuario BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT x.PK_ESTABLECIMIENTO
      FROM (
          SELECT ee.PK_ESTABLECIMIENTO, COUNT(*) OVER () AS n
            FROM (
                SELECT e.PK_ESTABLECIMIENTO
                  FROM academico_test.TESTABLECIMIENTO e
                  JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
                 WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario
                UNION
                SELECT e.PK_ESTABLECIMIENTO
                  FROM academico_test.TESTABLECIMIENTO e
                  JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
                 WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario
                UNION
                SELECT DISTINCT s.FK_TESTABLECIMIENTO
                  FROM academico_test.TSEDE_USUARIO su
                  JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
                 WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 8
                   AND su.FK_TUSUARIO = p_pk_usuario
            ) ee
      ) x
     WHERE x.n = 1;
$$;

COMMENT ON FUNCTION academico_test.fn_resolver_establecimiento_unico(BIGINT)
    IS 'Resuelve el establecimiento del usuario cuando es inequivoco: rector o secretaria de un establecimiento, o vinculado (FK_TROL=8) a exactamente una sede cuyo establecimiento coincide. Si el usuario esta ligado a mas de un establecimiento por esas vias, retorna NULL (ambiguo -> el caller trata esto como "sin permiso" salvo que sea superadmin). Baseline capturado del servidor en V112 (no existia en ninguna migracion previa del repo). Sin cambios de logica.';

ANALYZE academico_test.TSEDE_USUARIO;

ANALYZE academico_test.TUSUARIO;

ANALYZE academico_test.TFUNCIONARIO;
