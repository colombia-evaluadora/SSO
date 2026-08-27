import { describe, expect, it } from "vitest";
import { getImplicitSystemType, scanPlaceholders } from "./placeholderScanner";

/**
 * Espejo TS de {@code PlaceholderScannerTest.java} — mismos casos,
 * para que un cambio de regex en un lado que no se refleje en el
 * otro falle acá en vez de en producción (el bug real que motivó
 * este archivo: BODY_RAW faltaba en la alternancia del regex TS y
 * ningún test lo cubría de este lado).
 */
describe("scanPlaceholders", () => {
  it("detects all five namespaces", () => {
    const sql = "SELECT :PARAM.A, :BODY.B, :BODY_RAW.C, :QUERY.D, :CONTEXT.E";
    expect(scanPlaceholders(sql).sort()).toEqual(
      ["BODY.B", "BODY_RAW.C", "CONTEXT.E", "PARAM.A", "QUERY.D"].sort(),
    );
  });

  it("recognises BODY_RAW placeholders on their own", () => {
    expect(scanPlaceholders("SELECT cast(:BODY_RAW.FILTRO as jsonb)")).toEqual([
      "BODY_RAW.FILTRO",
    ]);
  });

  it("treats BODY and BODY_RAW as distinct namespaces", () => {
    const result = scanPlaceholders("SELECT :BODY.X, :BODY_RAW.X");
    expect(result).toHaveLength(2);
    expect(result.sort()).toEqual(["BODY.X", "BODY_RAW.X"].sort());
  });

  it("detects nested BODY paths", () => {
    const sql = "SELECT :BODY.USER.EMAIL, :BODY.FILTROS.ZONA";
    expect(scanPlaceholders(sql).sort()).toEqual(
      ["BODY.FILTROS.ZONA", "BODY.USER.EMAIL"].sort(),
    );
  });

  it("dedupes repeated placeholders", () => {
    expect(scanPlaceholders("WHERE :PARAM.X = :PARAM.X")).toEqual(["PARAM.X"]);
  });

  it("normalizes lowercase to uppercase, including body_raw", () => {
    const sql = "SELECT :param.x, :Body.Y, :body_raw.z";
    expect(scanPlaceholders(sql).sort()).toEqual(
      ["BODY.Y", "BODY_RAW.Z", "PARAM.X"].sort(),
    );
  });

  it("preserves order of first appearance", () => {
    const sql = "SELECT :PARAM.A, :BODY.B, :PARAM.A, :BODY_RAW.C, :BODY.B";
    expect(scanPlaceholders(sql)).toEqual(["PARAM.A", "BODY.B", "BODY_RAW.C"]);
  });

  it("returns an empty array for empty/no-placeholder SQL", () => {
    expect(scanPlaceholders("")).toEqual([]);
    expect(scanPlaceholders("SELECT 1")).toEqual([]);
  });
});

describe("getImplicitSystemType", () => {
  it("returns the system type for CONTEXT.* and QUERY.{SIZE,OFFSET}", () => {
    expect(getImplicitSystemType("CONTEXT.USER_ID")).toBe("BIGINT");
    expect(getImplicitSystemType("QUERY.SIZE")).toBe("INTEGER");
  });

  it("returns undefined for author-controlled namespaces, BODY_RAW included", () => {
    expect(getImplicitSystemType("PARAM.ID")).toBeUndefined();
    expect(getImplicitSystemType("BODY.NAME")).toBeUndefined();
    expect(getImplicitSystemType("BODY_RAW.FILTRO")).toBeUndefined();
  });
});
