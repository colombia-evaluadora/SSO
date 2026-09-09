-- ===========================================================================
-- V280 — Planeador: repara TUNIDAD -- la relacion con el referente curricular
-- de las unidades ya creadas, y la unicidad de su nombre (CU-86e311xxp).
--
-- V216 ya corrige las CAUSAS (fn_unidad_crear deriva el referente del grado
-- cuando el cliente no lo manda, y crear/editar exigen que el referente
-- aplique al nivel del grado y este ACTIVE + ESTADO='A'). Esta migracion
-- arregla las FILAS que se escribieron antes de eso.
--
-- LO QUE SE ENCONTRO EN EL SERVIDOR DE TEST (revisando la pantalla real del
-- Planeador con el usuario docente):
--
--   1. Unidades SIN referente. Las creadas desde la UI (60, 61, 62) tenian
--      FK_REFERENTE_CURRICULAR NULL, porque el front no lo mandaba y nadie lo
--      derivaba. Consecuencia visible: GET /planeador/unidades/:ID/referente
--      devolvia todo NULL y la pantalla no podia rotular los niveles, ni
--      decidir si hay seccion de evaluacion, ni ofrecer enunciados que marcar.
--
--   2. Unidades apuntando a un referente MUERTO. Las 12, 13, 14 y 15
--      apuntaban a los referentes 11 y 12, ambos con ACTIVE = false. El
--      detalle (V255) devolvia NULL mientras el listado mostraba el nombre
--      del referente desactivado: dos endpoints contradiciendose sobre la
--      misma unidad.
--
-- COMO SE REPARA: a cada unidad activa cuyo referente esta NULL, o ya no
-- resuelve (ACTIVE=false / ESTADO='I'), o no aplica al nivel educativo de su
-- grado, se le pone el que le CORRESPONDE segun fn_unidad_referente_aplicable
-- -- la misma regla que usa la creacion y que expone
-- GET /planeador/referente-curricular. Si no hay ninguno aplicable se deja
-- como esta: NULL es legitimo cuando el grado no tiene referente cargado, y
-- machacar una FK por otra igual de invalida no aporta nada.
--
-- -------------------------------------------------------------------------
-- LOS ENUNCIADOS RELACIONADOS TAMBIEN HAY QUE TOCARLOS
--
-- TUNIDAD_ENUNCIADO guarda que enunciados del referente marco la unidad. Los
-- de las unidades 12-15 son enunciados del referente 11 (el muerto). Si se
-- cambia el referente de la unidad y se dejan, quedan relaciones a enunciados
-- de un referente que la unidad ya no usa: el arbol de V255 no los muestra
-- (solo recorre el referente vigente) pero siguen ahi, y las evidencias de
-- actividad cuelgan de ellos (V136 exige que el enunciado padre este
-- relacionado con la unidad). Es decir: invisibles pero con efectos.
--
-- Asi que se desactivan (borrado logico, no DELETE) los TUNIDAD_ENUNCIADO
-- cuyo enunciado NO pertenece al referente que la unidad tiene despues de la
-- reparacion. No se intenta "traducirlos" al referente nuevo: no existe
-- correspondencia entre enunciados de referentes distintos, y adivinarla
-- seria inventar contenido pedagogico. El docente vuelve a marcar los
-- enunciados que apliquen, ahora sobre el arbol correcto.
--
-- Idempotente: al segundo pase no hay nada que cumpla las condiciones.
--
-- Depende de: V216 (fn_unidad_referente_aplicable), V136 (TUNIDAD_ENUNCIADO),
-- V212 (TREFERENTE_CURRICULAR*, rama CU-86e311xqh).
-- ===========================================================================

SET search_path TO academico_test, public;

DO $$
DECLARE
    v_unidades INT;
    v_enunc    INT;
    v_pendientes INT;
BEGIN
    -- 1) Unidades reparadas (idempotente: en el segundo pase no queda ninguna).
    WITH reparar AS (
        SELECT u.PK_TUNIDAD,
               academico_test.fn_unidad_referente_aplicable(
                   u.FK_TGRADO, u.FK_TASIGNATURA) AS despues
          FROM academico_test.TUNIDAD u
         WHERE u.ACTIVE = TRUE
           AND NOT EXISTS (
                 SELECT 1
                   FROM academico_test.TREFERENTE_CURRICULAR rc
                   JOIN academico_test.TREFERENTE_CURRICULAR_NIVEL rcn
                         ON rcn.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                        AND rcn.ACTIVE = TRUE
                   JOIN academico_test.TGRADO g ON g.PK_TGRADO = u.FK_TGRADO
                  WHERE rc.PK_REFERENTE_CURRICULAR = u.FK_REFERENTE_CURRICULAR
                    AND rc.ACTIVE = TRUE
                    AND rc.ESTADO = 'A'
                    AND rcn.FK_TNIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
               )
    ), aplicadas AS (
        UPDATE academico_test.TUNIDAD u
           SET FK_REFERENTE_CURRICULAR = r.despues,
               MODIFIED_BY = 'V280_reparacion',
               MODIFIED_AT = CURRENT_TIMESTAMP
          FROM reparar r
         WHERE u.PK_TUNIDAD = r.PK_TUNIDAD
           AND r.despues IS NOT NULL
        RETURNING u.PK_TUNIDAD
    )
    SELECT COUNT(*) INTO v_unidades FROM aplicadas;

    -- 2) Enunciados marcados que ya no son del referente de su unidad.
    WITH sueltos AS (
        UPDATE academico_test.TUNIDAD_ENUNCIADO ue
           SET ACTIVE = FALSE,
               MODIFIED_BY = 'V280_reparacion',
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE ue.ACTIVE = TRUE
           AND NOT EXISTS (
                 SELECT 1
                   FROM academico_test.TREFERENTE_ENUNCIADO en
                   JOIN academico_test.TUNIDAD u ON u.PK_TUNIDAD = ue.FK_TUNIDAD
                  WHERE en.PK_REFERENTE_ENUNCIADO = ue.FK_REFERENTE_ENUNCIADO
                    AND en.FK_REFERENTE_CURRICULAR = u.FK_REFERENTE_CURRICULAR
               )
        RETURNING ue.PK_TUNIDAD_ENUNCIADO
    )
    SELECT COUNT(*) INTO v_enunc FROM sueltos;

    -- 3) Las que NO se pudieron arreglar: su grado no tiene ningun referente
    --    aplicable. No es un fallo de la migracion; es catalogo que falta.
    SELECT COUNT(*) INTO v_pendientes
      FROM academico_test.TUNIDAD u
     WHERE u.ACTIVE = TRUE
       AND u.FK_REFERENTE_CURRICULAR IS NULL
       AND academico_test.fn_unidad_referente_aplicable(
               u.FK_TGRADO, u.FK_TASIGNATURA) IS NULL;

    RAISE NOTICE 'V280: % unidades re-apuntadas al referente que les corresponde, % enunciados marcados desactivados por no pertenecer a ese referente, % unidades siguen sin referente porque su grado no tiene ninguno aplicable (falta cargarlo en el catalogo).',
        v_unidades, v_enunc, v_pendientes;
END $$;

-- ===========================================================================
-- (3) un_tunidad_1 pasa a indice PARCIAL (WHERE active = true).
--
-- SINTOMA: borrar una unidad quemaba su nombre para siempre. Re-crear una
-- unidad con el mismo (nombre, asignatura, grado) que una ya borrada respondia
-- 409 con el mensaje GENERICO del motor
--     "Ya existe un registro con el mismo valor en 'nombre, asignatura, grado'"
-- en vez del mensaje propio de la funcion. Comprobado contra el servidor de
-- test, donde hay 17 unidades borradas ocupando su combinacion.
--
-- CAUSA: fn_unidad_crear si comprueba la unicidad solo entre unidades ACTIVAS
-- (WHERE ... AND ACTIVE = TRUE), que es la intencion de negocio de todo el
-- esquema de soft-delete. Pero el indice un_tunidad_1 es un UNIQUE plano y
-- salta ANTES de que la funcion pueda dar su error, sobre filas que para el
-- negocio ya no existen.
--
-- POR QUE NO SE ARREGLA EN V71, QUE ES DONDE DEBERIA ESTAR: V71 ya convirtio
-- este mismo indice a parcial (linea "un_tunidad_1 ... WHERE active = true"),
-- pero con las CUATRO columnas que tenia entonces
-- (nombre, fk_tasignatura, fk_tgrado, fk_tperiodo_evaluacion). Despues V218
-- --que vive en la rama CU-86e329pvq-- quito FK_TPERIODO_EVALUACION de TUNIDAD
-- y recreo el indice con tres columnas, esta vez SIN el predicado, deshaciendo
-- el arreglo. Volver a tocarlo en V71 no serviria: V218 corre despues y lo
-- pisaria otra vez. Por eso va aqui, en la migracion de reparacion de TUNIDAD
-- de esta rama, que corre despues de V218.
--
-- Mismo patron que V65/V71 aplicaron a las otras 84 restricciones de
-- academico_test, y con la misma perdida intencional del DEFERRABLE: Postgres
-- no permite respaldar un constraint deferrable con un indice parcial.
--
-- Idempotente: DROP ... IF EXISTS de las dos formas (constraint e indice) y
-- CREATE ... IF NOT EXISTS.
-- ===========================================================================

-- Puede existir como constraint (V22/V218) o como indice suelto: se sueltan
-- las dos formas, porque DROP CONSTRAINT no elimina un indice que no respalda
-- ningun constraint y DROP INDEX no puede eliminar el que si lo respalda.
ALTER TABLE academico_test.TUNIDAD DROP CONSTRAINT IF EXISTS un_tunidad_1;
DROP INDEX IF EXISTS academico_test.un_tunidad_1;

CREATE UNIQUE INDEX IF NOT EXISTS un_tunidad_1
    ON academico_test.TUNIDAD (nombre, fk_tasignatura, fk_tgrado)
 WHERE active = true;

COMMENT ON INDEX academico_test.un_tunidad_1
    IS 'Unicidad de (NOMBRE, FK_TASIGNATURA, FK_TGRADO) solo entre unidades ACTIVAS. Parcial a proposito (patron de V65/V71): con un UNIQUE plano, una unidad borrada seguia ocupando su nombre y re-crearla daba 409 con el mensaje generico del motor, tapando el de fn_unidad_crear -- que ya comprobaba la unicidad solo entre activas. V218 lo habia dejado sin el predicado al recrearlo con tres columnas; se restaura aqui porque V218 corre despues de V71. Pierde el DEFERRABLE original: Postgres no respalda constraints deferrables con indices parciales. V280.';
