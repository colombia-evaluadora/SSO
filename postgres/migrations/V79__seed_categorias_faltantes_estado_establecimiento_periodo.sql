-- V79 — agrega valores de TLISTA_VALOR que la version de produccion de
-- fn_est_crear/fn_periodo_actualizar (traidas en V78) necesitan y que el
-- catalogo local (origin/dev) no tenia en absoluto:
--
--   - ESTADO_ESTABLECIMIENTO: fn_est_crear trae hardcodeado
--     c_fk_lv_estado_activo=533 (el id real en produccion) -- sin esta fila
--     exacta, CUALQUIER llamada a fn_est_crear revienta con violacion de FK,
--     no solo las pruebas.
--   - ZONA (id=216, "Urbana y Rural"): usado por el REV4 de fn_est_crear
--     para la sede por defecto que crea automaticamente.
--   - ESTADOPERIODO: fn_periodo_actualizar valida que FK_TLV_ESTADO
--     pertenezca a esta categoria: el catalogo local no tenia NINGUNA fila
--     de esta categoria (ni siquiera la que ya usaba TPERIODO_ACADEMICO,
--     que apuntaba a un valor de otra categoria por error de seed).
--
-- Se insertan a proposito EN LOS MISMOS IDs que usa produccion (533, 216)
-- via OVERRIDING SYSTEM VALUE cuando el id esta libre, para que el
-- constante hardcodeado de fn_est_crear funcione sin tener que parametrizarla.
-- Para ESTADOPERIODO no hay un id fijo esperado por ninguna funcion (se
-- referencia siempre por PK_LISTA_VALOR guardado en cada TPERIODO_ACADEMICO,
-- no por constante), asi que se deja con id autogenerado.

INSERT INTO academico_test.TLISTA_VALOR (PK_LISTA_VALOR, CATEGORIA, NOMBRE, VALOR, CREATED_BY)
OVERRIDING SYSTEM VALUE
SELECT 533, 'ESTADO_ESTABLECIMIENTO', 'Activo', 'A', 'V79-seed'
WHERE NOT EXISTS (SELECT 1 FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = 533);

INSERT INTO academico_test.TLISTA_VALOR (PK_LISTA_VALOR, CATEGORIA, NOMBRE, VALOR, CREATED_BY)
OVERRIDING SYSTEM VALUE
SELECT 216, 'ZONA', 'Urbana y Rural', 'UR', 'V79-seed'
WHERE NOT EXISTS (SELECT 1 FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = 216);

INSERT INTO academico_test.TLISTA_VALOR (CATEGORIA, NOMBRE, VALOR, CREATED_BY)
SELECT 'ESTADOPERIODO', 'Activo', 'A', 'V79-seed'
WHERE NOT EXISTS (SELECT 1 FROM academico_test.TLISTA_VALOR WHERE CATEGORIA = 'ESTADOPERIODO');

-- Corrige el dato existente: TPERIODO_ACADEMICO.PK=2 (seed local) apuntaba
-- a FK_TLV_ESTADO=1 ("PREESCOLAR", categoria PLAN) -- un valor de la
-- categoria equivocada, posible solo porque la validacion estricta de
-- categoria no existia en la version local de fn_periodo_actualizar antes
-- de V78. Se reapunta al nuevo valor ESTADOPERIODO recien creado.
UPDATE academico_test.TPERIODO_ACADEMICO p
   SET FK_TLV_ESTADO = (SELECT PK_LISTA_VALOR FROM academico_test.TLISTA_VALOR WHERE CATEGORIA = 'ESTADOPERIODO' LIMIT 1)
 WHERE p.PK_TPERIODO_ACADEMICO = 2
   AND EXISTS (
       SELECT 1 FROM academico_test.TLISTA_VALOR lv
        WHERE lv.PK_LISTA_VALOR = p.FK_TLV_ESTADO AND lv.CATEGORIA <> 'ESTADOPERIODO'
   );
