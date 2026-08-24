-- =============================================================================
-- V122 — CU-86e2ycwqm: CODIGO de sede unico por establecimiento, no global.
--
-- Contexto: u_tsede_3 (creado en V22 como CONSTRAINT UNIQUE (CODIGO), y
-- convertido a indice parcial `WHERE active = true` por V71) fuerza que
-- CODIGO sea unico entre TODAS las sedes activas del sistema, sin importar
-- el establecimiento. En la practica esa regla ya no refleja los datos:
-- V116 documento codigos compartidos entre sedes de distintos EE en el
-- servidor de test (ej. EE-REUSE-SRV-15891 repetido en 10 sedes).
--
-- Este archivo reemplaza ese indice por uno equivalente pero acotado a
-- (FK_TESTABLECIMIENTO, CODIGO): el mismo CODIGO puede repetirse entre
-- sedes de EE distintos, pero sigue siendo unico dentro de un mismo EE
-- (entre sedes activas). Mismo patron `WHERE active = true` que u_tsede_1/
-- u_tsede_2/u_tsede_3 ya usaban, para que una sede dada de baja no bloquee
-- la reactivacion ni la reasignacion de su CODIGO.
--
-- DROP + CREATE (no ALTER): es un indice, no una tabla — no hay forma de
-- "agregarle una columna" a un indice existente, hay que recrearlo.
-- IF EXISTS / IF NOT EXISTS en ambos lados para que el archivo sea
-- re-ejecutable sin riesgo, igual que el resto de las migraciones del
-- modulo.
--
-- ---------------------------------------------------------------------------
-- Deuda tecnica declarada, NO resuelta en este archivo (fuera de alcance
-- de este ticket): fn_sed_crear y fn_sed_actualizar (V52) validan CODIGO
-- duplicado en la propia funcion ANTES de tocar la tabla —
--     SELECT 1 FROM TSEDE WHERE CODIGO = p_codigo AND ACTIVE = TRUE
-- sin filtrar por FK_TESTABLECIMIENTO (V52__campuse_module.sql, lineas
-- ~253-261 en fn_sed_crear y ~535-544 en fn_sed_actualizar). Ese guard de
-- aplicacion sigue siendo GLOBAL despues de este archivo: seguira
-- rechazando con 23505 un CODIGO reusado entre EE distintos aunque el
-- indice de abajo ya lo permita. Este archivo SOLO cambia el indice —
-- alinear esas dos funciones a la nueva regla (agregar
-- "AND FK_TESTABLECIMIENTO = v_fk_establecimiento" a esos EXISTS) requiere
-- su propio CREATE OR REPLACE FUNCTION y queda para el ticket que toque
-- ese comportamiento de negocio.
-- =============================================================================

SET search_path TO academico_test, public;

DROP INDEX IF EXISTS academico_test.u_tsede_3;

CREATE UNIQUE INDEX IF NOT EXISTS u_tsede_3
    ON academico_test.TSEDE (FK_TESTABLECIMIENTO, CODIGO)
 WHERE ACTIVE = TRUE;

COMMENT ON INDEX academico_test.u_tsede_3
    IS 'CODIGO unico por establecimiento (no global) entre sedes activas. Reemplaza en V122 al u_tsede_3 original (UNIQUE CODIGO solo, heredado de V22/V71), que forzaba unicidad global y ya no reflejaba los datos reales (codigos reusados entre EE distintos, ver V116). fn_sed_crear/fn_sed_actualizar (V52) aun validan CODIGO como global en su propio guard de aplicacion — ver nota en V122__indice_unico_sede_establecimiento_codigo.sql.';
