-- ===========================================================================
-- V407 — fn_docente_unidad_tabs_listar (V281) SOLO resolvia niveles/grados
-- via TDOCENTE_ASIGNATURA (el vinculo docente<->grupo<->grado): un
-- rector/secretaria no tiene filas ahi (no "dicta" nada), asi que la
-- funcion devolvia 0 filas para ellos -- GET /planeador/unidades/tabs
-- respondia [] y el front (planeador-tabs.tsx) caia al fallback fijo
-- "Unidad temática", aunque el establecimiento fuera de Preescolar y la
-- pestana real debiera decir "Proyecto pedagogico" (confirmado en
-- produccion: el docente SI ve el rotulo correcto, el rector no, viendo
-- la misma unidad).
--
-- Requisito confirmado: el rector debe ver TODOS los enfoques
-- pedagogicos (una pestana por referente/instrumento) presentes en su
-- establecimiento -- no solo el nivel de una unidad puntual -- igual
-- que un docente con grados de varios niveles ve varias pestanas.
--
-- FIX: la CTE `asignaciones` pasa a ser la UNION de dos ramas:
--
--   1. La rama docente de siempre (TDOCENTE_ASIGNATURA), sin tocar --
--      cero cambio de comportamiento para un docente puro.
--   2. Una rama "administrativa": TODOS los grados de las sedes que el
--      usuario alcanza a LEER, resueltas con el mismo par de helpers
--      que ya usa fn_unidad_listar (V216) para el mismo problema --
--      fn_usuario_categoria_rol_nivel + fn_usuario_sedes_lectura (V29)
--      -- y el mismo join TGRADO -> TPERIODO_ACADEMICO -> TSEDE que
--      V216 usa para filtrar el listado de unidades por alcance
--      territorial (misma fuente de verdad, la pestana y el listado
--      nunca pueden discrepar sobre que grados ve este usuario).
--
-- Para un docente puro (categoria/nivel 4), fn_usuario_sedes_lectura
-- devuelve 0 sedes -- la rama 2 no aporta nada y el resultado es
-- IDENTICO al de V281. Para un rector/secretaria (nivel 2),
-- fn_usuario_sedes_lectura devuelve las sedes de sus establecimientos
-- (fn_usuario_ee_accesibles) y la rama 2 es la que en la practica
-- resuelve todo. No hace falta un UNION condicional: la propia
-- funcion de alcance ya devuelve "nada" quien no debe ver nada.
--
-- La rama 2 no tiene una asignatura natural por grado (un rector no
-- "dicta" una asignatura puntual) -- se pasa NULL a
-- fn_unidad_referente_aplicable, que ya tolera ese caso (V216: sin
-- asignatura, no filtra por area, aplica el referente mas general del
-- nivel). pk_tasignatura/asignatura_nombre quedan NULL en esas filas;
-- jsonb_agg(DISTINCT ...) con pk/nombre NULL es un valor valido para
-- el front (lo usa solo para filtrar contenido al cambiar de pestana).
--
-- El guard de "0 filas si no hay funcionario activo" (V281) se relaja:
-- ahora es "0 filas solo si NO hay funcionario Y tampoco hay alcance
-- territorial" -- sigue siendo fail-closed (un usuario de categoria/
-- nivel 4 sin funcionario sigue sin ver nada), pero ya no bloquea a un
-- administrativo que por lo que sea no tuviera fila en TFUNCIONARIO.
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_docente_unidad_tabs_listar(
    p_pk_usuario_solicitante BIGINT
)
RETURNS TABLE (
    instrumento                 VARCHAR,
    instrumento_info_adicional  VARCHAR,
    pk_referente_curricular     BIGINT,
    referente_nombre            VARCHAR,
    enfoque_valor               VARCHAR,
    es_evaluativo               BOOLEAN,
    tipo_evaluacion_valor       VARCHAR,
    nivel_1_etiqueta            VARCHAR,
    nivel_2_etiqueta            VARCHAR,
    niveles                     JSONB,
    grados                      JSONB,
    asignaturas                 JSONB,
    total_grados                BIGINT,
    total_count                 BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_fk_tfuncionario BIGINT;
    v_alcance_total   BOOLEAN;
    v_sedes_lectura   BIGINT[];
    v_solo_propias    BOOLEAN;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    v_fk_tfuncionario := academico_test.fn_funcionario_actual(p_pk_usuario_solicitante);

    -- V407: mismo alcance de LECTURA que fn_unidad_listar (V216/V277) --
    -- nivel 0/1 todas las sedes, nivel 2 (rector/secretaria) las de sus
    -- establecimientos, nivel 3 (coordinador) las suyas, nivel 4 (docente
    -- puro) ninguna. Un docente puro sigue resolviendo TODO por la rama
    -- TDOCENTE_ASIGNATURA de abajo, como en V281.
    v_alcance_total := COALESCE(
        academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante), 99) <= 1;
    v_sedes_lectura := ARRAY(
        SELECT sl.sede_id
          FROM academico_test.fn_usuario_sedes_lectura(p_pk_usuario_solicitante) sl);

    -- La rama territorial es de quien ADMINISTRA. Un docente puro puede tener
    -- sedes de lectura por su categoria de rol y aun asi no administrar nada:
    -- sin esto le salian pestanas de referentes que no dicta.
    v_solo_propias := academico_test.fn_usuario_es_docente_puro(p_pk_usuario_solicitante);

    -- V407: 0 filas solo si NO es docente activo Y TAMPOCO tiene alcance
    -- territorial alguno -- antes (V281) bastaba con no tener funcionario.
    -- Fail-closed se conserva: fn_usuario_sedes_lectura ya devuelve 0 sedes
    -- para quien no tiene ningun rol/alcance reconocido.
    IF v_fk_tfuncionario IS NULL
       AND NOT v_alcance_total
       AND array_length(v_sedes_lectura, 1) IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH asignaciones AS (
        -- Rama 1 (V281, sin cambios): los pares (grado, asignatura) que el
        -- docente REALMENTE dicta.
        SELECT DISTINCT
               gr.PK_TGRADO           AS pk_tgrado,
               gr.NOMBRE              AS grado_nombre,
               gr.FK_TNIVEL_ENSENANZA AS pk_nivel,
               asig.PK_TASIGNATURA    AS pk_tasignatura,
               asig.NOMBRE            AS asignatura_nombre
          FROM academico_test.TDOCENTE_ASIGNATURA da
          JOIN academico_test.TGRUPO g       ON g.PK_TGRUPO = da.FK_TGRUPO
                                            AND g.ACTIVE = TRUE
          JOIN academico_test.TGRADO gr      ON gr.PK_TGRADO = g.FK_TGRADO
                                            AND gr.ACTIVE = TRUE
          JOIN academico_test.TASIGNATURA asig ON asig.PK_TASIGNATURA = da.FK_TASIGNATURA
                                            AND asig.ACTIVE = TRUE
         WHERE v_fk_tfuncionario IS NOT NULL
           AND da.FK_TFUNCIONARIO = v_fk_tfuncionario
           AND da.ACTIVE = TRUE

        UNION

        -- Rama 2 (V407, nueva): TODOS los grados de las sedes que este
        -- usuario alcanza a leer -- para un rector/secretaria/coordinador
        -- (o super admin/territorial) sin necesidad de que "dicte" nada.
        -- Sin asignatura puntual: pk_tasignatura/asignatura_nombre NULL,
        -- fn_unidad_referente_aplicable ya tolera ese caso.
        SELECT DISTINCT
               gr.PK_TGRADO           AS pk_tgrado,
               gr.NOMBRE              AS grado_nombre,
               gr.FK_TNIVEL_ENSENANZA AS pk_nivel,
               NULL::BIGINT           AS pk_tasignatura,
               NULL::VARCHAR          AS asignatura_nombre
          FROM academico_test.TGRADO gr
          JOIN academico_test.TPERIODO_ACADEMICO pa
                 ON pa.PK_TPERIODO_ACADEMICO = gr.FK_TPERIODO_ACADEMICO
          JOIN academico_test.TSEDE s
                 ON s.PK_TSEDE = pa.FK_TSEDE
                AND s.ACTIVE = TRUE
         WHERE gr.ACTIVE = TRUE
           AND NOT v_solo_propias
           AND (v_alcance_total OR pa.FK_TSEDE = ANY(v_sedes_lectura))
    ), con_referente AS (
        SELECT a.*,
               academico_test.fn_unidad_referente_aplicable(
                   a.pk_tgrado, a.pk_tasignatura) AS pk_referente
          FROM asignaciones a
    ), agrupado AS (
        SELECT COALESCE('R' || cr.pk_referente::TEXT, 'N' || cr.pk_nivel::TEXT) AS clave,
               MIN(cr.pk_referente)                                            AS pk_referente,
               jsonb_agg(DISTINCT jsonb_build_object(
                   'pk', cr.pk_tgrado, 'nombre', cr.grado_nombre))             AS grados,
               jsonb_agg(DISTINCT jsonb_build_object(
                   'pk', cr.pk_tasignatura, 'nombre', cr.asignatura_nombre))   AS asignaturas,
               jsonb_agg(DISTINCT jsonb_build_object(
                   'pk', cr.pk_nivel, 'nombre', ne.NOMBRE))                    AS niveles,
               COUNT(DISTINCT cr.pk_tgrado)::BIGINT                            AS total_grados
          FROM con_referente cr
          LEFT JOIN academico_test.TNIVEL_ENSENANZA ne
                 ON ne.PK_NIVEL_ENSENANZA = cr.pk_nivel
         GROUP BY COALESCE('R' || cr.pk_referente::TEXT, 'N' || cr.pk_nivel::TEXT)
    )
    SELECT COALESCE(NULLIF(TRIM(rc.INSTRUMENTO), ''), 'Unidad tematica')::VARCHAR,
           rc.INSTRUMENTO_INFO_ADICIONAL,
           rc.PK_REFERENTE_CURRICULAR,
           rc.NOMBRE,
           enf.VALOR,
           (enf.VALOR = 'EVALUATIVO'),
           tev.VALOR,
           rc.NIVEL_1_ETIQUETA,
           rc.NIVEL_2_ETIQUETA,
           ag.niveles,
           ag.grados,
           ag.asignaturas,
           ag.total_grados,
           COUNT(*) OVER()
      FROM agrupado ag
      LEFT JOIN academico_test.TREFERENTE_CURRICULAR rc
             ON rc.PK_REFERENTE_CURRICULAR = ag.pk_referente
      LEFT JOIN academico_test.TLISTA_VALOR enf ON enf.PK_LISTA_VALOR = rc.FK_TLV_ENFOQUE_PEDAGOGICO
      LEFT JOIN academico_test.TLISTA_VALOR tev ON tev.PK_LISTA_VALOR = rc.FK_TLV_TIPO_EVALUACION
     ORDER BY (ag.pk_referente IS NULL),
              COALESCE(NULLIF(TRIM(rc.INSTRUMENTO), ''), 'Unidad tematica'),
              ag.clave;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_docente_unidad_tabs_listar(BIGINT)
    IS 'Las PESTANAS de unidad que le corresponden al usuario autenticado: una por referente curricular de los niveles educativos que dicta (docente) o que administra (rector/secretaria/coordinador/super-admin/territorial, V407). El rotulo NO es fijo ("Unidad tematica"): lo define TREFERENTE_CURRICULAR.INSTRUMENTO del nivel ("Proyecto pedagogico" en Preescolar...). Para un docente los niveles salen de TDOCENTE_ASIGNATURA (igual que V281/V242/V250); para un usuario con alcance territorial (fn_usuario_categoria_rol_nivel/fn_usuario_sedes_lectura, V29, mismo criterio que fn_unidad_listar V216) salen de TODOS los grados de las sedes que alcanza a leer, sin asignatura puntual. Ambas ramas se UNEN: la territorial esta explicitamente cerrada para el docente puro (fn_usuario_es_docente_puro, V29), que por su categoria de rol puede tener sedes de lectura sin administrar nada y antes recibia pestanas de referentes que no dicta; un rector ve una pestana por cada enfoque pedagogico presente en su establecimiento aunque no dicte nada. Por cada par se deriva el referente con fn_unidad_referente_aplicable (V216, tolera asignatura NULL) y se agrupa por referente (o por nivel si no hay referente aplicable). 0 filas solo si el usuario no es docente activo Y tampoco tiene ningun alcance territorial. Gate VER sobre PLANEADOR. V407 (reemplaza V281).';
