-- ===========================================================================
-- V241 — Planeador educativo: conecta la calificacion automatica de OTRO con
-- metodo de valoracion configurado (CU-86e311xxp — G. Academico Back
-- Planeador educativo).
--
-- Complementa V240 (instrumento OTRO con metodo de valoracion RUBRICA |
-- LISTA_COTEJO | ESCALA_VALORACION, estructura completa via
-- fn_actividad_rubrica_definir/_cotejo_definir/_escala_definir) y V227
-- (fn_actividad_nota_calificar_rubrica/_cotejo/_escala/_otro y la fachada
-- fn_actividad_nota_calificar). V240 ya dejo fn_actividad_instrumento_assert
-- aceptando OTRO+metodo como equivalente al instrumento estructurado, por lo
-- que fn_actividad_nota_calificar_rubrica/_cotejo/_escala YA funcionan sin
-- cambios sobre una actividad OTRO con metodo configurado -- lo que faltaba
-- era que la FACHADA (fn_actividad_nota_calificar) las invocara en vez de
-- despachar siempre a fn_actividad_nota_calificar_otro (porcentaje manual).
--
-- Modulos:
--   (1) fn_actividad_otro_metodo_valoracion — helper: VALOR del metodo de
--       valoracion configurado en TACTIVIDAD_OTRO para una actividad (NULL
--       si no tiene fila activa). Evita repetir el JOIN
--       TACTIVIDAD_OTRO -> TLISTA_VALOR en 2+ sitios (fachada de calificar y
--       fn_actividad_nota_obtener).
--   (2) fn_actividad_nota_calificar — CREATE OR REPLACE (misma firma): la
--       rama OTRO ahora resuelve el metodo configurado y, si existe,
--       redirige al parseo/dispatch de RUBRICA/LISTA_COTEJO/ESCALA_VALORACION
--       (mismo p_calificacion, mismas funciones destino de V227); si no hay
--       metodo configurado, se mantiene el flujo manual original
--       ({porcentaje} -> fn_actividad_nota_calificar_otro).
--   (3) fn_actividad_nota_obtener — CREATE OR REPLACE: el detalle de captura
--       de una actividad OTRO con metodo configurado hoy siempre volvia NULL
--       (el CASE por instrumento solo contemplaba los 3 valores literales
--       RUBRICA/LISTA_COTEJO/ESCALA_VALORACION); con (2) esas actividades
--       pasan a tener filas reales en TACTIVIDAD_RUBRICA_EVALUACION /
--       _COTEJO_EVALUACION / _ESCALA_EVALUACION, asi que se corrige el mismo
--       patron detectado en la fachada: la rama OTRO ahora resuelve el
--       metodo (mismo helper del punto 1) y reutiliza el MISMO armado JSONB
--       que las ramas RUBRICA/LISTA_COTEJO/ESCALA_VALORACION (estilo ya usado
--       por V240 en fn_actividad_instrumento_obtener, que duplica el mismo
--       bloque JSONB para el caso OTRO en vez de intentar reutilizar el CASE
--       por funcion SQL).
--
-- -------------------------------------------------------------------------
-- DECISION DE NEGOCIO confirmada con el usuario (preguntada y respondida
-- explicitamente, no se repite):
--
--   * El {porcentaje} de fn_actividad_nota_calificar_otro es la
--     CALIFICACION del estudiante en la actividad (0-100,
--     TACTIVIDAD_NOTA.CALIFICACION), NO la PONDERACION de la actividad
--     dentro de la unidad (TACTIVIDAD.PONDERACION, V223/V224, no se toca
--     aqui) -- son conceptos distintos ya correctamente separados. Se
--     confirmo conectar el calculo automatico: cuando una actividad OTRO
--     tiene metodo de valoracion configurado, calificarla debe CALCULAR la
--     nota a partir de la estructura (igual que si el instrumento fuera
--     RUBRICA/LISTA_COTEJO/ESCALA_VALORACION directo), no seguir aceptando
--     un porcentaje manual para ese caso. El flujo manual de porcentaje
--     sigue existiendo, pero SOLO para OTRO sin metodo configurado (texto
--     libre puro).
--
-- -------------------------------------------------------------------------
-- QUE NO SE TOCA (revisado y descartado a proposito):
--
--   * fn_actividad_nota_calificar_rubrica_bulk / _cotejo_bulk / _escala_bulk
--     (V227/V239) -- NO tienen una fachada propia de despacho por
--     instrumento: el front las llama DIRECTO conociendo ya el instrumento
--     de la columna que esta calificando (misma actividad completa, no hay
--     ambiguedad RUBRICA-vs-OTRO+RUBRICA que resolver en cada llamada masiva
--     como si la hay en la fachada individual, que recibe una sola actividad
--     a la vez sin que el llamador tenga que saber de antemano si es OTRO).
--     Y como fn_actividad_instrumento_assert ya acepta OTRO+metodo (V240),
--     estas 3 funciones YA califican correctamente una actividad OTRO con
--     metodo configurado sin cambios -- no hay rama "OTRO manual" en ellas
--     que corregir. No requieren cambios.
--   * fn_actividad_estudiantes_calificaciones_listar (V227) -- devuelve el
--     VALOR crudo del instrumento (columna `instrumento`) y la CALIFICACION
--     ya guardada en TACTIVIDAD_NOTA; no decide que INPUT pedirle al front
--     por instrumento (esa decision la toma el cliente al abrir el detalle,
--     via fn_actividad_instrumento_obtener/fn_actividad_nota_obtener), asi
--     que no tiene el patron de este archivo. No requiere cambios.
--
-- -------------------------------------------------------------------------
-- Depende de (orden de version de Flyway):
--   * V227 — fn_actividad_estudiante_actividad, fn_actividad_nota_calificar_
--            rubrica/_cotejo/_escala/_otro, fn_actividad_nota_calificar
--            (fachada), fn_actividad_nota_obtener.
--   * V240 — TACTIVIDAD_OTRO.FK_TLV_METODO_VALORACION,
--            fn_actividad_instrumento_assert ampliada para aceptar OTRO+
--            metodo como equivalente al instrumento estructurado.
--
-- Estilo: V227 (fachada por instrumento, JSONB entrada/salida,
-- COMMENT ON FUNCTION) y V240 (duplicar el bloque JSONB de RUBRICA/
-- LISTA_COTEJO/ESCALA_VALORACION dentro de la rama OTRO en vez de reescribir
-- el CASE por funcion SQL).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ===========================================================================
-- (1) fn_actividad_otro_metodo_valoracion — VALOR del metodo de valoracion
-- configurado (TACTIVIDAD_OTRO.FK_TLV_METODO_VALORACION), NULL si la
-- actividad no tiene fila activa en TACTIVIDAD_OTRO (instrumento distinto de
-- OTRO, o OTRO sin fn_actividad_otro_definir todavia).
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_otro_metodo_valoracion(
    p_pk_tactividad BIGINT
)
RETURNS VARCHAR
LANGUAGE sql
STABLE
AS $$
    SELECT lvm.VALOR
      FROM academico_test.TACTIVIDAD_OTRO o
      JOIN academico_test.TLISTA_VALOR lvm ON lvm.PK_LISTA_VALOR = o.FK_TLV_METODO_VALORACION
     WHERE o.FK_TACTIVIDAD = p_pk_tactividad
       AND o.ACTIVE = TRUE;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_otro_metodo_valoracion(BIGINT)
    IS 'VALOR (RUBRICA | LISTA_COTEJO | ESCALA_VALORACION) del metodo de valoracion configurado para el instrumento OTRO de una actividad, via TACTIVIDAD_OTRO.FK_TLV_METODO_VALORACION (V240). NULL si la actividad no tiene fila ACTIVA en TACTIVIDAD_OTRO (instrumento distinto de OTRO, o OTRO sin fn_actividad_otro_definir todavia). Helper compartido por fn_actividad_nota_calificar (fachada) y fn_actividad_nota_obtener, evita repetir el JOIN TACTIVIDAD_OTRO->TLISTA_VALOR. V241.';

-- ===========================================================================
-- (2) fn_actividad_nota_calificar — CREATE OR REPLACE: la rama OTRO ahora
-- delega en el instrumento estructurado equivalente cuando hay metodo
-- configurado. Ver cabecera.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar(
    p_pk_usuario_solicitante    BIGINT,
    p_pk_tactividad_estudiante  BIGINT,
    p_calificacion               JSONB,
    p_fecha                      DATE DEFAULT CURRENT_DATE
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_tactividad BIGINT;
    v_valor         VARCHAR;
    v_metodo_otro   VARCHAR;
    v_pct           NUMERIC(5,2);
BEGIN
    -- Resolucion UNICA de la actividad (V227): las funciones de calculo
    -- llaman al mismo helper, que revalida en O(1) por PK.
    v_pk_tactividad := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);

    SELECT lv.VALOR INTO v_valor
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
     WHERE a.PK_TACTIVIDAD = v_pk_tactividad;

    IF p_calificacion IS NULL OR jsonb_typeof(p_calificacion) <> 'object' THEN
        RAISE EXCEPTION 'p_calificacion debe ser un objeto JSON' USING ERRCODE = '22023';
    END IF;

    -- V241: OTRO con metodo de valoracion configurado (V240) se califica
    -- IGUAL que el instrumento estructurado equivalente -- se sustituye
    -- v_valor por el metodo resuelto y se deja caer al mismo CASE de abajo
    -- (mismo parseo de p_calificacion, mismas funciones destino). OTRO sin
    -- metodo configurado (fn_actividad_otro_metodo_valoracion devuelve NULL)
    -- mantiene el flujo manual original: {porcentaje}.
    IF v_valor = 'OTRO' THEN
        v_metodo_otro := academico_test.fn_actividad_otro_metodo_valoracion(v_pk_tactividad);
        IF v_metodo_otro IS NOT NULL THEN
            v_valor := v_metodo_otro;
        END IF;
    END IF;

    CASE v_valor
        WHEN 'RUBRICA' THEN
            v_pct := academico_test.fn_actividad_nota_calificar_rubrica(
                         p_pk_usuario_solicitante, p_pk_tactividad_estudiante, p_calificacion->'niveles', p_fecha);
        WHEN 'LISTA_COTEJO' THEN
            v_pct := academico_test.fn_actividad_nota_calificar_cotejo(
                         p_pk_usuario_solicitante, p_pk_tactividad_estudiante,
                         ARRAY(SELECT jsonb_array_elements_text(COALESCE(p_calificacion->'itemsMarcados', '[]'::jsonb))::BIGINT),
                         p_fecha);
        WHEN 'ESCALA_VALORACION' THEN
            v_pct := academico_test.fn_actividad_nota_calificar_escala(
                         p_pk_usuario_solicitante, p_pk_tactividad_estudiante,
                         (p_calificacion->>'pkNivel')::BIGINT, (p_calificacion->>'valorNumerico')::NUMERIC, p_fecha);
        WHEN 'OTRO' THEN
            v_pct := academico_test.fn_actividad_nota_calificar_otro(
                         p_pk_usuario_solicitante, p_pk_tactividad_estudiante,
                         (p_calificacion->>'porcentaje')::NUMERIC, p_fecha);
        ELSE
            RAISE EXCEPTION 'La actividad no tiene un instrumento de evaluacion valido para calificar (%)',
                COALESCE(v_valor, 'sin instrumento') USING ERRCODE = '22023';
    END CASE;

    RETURN v_pct;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar(BIGINT, BIGINT, JSONB, DATE)
    IS 'Fachada: lee el instrumento de la actividad (via TACTIVIDAD_ESTUDIANTE.FK_TACTIVIDAD) y despacha a fn_actividad_nota_calificar_rubrica ({niveles:[{pkCriterio,pkNivel}]}), _cotejo ({itemsMarcados:[pk,...]}), _escala ({pkNivel} o {valorNumerico}) u _otro ({porcentaje}), pasando p_fecha (DEFAULT CURRENT_DATE, el dia de clase que se califica; el gate de asistencia se aplica contra ella). V241: si el instrumento es OTRO y tiene un metodo de valoracion configurado (fn_actividad_otro_metodo_valoracion, TACTIVIDAD_OTRO.FK_TLV_METODO_VALORACION de V240), se despacha al instrumento estructurado equivalente (RUBRICA/LISTA_COTEJO/ESCALA_VALORACION) con el MISMO parseo de p_calificacion -- calcula la nota a partir de la estructura definida, en vez de aceptar un porcentaje manual. OTRO SIN metodo configurado mantiene el flujo manual original ({porcentaje}). Calcula (salvo OTRO sin metodo) y guarda el % (0-100) en TACTIVIDAD_NOTA.CALIFICACION. Gate EDITAR sobre PLANEADOR (via las funciones destino). V227/V241.';

-- ===========================================================================
-- (3) fn_actividad_nota_obtener — CREATE OR REPLACE: el detalle de captura
-- de OTRO con metodo configurado reutiliza el mismo armado JSONB que
-- RUBRICA/LISTA_COTEJO/ESCALA_VALORACION (mismo patron de V240 en
-- fn_actividad_instrumento_obtener). Antes de V241 esta rama siempre volvia
-- NULL porque nunca habia filas de captura reales para una actividad OTRO
-- (la fachada nunca las escribia); con (2) si las hay.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_obtener(
    p_pk_usuario_solicitante    BIGINT,
    p_pk_tactividad_estudiante  BIGINT
)
RETURNS TABLE (
    instrumento         VARCHAR,
    calificacion        NUMERIC,
    calificable         CHAR(1),
    observacion         VARCHAR,
    detalle             JSONB
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TACTIVIDAD_ESTUDIANTE
         WHERE PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se encontro la asignacion actividad-estudiante solicitada' USING ERRCODE = 'P0002';
    END IF;

    RETURN QUERY
    SELECT lv.VALOR,
           n.CALIFICACION,
           n.CALIFICABLE,
           n.OBSERVACION,
           CASE lv.VALOR
               WHEN 'RUBRICA' THEN COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'pkCriterio',  re.FK_TACTIVIDAD_RUBRICA_CRITERIO,
                              'pkNivel',     re.FK_TACTIVIDAD_RUBRICA_NIVEL,
                              'ponderacion', re.PONDERACION))
                     FROM academico_test.TACTIVIDAD_RUBRICA_EVALUACION re
                     JOIN academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
                       ON c.PK_TACTIVIDAD_RUBRICA_CRITERIO = re.FK_TACTIVIDAD_RUBRICA_CRITERIO
                    WHERE re.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                      AND re.ACTIVE = TRUE AND c.FK_TACTIVIDAD = a.PK_TACTIVIDAD
               ), '[]'::jsonb)

               WHEN 'LISTA_COTEJO' THEN COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'pkItem',   ce.FK_TACTIVIDAD_COTEJO_ITEM,
                              'cumplido', ce.CUMPLIDO))
                     FROM academico_test.TACTIVIDAD_COTEJO_EVALUACION ce
                     JOIN academico_test.TACTIVIDAD_COTEJO_ITEM i
                       ON i.PK_TACTIVIDAD_COTEJO_ITEM = ce.FK_TACTIVIDAD_COTEJO_ITEM
                    WHERE ce.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                      AND ce.ACTIVE = TRUE AND i.FK_TACTIVIDAD = a.PK_TACTIVIDAD
               ), '[]'::jsonb)

               WHEN 'ESCALA_VALORACION' THEN (
                   SELECT jsonb_build_object(
                              'pkNivel',      ee.FK_TACTIVIDAD_ESCALA_NIVEL,
                              'valor',        ee.VALOR,
                              'ponderacion',  ee.PONDERACION)
                     FROM academico_test.TACTIVIDAD_ESCALA_EVALUACION ee
                     JOIN academico_test.TACTIVIDAD_ESCALA e ON e.PK_TACTIVIDAD_ESCALA = ee.FK_TACTIVIDAD_ESCALA
                    WHERE ee.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                      AND ee.ACTIVE = TRUE AND e.FK_TACTIVIDAD = a.PK_TACTIVIDAD
               )

               -- V241: OTRO con metodo configurado reutiliza el MISMO armado
               -- JSONB que su instrumento equivalente (mismo patron que V240
               -- uso en fn_actividad_instrumento_obtener para la definicion).
               WHEN 'OTRO' THEN (
                   CASE academico_test.fn_actividad_otro_metodo_valoracion(a.PK_TACTIVIDAD)
                       WHEN 'RUBRICA' THEN COALESCE((
                           SELECT jsonb_agg(jsonb_build_object(
                                      'pkCriterio',  re.FK_TACTIVIDAD_RUBRICA_CRITERIO,
                                      'pkNivel',     re.FK_TACTIVIDAD_RUBRICA_NIVEL,
                                      'ponderacion', re.PONDERACION))
                             FROM academico_test.TACTIVIDAD_RUBRICA_EVALUACION re
                             JOIN academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
                               ON c.PK_TACTIVIDAD_RUBRICA_CRITERIO = re.FK_TACTIVIDAD_RUBRICA_CRITERIO
                            WHERE re.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                              AND re.ACTIVE = TRUE AND c.FK_TACTIVIDAD = a.PK_TACTIVIDAD
                       ), '[]'::jsonb)

                       WHEN 'LISTA_COTEJO' THEN COALESCE((
                           SELECT jsonb_agg(jsonb_build_object(
                                      'pkItem',   ce.FK_TACTIVIDAD_COTEJO_ITEM,
                                      'cumplido', ce.CUMPLIDO))
                             FROM academico_test.TACTIVIDAD_COTEJO_EVALUACION ce
                             JOIN academico_test.TACTIVIDAD_COTEJO_ITEM i
                               ON i.PK_TACTIVIDAD_COTEJO_ITEM = ce.FK_TACTIVIDAD_COTEJO_ITEM
                            WHERE ce.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                              AND ce.ACTIVE = TRUE AND i.FK_TACTIVIDAD = a.PK_TACTIVIDAD
                       ), '[]'::jsonb)

                       WHEN 'ESCALA_VALORACION' THEN (
                           SELECT jsonb_build_object(
                                      'pkNivel',      ee.FK_TACTIVIDAD_ESCALA_NIVEL,
                                      'valor',        ee.VALOR,
                                      'ponderacion',  ee.PONDERACION)
                             FROM academico_test.TACTIVIDAD_ESCALA_EVALUACION ee
                             JOIN academico_test.TACTIVIDAD_ESCALA e ON e.PK_TACTIVIDAD_ESCALA = ee.FK_TACTIVIDAD_ESCALA
                            WHERE ee.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                              AND ee.ACTIVE = TRUE AND e.FK_TACTIVIDAD = a.PK_TACTIVIDAD
                       )

                       ELSE NULL  -- OTRO sin metodo configurado: sin captura estructurada
                   END
               )

               ELSE NULL
           END
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
      JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = ae.FK_TACTIVIDAD
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
      LEFT JOIN academico_test.TACTIVIDAD_NOTA n
             ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE AND n.ACTIVE = TRUE
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_obtener(BIGINT, BIGINT)
    IS 'Lee la nota de un estudiante para una actividad: instrumento aplicado, CALIFICACION (porcentaje 0-100, SIN homologar a la escala visual del periodo/asignatura — eso es responsabilidad de la capa de lectura/reporte existente, ver cabecera de V227), CALIFICABLE, OBSERVACION y el detalle de captura segun el instrumento (RUBRICA: [{pkCriterio,pkNivel,ponderacion}]; LISTA_COTEJO: [{pkItem,cumplido}]; ESCALA_VALORACION: {pkNivel,valor,ponderacion}; OTRO: si tiene metodo de valoracion configurado (fn_actividad_otro_metodo_valoracion, V240) reutiliza el MISMO formato de detalle de ese metodo (V241); OTRO sin metodo configurado: NULL). Gate VER sobre PLANEADOR. Es el DETALLE de UN estudiante; para la tabla completa de la pantalla use fn_actividad_estudiantes_calificaciones_listar. V227/V241.';
