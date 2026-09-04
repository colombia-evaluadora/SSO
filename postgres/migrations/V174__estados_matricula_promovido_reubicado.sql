-- =============================================================================
-- V174 -- Agrega al catalogo los dos estados de matricula que faltaban para el
-- juego de estados de la nueva version de la app:
--
--     Cursando   -- ya existia (VALOR '1')
--     Aprobado   -- ya existia (VALOR '2')
--     Reprobado  -- ya existia (VALOR '3')
--     Promovido  -- NUEVO, VALOR '13'
--     Reubicado  -- NUEVO, VALOR '14'
--     Retirado   -- ya existia (VALOR '4')
--
-- "Promovido" es distinto de "Promovido Anticipadamente" (VALOR '6', 6
-- matriculas activas heredadas): la nueva app NO usa el anticipado, asi que se
-- crea un estado propio en vez de reutilizar aquel. Ninguno de los dos se
-- desactiva aca -- los estados heredados (Graduado, Trasladado, Desertor,
-- Esperando Aprobacion, Rechazado, Sin definir, Promovido Anticipadamente)
-- siguen activos hasta que el negocio decida cuales conserva; hay matriculas
-- vivas apuntando a varios de ellos y desactivarlos ahora las dejaria
-- huerfanas de etiqueta.
--
-- Sobre los VALOR elegidos: se continua la numeracion despues del maximo
-- existente ('12' Rechazado) en vez de rellenar el unico hueco ('8'). Un hueco
-- en un catalogo migrado normalmente significa que ese codigo YA tuvo un
-- significado en el sistema de origen; reusarlo puede colisionar con datos o
-- reportes historicos. Numerar hacia adelante no tiene ese riesgo.
--
-- Los VALOR son el codigo de negocio estable y es por ahi que los resuelven
-- las funciones (fn_matricula_reactivar y las demas); los PK_LISTA_VALOR salen
-- de una secuencia y difieren entre ambientes, por eso nunca se hardcodean.
--
-- Idempotente: el INSERT no hace nada si la (CATEGORIA, VALOR) ya existe, que
-- es ademas lo que exige el indice unico parcial
-- tlista_valor_categoria_valor_key (categoria, valor) WHERE active.
-- =============================================================================

INSERT INTO academico_test.TLISTA_VALOR (CATEGORIA, NOMBRE, VALOR, CREATED_BY)
SELECT v.categoria, v.nombre, v.valor, 'V174_seed'
  FROM (VALUES
    ('ESTADO_MATRICULA'::VARCHAR, 'Promovido'::VARCHAR, '13'::VARCHAR),
    ('ESTADO_MATRICULA'::VARCHAR, 'Reubicado'::VARCHAR, '14'::VARCHAR)
  ) AS v(categoria, nombre, valor)
 WHERE NOT EXISTS (
       SELECT 1 FROM academico_test.TLISTA_VALOR lv
        WHERE lv.CATEGORIA = v.categoria AND lv.VALOR = v.valor
   );
