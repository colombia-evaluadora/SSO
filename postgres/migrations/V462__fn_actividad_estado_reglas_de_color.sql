-- ===========================================================================
-- V462 -- fn_actividad_estado: los cuatro estados segun las reglas de color.
-- Que hace: EN_EVALUACION (azul) pasa a ser "el plazo aun no se cumplio" --
--   de hoy en adelante, incluidas la actividad que no empieza todavia y la
--   que no tiene cierre --; PENDIENTE_POR_EVALUAR (amarillo) es la gracia de
--   1-2 dias tras el cierre y VENCIDA (rojo) los 3 o mas. Verde no cambia.
-- Por que aqui: V224 exigia ademas hoy >= FECHA_INICIO, asi que una actividad
--   programada a futuro salia amarilla sin que su plazo hubiera vencido.
--   Migracion nueva y no edicion de V224 para no re-ejecutar ese fichero y
--   sus arrastres, igual que hizo V454 sobre estas mismas funciones.
-- Depende de: V224 (definicion original).
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_estado(
    p_fecha_inicio      DATE,
    p_fecha_cierre      DATE,
    p_fecha_calificado  DATE,
    p_hoy               DATE,
    p_dias_gracia       INT DEFAULT 2
)
RETURNS VARCHAR
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT CASE
        -- Verde gana sobre cualquier fecha: una actividad calificada tarde
        -- no se pinta vencida. FECHA_CALIFICADO = 100% evaluada (V224).
        WHEN p_fecha_calificado IS NOT NULL                          THEN 'FINALIZADA'
        -- Azul: sin cierre no hay plazo que vencer, y que hoy < FECHA_INICIO
        -- no vuelve pendiente de evaluar a una actividad que no ha empezado.
        WHEN p_fecha_cierre IS NULL OR p_hoy <= p_fecha_cierre       THEN 'EN_EVALUACION'
        WHEN p_hoy > p_fecha_cierre + COALESCE(p_dias_gracia, 2)     THEN 'VENCIDA'
        ELSE 'PENDIENTE_POR_EVALUAR'
    END::VARCHAR;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_estado(DATE, DATE, DATE, DATE, INT)
    IS 'Estado DERIVADO de una actividad (no hay columna de estado), en los cuatro valores del tablero y con el orden de precedencia de las reglas de color: FINALIZADA/verde (FECHA_CALIFICADO informada, es decir evaluada al 100% segun fn_actividad_finalizacion_refrescar; gana sobre las fechas, una actividad calificada tarde no se pinta vencida) > EN_EVALUACION/azul (el plazo aun no se cumplio: hoy <= FECHA_CIERRE, o no hay FECHA_CIERRE; incluye la actividad programada a futuro que todavia no empieza) > VENCIDA/rojo (3 o mas dias desde el cierre sin evaluar, es decir hoy > cierre + p_dias_gracia con gracia 2) > PENDIENTE_POR_EVALUAR/amarillo (el cierre paso hace 1 o 2 dias y falta calificar). CAMBIO V462 respecto de V224: antes el azul exigia ademas hoy >= FECHA_INICIO y que hubiera al menos una fecha, asi que una actividad programada a futuro -- o sin fechas -- salia amarilla aunque su plazo no hubiera vencido. IMMUTABLE: recibe el "hoy" por parametro. Unica definicion, usada por listar / detalle / calendario / resumen / estado de unidad. V224/V462.';
