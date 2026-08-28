-- =============================================================================
-- V116 — los filtros de listado pasan de id a CODIGO.
--
-- Antes el front mandaba la llave primaria: `statuses=["533"]`. Eso tiene dos
-- costos. Uno visible: la URL y el buscador muestran un numero que no dice
-- nada, y si el catalogo todavia no cargo el input queda escrito con el id
-- crudo. Otro de fondo: el id es interno y no deberia ser parte del contrato
-- con el cliente — atarlo obliga a que cualquier consumidor conozca las llaves
-- de la base.
--
-- Ahora viaja el codigo: `statuses=["A"]`, `zones=["U"]`, `roles=["RECTOR"]`.
--
-- Cambian SIETE filtros en tres dominios:
--   * establecimientos: p_estados, p_departamentos, p_municipios
--   * sedes:            p_zones
--   * funcionarios:     p_roles, p_work_schedules
--
-- Como se resuelve cada uno:
--   * Los que salen de TLISTA_VALOR (estado, zona, jornada) se resuelven con
--     una subconsulta ACOTADA POR CATEGORIA. No es opcional: `valor` solo es
--     unico dentro de su categoria — 'A' es Activo en ESTADO_ESTABLECIMIENTO y
--     Abierto en ESTADOPERIODO. Sin el filtro de categoria se mezclan
--     catalogos y el resultado es silenciosamente incorrecto.
--   * Departamento y municipio ya venian JOINeados, asi que basta comparar
--     d.CODIGO / m.CODIGO sobre el alias, sin subconsulta.
--   * Rol y sede se resuelven contra su propia tabla por CODIGO.
--
-- Sobre la unicidad, que se verifico contra los datos antes de escribir esto:
--   departamento 33/33, municipio 1120/1120, rol 17/17, estado 5/5, zona 3/3,
--   jornada 6/6 — todos unicos y sin nulos.
--   sede 223 filas / 211 codigos: NO es unico. El codigo EE-REUSE-SRV-15891 lo
--   comparten 10 sedes. Filtrar funcionarios por ese codigo devuelve los de
--   las 10, y ESO ES LO PEDIDO ("si hay mas coincidencias tambien apareceran").
--   Por eso p_campus_id pasa de `= p_campus_id` a `IN (...)`: con el id era
--   una sede; con el codigo puede ser varias, y la comparacion tiene que
--   admitirlo.
--
-- Todas cambian de firma (bigint[] -> character varying[]), asi que NO alcanza
-- un CREATE OR REPLACE: cambiar el tipo de un parametro crea una SOBRECARGA, y
-- con dos versiones conviviendo las llamadas quedan ambiguas y PG las rechaza.
-- De ahi el DROP + CREATE de cada una. Los tres wrappers _paginado no filtran
-- —solo reenvian— pero cambian de firma igual, porque el tipo viaja a traves.
--
-- Las filas de public.query (listado y reporte de los tres dominios) tambien
-- cambian: sus CAST(... AS BIGINT[]) pasan a VARCHAR[] y su param_types
-- acompaña. Van en V117 para que este archivo quede solo con las funciones.
-- =============================================================================

SET search_path TO academico_test, public;

DROP FUNCTION IF EXISTS academico_test.fn_est_listar(bigint, character varying, bigint[], bigint[], bigint[], character varying, boolean, integer, integer);
CREATE OR REPLACE FUNCTION academico_test.fn_est_listar(p_pk_usuario_solicitante bigint, p_search character varying DEFAULT NULL::character varying, p_departamentos character varying[] DEFAULT NULL::character varying[], p_municipios character varying[] DEFAULT NULL::character varying[], p_estados character varying[] DEFAULT NULL::character varying[], p_sort_campo character varying DEFAULT NULL::character varying, p_sort_desc boolean DEFAULT false, p_page_index integer DEFAULT 0, p_page_size integer DEFAULT 10)
 RETURNS TABLE(pk_establecimiento bigint, codigo character varying, nombre character varying, nit character varying, fk_departamento bigint, departamento_nombre character varying, fk_municipio bigint, municipio_nombre character varying, fk_estado bigint, estado_nombre character varying)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_page_size  INT := CASE
        WHEN p_page_size IS NULL THEN NULL   -- reporte: sin limite
        ELSE LEAST(CASE WHEN p_page_size > 0 THEN p_page_size ELSE 10 END, 100)
    END;
    v_page_index INT := GREATEST(COALESCE(p_page_index, 0), 0);
BEGIN
    -- Gate UNICO (CU-86e2w4xdt): capability 'VER' sobre el menu ESTABLECIMIENTO
    -- + scope de lectura (el JOIN fn_usuario_ee_lectura de abajo). El
    -- SUPER_ADMIN (categoria de rol nivel 0) no pasa por la capability;
    -- fn_usuario_ee_lectura ya le devuelve todo (nivel 0-1). No hay
    -- ningun otro gate en esta funcion.
    IF academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante) <> 0
       AND NOT academico_test.fn_usuario_puede_en_menu(p_pk_usuario_solicitante, 'ESTABLECIMIENTO', 'VER') THEN
        RAISE EXCEPTION 'El usuario no tiene permiso para ver en el modulo ESTABLECIMIENTO'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT e.PK_ESTABLECIMIENTO, e.CODIGO, e.NOMBRE, e.NIT,
           d.PK_DEPARTAMENTO, d.NOMBRE,
           m.PK_TMUNICIPIO, m.NOMBRE,
           e.FK_TLV_ESTADO_ESTABLECIMIENTO, tlv.NOMBRE
      FROM academico_test.TESTABLECIMIENTO e
      JOIN academico_test.fn_usuario_ee_lectura(p_pk_usuario_solicitante) ee
        ON ee.establecimiento_id = e.PK_ESTABLECIMIENTO
      JOIN academico_test.TMUNICIPIO    m ON m.PK_TMUNICIPIO    = e.FK_TMUNICIPIO
      JOIN academico_test.TDEPARTAMENTO d ON d.PK_DEPARTAMENTO  = m.PK_TDEPARTAMENTO
 LEFT JOIN academico_test.TLISTA_VALOR  tlv ON tlv.PK_LISTA_VALOR = e.FK_TLV_ESTADO_ESTABLECIMIENTO
     WHERE e.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_search), '') IS NULL
            OR e.NOMBRE ILIKE '%' || p_search || '%'
            OR e.CODIGO ILIKE '%' || p_search || '%'
            OR d.NOMBRE ILIKE '%' || p_search || '%'
            OR m.NOMBRE ILIKE '%' || p_search || '%')
       AND (p_departamentos IS NULL OR CARDINALITY(p_departamentos) = 0
            OR d.CODIGO = ANY(p_departamentos))
       AND (p_municipios IS NULL OR CARDINALITY(p_municipios) = 0
            OR m.CODIGO = ANY(p_municipios))
       AND (p_estados IS NULL OR CARDINALITY(p_estados) = 0
            OR e.FK_TLV_ESTADO_ESTABLECIMIENTO IN (SELECT lv.PK_LISTA_VALOR FROM academico_test.TLISTA_VALOR lv
                        WHERE lv.CATEGORIA = 'ESTADO_ESTABLECIMIENTO' AND lv.VALOR = ANY(p_estados)))
     ORDER BY
        CASE WHEN p_sort_campo = 'name'         AND NOT p_sort_desc THEN e.NOMBRE   END ASC,
        CASE WHEN p_sort_campo = 'name'         AND     p_sort_desc THEN e.NOMBRE   END DESC,
        CASE WHEN p_sort_campo = 'dane'         AND NOT p_sort_desc THEN e.CODIGO   END ASC,
        CASE WHEN p_sort_campo = 'dane'         AND     p_sort_desc THEN e.CODIGO   END DESC,
        CASE WHEN p_sort_campo = 'department'   AND NOT p_sort_desc THEN d.NOMBRE   END ASC,
        CASE WHEN p_sort_campo = 'department'   AND     p_sort_desc THEN d.NOMBRE   END DESC,
        CASE WHEN p_sort_campo = 'municipality' AND NOT p_sort_desc THEN m.NOMBRE   END ASC,
        CASE WHEN p_sort_campo = 'municipality' AND     p_sort_desc THEN m.NOMBRE   END DESC,
        CASE WHEN p_sort_campo = 'status'       AND NOT p_sort_desc THEN tlv.NOMBRE END ASC,
        CASE WHEN p_sort_campo = 'status'       AND     p_sort_desc THEN tlv.NOMBRE END DESC,
        e.NOMBRE ASC,
        e.PK_ESTABLECIMIENTO ASC
     LIMIT v_page_size
    OFFSET v_page_index * COALESCE(v_page_size, 0);
END;
$function$;

DROP FUNCTION IF EXISTS academico_test.fn_est_contar(bigint, character varying, bigint[], bigint[], bigint[]);
CREATE OR REPLACE FUNCTION academico_test.fn_est_contar(p_pk_usuario_solicitante bigint, p_search character varying DEFAULT NULL::character varying, p_departamentos character varying[] DEFAULT NULL::character varying[], p_municipios character varying[] DEFAULT NULL::character varying[], p_estados character varying[] DEFAULT NULL::character varying[])
 RETURNS bigint
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_total BIGINT;
BEGIN
    -- Gate UNICO (CU-86e2w4xdt): capability 'VER' sobre el menu ESTABLECIMIENTO.
    -- El SUPER_ADMIN (categoria de rol nivel 0) no pasa por la capability;
    -- fn_usuario_ee_lectura ya le cuenta todo (nivel 0-1). No hay ningun otro
    -- gate en esta funcion.
    IF academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante) <> 0
       AND NOT academico_test.fn_usuario_puede_en_menu(p_pk_usuario_solicitante, 'ESTABLECIMIENTO', 'VER') THEN
        RAISE EXCEPTION 'El usuario no tiene permiso para ver en el modulo ESTABLECIMIENTO'
            USING ERRCODE = '42501';
    END IF;

    SELECT COUNT(*)
      INTO v_total
      FROM academico_test.TESTABLECIMIENTO e
      JOIN academico_test.fn_usuario_ee_lectura(p_pk_usuario_solicitante) ee
        ON ee.establecimiento_id = e.PK_ESTABLECIMIENTO
      JOIN academico_test.TMUNICIPIO    m ON m.PK_TMUNICIPIO    = e.FK_TMUNICIPIO
      JOIN academico_test.TDEPARTAMENTO d ON d.PK_DEPARTAMENTO  = m.PK_TDEPARTAMENTO
     WHERE e.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_search), '') IS NULL
            OR e.NOMBRE ILIKE '%' || p_search || '%'
            OR e.CODIGO ILIKE '%' || p_search || '%'
            OR d.NOMBRE ILIKE '%' || p_search || '%'
            OR m.NOMBRE ILIKE '%' || p_search || '%')
       AND (p_departamentos IS NULL OR CARDINALITY(p_departamentos) = 0
            OR d.CODIGO = ANY(p_departamentos))
       AND (p_municipios IS NULL OR CARDINALITY(p_municipios) = 0
            OR m.CODIGO = ANY(p_municipios))
       AND (p_estados IS NULL OR CARDINALITY(p_estados) = 0
            OR e.FK_TLV_ESTADO_ESTABLECIMIENTO IN (SELECT lv.PK_LISTA_VALOR FROM academico_test.TLISTA_VALOR lv
                        WHERE lv.CATEGORIA = 'ESTADO_ESTABLECIMIENTO' AND lv.VALOR = ANY(p_estados)));
    RETURN v_total;
END;
$function$;

DROP FUNCTION IF EXISTS academico_test.fn_usu_empleados_listar(bigint, character varying, bigint[], bigint[], character varying[], bigint, character varying, boolean, integer, integer);
CREATE OR REPLACE FUNCTION academico_test.fn_usu_empleados_listar(p_pk_usuario_solicitante bigint, p_search character varying DEFAULT NULL::character varying, p_roles character varying[] DEFAULT NULL::character varying[], p_work_schedules character varying[] DEFAULT NULL::character varying[], p_statuses character varying[] DEFAULT NULL::character varying[], p_campus_id bigint DEFAULT NULL::bigint, p_sort_campo character varying DEFAULT NULL::character varying, p_sort_desc boolean DEFAULT false, p_page_index integer DEFAULT 0, p_page_size integer DEFAULT 10)
 RETURNS TABLE(pk_empleado bigint, numero_documento character varying, primer_nombre character varying, segundo_nombre character varying, primer_apellido character varying, segundo_apellido character varying, nombre_completo character varying, fk_estado character varying, estado_label character varying, jornada_id bigint, jornada_nombre character varying, roles jsonb, sedes jsonb, estados_permisos jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    -- V114, reaplicado sobre esta firma: p_page_size NULL se propaga como
    -- NULL en vez de caer al default de 10 -- lo necesita el reporte sin
    -- paginar (fn_usu_empleados_listar_paginado no se ve afectado: siempre
    -- envia un v_page_size ya normalizado, nunca NULL). Cualquier valor
    -- NO nulo se comporta identico a antes, incluido 0 -> 10 y el tope 100.
    v_page_size  INT := CASE
        WHEN p_page_size IS NULL THEN NULL   -- reporte: sin limite
        ELSE LEAST(CASE WHEN p_page_size > 0 THEN p_page_size ELSE 10 END, 100)
    END;
    v_page_index INT := GREATEST(COALESCE(p_page_index, 0), 0);
    v_es_super   BOOLEAN := academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante);
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    -- REV6 (V51 REV5, cambio de modelo -- ver header de este archivo): ya
    -- no se resuelve UN EE via fn_resolver_establecimiento_unico (fallaba
    -- con NULL si el solicitante administra 2+ EE a la vez, algo que antes
    -- era raro y ahora es comun por como TFUNCIONARIO reusa TUSUARIO). Se
    -- pasa al mismo patron "union de EE accesibles" que ya usa
    -- fn_sed_listar/_contar: rector, secretaria, o jefe de sistema (rol 8
    -- via TSEDE_USUARIO) de CUALQUIERA de sus EE, no de "el unico".
    IF NOT v_es_super AND NOT EXISTS (
        WITH ee_accesibles AS (
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT DISTINCT s.FK_TESTABLECIMIENTO
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 8 AND su.FK_TUSUARIO = p_pk_usuario_solicitante
        ),
        -- REV7 -- coordinador (rol 11) de una sede puntual: alcance de SEDE,
        -- no de establecimiento (ver funcionarios_ee mas abajo).
        sedes_coordinador AS (
            SELECT su.FK_TSEDE
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 11 AND su.FK_TUSUARIO = p_pk_usuario_solicitante
        )
        SELECT 1 FROM ee_accesibles
        UNION ALL
        SELECT 1 FROM sedes_coordinador
    ) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    WITH ee_accesibles AS (
        SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT DISTINCT s.FK_TESTABLECIMIENTO
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 8 AND su.FK_TUSUARIO = p_pk_usuario_solicitante
    ),
    -- REV7 -- coordinador (rol 11) de una sede puntual: alcance de SEDE, no
    -- de establecimiento (ver funcionarios_ee mas abajo).
    sedes_coordinador AS (
        SELECT su.FK_TSEDE
          FROM academico_test.TSEDE_USUARIO su
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
         WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 11 AND su.FK_TUSUARIO = p_pk_usuario_solicitante
    ),
    -- REV8 -- todas las sedes donde el solicitante tiene alguna autoridad
    -- (las de sus EE accesibles, mas la suya propia si es coordinador).
    -- Se usa para acotar roles_agg/sedes_agg/estados_agg/jornada: antes,
    -- una vez que un funcionario compartido entre EE quedaba visible (por
    -- UN permiso en un EE accesible), se mostraban TODOS sus permisos,
    -- incluidos los de sedes/EE totalmente ajenos al solicitante. Ahora
    -- cada agregado solo trae lo que cae dentro de esta sede-alcance
    -- (super-admin no se filtra, ve todo).
    sedes_accesibles AS (
        SELECT s.PK_TSEDE
          FROM academico_test.TSEDE s
         WHERE s.ACTIVE = TRUE AND s.FK_TESTABLECIMIENTO IN (SELECT PK_ESTABLECIMIENTO FROM ee_accesibles)
        UNION
        SELECT FK_TSEDE FROM sedes_coordinador
    ),
    funcionarios_ee AS (
        SELECT e.FK_TFUNCIONARIO_RECTOR AS pk_tfuncionario
          FROM academico_test.TESTABLECIMIENTO e
         WHERE e.PK_ESTABLECIMIENTO IN (SELECT PK_ESTABLECIMIENTO FROM ee_accesibles) AND e.ACTIVE = TRUE
           AND e.FK_TFUNCIONARIO_RECTOR IS NOT NULL
        UNION
        SELECT e.FK_TFUNCIONARIO_SECRETARIA
          FROM academico_test.TESTABLECIMIENTO e
         WHERE e.PK_ESTABLECIMIENTO IN (SELECT PK_ESTABLECIMIENTO FROM ee_accesibles) AND e.ACTIVE = TRUE
           AND e.FK_TFUNCIONARIO_SECRETARIA IS NOT NULL
        UNION
        SELECT f3.PK_TFUNCIONARIO
          FROM academico_test.TFUNCIONARIO f3
          JOIN academico_test.TSEDE_USUARIO su ON su.FK_TUSUARIO = f3.FK_TUSUARIO AND su.ACTIVE = TRUE
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
         WHERE s.FK_TESTABLECIMIENTO IN (SELECT PK_ESTABLECIMIENTO FROM ee_accesibles) AND f3.ACTIVE = TRUE
           AND su.FK_TROL >= 7 AND su.FK_TROL NOT IN (15, 16)
        -- REV7 -- coordinador: SOLO funcionarios con permiso activo en SU
        -- propia sede (no todo el EE), y solo "otros cargos": excluye
        -- ademas rector(7)/jefe de sistema(8) -- el coordinador no tiene
        -- esa autoridad, aunque tecnicamente compartiera sede con alguno.
        UNION
        SELECT f4.PK_TFUNCIONARIO
          FROM academico_test.TFUNCIONARIO f4
          JOIN academico_test.TSEDE_USUARIO su ON su.FK_TUSUARIO = f4.FK_TUSUARIO AND su.ACTIVE = TRUE
         WHERE su.FK_TSEDE IN (SELECT FK_TSEDE FROM sedes_coordinador) AND f4.ACTIVE = TRUE
           AND su.FK_TROL >= 9 AND su.FK_TROL NOT IN (15, 16)
    ),
    base AS (
        -- Funcionarios activos cuyo TUSUARIO matchea search/estado y que
        -- tienen al menos un TSEDE_USUARIO activo que matchea los EXISTS
        -- con roles/workSchedules/campusId. Ya NO exige FK_ESTABLECIMIENTO
        -- NOT NULL (ver comentario de la funcion).
        SELECT DISTINCT f.PK_TFUNCIONARIO, u.PK_TUSUARIO, u.IDENTIFICACION,
               u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
               u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO,
               u.ESTADO
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TUSUARIO      u ON u.PK_TUSUARIO = f.FK_TUSUARIO
         WHERE f.ACTIVE = TRUE
           AND (v_es_super OR f.PK_TFUNCIONARIO IN (SELECT pk_tfuncionario FROM funcionarios_ee))
           -- V112 (punto 2), reaplicado sobre esta firma: 1 sola expresion
           -- concatenada en vez de 4 ILIKE sueltos, para que matchee el
           -- texto de idx_tusuario_busqueda_trgm (V112, sigue vivo en el
           -- servidor) y el planner pueda usarlo en vez de Seq Scan.
           AND (NULLIF(TRIM(p_search), '') IS NULL
                OR (COALESCE(u.PRIMER_NOMBRE,'') || ' ' || COALESCE(u.SEGUNDO_NOMBRE,'') || ' ' ||
                    COALESCE(u.PRIMER_APELLIDO,'') || ' ' || COALESCE(u.SEGUNDO_APELLIDO,'') || ' ' ||
                    COALESCE(u.IDENTIFICACION,'')) ILIKE '%' || p_search || '%'
                OR EXISTS (
                    SELECT 1 FROM academico_test.TSEDE_USUARIO su2
                      JOIN academico_test.TSEDE  s ON s.PK_TSEDE = su2.FK_TSEDE
                      JOIN academico_test.TROL   r ON r.PK_TROL  = su2.FK_TROL
                     WHERE su2.FK_TUSUARIO = u.PK_TUSUARIO
                       AND su2.ACTIVE      = TRUE
                       AND (s.NOMBRE ILIKE '%' || p_search || '%'
                            OR r.NOMBRE ILIKE '%' || p_search || '%')
                  )
           )
           -- REV9 -- filtra por el estado del PERMISO (TSEDE_USUARIO.TLV_ESTADO),
           -- no por el estado de la cuenta (TUSUARIO.ESTADO): son dos campos
           -- distintos, y el front (badges de la tabla, estados_agg) siempre
           -- mostro el primero. Filtrar por el segundo dejaba el filtro sin
           -- relacion con lo que se ve en pantalla. "Al menos un permiso con
           -- ese estado" -- mismo criterio que estados_agg (puede mostrar
           -- "Activo, Suspendido" a la vez si los permisos estan mezclados).
           AND (p_statuses IS NULL OR CARDINALITY(p_statuses) = 0
                OR EXISTS (
                    SELECT 1 FROM academico_test.TSEDE_USUARIO su6
                     WHERE su6.FK_TUSUARIO = u.PK_TUSUARIO
                       AND su6.ACTIVE      = TRUE
                       AND su6.FK_TROL >= 7 AND su6.FK_TROL NOT IN (15, 16)
                       AND su6.TLV_ESTADO = ANY(
                           SELECT CASE
                                    WHEN x = 'ACTIVE'    THEN 'ACTIVO'
                                    WHEN x = 'SUSPENDED' THEN 'INACTIVO'
                                  END
                             FROM unnest(p_statuses) AS x
                            WHERE x IN ('ACTIVE','SUSPENDED')
                       )
                ))
           AND (p_campus_id IS NULL OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su3
                 WHERE su3.FK_TUSUARIO = u.PK_TUSUARIO
                   AND su3.ACTIVE      = TRUE
                   AND su3.FK_TSEDE    = p_campus_id
                   AND su3.FK_TROL >= 7 AND su3.FK_TROL NOT IN (15, 16)
           ))
           AND (p_roles IS NULL OR CARDINALITY(p_roles) = 0 OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su4
                 WHERE su4.FK_TUSUARIO = u.PK_TUSUARIO
                   AND su4.ACTIVE      = TRUE
                   AND su4.FK_TROL     IN (SELECT t.PK_TROL FROM academico_test.TROL t WHERE t.CODIGO = ANY(p_roles))
                   AND su4.FK_TROL >= 7 AND su4.FK_TROL NOT IN (15, 16)
           ))
           AND (p_work_schedules IS NULL OR CARDINALITY(p_work_schedules) = 0 OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su5
                 WHERE su5.FK_TUSUARIO    = u.PK_TUSUARIO
                   AND su5.ACTIVE         = TRUE
                   AND su5.FK_TLV_JORNADA IN (SELECT lv.PK_LISTA_VALOR FROM academico_test.TLISTA_VALOR lv
                        WHERE lv.CATEGORIA = 'JORNADA' AND lv.VALOR = ANY(p_work_schedules))
                   AND su5.FK_TROL >= 7 AND su5.FK_TROL NOT IN (15, 16)
           ))
    )
    -- sedes_agg/estados_agg/jornada: FIX V112, reaplicado sobre esta firma.
    -- Antes venian de dos CTEs (`agregados` con GROUP BY, `jornada_pick`
    -- con DISTINCT ON) evaluados sobre TODO TSEDE_USUARIO activo y unidos a
    -- `base` con LEFT JOIN normal -> el planner no podia empujar el filtro
    -- de `base` adentro y materializaba el agregado completo del sistema
    -- antes de filtrar (11.5s medidos en V112 con 126K usuarios). Ahora son
    -- subqueries correlacionadas directas contra b.PK_TUSUARIO (mismo
    -- patron que roles_agg, que ya estaba bien escrito) y un
    -- LEFT JOIN LATERAL ... LIMIT 1 para jornada — Postgres los evalua
    -- perezosamente solo para las <=v_page_size filas que sobreviven
    -- ORDER BY + LIMIT, y el LATERAL usa idx_tsede_usuario_fk_tusuario_activo
    -- (V112) para resolver el ORDER BY sin sort.
    SELECT b.PK_TFUNCIONARIO,
           b.IDENTIFICACION,
           b.PRIMER_NOMBRE,
           b.SEGUNDO_NOMBRE,
           b.PRIMER_APELLIDO,
           b.SEGUNDO_APELLIDO,
           TRIM(COALESCE(b.PRIMER_NOMBRE,'') || ' ' || COALESCE(b.SEGUNDO_NOMBRE,'')
                || ' ' || COALESCE(b.PRIMER_APELLIDO,'') || ' ' || COALESCE(b.SEGUNDO_APELLIDO,''))::VARCHAR AS nombre_completo,
           b.ESTADO::VARCHAR AS fk_estado,
           (CASE b.ESTADO
                WHEN 'A' THEN 'ACTIVE'
                WHEN 'I' THEN 'SUSPENDED'
                ELSE NULL
           END)::VARCHAR      AS estado_label,
           jp.jornada_id,
           jp.jornada_nombre,
           -- roles: lista unica {id, nombre} de TSEDE_USUARIO, UNION un tag
           -- sintetico "Rector"/"Secretaria" (PK_TROL 7/17) si el funcionario
           -- es FK_TFUNCIONARIO_RECTOR/SECRETARIA de algun EE activo — antes
           -- SOLO salia de TSEDE_USUARIO, asi que un rector/secretaria sin
           -- ningun permiso de sede asignado (caso normal para uno recien
           -- creado, antes de que se decida si se liga a todas las sedes o
           -- no) aparecia con roles=[] en el listado, aunque en la practica
           -- si tuviera ese rol sobre su EE. PK_TROL=17 "Secretaria" es un
           -- catalogo nuevo (no existia una fila de TROL para esto, a
           -- diferencia de Rector=7): TESTABLECIMIENTO.FK_TFUNCIONARIO_
           -- SECRETARIA nunca paso por TROL, es un FK directo a TFUNCIONARIO.
           COALESCE(
               (SELECT jsonb_agg(DISTINCT role_obj ORDER BY role_obj)
                  FROM (
                      SELECT jsonb_build_object('id', r.PK_TROL, 'nombre', r.NOMBRE) AS role_obj
                        FROM academico_test.TSEDE_USUARIO su_r
                        JOIN academico_test.TROL          r ON r.PK_TROL = su_r.FK_TROL
                       WHERE su_r.FK_TUSUARIO = b.PK_TUSUARIO
                         AND su_r.ACTIVE      = TRUE
                         AND su_r.FK_TROL >= 7 AND su_r.FK_TROL NOT IN (15, 16)
                         AND (v_es_super OR su_r.FK_TSEDE IN (SELECT PK_TSEDE FROM sedes_accesibles))
                      UNION
                      SELECT jsonb_build_object('id', 7, 'nombre', 'Rector')
                       WHERE EXISTS (
                           SELECT 1 FROM academico_test.TESTABLECIMIENTO e
                            WHERE e.FK_TFUNCIONARIO_RECTOR = b.PK_TFUNCIONARIO AND e.ACTIVE = TRUE
                              AND (v_es_super OR e.PK_ESTABLECIMIENTO IN (SELECT PK_ESTABLECIMIENTO FROM ee_accesibles))
                       )
                      UNION
                      SELECT jsonb_build_object('id', 17, 'nombre', 'Secretaria')
                       WHERE EXISTS (
                           SELECT 1 FROM academico_test.TESTABLECIMIENTO e
                            WHERE e.FK_TFUNCIONARIO_SECRETARIA = b.PK_TFUNCIONARIO AND e.ACTIVE = TRUE
                              AND (v_es_super OR e.PK_ESTABLECIMIENTO IN (SELECT PK_ESTABLECIMIENTO FROM ee_accesibles))
                       )
                  ) roles_union),
               '[]'::jsonb
           )                             AS roles_agg,
           COALESCE(
               (SELECT jsonb_agg(DISTINCT jsonb_build_object('id', s.PK_TSEDE, 'nombre', s.NOMBRE)
                                  ORDER BY jsonb_build_object('id', s.PK_TSEDE, 'nombre', s.NOMBRE))
                  FROM academico_test.TSEDE_USUARIO su_s
                  JOIN academico_test.TSEDE         s ON s.PK_TSEDE = su_s.FK_TSEDE
                 WHERE su_s.FK_TUSUARIO = b.PK_TUSUARIO AND su_s.ACTIVE = TRUE
                   AND su_s.FK_TROL >= 7 AND su_s.FK_TROL NOT IN (15, 16)
                   AND (v_es_super OR su_s.FK_TSEDE IN (SELECT PK_TSEDE FROM sedes_accesibles))),
               '[]'::jsonb
           )                             AS sedes_agg,
           COALESCE(
               (SELECT jsonb_agg(DISTINCT su_e.TLV_ESTADO ORDER BY su_e.TLV_ESTADO)
                  FROM academico_test.TSEDE_USUARIO su_e
                 WHERE su_e.FK_TUSUARIO = b.PK_TUSUARIO AND su_e.ACTIVE = TRUE
                   AND su_e.FK_TROL >= 7 AND su_e.FK_TROL NOT IN (15, 16)
                   AND (v_es_super OR su_e.FK_TSEDE IN (SELECT PK_TSEDE FROM sedes_accesibles))),
               '[]'::jsonb
           )                             AS estados_agg
      FROM base b
      LEFT JOIN LATERAL (
            SELECT su.FK_TLV_JORNADA AS jornada_id, tlv.NOMBRE AS jornada_nombre
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TLISTA_VALOR  tlv ON tlv.PK_LISTA_VALOR = su.FK_TLV_JORNADA
             WHERE su.FK_TUSUARIO = b.PK_TUSUARIO AND su.ACTIVE = TRUE
               AND su.FK_TROL >= 7 AND su.FK_TROL NOT IN (15, 16)
               AND (v_es_super OR su.FK_TSEDE IN (SELECT PK_TSEDE FROM sedes_accesibles))
             ORDER BY su.PREDETERMINADO DESC, su.ORDEN ASC, su.PK_TSEDE_USUARIO ASC
             LIMIT 1
      ) jp ON TRUE
     ORDER BY
        CASE WHEN p_sort_campo = 'name'      AND NOT p_sort_desc
             THEN TRIM(COALESCE(b.PRIMER_NOMBRE,'') || ' ' || COALESCE(b.SEGUNDO_NOMBRE,'')
                       || ' ' || COALESCE(b.PRIMER_APELLIDO,'') || ' ' || COALESCE(b.SEGUNDO_APELLIDO,''))
        END ASC,
        CASE WHEN p_sort_campo = 'name'      AND     p_sort_desc
             THEN TRIM(COALESCE(b.PRIMER_NOMBRE,'') || ' ' || COALESCE(b.SEGUNDO_NOMBRE,'')
                       || ' ' || COALESCE(b.PRIMER_APELLIDO,'') || ' ' || COALESCE(b.SEGUNDO_APELLIDO,''))
        END DESC,
        CASE WHEN p_sort_campo = 'document'  AND NOT p_sort_desc THEN b.IDENTIFICACION END ASC,
        CASE WHEN p_sort_campo = 'document'  AND     p_sort_desc THEN b.IDENTIFICACION END DESC,
        CASE WHEN p_sort_campo = 'status'    AND NOT p_sort_desc THEN b.ESTADO END ASC,
        CASE WHEN p_sort_campo = 'status'    AND     p_sort_desc THEN b.ESTADO END DESC,
        b.PRIMER_NOMBRE  ASC,
        b.PRIMER_APELLIDO ASC,
        b.PK_TFUNCIONARIO ASC
     LIMIT v_page_size
    OFFSET v_page_index * COALESCE(v_page_size, 0);
END;
$function$;

DROP FUNCTION IF EXISTS academico_test.fn_usu_empleados_contar(bigint, character varying, bigint[], bigint[], character varying[], bigint);
CREATE OR REPLACE FUNCTION academico_test.fn_usu_empleados_contar(p_pk_usuario_solicitante bigint, p_search character varying DEFAULT NULL::character varying, p_roles character varying[] DEFAULT NULL::character varying[], p_work_schedules character varying[] DEFAULT NULL::character varying[], p_statuses character varying[] DEFAULT NULL::character varying[], p_campus_id bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_total BIGINT;
    v_es_super BOOLEAN := academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante);
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    -- REV6 (V51 REV5, cambio de modelo -- ver header de este archivo): ya
    -- no se resuelve UN EE via fn_resolver_establecimiento_unico (fallaba
    -- con NULL si el solicitante administra 2+ EE a la vez, algo que antes
    -- era raro y ahora es comun por como TFUNCIONARIO reusa TUSUARIO). Se
    -- pasa al mismo patron "union de EE accesibles" que ya usa
    -- fn_sed_listar/_contar: rector, secretaria, o jefe de sistema (rol 8
    -- via TSEDE_USUARIO) de CUALQUIERA de sus EE, no de "el unico".
    IF NOT v_es_super AND NOT EXISTS (
        WITH ee_accesibles AS (
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT DISTINCT s.FK_TESTABLECIMIENTO
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 8 AND su.FK_TUSUARIO = p_pk_usuario_solicitante
        ),
        -- REV3 -- coordinador (rol 11) de una sede puntual.
        sedes_coordinador AS (
            SELECT su.FK_TSEDE
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 11 AND su.FK_TUSUARIO = p_pk_usuario_solicitante
        )
        SELECT 1 FROM ee_accesibles
        UNION ALL
        SELECT 1 FROM sedes_coordinador
    ) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    IF v_es_super THEN
        SELECT COUNT(DISTINCT f.PK_TFUNCIONARIO)
          INTO v_total
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TUSUARIO      u ON u.PK_TUSUARIO = f.FK_TUSUARIO
         WHERE f.ACTIVE = TRUE
           AND (NULLIF(TRIM(p_search), '') IS NULL
                OR u.PRIMER_NOMBRE || ' ' || COALESCE(u.SEGUNDO_NOMBRE,'') ILIKE '%' || p_search || '%'
                OR u.PRIMER_APELLIDO || ' ' || COALESCE(u.SEGUNDO_APELLIDO,'') ILIKE '%' || p_search || '%'
                OR (u.PRIMER_NOMBRE || ' ' || COALESCE(u.PRIMER_APELLIDO,'')) ILIKE '%' || p_search || '%'
                OR u.IDENTIFICACION ILIKE '%' || p_search || '%'
                OR EXISTS (
                    SELECT 1 FROM academico_test.TSEDE_USUARIO su2
                      JOIN academico_test.TSEDE  s ON s.PK_TSEDE = su2.FK_TSEDE
                      JOIN academico_test.TROL   r ON r.PK_TROL  = su2.FK_TROL
                     WHERE su2.FK_TUSUARIO = u.PK_TUSUARIO
                       AND su2.ACTIVE      = TRUE
                       AND (s.NOMBRE ILIKE '%' || p_search || '%'
                            OR r.NOMBRE ILIKE '%' || p_search || '%')
                  )
           )
           AND (p_statuses IS NULL OR CARDINALITY(p_statuses) = 0
                OR EXISTS (
                    SELECT 1 FROM academico_test.TSEDE_USUARIO su6
                     WHERE su6.FK_TUSUARIO = u.PK_TUSUARIO
                       AND su6.ACTIVE      = TRUE
                       AND su6.FK_TROL >= 7 AND su6.FK_TROL NOT IN (15, 16)
                       AND su6.TLV_ESTADO = ANY(
                           SELECT CASE
                                    WHEN x = 'ACTIVE'    THEN 'ACTIVO'
                                    WHEN x = 'SUSPENDED' THEN 'INACTIVO'
                                  END
                             FROM unnest(p_statuses) AS x
                            WHERE x IN ('ACTIVE','SUSPENDED')
                       )
                ))
           AND (p_campus_id IS NULL OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su3
                 WHERE su3.FK_TUSUARIO = u.PK_TUSUARIO
                   AND su3.ACTIVE      = TRUE
                   AND su3.FK_TSEDE    = p_campus_id
                   AND su3.FK_TROL >= 7 AND su3.FK_TROL NOT IN (15, 16)
           ))
           AND (p_roles IS NULL OR CARDINALITY(p_roles) = 0 OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su4
                 WHERE su4.FK_TUSUARIO = u.PK_TUSUARIO
                   AND su4.ACTIVE      = TRUE
                   AND su4.FK_TROL     IN (SELECT t.PK_TROL FROM academico_test.TROL t WHERE t.CODIGO = ANY(p_roles))
                   AND su4.FK_TROL >= 7 AND su4.FK_TROL NOT IN (15, 16)
           ))
           AND (p_work_schedules IS NULL OR CARDINALITY(p_work_schedules) = 0 OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su5
                 WHERE su5.FK_TUSUARIO    = u.PK_TUSUARIO
                   AND su5.ACTIVE         = TRUE
                   AND su5.FK_TLV_JORNADA IN (SELECT lv.PK_LISTA_VALOR FROM academico_test.TLISTA_VALOR lv
                        WHERE lv.CATEGORIA = 'JORNADA' AND lv.VALOR = ANY(p_work_schedules))
                   AND su5.FK_TROL >= 7 AND su5.FK_TROL NOT IN (15, 16)
           ));
        RETURN v_total;
    END IF;

    WITH ee_accesibles AS (
        SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT DISTINCT s.FK_TESTABLECIMIENTO
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 8 AND su.FK_TUSUARIO = p_pk_usuario_solicitante
    ),
    -- REV3 -- coordinador (rol 11) de una sede puntual.
    sedes_coordinador AS (
        SELECT su.FK_TSEDE
          FROM academico_test.TSEDE_USUARIO su
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
         WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 11 AND su.FK_TUSUARIO = p_pk_usuario_solicitante
    ),
    funcionarios_ee AS (
        SELECT e.FK_TFUNCIONARIO_RECTOR AS pk_tfuncionario
          FROM academico_test.TESTABLECIMIENTO e
         WHERE e.PK_ESTABLECIMIENTO IN (SELECT PK_ESTABLECIMIENTO FROM ee_accesibles) AND e.ACTIVE = TRUE
           AND e.FK_TFUNCIONARIO_RECTOR IS NOT NULL
        UNION
        SELECT e.FK_TFUNCIONARIO_SECRETARIA
          FROM academico_test.TESTABLECIMIENTO e
         WHERE e.PK_ESTABLECIMIENTO IN (SELECT PK_ESTABLECIMIENTO FROM ee_accesibles) AND e.ACTIVE = TRUE
           AND e.FK_TFUNCIONARIO_SECRETARIA IS NOT NULL
        UNION
        SELECT f3.PK_TFUNCIONARIO
          FROM academico_test.TFUNCIONARIO f3
          JOIN academico_test.TSEDE_USUARIO su ON su.FK_TUSUARIO = f3.FK_TUSUARIO AND su.ACTIVE = TRUE
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
         WHERE s.FK_TESTABLECIMIENTO IN (SELECT PK_ESTABLECIMIENTO FROM ee_accesibles) AND f3.ACTIVE = TRUE
           AND su.FK_TROL >= 7 AND su.FK_TROL NOT IN (15, 16)
        UNION
        SELECT f4.PK_TFUNCIONARIO
          FROM academico_test.TFUNCIONARIO f4
          JOIN academico_test.TSEDE_USUARIO su ON su.FK_TUSUARIO = f4.FK_TUSUARIO AND su.ACTIVE = TRUE
         WHERE su.FK_TSEDE IN (SELECT FK_TSEDE FROM sedes_coordinador) AND f4.ACTIVE = TRUE
           AND su.FK_TROL >= 9 AND su.FK_TROL NOT IN (15, 16)
    )
    SELECT COUNT(DISTINCT f.PK_TFUNCIONARIO)
      INTO v_total
      FROM academico_test.TFUNCIONARIO f
      JOIN funcionarios_ee fee ON fee.pk_tfuncionario = f.PK_TFUNCIONARIO
      JOIN academico_test.TUSUARIO      u ON u.PK_TUSUARIO = f.FK_TUSUARIO
     WHERE f.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_search), '') IS NULL
            OR u.PRIMER_NOMBRE || ' ' || COALESCE(u.SEGUNDO_NOMBRE,'') ILIKE '%' || p_search || '%'
            OR u.PRIMER_APELLIDO || ' ' || COALESCE(u.SEGUNDO_APELLIDO,'') ILIKE '%' || p_search || '%'
            OR (u.PRIMER_NOMBRE || ' ' || COALESCE(u.PRIMER_APELLIDO,'')) ILIKE '%' || p_search || '%'
            OR u.IDENTIFICACION ILIKE '%' || p_search || '%'
            OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su2
                  JOIN academico_test.TSEDE  s ON s.PK_TSEDE = su2.FK_TSEDE
                  JOIN academico_test.TROL   r ON r.PK_TROL  = su2.FK_TROL
                 WHERE su2.FK_TUSUARIO = u.PK_TUSUARIO
                   AND su2.ACTIVE      = TRUE
                   AND (s.NOMBRE ILIKE '%' || p_search || '%'
                        OR r.NOMBRE ILIKE '%' || p_search || '%')
              )
       )
       AND (p_statuses IS NULL OR CARDINALITY(p_statuses) = 0
            OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su6
                 WHERE su6.FK_TUSUARIO = u.PK_TUSUARIO
                   AND su6.ACTIVE      = TRUE
                   AND su6.FK_TROL >= 7 AND su6.FK_TROL NOT IN (15, 16)
                   AND su6.TLV_ESTADO = ANY(
                       SELECT CASE
                                WHEN x = 'ACTIVE'    THEN 'ACTIVO'
                                WHEN x = 'SUSPENDED' THEN 'INACTIVO'
                              END
                         FROM unnest(p_statuses) AS x
                        WHERE x IN ('ACTIVE','SUSPENDED')
                   )
            ))
       AND (p_campus_id IS NULL OR EXISTS (
            SELECT 1 FROM academico_test.TSEDE_USUARIO su3
             WHERE su3.FK_TUSUARIO = u.PK_TUSUARIO
               AND su3.ACTIVE      = TRUE
               AND su3.FK_TSEDE    = p_campus_id
               AND su3.FK_TROL >= 7 AND su3.FK_TROL NOT IN (15, 16)
       ))
       AND (p_roles IS NULL OR CARDINALITY(p_roles) = 0 OR EXISTS (
            SELECT 1 FROM academico_test.TSEDE_USUARIO su4
             WHERE su4.FK_TUSUARIO = u.PK_TUSUARIO
               AND su4.ACTIVE      = TRUE
               AND su4.FK_TROL     IN (SELECT t.PK_TROL FROM academico_test.TROL t WHERE t.CODIGO = ANY(p_roles))
               AND su4.FK_TROL >= 7 AND su4.FK_TROL NOT IN (15, 16)
       ))
       AND (p_work_schedules IS NULL OR CARDINALITY(p_work_schedules) = 0 OR EXISTS (
            SELECT 1 FROM academico_test.TSEDE_USUARIO su5
             WHERE su5.FK_TUSUARIO    = u.PK_TUSUARIO
               AND su5.ACTIVE         = TRUE
               AND su5.FK_TLV_JORNADA IN (SELECT lv.PK_LISTA_VALOR FROM academico_test.TLISTA_VALOR lv
                        WHERE lv.CATEGORIA = 'JORNADA' AND lv.VALOR = ANY(p_work_schedules))
               AND su5.FK_TROL >= 7 AND su5.FK_TROL NOT IN (15, 16)
       ));

    RETURN v_total;
END;
$function$;

DROP FUNCTION IF EXISTS academico_test.fn_sed_listar(bigint, character varying, bigint[], character varying, boolean, integer, integer);
CREATE OR REPLACE FUNCTION academico_test.fn_sed_listar(p_pk_usuario_solicitante bigint, p_search character varying DEFAULT NULL::character varying, p_zones character varying[] DEFAULT NULL::character varying[], p_sort_campo character varying DEFAULT NULL::character varying, p_sort_desc boolean DEFAULT false, p_page_index integer DEFAULT 0, p_page_size integer DEFAULT 10)
 RETURNS TABLE(pk_sede bigint, codigo character varying, nombre character varying, consecutivo character varying, fk_zona bigint, zona_nombre character varying, direccion character varying, telefono character varying)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_page_size  INT := CASE
        WHEN p_page_size IS NULL THEN NULL   -- reporte: sin limite
        ELSE LEAST(CASE WHEN p_page_size > 0 THEN p_page_size ELSE 10 END, 100)
    END;
    v_page_index INT := GREATEST(COALESCE(p_page_index, 0), 0);
BEGIN
    -- Gate UNICO (CU-86e2w4xdt): capability 'VER' sobre el menu SEDES_EDUCATIVAS
    -- + scope de lectura (el JOIN fn_usuario_sedes_lectura de abajo). El
    -- SUPER_ADMIN (categoria de rol nivel 0) no pasa por la capability;
    -- fn_usuario_sedes_lectura ya le devuelve todo (nivel 0-1). No hay
    -- ningun otro gate en esta funcion.
    IF academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante) <> 0
       AND NOT academico_test.fn_usuario_puede_en_menu(p_pk_usuario_solicitante, 'SEDES_EDUCATIVAS', 'VER') THEN
        RAISE EXCEPTION 'El usuario no tiene permiso para ver en el modulo SEDES_EDUCATIVAS'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT s.PK_TSEDE, s.CODIGO, s.NOMBRE, s.CONSECUTIVO,
           s.FK_TLV_ZONA, tlv.NOMBRE,
           s.DIRECCION, s.TELEFONO
      FROM academico_test.TSEDE s
      JOIN academico_test.fn_usuario_sedes_lectura(p_pk_usuario_solicitante) sl
        ON sl.sede_id = s.PK_TSEDE
 LEFT JOIN academico_test.TLISTA_VALOR tlv ON tlv.PK_LISTA_VALOR = s.FK_TLV_ZONA
     WHERE s.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_search), '') IS NULL
            OR s.NOMBRE ILIKE '%' || p_search || '%'
            OR s.CODIGO ILIKE '%' || p_search || '%')
       AND (p_zones IS NULL OR CARDINALITY(p_zones) = 0
            OR s.FK_TLV_ZONA IN (SELECT lv.PK_LISTA_VALOR FROM academico_test.TLISTA_VALOR lv
                        WHERE lv.CATEGORIA = 'ZONA' AND lv.VALOR = ANY(p_zones)))
     ORDER BY
        CASE WHEN p_sort_campo = 'name'   AND NOT p_sort_desc THEN s.NOMBRE END ASC,
        CASE WHEN p_sort_campo = 'name'   AND     p_sort_desc THEN s.NOMBRE END DESC,
        CASE WHEN p_sort_campo = 'dane'   AND NOT p_sort_desc THEN s.CODIGO END ASC,
        CASE WHEN p_sort_campo = 'dane'   AND     p_sort_desc THEN s.CODIGO END DESC,
        CASE WHEN p_sort_campo = 'zone'   AND NOT p_sort_desc THEN tlv.NOMBRE END ASC,
        CASE WHEN p_sort_campo = 'zone'   AND     p_sort_desc THEN tlv.NOMBRE END DESC,
        s.NOMBRE ASC,
        s.PK_TSEDE ASC
     LIMIT v_page_size
    OFFSET v_page_index * COALESCE(v_page_size, 0);
END;
$function$;

DROP FUNCTION IF EXISTS academico_test.fn_sed_contar(bigint, character varying, bigint[]);
CREATE OR REPLACE FUNCTION academico_test.fn_sed_contar(p_pk_usuario_solicitante bigint, p_search character varying DEFAULT NULL::character varying, p_zones character varying[] DEFAULT NULL::character varying[])
 RETURNS bigint
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_total BIGINT;
BEGIN
    -- Gate UNICO (CU-86e2w4xdt): capability 'VER' sobre el menu SEDES_EDUCATIVAS
    -- + scope de lectura (el JOIN fn_usuario_sedes_lectura de abajo). El
    -- SUPER_ADMIN (categoria de rol nivel 0) no pasa por la capability;
    -- fn_usuario_sedes_lectura ya le devuelve todo (nivel 0-1). No hay
    -- ningun otro gate en esta funcion.
    IF academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante) <> 0
       AND NOT academico_test.fn_usuario_puede_en_menu(p_pk_usuario_solicitante, 'SEDES_EDUCATIVAS', 'VER') THEN
        RAISE EXCEPTION 'El usuario no tiene permiso para ver en el modulo SEDES_EDUCATIVAS'
            USING ERRCODE = '42501';
    END IF;

    SELECT COUNT(*)
      INTO v_total
      FROM academico_test.TSEDE s
      JOIN academico_test.fn_usuario_sedes_lectura(p_pk_usuario_solicitante) sl
        ON sl.sede_id = s.PK_TSEDE
 LEFT JOIN academico_test.TLISTA_VALOR tlv ON tlv.PK_LISTA_VALOR = s.FK_TLV_ZONA
     WHERE s.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_search), '') IS NULL
            OR s.NOMBRE ILIKE '%' || p_search || '%'
            OR s.CODIGO ILIKE '%' || p_search || '%')
       AND (p_zones IS NULL OR CARDINALITY(p_zones) = 0
            OR s.FK_TLV_ZONA IN (SELECT lv.PK_LISTA_VALOR FROM academico_test.TLISTA_VALOR lv
                        WHERE lv.CATEGORIA = 'ZONA' AND lv.VALOR = ANY(p_zones)));

    RETURN v_total;
END;
$function$;

DROP FUNCTION IF EXISTS academico_test.fn_est_listar_paginado(bigint, character varying, bigint[], bigint[], bigint[], character varying, boolean, integer, integer);
CREATE OR REPLACE FUNCTION academico_test.fn_est_listar_paginado(p_pk_usuario_solicitante bigint, p_search character varying DEFAULT NULL::character varying, p_departamentos character varying[] DEFAULT NULL::character varying[], p_municipios character varying[] DEFAULT NULL::character varying[], p_estados character varying[] DEFAULT NULL::character varying[], p_sort_campo character varying DEFAULT NULL::character varying, p_sort_desc boolean DEFAULT false, p_page_index integer DEFAULT 0, p_page_size integer DEFAULT 10)
 RETURNS TABLE(rows jsonb, total_count bigint, page_count bigint, page_index integer, page_size integer)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_rows_json   JSONB   := '[]'::JSONB;
    v_total       BIGINT;
    v_page_size   INT     := LEAST(CASE WHEN p_page_size > 0 THEN p_page_size ELSE 10 END, 100);
    v_page_index  INT     := GREATEST(COALESCE(p_page_index, 0), 0);
    v_page_count  BIGINT;
    v_one_row     JSONB;
BEGIN
    -- 1) Total de filas que cumplen los filtros (con gate aplicado).
    --    fn_est_contar ya aplica el gate de autorizacion (super-admin OR
    --    rector de >=1 EE activo). Si no cumple, lanza 42501.
    v_total := academico_test.fn_est_contar(
        p_pk_usuario_solicitante,
        p_search,
        p_departamentos,
        p_municipios,
        p_estados
    );

    -- 2) Calculo de page_count (0 si no hay resultados).
    v_page_count := CASE WHEN v_total = 0 THEN 0 ELSE CEIL(v_total::NUMERIC / v_page_size)::BIGINT END;

    -- 3) Captura de la pagina via FOR ... IN SELECT ... LOOP sobre
    --    fn_est_listar. fn_est_listar aplica los mismos filtros + gate y
    --    ya respeta p_page_index/p_page_size.
    FOR
        v_one_row IN
        SELECT to_jsonb(t)
          FROM academico_test.fn_est_listar(
              p_pk_usuario_solicitante,
              p_search,
              p_departamentos,
              p_municipios,
              p_estados,
              p_sort_campo,
              p_sort_desc,
              v_page_index,
              v_page_size
          ) AS t(
              pk_establecimiento, codigo, nombre, nit,
              fk_departamento, departamento_nombre,
              fk_municipio, municipio_nombre,
              fk_estado, estado_nombre
          )
    LOOP
        v_rows_json := v_rows_json || jsonb_build_array(v_one_row);
    END LOOP;

    -- 4) Resultado final en un solo record.
    RETURN QUERY
    SELECT v_rows_json, v_total, v_page_count, v_page_index, v_page_size;
END;
$function$;

DROP FUNCTION IF EXISTS academico_test.fn_sed_listar_paginado(bigint, character varying, bigint[], character varying, boolean, integer, integer);
CREATE OR REPLACE FUNCTION academico_test.fn_sed_listar_paginado(p_pk_usuario_solicitante bigint, p_search character varying DEFAULT NULL::character varying, p_zones character varying[] DEFAULT NULL::character varying[], p_sort_campo character varying DEFAULT NULL::character varying, p_sort_desc boolean DEFAULT false, p_page_index integer DEFAULT 0, p_page_size integer DEFAULT 10)
 RETURNS TABLE(rows jsonb, total_count bigint, page_count bigint, page_index integer, page_size integer)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_rows_json   JSONB   := '[]'::JSONB;
    v_total       BIGINT;
    v_page_size   INT     := LEAST(CASE WHEN p_page_size > 0 THEN p_page_size ELSE 10 END, 100);
    v_page_index  INT     := GREATEST(COALESCE(p_page_index, 0), 0);
    v_page_count  BIGINT;
    v_one_row     JSONB;
BEGIN
    -- 1) Total de filas que cumplen los filtros (con gate aplicado).
    --    fn_sed_contar ya aplica el gate de autorizacion (super-admin OR
    --    rector/secretaria/jefe de sistema de >=1 EE activo). Si no
    --    cumple, lanza 42501.
    v_total := academico_test.fn_sed_contar(
        p_pk_usuario_solicitante,
        p_search,
        p_zones
    );

    -- 2) Calculo de page_count (0 si no hay resultados).
    v_page_count := CASE WHEN v_total = 0 THEN 0 ELSE CEIL(v_total::NUMERIC / v_page_size)::BIGINT END;

    -- 3) Captura de la pagina via FOR ... IN SELECT ... LOOP sobre
    --    fn_sed_listar. fn_sed_listar aplica los mismos filtros + gate y
    --    ya respeta p_page_index/p_page_size.
    FOR
        v_one_row IN
        SELECT to_jsonb(t)
          FROM academico_test.fn_sed_listar(
              p_pk_usuario_solicitante,
              p_search,
              p_zones,
              p_sort_campo,
              p_sort_desc,
              v_page_index,
              v_page_size
          ) AS t(
              pk_sede, codigo, nombre, consecutivo,
              fk_zona, zona_nombre,
              direccion, telefono
          )
    LOOP
        v_rows_json := v_rows_json || jsonb_build_array(v_one_row);
    END LOOP;

    -- 4) Resultado final en un solo record.
    RETURN QUERY
    SELECT v_rows_json, v_total, v_page_count, v_page_index, v_page_size;
END;
$function$;

DROP FUNCTION IF EXISTS academico_test.fn_usu_empleados_listar_paginado(bigint, character varying, bigint[], bigint[], character varying[], bigint, character varying, boolean, integer, integer);
CREATE OR REPLACE FUNCTION academico_test.fn_usu_empleados_listar_paginado(p_pk_usuario_solicitante bigint, p_search character varying DEFAULT NULL::character varying, p_roles character varying[] DEFAULT NULL::character varying[], p_work_schedules character varying[] DEFAULT NULL::character varying[], p_statuses character varying[] DEFAULT NULL::character varying[], p_campus_id bigint DEFAULT NULL::bigint, p_sort_campo character varying DEFAULT NULL::character varying, p_sort_desc boolean DEFAULT false, p_page_index integer DEFAULT 0, p_page_size integer DEFAULT 10)
 RETURNS TABLE(rows jsonb, total_count bigint, page_count bigint, page_index integer, page_size integer)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_rows_json   JSONB   := '[]'::JSONB;
    v_total       BIGINT;
    v_page_size   INT     := LEAST(CASE WHEN p_page_size > 0 THEN p_page_size ELSE 10 END, 100);
    v_page_index  INT     := GREATEST(COALESCE(p_page_index, 0), 0);
    v_page_count  BIGINT;
    v_one_row     JSONB;
BEGIN
    v_total := academico_test.fn_usu_empleados_contar(
        p_pk_usuario_solicitante, p_search, p_roles, p_work_schedules, p_statuses, p_campus_id
    );

    v_page_count := CASE WHEN v_total = 0 THEN 0 ELSE CEIL(v_total::NUMERIC / v_page_size)::BIGINT END;

    FOR
        v_one_row IN
        SELECT to_jsonb(t)
          FROM academico_test.fn_usu_empleados_listar(
              p_pk_usuario_solicitante, p_search, p_roles, p_work_schedules, p_statuses, p_campus_id,
              p_sort_campo, p_sort_desc, v_page_index, v_page_size
          ) AS t(
              pk_empleado, numero_documento, primer_nombre, segundo_nombre,
              primer_apellido, segundo_apellido, nombre_completo,
              fk_estado, estado_label, jornada_id, jornada_nombre,
              roles, sedes, estados_permisos
          )
    LOOP
        v_rows_json := v_rows_json || jsonb_build_array(v_one_row);
    END LOOP;

    RETURN QUERY
    SELECT v_rows_json, v_total, v_page_count, v_page_index, v_page_size;
END;
$function$;

