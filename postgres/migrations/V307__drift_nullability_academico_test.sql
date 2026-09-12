-- ===========================================================================
-- V307 - relaja cuatro NOT NULL heredados del DDL de Oracle que ninguna
--        funcion respeta. Sin esto, crear un area/asignatura falla con
--        "Falta el campo obligatorio 'abreviacion'" aunque el campo venga
--        relleno.
--
-- EL SINTOMA QUE LO DESTAPO
--   En la pantalla "Agregar area/asignatura", con la abreviacion escrita
--   ("DIM"), guardar respondia:
--
--       Falta el campo obligatorio 'abreviacion'
--
--   El mensaje es correcto pero enganoso: no lo genera ninguna validacion de
--   negocio, sino SqlErrorSanitizer traduciendo una violacion NOT NULL cruda
--   de Postgres -- el mismo patron que V192 documento para
--   tfuncionario.fk_tmunicipio_expedicion.
--
--   La abreviacion SI viaja, pero no va a la columna que el usuario cree.
--   fn_subject_crear la guarda en CODIGO:
--
--       INSERT INTO academico_test.TASIGNATURA
--           (CODIGO, NOMBRE, FK_TAREA, FK_TAREA_ASIGNATURA, FK_TENFASIS,
--            COLOR, ORDEN_REPORTE, CREATED_BY)
--       VALUES (p_abreviacion, ...)
--
--   ABREVIACION no aparece en ese INSERT -- ni en el de
--   fn_subject_guardar_bulk, que son las dos unicas funciones que insertan
--   en TASIGNATURA. La columna es vestigial: existe en el DDL, nadie la
--   escribe, y en produccion es NOT NULL. Toda alta falla.
--
-- COMO SE ELIGIERON ESTAS CUATRO
--   Se comparo la nullability de las 2039 columnas de academico_test entre
--   produccion y el servidor de pruebas (el entorno funcional). Nueve
--   difieren. Se relajan solo aquellas donde el servidor de pruebas tiene
--   filas reales con NULL, es decir donde el NOT NULL de produccion es
--   demostrablemente incorrecto -- no una diferencia teorica:
--
--       tusuario.fk_tlv_genero .............. 66.707 NULL de 149.847
--       tasignatura.abreviacion .................. 44 NULL de   3.606
--       tarea.abreviacion ........................ 34 NULL de   2.358
--       tescala_valoracion.limite_promedio ........ 3 NULL de      91
--
--   tusuario.fk_tlv_genero es el mas grave por volumen: el 45% de los
--   usuarios del entorno funcional no tiene genero. Con la columna NOT NULL,
--   en produccion no se puede registrar a ninguno de ellos. Encaja con el
--   trabajo que volvio opcionales fechaNacimiento, tipo de documento y
--   genero en RegisterUsuarioRequest: el request se relajo, la columna no.
--
-- QUE NO SE TOCA, Y POR QUE
--   Estas tres tambien difieren, pero en el servidor de pruebas NO hay
--   ninguna fila con NULL, asi que el NOT NULL de produccion no esta
--   rompiendo nada hoy. Relajar una restriccion sin necesidad es debilitar
--   el esquema a cambio de nada:
--
--       tescala_valoracion.limite_inferior     0 NULL de 91
--       tescala_valoracion.limite_superior     0 NULL de 91
--       tsede_usuario.fk_trol                  0 NULL de 148.386
--
--   Y estas dos van al reves -- pruebas es MAS estricto que produccion --
--   asi que alinearlas significaria ENDURECER produccion, donde ya hay una
--   fila con cada valor en NULL. No se puede sin limpiar datos primero:
--
--       testablecimiento.codigo    prod NULL permitido, 1 fila NULL
--       testablecimiento.nit       prod NULL permitido, 1 fila NULL
--
--   Queda ademas anotado que trol_menu.fk_tplan existe SOLO en produccion.
--   Es una columna de mas, no una diferencia de nullability, y merece
--   revisarse aparte.
--
-- POR QUE DROP NOT NULL Y NO ARREGLAR LAS FUNCIONES
--   Para abreviacion se podria pensar en hacer que las funciones escriban la
--   columna. Pero la abreviacion ya se guarda -- en CODIGO -- y ahi la leen
--   los listados y las validaciones de duplicados
--   (fn_subject_crear compara UPPER(TRIM(s.CODIGO)) contra la abreviacion
--   entrante). Escribir ademas ABREVIACION crearia dos fuentes para el mismo
--   dato, que es peor que una columna vestigial. Lo correcto es que la
--   columna admita NULL mientras nadie la use.
--
-- ALCANCE
--   Relaja restricciones, no las impone: ninguna fila existente queda
--   invalida y no hace falta backfill. Idempotente: cada ALTER solo se
--   ejecuta si la columna sigue siendo NOT NULL.
-- ===========================================================================

DO $$
DECLARE
    r        RECORD;
    v_total  INT := 0;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            ('tarea',              'abreviacion'),
            ('tasignatura',        'abreviacion'),
            ('tescala_valoracion', 'limite_promedio'),
            ('tusuario',           'fk_tlv_genero')
        ) AS t(tabla, columna)
    LOOP
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'academico_test'
               AND table_name   = r.tabla
               AND column_name  = r.columna
               AND is_nullable  = 'NO'
        ) THEN
            EXECUTE format('ALTER TABLE academico_test.%I ALTER COLUMN %I DROP NOT NULL',
                           r.tabla, r.columna);
            v_total := v_total + 1;
            RAISE NOTICE 'V307: academico_test.%.% pasa a NULLABLE', r.tabla, r.columna;
        ELSIF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'academico_test'
               AND table_name   = r.tabla
               AND column_name  = r.columna
        ) THEN
            RAISE WARNING 'V307: no existe academico_test.%.% -- se ignora', r.tabla, r.columna;
        END IF;
    END LOOP;

    RAISE NOTICE 'V307: columnas relajadas = % (0 = el entorno ya estaba alineado)', v_total;
END $$;

COMMENT ON COLUMN academico_test.TASIGNATURA.ABREVIACION IS
    'Vestigial (V307): ninguna funcion la escribe. La abreviacion real de la asignatura vive en CODIGO, que es donde la guarda fn_subject_crear y contra la que valida duplicados. NULLABLE mientras siga sin usarse.';

COMMENT ON COLUMN academico_test.TAREA.ABREVIACION IS
    'Vestigial (V307): misma situacion que TASIGNATURA.ABREVIACION -- la abreviacion del area se guarda en CODIGO.';
