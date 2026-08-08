# Namespaces de parámetros y sintaxis `:VARIABLE` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Que los parámetros de una query tengan un origen explícito (`:PARAM.*`, `:QUERY.*`, `:BODY.*`, `:CONTEXT.*`), que las plantillas de ruta usen `:MAYÚSCULA`, que los valores de ruta lleguen decodificados, y que el formulario deje de pedir dos datos que el sistema puede deducir.

**Architecture:** La sintaxis de plantillas vive en una clase nueva del módulo `common`, compartida por el validador de escritura (sso-admin) y el matcher de lectura (query-service), para que no puedan desincronizarse. `QueryPathRegistry` pasa de `AntPathMatcher` a `PathPatternParser`, que devuelve las variables ya decodificadas. `QueryPathController` deja de volcar todo en un mapa plano y prefija cada valor con su origen. Una migración V32 reescribe los datos existentes.

**Tech Stack:** Java 25, Spring Boot 4.0.7, Spring Framework 7, Maven multi-módulo, Flyway (SQL puro), React + TypeScript (admin-ui), JUnit 5 + AssertJ + Mockito, H2 para tests de integración.

**Spec:** `docs/superpowers/specs/2026-08-07-query-param-namespaces-design.md`

---

## Aviso sobre el entorno

El plan se redactó en una máquina **sin Maven ni Docker**. Quien lo ejecute necesita Maven instalado. Todos los comandos usan `mvn` directamente (este repo **no tiene** wrapper `mvnw`). Si no hay Maven local, la única validación disponible es CI — en ese caso, ejecuta las tareas igualmente, commitea, y verifica en el PR.

Comando base para tests de un módulo:
```bash
mvn -q -pl <modulo> -am test -Dtest=<ClaseDeTest>
```

---

## Estructura de ficheros

**Crear:**
- `common/src/main/java/com/co/eurekatic/common/query/PathTemplateSyntax.java` — única fuente de verdad de la sintaxis `:VARIABLE`: validación y traducción a la forma `{VARIABLE}` que entiende `PathPattern`.
- `common/src/main/java/com/co/eurekatic/common/query/ParamNamespace.java` — los cuatro prefijos y el helper que normaliza claves del llamante detectando colisiones de caja.
- `common/src/test/java/com/co/eurekatic/common/query/PathTemplateSyntaxTest.java`
- `common/src/test/java/com/co/eurekatic/common/query/ParamNamespaceTest.java`
- `query-service/src/test/java/com/co/eurekatic/query/read/DottedParamBindingTest.java` — prueba que `:PARAM.NOMBRE` se parsea y bindea. El esquema entero descansa aquí.
- `postgres/migrations/V32__query_param_namespaces.sql`

**Modificar:**
- `query-service/src/main/java/com/co/eurekatic/query/routing/QueryPathRegistry.java` — `AntPathMatcher` → `PathPatternParser`.
- `query-service/src/main/java/com/co/eurekatic/query/web/path/QueryPathController.java` — prefijar por origen.
- `query-service/src/main/java/com/co/eurekatic/query/read/QueryService.java:185-250` — renombrar contexto, eliminar inyección y reescritura de `limit`/`offset`.
- `sso-admin/src/main/java/com/co/eurekatic/ssoadmin/service/QueryAdminService.java` — validar sintaxis, derivar modo, heredar dialecto.
- `admin-ui/src/pages/queries/QueryFormDrawer.tsx` — quitar dos campos, actualizar ayudas.
- `admin-ui/src/schemas/` (el fichero que define `queryFormSchema`).

**Orden:** `common` primero (sin dependencias), luego query-service y sso-admin en paralelo, luego admin-ui, y la migración al final para que el código que la necesita ya exista.

---

## Task 1: Sintaxis de plantillas en `common`

**Files:**
- Create: `common/src/main/java/com/co/eurekatic/common/query/PathTemplateSyntax.java`
- Test: `common/src/test/java/com/co/eurekatic/common/query/PathTemplateSyntaxTest.java`

- [ ] **Step 1: Write the failing test**

```java
package com.co.eurekatic.common.query;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class PathTemplateSyntaxTest {

    @Test
    void acceptsUppercaseVariables() {
        PathTemplateSyntax.validate("/establecimiento/:NOMBRE");
        PathTemplateSyntax.validate("/municipio/:MUNICIPIO/establecimientos");
        PathTemplateSyntax.validate("/x/:A_1");
        PathTemplateSyntax.validate("/sin/variables");
    }

    @Test
    void rejectsLegacyBraceSyntax() {
        assertThatThrownBy(() -> PathTemplateSyntax.validate("/establecimiento/{nombre}"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("{nombre}")
                .hasMessageContaining(":NOMBRE");
    }

    @Test
    void rejectsLowercaseVariableNames() {
        assertThatThrownBy(() -> PathTemplateSyntax.validate("/establecimiento/:nombre"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("MAYÚSCULA");
    }

    @Test
    void rejectsWildcard() {
        assertThatThrownBy(() -> PathTemplateSyntax.validate("/establecimiento/**"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("**");
    }

    @Test
    void rejectsTemplateNotStartingWithSlash() {
        assertThatThrownBy(() -> PathTemplateSyntax.validate("establecimiento/:NOMBRE"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("/");
    }

    @Test
    void rejectsDuplicateVariableNames() {
        assertThatThrownBy(() -> PathTemplateSyntax.validate("/a/:X/b/:X"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("X");
    }

    @Test
    void translatesToBracePatternForPathPattern() {
        assertThat(PathTemplateSyntax.toBracePattern("/establecimiento/:NOMBRE"))
                .isEqualTo("/establecimiento/{NOMBRE}");
        assertThat(PathTemplateSyntax.toBracePattern("/municipio/:M/est/:ID"))
                .isEqualTo("/municipio/{M}/est/{ID}");
        assertThat(PathTemplateSyntax.toBracePattern("/sin/variables"))
                .isEqualTo("/sin/variables");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -q -pl common -am test -Dtest=PathTemplateSyntaxTest`
Expected: FAIL — compilación rota, `PathTemplateSyntax` no existe.

- [ ] **Step 3: Write minimal implementation**

```java
package com.co.eurekatic.common.query;

import java.util.LinkedHashSet;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Única fuente de verdad de la sintaxis de plantillas de ruta.
 *
 * <p>Vive en {@code common} a propósito: la validación al guardar
 * (sso-admin) y el matching en tiempo de petición (query-service)
 * tienen que entender exactamente la misma gramática. Si cada lado
 * tuviera su propia copia, una plantilla podría guardarse y luego
 * no resolver — el fallo más caro de diagnosticar que hay aquí,
 * porque no produce error: produce 200 con lista vacía.
 *
 * <p>Gramática: una variable es {@code :} seguido de
 * {@code [A-Z][A-Z0-9_]*}. Las mayúsculas son obligatorias para que
 * una variable se distinga de un literal de un vistazo, y porque
 * los parámetros que inyecta el sistema son todos minúsculas — así
 * una variable de ruta nunca puede pisarlos.
 */
public final class PathTemplateSyntax {

    private PathTemplateSyntax() {}

    /** Una variable bien formada: dos puntos + nombre en MAYÚSCULA. */
    private static final Pattern VARIABLE =
            Pattern.compile(":([A-Za-z_][A-Za-z0-9_]*)");

    /** Nombre aceptable dentro de una variable. */
    private static final Pattern VALID_NAME =
            Pattern.compile("[A-Z][A-Z0-9_]*");

    /**
     * Valida una plantilla. Lanza {@link IllegalArgumentException}
     * con un mensaje que explica QUÉ hay que escribir, no sólo qué
     * está mal — el consumidor es un admin en un formulario, no un
     * programador leyendo un stacktrace.
     */
    public static void validate(String template) {
        if (template == null || template.isBlank()) {
            throw new IllegalArgumentException(
                    "La plantilla de ruta no puede estar vacía.");
        }
        String t = template.trim();
        if (!t.startsWith("/")) {
            throw new IllegalArgumentException(
                    "La plantilla debe empezar por '/': " + t);
        }
        if (t.contains("**")) {
            throw new IllegalArgumentException(
                    "La plantilla no puede contener '**' — ese prefijo lo "
                    + "aporta el microservicio (MICROSERVICE.REQUEST_URI). "
                    + "Usa una ruta literal, ej /establecimiento/:NOMBRE");
        }
        if (t.indexOf('{') >= 0 || t.indexOf('}') >= 0) {
            throw new IllegalArgumentException(
                    "La sintaxis {variable} ya no se admite. Escribe "
                    + ":VARIABLE en MAYÚSCULA — por ejemplo, en vez de "
                    + "/establecimiento/{nombre} usa /establecimiento/:NOMBRE");
        }
        Set<String> seen = new LinkedHashSet<>();
        Matcher m = VARIABLE.matcher(t);
        while (m.find()) {
            String name = m.group(1);
            if (!VALID_NAME.matcher(name).matches()) {
                throw new IllegalArgumentException(
                        "El nombre de variable ':" + name + "' debe ir en "
                        + "MAYÚSCULA y empezar por letra: usa ':"
                        + name.toUpperCase() + "'");
            }
            if (!seen.add(name)) {
                throw new IllegalArgumentException(
                        "La variable ':" + name + "' aparece más de una vez "
                        + "en la plantilla.");
            }
        }
    }

    /**
     * Traduce {@code :NOMBRE} a {@code {NOMBRE}}, que es la forma
     * que entiende {@code PathPatternParser} de Spring.
     *
     * <p>Es el único punto de traducción del sistema: hacia fuera
     * (catálogo, formulario, documentación) sólo existe {@code :}.
     */
    public static String toBracePattern(String template) {
        if (template == null) {
            return null;
        }
        return VARIABLE.matcher(template).replaceAll("{$1}");
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn -q -pl common -am test -Dtest=PathTemplateSyntaxTest`
Expected: PASS — 8 tests.

- [ ] **Step 5: Commit**

```bash
git add common/src/main/java/com/co/eurekatic/common/query/PathTemplateSyntax.java \
        common/src/test/java/com/co/eurekatic/common/query/PathTemplateSyntaxTest.java
git commit -m "feat(common): add :VARIABLE path template syntax"
```

---

## Task 2: Namespaces y normalización de claves

**Files:**
- Create: `common/src/main/java/com/co/eurekatic/common/query/ParamNamespace.java`
- Test: `common/src/test/java/com/co/eurekatic/common/query/ParamNamespaceTest.java`

- [ ] **Step 1: Write the failing test**

```java
package com.co.eurekatic.common.query;

import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ParamNamespaceTest {

    @Test
    void prefixesAndUppercasesCallerKeys() {
        Map<String, String> in = new LinkedHashMap<>();
        in.put("estado", "activo");
        in.put("SIZE", "20");

        Map<String, Object> out = new LinkedHashMap<>();
        ParamNamespace.putAll(out, ParamNamespace.QUERY, in);

        assertThat(out).containsEntry("QUERY.ESTADO", "activo");
        assertThat(out).containsEntry("QUERY.SIZE", "20");
    }

    @Test
    void rejectsKeysThatDifferOnlyByCase() {
        Map<String, String> in = new LinkedHashMap<>();
        in.put("estado", "a");
        in.put("ESTADO", "b");

        Map<String, Object> out = new LinkedHashMap<>();
        assertThatThrownBy(() -> ParamNamespace.putAll(out, ParamNamespace.QUERY, in))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("ESTADO");
    }

    @Test
    void flattensNestedBodyWithDottedUppercasePaths() {
        Map<String, Object> body = Map.of(
                "filtros", Map.of("zona", 214));

        Map<String, Object> out = ParamNamespace.flatten(body, ParamNamespace.BODY);

        assertThat(out).containsEntry("BODY.FILTROS.ZONA", 214);
    }

    @Test
    void keepsArraysIntactWhenFlattening() {
        Map<String, Object> body = Map.of("tags", java.util.List.of("a", "b"));

        Map<String, Object> out = ParamNamespace.flatten(body, ParamNamespace.BODY);

        assertThat(out).containsEntry("BODY.TAGS", java.util.List.of("a", "b"));
    }

    @Test
    void rejectsNestedKeysThatCollideByCase() {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("zona", 1);
        body.put("ZONA", 2);

        assertThatThrownBy(() -> ParamNamespace.flatten(body, ParamNamespace.BODY))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("ZONA");
    }

    @Test
    void exposesTheFourNamespaces() {
        assertThat(ParamNamespace.PARAM).isEqualTo("PARAM");
        assertThat(ParamNamespace.QUERY).isEqualTo("QUERY");
        assertThat(ParamNamespace.BODY).isEqualTo("BODY");
        assertThat(ParamNamespace.CONTEXT).isEqualTo("CONTEXT");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -q -pl common -am test -Dtest=ParamNamespaceTest`
Expected: FAIL — `ParamNamespace` no existe.

- [ ] **Step 3: Write minimal implementation**

```java
package com.co.eurekatic.common.query;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Los cuatro orígenes posibles de un parámetro y cómo se nombran.
 *
 * <p>Antes todos los valores caían en un mapa plano: las variables
 * de ruta, los query params, el body aplanado y lo inyectado del
 * JWT. Eso tenía dos consecuencias malas. Una, que mirando una SQL
 * no se sabía qué controla el llamante y qué el sistema — la
 * distinción que importa para razonar sobre seguridad. Y dos, que
 * podían pisarse entre sí en silencio.
 *
 * <p>Con prefijo obligatorio la colisión deja de ser improbable y
 * pasa a ser imposible, que es una garantía distinta.
 */
public final class ParamNamespace {

    private ParamNamespace() {}

    /** Variables de la ruta. Las controla el llamante. */
    public static final String PARAM = "PARAM";
    /** Query string. Lo controla el llamante. */
    public static final String QUERY = "QUERY";
    /** Cuerpo JSON. Lo controla el llamante. */
    public static final String BODY = "BODY";
    /** Derivado del JWT verificado. NO lo controla el llamante. */
    public static final String CONTEXT = "CONTEXT";

    /**
     * Copia {@code source} en {@code target} prefijando con el
     * namespace y pasando la clave a MAYÚSCULA.
     *
     * <p>Se normaliza el NOMBRE, nunca el VALOR: un nombre es un
     * identificador y puede canonicalizarse, un valor es dato y
     * pasarlo a mayúscula destrozaría emails, códigos o UUIDs.
     *
     * @throws IllegalArgumentException si dos claves sólo se
     *         diferencian por la caja. Elegir una en silencio
     *         sería justo el tipo de fallo invisible que este
     *         diseño existe para eliminar.
     */
    public static void putAll(Map<String, Object> target,
                              String namespace,
                              Map<String, ?> source) {
        if (source == null || source.isEmpty()) {
            return;
        }
        Map<String, String> originalByUpper = new LinkedHashMap<>();
        for (Map.Entry<String, ?> e : source.entrySet()) {
            String upper = e.getKey().toUpperCase();
            String previous = originalByUpper.putIfAbsent(upper, e.getKey());
            if (previous != null) {
                throw new IllegalArgumentException(
                        "Las claves '" + previous + "' y '" + e.getKey()
                        + "' sólo se diferencian por mayúsculas y ambas "
                        + "resolverían a :" + namespace + "." + upper
                        + ". Envía sólo una.");
            }
            target.put(namespace + "." + upper, e.getValue());
        }
    }

    /**
     * Aplana un JSON anidado a rutas con punto, en MAYÚSCULA:
     * {@code {"filtros":{"zona":1}}} → {@code BODY.FILTROS.ZONA=1}.
     *
     * <p>Los arrays se dejan intactos: JDBC sabe bindear una lista
     * a un parámetro, y trocearla por índice produciría nombres
     * que nadie puede escribir en una SQL.
     */
    public static Map<String, Object> flatten(Map<String, ?> body, String prefix) {
        Map<String, Object> out = new LinkedHashMap<>();
        flattenInto(out, body, prefix);
        return out;
    }

    private static void flattenInto(Map<String, Object> out,
                                    Map<String, ?> body,
                                    String prefix) {
        Map<String, String> originalByUpper = new LinkedHashMap<>();
        for (Map.Entry<String, ?> e : body.entrySet()) {
            String upper = e.getKey().toUpperCase();
            String previous = originalByUpper.putIfAbsent(upper, e.getKey());
            if (previous != null) {
                throw new IllegalArgumentException(
                        "Las claves '" + previous + "' y '" + e.getKey()
                        + "' del cuerpo sólo se diferencian por mayúsculas "
                        + "y ambas resolverían a :" + prefix + "." + upper
                        + ". Envía sólo una.");
            }
            String key = prefix + "." + upper;
            Object val = e.getValue();
            if (val instanceof Map<?, ?> nested) {
                @SuppressWarnings("unchecked")
                Map<String, Object> nestedMap = (Map<String, Object>) nested;
                flattenInto(out, nestedMap, key);
            } else {
                out.put(key, val);
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn -q -pl common -am test -Dtest=ParamNamespaceTest`
Expected: PASS — 6 tests.

- [ ] **Step 5: Commit**

```bash
git add common/src/main/java/com/co/eurekatic/common/query/ParamNamespace.java \
        common/src/test/java/com/co/eurekatic/common/query/ParamNamespaceTest.java
git commit -m "feat(common): add parameter namespaces with case-collision detection"
```

---

## Task 3: Probar que los nombres con punto bindean de verdad

Todo el esquema descansa en que `:PARAM.NOMBRE` se parsea como **un solo nombre**. Es cierto — el parser de Spring no trata el `.` como separador — pero la suite actual nunca lo comprueba. Deja de ser una suposición.

**Files:**
- Create: `query-service/src/test/java/com/co/eurekatic/query/read/DottedParamBindingTest.java`

- [ ] **Step 1: Write the failing test**

```java
package com.co.eurekatic.query.read;

import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterUtils;
import org.springframework.jdbc.core.namedparam.ParsedSql;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * El esquema de namespaces entero depende de que Spring parsee
 * ":PARAM.NOMBRE" como UN nombre de parámetro y no lo corte en el
 * punto. Lo es — el punto no está en la lista de separadores de
 * NamedParameterUtils — pero es una garantía prestada de una
 * librería de terceros, así que la fijamos con un test propio.
 */
class DottedParamBindingTest {

    @Test
    void dottedNamesParseAsASingleParameter() {
        ParsedSql parsed = NamedParameterUtils.parseSqlStatement(
                "SELECT * FROM t WHERE nombre = :PARAM.NOMBRE");

        assertThat(parsed.getParameterNames()).containsExactly("PARAM.NOMBRE");
    }

    @Test
    void allFourNamespacesParseInOneStatement() {
        ParsedSql parsed = NamedParameterUtils.parseSqlStatement(
                "SELECT * FROM t "
                + "WHERE municipio = :PARAM.MUNICIPIO "
                + "  AND zona = :BODY.FILTROS.ZONA "
                + "  AND owner = :CONTEXT.USER_ID "
                + "LIMIT :QUERY.SIZE");

        assertThat(parsed.getParameterNames()).containsExactly(
                "PARAM.MUNICIPIO", "BODY.FILTROS.ZONA",
                "CONTEXT.USER_ID", "QUERY.SIZE");
    }

    @Test
    void dottedNamesBindTheirValues() {
        ParsedSql parsed = NamedParameterUtils.parseSqlStatement(
                "SELECT * FROM t WHERE a = :PARAM.NOMBRE AND b = :CONTEXT.USER_ID");
        MapSqlParameterSource source = new MapSqlParameterSource()
                .addValue("PARAM.NOMBRE", "PRUEBA2025")
                .addValue("CONTEXT.USER_ID", 42L);

        Object[] values = NamedParameterUtils.buildValueArray(parsed, source, null);

        assertThat(values).containsExactly("PRUEBA2025", 42L);
    }

    @Test
    void substitutionProducesOnePlaceholderPerDottedName() {
        ParsedSql parsed = NamedParameterUtils.parseSqlStatement(
                "SELECT * FROM t WHERE a = :PARAM.NOMBRE");

        String sql = NamedParameterUtils.substituteNamedParameters(
                parsed, new MapSqlParameterSource("PARAM.NOMBRE", "x"));

        assertThat(sql).isEqualTo("SELECT * FROM t WHERE a = ?");
    }
}
```

- [ ] **Step 2: Run test to verify it passes immediately**

Run: `mvn -q -pl query-service -am test -Dtest=DottedParamBindingTest`
Expected: **PASS a la primera.** Es un test de caracterización: documenta una garantía que ya existe. Si **falla**, para el plan — significa que el diseño no es viable tal cual y hay que volver al spec.

- [ ] **Step 3: Commit**

```bash
git add query-service/src/test/java/com/co/eurekatic/query/read/DottedParamBindingTest.java
git commit -m "test(query-service): pin dotted parameter name binding"
```

---

## Task 4: `QueryPathRegistry` con `PathPatternParser`

**Files:**
- Modify: `query-service/src/main/java/com/co/eurekatic/query/routing/QueryPathRegistry.java`
- Test: `query-service/src/test/java/com/co/eurekatic/query/routing/QueryPathRegistryMatchTest.java` (crear)

- [ ] **Step 1: Write the failing test**

```java
package com.co.eurekatic.query.routing;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * El matching se prueba sobre el helper estático para no montar
 * el contexto de Spring ni mockear el catálogo: lo que importa
 * aquí es la gramática y la decodificación.
 */
class QueryPathRegistryMatchTest {

    @Test
    void matchesAndExtractsUppercaseVariable() {
        var match = QueryPathRegistry.matchTemplate(
                "/establecimiento/:NOMBRE", "/establecimiento/PRUEBA2025");

        assertThat(match).isPresent();
        assertThat(match.get()).containsEntry("NOMBRE", "PRUEBA2025");
    }

    /** El bug del 2026-08-07: el valor llegaba percent-encoded. */
    @Test
    void decodesSpacesInTheValue() {
        var match = QueryPathRegistry.matchTemplate(
                "/establecimiento/:NOMBRE", "/establecimiento/PRUDENCIA%20DAZA");

        assertThat(match).isPresent();
        assertThat(match.get()).containsEntry("NOMBRE", "PRUDENCIA DAZA");
    }

    @Test
    void decodesAccentsInTheValue() {
        var match = QueryPathRegistry.matchTemplate(
                "/establecimiento/:NOMBRE", "/establecimiento/INSTITUCI%C3%93N");

        assertThat(match).isPresent();
        assertThat(match.get()).containsEntry("NOMBRE", "INSTITUCIÓN");
    }

    /**
     * Un %2F dentro del valor NO debe partir en segmentos: si lo
     * hiciera, un llamante podría hacer casar una plantilla que no
     * le corresponde.
     */
    @Test
    void encodedSlashDoesNotInjectPathSegments() {
        var twoSegments = QueryPathRegistry.matchTemplate(
                "/est/:NOMBRE", "/est/A%2FB");
        assertThat(twoSegments).isPresent();
        assertThat(twoSegments.get()).containsEntry("NOMBRE", "A/B");

        var deeper = QueryPathRegistry.matchTemplate(
                "/est/:NOMBRE", "/est/A/B");
        assertThat(deeper).isEmpty();
    }

    @Test
    void matchesMultipleVariables() {
        var match = QueryPathRegistry.matchTemplate(
                "/municipio/:MUNICIPIO/est/:ID", "/municipio/404/est/528");

        assertThat(match).isPresent();
        assertThat(match.get())
                .containsEntry("MUNICIPIO", "404")
                .containsEntry("ID", "528");
    }

    @Test
    void doesNotMatchDifferentPath() {
        assertThat(QueryPathRegistry.matchTemplate(
                "/establecimiento/:NOMBRE", "/otra/cosa")).isEmpty();
    }

    @Test
    void toleratesTrailingSlash() {
        var match = QueryPathRegistry.matchTemplate(
                "/establecimiento/:NOMBRE", "/establecimiento/X/");

        assertThat(match).isPresent();
        assertThat(match.get()).containsEntry("NOMBRE", "X");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -q -pl query-service -am test -Dtest=QueryPathRegistryMatchTest`
Expected: FAIL — `matchTemplate` no existe.

- [ ] **Step 3: Replace the matcher**

En `QueryPathRegistry.java`, sustituye el import de `AntPathMatcher`:

```java
import org.springframework.http.server.PathContainer;
import org.springframework.web.util.pattern.PathPattern;
import org.springframework.web.util.pattern.PathPatternParser;
```

Borra el campo `matcher`:

```java
private final AntPathMatcher matcher = new AntPathMatcher();   // BORRAR
```

y añade en su lugar:

```java
/**
 * PathPatternParser en vez de AntPathMatcher por dos razones.
 * La primera es correctitud: matchAndExtract devuelve las
 * variables YA DECODIFICADAS, mientras que con AntPathMatcher
 * el valor llegaba percent-encoded a la SQL y cualquier nombre
 * con espacio o acento fallaba en silencio con 200 y lista
 * vacía. La segunda es que es la API que usa el propio Spring
 * MVC; AntPathMatcher está en retirada para matching de
 * peticiones.
 *
 * <p>Se decodifica la VARIABLE EXTRAÍDA, no la ruta completa
 * antes de matchear: si se decodificara antes, un %2F dentro de
 * un valor inyectaría segmentos y podría hacer casar una
 * plantilla que no corresponde. PathPattern hace exactamente
 * eso — matchea sobre la ruta cruda y decodifica al extraer.
 */
private static final PathPatternParser PARSER = new PathPatternParser();
```

Reemplaza el método `match` entero por:

```java
    public Optional<Match> match(String path) {
        if (path == null || path.isEmpty()) {
            return Optional.empty();
        }
        Map<String, String> snapshot = tableRef.get();
        for (Map.Entry<String, String> e : snapshot.entrySet()) {
            Optional<Map<String, String>> vars = matchTemplate(e.getKey(), path);
            if (vars.isPresent()) {
                metrics.recordRegistryMatch(QueryMetrics.Match.HIT);
                return Optional.of(new Match(e.getValue(), vars.get()));
            }
        }
        metrics.recordRegistryMatch(QueryMetrics.Match.MISS);
        return Optional.empty();
    }

    /**
     * Casa una plantilla {@code :VARIABLE} contra una ruta y
     * devuelve las variables decodificadas.
     *
     * <p>Estático y package-private para poder probar la gramática
     * y la decodificación sin levantar el contexto de Spring ni
     * mockear el catálogo.
     */
    static Optional<Map<String, String>> matchTemplate(String template, String path) {
        String normalized = path.endsWith("/") && path.length() > 1
                ? path.substring(0, path.length() - 1)
                : path;
        PathPattern pattern = PARSER.parse(
                PathTemplateSyntax.toBracePattern(template));
        PathPattern.PathMatchInfo info =
                pattern.matchAndExtract(PathContainer.parsePath(normalized));
        return info == null
                ? Optional.empty()
                : Optional.of(info.getUriVariables());
    }
```

Añade el import de la sintaxis compartida:

```java
import com.co.eurekatic.common.query.PathTemplateSyntax;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn -q -pl query-service -am test -Dtest=QueryPathRegistryMatchTest`
Expected: PASS — 7 tests.

- [ ] **Step 5: Run the existing registry tests**

Run: `mvn -q -pl query-service -am test -Dtest=QueryPathDispatcherIntegrationTest`
Expected: los tests que usan `/establecimiento/{id}` **fallan ahora**. Es lo correcto: esa sintaxis ya no existe. Actualízalos a `/establecimiento/:ID` y el SQL a `:PARAM.ID` — se arreglan del todo en la Task 5, cuando el controller ya prefije. Si tras la Task 5 siguen fallando, investígalo antes de continuar.

- [ ] **Step 6: Commit**

```bash
git add query-service/src/main/java/com/co/eurekatic/query/routing/QueryPathRegistry.java \
        query-service/src/test/java/com/co/eurekatic/query/routing/QueryPathRegistryMatchTest.java
git commit -m "fix(query-service): decode path variables via PathPatternParser"
```

---

## Task 5: `QueryPathController` prefija por origen

**Files:**
- Modify: `query-service/src/main/java/com/co/eurekatic/query/web/path/QueryPathController.java`
- Test: `query-service/src/test/java/com/co/eurekatic/query/web/path/QueryPathControllerParamsTest.java` (crear)

- [ ] **Step 1: Write the failing test**

```java
package com.co.eurekatic.query.web.path;

import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class QueryPathControllerParamsTest {

    @Test
    void mergesTheThreeCallerSourcesUnderTheirNamespaces() {
        Map<String, String> pathVars = Map.of("MUNICIPIO", "404");
        Map<String, String> queryParams = new LinkedHashMap<>();
        queryParams.put("size", "20");
        Map<String, Object> body = Map.of("filtros", Map.of("zona", 214));

        Map<String, Object> params =
                QueryPathController.buildParams(pathVars, queryParams, body);

        assertThat(params)
                .containsEntry("PARAM.MUNICIPIO", "404")
                .containsEntry("QUERY.SIZE", "20")
                .containsEntry("BODY.FILTROS.ZONA", 214);
    }

    /**
     * Antes los query params PISABAN a las variables de ruta
     * (putAll(pathVars) y luego putAll(queryParams)), así que una
     * ruta declarada podía secuestrarse desde el query string.
     * Con namespaces la colisión es imposible por construcción.
     */
    @Test
    void queryParamsCannotOverridePathVariables() {
        Map<String, Object> params = QueryPathController.buildParams(
                Map.of("NOMBRE", "delPath"),
                Map.of("NOMBRE", "delQueryString"),
                null);

        assertThat(params)
                .containsEntry("PARAM.NOMBRE", "delPath")
                .containsEntry("QUERY.NOMBRE", "delQueryString");
    }

    @Test
    void handlesNullBody() {
        Map<String, Object> params = QueryPathController.buildParams(
                Map.of("ID", "1"), Map.of(), null);

        assertThat(params).containsExactly(Map.entry("PARAM.ID", "1"));
    }

    @Test
    void rejectsQueryParamsThatCollideByCase() {
        Map<String, String> queryParams = new LinkedHashMap<>();
        queryParams.put("estado", "a");
        queryParams.put("ESTADO", "b");

        assertThatThrownBy(() ->
                QueryPathController.buildParams(Map.of(), queryParams, null))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("ESTADO");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -q -pl query-service -am test -Dtest=QueryPathControllerParamsTest`
Expected: FAIL — `buildParams` no existe.

- [ ] **Step 3: Implement**

En `QueryPathController.java`, sustituye el bloque que arma `params` dentro de `dispatch`:

```java
        Map<String, Object> params = new LinkedHashMap<>();
        params.putAll(match.pathVars());
        params.putAll(queryParams);
        if (body != null) {
            params.putAll(flattenToPaths(body, "body"));
        }
```

por:

```java
        Map<String, Object> params =
                buildParams(match.pathVars(), queryParams, body);
```

Borra el método `flattenToPaths` entero (su lógica vive ahora en `ParamNamespace.flatten`, que además normaliza claves y detecta colisiones) y añade:

```java
    /**
     * Arma el mapa de binds prefijando cada valor con su origen.
     *
     * <p>Los tres orígenes que controla el llamante viven en
     * namespaces separados, así que ya no pueden pisarse: antes
     * un {@code ?nombre=} machacaba silenciosamente a la variable
     * de ruta {@code {nombre}} porque ambos escribían la misma
     * clave. {@code CONTEXT.*} lo añade QueryService desde el JWT
     * — deliberadamente fuera de aquí, porque nada de lo que
     * llegue en la petición debe poder inventárselo.
     *
     * <p>Package-private y estático para poder probar la mezcla
     * sin montar MockMvc.
     */
    static Map<String, Object> buildParams(Map<String, String> pathVars,
                                           Map<String, String> queryParams,
                                           Map<String, Object> body) {
        Map<String, Object> params = new LinkedHashMap<>();
        // Las variables de ruta ya vienen validadas en MAYÚSCULA
        // desde el catálogo, así que se prefijan sin normalizar.
        if (pathVars != null) {
            for (Map.Entry<String, String> e : pathVars.entrySet()) {
                params.put(ParamNamespace.PARAM + "." + e.getKey(), e.getValue());
            }
        }
        ParamNamespace.putAll(params, ParamNamespace.QUERY, queryParams);
        if (body != null) {
            params.putAll(ParamNamespace.flatten(body, ParamNamespace.BODY));
        }
        return params;
    }
```

Añade el import:

```java
import com.co.eurekatic.common.query.ParamNamespace;
```

- [ ] **Step 4: Map the collision error to 400**

`ParamNamespace` lanza `IllegalArgumentException`, y el catch-all de `GlobalExceptionHandler` la convertiría en 500. Añade en `query-service/src/main/java/com/co/eurekatic/query/exception/GlobalExceptionHandler.java`, junto a los demás `@ExceptionHandler`:

```java
    /**
     * Claves del llamante que sólo se diferencian por la caja
     * (?estado=a&ESTADO=b). Es un error de quien llama, no del
     * servidor: 400, no 500.
     */
    @ExceptionHandler(IllegalArgumentException.class)
    public ResponseEntity<Map<String, Object>> handleIllegalArgument(IllegalArgumentException ex) {
        return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(Map.of(
                "code", "BAD_REQUEST",
                "message", ex.getMessage()));
    }
```

- [ ] **Step 5: Run tests**

Run: `mvn -q -pl query-service -am test -Dtest=QueryPathControllerParamsTest`
Expected: PASS — 4 tests.

- [ ] **Step 6: Commit**

```bash
git add query-service/src/main/java/com/co/eurekatic/query/web/path/QueryPathController.java \
        query-service/src/main/java/com/co/eurekatic/query/exception/GlobalExceptionHandler.java \
        query-service/src/test/java/com/co/eurekatic/query/web/path/QueryPathControllerParamsTest.java
git commit -m "feat(query-service): namespace path, query and body parameters"
```

---

## Task 6: `CONTEXT.*` y fin de la reescritura de SQL

**Files:**
- Modify: `query-service/src/main/java/com/co/eurekatic/query/read/QueryService.java:185-250`

- [ ] **Step 1: Rename the injected context parameters**

En el bloque `if (auth != null && auth.getPrincipal() instanceof AuthPrincipal p)`, cambia las cuatro claves:

```java
                params.addValue(ParamNamespace.CONTEXT + ".USER_ID", p.userId());
```
```java
                params.addValue(ParamNamespace.CONTEXT + ".EMAIL", p.email());
```
```java
            params.addValue(ParamNamespace.CONTEXT + ".ROLES", rolesCsv);
            params.addValue(ParamNamespace.CONTEXT + ".ROLES_ARRAY", rolesArray);
```

Actualiza el comentario del bloque, que cita los nombres viejos:

```java
        // Inyección del contexto del llamante, sacada del JWT
        // verificado y NO del cuerpo de la petición: el cliente no
        // puede falsificar su userId porque la firma la controla
        // auth-center.
        //
        // El autor del catálogo escribe SQL como
        //   CALL get_x(:CONTEXT.USER_ID, :CONTEXT.EMAIL)
        // y el procedimiento recibe la identidad verificada.
        //
        // El prefijo CONTEXT no es cosmético: es lo que distingue
        // de un vistazo lo que controla el llamante (PARAM, QUERY,
        // BODY) de lo que no. Antes se llamaban caller_* y vivían
        // en el mismo saco plano que el resto.
        //
        // Siguen siendo opcionales: los tokens anteriores a V29 no
        // llevan claim uid, y el endpoint público no tiene
        // principal. En ambos casos NO se añade el parámetro — el
        // autor del procedimiento decide qué hacer con la ausencia.
```

Añade el import:

```java
import com.co.eurekatic.common.query.ParamNamespace;
```

- [ ] **Step 2: Delete the limit/offset injection and the SQL rewriting**

Borra estas líneas:

```java
        if (req.limit() != null) {
            params.addValue("limit", req.limit());
        }
        if (req.offset() != null) {
            params.addValue("offset", req.offset());
        }
```

y sustituye el bloque de reescritura:

```java
        String sql = def.query();
        if ("SELECT".equals(mode) || "FUNCTION".equals(mode)) {
            if (req.limit() != null) {
                sql = sql + " LIMIT :limit";
            }
            if (req.offset() != null) {
                sql = sql + " OFFSET :offset";
            }
        }
```

por:

```java
        // El SQL se ejecuta tal cual está en el catálogo. Antes se
        // le concatenaba " LIMIT :limit" por detrás, de modo que lo
        // que se ejecutaba no era lo que el autor veía en el
        // formulario — y sólo en modo SELECT, ignorándose en
        // silencio para PROCEDURE. La paginación ahora la escribe
        // el autor con :QUERY.SIZE / :QUERY.OFFSET, que además le
        // da control del dialecto y del orden de las cláusulas.
        String sql = def.query();
```

- [ ] **Step 3: Run the query-service test suite**

Run: `mvn -q -pl query-service -am test`
Expected: los tests que afirmen `LIMIT :limit` o usen `:caller_*` fallan. Actualízalos a la nomenclatura nueva. Los que fallen por otra cosa, investígalos.

- [ ] **Step 4: Commit**

```bash
git add query-service/src/main/java/com/co/eurekatic/query/read/QueryService.java
git commit -m "feat(query-service): rename caller context to CONTEXT.* and stop rewriting SQL"
```

---

## Task 7: Validación, derivación de modo y herencia de dialecto en sso-admin

**Files:**
- Modify: `sso-admin/src/main/java/com/co/eurekatic/ssoadmin/service/QueryAdminService.java`
- Test: `sso-admin/src/test/java/com/co/eurekatic/ssoadmin/service/QueryDerivationTest.java` (crear)

- [ ] **Step 1: Write the failing test**

```java
package com.co.eurekatic.ssoadmin.service;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class QueryDerivationTest {

    @Test
    void derivesProcedureFromCall() {
        assertThat(QueryAdminService.deriveExecutionMode("CALL get_est(:PARAM.ID)"))
                .isEqualTo("PROCEDURE");
        assertThat(QueryAdminService.deriveExecutionMode("  call get_est()  "))
                .isEqualTo("PROCEDURE");
    }

    @Test
    void derivesSelectFromSelectAndWith() {
        assertThat(QueryAdminService.deriveExecutionMode("SELECT 1")).isEqualTo("SELECT");
        assertThat(QueryAdminService.deriveExecutionMode("with x as (select 1) select * from x"))
                .isEqualTo("SELECT");
    }

    /**
     * Un SELECT que invoca una función es indistinguible de un
     * SELECT normal — y no hacía falta distinguirlos: FUNCTION se
     * ejecutaba y se validaba exactamente igual que SELECT.
     */
    @Test
    void functionCallsDeriveAsSelect() {
        assertThat(QueryAdminService.deriveExecutionMode("SELECT * FROM mi_funcion(1)"))
                .isEqualTo("SELECT");
    }

    @Test
    void ignoresLeadingComments() {
        assertThat(QueryAdminService.deriveExecutionMode(
                "-- devuelve establecimientos\n-- por municipio\nSELECT 1"))
                .isEqualTo("SELECT");
    }

    @Test
    void rejectsSqlThatIsNeitherSelectNorCall() {
        assertThatThrownBy(() -> QueryAdminService.deriveExecutionMode("DELETE FROM t"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("SELECT")
                .hasMessageContaining("CALL");
    }

    @Test
    void rejectsEmptySql() {
        assertThatThrownBy(() -> QueryAdminService.deriveExecutionMode("   "))
                .isInstanceOf(IllegalArgumentException.class);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -q -pl sso-admin -am test -Dtest=QueryDerivationTest`
Expected: FAIL — `deriveExecutionMode` no existe.

- [ ] **Step 3: Implement the derivation**

Añade en `QueryAdminService`:

```java
    /**
     * Deduce el modo de ejecución del primer keyword del SQL.
     *
     * <p>Antes esto era un campo del formulario y el backend se
     * limitaba a comprobar que coincidiera con el SQL — pedirle al
     * admin un dato que el sistema ya podía leer, y luego reñirle
     * si no acertaba. Ahora se deriva.
     *
     * <p>FUNCTION desaparece como modo: QueryService lo trataba con
     * el mismo if que SELECT y la validación le exigía el mismo
     * primer keyword. No aportaba comportamiento, sólo una opción
     * más que equivocar.
     *
     * <p>Package-private y estático para poder probarlo sin montar
     * el servicio entero con sus repositorios.
     */
    static String deriveExecutionMode(String rawSql) {
        String sql = rawSql == null ? "" : rawSql.stripLeading();
        // Misma tolerancia a comentarios iniciales que tenía
        // validateExecutionModePrefix, que este método sustituye.
        while (sql.startsWith("--")) {
            int nl = sql.indexOf('\n');
            if (nl < 0) { sql = ""; break; }
            sql = sql.substring(nl + 1).stripLeading();
        }
        if (sql.isEmpty()) {
            throw new IllegalArgumentException(
                    "El SQL no puede estar vacío.");
        }
        String first = sql.split("\\s+", 2)[0].toUpperCase();
        if (first.equals("CALL")) {
            return "PROCEDURE";
        }
        if (first.equals("SELECT") || first.equals("WITH")) {
            return "SELECT";
        }
        throw new IllegalArgumentException(
                "El SQL debe empezar por SELECT, WITH o CALL; empieza por '"
                + first + "'. Para escribir o borrar datos usa una "
                + "definición de escritura, no una query.");
    }
```

Borra el método `validateExecutionModePrefix` y su llamada — queda subsumido: si el SQL no empieza por algo válido, `deriveExecutionMode` ya lanza.

- [ ] **Step 4: Wire derivation and dialect inheritance into `copy`**

En el método `copy(QueryRequest req, Query q, String uuid)`:

```java
        q.setType(req.type());
```
pasa a:
```java
        // El dialecto lo declara el microservicio dueño, así que
        // el admin no tiene por qué teclearlo. Antes el formulario
        // lo pedía como "Tipo" describiéndolo como etiqueta
        // opcional — y no lo era: elige el NamedParameterJdbcTemplate
        // y la clave de bulkhead. Escribir "CHART" ahí producía un
        // 502 la primera vez que se invocaba la query.
        q.setType(resolveDialect(req));
```

```java
        q.setExecutionMode(req.executionMode() == null
                ? ExecutionMode.DEFAULT
                : req.executionMode().name());
```
pasa a:
```java
        q.setExecutionMode(deriveExecutionMode(req.query()));
```

Y añade:

```java
    /**
     * Dialecto heredado del microservicio dueño. Sin microservicio
     * se conserva el comportamiento previo: null, que
     * JdbcTemplateRegistry.resolve interpreta como "postgres".
     */
    private String resolveDialect(QueryRequest req) {
        if (req.microserviceId() == null) {
            return null;
        }
        return microserviceRepo.findById(req.microserviceId())
                .map(Microservice::getDialect)
                .orElse(null);
    }
```

Si `QueryAdminService` no tiene ya `microserviceRepo`, inyéctalo por constructor igual que el resto de repositorios de la clase, y añade `import com.co.eurekatic.common.entity.Microservice;`.

- [ ] **Step 5: Validate the path template syntax**

En el método que valida la plantilla (donde hoy está el `if (tpl.contains("**"))`), sustituye ese `if` por la validación compartida:

```java
        PathTemplateSyntax.validate(tpl);
```

Añade el import:

```java
import com.co.eurekatic.common.query.PathTemplateSyntax;
```

- [ ] **Step 6: Run tests**

Run: `mvn -q -pl sso-admin -am test`
Expected: `QueryDerivationTest` pasa. Los tests existentes que envíen `executionMode` explícito o plantillas con `{}` fallan — actualízalos a la sintaxis nueva.

- [ ] **Step 7: Commit**

```bash
git add sso-admin/src/main/java/com/co/eurekatic/ssoadmin/service/QueryAdminService.java \
        sso-admin/src/test/java/com/co/eurekatic/ssoadmin/service/QueryDerivationTest.java
git commit -m "feat(sso-admin): derive execution mode and inherit dialect"
```

---

## Task 8: Migración V32

**Files:**
- Create: `postgres/migrations/V32__query_param_namespaces.sql`

- [ ] **Step 1: Write the migration**

```sql
-- =============================================================================
-- V32 — namespaces de parámetros y sintaxis :VARIABLE en path templates.
--
-- Reescribe los datos existentes para la nueva gramática. Es un cambio con
-- ruptura y se hace ahora a propósito: el 2026-08-07 el catálogo tenía 5
-- filas y sólo una con PATH_TEMPLATE. Con cincuenta filas esto ya no sería
-- barato.
--
-- El orden de los UPDATE importa: la reescritura del path va antes que la
-- del SQL porque la segunda necesita leer los nombres de variable de la
-- plantilla YA convertida.
-- =============================================================================

-- 1. Plantillas: {nombre} -> :NOMBRE
--    regexp_replace con 'g' cubre varias variables en la misma plantilla.
UPDATE QUERY
SET PATH_TEMPLATE = regexp_replace(PATH_TEMPLATE, '\{([A-Za-z_][A-Za-z0-9_]*)\}', ':\1', 'g')
WHERE PATH_TEMPLATE IS NOT NULL
  AND PATH_TEMPLATE LIKE '%{%';

UPDATE QUERY
SET PATH_TEMPLATE = upper_vars.tpl
FROM (
    SELECT q.ID_QUERY AS id,
           -- Pasa a MAYÚSCULA sólo los nombres de variable, dejando
           -- intactos los segmentos literales de la ruta.
           (SELECT string_agg(
                     CASE WHEN seg LIKE ':%' THEN upper(seg) ELSE seg END,
                     '/' ORDER BY ord)
              FROM regexp_split_to_table(q.PATH_TEMPLATE, '/')
                   WITH ORDINALITY AS s(seg, ord)) AS tpl
      FROM QUERY q
     WHERE q.PATH_TEMPLATE IS NOT NULL
) AS upper_vars
WHERE QUERY.ID_QUERY = upper_vars.id
  AND upper_vars.tpl IS NOT NULL;

-- 2. Binds de las variables de ruta en el SQL: :nombre -> :PARAM.NOMBRE
--    Sólo se tocan los nombres que son variables de ESA plantilla; un
--    :otro_bind que no aparezca en la ruta se deja intacto. La sustitución
--    necesita iterar los nombres de variable fila a fila, cosa que un
--    UPDATE plano no expresa bien, así que va en un bloque procedural.
DO $$
DECLARE
    r        RECORD;
    var_name TEXT;
    new_sql  TEXT;
BEGIN
    FOR r IN
        SELECT ID_QUERY, PATH_TEMPLATE, QUERY
          FROM QUERY
         WHERE PATH_TEMPLATE IS NOT NULL
    LOOP
        new_sql := r.QUERY;
        FOR var_name IN
            SELECT upper(substring(seg FROM 2))
              FROM regexp_split_to_table(r.PATH_TEMPLATE, '/') AS seg
             WHERE seg LIKE ':%'
        LOOP
            -- \m y \M son límites de palabra en Postgres. Sin ellos,
            -- :id reescribiría también el prefijo de :identificador.
            new_sql := regexp_replace(
                new_sql,
                ':\m' || var_name || '\M',
                ':PARAM.' || var_name,
                'gi');
        END LOOP;
        IF new_sql IS DISTINCT FROM r.QUERY THEN
            UPDATE QUERY SET QUERY = new_sql WHERE ID_QUERY = r.ID_QUERY;
        END IF;
    END LOOP;
END $$;

-- 3. Contexto del llamante: caller_* -> CONTEXT.*
--    ROLES_ARRAY va ANTES que ROLES: si no, el prefijo común corrompe
--    el nombre largo y :caller_roles_array acabaría como
--    :CONTEXT.ROLES_array.
UPDATE QUERY SET QUERY = replace(QUERY, ':caller_roles_array', ':CONTEXT.ROLES_ARRAY')
 WHERE QUERY LIKE '%:caller_roles_array%';
UPDATE QUERY SET QUERY = replace(QUERY, ':caller_user_id', ':CONTEXT.USER_ID')
 WHERE QUERY LIKE '%:caller_user_id%';
UPDATE QUERY SET QUERY = replace(QUERY, ':caller_email', ':CONTEXT.EMAIL')
 WHERE QUERY LIKE '%:caller_email%';
UPDATE QUERY SET QUERY = replace(QUERY, ':caller_roles', ':CONTEXT.ROLES')
 WHERE QUERY LIKE '%:caller_roles%';

-- 4. FUNCTION deja de existir como modo: se ejecutaba y validaba igual
--    que SELECT, así que la conversión es exacta, no una aproximación.
UPDATE QUERY SET EXECUTION_MODE = 'SELECT' WHERE EXECUTION_MODE = 'FUNCTION';

-- 5. TYPE (el dialecto) se hereda del microservicio dueño cuando falte.
UPDATE QUERY q
SET TYPE = m.DIALECT
FROM MICROSERVICE m
WHERE q.MICROSERVICE_ID = m.ID_MICROSERVICE
  AND m.DIALECT IS NOT NULL
  AND (q.TYPE IS NULL OR q.TYPE = '');

COMMENT ON COLUMN QUERY.PATH_TEMPLATE IS
    'Ruta dentro del microservicio con variables :MAYUSCULA (ej /establecimiento/:NOMBRE). Componer con MICROSERVICE.REQUEST_URI para la URL completa. Los valores se bindean como :PARAM.<VARIABLE>. NULL = sólo accesible vía POST /<svc>/query (legacy).';
```

- [ ] **Step 2: Verify the migration syntax**

Si tienes Docker, contra un Postgres desechable:

```bash
docker run --rm -d --name v32check -e POSTGRES_PASSWORD=x -p 55432:5432 postgres:16
sleep 8
docker exec -i v32check psql -U postgres -c "CREATE TABLE QUERY (ID_QUERY serial primary key, PATH_TEMPLATE varchar(500), QUERY text, EXECUTION_MODE varchar(20), TYPE varchar(50), MICROSERVICE_ID bigint);"
docker exec -i v32check psql -U postgres -c "CREATE TABLE MICROSERVICE (ID_MICROSERVICE bigint primary key, DIALECT varchar(50));"
docker exec -i v32check psql -U postgres -c "INSERT INTO MICROSERVICE VALUES (8,'postgres'); INSERT INTO QUERY (PATH_TEMPLATE, QUERY, EXECUTION_MODE, MICROSERVICE_ID) VALUES ('/establecimiento/{nombre}', 'SELECT * FROM t WHERE nombre like :nombre', 'SELECT', 8);"
docker exec -i v32check psql -U postgres < postgres/migrations/V32__query_param_namespaces.sql
docker exec -i v32check psql -U postgres -c "SELECT PATH_TEMPLATE, QUERY, TYPE FROM QUERY;"
docker rm -f v32check
```

Expected:
```
      path_template       |                    query                          |   type
--------------------------+---------------------------------------------------+----------
 /establecimiento/:NOMBRE | SELECT * FROM t WHERE nombre like :PARAM.NOMBRE   | postgres
```

Sin Docker, revisa el SQL a ojo y confía en el despliegue a test — pero **anótalo en el PR** para que quien lo revise lo sepa.

- [ ] **Step 3: Commit**

```bash
git add postgres/migrations/V32__query_param_namespaces.sql
git commit -m "feat(db): migrate path templates and binds to namespaced syntax"
```

---

## Task 9: Formulario del admin-ui

**Files:**
- Modify: `admin-ui/src/pages/queries/QueryFormDrawer.tsx`
- Modify: el fichero de `admin-ui/src/schemas/` que define `queryFormSchema`

- [ ] **Step 1: Locate the schema**

Run: `grep -rn "queryFormSchema" admin-ui/src/schemas/`

- [ ] **Step 2: Drop the two fields from the schema**

Quita `type` y `executionMode` de `queryFormSchema` y de `QueryFormValues`. Si `pathTemplate` tiene validación, cámbiala para rechazar `{}` y exigir variables en mayúscula:

```ts
pathTemplate: z
  .string()
  .nullable()
  .optional()
  .refine(
    (v) => !v || !v.includes("{"),
    "La sintaxis {variable} ya no se admite — usa :VARIABLE en MAYÚSCULA",
  )
  .refine(
    (v) => !v || !/:[a-z]/.test(v),
    "Los nombres de variable van en MAYÚSCULA (ej :NOMBRE)",
  ),
```

- [ ] **Step 3: Remove both inputs from the form**

En `QueryFormDrawer.tsx`:

- Borra el bloque del campo `Tipo` (el `label="Tipo"` con su `value={values.type}` y su `onChange`).
- Borra el bloque del `select` de `Modo de ejecución`, incluyendo el `<label>` y la lógica que ramifica sobre `values.executionMode === "PROCEDURE"` / `"FUNCTION"` para mostrar u ocultar `outParamNames`.
- Quita `type` y `executionMode` de los `defaultValues` (líneas 67 y 74).

Para `outParamNames`, que antes se mostraba según el modo: pásalo a mostrarse cuando el SQL empiece por `CALL`, que es la misma condición ahora derivada:

```tsx
{/^\s*call\b/i.test(values.query ?? "") && (
  // ... el bloque de outParamNames tal cual estaba
)}
```

- [ ] **Step 4: Show what was derived**

Debajo del campo SQL, añade un texto no editable para que siga siendo visible qué se va a guardar:

```tsx
<p className="text-sm text-muted-foreground">
  Modo de ejecución:{" "}
  <strong>
    {/^\s*call\b/i.test(values.query ?? "") ? "PROCEDURE" : "SELECT"}
  </strong>{" "}
  — derivado del SQL. El dialecto lo hereda del microservicio.
</p>
```

- [ ] **Step 5: Update the parameter hints**

Sustituye el texto de ayuda del SQL, que cita los nombres viejos:

```tsx
<p className="text-sm text-muted-foreground">
  Los parámetros llevan prefijo según su origen:{" "}
  <code>:PARAM.X</code> (variables de la ruta),{" "}
  <code>:QUERY.X</code> (query string),{" "}
  <code>:BODY.X.Y</code> (cuerpo JSON) y{" "}
  <code>:CONTEXT.USER_ID</code>, <code>:CONTEXT.EMAIL</code>,{" "}
  <code>:CONTEXT.ROLES</code>, <code>:CONTEXT.ROLES_ARRAY</code>{" "}
  (del JWT, no los envía el cliente). La paginación la escribes tú:{" "}
  <code>LIMIT :QUERY.SIZE OFFSET :QUERY.OFFSET</code>.
</p>
```

Y el de `Path template`:

```tsx
hint="Sufijo de URL DENTRO del microservicio. Variables con :MAYÚSCULA (ej /establecimiento/:NOMBRE), que se bindean como :PARAM.NOMBRE. Vacío = sólo accesible vía POST /<svc>/query (legacy)."
```

- [ ] **Step 6: Run the front-end checks**

```bash
cd admin-ui && npm run typecheck && npm run lint && npm test
```
Expected: PASS. Si `QueriesAdminPage.test.tsx` o `QueryFormDrawer` tienen tests que afirmen los campos borrados, actualízalos.

- [ ] **Step 7: Commit**

```bash
git add admin-ui/src/pages/queries/QueryFormDrawer.tsx admin-ui/src/schemas/
git commit -m "feat(admin-ui): drop derived fields and document parameter namespaces"
```

---

## Task 10: Documentación y verificación end-to-end

**Files:**
- Modify: `README.md` (sección "Queries as REST endpoints (V27 + V28 + V29)")

- [ ] **Step 1: Update the README example**

Sustituye el ejemplo que usa la sintaxis vieja:

````markdown
```
POST /api/eval-col/municipio/404/establecimientos?SIZE=20&OFFSET=0
Authorization: Bearer <jwt, uid=42, roles=[EVALUADOR]>
{ "filtros": { "zona": 214 } }

PATH_TEMPLATE = /municipio/:MUNICIPIO/establecimientos

SELECT pk_establecimiento, nombre
FROM testablecimiento
WHERE fk_tmunicipio        = CAST(:PARAM.MUNICIPIO AS bigint)
  AND fk_tlista_valor_zona = CAST(:BODY.FILTROS.ZONA AS bigint)
  AND fk_tfuncionario_rector = :CONTEXT.USER_ID
LIMIT :QUERY.SIZE OFFSET :QUERY.OFFSET
```

| Prefijo | Origen | Lo controla |
|---|---|---|
| `:PARAM.*` | variables de la ruta | quien llama |
| `:QUERY.*` | query string | quien llama |
| `:BODY.*` | cuerpo JSON | quien llama |
| `:CONTEXT.*` | JWT verificado | el sistema |
````

Actualiza también la tabla de la sección que menciona `QUERY.EXECUTION_MODE` como campo editable y el claim `uid` como `:caller_user_id`.

- [ ] **Step 2: Full build**

Run: `mvn -q test`
Expected: PASS en todos los módulos.

- [ ] **Step 3: Commit and open the PR**

```bash
git add README.md
git commit -m "docs: document parameter namespaces in the query catalog"
git push -u origin <rama>
gh pr create --base main --title "feat: parameter namespaces and :VARIABLE path syntax"
```

- [ ] **Step 4: Verify against the test host after deploy**

Una vez CI despliegue, y **tras re-provisionar `query-service-eval-col`** para que tome la imagen nueva:

```bash
TOKEN=$(curl -s -X POST http://172.233.184.248:8080/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@example.com","password":"<pass>"}' \
  | sed -E 's/.*"token":"([^"]+)".*/\1/')

# 1. El bug de los espacios, que era el origen de todo
curl -s -X POST "http://172.233.184.248:8080/api/eval-col/establecimiento/PRUDENCIA%20DAZA" \
     -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{}'
```
Expected: una fila con `"nombre":"PRUDENCIA DAZA"`. **Éste es el criterio de aceptación real** — hoy devuelve `{"rows":[]}`.

```bash
# 2. Sin token
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
     "http://172.233.184.248:8080/api/eval-col/establecimiento/X" \
     -H "Content-Type: application/json" -d '{}'
```
Expected: `401`.

```bash
# 3. Ruta no registrada
curl -s -X POST "http://172.233.184.248:8080/api/eval-col/noexiste/x" \
     -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{}'
```
Expected: `404` con `"No query registered for path"`.

```bash
# 4. Colisión de caja
curl -s -X POST "http://172.233.184.248:8080/api/eval-col/establecimiento/X?estado=a&ESTADO=b" \
     -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{}'
```
Expected: `400` mencionando `ESTADO`.

---

## Cobertura del spec

| Requisito del spec | Tarea |
|---|---|
| Namespaces PARAM/QUERY/BODY/CONTEXT | 2, 5, 6 |
| Normalización de claves + 400 por colisión | 2, 5 |
| Sin reescritura de SQL (LIMIT/OFFSET) | 6 |
| Legacy `/query` sin namespacear | 6 (no se toca `req.params()`) |
| Sintaxis `:MAYÚSCULA` + rechazo de `{}`, minúsculas, `**` | 1, 7, 9 |
| `PathPatternParser` y decodificación | 4 |
| `%2F` no inyecta segmentos | 4 |
| Derivación del modo, retirada de FUNCTION | 7, 9 |
| Herencia del dialecto | 7, 9 |
| Migración de datos | 8 |
| Test de binds con punto | 3 |
| Test de espacios y acentos | 4, 10 |
