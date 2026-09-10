-- ===========================================================================
-- V192 - academico_test.tfuncionario.fk_tmunicipio_expedicion pasa a ser
--        NULLABLE, tal como V51/V60 ya asumen que es (pero ninguna
--        migracion lo habia hecho realmente).
--
-- POR QUE ESTA MIGRACION EXISTE
--   V22__academic-schema.sql declaro la columna NOT NULL desde el origen
--   (viene 1:1 del DDL de Oracle). V51__employee_module.sql (fn_fun_crear)
--   y V60__add_direccion_and_establecimiento_to_tfuncionario.sql comentan
--   repetidamente "FK_TMUNICIPIO_EXPEDICION ya no es NOT NULL, ver V60+" y
--   dan por hecho que /register/funcionario puede omitirla (fn_fun_crear
--   la deja en DEFAULT NULL a proposito, se completa despues via
--   fn_fun_actualizar). Ese ALTER TABLE nunca existio en ningun archivo de
--   postgres/migrations -- en un servidor sembrado solo por Flyway (sin el
--   dump base de Oracle) la columna sigue NOT NULL, y el primer
--   POST /register/funcionario falla con
--   "Falta el campo obligatorio 'municipio expedicion'" (SqlErrorSanitizer
--   traduciendo una violacion NOT NULL cruda).
--
-- NUMERACION
--   Hueco libre V192, verificado contra TODAS las ramas de origin.
-- ===========================================================================

ALTER TABLE academico_test.tfuncionario
    ALTER COLUMN fk_tmunicipio_expedicion DROP NOT NULL;
