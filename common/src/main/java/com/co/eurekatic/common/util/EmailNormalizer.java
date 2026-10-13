package com.co.eurekatic.common.util;

import java.util.regex.Pattern;

/**
 * Normaliza correos que llegan de formularios: quita caracteres invisibles que
 * se cuelan al copiar/pegar (zero-width space/joiner/non-joiner U+200B-U+200D,
 * word joiner U+2060, BOM U+FEFF, espacio duro U+00A0) y recorta espacios.
 *
 * <p>NO cambia mayusculas/minusculas a proposito: {@code public.users.email}
 * se busca por igualdad exacta ({@code UserRepository#findByEmail}) y hay
 * cuentas guardadas con mayusculas; pasar a minusculas aca romperia el login
 * de esas cuentas. El caso real fue "\u2060jorge.sanchez@..." guardado en
 * public.users y en el funcionario: el login y la reactivacion por cambio de
 * correo no lo encontraban.
 */
public final class EmailNormalizer {

    private static final Pattern INVISIBLES = Pattern.compile("[\u200B-\u200D\u2060\uFEFF\u00A0]");

    private EmailNormalizer() {
    }

    /** {@code null} queda {@code null}; el resto sin invisibles y con trim. */
    public static String normalize(String email) {
        if (email == null) return null;
        return INVISIBLES.matcher(email).replaceAll("").trim();
    }
}
