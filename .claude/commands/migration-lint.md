---
description: Lint de invariantes sobre las migraciones (reglas de regresiones reales)
argument-hint: '[archivo.sql | --all | --from N] [--no-baseline]'
allowed-tools: 'Bash(python scripts/migration-lint.py:*), Read, Edit'
---

Corre `python scripts/migration-lint.py $ARGUMENTS` (sin argumentos: `--all`).

Cada regla viene de una regresión que ya ocurrió en este repo:

| Regla | Severidad | Qué atrapa |
|---|---|---|
| `QUERY-ON-CONFLICT` | error | `INSERT` en `public.query` con `ON CONFLICT DO NOTHING` sin `DELETE` previo por uuid: no-op silencioso (V253/V279) |
| `GATE-TILDES` | error | literal con tildes pasado a un gate de menú: el CODIGO real no las lleva y la comparación es exacta → 42501 (V396) |
| `FIRMA-SIN-DROP` | error | cambio de aridad sin `DROP FUNCTION IF EXISTS`: quedan dos sobrecargas vivas |
| `AUTO-REFERENCIA` | error | el cuerpo de una función nombra su propio `V<n>` |
| `MOJIBAKE` | error | fichero guardado en cp1252 en vez de UTF-8 |
| `TABLA-SIN-CDC` | aviso | `CREATE TABLE` (≥ V276) sin `fn_audit_declarar` |
| `PK-CATALOGO` | aviso | `fk_tlista_valor* = <numero>`: los pk no son estables entre bases |
| `SEED-POR-CODIGO` | aviso | seed sobre `TROL` por `CODIGO`: no-op en CI, los roles vienen del dump base |
| `COMENTARIOS` / `CABECERA` | aviso | presupuesto de ≤20% de comentarios y ≤12 líneas de cabecera |

**Baseline.** Las 330 migraciones existentes no se pueden reescribir sin romper
checksums, así que su deuda está congelada en
`scripts/migration-lint-baseline.json` y por defecto **solo se reporta lo
nuevo**. Con `--no-baseline` sale todo, útil para auditar.

Al terminar:

1. Si hay **errores**, corrígelos y vuelve a correr. Si en un caso concreto la
   regla no aplica, dilo explícitamente en la respuesta con el motivo; no
   silencies la regla en el script ni metas el hallazgo al baseline.
2. Si añadiste una migración legítima que dispara un aviso aceptado a
   propósito, `--baseline-write` solo tras acordarlo con el usuario: congela
   **todo** lo pendiente, no solo ese hallazgo.
3. Resume: hallazgos por regla, cuáles corregiste y cuáles quedan justificados.
