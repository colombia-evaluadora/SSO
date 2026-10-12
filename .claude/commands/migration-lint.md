---
description: Lint de invariantes sobre las migraciones (reglas de regresiones reales)
argument-hint: '[archivo.sql | --all | --from N] [--no-baseline]'
allowed-tools: 'Bash(python scripts/migration-analysis lint:*), Read, Edit'
---

Corre `python scripts/migration-analysis lint $ARGUMENTS` (sin argumentos: `--all`).

Cada regla viene de una regresión que ya ocurrió en este repo:

| Regla | Severidad | Qué atrapa |
|---|---|---|
| `QUERY-ON-CONFLICT` | error | `INSERT` en `public.query` con `ON CONFLICT DO NOTHING` sin `DELETE` previo por uuid: no-op silencioso (V253/V279) |
| `GATE-TILDES` | error | literal con tildes pasado a un gate de menú: el CODIGO real no las lleva y la comparación es exacta → 42501 (V396) |
| `FIRMA-SIN-DROP` | error | cambio de aridad sin `DROP FUNCTION IF EXISTS`: quedan dos sobrecargas vivas |
| `AUTO-REFERENCIA` | error | el cuerpo de una función nombra su propio `V<n>` |
| `MOJIBAKE` | error | fichero guardado en cp1252 en vez de UTF-8 |
| `COMENTARIOS` / `CABECERA` | **error** en una migración que no está en `origin/dev`; aviso en las demás | presupuesto de ≤20% de comentarios y ≤12 líneas de cabecera |
| `TABLA-SIN-CDC` | aviso | `CREATE TABLE` (≥ V276) sin `fn_audit_declarar` |
| `PK-CATALOGO` | aviso | `fk_tlista_valor* = <numero>`: los pk no son estables entre bases |
| `SEED-POR-CODIGO` | aviso | seed sobre `TROL` por `CODIGO`: no-op en CI, los roles vienen del dump base |
| `GATE-EN-LINEA` / `WRAPPER-GORDO` | aviso | 42501 a mano en vez de un helper de permisos; wrapper con lógica en vez de delegar en `_interno` |
| `BORRADO-SIN-GUARDA` | aviso | `_eliminar` sin comprobar dependientes (23503) |
| `FN-REPORTE-DUPLICADA` | aviso | `fn_x_reporte_*` / `_exportar` junto a un `fn_x_listar`: divergirán |
| `COMMENT-LARGO` | aviso | `COMMENT ON FUNCTION` de más de 600 caracteres: contrato, no historia |
| `BIND-SIN-TIPO` | aviso | bind del SQL de un endpoint sin tipo en `param_types`, o sin mayúsculas: 500 en vez de 400 |
| `LISTADO-PLAN-GENERICO` | aviso | lectura PL/pgSQL con 3+ filtros `(p_x IS NULL OR ...)` sin `plan_cache_mode = force_custom_plan` |

**Baseline.** Las migraciones ya desplegadas arrastran deuda que no vale la
pena reescribir de golpe, así que está congelada en
`scripts/migration-analysis/comandos/lint-baseline.json` y por defecto **solo se reporta lo
nuevo**. Con `--no-baseline` sale todo, útil para auditar. Una regla que nace o
cambia congela solo su deuda, en el mismo PR:
`lint --all --baseline-regla <CODIGO>`.

Al terminar:

1. Si hay **errores**, corrígelos y vuelve a correr. Si en un caso concreto la
   regla no aplica, dilo explícitamente en la respuesta con el motivo; no
   silencies la regla en el script ni metas el hallazgo al baseline.
2. Si añadiste una migración legítima que dispara un aviso aceptado a
   propósito, `--baseline-write` solo tras acordarlo con el usuario: congela
   **todo** lo pendiente, no solo ese hallazgo.
3. Resume: hallazgos por regla, cuáles corregiste y cuáles quedan justificados.
