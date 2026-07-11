import { describe, expect, it } from "vitest";
import { extractQueryParams } from "./queryParams";

/**
 * Pure-function tests for {@link extractQueryParams}. The auto-
 * parse is what lets the admin-ui render a parameter form from
 * raw SQL with no separate metadata, so the cases here are the
 * ones that drove the regex design:
 *
 *  - basic `:foo`
 *  - multi-placeholder
 *  - underscores and digits
 *  - dedup
 *  - reserved (`limit`/`offset`) filtered
 *  - Postgres `::cast` syntax NOT matched (negative lookbehind)
 *  - empty SQL
 */
describe("extractQueryParams", () => {
  it("returns a single placeholder", () => {
    expect(extractQueryParams("SELECT * FROM t WHERE id = :id")).toEqual(["id"]);
  });

  it("returns multiple placeholders in source order", () => {
    expect(extractQueryParams("SELECT * FROM t WHERE a = :a AND b = :b")).toEqual(["a", "b"]);
  });

  it("supports underscores and digits after the first char", () => {
    expect(extractQueryParams("SELECT * FROM t WHERE foo_bar = :foo_bar AND x = :x123")).toEqual([
      "foo_bar",
      "x123",
    ]);
  });

  it("dedupes repeated placeholders", () => {
    expect(extractQueryParams("SELECT * FROM t WHERE id = :id OR parent_id = :id")).toEqual(["id"]);
  });

  it("filters out the reserved limit/offset placeholders", () => {
    expect(extractQueryParams("SELECT * FROM t LIMIT :limit OFFSET :offset")).toEqual([]);
  });

  it("filters limit/offset but keeps other placeholders", () => {
    expect(
      extractQueryParams("SELECT * FROM t WHERE a = :a LIMIT :limit OFFSET :offset"),
    ).toEqual(["a"]);
  });

  it("does not match the Postgres ::cast syntax", () => {
    // Negative lookbehind: the second ':' is preceded by
    // another ':', so it must NOT match. Only `id` is a real
    // placeholder.
    expect(extractQueryParams("SELECT id::int FROM t WHERE x = :id")).toEqual(["id"]);
  });

  it("returns [] when no placeholders are present", () => {
    expect(extractQueryParams("SELECT 1")).toEqual([]);
  });

  it("handles empty input", () => {
    expect(extractQueryParams("")).toEqual([]);
  });

  it("matches case-insensitively on reserved names", () => {
    // ResERVE check is case-insensitive — operators who write
    // :LIMIT in caps still get it filtered.
    expect(extractQueryParams("SELECT * FROM t LIMIT :LIMIT")).toEqual([]);
  });

  it("does not match a placeholder preceded by a colon that isn't a cast", () => {
    // `:a::int` — the second colon between a and int is part of
    // the cast, but the FIRST :a is preceded by start-of-line so
    // it IS a real placeholder. The second `:int` is preceded by
    // another `:` so it must NOT match.
    expect(extractQueryParams("SELECT :a::int FROM t")).toEqual(["a"]);
  });
});