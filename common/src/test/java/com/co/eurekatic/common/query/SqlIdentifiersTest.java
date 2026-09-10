package com.co.eurekatic.common.query;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * Tests de {@link SqlIdentifiers}.
 *
 * <p>El caso que justifica la clase es el último bloque: cadenas que
 * se cuelan en un {@code INSERT INTO <tabla>} si nadie las mira.
 */
class SqlIdentifiersTest {

    // ── identificadores simples válidos ──────────────────────────────

    @ParameterizedTest
    @ValueSource(strings = {
            "users", "USERS", "_privado", "tabla_1", "a",
            "fk_tfuncionario_rector", "pk_tarchivo", "C1"
    })
    void aceptaIdentificadoresSimples(String id) {
        assertThat(SqlIdentifiers.exigirSimple(id, "columna")).isEqualTo(id);
    }

    @Test
    void aceptaExactamente63Caracteres() {
        String limite = "a".repeat(63);
        assertThat(SqlIdentifiers.exigirSimple(limite, "columna")).isEqualTo(limite);
    }

    // ── identificadores simples inválidos ────────────────────────────

    @ParameterizedTest
    @ValueSource(strings = {
            "1tabla",          // no puede empezar por dígito
            "mi tabla",        // espacio
            "mi-tabla",        // guion
            "tabla;",          // terminador de sentencia
            "esquema.tabla",   // punto: para eso está exigirTabla
            "año",             // fuera de ASCII
            "\"Mi Tabla\"",    // entrecomillado
            "tabla--",         // inicio de comentario
            ""
    })
    void rechazaIdentificadoresSimplesInvalidos(String id) {
        assertThatThrownBy(() -> SqlIdentifiers.exigirSimple(id, "columna"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("columna");
    }

    @Test
    void rechazaNulo() {
        assertThatThrownBy(() -> SqlIdentifiers.exigirSimple(null, "columna"))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void rechaza64CaracteresPorquePostgresTruncaria() {
        assertThatThrownBy(() -> SqlIdentifiers.exigirSimple("a".repeat(64), "columna"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("63");
    }

    // ── nombres de tabla ─────────────────────────────────────────────

    @Test
    void aceptaTablaSinEsquema() {
        assertThat(SqlIdentifiers.exigirTabla("testablecimiento", "tabla"))
                .isEqualTo("testablecimiento");
    }

    @Test
    void aceptaTablaConEsquema() {
        assertThat(SqlIdentifiers.exigirTabla("academico_test.tusuario", "tabla"))
                .isEqualTo("academico_test.tusuario");
    }

    @Test
    void rechazaTresSegmentos() {
        assertThatThrownBy(() -> SqlIdentifiers.exigirTabla("bd.esquema.tabla", "tabla"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("más de un punto");
    }

    @ParameterizedTest
    @ValueSource(strings = {".tabla", "esquema.", ".", "esquema..tabla"})
    void rechazaSegmentosVacios(String nombre) {
        assertThatThrownBy(() -> SqlIdentifiers.exigirTabla(nombre, "tabla"))
                .isInstanceOf(IllegalArgumentException.class);
    }

    // ── lo que motiva la clase ───────────────────────────────────────

    @ParameterizedTest
    @ValueSource(strings = {
            "users; DROP TABLE users",
            "users WHERE 1=1",
            "users--",
            "users/*",
            "users UNION SELECT 1",
            "users(select 1)"
    })
    void rechazaTablasQueRomperianLaSentencia(String hostil) {
        assertThatThrownBy(() -> SqlIdentifiers.exigirTabla(hostil, "tabla"))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void plegarNormalizaAMinusculasConLocaleRoot() {
        // Con locale turco, "I".toLowerCase() da "ı" (i sin punto) y el
        // identificador dejaría de coincidir con el de Postgres.
        assertThat(SqlIdentifiers.plegar("ID_USUARIO")).isEqualTo("id_usuario");
    }
}
