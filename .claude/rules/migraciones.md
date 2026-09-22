---
paths:
  - "postgres/**"
  - "scripts/migration-lint.py"
  - "scripts/migration-analysis/**"
---

# Reglas — Postgres y migraciones (`postgres/`)

Aplican a todo `postgres/migrations/`. Complementan el `CLAUDE.md` raíz.

## Orden de trabajo

No se empieza escribiendo SQL. Se empieza averiguando **qué archivo tocar**:

```bash
python .claude/skills/next-migration-number/deps.py <fn|ruta>   # quién lo define hoy
python .claude/skills/next-migration-number/deps.py --version N # de qué depende
bash .claude/skills/next-migration-number/scan.sh               # número libre real
```

Si el objeto ya tiene dueña, **se edita esa migración**; solo se crea un `V<n>`
nuevo cuando el objeto no existe o la funcionalidad convive con la vieja.
`docs/MAPA.md` da el índice dominio → función → migración.

## Skills y agentes

| Trabajo | Usar |
|---|---|
| Crear/editar/revisar una migración | agente `flyway-migration-author` |
| Funciones, triggers, PL/pgSQL | skill `plpgsql` |
| SQL, índices, constraints, performance | skill `postgresql` |
| Versionado y patrones Flyway | skill `flyway-migrations` |
| SQL portado desde Oracle | skill `reviewing-oracle-to-postgres-migration` |
| Endpoint de `query-service` | `/new-query-endpoint` + agente `query-service-endpoint-builder` |
| Saber qué quedó obsoleto tras editar | agente `migration-analysis-reporter` |
| El servidor no se comporta como el repo | agente `server-drift-detector` |

## Anatomía de una función de endpoint

Una función de endpoint es un **wrapper delgado**: valida permisos y delega. La
lógica vive en un **núcleo sin gate**, que otro endpoint, un trigger, un reporte
o una exportación pueden reutilizar sin volver a pedir permisos.

```sql
-- wrapper: el único que sabe de permisos
CREATE OR REPLACE FUNCTION fn_matricula_config_crear(p_pk_usuario BIGINT, ...)
...
  PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario, 'MATRICULA', 'CREAR', ...);
  RETURN academico_test.fn_matricula_config_crear_interno(...);
```

- **El gate va solo en el wrapper**: una llamada a `fn_assert_permiso_seccion` /
  `fn_*_gate_escritura` / `fn_planeador_assert_alcance` al principio, y delegar.
- **El núcleo no recibe `p_pk_usuario_solicitante`** salvo para auditoría. Si lo
  necesita para decidir *qué* devuelve, eso es scope: se resuelve en el wrapper
  y se le pasa ya resuelto como filtro.
- **Nombre del núcleo: sufijo `_interno`** (precedente vivo:
  `fn_matricula_config_crear_interno`, V159). No `_core` ni `_impl`.
- **`COMMENT ON FUNCTION`:** el wrapper empieza por la ruta HTTP; el núcleo
  empieza por `INTERNO:` y nombra quién lo reutiliza.
- **Antes de escribir un núcleo, busca uno que sirva** con `deps.py`. Reutilizar
  es el objetivo, no un efecto secundario.
- **Reportes y exportaciones no crean función propia:** llaman al mismo núcleo
  que la pantalla. Una `fn_*_reporte_listar` aparte diverge de su `fn_*_listar`
  en cuanto una de las dos se toca (pasó con V186-V190).
- **Refactor incremental:** si ya vas a editar una función que lleva el gate en
  línea, pártela en wrapper + núcleo **en esa misma migración**. No hay refactor
  masivo de las funciones existentes.

Por qué: cuando el gate va dentro de la lógica, la lógica no se puede reutilizar.
La cabecera de `V130__listar_sin_paginar_para_reportes.sql` lo dice — se descartó
crear funciones de reporte porque "duplicaría el WHERE y el gate de autorización
de cada listado", y hubo que meter `p_page_size NULL` a la función existente.

## Restricciones

- **Numeración contra TODAS las ramas de `origin`.** Dos ramas que numeran a la
  vez no chocan hasta que se mergea la segunda, y ahí Flyway rechaza el
  despliegue entero (V53, V59, V66, V123, V136-V145).
- **Los huecos no son números libres.** Casi siempre son una rama borrada o una
  migración ya aplicada en un servidor. Reutilizar uno es una decisión explícita
  de orden (out-of-order), confirmada antes con `/server-status`.
- **Idempotencia obligatoria:** `IF NOT EXISTS`, `DROP ... IF EXISTS`, `DELETE`
  por `uuid` antes del `INSERT`. Toda migración debe poder reaplicarse.
- **Cambiar la aridad de una función exige `DROP FUNCTION IF EXISTS`** de la
  firma vieja, o quedan dos sobrecargas vivas.
- **Gate de permisos explícito** en todo endpoint, con su menú y capability. Los
  CODIGO de menú van **sin tildes** y se comparan exactos.
- **Catálogos por texto, nunca por pk.** Los `pk_tlista_valor` difieren entre el
  servidor de test y un Postgres limpio, y el catálogo de `TROL` no está en las
  migraciones: llega por el dump base.
- **Tabla nueva ⇒ declarar auditoría** (V26/V276).
- **Mensajes de error con nombre legible**, no solo el PK.
- **Sin auto-referencias** al propio `V<n>` dentro del cuerpo de una función: la
  función sobrevive a su migración.
- **Presupuesto de comentarios:** cabecera ≤ 12 líneas (qué hace / por qué aquí /
  depende de) y ≤ 20% de comentarios. La historia va al commit o al PR.

## Validación

- **Siempre contra el Postgres local** (contenedor `sso-postgres`), **nunca**
  contra un servidor. El servidor es para diagnosticar, no para probar, y lo que
  se aplica ahí no tiene deshacer: el hook `no-prod.sh` bloquea los comandos que
  escriben en su base (los hosts están en `.claude/hooks/hosts-prod.txt`). Leer
  —`SELECT`, `\df`, `flyway info`, `pg_dump`— sigue permitido.
- `.github/scripts/check-flyway-migrations.sh` corre el historial completo sobre
  un Postgres limpio y luego reaplica lo nuevo, que es la prueba de idempotencia.

## Al cerrar

```bash
python scripts/migration-lint.py --all        # sin errores nuevos
python scripts/migration-analysis/analyze_migrations.py
python scripts/generar-mapa.py                # si cambiaron funciones o endpoints
```

El lint corre además como hook al editar cualquier `.sql` de este directorio.
Sus reglas no se silencian: si una no aplica en un caso concreto, se dice por
qué en la respuesta.
