-- ===========================================================================
-- V553 — Planeador de un docente elegido (solo lectura) para super admin y
--   coordinador: GET /planeador/docentes y ?funcionario= en las lecturas del
--   tablero (mias, calendario, stats, tabs, unidades, unidades/tabs,
--   docentes/*); mias, calendario y unidades traen el docente de cada fila.
--   ?sede=&periodo= (filtro avanzado, V553.1) acotan el alcance y las lecturas.
-- Que hace: el alcance (sedes + pares sede/jornada del nivel 3 resueltos a
--   periodos academicos), la validacion del docente pedido y el selector de
--   docentes; los wrappers que lo usan se editaron en su migracion dueña
--   (V250, V407, V488, V497, V525, V526, V528, V530).
-- Depende de: V29 (alcance por rol), V224 (fn_funcionario_actual), V481
--   (fn_planeador_listado_alcance).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 0. Jornada "Completa" (o sin jornada): no acota a una jornada concreta.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_planeador_jornada_completa(
    p_fk_tlv_jornada BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT p_fk_tlv_jornada IS NULL
        OR EXISTS (SELECT 1
                     FROM academico_test.TLISTA_VALOR lv
                    WHERE lv.PK_LISTA_VALOR = p_fk_tlv_jornada
                      AND lv.CATEGORIA = 'JORNADA'
                      AND (UPPER(TRIM(lv.NOMBRE)) = 'COMPLETA' OR UPPER(TRIM(lv.VALOR)) = 'COMPLETA'));
$$;

COMMENT ON FUNCTION academico_test.fn_planeador_jornada_completa(BIGINT)
    IS 'INTERNO: TRUE si la jornada es NULL o la "Completa" del catálogo JORNADA (por texto, no por pk). En los años viejos el periodo académico se creaba con jornada "Completa" y la jornada real vive en el grupo (ver V537). Lo usa fn_planeador_alcance_docente para el alcance sede+jornada del coordinador.';

-- ---------------------------------------------------------------------------
-- 1. Docentes que dictan algo (TDOCENTE_ASIGNATURA activa) dentro de un alcance.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_planeador_docentes_listar_interno(
    p_fk_establecimiento BIGINT,
    p_alcance_total      BOOLEAN,
    p_periodos_lectura   BIGINT[],
    p_fk_tfuncionario    BIGINT DEFAULT NULL,
    p_grupos_lectura     BIGINT[] DEFAULT NULL
)
RETURNS TABLE (
    pk_tfuncionario BIGINT,
    nombre_completo VARCHAR,
    identificacion  VARCHAR
)
LANGUAGE sql
STABLE
AS $$
    SELECT f.PK_TFUNCIONARIO,
           NULLIF(TRIM(CONCAT_WS(' ', us.PRIMER_NOMBRE, us.SEGUNDO_NOMBRE,
                                      us.PRIMER_APELLIDO, us.SEGUNDO_APELLIDO)), '')::VARCHAR,
           us.IDENTIFICACION::VARCHAR
      FROM academico_test.TFUNCIONARIO f
      JOIN academico_test.TUSUARIO us ON us.PK_TUSUARIO = f.FK_TUSUARIO
     WHERE f.ACTIVE = TRUE
       AND (p_fk_tfuncionario IS NULL OR f.PK_TFUNCIONARIO = p_fk_tfuncionario)
       AND EXISTS (
             SELECT 1
               FROM academico_test.TDOCENTE_ASIGNATURA da
               JOIN academico_test.TGRUPO g  ON g.PK_TGRUPO = da.FK_TGRUPO AND g.ACTIVE = TRUE
               JOIN academico_test.TGRADO gr ON gr.PK_TGRADO = g.FK_TGRADO
               JOIN academico_test.TPERIODO_ACADEMICO pa
                 ON pa.PK_TPERIODO_ACADEMICO = gr.FK_TPERIODO_ACADEMICO AND pa.ACTIVE = TRUE
               JOIN academico_test.TSEDE s   ON s.PK_TSEDE = pa.FK_TSEDE AND s.ACTIVE = TRUE
              WHERE da.FK_TFUNCIONARIO = f.PK_TFUNCIONARIO
                AND da.ACTIVE = TRUE
                AND (p_fk_establecimiento IS NULL OR s.FK_TESTABLECIMIENTO = p_fk_establecimiento)
                AND (p_alcance_total OR pa.PK_TPERIODO_ACADEMICO = ANY(p_periodos_lectura))
                AND (p_grupos_lectura IS NULL OR g.PK_TGRUPO = ANY(p_grupos_lectura)))
     ORDER BY 2, 1;
$$;

COMMENT ON FUNCTION academico_test.fn_planeador_docentes_listar_interno(BIGINT, BOOLEAN, BIGINT[], BIGINT, BIGINT[])
    IS 'INTERNO: funcionarios activos con alguna asignación activa (TDOCENTE_ASIGNATURA, grupo activo) en un periodo académico activo de una sede activa: del establecimiento pedido (NULL = cualquiera) y dentro del alcance (p_alcance_total, o el periodo en p_periodos_lectura y, si no es NULL, el grupo en p_grupos_lectura). p_fk_tfuncionario acota a uno. Lo usan fn_planeador_docentes_listar (GET /planeador/docentes) y fn_planeador_alcance_docente (validar ?funcionario=).';

-- ---------------------------------------------------------------------------
-- 2. Alcance de lectura + docente objetivo, resuelto una vez por petición.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_planeador_alcance_docente(BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_planeador_alcance_docente(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tfuncionario        BIGINT DEFAULT NULL,
    p_fk_sede                BIGINT DEFAULT NULL,
    p_fk_periodo             BIGINT DEFAULT NULL
)
RETURNS TABLE (
    sedes_lectura          BIGINT[],
    alcance_total          BOOLEAN,
    solo_propias           BOOLEAN,
    fk_tfuncionario_propio BIGINT,
    periodos_lectura       BIGINT[],
    fk_tfuncionario        BIGINT,
    grupos_lectura         BIGINT[]
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_alc      RECORD;
    v_nivel    INT;
    v_sedes    BIGINT[];
    v_rector   BIGINT[] := '{}';
    v_periodos BIGINT[];
    v_grupos   BIGINT[];
    v_objetivo BIGINT;
    v_solo     BOOLEAN;
    v_total    BOOLEAN;
BEGIN
    SELECT * INTO v_alc FROM academico_test.fn_planeador_listado_alcance(p_pk_usuario_solicitante);
    v_nivel := COALESCE(academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante), 99);
    v_sedes := v_alc.sedes_lectura;
    v_total := v_alc.alcance_total;

    -- En el Planeador el director de grupo (peso 3) tampoco administra: como
    -- el docente (peso 4), solo ve lo suyo. fn_usuario_es_docente_puro lo deja
    -- fuera (exige peso >= 4) y sin esto veia los grados de toda la sede.
    v_solo := v_alc.solo_propias
              OR (v_nivel = 3 AND COALESCE(
                     (SELECT MIN(COALESCE(r.PESO_CATEGORIA, 4))
                        FROM academico_test.TSEDE_USUARIO su
                        JOIN academico_test.TROL r ON r.PK_TROL = su.FK_TROL
                       WHERE su.FK_TUSUARIO = p_pk_usuario_solicitante
                         AND su.ACTIVE = TRUE
                         AND academico_test.fn_rol_categoria_nivel(su.FK_TROL) = 3), 4) >= 3);

    -- Rector solo por TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR (sin TSEDE_USUARIO
    -- de nivel 2): nivel 2 sobre todas las sedes y jornadas de ese EE.
    IF NOT v_alc.alcance_total THEN
        v_rector := ARRAY(
            SELECT s.PK_TSEDE
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f
                ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR AND f.ACTIVE = TRUE
              JOIN academico_test.TSEDE s
                ON s.FK_TESTABLECIMIENTO = e.PK_ESTABLECIMIENTO AND s.ACTIVE = TRUE
             WHERE e.ACTIVE = TRUE
               AND f.FK_TUSUARIO = p_pk_usuario_solicitante);
        IF cardinality(v_rector) > 0 THEN
            v_sedes := ARRAY(SELECT DISTINCT x
                               FROM unnest(v_rector || CASE WHEN v_solo THEN '{}'::BIGINT[]
                                                            ELSE v_sedes END) x
                              ORDER BY x);
            v_solo := FALSE;
        END IF;
    END IF;

    -- El docente puro sigue acotado a lo que dicta (sin periodos); el nivel 3
    -- que administra (coordinador) alcanza por PAR sede+jornada, no por sede.
    -- Periodo "Completa": la jornada real vive en el grupo, así que entra el
    -- periodo (sus unidades) y grupos_lectura deja solo los grupos de la jornada.
    IF NOT v_alc.alcance_total AND NOT v_solo THEN
        v_periodos := ARRAY(
            SELECT pa.PK_TPERIODO_ACADEMICO
              FROM academico_test.TPERIODO_ACADEMICO pa
             WHERE pa.FK_TSEDE = ANY(v_sedes)
               AND (v_nivel <> 3
                    OR pa.FK_TSEDE = ANY(v_rector)
                    OR EXISTS (SELECT 1
                                 FROM academico_test.fn_usuario_sedes_jornadas_accesibles(p_pk_usuario_solicitante) sj
                                WHERE sj.sede_id = pa.FK_TSEDE
                                  AND (sj.jornada_id = pa.FK_TLV_JORNADA
                                       OR academico_test.fn_planeador_jornada_completa(pa.FK_TLV_JORNADA)
                                       OR (sj.jornada_id IS NOT NULL
                                           AND academico_test.fn_planeador_jornada_completa(sj.jornada_id))))));
    END IF;

    -- Filtro sede / periodo académico (?sede=&periodo=): acota, nunca amplía.
    -- Deja de ser alcance total para que "todos los docentes" de una sede no
    -- caiga en la rama "alcance total sin docente = 0 filas".
    IF NOT v_solo AND (p_fk_sede IS NOT NULL OR p_fk_periodo IS NOT NULL) THEN
        v_periodos := ARRAY(
            SELECT pa.PK_TPERIODO_ACADEMICO
              FROM academico_test.TPERIODO_ACADEMICO pa
             WHERE (v_total OR pa.PK_TPERIODO_ACADEMICO = ANY(v_periodos))
               AND (p_fk_sede IS NULL OR pa.FK_TSEDE = p_fk_sede)
               AND (p_fk_periodo IS NULL OR pa.PK_TPERIODO_ACADEMICO = p_fk_periodo));
        v_sedes := ARRAY(SELECT DISTINCT pa.FK_TSEDE
                           FROM academico_test.TPERIODO_ACADEMICO pa
                          WHERE pa.PK_TPERIODO_ACADEMICO = ANY(v_periodos));
        v_total := FALSE;
    END IF;

    IF NOT v_total AND NOT v_solo THEN
        IF v_nivel = 3 THEN
            v_grupos := ARRAY(
                SELECT g.PK_TGRUPO
                  FROM academico_test.TGRUPO g
                  JOIN academico_test.TGRADO gr ON gr.PK_TGRADO = g.FK_TGRADO
                  JOIN academico_test.TPERIODO_ACADEMICO pa
                    ON pa.PK_TPERIODO_ACADEMICO = gr.FK_TPERIODO_ACADEMICO
                 WHERE pa.PK_TPERIODO_ACADEMICO = ANY(v_periodos)
                   AND (pa.FK_TSEDE = ANY(v_rector)
                        OR NOT academico_test.fn_planeador_jornada_completa(pa.FK_TLV_JORNADA)
                        OR academico_test.fn_planeador_jornada_completa(g.FK_TLV_JORNADA)
                        OR EXISTS (SELECT 1
                                     FROM academico_test.fn_usuario_sedes_jornadas_accesibles(p_pk_usuario_solicitante) sj
                                    WHERE sj.sede_id = pa.FK_TSEDE
                                      AND (sj.jornada_id = g.FK_TLV_JORNADA
                                           OR (sj.jornada_id IS NOT NULL
                                               AND academico_test.fn_planeador_jornada_completa(sj.jornada_id))))));
        END IF;
    END IF;

    IF v_solo THEN
        v_objetivo := v_alc.fk_tfuncionario;
    ELSIF p_fk_tfuncionario IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1
                         FROM academico_test.fn_planeador_docentes_listar_interno(
                                  NULL, v_total, v_periodos, p_fk_tfuncionario, v_grupos)) THEN
            RAISE EXCEPTION 'No tienes acceso al planeador de ese docente'
                USING ERRCODE = '42501',
                      HINT = 'El docente debe dictar alguna asignatura en una sede y jornada de tu alcance';
        END IF;
        v_objetivo := p_fk_tfuncionario;
    END IF;

    RETURN QUERY SELECT v_sedes, v_total, v_solo,
                        v_alc.fk_tfuncionario, v_periodos, v_objetivo, v_grupos;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_planeador_alcance_docente(BIGINT, BIGINT, BIGINT, BIGINT)
    IS 'INTERNO: alcance de lectura del Planeador (fn_planeador_listado_alcance) más periodos_lectura, grupos_lectura y el docente objetivo. p_fk_sede / p_fk_periodo (?sede=&periodo= del filtro avanzado, salvo solo_propias): periodos_lectura queda en los de esa sede / ese periodo académico dentro del alcance (alcance_total pasa a FALSE y sedes_lectura a las sedes de esos periodos); el docente pedido se valida contra ese alcance ya acotado. Rector solo por TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR (sin TSEDE_USUARIO de nivel 2): suma las sedes activas de ese EE sin restricción de jornada y deja de ser solo_propias (si además era docente puro, sus otras sedes no se suman). solo_propias: docente puro (fn_usuario_es_docente_puro) o nivel 3 cuyo mejor rol pesa >= 3 (docente y/o director de grupo, sin coordinador ni jefe de área). periodos_lectura: NULL para alcance_total y solo_propias; si no, los periodos académicos de sus sedes de lectura y, en nivel 3 (fuera de las sedes de rector), solo los de sus pares (sede, jornada) de fn_usuario_sedes_jornadas_accesibles contra TPERIODO_ACADEMICO.FK_TLV_JORNADA; un periodo o un par con jornada "Completa" (fn_planeador_jornada_completa; periodo sin jornada también) casa con cualquier jornada de esa sede. grupos_lectura: solo en nivel 3 (si no, NULL = sin restricción extra): los grupos de esos periodos; en un periodo "Completa" se mira la jornada del GRUPO contra los pares (grupo sin jornada o "Completa": entra). Los listados la aplican a lo que cuelga de un grupo; las unidades (sin grupo) se quedan con periodos_lectura. fk_tfuncionario: solo_propias -> el suyo (ignora p_fk_tfuncionario); con p_fk_tfuncionario -> ese, si dicta algo en el alcance (fn_planeador_docentes_listar_interno), si no 42501; sin él -> NULL (todo el alcance). Lo usan los wrappers de lectura del tablero del Planeador. No valida permisos.';

-- ---------------------------------------------------------------------------
-- 3. Periodos de los selectores grupo/grado-asignatura del tablero.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_planeador_docente_periodos(
    p_fk_tfuncionario  BIGINT,
    p_periodos_lectura BIGINT[],
    p_fk_periodo       BIGINT DEFAULT NULL
)
RETURNS BIGINT[]
LANGUAGE sql
STABLE
AS $$
    SELECT CASE
        WHEN p_fk_periodo IS NOT NULL THEN
            CASE WHEN p_periodos_lectura IS NULL OR p_fk_periodo = ANY(p_periodos_lectura)
                 THEN ARRAY[p_fk_periodo] ELSE '{}'::BIGINT[] END
        WHEN p_fk_tfuncionario IS NOT NULL THEN
            ARRAY(SELECT pa.PK_TPERIODO_ACADEMICO
                    FROM academico_test.TDOCENTE_ASIGNATURA da
                    JOIN academico_test.TPERIODO_ACADEMICO pa
                      ON pa.PK_TPERIODO_ACADEMICO = da.FK_TPERIODO_ACADEMICO AND pa.ACTIVE = TRUE
                   WHERE da.FK_TFUNCIONARIO = p_fk_tfuncionario
                     AND da.ACTIVE = TRUE
                     AND (p_periodos_lectura IS NULL OR pa.PK_TPERIODO_ACADEMICO = ANY(p_periodos_lectura))
                   ORDER BY (CURRENT_DATE BETWEEN pa.FECHA_INICIO AND pa.FECHA_FIN) DESC,
                            pa.FECHA_INICIO DESC, pa.PK_TPERIODO_ACADEMICO DESC
                   LIMIT 1)
        ELSE
            ARRAY(SELECT DISTINCT ON (pa.FK_TSEDE, pa.FK_TLV_JORNADA) pa.PK_TPERIODO_ACADEMICO
                    FROM academico_test.TPERIODO_ACADEMICO pa
                   WHERE pa.ACTIVE = TRUE
                     AND pa.PK_TPERIODO_ACADEMICO = ANY(p_periodos_lectura)
                   ORDER BY pa.FK_TSEDE, pa.FK_TLV_JORNADA,
                            (CURRENT_DATE BETWEEN pa.FECHA_INICIO AND pa.FECHA_FIN) DESC,
                            pa.FECHA_INICIO DESC, pa.PK_TPERIODO_ACADEMICO DESC)
    END;
$$;

COMMENT ON FUNCTION academico_test.fn_planeador_docente_periodos(BIGINT, BIGINT[], BIGINT)
    IS 'INTERNO: periodos académicos de los selectores grupo / grado-asignatura del tablero. Con p_fk_periodo: ese, si está en p_periodos_lectura (NULL = sin restricción). Con docente: su periodo vigente por fechas (o el más reciente) dentro del alcance, mismo orden que fn_docente_periodo_vigente. Sin docente: el vigente (o más reciente) de cada par (sede, jornada) del alcance. Lo usan fn_docente_grupos_listar y fn_docente_grado_asignatura_listar.';

-- ---------------------------------------------------------------------------
-- 4. Docente de una actividad: quien dicta su grupo+asignatura; sin grupo, el
--    autor de su unidad.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_docente_dicta(
    p_pk_tactividad          BIGINT,
    p_fk_tfuncionario_propio BIGINT DEFAULT NULL
)
RETURNS TABLE (
    fk_tfuncionario_docente BIGINT,
    docente_nombre          VARCHAR,
    es_propia               VARCHAR
)
LANGUAGE sql
STABLE
AS $$
    SELECT f.PK_TFUNCIONARIO,
           NULLIF(TRIM(CONCAT_WS(' ', us.PRIMER_NOMBRE, us.SEGUNDO_NOMBRE,
                                      us.PRIMER_APELLIDO, us.SEGUNDO_APELLIDO)), '')::VARCHAR,
           CASE WHEN f.PK_TFUNCIONARIO = p_fk_tfuncionario_propio THEN 'S' ELSE 'N' END::VARCHAR
      FROM (SELECT 1 AS prioridad, da.FK_TFUNCIONARIO AS fk, da.PK_TDOCENTE_ASIGNATURA AS orden
              FROM academico_test.TACTIVIDAD a
              JOIN academico_test.TDOCENTE_ASIGNATURA da
                ON da.FK_TGRUPO = a.FK_TGRUPO
               AND da.FK_TASIGNATURA = a.FK_TASIGNATURA
               AND da.ACTIVE = TRUE
             WHERE a.PK_TACTIVIDAD = p_pk_tactividad
            UNION ALL
            SELECT 2, u.FK_TFUNCIONARIO, 0
              FROM academico_test.TACTIVIDAD a
              JOIN academico_test.TUNIDAD u ON u.PK_TUNIDAD = a.FK_TUNIDAD
             WHERE a.PK_TACTIVIDAD = p_pk_tactividad
               AND u.FK_TFUNCIONARIO IS NOT NULL) x
      JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = x.fk
      JOIN academico_test.TUSUARIO us    ON us.PK_TUSUARIO = f.FK_TUSUARIO
     ORDER BY x.prioridad, x.orden DESC
     LIMIT 1;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_docente_dicta(BIGINT, BIGINT)
    IS 'INTERNO: docente (fk_tfuncionario_docente, docente_nombre, y es_propia = S si es p_fk_tfuncionario_propio, el funcionario de quien consulta) al que pertenece una actividad: el que la dicta (TDOCENTE_ASIGNATURA activa del grupo+asignatura, la asignación más reciente) o, si no tiene grupo, el autor de su unidad. 0 filas si no se resuelve. Lo usan las filas de GET /planeador/actividades/mias y /calendario para mostrar de quién es cada actividad.';

-- ---------------------------------------------------------------------------
-- 5. GET /planeador/docentes: selector de docente del planeador.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_planeador_docentes_listar(BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_planeador_docentes_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_establecimiento     BIGINT DEFAULT NULL,
    p_fk_sede                BIGINT DEFAULT NULL,
    p_fk_periodo             BIGINT DEFAULT NULL
)
RETURNS TABLE (
    pk_tfuncionario BIGINT,
    nombre_completo VARCHAR,
    identificacion  VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_alc RECORD;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    SELECT * INTO v_alc
      FROM academico_test.fn_planeador_alcance_docente(p_pk_usuario_solicitante, NULL, p_fk_sede, p_fk_periodo);

    -- Docente puro: solo él. Alcance total: exige elegir el establecimiento.
    IF v_alc.solo_propias THEN
        IF v_alc.fk_tfuncionario IS NULL THEN
            RETURN;
        END IF;
        RETURN QUERY
        SELECT f.PK_TFUNCIONARIO,
               NULLIF(TRIM(CONCAT_WS(' ', us.PRIMER_NOMBRE, us.SEGUNDO_NOMBRE,
                                          us.PRIMER_APELLIDO, us.SEGUNDO_APELLIDO)), '')::VARCHAR,
               us.IDENTIFICACION::VARCHAR
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TUSUARIO us ON us.PK_TUSUARIO = f.FK_TUSUARIO
         WHERE f.PK_TFUNCIONARIO = v_alc.fk_tfuncionario;
        RETURN;
    END IF;

    IF v_alc.alcance_total AND p_fk_establecimiento IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT * FROM academico_test.fn_planeador_docentes_listar_interno(
        p_fk_establecimiento, v_alc.alcance_total, v_alc.periodos_lectura, NULL, v_alc.grupos_lectura);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_planeador_docentes_listar(BIGINT, BIGINT, BIGINT, BIGINT)
    IS 'GET /planeador/docentes?establecimiento=&sede=&periodo=: docentes (pk_tfuncionario, nombre_completo, identificacion) cuyo planeador puede ver el usuario, por nombre. Gate VER sobre PLANEADOR. Alcance total (nivel 0-1): los del establecimiento pedido, obligatorio (sin él 0 filas). Nivel 2/3 que administra: los de sus sedes (nivel 3: solo sus pares sede+jornada), opcionalmente de un establecimiento. Docente puro: solo él. p_fk_sede / p_fk_periodo (opcionales, acotan): los que dictan en esa sede / ese periodo académico dentro del alcance; con cualquiera de los dos el alcance total ya no exige establecimiento. Lógica en fn_planeador_docentes_listar_interno.';

INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                          path_template, execution_mode, http_method, param_types, detail)
SELECT
    'planeador-docentes-listar',
    $q$SELECT * FROM academico_test.fn_planeador_docentes_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.ESTABLECIMIENTO AS BIGINT),
    CAST(:QUERY.SEDE AS BIGINT),
    CAST(:QUERY.PERIODO AS BIGINT)
);$q$,
    'postgres', false, false, m.id_microservice,
    '/planeador/docentes', 'SELECT', 'GET', '{"QUERY.ESTABLECIMIENTO": "BIGINT", "QUERY.SEDE": "BIGINT", "QUERY.PERIODO": "BIGINT"}'::jsonb,
    'Selector de docente del Planeador (vista de solo lectura del planeador de otro docente). ?establecimiento= (pk_establecimiento): obligatorio para super admin / territoriales (sin él 0 filas); opcional para los demás, que solo ven los docentes de sus sedes (coordinador: de sus pares sede+jornada). Un docente puro recibe solo su propia fila. Filas: pk_tfuncionario, nombre_completo, identificacion, ordenadas por nombre. ?sede= (pk_tsede) y ?periodo= (pk_tperiodo_academico), opcionales: solo los que dictan en esa sede / ese periodo (con cualquiera de los dos el super admin ya no necesita ?establecimiento=). El pk_tfuncionario es el ?funcionario= de /planeador/actividades/mias, /calendario, /stats, /tabs, /planeador/unidades, /unidades/tabs y /planeador/docentes/grupos|grado-asignatura. Gate VER sobre PLANEADOR.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- Los roles que hoy leen /planeador/actividades/tabs y /mias.
INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
  JOIN public.role r ON r.name IN (
        'CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-RECTOR', 'CEVAL-COORDINADOR', 'CEVAL-DOCENTE',
        'CEVAL-DIRECTOR_GRUPO', 'CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO',
        'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_AREA_CALIDAD', 'CEVAL-JEFE_AREA_COBERTURA',
        'CEVAL-JEFE_AREA_PLANEACION', 'CEVAL-PSICO_ORIENTADOR')
 WHERE q.uuid = 'planeador-docentes-listar'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 6. ?funcionario= en las lecturas del tablero. Texto completo con
--    dollar-quoting, como V527/V529/V531. mias, calendario y unidades agregan
--    fk_tfuncionario_docente, docente_nombre y es_propia (S/N). mias y
--    calendario ordenan por WITH ORDINALITY (el orden de la función).
-- ---------------------------------------------------------------------------
UPDATE public.query q
   SET query = $q$SELECT u.*,
       u.fk_tfuncionario AS fk_tfuncionario_docente,
       u.docente         AS docente_nombre,
       CASE WHEN u.fk_tfuncionario = academico_test.fn_funcionario_actual(
                     public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT))
            THEN 'S' ELSE 'N' END AS es_propia
  FROM academico_test.fn_unidad_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.SEARCH AS VARCHAR),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.GRADO AS BIGINT),
    CAST(:QUERY.FUNCIONARIO AS BIGINT),
    COALESCE(CAST(:QUERY.INCLUIR_INACTIVOS AS BOOLEAN), FALSE),
    COALESCE(CAST(:QUERY.ORDEN_POR AS VARCHAR), 'nombre'),
    COALESCE(CAST(:QUERY.ORDEN_ASC AS BOOLEAN), TRUE),
    COALESCE(CAST(:QUERY.SIZE AS INT), 20),
    COALESCE(CAST(:QUERY.OFFSET AS INT), 0),
    CAST(:QUERY.DIA AS DATE),
    COALESCE(CAST(:QUERY.DIAS_GRACIA AS INT), 2),
    CAST(:QUERY.SEDE AS BIGINT),
    CAST(:QUERY.PERIODO AS BIGINT)
) u;$q$,
       param_types = COALESCE(q.param_types, '{}'::jsonb) || '{"QUERY.FUNCIONARIO": "BIGINT", "QUERY.SEDE": "BIGINT", "QUERY.PERIODO": "BIGINT"}'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/unidades'
   AND q.http_method     = 'GET'
   AND q.query LIKE '%fn_unidad_listar%';

UPDATE public.query q
   SET query = $q$SELECT f.*, d.fk_tfuncionario_docente, d.docente_nombre, COALESCE(d.es_propia, 'N') AS es_propia
  FROM academico_test.fn_actividad_listar_docente(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.SEARCH AS VARCHAR),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.UNIDAD AS BIGINT),
    string_to_array(NULLIF(TRIM(CAST(:QUERY.ESTADOS AS VARCHAR)), ''), ','),
    COALESCE(CAST(:QUERY.DIAS_GRACIA AS INT), 2),
    COALESCE(CAST(:QUERY.ORDEN_POR AS VARCHAR), 'fecha_inicio'),
    COALESCE(CAST(:QUERY.ORDEN_ASC AS BOOLEAN), TRUE),
    COALESCE(CAST(:QUERY.SIZE AS INT), 20),
    COALESCE(CAST(:QUERY.OFFSET AS INT), 0),
    CAST(:QUERY.DIA AS DATE),
    string_to_array(NULLIF(TRIM(CAST(:QUERY.GRADO_ASIGNATURA_PARES AS VARCHAR)), ''), ','),
    CAST(:QUERY.FUNCIONARIO AS BIGINT),
    CAST(:QUERY.SEDE AS BIGINT),
    CAST(:QUERY.PERIODO AS BIGINT)
) WITH ORDINALITY f
  LEFT JOIN LATERAL academico_test.fn_actividad_docente_dicta(
           f.pk_tactividad,
           academico_test.fn_funcionario_actual(public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT))) d ON TRUE
 ORDER BY f.ordinality;$q$,
       param_types = COALESCE(q.param_types, '{}'::jsonb) || '{"QUERY.FUNCIONARIO": "BIGINT", "QUERY.SEDE": "BIGINT", "QUERY.PERIODO": "BIGINT"}'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/mias'
   AND q.http_method     = 'GET'
   AND q.query LIKE '%fn_actividad_listar_docente%';

UPDATE public.query q
   SET query = $q$SELECT c.*, d.fk_tfuncionario_docente, d.docente_nombre, COALESCE(d.es_propia, 'N') AS es_propia
  FROM academico_test.fn_actividad_calendario_docente(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.FECHA_DESDE AS DATE),
    CAST(:QUERY.FECHA_HASTA AS DATE),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.UNIDAD AS BIGINT),
    COALESCE(CAST(:QUERY.DIAS_GRACIA AS INT), 2),
    string_to_array(NULLIF(TRIM(CAST(:QUERY.GRADO_ASIGNATURA_PARES AS VARCHAR)), ''), ','),
    CAST(:QUERY.FUNCIONARIO AS BIGINT),
    CAST(:QUERY.SEDE AS BIGINT),
    CAST(:QUERY.PERIODO AS BIGINT)
) WITH ORDINALITY c
  LEFT JOIN LATERAL academico_test.fn_actividad_docente_dicta(
           c.pk_tactividad,
           academico_test.fn_funcionario_actual(public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT))) d ON TRUE
 ORDER BY c.ordinality;$q$,
       param_types = COALESCE(q.param_types, '{}'::jsonb) || '{"QUERY.FUNCIONARIO": "BIGINT", "QUERY.SEDE": "BIGINT", "QUERY.PERIODO": "BIGINT"}'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/calendario'
   AND q.http_method     = 'GET'
   AND q.query LIKE '%fn_actividad_calendario_docente%';

UPDATE public.query q
   SET query = $q$SELECT t.pendientes_por_evaluar AS pending,
       t.en_evaluacion          AS in_progress,
       t.finalizadas            AS completed,
       t.vencidas               AS cancelled,
       t.pendientes_por_evaluar,
       t.en_evaluacion,
       t.finalizadas,
       t.vencidas,
       t.total
  FROM academico_test.fn_actividad_resumen_estados_docente(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.UNIDAD AS BIGINT),
    CAST(:QUERY.FECHA_DESDE AS DATE),
    CAST(:QUERY.FECHA_HASTA AS DATE),
    COALESCE(CAST(:QUERY.DIAS_GRACIA AS INT), 2),
    string_to_array(NULLIF(TRIM(CAST(:QUERY.GRADO_ASIGNATURA_PARES AS VARCHAR)), ''), ','),
    CAST(:QUERY.FUNCIONARIO AS BIGINT),
    CAST(:QUERY.SEDE AS BIGINT),
    CAST(:QUERY.PERIODO AS BIGINT)
) t;$q$,
       param_types = COALESCE(q.param_types, '{}'::jsonb) || '{"QUERY.FUNCIONARIO": "BIGINT", "QUERY.SEDE": "BIGINT", "QUERY.PERIODO": "BIGINT"}'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/stats'
   AND q.http_method     = 'GET'
   AND q.query LIKE '%fn_actividad_resumen_estados_docente%';

UPDATE public.query q
   SET query = $q$SELECT * FROM academico_test.fn_planeador_actividad_tabs_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.FUNCIONARIO AS BIGINT),
    CAST(:QUERY.SEDE AS BIGINT),
    CAST(:QUERY.PERIODO AS BIGINT)
);$q$,
       param_types = COALESCE(q.param_types, '{}'::jsonb) || '{"QUERY.FUNCIONARIO": "BIGINT", "QUERY.SEDE": "BIGINT", "QUERY.PERIODO": "BIGINT"}'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/tabs'
   AND q.http_method     = 'GET';

UPDATE public.query q
   SET query = $q$SELECT * FROM academico_test.fn_docente_unidad_tabs_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.FUNCIONARIO AS BIGINT),
    CAST(:QUERY.SEDE AS BIGINT),
    CAST(:QUERY.PERIODO AS BIGINT)
);$q$,
       param_types = COALESCE(q.param_types, '{}'::jsonb) || '{"QUERY.FUNCIONARIO": "BIGINT", "QUERY.SEDE": "BIGINT", "QUERY.PERIODO": "BIGINT"}'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/unidades/tabs'
   AND q.http_method     = 'GET';

UPDATE public.query q
   SET query = $q$SELECT * FROM academico_test.fn_docente_grupos_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.PERIODO AS BIGINT),
    CAST(:QUERY.FUNCIONARIO AS BIGINT),
    CAST(:QUERY.SEDE AS BIGINT)
);$q$,
       param_types = COALESCE(q.param_types, '{}'::jsonb) || '{"QUERY.FUNCIONARIO": "BIGINT", "QUERY.SEDE": "BIGINT"}'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/docentes/grupos'
   AND q.http_method     = 'GET';

UPDATE public.query q
   SET query = $q$SELECT * FROM academico_test.fn_docente_grado_asignatura_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.PERIODO AS BIGINT),
    CAST(:QUERY.FUNCIONARIO AS BIGINT),
    CAST(:QUERY.REFERENTE AS BIGINT),
    CAST(:QUERY.SEDE AS BIGINT)
);$q$,
       param_types = COALESCE(q.param_types, '{}'::jsonb) || '{"QUERY.FUNCIONARIO": "BIGINT", "QUERY.SEDE": "BIGINT"}'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/docentes/grado-asignatura'
   AND q.http_method     = 'GET';

DO $$
DECLARE
    v_faltan TEXT;
BEGIN
    SELECT string_agg(r.ruta, ', ')
      INTO v_faltan
      FROM (VALUES ('/planeador/actividades/mias'), ('/planeador/actividades/calendario'),
                   ('/planeador/actividades/stats'), ('/planeador/actividades/tabs'),
                   ('/planeador/unidades/tabs'), ('/planeador/docentes/grupos'),
                   ('/planeador/docentes/grado-asignatura'), ('/planeador/unidades')) AS r(ruta)
     WHERE NOT EXISTS (SELECT 1 FROM public.query q
                        WHERE q.path_template = r.ruta AND q.http_method = 'GET'
                          AND q.query LIKE '%:QUERY.FUNCIONARIO AS BIGINT%'
                          AND q.param_types ? 'QUERY.FUNCIONARIO'
                          AND q.query LIKE '%:QUERY.SEDE AS BIGINT%'
                          AND q.param_types ? 'QUERY.SEDE');
    IF v_faltan IS NOT NULL THEN
        RAISE EXCEPTION 'No quedo ?funcionario= / ?sede= en: %', v_faltan;
    END IF;
    SELECT string_agg(r.ruta, ', ')
      INTO v_faltan
      FROM (VALUES ('/planeador/actividades/mias'), ('/planeador/actividades/calendario'),
                   ('/planeador/unidades')) AS r(ruta)
     WHERE NOT EXISTS (SELECT 1 FROM public.query q
                        WHERE q.path_template = r.ruta AND q.http_method = 'GET'
                          AND q.query LIKE '%docente_nombre%es_propia%');
    IF v_faltan IS NOT NULL THEN
        RAISE EXCEPTION 'No quedo el docente de cada fila en: %', v_faltan;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'planeador-docentes-listar') THEN
        RAISE EXCEPTION 'No se registro GET /planeador/docentes (falta el microservicio eval-col)';
    END IF;
END $$;
