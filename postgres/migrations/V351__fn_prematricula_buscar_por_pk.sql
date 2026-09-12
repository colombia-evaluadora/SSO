-- ===========================================================================
-- V351 - fn_prematricula_buscar_por_pk: el detalle de UNA pre-matricula.
--
-- POR QUE VA APARTE DEL LISTADO
--   fn_prematricula_listar (V350) devuelve solo lo que pinta la tabla. La
--   ficha -- datos completos del estudiante y del acudiente -- se pide por
--   separado cuando se abre una fila, que es como funcionan los demas
--   modulos: fn_usu_empleado_buscar_por_pk en funcionarios,
--   fn_actividad_buscar_por_pk en el planeador, fn_matricula_obtener_completa
--   en matricula. Se sigue la misma forma que los dos primeros -- RETURNS
--   TABLE de una sola fila y firma (solicitante, pk) -- porque el detalle de
--   una prematricula es PLANO: no tiene colecciones anidadas que obliguen a
--   devolver JSONB como si hace la matricula con sus archivos y acudientes.
--
-- QUE DEVUELVE
--   Las mismas columnas del listado, para que la ficha se pueda abrir sin
--   depender de la fila que la abrio, mas todo lo que el listado no lleva:
--
--     * estudiante -- tipo y numero de documento, los cuatro nombres, fecha
--       de nacimiento, genero, correo, telefono, municipio de residencia y
--       direccion. Todo vive en TUSUARIO, no en la prematricula.
--     * destino    -- target_campus y target_group, ademas del target_grade
--       que ya trae el listado, y has_slot (el booleano crudo detras de
--       status, util en la ficha aunque en la tabla baste el badge).
--     * acudiente  -- documento, nombres, parentesco, correo, telefono,
--       direccion y si convive con el estudiante.
--     * estado_prematricula y created_at, para trazabilidad.
--
-- EL ACUDIENTE
--   Sale del FK_TPADRE de la propia prematricula (el "acudiente
--   provisional", segun la DDL). El parentesco se toma primero del
--   FK_TLV_ACUDIENTE_PARENTESCO de la prematricula y, si viene NULL, del
--   TNUCLEO_FAMILIAR de ese par (padre, estudiante) -- mismo respaldo que
--   usa fn_matricula_listar. Hace falta: de los 47 registros de hoy, 35
--   tienen acudiente y NINGUNO trae parentesco propio.
--
--   guardian_lives_with_student sale de TPADRE.VIVE ('S'/'N'). No hay
--   equivalente en TPREMATRICULA: la columna ESTADO_CONVIVE_ACUDIENTE existe
--   solo en TRESERVA_CUPO, que es la rama de los estudiantes nuevos.
--
-- PERMISOS
--   Los mismos que el listado: capability por el menu PRE_MATRICULA y
--   alcance sobre el periodo academico del grupo DESTINO. Si la prematricula
--   no existe, esta inactiva o cae fuera del alcance, devuelve CERO filas --
--   no levanta: para el que consulta son el mismo hecho ("no la tienes") y
--   distinguirlos filtraria informacion sobre registros ajenos.
--
-- Idempotente: CREATE OR REPLACE. Funcion nueva, sin sobrecarga previa.
-- ===========================================================================


CREATE OR REPLACE FUNCTION academico_test.fn_prematricula_buscar_por_pk(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_tprematricula        BIGINT
)
RETURNS TABLE(
    id                          BIGINT,
    -- estudiante
    document_type               VARCHAR,
    document_number             VARCHAR,
    first_name                  VARCHAR,
    second_name                 VARCHAR,
    last_name                   VARCHAR,
    second_last_name            VARCHAR,
    birth_date                  DATE,
    gender                      VARCHAR,
    email                       VARCHAR,
    phone                       VARCHAR,
    residence                   VARCHAR,
    address                     VARCHAR,
    -- origen: donde esta hoy
    institution                 VARCHAR,
    campus                      VARCHAR,
    shift                       VARCHAR,
    education_level             TEXT,
    grade                       INTEGER,
    grupo                       VARCHAR,
    -- destino: a donde aspira
    target_grade                INTEGER,
    target_campus               VARCHAR,
    target_group                VARCHAR,
    failed                      BOOLEAN,
    has_slot                    BOOLEAN,
    status                      TEXT,
    -- acudiente
    guardian_document_type      VARCHAR,
    guardian_document_number    VARCHAR,
    guardian_first_name         VARCHAR,
    guardian_second_name        VARCHAR,
    guardian_last_name          VARCHAR,
    guardian_second_last_name   VARCHAR,
    guardian_relationship       VARCHAR,
    guardian_email              VARCHAR,
    guardian_phone              VARCHAR,
    guardian_address            VARCHAR,
    guardian_lives_with_student BOOLEAN,
    -- trazabilidad
    estado_prematricula         VARCHAR,
    created_at                  DATE
)
LANGUAGE plpgsql
STABLE
AS $function$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PRE_MATRICULA', 'VER');

    RETURN QUERY
    SELECT
        pm.PK_TPREMATRICULA,

        tdoc.NOMBRE,
        u.IDENTIFICACION,
        u.PRIMER_NOMBRE,
        u.SEGUNDO_NOMBRE,
        u.PRIMER_APELLIDO,
        u.SEGUNDO_APELLIDO,
        u.FECHA_NACIMIENTO,
        gen.NOMBRE,
        u.CORREO_ELECTRONICO,
        u.TELEFONO,
        mun.NOMBRE,
        u.DIRECCION_RESIDENCIA,

        o.institution,
        o.campus,
        o.shift,
        o.education_level,
        o.grade,
        o.grupo,

        NULLIF(gd.CODIGO, '')::INT,
        sdd.NOMBRE,
        grd.NOMBRE,
        COALESCE(o.estado_valor = '3', FALSE),
        (grd.CAPACIDAD IS NOT NULL
         AND academico_test.fn_matricula_cupo_ocupado(grd.PK_TGRUPO) < grd.CAPACIDAD),
        CASE WHEN grd.CAPACIDAD IS NOT NULL
               AND academico_test.fn_matricula_cupo_ocupado(grd.PK_TGRUPO) < grd.CAPACIDAD
             THEN 'con_cupo' ELSE 'sin_cupo' END::TEXT,

        gdoc.NOMBRE,
        pu.IDENTIFICACION,
        pu.PRIMER_NOMBRE,
        pu.SEGUNDO_NOMBRE,
        pu.PRIMER_APELLIDO,
        pu.SEGUNDO_APELLIDO,
        COALESCE(par.NOMBRE, parnf.nombre),
        pu.CORREO_ELECTRONICO,
        pu.TELEFONO,
        pu.DIRECCION_RESIDENCIA,
        (pa_d.VIVE = 'S'),

        epm.NOMBRE,
        pm.CREATED_AT::DATE

      FROM academico_test.TPREMATRICULA pm

      JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = pm.FK_TESTUDIANTE AND es.ACTIVE = TRUE
      JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO = es.FK_TUSUARIO

      -- grupo DESTINO y su cadena hasta la sede
      JOIN academico_test.TGRUPO grd     ON grd.PK_TGRUPO = pm.FK_TGRUPO AND grd.ACTIVE = TRUE
      JOIN academico_test.TGRADO gd      ON gd.PK_TGRADO = grd.FK_TGRADO AND gd.ACTIVE = TRUE
      JOIN academico_test.TPERIODO_ACADEMICO pad ON pad.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE sdd      ON sdd.PK_TSEDE = pad.FK_TSEDE

      JOIN academico_test.TLISTA_VALOR epm ON epm.PK_LISTA_VALOR = pm.FK_TLV_ESTADO_PREMATRICULA

      LEFT JOIN academico_test.TLISTA_VALOR tdoc ON tdoc.PK_LISTA_VALOR = u.FK_TLV_TIPO_DOCUMENTO
      LEFT JOIN academico_test.TLISTA_VALOR gen  ON gen.PK_LISTA_VALOR  = u.FK_TLV_GENERO
      LEFT JOIN academico_test.TMUNICIPIO mun    ON mun.PK_TMUNICIPIO   = u.FK_TMUNICIPIO_RESIDENCIA

      -- ORIGEN: no hay FK entre prematricula y matricula, se toma la activa
      -- mas reciente del estudiante. Mismo criterio que V350.
      LEFT JOIN LATERAL (
            SELECT est.NOMBRE  AS institution,
                   sd.NOMBRE   AS campus,
                   jor.NOMBRE  AS shift,
                   CASE ne.CODIGO
                       WHEN '1' THEN 'PREESCOLAR'
                       WHEN '2' THEN 'BASICA_PRIMARIA'
                       WHEN '3' THEN 'BASICA_SECUNDARIA'
                       WHEN '4' THEN 'MEDIA'
                   END         AS education_level,
                   NULLIF(g.CODIGO, '')::INT AS grade,
                   gr.NOMBRE   AS grupo,
                   em.VALOR    AS estado_valor
              FROM academico_test.TMATRICULA m
              JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
              JOIN academico_test.TGRADO g  ON g.PK_TGRADO = gr.FK_TGRADO
              JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
              JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
              JOIN academico_test.TSEDE sd  ON sd.PK_TSEDE = pa.FK_TSEDE
              JOIN academico_test.TESTABLECIMIENTO est ON est.PK_ESTABLECIMIENTO = sd.FK_TESTABLECIMIENTO
              JOIN academico_test.TLISTA_VALOR jor ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
              JOIN academico_test.TLISTA_VALOR em  ON em.PK_LISTA_VALOR = m.FK_TLV_ESTADO_MATRICULA
             WHERE m.FK_TESTUDIANTE = pm.FK_TESTUDIANTE
               AND m.ACTIVE = TRUE
             ORDER BY m.PK_TMATRICULA DESC
             LIMIT 1
      ) o ON TRUE

      LEFT JOIN academico_test.TPADRE pa_d ON pa_d.PK_TPADRE = pm.FK_TPADRE
      LEFT JOIN academico_test.TUSUARIO pu ON pu.PK_TUSUARIO = pa_d.FK_TUSUARIO
      LEFT JOIN academico_test.TLISTA_VALOR gdoc ON gdoc.PK_LISTA_VALOR = pu.FK_TLV_TIPO_DOCUMENTO
      LEFT JOIN academico_test.TLISTA_VALOR par  ON par.PK_LISTA_VALOR  = pm.FK_TLV_ACUDIENTE_PARENTESCO
      -- Respaldo del parentesco: los 47 registros de hoy no traen el propio.
      LEFT JOIN LATERAL (
            SELECT lv.NOMBRE AS nombre
              FROM academico_test.TNUCLEO_FAMILIAR nf
              JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = nf.FK_TLV_PARENTESCO
             WHERE nf.FK_TESTUDIANTE = pm.FK_TESTUDIANTE
               AND nf.FK_TPADRE      = pm.FK_TPADRE
               AND nf.ACTIVE         = TRUE
             ORDER BY nf.PK_TNUCLEO_FAMILIAR
             LIMIT 1
      ) parnf ON TRUE

     WHERE pm.PK_TPREMATRICULA = p_pk_tprematricula
       AND pm.ACTIVE = TRUE
       AND academico_test.fn_periodo_usuario_puede_ver(
               p_pk_usuario_solicitante, pad.PK_TPERIODO_ACADEMICO);
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_prematricula_buscar_por_pk(BIGINT, BIGINT)
    IS 'Detalle de UNA pre-matricula (TPREMATRICULA). Complementa a fn_prematricula_listar (V350), que solo devuelve lo que pinta la tabla: aqui van ademas los datos completos del estudiante (tipo y numero de documento, los cuatro nombres, fecha de nacimiento, genero, correo, telefono, municipio de residencia y direccion -- todos viven en TUSUARIO), el destino completo (target_campus, target_group, has_slot) y el bloque del acudiente. Se devuelve como RETURNS TABLE de una fila, no JSONB, porque el detalle es plano: no tiene colecciones anidadas como si las tiene fn_matricula_obtener_completa. Misma forma que fn_usu_empleado_buscar_por_pk y fn_actividad_buscar_por_pk. El acudiente sale del FK_TPADRE de la prematricula (el "acudiente provisional" de la DDL) y su parentesco del FK_TLV_ACUDIENTE_PARENTESCO propio con respaldo en TNUCLEO_FAMILIAR -- hace falta: de los 47 registros de hoy, 35 tienen acudiente y ninguno trae parentesco propio. guardian_lives_with_student sale de TPADRE.VIVE; no hay equivalente en TPREMATRICULA, porque ESTADO_CONVIVE_ACUDIENTE solo existe en TRESERVA_CUPO (la rama de los estudiantes nuevos). Permisos: capability por el menu PRE_MATRICULA y alcance sobre el periodo academico del grupo destino. Si la prematricula no existe, esta inactiva o queda fuera del alcance devuelve CERO filas en vez de levantar: para quien consulta son el mismo hecho, y distinguirlos filtraria informacion sobre registros ajenos.';
