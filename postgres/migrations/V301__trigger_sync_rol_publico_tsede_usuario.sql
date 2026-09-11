-- ===========================================================================
-- V301 - TSEDE_USUARIO: resincronizar public.role_users por trigger, no a
--        mano en cada punto de escritura.
--
-- POR QUE ESTA MIGRACION EXISTE
--   V111 conecto los roles academicos (TSEDE_USUARIO -> TROL) con
--   public.role_users, que es lo unico que EffectiveRolesResolver lee para
--   armar el claim "roles" del JWT. El mecanismo -- fn_sincronizar_rol_publico
--   (full-resync del set CEVAL-*/PIGSE-* de un usuario) -- es correcto, pero
--   se cableo llamandolo a mano desde los puntos de escritura conocidos en
--   ese momento:
--
--       fn_sede_usuario_crear
--       fn_sede_usuario_soft_delete
--       fn_est_crear / fn_est_actualizar
--       fn_fun_baja_establecimiento
--
--   El problema es estructural: TSEDE_USUARIO se desactiva tambien EN
--   CASCADA desde funciones que no estan en esa lista y que nunca llamaron
--   al resync. Auditadas contra el servidor, son cuatro:
--
--       fn_sed_soft_delete             (cascada al dar de baja una sede)
--       fn_estudiante_soft_delete
--       fn_padre_soft_delete
--       fn_matricula_directa_actualizar
--
--   (fn_sede_usuario_actualizar tambien hace UPDATE sobre la tabla, pero no
--   toca ACTIVE ni FK_TROL ni FK_TUSUARIO, asi que no altera el set de roles
--   y no necesita resync.)
--
-- INCIDENTE QUE LO DESTAPO
--   Una cuenta de super administrador quedo bloqueada en produccion: sus 50
--   filas de TSEDE_USUARIO con FK_TROL = 1 (SUPER_ADMINISTRADOR) quedaron en
--   ACTIVE = FALSE, pero public.role_users conservo CEVAL-SUPER_ADMINISTRADOR.
--   El resultado es el peor de los dos mundos: el JWT sale con el rol y el
--   gate del gateway la deja pasar, pero los gates de PL/pgSQL leen
--   TSEDE_USUARIO y la rechazan con 42501 --
--   fn_puede_afectar_establecimiento devuelve FALSE porque exige una fila
--   ACTIVE = TRUE con FK_TROL IN (1,2,3). Sintoma visible: la UI la muestra
--   como super admin y todo endpoint que pase por un gate de base le
--   responde "El usuario no tiene el nivel de permisos necesario para
--   realizar esta accion".
--
--   El camino fue PUT /establecimientos/sedes/bulk-delete ->
--   fn_sed_soft_delete_bulk -> fn_sed_soft_delete, que cascadea sobre
--   TSEDE_USUARIO. Al borrar sedes en bloque se llevo por delante sus
--   propios permisos sin resincronizar.
--
-- POR QUE UN TRIGGER Y NO CUATRO PARCHES
--   Parchear las cuatro funciones arregla los cuatro casos de hoy y deja el
--   quinto abierto: cualquier cascada nueva, o cualquier funcion que en el
--   servidor este en drift respecto al repo, vuelve a desincronizar sin que
--   nada lo avise. El invariante que queremos es "public.role_users refleja
--   TSEDE_USUARIO", y ese invariante pertenece a la tabla, no a cada uno de
--   sus escritores. Con el trigger ningun camino -- presente, futuro o por
--   drift -- puede saltarselo.
--
--   Se usan transition tables y FOR EACH STATEMENT, no FOR EACH ROW: las
--   cascadas apagan decenas de filas en un solo UPDATE (el incidente fueron
--   tandas de 10, 10 y 30) y asi se hace UN resync por usuario afectado en
--   vez de uno por fila.
--
--   El UPDATE se filtra comparando OLD contra NEW: solo disparan los cambios
--   de ACTIVE, FK_TROL o FK_TUSUARIO, que son los tres campos de los que
--   depende el set de roles. Un UPDATE de jornada/orden/estado
--   (fn_sede_usuario_actualizar) no paga nada.
--
--   Las llamadas explicitas que ya existen en fn_sede_usuario_crear y
--   compania NO se quitan: fn_sincronizar_rol_publico es un full-resync
--   idempotente, de modo que la llamada redundante es inofensiva, y dejar
--   esos cuerpos intactos evita reescribir funciones que hoy estan en drift
--   en el servidor. Si mas adelante se quieren limpiar, el trigger ya las
--   hace innecesarias.
--
-- NO HAY RIESGO DE RECURSION
--   fn_sincronizar_rol_publico escribe en public.role_users y public.app_users
--   (via fn_sync_app_users). No toca TSEDE_USUARIO, asi que el trigger no se
--   reentra.
--
-- ALCANCE
--   Esta migracion NO restaura ningun dato. Repara el mecanismo hacia
--   adelante; la reactivacion de permisos ya apagados es una decision
--   operativa aparte.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Funcion de trigger: resincroniza una sola vez por usuario afectado.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_trg_tsede_usuario_sync_rol_publico()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_tusuario BIGINT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        FOR v_pk_tusuario IN
            SELECT DISTINCT n.FK_TUSUARIO
              FROM afectadas_new n
             WHERE n.FK_TUSUARIO IS NOT NULL
        LOOP
            PERFORM academico_test.fn_sincronizar_rol_publico(v_pk_tusuario);
        END LOOP;

    ELSIF TG_OP = 'UPDATE' THEN
        -- Solo los cambios que pueden alterar el set de roles. Se emparejan
        -- OLD y NEW por PK y se resincronizan AMBOS usuarios cuando la fila
        -- cambio de dueno (FK_TUSUARIO distinto): el que lo gana y el que lo
        -- pierde.
        FOR v_pk_tusuario IN
            WITH cambiadas AS (
                SELECT o.FK_TUSUARIO AS fk_old, n.FK_TUSUARIO AS fk_new
                  FROM afectadas_old o
                  JOIN afectadas_new n
                    ON n.PK_TSEDE_USUARIO = o.PK_TSEDE_USUARIO
                 WHERE n.ACTIVE      IS DISTINCT FROM o.ACTIVE
                    OR n.FK_TROL     IS DISTINCT FROM o.FK_TROL
                    OR n.FK_TUSUARIO IS DISTINCT FROM o.FK_TUSUARIO
            )
            SELECT DISTINCT fk
              FROM (
                    SELECT fk_old AS fk FROM cambiadas
                    UNION
                    SELECT fk_new      FROM cambiadas
                   ) u
             WHERE fk IS NOT NULL
        LOOP
            PERFORM academico_test.fn_sincronizar_rol_publico(v_pk_tusuario);
        END LOOP;

    ELSIF TG_OP = 'DELETE' THEN
        -- TSEDE_USUARIO se maneja por borrado logico, pero si alguna vez se
        -- borra fisico (limpiezas, cargas) el invariante se sostiene igual.
        FOR v_pk_tusuario IN
            SELECT DISTINCT o.FK_TUSUARIO
              FROM afectadas_old o
             WHERE o.FK_TUSUARIO IS NOT NULL
        LOOP
            PERFORM academico_test.fn_sincronizar_rol_publico(v_pk_tusuario);
        END LOOP;
    END IF;

    RETURN NULL;  -- AFTER ... FOR EACH STATEMENT: el valor se ignora.
END;
$$;

COMMENT ON FUNCTION academico_test.fn_trg_tsede_usuario_sync_rol_publico() IS
    'V301 - mantiene public.role_users al dia con TSEDE_USUARIO. Sustituye a las llamadas manuales a fn_sincronizar_rol_publico repartidas por los puntos de escritura, que las cascadas (fn_sed_soft_delete y companeras) se saltaban.';

-- ---------------------------------------------------------------------------
-- Triggers. Uno por operacion: una transition table no puede declararse para
-- varias operaciones en un mismo CREATE TRIGGER.
-- Idempotentes (DROP IF EXISTS) para poder reaplicar la migracion en local.
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_tsede_usuario_sync_rol_publico_ins ON academico_test.TSEDE_USUARIO;
CREATE TRIGGER trg_tsede_usuario_sync_rol_publico_ins
    AFTER INSERT ON academico_test.TSEDE_USUARIO
    REFERENCING NEW TABLE AS afectadas_new
    FOR EACH STATEMENT
    EXECUTE FUNCTION academico_test.fn_trg_tsede_usuario_sync_rol_publico();

DROP TRIGGER IF EXISTS trg_tsede_usuario_sync_rol_publico_upd ON academico_test.TSEDE_USUARIO;
CREATE TRIGGER trg_tsede_usuario_sync_rol_publico_upd
    AFTER UPDATE ON academico_test.TSEDE_USUARIO
    REFERENCING OLD TABLE AS afectadas_old NEW TABLE AS afectadas_new
    FOR EACH STATEMENT
    EXECUTE FUNCTION academico_test.fn_trg_tsede_usuario_sync_rol_publico();

DROP TRIGGER IF EXISTS trg_tsede_usuario_sync_rol_publico_del ON academico_test.TSEDE_USUARIO;
CREATE TRIGGER trg_tsede_usuario_sync_rol_publico_del
    AFTER DELETE ON academico_test.TSEDE_USUARIO
    REFERENCING OLD TABLE AS afectadas_old
    FOR EACH STATEMENT
    EXECUTE FUNCTION academico_test.fn_trg_tsede_usuario_sync_rol_publico();
