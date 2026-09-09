-- ===========================================================================
-- V276 — trg_audit_ctx en las tablas creadas DESPUES de V26.
--
-- EL PROBLEMA. V26__context-emitter.sql instala trg_audit_ctx recorriendo
-- pg_tables de academico_test, pero ese recorrido se ejecuto UNA vez, con las
-- tablas que existian en ese momento. Flyway no reejecuta una migracion ya
-- aplicada, asi que toda tabla creada despues nacio SIN trigger: sus INSERT /
-- UPDATE / DELETE no emiten el mensaje logico y por lo tanto no llegan a
-- auditoria.audit_log en ClickHouse. No hay error ni aviso -- simplemente no
-- se auditan, que es la peor forma de fallar para una auditoria.
--
-- En el servidor de test eran trece tablas, de cuatro frentes distintos:
--
--   Planeador          tactividad_criterio_unidad, tactividad_evidencia,
--                      tunidad_enunciado, tactividad_otro,
--                      tactividad_adaptacion_estudiante
--   Referente curric.  treferente_curricular, treferente_curricular_area,
--                      treferente_enunciado
--   Matricula          tmatricula_campo, tmatricula_config, tmatricula_valor
--   Documentos         tdocumento_institucional, tdocumento_institucional_hist
--
-- POR QUE UNA MIGRACION NUEVA Y NO EDITAR V26. Editar V26 no arreglaria nada:
-- Flyway no la volveria a correr en los entornos donde ya esta aplicada, que
-- son todos. Ademas cambiaria su checksum y obligaria a un repair en cada uno.
--
-- POR QUE UN BUCLE Y NO UNA LISTA. La lista de arriba es la foto de HOY. Este
-- bucle recorre las tablas que le FALTA el trigger en el momento de aplicarse,
-- asi que corrige tambien las tablas que otras ramas hayan creado y que aqui
-- no se ven, sin tocar sus definiciones. Es idempotente: reejecutarlo no hace
-- nada si ya estan todas cubiertas.
--
-- La definicion del trigger es la MISMA de V26, copiada tal cual (BEFORE
-- INSERT OR UPDATE OR DELETE ... FOR EACH STATEMENT). No se cambia la
-- estrategia ni la funcion: fn_audit_ctx se resuelve por nombre en cada
-- disparo, asi que estas tablas heredan automaticamente la version vigente,
-- incluida la de V184 (contexto HTTP).
--
-- ESTO NO CIERRA EL AGUJERO A FUTURO. Una tabla creada despues de V276 volvera
-- a nacer sin trigger. La solucion definitiva es un event trigger sobre
-- CREATE TABLE, pero eso cambia el comportamiento del esquema para todas las
-- ramas a la vez y merece decidirse aparte; aqui se corrige lo que hoy no se
-- esta auditando, que es el problema concreto.
-- ===========================================================================

DO $$
DECLARE
    r        RECORD;
    v_total  INT := 0;
BEGIN
    FOR r IN
        SELECT t.schemaname, t.tablename
          FROM pg_tables t
         WHERE t.schemaname = 'academico_test'
           AND NOT EXISTS (
               SELECT 1
                 FROM pg_trigger tg
                 JOIN pg_class c     ON c.oid = tg.tgrelid
                 JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname   = t.schemaname
                  AND c.relname   = t.tablename
                  AND tg.tgname   = 'trg_audit_ctx'
                  AND NOT tg.tgisinternal
           )
         ORDER BY t.tablename
    LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_audit_ctx BEFORE INSERT OR UPDATE OR DELETE ON %I.%I
             FOR EACH STATEMENT EXECUTE FUNCTION academico_test.fn_audit_ctx()',
            r.schemaname, r.tablename
        );
        v_total := v_total + 1;
        RAISE NOTICE 'trg_audit_ctx instalado en %.%', r.schemaname, r.tablename;
    END LOOP;

    RAISE NOTICE 'V276: % tabla(s) de academico_test quedaron con trg_audit_ctx', v_total;
END $$;
