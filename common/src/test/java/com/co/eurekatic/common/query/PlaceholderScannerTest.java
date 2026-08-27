package com.co.eurekatic.common.query;

import org.junit.jupiter.api.Test;

import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Tests del scanner de placeholders. Reconoce los cinco namespaces
 * ({@code PARAM, BODY, BODY_RAW, QUERY, CONTEXT}) y reporta los placeholders
 * únicos en orden de aparición.
 *
 * <p>V49-bis: añadido {@code BODY_RAW} (sin aplanar) para sub-objetos
 * completos que el autor pasa como JSONB.
 */
class PlaceholderScannerTest {

    @Test
    void detectsAllFiveNamespaces() {
        String sql = "SELECT :PARAM.A, :BODY.B, :BODY_RAW.C, :QUERY.D, :CONTEXT.E";
        assertThat(PlaceholderScanner.scan(sql)).containsExactlyInAnyOrder(
                "PARAM.A", "BODY.B", "BODY_RAW.C", "QUERY.D", "CONTEXT.E");
    }

    @Test
    void detectsNestedBodyPaths() {
        String sql = "SELECT :BODY.USER.EMAIL, :BODY.FILTROS.ZONA";
        assertThat(PlaceholderScanner.scan(sql)).containsExactlyInAnyOrder(
                "BODY.USER.EMAIL", "BODY.FILTROS.ZONA");
    }

    @Test
    void deduplicatesRepeatedPlaceholders() {
        String sql = "WHERE :PARAM.X = :PARAM.X";
        assertThat(PlaceholderScanner.scan(sql)).containsExactly("PARAM.X");
    }

    @Test
    void ignoresLiteralsAndComments() {
        String sql = "SELECT ':not.a.placeholder', -- :also.not, :PARAM.X";
        assertThat(PlaceholderScanner.scan(sql)).containsExactly("PARAM.X");
    }

    @Test
    void normalizesLowercaseToUppercase() {
        String sql = "SELECT :param.x, :Body.Y, :body_raw.z";
        assertThat(PlaceholderScanner.scan(sql)).containsExactlyInAnyOrder(
                "PARAM.X", "BODY.Y", "BODY_RAW.Z");
    }

    @Test
    void emptySqlProducesEmptySet() {
        assertThat(PlaceholderScanner.scan(null)).isEmpty();
        assertThat(PlaceholderScanner.scan("")).isEmpty();
        assertThat(PlaceholderScanner.scan("SELECT 1")).isEmpty();
    }

    @Test
    void preservesOrderOfFirstAppearance() {
        String sql = "SELECT :PARAM.A, :BODY.B, :PARAM.A, :BODY_RAW.C, :BODY.B";
        // LinkedHashSet preserva orden: A, B, C.
        assertThat(PlaceholderScanner.scan(sql)).containsExactly(
                "PARAM.A", "BODY.B", "BODY_RAW.C");
    }

    @Test
    void rejectsMalformedPlaceholders() {
        // El segmento debe empezar por letra, no número; caracteres no
        // permitidos se ignoran (no matchean la regex). NOTA: `::PARAM.X`
        // sí matchea porque después del segundo `:` empieza con namespace
        // válido — la regex no distingue `::` de `:`, así que este caso
        // es aceptado y se interpreta como :PARAM.X.
        String sql = "SELECT :1FOO, :PAR+AM";
        assertThat(PlaceholderScanner.scan(sql)).isEmpty();
    }

    @Test
    void bodyRawPlaceholdersAreRecognised() {
        String sql = "SELECT cast(:BODY_RAW.FILTRO as jsonb)";
        assertThat(PlaceholderScanner.scan(sql)).containsExactly("BODY_RAW.FILTRO");
    }

    @Test
    void bodyAndBodyRawAreDistinctNamespaces() {
        // BODY.X y BODY_RAW.X son placeholders distintos — no se mezclan.
        String sql = "SELECT :BODY.X, :BODY_RAW.X";
        Set<String> result = PlaceholderScanner.scan(sql);
        assertThat(result).hasSize(2);
        assertThat(result).containsExactlyInAnyOrder("BODY.X", "BODY_RAW.X");
    }
}