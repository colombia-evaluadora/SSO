package com.co.eurekatic.common.security;

import java.util.ArrayList;
import java.util.List;

/**
 * Reglas de complejidad que debe cumplir una contraseña elegida por
 * la persona usuaria: 8 caracteres como mínimo, con al menos una
 * mayúscula, una minúscula, un dígito y un carácter especial.
 *
 * <p>Vive junto a {@link PasswordEncoderFactory} porque es la otra
 * mitad de la misma decisión: el encoder define cuánto cuesta romper
 * un hash, y esto define cuánto hay que romper. Subir el coste del
 * hash no sirve de nada si la contraseña es {@code 123456}.
 *
 * <p><b>Se informa de TODO lo que falta, no del primer fallo.</b>
 * Una validación que solo dice "falta un número", y al reintentar
 * "falta una mayúscula", obliga a adivinar la regla a base de
 * intentos. {@link #validate(String)} acumula los incumplimientos y
 * los devuelve en un único mensaje.
 *
 * <p>La política NO se aplica a las contraseñas ya almacenadas: sólo
 * corre cuando alguien elige una nueva (activación de cuenta y
 * restablecimiento). Una cuenta antigua con una contraseña de 6
 * caracteres sigue pudiendo entrar; sólo se le exigirá la regla
 * nueva cuando la cambie. Aplicarla en el login dejaría fuera a
 * gente que no ha hecho nada malo, sin darle forma de arreglarlo.
 */
public final class PasswordPolicy {

    public static final int MIN_LENGTH = 8;

    /**
     * Tope alineado con {@code @Size(max = 100)} del DTO. No es una
     * regla de seguridad — Argon2id digiere cualquier longitud — sino
     * un límite para no aceptar un cuerpo arbitrariamente grande en
     * un endpoint público.
     */
    public static final int MAX_LENGTH = 100;

    /**
     * Conjunto de caracteres especiales aceptados. Es explícito y no
     * un {@code \W} genérico para poder enseñárselo al usuario en la
     * interfaz: una regla que no se puede leer es una regla que se
     * cumple por prueba y error.
     */
    public static final String SPECIAL_CHARS = "!@#$%^&*()-_=+[]{};:,.<>?/|~";

    private PasswordPolicy() {
    }

    /**
     * @throws IllegalArgumentException con todos los requisitos
     *         incumplidos si la contraseña no pasa. El
     *         {@code GlobalExceptionHandler} de sso-admin lo mapea a
     *         400 {@code INVALID_REQUEST} y el SPA muestra el
     *         mensaje tal cual.
     */
    public static void validate(String password) {
        List<String> problems = check(password);
        if (!problems.isEmpty()) {
            throw new IllegalArgumentException(
                    "La contraseña no cumple los requisitos: " + String.join("; ", problems) + ".");
        }
    }

    /**
     * Devuelve la lista de requisitos incumplidos, vacía si la
     * contraseña es válida. Separado de {@link #validate(String)}
     * para que los tests puedan afirmar sobre requisitos concretos
     * sin parsear un mensaje.
     */
    public static List<String> check(String password) {
        List<String> problems = new ArrayList<>();
        if (password == null || password.isBlank()) {
            problems.add("no puede estar vacía");
            return problems;
        }
        if (password.length() < MIN_LENGTH) {
            problems.add("debe tener al menos " + MIN_LENGTH + " caracteres");
        }
        if (password.length() > MAX_LENGTH) {
            problems.add("no puede superar los " + MAX_LENGTH + " caracteres");
        }
        if (password.chars().noneMatch(Character::isUpperCase)) {
            problems.add("debe incluir al menos una letra mayúscula");
        }
        if (password.chars().noneMatch(Character::isLowerCase)) {
            problems.add("debe incluir al menos una letra minúscula");
        }
        if (password.chars().noneMatch(Character::isDigit)) {
            problems.add("debe incluir al menos un número");
        }
        if (password.chars().noneMatch(c -> SPECIAL_CHARS.indexOf(c) >= 0)) {
            problems.add("debe incluir al menos un carácter especial ("
                    + SPECIAL_CHARS + ")");
        }
        return problems;
    }
}
