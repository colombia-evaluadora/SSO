-- ===========================================================================
-- V507 - Prematricula (6/9): la funcion general del PRIMER endpoint.
--
--   fn_prematricula_gate_ee(usuario, ee, sede, accion)      -> gate por EE
--   fn_prematricula_gate_grupo(usuario, grupo, accion)      -> gate por grupo
--   fn_prematricula_plan_listar(usuario, ee, sede)          -> el plan
--
--
-- QUE DEVUELVE EL PLAN
--   Una fila POR GRUPO, y dentro de cada fila el arreglo de matriculas de ese
--   grupo. Eso es la "lista de listas": el front recorre las filas y llama al
--   segundo endpoint una vez por cada una, pasandole el grupo y su arreglo.
--
--   Se parte asi y no en una sola llamada porque el proceso puede tardar y
--   hay que poder mostrar avance, reanudar si se corta y no rehacer lo ya
--   hecho. Cada fila trae ademas los dos destinos ya resueltos y cuantos
--   estudiantes faltan, para que la pantalla pueda pintar el estado ANTES de
--   empezar -- y para que un grupo sin destino se vea como tal en vez de
--   fallar recien al ejecutarlo.
--
--
-- LOS GATES
--   Dos envoltorios de una linea sobre fn_assert_permiso_seccion (V29), menu
--   'PRE_MATRICULA', que es el que ya usan fn_prematricula_listar y
--   fn_prematricula_soft_delete. Mismo modelo que fn_matricula_gate_escritura:
--   capability dinamica (TROL_MENU concede / TUSUARIO_ROL_PERMISO recorta) +
--   scope por categoria de rol. El de grupo resuelve las tres coordenadas con
--   los helpers que ya existen (fn_grupo_establecimiento, fn_grupo_periodo /
--   fn_periodo_sede, fn_grupo_jornada), igual que matricula.
--
--   Se exige 'CREAR' y no 'VER' aunque el plan solo lea: existe unicamente
--   para alimentar la creacion, y pedir VER dejaria que un rol de solo
--   lectura arranque un proceso que no va a poder terminar.
--
--   NOTA: el super admin sigue pasando por el bypass de
--   fn_assert_permiso_seccion, igual que en matricula -- cuyo gate es solo
--   esa llamada, sin exclusion propia. Si se quiere que aca NO pueda actuar,
--   hay que agregarlo explicitamente y conviene hacerlo en los dos modulos a
--   la vez.
--
-- Idempotente: CREATE OR REPLACE. fn_prematricula_plan_listar se DROPea antes
-- por si una version anterior declaro otro RETURNS TABLE (42P13).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) Gates.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_prematricula_gate_ee(
    p_pk_usuario           BIGINT,
    p_fk_testablecimiento  BIGINT,
    p_fk_tsede             BIGINT  DEFAULT NULL,
    p_accion               VARCHAR DEFAULT 'CREAR'
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario, 'PRE_MATRICULA', p_accion,
        p_fk_testablecimiento, p_fk_tsede, NULL);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_prematricula_gate_ee(BIGINT, BIGINT, BIGINT, VARCHAR)
    IS 'Gate de la seccion Pre-Matricula cuando todavia no hay un grupo concreto: se scopea por establecimiento y, si viene, por sede. La jornada va NULL porque el plan abarca todas. Envoltorio de fn_assert_permiso_seccion (V29), menu PRE_MATRICULA.';

CREATE OR REPLACE FUNCTION academico_test.fn_prematricula_gate_grupo(
    p_pk_usuario  BIGINT,
    p_fk_tgrupo   BIGINT,
    p_accion      VARCHAR DEFAULT 'CREAR'
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario, 'PRE_MATRICULA', p_accion,
        academico_test.fn_grupo_establecimiento(p_fk_tgrupo),
        academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(p_fk_tgrupo)),
        academico_test.fn_grupo_jornada(p_fk_tgrupo));
END;
$$;

COMMENT ON FUNCTION academico_test.fn_prematricula_gate_grupo(BIGINT, BIGINT, VARCHAR)
    IS 'Gate de la seccion Pre-Matricula sobre un grupo concreto. Resuelve las tres coordenadas del scope (EE, sede, jornada) con los mismos helpers que fn_matricula_gate_escritura, asi que un coordinador solo alcanza su par (sede, jornada). Envoltorio de fn_assert_permiso_seccion (V29), menu PRE_MATRICULA.';

-- ---------------------------------------------------------------------------
-- 2) El plan.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_prematricula_plan_listar(BIGINT, BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_prematricula_plan_listar(
    p_pk_usuario_solicitante  BIGINT,
    p_fk_testablecimiento     BIGINT,
    p_fk_tsede                BIGINT DEFAULT NULL
)
RETURNS TABLE (
    fk_tgrupo              BIGINT,
    grupo_nombre           VARCHAR,
    fk_tgrado              BIGINT,
    grado_nombre           VARCHAR,
    fk_tsede               BIGINT,
    sede_nombre            VARCHAR,
    fk_tlv_jornada         BIGINT,
    jornada_nombre         VARCHAR,
    fk_tperiodo_academico  BIGINT,
    fk_tperiodo_siguiente  BIGINT,
    fk_tgrupo_ascenso      BIGINT,
    fk_tgrupo_repite       BIGINT,
    es_ultimo_grado        BOOLEAN,
    estudiantes            BIGINT,
    pendientes             BIGINT,
    matriculas             BIGINT[]
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_prematricula_gate_ee(
        p_pk_usuario_solicitante, p_fk_testablecimiento, p_fk_tsede, 'CREAR');

    PERFORM academico_test.fn_prematricula_assert_periodo_siguiente(
        p_fk_testablecimiento, p_fk_tsede);

    RETURN QUERY
    SELECT g.PK_TGRUPO,
           g.NOMBRE,
           gd.PK_TGRADO,
           gd.NOMBRE,
           pa.FK_TSEDE,
           s.NOMBRE,
           pa.FK_TLV_JORNADA,
           jor.NOMBRE,
           pa.PK_TPERIODO_ACADEMICO,
           d.fk_tperiodo_siguiente,
           d.fk_tgrupo_ascenso,
           d.fk_tgrupo_repite,
           d.es_ultimo_grado,
           COUNT(m.PK_TMATRICULA)::BIGINT,
           -- Los que faltan. NO se usa fn_prematricula_matricula_procesable
           -- aunque responda justo esto: llamarla por fila la obliga a
           -- resolver el periodo siguiente una vez POR MATRICULA (~900 veces
           -- en un establecimiento mediano) y el plan pasaba de 300 ms a 2,5 s.
           -- Aca el periodo ya viene resuelto por grupo en el LATERAL, asi que
           -- basta el NOT EXISTS. La funcion sigue existiendo para el uso de a
           -- uno, que es donde tiene sentido (V508).
           COUNT(m.PK_TMATRICULA) FILTER (
               WHERE NOT EXISTS (
                   SELECT 1
                     FROM academico_test.TPREMATRICULA pm
                     JOIN academico_test.TGRUPO gp  ON gp.PK_TGRUPO  = pm.FK_TGRUPO
                     JOIN academico_test.TGRADO gdp ON gdp.PK_TGRADO = gp.FK_TGRADO
                    WHERE pm.FK_TESTUDIANTE = m.FK_TESTUDIANTE
                      AND pm.ACTIVE = TRUE
                      AND gdp.FK_TPERIODO_ACADEMICO = d.fk_tperiodo_siguiente)
           )::BIGINT,
           ARRAY_AGG(m.PK_TMATRICULA ORDER BY m.PK_TMATRICULA)
      FROM academico_test.fn_prematricula_periodos_actuales(
               p_fk_testablecimiento, p_fk_tsede) pact
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = pact.fk_tperiodo_academico
      JOIN academico_test.TSEDE s
        ON s.PK_TSEDE = pa.FK_TSEDE
 LEFT JOIN academico_test.TLISTA_VALOR jor
        ON jor.PK_LISTA_VALOR = pa.FK_TLV_JORNADA
      JOIN academico_test.TGRADO gd
        ON gd.FK_TPERIODO_ACADEMICO = pa.PK_TPERIODO_ACADEMICO
       AND gd.ACTIVE = TRUE
      JOIN academico_test.TGRUPO g
        ON g.FK_TGRADO = gd.PK_TGRADO
       AND g.ACTIVE    = TRUE
      -- Solo los tres estados que entran al proceso. Es un JOIN y no un LEFT:
      -- un grupo sin nadie prematriculable no tiene por que aparecer en el
      -- plan -- el front lo pintaria como una tanda vacia.
      JOIN academico_test.TMATRICULA m
        ON m.FK_TGRUPO = g.PK_TGRUPO
       AND m.ACTIVE    = TRUE
      JOIN academico_test.TLISTA_VALOR est
        ON est.PK_LISTA_VALOR = m.FK_TLV_ESTADO_MATRICULA
       AND est.CATEGORIA = 'ESTADO_MATRICULA'
       AND est.VALOR IN ('1', '2', '3')
 LEFT JOIN LATERAL academico_test.fn_prematricula_grupos_destino(g.PK_TGRUPO) d ON TRUE
     GROUP BY g.PK_TGRUPO, g.NOMBRE, gd.PK_TGRADO, gd.NOMBRE,
              pa.FK_TSEDE, s.NOMBRE, pa.FK_TLV_JORNADA, jor.NOMBRE,
              pa.PK_TPERIODO_ACADEMICO, d.fk_tperiodo_siguiente,
              d.fk_tgrupo_ascenso, d.fk_tgrupo_repite, d.es_ultimo_grado
     ORDER BY s.NOMBRE, gd.NOMBRE, g.NOMBRE;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_prematricula_plan_listar(BIGINT, BIGINT, BIGINT)
    IS 'El plan de prematricula de un establecimiento (opcionalmente de una sede): una fila POR GRUPO del periodo academico en curso, con el arreglo de sus matriculas en estado Cursando/Aprobado/Reprobado. Es la "lista de listas" con la que el front llama al segundo endpoint una vez por grupo. Cada fila trae los dos destinos del ano siguiente ya resueltos (ascenso y repeticion), si el grado es el ultimo, y cuantos estudiantes faltan por prematricular -- asi la pantalla pinta el estado antes de empezar y un grupo sin destino se ve como tal en vez de fallar al ejecutarlo. Gate PRE_MATRICULA/CREAR sobre el EE (y la sede si viene) + assert de que exista el periodo del ano siguiente. Los grupos sin nadie prematriculable no salen.';
