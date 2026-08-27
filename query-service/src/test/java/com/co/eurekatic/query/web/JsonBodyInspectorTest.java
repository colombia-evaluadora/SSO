package com.co.eurekatic.query.web;

import org.junit.jupiter.api.Test;
import tools.jackson.databind.JsonNode;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Unit tests for {@link JsonBodyInspector}. Cada caso cubre una
 * violación de forma específica o un body legítimo; el
 * inspector debe distinguirlos y emitir la lista de violations
 * verbatim para que el operador leyendo el log sepa exactamente
 * qué campo del body hay que arreglar.
 *
 * <p>Estos tests usan el árbol Jackson 3 (tools.jackson) sin
 * contexto de Spring — son unit tests rápidos.
 */
class JsonBodyInspectorTest {

    /** Helper: inspecciona el sub-árbol "params" recibido por el caller. */
    private static JsonBodyInspector.InspectionReport inspectParams(JsonNode paramsNode) {
        return JsonBodyInspector.inspect(paramsNode, "params");
    }

    @Test
    void plainObjectIsClean() {
        JsonNode params = JsonSamples.obj(Map.of(
                "page", JsonSamples.num(1),
                "size", JsonSamples.num(20)));
        JsonBodyInspector.InspectionReport rep = inspectParams(params);
        assertThat(rep.isClean()).isTrue();
        assertThat(rep.rootKind()).isEqualTo(JsonBodyInspector.JsonKind.OBJECT);
        assertThat(rep.topLevelTypes()).containsOnlyKeys("page", "size");
    }

    @Test
    void arrayAsParamsValueIsClean() {
        JsonNode params = JsonSamples.obj(Map.of(
                "items", JsonSamples.arr(
                        JsonSamples.num(1),
                        JsonSamples.num(2))));
        assertThat(inspectParams(params).isClean()).isTrue();
    }

    @Test
    void nullValueFieldIsClean() {
        Map<String, JsonNode> fields = new LinkedHashMap<>();
        fields.put("x", JsonSamples.nul());
        JsonNode params = JsonSamples.obj(fields);
        JsonBodyInspector.InspectionReport rep = inspectParams(params);
        assertThat(rep.isClean()).isTrue();
        assertThat(rep.topLevelTypes().get("x").kind())
                .isEqualTo(JsonBodyInspector.JsonKind.NULL);
    }

    @Test
    void mixedNumberArrayProducesViolation() {
        JsonNode params = JsonSamples.obj(Map.of("ids", JsonSamples.arr(
                JsonSamples.num(1),
                JsonSamples.num(2),
                JsonSamples.num(3.5))));
        JsonBodyInspector.InspectionReport rep = inspectParams(params);
        assertThat(rep.isClean()).isFalse();
        assertThat(rep.violations())
                .anyMatch(v -> v.contains("ids") && v.contains("mezcla"));
    }

    @Test
    void mixedStringAndNumberArrayProducesViolation() {
        JsonNode params = JsonSamples.obj(Map.of("rows", JsonSamples.arr(
                JsonSamples.num(1),
                JsonSamples.str("2"),
                JsonSamples.num(3))));
        JsonBodyInspector.InspectionReport rep = inspectParams(params);
        assertThat(rep.isClean()).isFalse();
        assertThat(rep.violations())
                .anyMatch(v -> v.contains("rows") && v.contains("mezcla"));
    }

    @Test
    void uniformIntegerArrayIsClean() {
        JsonNode params = JsonSamples.obj(Map.of("ids", JsonSamples.arr(
                JsonSamples.num(1),
                JsonSamples.num(2),
                JsonSamples.num(3))));
        assertThat(inspectParams(params).isClean()).isTrue();
    }

    @Test
    void nestedObjectBeyondMaxDepthRejected() {
        JsonNode deepest = JsonSamples.num(7);
        JsonNode current = deepest;
        for (int i = 0; i < JsonBodyInspector.MAX_DEPTH + 1; i++) {
            Map<String, JsonNode> fields = new LinkedHashMap<>();
            fields.put("child", current);
            current = JsonSamples.obj(fields);
        }
        JsonNode params = JsonSamples.obj(Map.of("deep", current));
        JsonBodyInspector.InspectionReport rep = inspectParams(params);
        assertThat(rep.isClean()).isFalse();
        assertThat(rep.violations()).anyMatch(v -> v.contains("profundidad"));
    }

    @Test
    void largeArrayRejected() {
        int over = JsonBodyInspector.MAX_ARRAY_LENGTH + 1;
        JsonNode[] bigArr = new JsonNode[over];
        for (int i = 0; i < over; i++) bigArr[i] = JsonSamples.num(1);
        JsonNode params = JsonSamples.obj(Map.of("rows", JsonSamples.arr(bigArr)));
        JsonBodyInspector.InspectionReport rep = inspectParams(params);
        assertThat(rep.isClean()).isFalse();
        assertThat(rep.violations())
                .anyMatch(v -> v.contains("rows") && v.contains("demasiado grande"));
    }

    @Test
    void manyFieldsRejected() {
        int over = JsonBodyInspector.MAX_FIELDS_PER_OBJECT + 1;
        Map<String, JsonNode> fields = new LinkedHashMap<>();
        for (int i = 0; i < over; i++) {
            fields.put("f" + i, JsonSamples.num(i));
        }
        JsonNode params = JsonSamples.obj(fields);
        JsonBodyInspector.InspectionReport rep = inspectParams(params);
        assertThat(rep.isClean()).isFalse();
        assertThat(rep.violations())
                .anyMatch(v -> v.contains("demasiados campos") || v.contains("campos"));
    }
}
