-- ===========================================================================
-- V220 — Sistema de asistencias (G-Academ Back Asistencias, CU-86e32gvpp).
--
-- USA TAL CUAL la tabla academico_test.TASISTENCIA definida en V22
-- (un registro por estudiante-asignatura-sesion):
--   FECHA, FK_TLV_TIPO_ASISTENCIA, FK_TASIGNATURA, FK_TPERIODO_EVALUACION,
--   FK_TMATRICULA, OBSERVACION, FK_SOPORTE_ARCHIVO, BLOQUE + auditoria.
-- NO se agregan columnas: lo que las pantallas necesitan y no esta en la
-- tabla se deriva de las tablas relacionadas.
--
-- ---------------------------------------------------------------------------
-- MODELO DE UNA "SESION"
-- ---------------------------------------------------------------------------
--   Sesion = (FK_TGRUPO, FK_TASIGNATURA, FECHA, BLOQUE).
--   El grupo se deriva de TMATRICULA.FK_TGRUPO; la FRANJA HORARIA y el
--   catalogo de sesiones PROGRAMADAS salen de THORARIO, que es quien define
--   los bloques del periodo academico:
--       THORARIO(FK_TGRUPO, FK_TASIGNATURA, NUMERO_BLOQUE,
--                FK_TLV_DIA_SEMANA, HORA_INICIO, HORA_FIN)
--
--   *** MAPEO DIA_SEMANA (verificado en 172.233.184.248) ***
--       TLISTA_VALOR CATEGORIA='DIA_SEMANA', VALOR 1..7 =
--       Domingo..Sabado  =>  VALOR = EXTRACT(DOW FROM fecha) + 1
--   Ese mapeo es lo que permite (a) unir THORARIO a una FECHA concreta sin
--   duplicar, y (b) proyectar el horario sobre el mes para saber que
--   sesiones estan PENDIENTES o RETRASADAS.
--   La comparacion va como TEXTO -- dia.VALOR = (EXTRACT(DOW..)+1)::TEXT --
--   y NO casteando dia.VALOR::INT: el planner puede aplicar el cast antes
--   del filtro CATEGORIA='DIA_SEMANA' y reventar contra un VALOR no numerico
--   de otra categoria (p.ej. CATEGORIA='PLAN', VALOR='PREESCOLAR').
--
--   *** POR QUE EL JOIN A THORARIO ES LATERAL Y NO UN LEFT JOIN PLANO ***
--   (FK_TGRUPO, FK_TASIGNATURA, NUMERO_BLOQUE) NO es unico en THORARIO: el
--   mismo bloque se repite una vez por dia de semana. En el servidor de test
--   hay 9259 filas activas para 8306 combos distintos -> 953 combos
--   duplicados. Un LEFT JOIN por esas 3 columnas MULTIPLICA las filas de
--   TASISTENCIA e infla total_count, ausentes, total_estudiantes y todas las
--   sumas de horas. Se une por los 4 campos (incluido el dia de semana
--   derivado de la FECHA) dentro de un LEFT JOIN LATERAL ... LIMIT 1, que
--   ademas es robusto si quedara algun duplicado residual.
--
-- ---------------------------------------------------------------------------
-- AUTORIZACION — helpers de capability + scope (rama CU-86e2w4xdt / PR #100)
-- ---------------------------------------------------------------------------
--   Se reusan los helpers de V29 a traves de dos envoltorios propios, con el
--   MISMO patron que la seccion Matricula (V40 fn_matricula_gate_escritura /
--   fn_matricula_puede_ver):
--       fn_asistencia_gate_escritura(usuario, grupo, accion)  -> lanza 42501
--       fn_asistencia_puede_ver(usuario, grupo)               -> BOOLEAN
--   sobre el menu 'ASISTENCIA' que se siembra mas abajo. Modelo de 3 capas:
--   CAPABILITY (TROL_MENU concede / TUSUARIO_ROL_PERMISO recorta) + SCOPE por
--   categoria de rol (nivel 1 territorial = todos los EE; nivel 2 =
--   fn_usuario_ee_accesibles; nivel 3 = par (sede, jornada) del grupo) +
--   BYPASS del SUPER_ADMIN. Nunca se hardcodean pk_trol.
--
--   *** DEPENDENCIA CROSS-BRANCH (deliberada) ***
--   Esta rama sale de `dev` y contiene UNICAMENTE V220 + V221; no arrastra
--   commits de otras ramas. Los helpers que consume viven en ramas aun sin
--   mergear, y se toman como REFERENCIA de contrato, no como codigo propio:
--     * V29  (feature/CU-86e2w4xdt-Permisos-segun-Rol, PR #100) —
--       fn_assert_permiso_seccion, fn_usuario_puede_en_menu,
--       fn_usuario_categoria_rol_nivel, fn_usuario_ee_accesibles,
--       fn_usuario_sedes_jornadas_accesibles.
--     * V40  (misma rama) — fn_grupo_establecimiento, fn_grupo_periodo,
--       fn_grupo_jornada, fn_periodo_sede, y los gates de Matricula
--       (fn_matricula_gate_escritura / fn_matricula_puede_ver) que aqui se
--       replican en su version de Asistencia.
--     * V113 (misma rama) — menus logicos por CODIGO, incluido el grupo
--       padre 'COBERTURA_EDUCATIVA' del que cuelga 'ASISTENCIA'.
--     * V185 (misma rama) — fn_usuario_permisos_menu (capability efectiva).
--
--   Como TODOS los envoltorios de abajo son LANGUAGE plpgsql, PostgreSQL no
--   valida esos nombres al crear la funcion: los resuelve en tiempo de
--   EJECUCION. Por eso V220 APLICA sin error sobre `dev` tal cual, y los
--   endpoints quedan operativos en cuanto se mergee PR #100. Mismo criterio
--   que ya usa la rama del Planeador (deps cross-branch V29/V73/V212-214).
--
--   Lo unico que NO es inerte sin PR #100 es el seed del menu del punto 2:
--   si 'COBERTURA_EDUCATIVA' todavia no existe, el INSERT inserta 0 filas
--   (esta condicionado por el JOIN al padre) y hay que reaplicar V220 —o
--   sembrar el menu a mano— tras el merge. Es deliberado: preferible un seed
--   que no hace nada a uno que cuelga el menu de un padre inventado.
--
--   NO se deja fallback al gate viejo (fn_puede_afectar_usuarios): un gate de
--   permisos que se degrada en silencio a uno mas debil es peor que uno que
--   falla cerrado.
--
-- ---------------------------------------------------------------------------
-- ESTADOS
-- ---------------------------------------------------------------------------
--   TLISTA_VALOR CATEGORIA='TIPO_ASISTENCIA' (ya sembrada en el servidor):
--     valor 1 -> Asistio            valor 5 -> Llego tarde
--     valor 2 -> NO Asistio         valor 6 -> Llego tarde trajo justificacion
--     valor 3 -> NO Asistio trajo justificacion
--   Los pk_lista_valor NO son estables entre ambientes: se resuelve SIEMPRE
--   por (CATEGORIA, VALOR). "Presente" = 1,5,6; "ausente" = 2,3; "tarde" = 5,6.
--
--   OJO: el estado de la CELDA del calendario NO es el estado del alumno.
--   Segun el mock, la celda informa si la asistencia se TOMO o no:
--     REGISTRADA (verde) : hay registro          -> "Asistencia pasada"
--     RETRASADA  (rojo)  : fecha <= hoy, sin registro -> "No registrada en la fecha"
--     PENDIENTE  (azul)  : fecha  > hoy, sin registro -> "Aun no corresponde tomarla"
--
-- ---------------------------------------------------------------------------
-- OBJETOS QUE CREA
-- ---------------------------------------------------------------------------
--   1. Indices  UQ_TASISTENCIA_SESION (unico parcial) + IDX_TASISTENCIA_9/10
--      y IDX_THORARIO_LOOKUP.
--   2. Menu 'ASISTENCIA' (TMENU) + concesion al SUPER_ADMINISTRADOR.
--   3. fn_asistencia_gate_escritura / fn_asistencia_puede_ver  (autorizacion)
--   4. fn_asistencia_periodo_eval / fn_asistencia_tipo_pk      (resolucion)
--   5. VISTA v_asistencia_detalle  (cadena de joins + clasificacion, un solo
--      sitio; la consumen las 3 funciones de lectura)
--   6. fn_asistencia_sesiones_programadas (proyeccion del horario sobre
--      fechas reales, compartida por calendario y resumen)
--   7. fn_asistencia_registrar_bulk, fn_asistencia_editar,
--      fn_asistencia_estudiantes_sesion (padron para "Asistencia manual"),
--      fn_asistencia_listar_seguimiento, fn_asistencia_calendario,
--      fn_asistencia_resumen_horas
--      El calendario y el resumen aceptan p_fk_tfuncionario: cuando llega,
--      los puntos / las horas se acotan a las asignaturas ASIGNADAS a ese
--      docente en TDOCENTE_ASIGNATURA (vista "mis clases").
--
-- Depende de:
--   * EN ESTA RAMA (dev): V22 — TASISTENCIA, TMATRICULA, TGRUPO, TGRADO,
--     TPERIODO_ACADEMICO, TPERIODO_EVALUACION, TSEDE, TASIGNATURA, THORARIO,
--     TDOCENTE_ASIGNATURA (asignacion academica docente<->grupo<->asignatura,
--     para el filtro "mis clases"), TARCHIVO, TLISTA_VALOR, TUSUARIO,
--     TESTUDIANTE, TFUNCIONARIO, TMENU, TROL, TROL_MENU.
--   * EN RAMAS SIN MERGEAR (resueltas en ejecucion, ver arriba): V29, V40,
--     V113, V185 de PR #100.
-- Numeracion: V220 es el primer hueco libre por encima de V219; revisadas
-- todas las ramas de origin.
-- ===========================================================================

SET search_path TO academico_test, public;

-- ===========================================================================
-- 0. LIMPIEZA DE FIRMAS PREVIAS
--    CREATE OR REPLACE no puede cambiar el tipo de retorno ni la lista de
--    parametros: si la firma cambia deja una SOBRECARGA nueva conviviendo con
--    la vieja (y si solo cambia el RETURNS TABLE, falla con 42P13). Se sueltan
--    aqui las firmas de versiones anteriores de este mismo archivo para que
--    reaplicarlo sea idempotente y no queden overloads ambiguos.
-- ===========================================================================
DROP FUNCTION IF EXISTS academico_test.fn_asistencia_registrar_bulk(
    BIGINT, BIGINT, BIGINT, DATE, TIMESTAMP, TIMESTAMP, BIGINT, BIGINT, JSONB, NUMERIC);
DROP FUNCTION IF EXISTS academico_test.fn_asistencia_registrar_bulk(
    BIGINT, BIGINT, BIGINT, DATE, TIMESTAMP, TIMESTAMP, NUMERIC, BIGINT, JSONB, NUMERIC);
DROP FUNCTION IF EXISTS academico_test.fn_asistencia_listar_seguimiento(
    DATE, DATE, BIGINT, BIGINT, NUMERIC, TEXT, INT, INT, TEXT, TEXT);
-- fn_asistencia_calendario / fn_asistencia_resumen_horas ganaron el parametro
-- p_fk_tfuncionario (filtro "mis asignaturas asignadas"); y resumen_horas
-- ademas dos columnas de horas programadas -> cambia la firma / el RETURNS.
DROP FUNCTION IF EXISTS academico_test.fn_asistencia_calendario(
    BIGINT, BIGINT, INTEGER, INTEGER, BIGINT, BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_asistencia_calendario(
    BIGINT, BIGINT, INTEGER, INTEGER, BIGINT, BIGINT, DATE);
DROP FUNCTION IF EXISTS academico_test.fn_asistencia_resumen_horas(
    BIGINT, BIGINT, DATE, BIGINT, BIGINT);

-- ===========================================================================
-- 1. INDICES
-- ===========================================================================

-- Unicidad operativa: un registro ACTIVO por estudiante / asignatura /
-- sesion. Indice unico PARCIAL (memoria "v65-unique-constraints-partial-
-- active") y target de ON CONFLICT del upsert masivo.
CREATE UNIQUE INDEX IF NOT EXISTS UQ_TASISTENCIA_SESION
  ON TASISTENCIA (FK_TMATRICULA, FK_TASIGNATURA, FECHA, COALESCE(BLOQUE, 0))
  WHERE ACTIVE = true ;

-- Acceso del listado / calendario: filtran por rango de FECHA + asignatura y
-- solo miran filas activas. V22 solo trae IX_TASISTENCIA_2 (FECHA) suelto.
CREATE INDEX IF NOT EXISTS IDX_TASISTENCIA_9
  ON TASISTENCIA (FECHA, FK_TASIGNATURA) WHERE ACTIVE = true ;

-- El listado agrupa/filtra por matricula dentro de un rango de fechas.
CREATE INDEX IF NOT EXISTS IDX_TASISTENCIA_10
  ON TASISTENCIA (FK_TMATRICULA, FECHA) WHERE ACTIVE = true ;

-- Lookup del LATERAL a THORARIO (grupo, asignatura, bloque, dia de semana).
CREATE INDEX IF NOT EXISTS IDX_THORARIO_LOOKUP
  ON THORARIO (FK_TGRUPO, FK_TASIGNATURA, NUMERO_BLOQUE, FK_TLV_DIA_SEMANA)
  WHERE ACTIVE = true ;


-- ===========================================================================
-- 2. MENU 'ASISTENCIA' (capability)
--    Mismo patron que V113: alta idempotente por CODIGO, colgado del grupo
--    'COBERTURA_EDUCATIVA', y concesion al SUPER_ADMINISTRADOR resuelta por
--    TROL.CODIGO (nunca por pk literal: varia por ambiente).
--    El resto de roles los administra el super admin desde la pantalla de
--    "Configuracion de roles y menus" (PUT /roles/:ID/menus).
-- ===========================================================================
INSERT INTO academico_test.tmenu (codigo, nombre, url, visible, estado, fk_tmenu, orden, created_by)
SELECT 'ASISTENCIA', 'Asistencia', '/cobertura-educativa/asistencia', 'S', 'A',
       padre.pk_tmenu, 4::NUMERIC, 'V220_seed'
  FROM academico_test.tmenu padre
 WHERE padre.codigo = 'COBERTURA_EDUCATIVA'
   AND padre.active = TRUE
   AND padre.fk_tmenu IS NULL
   AND NOT EXISTS (
       SELECT 1 FROM academico_test.tmenu m
        WHERE m.codigo = 'ASISTENCIA' AND m.active = TRUE
   );

INSERT INTO academico_test.trol_menu (fk_trol, fk_tmenu, created_by)
SELECT r.pk_trol, m.pk_tmenu, 'V220_seed'
  FROM academico_test.trol r
  JOIN academico_test.tmenu m ON m.codigo = 'ASISTENCIA' AND m.active = TRUE
 WHERE r.codigo = 'SUPER_ADMINISTRADOR'
   AND r.active = TRUE
   AND NOT EXISTS (
       SELECT 1 FROM academico_test.trol_menu rm
        WHERE rm.fk_trol = r.pk_trol AND rm.fk_tmenu = m.pk_tmenu
   );


-- ===========================================================================
-- 3. AUTORIZACION — envoltorios sobre los helpers de V29/V40
-- ===========================================================================

-- Gate de ESCRITURA. Wrapper de una linea sobre fn_assert_permiso_seccion,
-- calcado de fn_matricula_gate_escritura (V40): el scope se resuelve por el
-- grupo (TGRUPO -> TGRADO -> TPERIODO_ACADEMICO -> TSEDE + jornada).
CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_gate_escritura(
    p_pk_usuario  BIGINT,
    p_fk_tgrupo   BIGINT,
    p_accion      VARCHAR DEFAULT 'EDITAR'
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario, 'ASISTENCIA', p_accion,
        academico_test.fn_grupo_establecimiento(p_fk_tgrupo),
        academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(p_fk_tgrupo)),
        academico_test.fn_grupo_jornada(p_fk_tgrupo));
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_gate_escritura(BIGINT, BIGINT, VARCHAR)
    IS 'Gate de ESCRITURA de la seccion Asistencia. Wrapper sobre fn_assert_permiso_seccion (V29) con el menu ''ASISTENCIA''; identico en forma a fn_matricula_gate_escritura (V40). CAPABILITY dinamica (TROL_MENU concede / TUSUARIO_ROL_PERMISO recorta) + SCOPE por categoria de rol resuelto por el grupo + BYPASS del SUPER_ADMIN. Lanza 42501 (-> HTTP 403). Depende de PR #100 (cross-branch); resuelve nombres en ejecucion por ser plpgsql.';

-- Version BOOLEAN para el WHERE de los LISTADOS: no lanza, asi que no abre
-- una subtransaccion por fila. Calcada de fn_matricula_puede_ver (V40).
CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_puede_ver(
    p_pk_usuario  BIGINT,
    p_fk_tgrupo   BIGINT
)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_nivel INT;
BEGIN
    -- Llamada interna sin scoping (p. ej. desde otra funcion ya autorizada).
    IF p_pk_usuario IS NULL THEN
        RETURN TRUE;
    END IF;

    v_nivel := COALESCE(academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario), 99);

    IF v_nivel = 0 THEN                       -- SUPER_ADMIN: bypass
        RETURN TRUE;
    END IF;

    IF NOT academico_test.fn_usuario_puede_en_menu(p_pk_usuario, 'ASISTENCIA', 'VER') THEN
        RETURN FALSE;
    END IF;

    IF v_nivel = 1 THEN                       -- territorial: todos los EE
        RETURN TRUE;
    ELSIF v_nivel = 2 THEN                    -- establecimiento
        RETURN academico_test.fn_grupo_establecimiento(p_fk_tgrupo) IN (
                   SELECT establecimiento_id
                     FROM academico_test.fn_usuario_ee_accesibles(p_pk_usuario));
    ELSIF v_nivel = 3 THEN                    -- sede + jornada (par exacto)
        RETURN (
                   academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(p_fk_tgrupo)),
                   academico_test.fn_grupo_jornada(p_fk_tgrupo)
               ) IN (
                   SELECT sede_id, jornada_id
                     FROM academico_test.fn_usuario_sedes_jornadas_accesibles(p_pk_usuario));
    END IF;

    RETURN FALSE;                             -- nivel 4 / sin categoria: fail-closed
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_puede_ver(BIGINT, BIGINT)
    IS 'Version BOOLEAN de fn_asistencia_gate_escritura para el WHERE de los listados de asistencia: capability ''VER'' sobre el menu ''ASISTENCIA'' + scope por categoria de rol, resuelto por el grupo. p_pk_usuario NULL o SUPER_ADMIN => TRUE; nivel 4 o sin categoria => FALSE. No lanza (evita una subtransaccion por fila).';


-- ===========================================================================
-- 4. RESOLUCION (helpers de dominio, reutilizados por las 5 funciones)
-- ===========================================================================

-- Periodo de evaluacion de una sesion (FK_TPERIODO_EVALUACION es NOT NULL en
-- TASISTENCIA pero NO se le pide al cliente).
CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_periodo_eval(
    p_fk_tgrupo BIGINT,
    p_fecha     DATE
)
RETURNS BIGINT
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT pe.PK_TPERIODO_EVALUACION
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_EVALUACION pe
        ON pe.FK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
       AND pe.ACTIVE = TRUE
       AND p_fecha BETWEEN pe.FECHA_INICIO AND pe.FECHA_FIN
     WHERE gr.PK_TGRUPO = p_fk_tgrupo AND gr.ACTIVE = TRUE
     ORDER BY pe.FECHA_INICIO DESC
     LIMIT 1;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_periodo_eval(BIGINT, DATE)
    IS 'PK_TPERIODO_EVALUACION de una sesion: periodo de evaluacion activo del periodo academico del grado del grupo cuyo rango [FECHA_INICIO,FECHA_FIN] contiene la fecha. NULL si no hay.';

-- PK del TLISTA_VALOR de un TIPO_ASISTENCIA a partir de su VALOR numerico.
-- Centraliza la resolucion que antes estaba repetida en 3 sitios.
CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_tipo_pk(
    p_valor NUMERIC
)
RETURNS BIGINT
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT lv.PK_LISTA_VALOR
      FROM academico_test.TLISTA_VALOR lv
     WHERE lv.CATEGORIA = 'TIPO_ASISTENCIA'
       AND lv.VALOR = p_valor::TEXT
       AND lv.ACTIVE = TRUE
     LIMIT 1;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_tipo_pk(NUMERIC)
    IS 'PK_LISTA_VALOR del TIPO_ASISTENCIA con ese VALOR (1,2,3,5,6). Resuelve por (CATEGORIA, VALOR) porque los pk no son estables entre ambientes. NULL si el valor no existe o esta inactivo.';


-- ===========================================================================
-- 5. VISTA v_asistencia_detalle
--    Un unico sitio con: la cadena de joins (asistencia -> matricula ->
--    estudiante/usuario, grupo -> grado -> periodo academico -> sede), la
--    franja horaria via LATERAL a THORARIO por dia de semana, y la
--    clasificacion del estado. Las 3 funciones de lectura la consumen, en vez
--    de repetir 30 lineas de joins y los literales IN (1)/(2,3)/(5,6).
-- ===========================================================================
CREATE OR REPLACE VIEW academico_test.v_asistencia_detalle AS
SELECT
    a.PK_TASISTENCIA                          AS pk_tasistencia,
    a.FK_TMATRICULA                           AS fk_tmatricula,
    m.FK_TGRUPO                               AS fk_tgrupo,
    gr.NOMBRE                                 AS grupo,
    gr.FK_TLV_JORNADA                         AS fk_tlv_jornada,
    g.PK_TGRADO                               AS fk_tgrado,
    pa.PK_TPERIODO_ACADEMICO                  AS fk_tperiodo_academico,
    pa.FK_TSEDE                               AS fk_tsede,
    a.FK_TASIGNATURA                          AS fk_tasignatura,
    asig.NOMBRE                               AS asignatura,
    a.FK_TPERIODO_EVALUACION                  AS fk_tperiodo_evaluacion,
    a.FECHA                                   AS fecha,
    a.BLOQUE                                  AS bloque,
    h.HORA_INICIO                             AS hora_inicio,
    h.HORA_FIN                                AS hora_fin,
    -- Duracion de la sesion en horas (0 si el bloque no esta en THORARIO).
    ROUND(COALESCE(EXTRACT(EPOCH FROM (h.HORA_FIN - h.HORA_INICIO)) / 3600.0, 0)::NUMERIC, 2)
                                              AS horas,
    a.FK_TLV_TIPO_ASISTENCIA                  AS fk_tlv_tipo_asistencia,
    -- El estado se compara SIEMPRE como TEXTO contra el dominio fijo de
    -- TIPO_ASISTENCIA ('1','2','3','5','6'). No se hace lv.VALOR::INT: el
    -- planner puede evaluar ese cast sobre filas de TLISTA_VALOR de otra
    -- categoria (p.ej. CATEGORIA='PLAN', VALOR='PREESCOLAR') antes de que el
    -- join por PK las descarte, y revienta con 22P02. El CASE cubre el
    -- dominio real; cualquier otro valor -> NULL (fila ignorada por las
    -- 4 banderas, que quedan FALSE).
    CASE lv.VALOR WHEN '1' THEN 1 WHEN '2' THEN 2 WHEN '3' THEN 3
                  WHEN '5' THEN 5 WHEN '6' THEN 6 END  AS tipo_valor,
    lv.NOMBRE                                 AS tipo_nombre,
    -- Clasificacion en un solo sitio (evita repetir los literales).
    (lv.VALOR IN ('1','5','6'))               AS es_presente,
    (lv.VALOR IN ('5','6'))                   AS es_tarde,
    (lv.VALOR IN ('2','3'))                   AS es_ausente,
    (lv.VALOR IN ('3','6'))                   AS es_justificado,
    a.OBSERVACION                             AS observacion,
    a.FK_SOPORTE_ARCHIVO                      AS fk_soporte_archivo,
    (a.FK_SOPORTE_ARCHIVO IS NOT NULL)        AS tiene_soporte,
    arch.NOMBRE                               AS soporte_nombre,
    es.PK_TESTUDIANTE                         AS fk_testudiante,
    u.IDENTIFICACION                          AS documento,
    NULLIF(TRIM(regexp_replace(
        concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                       u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO),
        '\s+', ' ', 'g')), '')                AS estudiante,
    a.CREATED_BY                              AS registrado_por,
    a.CREATED_AT                              AS registrado_at
  FROM academico_test.TASISTENCIA a
  JOIN academico_test.TMATRICULA  m    ON m.PK_TMATRICULA = a.FK_TMATRICULA
  JOIN academico_test.TESTUDIANTE es   ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
  JOIN academico_test.TUSUARIO    u    ON u.PK_TUSUARIO = es.FK_TUSUARIO
  JOIN academico_test.TGRUPO      gr   ON gr.PK_TGRUPO = m.FK_TGRUPO
  JOIN academico_test.TGRADO      g    ON g.PK_TGRADO = gr.FK_TGRADO
  JOIN academico_test.TPERIODO_ACADEMICO pa
                                       ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
  JOIN academico_test.TASIGNATURA asig ON asig.PK_TASIGNATURA = a.FK_TASIGNATURA
  JOIN academico_test.TLISTA_VALOR lv  ON lv.PK_LISTA_VALOR = a.FK_TLV_TIPO_ASISTENCIA
  LEFT JOIN academico_test.TARCHIVO arch ON arch.PK_TARCHIVO = a.FK_SOPORTE_ARCHIVO
  -- Franja horaria: LATERAL + LIMIT 1 y match por DIA DE SEMANA de la FECHA.
  -- Ver "POR QUE EL JOIN A THORARIO ES LATERAL" en la cabecera: sin el dia,
  -- (grupo, asignatura, bloque) devuelve varias filas y duplica la asistencia.
  LEFT JOIN LATERAL (
      SELECT th.HORA_INICIO, th.HORA_FIN
        FROM academico_test.THORARIO th
        JOIN academico_test.TLISTA_VALOR dia
          ON dia.PK_LISTA_VALOR = th.FK_TLV_DIA_SEMANA
         AND dia.CATEGORIA = 'DIA_SEMANA'
         AND dia.VALOR = (EXTRACT(DOW FROM a.FECHA)::INT + 1)::TEXT
       WHERE th.FK_TGRUPO      = m.FK_TGRUPO
         AND th.FK_TASIGNATURA = a.FK_TASIGNATURA
         AND th.NUMERO_BLOQUE  = a.BLOQUE
         AND th.ACTIVE = TRUE
       LIMIT 1
  ) h ON TRUE
 WHERE a.ACTIVE = TRUE;

COMMENT ON VIEW academico_test.v_asistencia_detalle
    IS 'Detalle plano de TASISTENCIA (solo ACTIVE) con la cadena de joins ya resuelta: estudiante (nombre/documento), grupo, grado, periodo academico, sede, jornada, asignatura, soporte, y la franja horaria + duracion tomadas de THORARIO por (grupo, asignatura, bloque, DIA DE SEMANA de la fecha) via LEFT JOIN LATERAL LIMIT 1 -- el join sin el dia duplica filas porque el mismo bloque se repite por dia. Expone la clasificacion del estado como banderas (es_presente / es_tarde / es_ausente / es_justificado) para no repetir los literales 1/2,3/5,6. La consumen fn_asistencia_listar_seguimiento, fn_asistencia_calendario y fn_asistencia_resumen_horas.';


-- ===========================================================================
-- 6. ESCRITURA
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- fn_asistencia_registrar_bulk — "Asistencia manual" y "Marcar todo como
-- Asistio". Un solo statement de upsert; la validacion se hace sobre un CTE
-- de entrada, sin tabla temporal.
-- ---------------------------------------------------------------------------
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
    p_marcar_todos_valor     NUMERIC DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_afectados  INTEGER := 0;
    v_fk_periodo BIGINT;
    v_entrada    JSONB;
    v_invalido   TEXT;
BEGIN
    -- 0. Obligatorios de forma (antes del gate: no filtran informacion).
    IF p_fk_tgrupo IS NULL OR p_fk_tasignatura IS NULL OR p_fecha IS NULL THEN
        RAISE EXCEPTION 'grupo, asignatura y fecha son obligatorios' USING ERRCODE = '23502';
    END IF;

    -- 1. Gate de capability + scope (menu ASISTENCIA, accion CREAR).
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
    IF NOT EXISTS (SELECT 1 FROM academico_test.TASIGNATURA
                    WHERE PK_TASIGNATURA = p_fk_tasignatura AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'asignatura (%) no existe o no esta activa', p_fk_tasignatura USING ERRCODE = '23503';
    END IF;

    -- 3. Periodo de evaluacion (NOT NULL en TASISTENCIA): se resuelve.
    v_fk_periodo := academico_test.fn_asistencia_periodo_eval(p_fk_tgrupo, p_fecha);
    IF v_fk_periodo IS NULL THEN
        RAISE EXCEPTION 'no hay periodo de evaluacion activo para el grupo % que contenga la fecha %',
            p_fk_tgrupo, p_fecha USING ERRCODE = '22023';
    END IF;

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
                                       WHERE ar.PK_TARCHIVO = e.fk_archivo AND ar.ACTIVE = TRUE)
                   THEN format('el archivo de soporte %s no existe o no esta activo', e.fk_archivo)
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
            FECHA, FK_TLV_TIPO_ASISTENCIA, FK_TASIGNATURA, FK_TPERIODO_EVALUACION,
            FK_TMATRICULA, OBSERVACION, FK_SOPORTE_ARCHIVO, BLOQUE,
            CREATED_BY, CREATED_AT, ACTIVE
        )
        SELECT p_fecha, e.fk_tlv_tipo, p_fk_tasignatura, v_fk_periodo,
               e.fk_matricula, e.observacion, e.fk_archivo, p_bloque,
               p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
          FROM entrada e
        ON CONFLICT (FK_TMATRICULA, FK_TASIGNATURA, FECHA, COALESCE(BLOQUE, 0))
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
    BIGINT, BIGINT, BIGINT, DATE, NUMERIC, JSONB, NUMERIC
) IS 'Registro/actualizacion masiva de la asistencia de un grupo en una sesion (FECHA + BLOQUE). p_registros = JSONB [{fkMatricula,tipoAsistencia,observacion,fkArchivo}]. Si viene vacio y p_marcar_todos_valor no es NULL, aplica ese estado a todas las matriculas activas del grupo ("Marcar todo como Asistio" -> 1). Upsert por (FK_TMATRICULA,FK_TASIGNATURA,FECHA,COALESCE(BLOQUE,0)) sobre filas ACTIVE (UQ_TASISTENCIA_SESION). FK_TPERIODO_EVALUACION resuelto por fn_asistencia_periodo_eval; la franja horaria NO se guarda (se deriva de THORARIO al leer). Gate: fn_asistencia_gate_escritura(usuario, grupo, ''CREAR''). Valida todas las filas de entrada en un solo recorrido y lanza con el primer motivo concreto. Retorna # de registros afectados.';


-- ---------------------------------------------------------------------------
-- fn_asistencia_editar — edicion de un registro individual.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_editar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tasistencia         BIGINT,
    p_tipo_asistencia_valor  NUMERIC   DEFAULT NULL,
    p_observacion            VARCHAR   DEFAULT NULL,
    p_fk_soporte_archivo     BIGINT    DEFAULT NULL,
    p_limpiar_archivo        BOOLEAN   DEFAULT FALSE,
    p_limpiar_observacion    BOOLEAN   DEFAULT FALSE
)
RETURNS BIGINT
LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_fk_tgrupo   BIGINT;
    v_fk_tlv_tipo BIGINT;
BEGIN
    -- 1. El registro existe (y de paso da el grupo con el que se autoriza).
    SELECT m.FK_TGRUPO INTO v_fk_tgrupo
      FROM academico_test.TASISTENCIA a
      JOIN academico_test.TMATRICULA m ON m.PK_TMATRICULA = a.FK_TMATRICULA
     WHERE a.PK_TASISTENCIA = p_pk_tasistencia AND a.ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'registro de asistencia (%) no existe o no esta activo', p_pk_tasistencia
            USING ERRCODE = 'P0002';
    END IF;

    -- 2. Gate de capability + scope sobre el grupo del registro.
    PERFORM academico_test.fn_asistencia_gate_escritura(
        p_pk_usuario_solicitante, v_fk_tgrupo, 'EDITAR');

    -- 3. Validacion de los campos que llegan.
    IF p_tipo_asistencia_valor IS NOT NULL THEN
        v_fk_tlv_tipo := academico_test.fn_asistencia_tipo_pk(p_tipo_asistencia_valor);
        IF v_fk_tlv_tipo IS NULL THEN
            RAISE EXCEPTION 'tipoAsistencia % invalido (validos: 1,2,3,5,6)', p_tipo_asistencia_valor
                USING ERRCODE = '23503';
        END IF;
    END IF;

    IF p_fk_soporte_archivo IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TARCHIVO
         WHERE PK_TARCHIVO = p_fk_soporte_archivo AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'archivo (%) no existe o no esta activo', p_fk_soporte_archivo
            USING ERRCODE = '23503';
    END IF;

    -- 4. Update parcial.
    UPDATE academico_test.TASISTENCIA SET
        FK_TLV_TIPO_ASISTENCIA = COALESCE(v_fk_tlv_tipo, FK_TLV_TIPO_ASISTENCIA),
        OBSERVACION = CASE WHEN p_limpiar_observacion THEN NULL
                           ELSE COALESCE(NULLIF(TRIM(p_observacion), ''), OBSERVACION) END,
        FK_SOPORTE_ARCHIVO = CASE WHEN p_limpiar_archivo THEN NULL
                                  ELSE COALESCE(p_fk_soporte_archivo, FK_SOPORTE_ARCHIVO) END,
        MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
        MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TASISTENCIA = p_pk_tasistencia AND ACTIVE = TRUE;

    RETURN p_pk_tasistencia;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_editar(
    BIGINT, BIGINT, NUMERIC, VARCHAR, BIGINT, BOOLEAN, BOOLEAN
) IS 'Edita un registro individual de TASISTENCIA (estado, observacion, soporte). Solo aplica los campos no nulos; p_limpiar_archivo / p_limpiar_observacion fuerzan NULL. El grupo del registro se resuelve primero y con el se autoriza via fn_asistencia_gate_escritura(..., ''EDITAR''). Retorna PK_TASISTENCIA.';


-- ===========================================================================
-- 7. LECTURA
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- fn_asistencia_estudiantes_sesion — PADRON de una sesion, pantalla
-- "Asistencia manual".
--
--   Devuelve TODAS las matriculas activas del grupo (una fila por alumno),
--   con su estado ACTUAL para ese (asignatura, fecha, bloque) si ya existe
--   registro, o NULL si aun no se ha tomado ("Seleccionar" en el mock).
--
--   No puede salir de v_asistencia_detalle: esa vista es FROM TASISTENCIA
--   (inner join), asi que solo tiene filas de alumnos YA registrados. El
--   padron arranca de TMATRICULA y hace LEFT JOIN a los registros de la
--   sesion.
--
--   La cabecera de la sesion (fecha ya la da el caller; hora_inicio/fin de
--   THORARIO por dia de semana, y el periodo de evaluacion) se repite en
--   cada fila para que el front pinte "16 FEBRERO (7:00 - 10:00)" sin una
--   segunda llamada. Las pestanas de asignatura del mock (Matematicas /
--   Geometria) las arma el front con el horario del grupo; aqui la
--   asignatura llega ya elegida.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_estudiantes_sesion(
    p_pk_usuario     BIGINT,
    p_fk_tgrupo      BIGINT,
    p_fk_tasignatura BIGINT,
    p_fecha          DATE,
    p_bloque         NUMERIC DEFAULT NULL
)
RETURNS TABLE (
    fk_tmatricula          BIGINT,
    fk_testudiante         BIGINT,
    estudiante             TEXT,
    documento              VARCHAR,
    -- estado ACTUAL del alumno en la sesion (NULL = sin registrar)
    pk_tasistencia         BIGINT,
    tipo_asistencia_valor  INTEGER,
    tipo_asistencia        VARCHAR,
    observacion            VARCHAR,
    fk_soporte_archivo     BIGINT,
    soporte_nombre         VARCHAR,
    -- cabecera de la sesion, repetida en cada fila
    fk_tperiodo_evaluacion BIGINT,
    hora_inicio            TIMESTAMP,
    hora_fin               TIMESTAMP,
    total_estudiantes      BIGINT,
    registrados            BIGINT
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    -- Gate de LECTURA sobre el grupo (capability 'VER' + scope por categoria
    -- de rol). p_pk_usuario NULL o SUPER_ADMIN => pasa.
    IF NOT academico_test.fn_asistencia_puede_ver(p_pk_usuario, p_fk_tgrupo) THEN
        RAISE EXCEPTION 'El usuario no puede ver la asistencia del grupo %', p_fk_tgrupo
            USING ERRCODE = '42501';
    END IF;

    IF p_fk_tgrupo IS NULL OR p_fk_tasignatura IS NULL OR p_fecha IS NULL THEN
        RAISE EXCEPTION 'grupo, asignatura y fecha son obligatorios' USING ERRCODE = '23502';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM academico_test.TGRUPO
                    WHERE PK_TGRUPO = p_fk_tgrupo AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'grupo (%) no existe o no esta activo', p_fk_tgrupo USING ERRCODE = '23503';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM academico_test.TASIGNATURA
                    WHERE PK_TASIGNATURA = p_fk_tasignatura AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'asignatura (%) no existe o no esta activa', p_fk_tasignatura USING ERRCODE = '23503';
    END IF;

    RETURN QUERY
    WITH horario AS (
        -- Franja horaria de la sesion: mismo patron que la vista (LATERAL por
        -- dia de semana), pero keyed off p_fecha/p_bloque, no de un registro.
        SELECT th.HORA_INICIO, th.HORA_FIN
          FROM academico_test.THORARIO th
          JOIN academico_test.TLISTA_VALOR dia
            ON dia.PK_LISTA_VALOR = th.FK_TLV_DIA_SEMANA
           AND dia.CATEGORIA = 'DIA_SEMANA'
           AND dia.VALOR = (EXTRACT(DOW FROM p_fecha)::INT + 1)::TEXT
         WHERE th.FK_TGRUPO      = p_fk_tgrupo
           AND th.FK_TASIGNATURA = p_fk_tasignatura
           AND th.NUMERO_BLOQUE  = p_bloque
           AND th.ACTIVE = TRUE
         LIMIT 1
    ),
    registros AS (
        -- Lo ya registrado para ESTA sesion (0 o 1 fila por matricula: el
        -- indice unico parcial UQ_TASISTENCIA_SESION lo garantiza). Se reusa
        -- v_asistencia_detalle -- aqui SI aplica: la vista ya resuelve el
        -- estado y sus banderas, y este set es "el alumno que ya tiene
        -- registro", que es exactamente lo que la vista contiene.
        SELECT d.fk_tmatricula, d.pk_tasistencia, d.tipo_valor, d.tipo_nombre,
               d.observacion, d.fk_soporte_archivo, d.soporte_nombre
          FROM academico_test.v_asistencia_detalle d
         WHERE d.fk_tasignatura = p_fk_tasignatura
           AND d.fecha = p_fecha
           AND COALESCE(d.bloque, 0) = COALESCE(p_bloque, 0)
    )
    SELECT
        m.PK_TMATRICULA,
        es.PK_TESTUDIANTE,
        NULLIF(TRIM(regexp_replace(
            concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                           u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO),
            '\s+', ' ', 'g')), ''),
        u.IDENTIFICACION,
        r.PK_TASISTENCIA,
        r.tipo_valor,
        r.tipo_nombre,
        r.OBSERVACION,
        r.FK_SOPORTE_ARCHIVO,
        r.soporte_nombre,
        academico_test.fn_asistencia_periodo_eval(p_fk_tgrupo, p_fecha),
        (SELECT h.HORA_INICIO FROM horario h),
        (SELECT h.HORA_FIN    FROM horario h),
        count(*)            OVER ()::BIGINT,
        count(r.PK_TASISTENCIA) OVER ()::BIGINT
      FROM academico_test.TMATRICULA  m
      JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
      JOIN academico_test.TUSUARIO    u  ON u.PK_TUSUARIO = es.FK_TUSUARIO
 LEFT JOIN registros r ON r.FK_TMATRICULA = m.PK_TMATRICULA
     WHERE m.FK_TGRUPO = p_fk_tgrupo AND m.ACTIVE = TRUE
     ORDER BY u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO, u.PRIMER_NOMBRE,
              u.SEGUNDO_NOMBRE, m.PK_TMATRICULA;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_estudiantes_sesion(
    BIGINT, BIGINT, BIGINT, DATE, NUMERIC
) IS 'Padron de una sesion para la pantalla "Asistencia manual": una fila por matricula activa del grupo, con el estado ACTUAL del alumno para ese (asignatura, fecha, bloque) si ya hay registro (pk_tasistencia / tipo / observacion / soporte) o NULL si falta tomarlo ("Seleccionar"). Arranca de TMATRICULA con LEFT JOIN a los registros -- v_asistencia_detalle no sirve porque es inner sobre TASISTENCIA. Repite en cada fila la cabecera de la sesion: fk_tperiodo_evaluacion (fn_asistencia_periodo_eval) y hora_inicio/hora_fin de THORARIO por dia de semana de la fecha. total_estudiantes y registrados son ventanas sobre el padron completo. Gate: fn_asistencia_puede_ver(usuario, grupo). Orden: apellidos, nombres.';


-- ---------------------------------------------------------------------------
-- fn_asistencia_listar_seguimiento — pantalla "Seguimiento".
--   total_estudiantes / ausentes / total_count son ventanas sobre el set
--   filtrado COMPLETO (independientes de la pagina).
--   ausentes cuenta ESTUDIANTES DISTINTOS ausentes, no registros: con un
--   rango de varios dias, un mismo alumno ausente 3 veces contaba 3.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_listar_seguimiento(
    p_pk_usuario      BIGINT  DEFAULT NULL,   -- alcance (fn_asistencia_puede_ver)
    p_fecha_desde     DATE    DEFAULT NULL,
    p_fecha_hasta     DATE    DEFAULT NULL,
    p_fk_tgrupo       BIGINT  DEFAULT NULL,
    p_fk_tasignatura  BIGINT  DEFAULT NULL,
    p_tipo_asistencia NUMERIC DEFAULT NULL,   -- VALOR de TIPO_ASISTENCIA
    p_search          TEXT    DEFAULT NULL,
    p_page_index      INT     DEFAULT 0,
    p_page_size       INT     DEFAULT 10,
    p_sort_by         TEXT    DEFAULT NULL,   -- estudiante|fecha|tipo|grupo|asignatura|documento
    p_sort_dir        TEXT    DEFAULT NULL    -- asc|desc
)
RETURNS TABLE (
    pk_tasistencia        BIGINT,
    estudiante            TEXT,
    documento             VARCHAR,
    grupo                 VARCHAR,
    asignatura            VARCHAR,
    fecha                 DATE,
    bloque                NUMERIC,
    hora_inicio           TIMESTAMP,
    hora_fin              TIMESTAMP,
    tipo_asistencia_valor INTEGER,
    tipo_asistencia       VARCHAR,
    observacion           VARCHAR,
    tiene_soporte         BOOLEAN,
    fk_soporte_archivo    BIGINT,
    soporte_nombre        VARCHAR,
    total_estudiantes     BIGINT,
    ausentes              BIGINT,
    total_count           BIGINT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_col TEXT;
    v_dir TEXT;
BEGIN
    v_col := CASE lower(coalesce(p_sort_by, ''))
        WHEN 'estudiante' THEN 'estudiante'
        WHEN 'documento'  THEN 'documento'
        WHEN 'fecha'      THEN 'fecha'
        WHEN 'tipo'       THEN 'tipo_asistencia_valor'
        WHEN 'grupo'      THEN 'grupo'
        WHEN 'asignatura' THEN 'asignatura'
        ELSE 'fecha'
    END;
    v_dir := CASE WHEN lower(coalesce(p_sort_dir, '')) = 'asc' THEN 'ASC' ELSE 'DESC' END;

    RETURN QUERY EXECUTE format($q$
        SELECT
            pk_tasistencia, estudiante, documento, grupo, asignatura, fecha,
            bloque, hora_inicio, hora_fin, tipo_asistencia_valor, tipo_asistencia,
            observacion, tiene_soporte, fk_soporte_archivo, soporte_nombre,
            -- DISTINCT no existe en funciones de ventana: se cuenta la
            -- primera aparicion de cada matricula (rn_mat = 1).
            SUM((rn_mat = 1)::int) OVER ()::BIGINT                          AS total_estudiantes,
            SUM((rn_aus = 1)::int) OVER ()::BIGINT                          AS ausentes,
            COUNT(*) OVER ()::BIGINT                                        AS total_count
        FROM (
            SELECT
                d.pk_tasistencia, d.estudiante, d.documento, d.grupo, d.asignatura,
                d.fecha, d.bloque, d.hora_inicio, d.hora_fin,
                d.tipo_valor  AS tipo_asistencia_valor,
                d.tipo_nombre AS tipo_asistencia,
                d.observacion, d.tiene_soporte, d.fk_soporte_archivo, d.soporte_nombre,
                row_number() OVER (PARTITION BY d.fk_tmatricula
                                       ORDER BY d.pk_tasistencia)           AS rn_mat,
                CASE WHEN d.es_ausente
                     THEN row_number() OVER (PARTITION BY d.fk_tmatricula, d.es_ausente
                                                 ORDER BY d.pk_tasistencia)
                     ELSE 0 END                                             AS rn_aus
              FROM academico_test.v_asistencia_detalle d
             WHERE ($2 IS NULL OR d.fecha >= $2)
               AND ($3 IS NULL OR d.fecha <= $3)
               AND ($4 IS NULL OR d.fk_tgrupo = $4)
               AND ($5 IS NULL OR d.fk_tasignatura = $5)
               AND ($6 IS NULL OR d.tipo_valor = $6::INT)
               AND ($7 IS NULL OR (
                       d.estudiante  ILIKE '%%' || $7 || '%%' OR
                       d.documento   ILIKE '%%' || $7 || '%%' OR
                       d.grupo       ILIKE '%%' || $7 || '%%' OR
                       d.asignatura  ILIKE '%%' || $7 || '%%' OR
                       d.tipo_nombre ILIKE '%%' || $7 || '%%'
                   ))
               -- Alcance por rol. Se evalua al final y una sola vez por
               -- grupo distinto (fn_asistencia_puede_ver es STABLE).
               AND academico_test.fn_asistencia_puede_ver($1, d.fk_tgrupo)
        ) q
        ORDER BY %s %s, pk_tasistencia
        LIMIT NULLIF($9, 0)
       OFFSET COALESCE($8, 0) * COALESCE(NULLIF($9, 0), 0)
    $q$, v_col, v_dir)
    USING p_pk_usuario, p_fecha_desde, p_fecha_hasta, p_fk_tgrupo, p_fk_tasignatura,
          p_tipo_asistencia, NULLIF(TRIM(p_search), ''), p_page_index, p_page_size;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_listar_seguimiento(
    BIGINT, DATE, DATE, BIGINT, BIGINT, NUMERIC, TEXT, INT, INT, TEXT, TEXT
) IS 'Pantalla Seguimiento: listado paginado sobre v_asistencia_detalle con filtros rango de fecha / grupo / asignatura / tipo (VALOR) / busqueda libre (estudiante, documento, grupo, asignatura, estado). Alcance por rol via fn_asistencia_puede_ver. total_estudiantes y ausentes cuentan ESTUDIANTES DISTINTOS (no registros) del set filtrado completo, y total_count sus filas -- las tres son ventanas independientes de la pagina. Orden por estudiante|documento|fecha|tipo|grupo|asignatura.';


-- ---------------------------------------------------------------------------
-- fn_asistencia_sesiones_programadas — proyeccion del HORARIO sobre fechas
-- reales. UN solo sitio con "que sesiones toca dictar en [desde, hasta]"
-- (generate_series de dias x THORARIO por DIA_SEMANA). La consumen el
-- calendario y el resumen de horas.
--
--   p_fk_tfuncionario NO NULL  ->  solo las (grupo, asignatura) que ESE
--   docente tiene asignadas en TDOCENTE_ASIGNATURA (la "asignatura
--   asignada"): es lo que convierte el calendario en "mis clases".
--   THORARIO no tiene docente; la asignacion vive en TDOCENTE_ASIGNATURA
--   (fk_tfuncionario, fk_tgrupo, fk_tasignatura, fk_tperiodo_academico) --
--   el grupo determina el periodo academico, asi que basta el trio.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_sesiones_programadas(
    p_pk_usuario      BIGINT,
    p_fk_tsede        BIGINT,
    p_fecha_desde     DATE,
    p_fecha_hasta     DATE,     -- INCLUSIVO
    p_fk_tgrupo       BIGINT DEFAULT NULL,
    p_fk_tasignatura  BIGINT DEFAULT NULL,
    p_fk_tfuncionario BIGINT DEFAULT NULL
)
RETURNS TABLE (
    fecha          DATE,
    fk_tgrupo      BIGINT,
    grupo          VARCHAR,
    fk_tasignatura BIGINT,
    asignatura     VARCHAR,
    bloque         NUMERIC,
    hora_inicio    TIMESTAMP,
    hora_fin       TIMESTAMP,
    horas          NUMERIC
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
    SELECT dd::date,
           th.FK_TGRUPO,      gr.NOMBRE,
           th.FK_TASIGNATURA, asig.NOMBRE,
           th.NUMERO_BLOQUE,
           th.HORA_INICIO,    th.HORA_FIN,
           ROUND(COALESCE(EXTRACT(EPOCH FROM (th.HORA_FIN - th.HORA_INICIO)) / 3600.0, 0)::NUMERIC, 2)
      FROM generate_series(p_fecha_desde, p_fecha_hasta, INTERVAL '1 day') dd
      JOIN academico_test.TLISTA_VALOR dia
        ON dia.CATEGORIA = 'DIA_SEMANA'
       AND dia.VALOR = (EXTRACT(DOW FROM dd)::INT + 1)::TEXT
      JOIN academico_test.THORARIO th
        ON th.FK_TLV_DIA_SEMANA = dia.PK_LISTA_VALOR
       AND th.ACTIVE = TRUE
      JOIN academico_test.TGRUPO gr             ON gr.PK_TGRUPO = th.FK_TGRUPO
      JOIN academico_test.TGRADO g              ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TASIGNATURA asig      ON asig.PK_TASIGNATURA = th.FK_TASIGNATURA
     WHERE pa.FK_TSEDE = p_fk_tsede
       AND (p_fk_tgrupo      IS NULL OR th.FK_TGRUPO = p_fk_tgrupo)
       AND (p_fk_tasignatura IS NULL OR th.FK_TASIGNATURA = p_fk_tasignatura)
       AND (p_fk_tfuncionario IS NULL OR EXISTS (
               SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
                WHERE da.FK_TFUNCIONARIO = p_fk_tfuncionario
                  AND da.FK_TGRUPO       = th.FK_TGRUPO
                  AND da.FK_TASIGNATURA  = th.FK_TASIGNATURA
                  AND da.ACTIVE = TRUE))
       AND academico_test.fn_asistencia_puede_ver(p_pk_usuario, th.FK_TGRUPO)
     GROUP BY dd::date, th.FK_TGRUPO, gr.NOMBRE, th.FK_TASIGNATURA, asig.NOMBRE,
              th.NUMERO_BLOQUE, th.HORA_INICIO, th.HORA_FIN;  -- colapsa bloques duplicados
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_sesiones_programadas(
    BIGINT, BIGINT, DATE, DATE, BIGINT, BIGINT, BIGINT
) IS 'Proyeccion del horario (THORARIO) sobre las fechas reales de [p_fecha_desde, p_fecha_hasta] (INCLUSIVO): una fila por sesion que TOCA dictar (grupo, asignatura, bloque, fecha) con su duracion en horas. Scope por sede + fn_asistencia_puede_ver. Si p_fk_tfuncionario no es NULL, solo las (grupo, asignatura) asignadas a ese docente en TDOCENTE_ASIGNATURA. La usan fn_asistencia_calendario (rama "programadas") y fn_asistencia_resumen_horas (horas programadas de la semana / del mes).';


-- ---------------------------------------------------------------------------
-- fn_asistencia_calendario — pantalla "Asistencia" (calendario mensual).
--
--   Devuelve TODAS las sesiones del mes: las PROGRAMADAS en THORARIO
--   (fn_asistencia_sesiones_programadas) y ademas las registradas que no
--   correspondan a ningun bloque programado (asistencia manual suelta) ->
--   FULL OUTER JOIN.
--
--   p_fk_tfuncionario: si no es NULL, el calendario queda acotado a las
--   asignaturas ASIGNADAS a ese docente (los puntos = "sus" clases). El
--   endpoint lo resuelve desde el token cuando el front pide "mis clases".
--
--   estado_sesion:
--     'REGISTRADA' hay registro                       (verde  / "Asistencia pasada")
--     'RETRASADA'  fecha <= p_fecha_hoy y sin registro (rojo   / "No registrada en la fecha")
--     'PENDIENTE'  fecha  > p_fecha_hoy y sin registro (azul   / "Aun no corresponde tomarla")
-- ---------------------------------------------------------------------------
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
    fk_tasignatura    BIGINT,
    asignatura        VARCHAR,
    bloque            NUMERIC,
    hora_inicio       TIMESTAMP,
    hora_fin          TIMESTAMP,
    horas             NUMERIC,
    total_estudiantes BIGINT,
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
    RETURN QUERY
    -- (a) Sesiones PROGRAMADAS del mes (helper compartido).
    WITH programadas AS (
        SELECT sp.fecha, sp.fk_tgrupo, sp.grupo, sp.fk_tasignatura, sp.asignatura,
               sp.bloque, sp.hora_inicio, sp.hora_fin
          FROM academico_test.fn_asistencia_sesiones_programadas(
                   p_pk_usuario, p_fk_tsede, v_ini, v_fin - 1,
                   p_fk_tgrupo, p_fk_tasignatura, p_fk_tfuncionario) sp
    ),
    -- (b) Sesiones REGISTRADAS del mes, ya agregadas por sesion.
    registradas AS (
        SELECT d.fecha, d.fk_tgrupo, d.grupo, d.fk_tasignatura, d.asignatura,
               d.bloque,
               MIN(d.hora_inicio)                            AS hora_inicio,
               MIN(d.hora_fin)                               AS hora_fin,
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
         GROUP BY d.fecha, d.fk_tgrupo, d.grupo, d.fk_tasignatura, d.asignatura, d.bloque
    )
    SELECT
        COALESCE(p.fecha, r.fecha),
        COALESCE(p.fk_tgrupo, r.fk_tgrupo),
        COALESCE(p.grupo, r.grupo),
        COALESCE(p.fk_tasignatura, r.fk_tasignatura),
        COALESCE(p.asignatura, r.asignatura),
        COALESCE(p.bloque, r.bloque),
        COALESCE(p.hora_inicio, r.hora_inicio),
        COALESCE(p.hora_fin, r.hora_fin),
        ROUND(COALESCE(EXTRACT(EPOCH FROM (COALESCE(p.hora_fin, r.hora_fin)
                                         - COALESCE(p.hora_inicio, r.hora_inicio))) / 3600.0, 0)::NUMERIC, 2),
        COALESCE(r.n_total, 0)::BIGINT,
        COALESCE(r.n_a_tiempo, 0)::BIGINT,
        COALESCE(r.n_tarde, 0)::BIGINT,
        COALESCE(r.n_ausentes, 0)::BIGINT,
        CASE WHEN r.n_total IS NOT NULL                       THEN 'REGISTRADA'
             WHEN COALESCE(p.fecha, r.fecha) <= p_fecha_hoy   THEN 'RETRASADA'
             ELSE 'PENDIENTE'
        END
      FROM programadas p
      FULL OUTER JOIN registradas r
        ON r.fecha          = p.fecha
       AND r.fk_tgrupo      = p.fk_tgrupo
       AND r.fk_tasignatura = p.fk_tasignatura
       AND COALESCE(r.bloque, -1) = COALESCE(p.bloque, -1)
     ORDER BY 1, 3, 5, 6;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_calendario(
    BIGINT, BIGINT, INTEGER, INTEGER, BIGINT, BIGINT, DATE, BIGINT
) IS 'Pantalla Asistencia (calendario mensual por sede). Una fila por SESION del mes: las PROGRAMADAS (fn_asistencia_sesiones_programadas) en FULL OUTER JOIN con las REGISTRADAS, de modo que tambien aparecen las tomas manuales sin bloque programado. estado_sesion = REGISTRADA (hay registro) | RETRASADA (fecha <= p_fecha_hoy sin registro) | PENDIENTE (fecha futura sin registro) -- los 3 contadores del encabezado. p_fk_tfuncionario no NULL acota a las asignaturas asignadas a ese docente en TDOCENTE_ASIGNATURA (vista "mis clases"). Rango de fechas sargable. Alcance por rol via fn_asistencia_puede_ver.';


-- ---------------------------------------------------------------------------
-- fn_asistencia_resumen_horas — tarjetas del encabezado.
--   Los limites de semana / mes / anio se calculan UNA vez en variables y se
--   comparan por rango (sargable), en vez de repetir EXTRACT(MONTH FROM ...)
--   en cada agregado.
--
--   Dos familias de horas:
--     horas_semana / horas_mes / horas_anio       = DICTADAS (registradas)
--     horas_programadas_semana / _mes             = del HORARIO (toque o no)
--   El widget "Dictadas 16 h / 20 h - Faltan 4 h" del mock sale de
--   horas_semana (16) vs horas_programadas_semana (20); "faltan" = 20 - 16.
--
--   "Horas efectivas" = horas de cada sesion ponderadas por la fraccion de
--   estudiantes presentes (asistio + tarde).
--
--   p_fk_tfuncionario no NULL -> todo se acota a las asignaturas ASIGNADAS a
--   ese docente (mismo criterio que fn_asistencia_calendario).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_resumen_horas(
    p_pk_usuario      BIGINT,
    p_fk_tsede        BIGINT,
    p_fecha_ref       DATE   DEFAULT CURRENT_DATE,
    p_fk_tgrupo       BIGINT DEFAULT NULL,
    p_fk_tasignatura  BIGINT DEFAULT NULL,
    p_fk_tfuncionario BIGINT DEFAULT NULL
)
RETURNS TABLE (
    horas_semana             NUMERIC,   -- dictadas (registradas)
    horas_mes                NUMERIC,
    horas_anio               NUMERIC,
    horas_programadas_semana NUMERIC,   -- del horario (THORARIO)
    horas_programadas_mes    NUMERIC,
    horas_efectivas_mes      NUMERIC,
    sesiones_mes             BIGINT,
    registros_mes            BIGINT,
    a_tiempo_mes             BIGINT,
    tarde_mes                BIGINT,
    ausentes_mes             BIGINT,
    registradas_mes          BIGINT,
    retrasadas_mes           BIGINT,
    pendientes_mes           BIGINT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_anio_ini DATE := date_trunc('year',  p_fecha_ref::timestamp)::date;
    v_anio_fin DATE := (date_trunc('year',  p_fecha_ref::timestamp) + INTERVAL '1 year')::date;
    v_mes_ini  DATE := date_trunc('month', p_fecha_ref::timestamp)::date;
    v_mes_fin  DATE := (date_trunc('month', p_fecha_ref::timestamp) + INTERVAL '1 month')::date;
    v_sem_ini  DATE := date_trunc('week',  p_fecha_ref::timestamp)::date;
    v_sem_fin  DATE := (date_trunc('week',  p_fecha_ref::timestamp) + INTERVAL '1 week')::date;
BEGIN
    RETURN QUERY
    -- Sesiones registradas del ANIO de referencia, agregadas por sesion.
    WITH sesion AS (
        SELECT d.fecha,
               MIN(d.horas)                          AS horas_sesion,
               COUNT(*)                              AS n_total,
               COUNT(*) FILTER (WHERE d.es_presente) AS n_presentes,
               COUNT(*) FILTER (WHERE d.tipo_valor = 1) AS n_a_tiempo,
               COUNT(*) FILTER (WHERE d.es_tarde)    AS n_tarde,
               COUNT(*) FILTER (WHERE d.es_ausente)  AS n_ausentes
          FROM academico_test.v_asistencia_detalle d
         WHERE d.fecha >= v_anio_ini AND d.fecha < v_anio_fin
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
         GROUP BY d.fecha, d.fk_tgrupo, d.fk_tasignatura, d.bloque
    ),
    -- Horas PROGRAMADAS: proyeccion del horario sobre [semana U mes] (una
    -- sola llamada; la semana puede desbordar el mes en su primer/ultimo
    -- tramo, por eso el rango cubre ambos).
    programadas AS (
        SELECT sp.fecha, sp.horas
          FROM academico_test.fn_asistencia_sesiones_programadas(
                   p_pk_usuario, p_fk_tsede,
                   LEAST(v_sem_ini, v_mes_ini),
                   GREATEST(v_sem_fin, v_mes_fin) - 1,
                   p_fk_tgrupo, p_fk_tasignatura, p_fk_tfuncionario) sp
    ),
    -- Estado de las sesiones del MES (reusa el calendario: una sola
    -- definicion de REGISTRADA / RETRASADA / PENDIENTE en todo el modulo).
    estados AS (
        SELECT c.estado_sesion, COUNT(*) AS n
          FROM academico_test.fn_asistencia_calendario(
                   p_pk_usuario      => p_pk_usuario,
                   p_fk_tsede        => p_fk_tsede,
                   p_anio            => EXTRACT(YEAR  FROM p_fecha_ref)::INT,
                   p_mes             => EXTRACT(MONTH FROM p_fecha_ref)::INT,
                   p_fk_tgrupo       => p_fk_tgrupo,
                   p_fk_tasignatura  => p_fk_tasignatura,
                   p_fk_tfuncionario => p_fk_tfuncionario) c
         GROUP BY c.estado_sesion
    )
    SELECT
        ROUND(COALESCE(SUM(s.horas_sesion) FILTER (WHERE s.fecha >= v_sem_ini AND s.fecha < v_sem_fin), 0), 2),
        ROUND(COALESCE(SUM(s.horas_sesion) FILTER (WHERE s.fecha >= v_mes_ini AND s.fecha < v_mes_fin), 0), 2),
        ROUND(COALESCE(SUM(s.horas_sesion), 0), 2),
        (SELECT ROUND(COALESCE(SUM(pr.horas) FILTER (WHERE pr.fecha >= v_sem_ini AND pr.fecha < v_sem_fin), 0), 2)
           FROM programadas pr),
        (SELECT ROUND(COALESCE(SUM(pr.horas) FILTER (WHERE pr.fecha >= v_mes_ini AND pr.fecha < v_mes_fin), 0), 2)
           FROM programadas pr),
        ROUND(COALESCE(SUM(s.horas_sesion * s.n_presentes::NUMERIC / NULLIF(s.n_total, 0))
                       FILTER (WHERE s.fecha >= v_mes_ini AND s.fecha < v_mes_fin), 0), 2),
        COUNT(*)          FILTER (WHERE s.fecha >= v_mes_ini AND s.fecha < v_mes_fin)::BIGINT,
        COALESCE(SUM(s.n_total)    FILTER (WHERE s.fecha >= v_mes_ini AND s.fecha < v_mes_fin), 0)::BIGINT,
        COALESCE(SUM(s.n_a_tiempo) FILTER (WHERE s.fecha >= v_mes_ini AND s.fecha < v_mes_fin), 0)::BIGINT,
        COALESCE(SUM(s.n_tarde)    FILTER (WHERE s.fecha >= v_mes_ini AND s.fecha < v_mes_fin), 0)::BIGINT,
        COALESCE(SUM(s.n_ausentes) FILTER (WHERE s.fecha >= v_mes_ini AND s.fecha < v_mes_fin), 0)::BIGINT,
        (SELECT COALESCE(SUM(e.n), 0) FROM estados e WHERE e.estado_sesion = 'REGISTRADA')::BIGINT,
        (SELECT COALESCE(SUM(e.n), 0) FROM estados e WHERE e.estado_sesion = 'RETRASADA')::BIGINT,
        (SELECT COALESCE(SUM(e.n), 0) FROM estados e WHERE e.estado_sesion = 'PENDIENTE')::BIGINT
      FROM sesion s;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_resumen_horas(
    BIGINT, BIGINT, DATE, BIGINT, BIGINT, BIGINT
) IS 'Tarjetas del encabezado de la pantalla Asistencia. Horas DICTADAS (registradas) de semana/mes/anio + horas PROGRAMADAS del horario de semana/mes (fn_asistencia_sesiones_programadas) -> el widget "16 h / 20 h - faltan 4 h" es horas_semana vs horas_programadas_semana. horas_efectivas_mes ponderadas por fraccion de presentes. Conteos de registros del mes y los 3 contadores de estado (registradas/retrasadas/pendientes) delegados en fn_asistencia_calendario. p_fk_tfuncionario no NULL acota todo a las asignaturas asignadas a ese docente. Limites sargables. Alcance por rol via fn_asistencia_puede_ver.';
