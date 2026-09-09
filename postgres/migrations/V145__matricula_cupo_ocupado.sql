-- =============================================================================
-- V145 -- fn_matricula_cupo_ocupado: cuantas plazas de un grupo estan
-- realmente ocupadas.
--
-- Una sola definicion de "que estado ocupa plaza", porque hay DOS sitios que
-- necesitan la cuenta y con reglas distintas seria cuestion de tiempo que
-- divergieran:
--
--   fn_matricula_validar_cupo  -- el alta: ¿cabe uno mas?  (V205)
--   fn_matricula_mover_lote    -- el movimiento: ¿cabe el lote?  (V178, paso 6)
--
-- Numero bajo y en un hueco libre (137-146 estaban sin usar y sin registrar en
-- flyway_schema_history) para que quede ANTES de V178, que la llama. Asi el
-- orden de Flyway resuelve solo en una base nueva y no hay que confiar en que
-- PL/pgSQL resuelve los nombres al ejecutar.
--
-- -----------------------------------------------------------------------------
-- Que estados ocupan plaza
-- -----------------------------------------------------------------------------
-- Solo tres: Cursando ('1'), Aprobado ('2') y Reprobado ('3'). Son los
-- estados en los que el estudiante SIGUE siendo del grupo -- esta cursando, o
-- termino el año ahi.
--
-- Los demas no ocupan:
--
--   Reubicado ('14') / Promovido ('13')  la matricula quedo atras al
--                                        encadenarse otra; el estudiante ya
--                                        esta en el grupo nuevo, contarlo dos
--                                        veces es contar una persona doble.
--   Retirado ('4')                       no asiste. Sigue siendo su matricula
--                                        en el periodo -- y por eso bloquea un
--                                        movimiento en paralelo, ver V178 --
--                                        pero su silla esta libre.
--   Trasladado, Graduado, Desertor...    la matricula esta cerrada.
--
-- -----------------------------------------------------------------------------
-- Que cambia respecto de antes
-- -----------------------------------------------------------------------------
-- Antes las dos cuentas eran `COUNT(*) WHERE FK_TGRUPO = X AND ACTIVE` -- sin
-- mirar el estado. Se midio lo que eso significaba: **27.988 plazas** ocupadas
-- por matriculas que no estan en Cursando (21.878 Aprobado, 3.542 Retirado,
-- 2.492 Reprobado, 61 Trasladado, y 15 mas), y **170 de 5.332 grupos** dados
-- por llenos cuando contando solo Cursando serian 50.
--
-- Hoy eso casi no muerde: de los **65 grupos de periodos vigentes**, solo 1
-- esta lleno y **ninguno** lo esta por matriculas que no ocupen. Los grupos con
-- muchos Aprobados son de años cerrados, donde nadie matricula. Pero empezara a
-- morder en cuanto exista el aprobar/reprobar de verdad: al cerrar un año los
-- grupos se llenarian de Aprobados, y con la cuenta vieja un Reubicado o un
-- Promovido gastaria una silla que nadie ocupa.
--
-- Aprobado y Reprobado SI cuentan a proposito: son el año terminado en ese
-- grupo, no una matricula que se fue a otro sitio.
--
-- -----------------------------------------------------------------------------
-- p_excluir
-- -----------------------------------------------------------------------------
-- fn_matricula_mover_lote lo necesita: en una correccion la matricula se MUEVE
-- en vez de duplicarse, asi que las del propio lote que ya estan en el grupo
-- destino no pueden contarse dos veces. El alta no excluye nada.
--
-- Idempotente: CREATE OR REPLACE.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_cupo_ocupado(
    p_fk_tgrupo BIGINT,
    p_excluir   BIGINT[] DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $function$
    SELECT COUNT(*)
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TLISTA_VALOR lv
        ON lv.PK_LISTA_VALOR = m.FK_TLV_ESTADO_MATRICULA
     WHERE m.FK_TGRUPO = p_fk_tgrupo
       AND m.ACTIVE    = TRUE
       AND lv.CATEGORIA = 'ESTADO_MATRICULA'
       -- Por VALOR y no por nombre: el catalogo tiene 'Promovido' ('13') y
       -- 'Promovido Anticipadamente' ('6'), que empiezan igual y son cosas
       -- distintas. Un LIKE abriria un agujero silencioso.
       AND lv.VALOR IN ('1', '2', '3')
       AND (p_excluir IS NULL OR NOT (m.PK_TMATRICULA = ANY(p_excluir)));
$function$;

COMMENT ON FUNCTION academico_test.fn_matricula_cupo_ocupado(BIGINT, BIGINT[])
    IS 'Plazas realmente ocupadas de un grupo: cuenta las matriculas activas en estado Cursando (VALOR ''1''), Aprobado (''2'') o Reprobado (''3''), que son los estados en que el estudiante sigue siendo del grupo. NO cuentan Reubicado ni Promovido -- la matricula quedo atras al encadenarse otra y el estudiante ya esta en el grupo nuevo, asi que contarla seria contar a una persona dos veces -- ni Retirado, Trasladado o Graduado. Antes las dos cuentas de cupo (el alta y el movimiento) hacian COUNT(*) sin mirar el estado: se midieron 27.988 plazas ocupadas por matriculas que no estaban en Cursando y 170 de 5.332 grupos dados por llenos frente a 50. Existe para que esa regla viva en un solo sitio, porque la usan fn_matricula_validar_cupo (V205) y fn_matricula_mover_lote (V178). p_excluir lo necesita el movimiento: en una correccion la matricula se mueve, no se duplica. V145.';
