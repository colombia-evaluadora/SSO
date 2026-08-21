package com.co.eurekatic.common.entity;

import org.junit.jupiter.api.Test;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V81 — {@link Query#replaceParamConstraints}. Cubre el bug real que
 * motivó el diff-por-key en vez de {@code clear()} + re-add: editar
 * una query SIN cambiar sus placeholders (el caso común) no debe
 * crear entidades nuevas para keys que ya existían — sólo actualizar
 * sus columnas in-place. Un {@code clear()} + re-add deja entidades
 * NUEVAS con el mismo {@code paramKey}, que Hibernate intenta
 * INSERTar antes de hacer DELETE de las huérfanas (el orden de la
 * action queue), chocando contra el unique constraint
 * {@code (query_id, param_key)} — ver el javadoc del método.
 */
class QueryReplaceParamConstraintsTest {

    @Test
    void sameKeysAreUpdatedInPlaceNotReplaced() {
        Query q = new Query();
        QueryParamConstraint original = new QueryParamConstraint(
                q, "BODY.EDAD", true, null, null, null, null, null);
        q.replaceParamConstraints(List.of(original));
        assertThat(q.getParamConstraints()).hasSize(1);

        QueryParamConstraint updated = new QueryParamConstraint(
                null, "BODY.EDAD", false, true, 4, null, null, null);
        q.replaceParamConstraints(List.of(updated));

        // Misma instancia in-memory (identidad), sólo con los campos
        // actualizados — no una entidad nueva.
        assertThat(q.getParamConstraints()).hasSize(1);
        QueryParamConstraint result = q.getParamConstraints().get(0);
        assertThat(result).isSameAs(original);
        assertThat(result.getOnlyPositive()).isFalse();
        assertThat(result.getAllowDecimals()).isTrue();
        assertThat(result.getMaxDigits()).isEqualTo(4);
    }

    @Test
    void removedKeyIsDroppedFromCollection() {
        Query q = new Query();
        q.replaceParamConstraints(List.of(
                new QueryParamConstraint(q, "BODY.A", true, null, null, null, null, null),
                new QueryParamConstraint(q, "BODY.B", null, null, null, true, null, null)));
        assertThat(q.getParamConstraints()).hasSize(2);

        q.replaceParamConstraints(List.of(
                new QueryParamConstraint(q, "BODY.A", true, null, null, null, null, null)));

        assertThat(q.getParamConstraints()).hasSize(1);
        assertThat(q.getParamConstraints().get(0).getParamKey()).isEqualTo("BODY.A");
    }

    @Test
    void newKeyIsAppended() {
        Query q = new Query();
        q.replaceParamConstraints(List.of(
                new QueryParamConstraint(q, "BODY.A", true, null, null, null, null, null)));

        q.replaceParamConstraints(List.of(
                new QueryParamConstraint(q, "BODY.A", true, null, null, null, null, null),
                new QueryParamConstraint(q, "BODY.B", null, null, null, true, 2, 8)));

        assertThat(q.getParamConstraints()).hasSize(2);
        assertThat(q.getParamConstraints().stream().map(QueryParamConstraint::getParamKey).toList())
                .containsExactlyInAnyOrder("BODY.A", "BODY.B");
        // La entidad nueva quedó atada a la query dueña.
        QueryParamConstraint b = q.getParamConstraints().stream()
                .filter(c -> "BODY.B".equals(c.getParamKey())).findFirst().orElseThrow();
        assertThat(b.getQuery()).isSameAs(q);
    }

    @Test
    void emptyNextClearsEverything() {
        Query q = new Query();
        q.replaceParamConstraints(List.of(
                new QueryParamConstraint(q, "BODY.A", true, null, null, null, null, null)));
        q.replaceParamConstraints(List.of());
        assertThat(q.getParamConstraints()).isEmpty();
    }
}
