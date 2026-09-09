-- ===========================================================================
-- V73 — TUNIDAD: metodo de calculo de la definitiva de la unidad
--
-- Contexto: la pantalla "Unidad tematica" del Planeador (tab "Informacion
-- general") muestra y permite editar "Forma en que se van a calcular las
-- actividades dentro de la unidad" con tres opciones:
--   - Ponderar actividades   (cada actividad tiene un % — TACTIVIDAD.INFLUENCIA)
--   - Promediar actividades   (promedio aritmetico de las actividades)
--   - Sumatoria de actividades (suma de los puntajes)
--
-- Hoy TUNIDAD no tiene donde persistir esa eleccion: TUNIDAD_NOTA asume de
-- forma fija "promedio ponderado por INFLUENCIA", lo que contradice la UI.
--
-- Estas tres opciones ya existen en academico_test.TLISTA_VALOR bajo
-- CATEGORIA='CALCULO_DEFINITIVA' (mismo catalogo que ya consume
-- TASIGNATURA_PLAN.FK_TLV_CALCULO_DEFINITIVA):
--   - Promediar Actividades o descriptores
--   - Ponderar Actividades o Descriptores
--   - Sumatoria de Actividades
-- Este catalogo viene del dump base (no se seedea en migraciones), por lo
-- que esta migracion NO lo re-crea: solo agrega la columna FK en TUNIDAD.
--
--   * academico_test.TUNIDAD gana:
--       - FK_TLV_CALCULO_DEFINITIVA BIGINT, nullable (una unidad sin metodo
--         elegido aun es un estado valido y aplica a todas las filas
--         existentes), FK a TLISTA_VALOR(PK_LISTA_VALOR). Sin ON DELETE
--         porque TLISTA_VALOR usa soft-delete (ACTIVE=FALSE) — mismo patron
--         que TASIGNATURA_PLAN.FK_TLV_CALCULO_DEFINITIVA (V22) y que
--         TROL.FK_TLISTA_VALOR_CATEGORIA (V120).
--       - Nombre de columna identico al de TASIGNATURA_PLAN para que ambos
--         apunten al mismo catalogo con la misma convencion.
--
-- Idempotencia: ADD COLUMN IF NOT EXISTS + CREATE INDEX IF NOT EXISTS.
--
-- Fuera de alcance: el recalculo de TUNIDAD_NOTA segun el metodo elegido
-- (hoy fijo a ponderado) se ajusta en la funcion correspondiente, no aqui:
-- este archivo solo toca el esquema.
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- TUNIDAD.FK_TLV_CALCULO_DEFINITIVA
-- ---------------------------------------------------------------------------
ALTER TABLE academico_test.TUNIDAD
    ADD COLUMN IF NOT EXISTS FK_TLV_CALCULO_DEFINITIVA BIGINT
        REFERENCES academico_test.TLISTA_VALOR (PK_LISTA_VALOR);

CREATE INDEX IF NOT EXISTS IDX_TUNIDAD_FK_TLV_CALCULO_DEFINITIVA
    ON academico_test.TUNIDAD (FK_TLV_CALCULO_DEFINITIVA)
    WHERE FK_TLV_CALCULO_DEFINITIVA IS NOT NULL;

COMMENT ON COLUMN academico_test.TUNIDAD.FK_TLV_CALCULO_DEFINITIVA IS
    'Metodo de calculo de la definitiva de la unidad a partir de sus actividades — TLISTA_VALOR CATEGORIA=''CALCULO_DEFINITIVA'' (Promediar / Ponderar / Sumatoria de Actividades). Nullable (unidad sin metodo elegido aun). Mismo catalogo que TASIGNATURA_PLAN.FK_TLV_CALCULO_DEFINITIVA (V73).';
