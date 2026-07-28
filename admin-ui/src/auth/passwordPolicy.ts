/**
 * Espejo en el cliente de `common.security.PasswordPolicy` del
 * backend. La autoridad es el backend — el SPA no puede impedir que
 * alguien haga el POST a mano — pero repetir la regla aquí es lo que
 * permite enseñarla ANTES de enviar el formulario, en vez de
 * devolver un 400 con la lista de lo que falta.
 *
 * <p>Las dos copias tienen que cambiar juntas. Si divergen, el
 * síntoma es una contraseña que el formulario acepta y el servidor
 * rechaza, que es exactamente la experiencia que esto viene a
 * quitar.
 */

export const PASSWORD_MIN_LENGTH = 8;
export const PASSWORD_MAX_LENGTH = 100;

/** Debe coincidir con PasswordPolicy.SPECIAL_CHARS del backend. */
export const PASSWORD_SPECIAL_CHARS = "!@#$%^&*()-_=+[]{};:,.<>?/|~";

export interface PasswordRule {
  /** Clave estable para el `key` de React y para los tests. */
  id: string;
  /** Texto que ve la persona usuaria. En imperativo y en positivo. */
  label: string;
  test: (password: string) => boolean;
}

export const PASSWORD_RULES: readonly PasswordRule[] = [
  {
    id: "length",
    label: `Al menos ${PASSWORD_MIN_LENGTH} caracteres`,
    test: (p) => p.length >= PASSWORD_MIN_LENGTH,
  },
  {
    id: "uppercase",
    label: "Una letra mayúscula",
    // Rango explícito en vez de /[A-Z]/ para no marcar como
    // incumplida una contraseña con acentos o eñes: "Ñ" y "Á" son
    // mayúsculas legítimas y el backend usa Character.isUpperCase,
    // que sí las reconoce.
    test: (p) => p !== p.toLowerCase(),
  },
  {
    id: "lowercase",
    label: "Una letra minúscula",
    test: (p) => p !== p.toUpperCase(),
  },
  {
    id: "digit",
    label: "Un número",
    test: (p) => /\d/.test(p),
  },
  {
    id: "special",
    label: `Un carácter especial (${PASSWORD_SPECIAL_CHARS})`,
    test: (p) => p.split("").some((c) => PASSWORD_SPECIAL_CHARS.includes(c)),
  },
];

/** True cuando la contraseña cumple todas las reglas. */
export function isPasswordValid(password: string): boolean {
  return (
    password.length <= PASSWORD_MAX_LENGTH &&
    PASSWORD_RULES.every((rule) => rule.test(password))
  );
}
