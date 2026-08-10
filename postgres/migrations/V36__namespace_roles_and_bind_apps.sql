-- =============================================================================
-- V36 — namespace the `role` table by app and wire each namespace to its app.
--
-- Until now every role in `public.role` (ADMIN, USER, anything created via
-- DataInitializer or the admin UI) was a single undifferentiated pool, and the
-- role_app join table had to be wired by hand — V10 did it for SSO-ADMIN, the
-- COLOMBIA-EVALUADORA binding was set interactively from the Apps admin screen
-- (see V14's note).
--
-- With two apps now provisioned we want each app to own a named role
-- namespace:
--
--   * SSO-*       roles are owned by the SSO-ADMIN app.
--   * CEVAL-*     roles are owned by the COLOMBIA-EVALUADORA app. These are
--                 imported from academico_test.TROL (NOMBRE), a legacy Oracle
--                 catalog the evaluator frontend was built against.
--
-- The new role_app state is fully driven by the role NAME's prefix — there is
-- no per-role mapping to maintain: every SSO-* lands on SSO-ADMIN, every
-- CEVAL-* on COLOMBIA-EVALUADORA. That keeps the binding in sync with the
-- namespace instead of with whatever someone clicked in the UI.
--
-- Four steps, all idempotent so re-applying this migration is a no-op:
--
--   1. Widen role.name so a CEVAL- prefix (5 chars) + a 130-char TROL.NOMBRE
--      fit. TROL.NOMBRE is VARCHAR(130); we use VARCHAR(140) so two prefixes
--      would still leave headroom and a future SSOMFA- or CEVAL2- prefix
--      doesn't force another widening migration. UNIQUE on name is preserved.
--
--   2. Prefix the existing public.role rows with SSO-. Skips rows already
--      prefixed (either by a previous run of this migration, or by an admin
--      who created SSO-* / CEVAL-* manually) so re-running is safe.
--
--      Caveat for fresh installs: DataInitializer in auth-center creates
--      ADMIN/USER at startup AFTER migrations run. Those will NOT pick up the
--      prefix — that is a separate concern (add sso.bootstrap.roles:
--      SSO-ADMIN,SSO-USER or seed SSO-* from a V37 once the team agrees on
--      the path). This migration only namespaces rows that already exist.
--
--   3. Import every distinct role from academico_test.TROL with the CEVAL-
--      prefix. TROL.NOMBRE is the role name there; CODIGO is the short code
--      the evaluadora UI uses. We store the code in `description` so the
--      legacy identifier survives the rename (and the admin UI can show it
--      without re-querying academico_test). `WHERE NOT EXISTS` makes the
--      insert idempotent in environments that re-run migrations.
--
--   4. Re-bind role_app strictly by prefix:
--        - delete any binding whose prefix doesn't match the app's namespace
--        - reinsert for every SSO-* onto SSO-ADMIN and every CEVAL-* onto
--          COLOMBIA-EVALUADORA, with ON CONFLICT DO NOTHING
--      This is the "wire by namespace" step. It replaces any drift between
--      the role name and its app ownership.
--
-- Run order matters: step 1 widens first, step 2 is just an UPDATE of an
-- already-widened column, step 3 inserts into the widened column, step 4 only
-- reads/writes role_app. None of them depend on the prior migration's
-- academico_test schema state other than TROL existing (it does — V22).
-- =============================================================================

-- 1. Widen role.name to fit "CEVAL-" + TROL.NOMBRE(VARCHAR 130) with margin.
ALTER TABLE role ALTER COLUMN name TYPE VARCHAR(140);

-- 2. Prefix existing roles with SSO- (skip already-prefixed rows so the
--    migration is safe to re-apply against a DB that already migrated).
UPDATE role
   SET name = 'SSO-' || name
 WHERE name NOT LIKE 'SSO-%'
   AND name NOT LIKE 'CEVAL-%';

-- 3. Import academico_test.TROL roles with CEVAL- prefix.
--
--    V22 prints the column names uppercase but writes them UNQUOTED, so
--    PostgreSQL folds them to lowercase — that's why the existing eval-col
--    migrations reference tfuncionario.fk_tarchivo (all lowercase). Use
--    the same convention here: schema-qualified table, lowercase columns.
--    Schema-qualify rather than setting search_path so this migration
--    works regardless of Flyway's session.
INSERT INTO role (name, description)
SELECT DISTINCT
       'CEVAL-' || t.codigo,
       COALESCE(NULLIF(t.nombre, ''), 'CEVAL-' || t.codigo)
  FROM academico_test.trol t
 WHERE NOT EXISTS (
       SELECT 1
         FROM role r
        WHERE r.name = 'CEVAL-' || t.nombre
       );

-- 4. Re-wire role_app strictly by prefix.
--    Drop cross-namespace bindings first (e.g. a UI-bound SSO-USER on
--    COLOMBIA-EVALUADORA, or a CEVAL-* mistakenly linked to SSO-ADMIN).
DELETE FROM role_app ra
 USING role r, app a
 WHERE ra.id_role = r.id_role
   AND ra.id_app  = a.id_app
   AND (
        (r.name LIKE 'SSO-%'  AND a.name <> 'SSO-ADMIN')
     OR (r.name LIKE 'CEVAL-%' AND a.name <> 'COLOMBIA-EVALUADORA')
   );

--    Bind every SSO-* to SSO-ADMIN and every CEVAL-* to COLOMBIA-EVALUADORA.
INSERT INTO role_app (id_app, id_role)
SELECT a.id_app, r.id_role
  FROM app a
 CROSS JOIN role r
 WHERE (r.name LIKE 'SSO-%'  AND a.name = 'SSO-ADMIN')
    OR (r.name LIKE 'CEVAL-%' AND a.name = 'COLOMBIA-EVALUADORA')
 ON CONFLICT (id_app, id_role) DO NOTHING;
