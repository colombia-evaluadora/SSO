import { describe, expect, it } from "vitest";
import { tokenizeSql } from "./sqlHighlighter";

/** Reconstruye el texto original concatenando los tokens — invariante
 *  que debe cumplirse siempre: el tokenizer nunca pierde ni
 *  transforma caracteres, sólo los clasifica. */
function joined(tokens: ReturnType<typeof tokenizeSql>): string {
  return tokens.map((t) => t.text).join("");
}

describe("tokenizeSql", () => {
  it("never drops or alters characters", () => {
    const sql = "SELECT id, nombre FROM t WHERE x = :PARAM.ID AND y = 'a''b' -- c\n/* d */ 42.5";
    expect(joined(tokenizeSql(sql))).toBe(sql);
  });

  it("classifies SQL keywords case-insensitively", () => {
    const tokens = tokenizeSql("select * from t where id = 1");
    const kw = tokens.filter((t) => t.type === "keyword").map((t) => t.text);
    expect(kw).toEqual(["select", "from", "where"]);
  });

  it("classifies the four placeholder namespaces", () => {
    const sql = ":PARAM.ID :BODY.X.Y :QUERY.SIZE :CONTEXT.USER_ID :BODY_RAW.OBJ";
    const tokens = tokenizeSql(sql).filter((t) => t.type === "placeholder");
    expect(tokens.map((t) => t.text)).toEqual([
      ":PARAM.ID",
      ":BODY.X.Y",
      ":QUERY.SIZE",
      ":CONTEXT.USER_ID",
      ":BODY_RAW.OBJ",
    ]);
  });

  it("prefers BODY_RAW over BODY (longer alternative first)", () => {
    const tokens = tokenizeSql(":BODY_RAW.SCALES").filter((t) => t.type === "placeholder");
    expect(tokens).toHaveLength(1);
    expect(tokens[0]?.text).toBe(":BODY_RAW.SCALES");
  });

  it("classifies single-quoted strings, including escaped quotes", () => {
    const tokens = tokenizeSql("'it''s ok'").filter((t) => t.type === "string");
    expect(tokens).toEqual([{ type: "string", text: "'it''s ok'" }]);
  });

  it("classifies double-quoted identifiers", () => {
    const tokens = tokenizeSql('"weird column"').filter((t) => t.type === "identifier");
    expect(tokens).toEqual([{ type: "identifier", text: '"weird column"' }]);
  });

  it("classifies line comments up to (not including) the newline", () => {
    const tokens = tokenizeSql("-- nota\nSELECT 1");
    expect(tokens[0]).toEqual({ type: "comment", text: "-- nota" });
  });

  it("classifies block comments, tolerating an unterminated one", () => {
    expect(tokenizeSql("/* a */ x")[0]).toEqual({ type: "comment", text: "/* a */" });
    expect(tokenizeSql("/* never closes")[0]).toEqual({
      type: "comment",
      text: "/* never closes",
    });
  });

  it("classifies integers and decimals", () => {
    const tokens = tokenizeSql("a 42 3.14 b").filter((t) => t.type === "number");
    expect(tokens.map((t) => t.text)).toEqual(["42", "3.14"]);
  });

  it("does not misclassify a placeholder-shaped word as a keyword", () => {
    const tokens = tokenizeSql(":PARAM.SELECT");
    expect(tokens.filter((t) => t.type === "keyword")).toHaveLength(0);
    expect(tokens.find((t) => t.type === "placeholder")?.text).toBe(":PARAM.SELECT");
  });

  it("real catalog SQL round-trips and tags the right tokens", () => {
    const sql =
      "select PK_LISTA_VALOR, NOMBRE, VALOR, ACCION\n" +
      "from academico_test.tlista_valor\n" +
      "where academico_test.tlista_valor.categoria = UPPER(CAST(:PARAM.CATEGORIA AS VARCHAR))\n" +
      "order by VALOR asc";
    const tokens = tokenizeSql(sql);
    expect(joined(tokens)).toBe(sql);
    expect(tokens.some((t) => t.type === "placeholder" && t.text === ":PARAM.CATEGORIA")).toBe(
      true,
    );
    expect(tokens.filter((t) => t.type === "keyword").map((t) => t.text)).toEqual([
      "select", "from", "where", "CAST", "AS", "VARCHAR", "order", "by", "asc",
    ]);
  });
});
