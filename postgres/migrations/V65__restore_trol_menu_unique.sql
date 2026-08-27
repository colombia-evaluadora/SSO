-- =============================================================================
-- V65 — restore U_TROL_MENU_1 as a FULL unique on (FK_TROL, FK_TMENU).
--
-- Symptom: every PUT /roles/{roleId}/menus returns 500. The query-service log
-- shows the query-service mapping a raw PostgreSQL failure:
--
--     sqlState=42P10: there is no unique or exclusion constraint matching the
--     ON CONFLICT specification
--     PL/pgSQL function fn_associate_menus_to_rol(...) line 83
--
-- Cause: schema drift, not a bug in V59. V22 declares the constraint as a
-- plain table-level UNIQUE:
--
--     CONSTRAINT U_TROL_MENU_1 UNIQUE (FK_TROL, FK_TMENU)
--
-- but the live database carries it as a PARTIAL unique index instead:
--
--     CREATE UNIQUE INDEX u_trol_menu_1 ON academico_test.trol_menu
--         USING btree (fk_trol, fk_tmenu) WHERE (active = true)
--
-- No migration in this folder performs that replacement, so it was applied by
-- hand at some point. PostgreSQL will not infer a partial index for an
-- ON CONFLICT clause unless the statement repeats the index predicate, and
-- fn_associate_menus_to_rol (V59, line 691) infers the bare column list:
--
--     ON CONFLICT (fk_trol, fk_tmenu) DO UPDATE
--
-- so the INSERT aborts on the first iteration of the loop and takes the whole
-- association down with it — for every role, not just one.
--
-- Why restore the full UNIQUE rather than add `WHERE active = TRUE` to the
-- function: the partial index only covers active rows, so re-adding a menu
-- that had been soft-deleted (fn_associate_menus_to_rol sets active = FALSE in
-- full_replace mode for anything dropped from the list) would not conflict at
-- all. It would insert a SECOND row for the same pair and the function's own
-- documented 'reactivated' branch would become dead code. The full UNIQUE is
-- what V59 was written against — see its header: "Semantica UPSERT sobre la
-- U_TROL_MENU_1 (FK_TROL, FK_TMENU)".
--
-- Safety: verified against the live database before writing this migration —
-- zero duplicate (fk_trol, fk_tmenu) pairs exist, counting inactive rows, so
-- promoting the partial index to a full UNIQUE cannot fail on existing data.
-- If a duplicate appears between now and the deploy, the ADD CONSTRAINT fails
-- loudly (that is the desired outcome: the data would need reconciling first).
--
-- Idempotent on purpose: this was applied by hand to the test environment to
-- unblock it, so Flyway must be able to re-run it without erroring out.
--
-- Bug fixed here: the original version issued `DROP INDEX IF EXISTS
-- academico_test.u_trol_menu_1` unconditionally, BEFORE checking whether the
-- constraint already existed. `IF EXISTS` only guards against the index
-- being absent — it does nothing when the index IS present but now backs a
-- constraint (exactly the state on the server this migration describes
-- having hand-patched already): Postgres refuses `DROP INDEX` on a
-- constraint-backing index no matter what, with
--
--     ERROR: cannot drop index u_trol_menu_1 because constraint
--     u_trol_menu_1 on table trol_menu requires it
--     HINT: You can drop constraint u_trol_menu_1 on table trol_menu instead.
--
-- which is precisely what broke Flyway on re-run: the constraint from the
-- hand-fix was already in place, so `DROP INDEX` failed before the migration
-- ever reached the `IF NOT EXISTS (...)` guard below it. Moving the DROP
-- INDEX inside that SAME guard closes the gap — if the constraint already
-- exists, NEITHER statement runs, which is exactly the "nothing left to do"
-- case this migration is supposed to be a no-op for.
-- =============================================================================

SET search_path TO academico_test, public;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM pg_constraint
         WHERE conrelid = 'academico_test.trol_menu'::regclass
           AND conname  = 'u_trol_menu_1'
    ) THEN
        -- The full UNIQUE below subsumes the partial index: same
        -- columns, no predicate. Only reached when the constraint
        -- doesn't exist yet, i.e. the index (if present at all) is
        -- still the old bare partial one, not a constraint's backing
        -- index — so DROP INDEX is safe here.
        DROP INDEX IF EXISTS academico_test.u_trol_menu_1;
        ALTER TABLE academico_test.trol_menu
            ADD CONSTRAINT u_trol_menu_1 UNIQUE (fk_trol, fk_tmenu);
    END IF;
END
$$;

COMMENT ON CONSTRAINT u_trol_menu_1 ON academico_test.trol_menu IS
    'Un menu no puede asociarse dos veces al mismo rol. Cubre tambien las filas inactivas: la desasociacion es soft-delete (active=FALSE), y fn_associate_menus_to_rol reactiva esa misma fila via ON CONFLICT (fk_trol, fk_tmenu) DO UPDATE en vez de insertar una nueva. Restaurada en V65 tras haber derivado a un indice parcial WHERE active = true, que rompia esa inferencia (42P10).';
