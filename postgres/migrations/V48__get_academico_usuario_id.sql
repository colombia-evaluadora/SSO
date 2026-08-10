-- =============================================================================
-- V48 — lookup helper: public.users.id_user → academico_test.TUSUARIO.PK_TUSUARIO.
--
-- Purpose.
--   auth-center (public) and the postgrest academic catalog (academico_test)
--   both have their own user tables. They identify users by different primary
--   keys (public.users.id_user vs academico_test.TUSUARIO.PK_TUSUARIO) and
--   the two PKs are not preserved on insert — TUSUARIO.PK_TUSUARIO is a
--   GENERATED IDENTITY column.
--
--   This migration exposes a single function that resolves a public
--   user PK to its TUSUARIO counterpart so the rest of the codebase
--   does not need to know that the join goes through email/CUENTA:
--
--       public.users.id_user  →  public.users.email  →  TUSUARIO.CUENTA
--                                                        → TUSUARIO.PK_TUSUARIO
--
--   Returns NULL when the user is missing in either schema (the caller
--   decides how to react — typically a left-anti join).
--
-- Idempotency.
--   The function is CREATE OR REPLACE so re-running the migration is
--   safe. It does not modify any data, only adds one function and its
--   COMMENT.
-- =============================================================================

-- Defensive: ensure the schema exists. V22 creates it, but local dev
-- sometimes starts from V1.
CREATE SCHEMA IF NOT EXISTS academico_test;

-- -----------------------------------------------------------------------------
-- Lookup function: given a public.users.id_user, return the
-- academico_test.TUSUARIO.PK_TUSUARIO of the mirrored row.
--
-- Marked STABLE so the planner can fold multiple references within a
-- single statement into one underlying query, and pinned to a
-- search_path so the call works regardless of the session's path.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_get_academico_usuario_id(p_user_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
SET search_path = public, academico_test
AS $$
DECLARE
    v_email       VARCHAR(200);
    v_tusuario_pk BIGINT;
BEGIN
    -- Resolve the public.users PK → email.
    SELECT email
      INTO v_email
      FROM public.users
     WHERE id_user = p_user_id;

    IF v_email IS NULL THEN
        -- No public.users row, or its email is NULL (should not happen
        -- post-V12 since email is NOT NULL, but defensive against pre-V12
        -- environments where the function may be tested).
        RETURN NULL;
    END IF;

    -- Resolve email → TUSUARIO PK via the CUENTA mirror column.
    -- LIMIT 1 is defensive: U_TUSUARIO_1 UNIQUE (CUENTA) already
    -- guarantees at most one row, but the planner ignores a unique
    -- index when the predicate is a parameter, so LIMIT 1 lets PG pick
    -- a cheaper plan.
    SELECT PK_TUSUARIO
      INTO v_tusuario_pk
      FROM academico_test.TUSUARIO
     WHERE CUENTA = v_email
     ORDER BY PK_TUSUARIO
     LIMIT 1;

    RETURN v_tusuario_pk;
END;
$$;

COMMENT ON FUNCTION public.fn_get_academico_usuario_id(BIGINT) IS
    'Returns academico_test.TUSUARIO.PK_TUSUARIO for a public.users.id_user. NULL if the user is missing in either schema.';