-- =============================================================================
-- V74 — Catalogo AGRUPACION_PLANILLA en TLISTA_VALOR: por que se agrupa la
-- planilla de calificaciones, por ACTIVIDAD o por UNIDAD.
--
-- Categoria nueva en el catalogo generico, asi que NO hace falta endpoint:
-- GET /api/eval-col/select/AGRUPACION_PLANILLA ya la expone (esa ruta lee
-- academico_test.TLISTA_VALOR por CATEGORIA y CEVAL-DOCENTE ya tiene permiso).
--
-- -----------------------------------------------------------------------------
-- CONVENCION DE VALOR: token en mayusculas, no un consecutivo numerico
--
-- En TLISTA_VALOR conviven dos convenciones. Los catalogos que vienen del dump
-- original usan consecutivos ('1', '2', '3' -- TIPO_ACTIVIDAD,
-- CALCULO_DEFINITIVA, TIPO_JERARQUIA_ACTIVIDAD) y los que nacieron con el
-- Planeador usan el token en mayusculas (ENFOQUE_PEDAGOGICO = EVALUATIVO /
-- FORMATIVO, TIPO_EVALUACION = CUALITATIVA / ...). Esta categoria sigue la
-- segunda, que es la de su modulo: el back compara por VALOR
-- (p.ej. `enf.VALOR = 'EVALUATIVO'` en V278), y un '1' ahi no se puede leer.
--
-- Y compararlo por VALOR y no por PK no es un gusto: los PK_LISTA_VALOR NO son
-- estables entre bases -- la misma categoria tiene ids distintos en el servidor
-- de test y en un Postgres limpio --, asi que cualquier codigo o seed que
-- dependa de estas filas debe resolverlas por (CATEGORIA, VALOR).
--
-- -----------------------------------------------------------------------------
-- POR QUE WHERE NOT EXISTS Y NO ON CONFLICT
--
-- Seria natural apoyarse en la unicidad (CATEGORIA, VALOR), pero esa restriccion
-- CAMBIA DE FORMA a lo largo de la cadena de migraciones: V22 la crea como
-- constraint UNIQUE normal y V71 la convierte en indice PARCIAL
-- (... WHERE ACTIVE = true). Un `ON CONFLICT (CATEGORIA, VALOR)` no infiere el
-- indice parcial, y `ON CONFLICT (CATEGORIA, VALOR) WHERE ACTIVE = TRUE` no
-- infiere la constraint normal: cual de las dos formas funciona depende de si
-- V71 ya corrio. WHERE NOT EXISTS es indiferente a eso y sigue siendo
-- idempotente. Es ademas el patron que ya usan V120 y V165 para sembrar
-- TLISTA_VALOR.
--
-- El NOT EXISTS no filtra por ACTIVE a proposito (igual que V165): si alguien
-- desactivo una de estas filas, reaplicar la migracion no debe resucitarla.
--
-- Depende de: V22 (TLISTA_VALOR).
-- =============================================================================

SET search_path TO academico_test, public;

INSERT INTO academico_test.TLISTA_VALOR (CATEGORIA, NOMBRE, VALOR, CREATED_BY)
SELECT v.categoria, v.nombre, v.valor, 'V74_seed'
  FROM (VALUES
    ('AGRUPACION_PLANILLA'::VARCHAR, 'Actividad'::VARCHAR, 'ACTIVIDAD'::VARCHAR),
    ('AGRUPACION_PLANILLA'::VARCHAR, 'Unidad'::VARCHAR,    'UNIDAD'::VARCHAR)
  ) AS v(categoria, nombre, valor)
 WHERE NOT EXISTS (
       SELECT 1 FROM academico_test.TLISTA_VALOR lv
        WHERE lv.CATEGORIA = v.categoria AND lv.VALOR = v.valor
   );
