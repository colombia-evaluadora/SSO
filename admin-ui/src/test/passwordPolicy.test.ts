import { describe, expect, it } from "vitest";
import {
  PASSWORD_RULES,
  isPasswordValid,
} from "@/auth/passwordPolicy";

/**
 * La política del cliente es un espejo de
 * `common.security.PasswordPolicy`. Si divergen, el síntoma es una
 * contraseña que el formulario acepta y el servidor rechaza, así que
 * los casos límite se fijan aquí explícitamente.
 */
describe("passwordPolicy", () => {
  const ruleFor = (id: string) => {
    const rule = PASSWORD_RULES.find((r) => r.id === id);
    if (!rule) throw new Error(`regla desconocida: ${id}`);
    return rule;
  };

  it("acepta una contraseña que cumple las cinco reglas", () => {
    expect(isPasswordValid("Newpass1!")).toBe(true);
  });

  it("rechaza por longitud aunque tenga de todo lo demás", () => {
    // 7 caracteres con mayúscula, minúscula, dígito y símbolo.
    expect(isPasswordValid("Ab1!cde")).toBe(false);
    expect(ruleFor("length").test("Ab1!cde")).toBe(false);
    expect(ruleFor("length").test("Ab1!cdef")).toBe(true);
  });

  it("rechaza cuando falta un único requisito", () => {
    expect(isPasswordValid("newpass1!")).toBe(false); // sin mayúscula
    expect(isPasswordValid("NEWPASS1!")).toBe(false); // sin minúscula
    expect(isPasswordValid("Newpassw!")).toBe(false); // sin número
    expect(isPasswordValid("Newpass12")).toBe(false); // sin símbolo
  });

  it("rechaza la cadena vacía sin lanzar", () => {
    expect(isPasswordValid("")).toBe(false);
  });

  it("cuenta acentos y eñes como letras, no como símbolos", () => {
    // El backend usa Character.isUpperCase, que sí reconoce Ñ y Á.
    // Un /[A-Z]// en el cliente las daría por no-mayúsculas y
    // bloquearía una contraseña que el servidor acepta.
    expect(ruleFor("uppercase").test("ñandú1!aa")).toBe(false);
    expect(ruleFor("uppercase").test("Ñandú1!aa")).toBe(true);
    expect(ruleFor("lowercase").test("ÑANDÚ1!AA")).toBe(false);
    // Una letra acentuada no cuenta como carácter especial.
    expect(ruleFor("special").test("Ñandúa1a")).toBe(false);
  });

  it("no cuenta el espacio como carácter especial", () => {
    // El espacio no está en SPECIAL_CHARS del backend; si el cliente
    // lo aceptara, el formulario dejaría enviar y el servidor daría
    // 400.
    expect(ruleFor("special").test("Newpass 1")).toBe(false);
  });

  it("rechaza por encima del máximo de 100 caracteres", () => {
    expect(isPasswordValid("A1!" + "a".repeat(98))).toBe(false);
  });
});
