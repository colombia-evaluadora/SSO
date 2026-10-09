package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.User;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * El saludo de los correos ("Hola, <nombre>.") salia "Hola, Administrador
 * MALDONADO ." porque el nombre del funcionario llega de concat_ws sobre
 * TUSUARIO y un apellido vacio ('' en vez de NULL) deja un espacio colgando.
 */
class UserAdminDisplayNameTest {

    private static User user(String fullName) {
        User u = new User();
        u.setEmail("ana@example.com");
        u.setFullName(fullName);
        return u;
    }

    @Test
    void recortaYColapsaEspacios() {
        assertThat(UserAdminService.displayNameOf(user("Administrador MALDONADO ")))
                .isEqualTo("Administrador MALDONADO");
        assertThat(UserAdminService.displayNameOf(user("  Ana   Maria  Perez ")))
                .isEqualTo("Ana Maria Perez");
    }

    @Test
    void sinNombreOEnBlancoUsaElCorreo() {
        assertThat(UserAdminService.displayNameOf(user(null))).isEqualTo("ana@example.com");
        assertThat(UserAdminService.displayNameOf(user("   "))).isEqualTo("ana@example.com");
    }

    @Test
    void normalizeFullNameRespetaNull() {
        assertThat(UserAdminService.normalizeFullName(null)).isNull();
        assertThat(UserAdminService.normalizeFullName(" ")).isEmpty();
    }
}
