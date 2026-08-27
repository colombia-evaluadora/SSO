---
name: next-migration-number
description: >-
  Calcula el siguiente número de migración Flyway (V<n>) libre revisando
  TODAS las ramas de origin, no solo la actual. Usar antes de crear cualquier
  migración en postgres/migrations/.
disable-model-invocation: true
---

# next-migration-number

Regla de `CLAUDE.md`: el siguiente `V<n>` se calcula contra **todas las ramas
de `origin`**, porque dos ramas que numeran a la vez producen una colisión
que solo revienta al mergear la segunda (historial: V53, V59, V66, V123,
V136-V145).

## Uso

```bash
bash .claude/skills/next-migration-number/scan.sh
```

Imprime: el `V<n>` máximo por rama, el máximo global, y el siguiente libre
sugerido. Si hay PRs abiertas que aún no están en `origin/*`, verifícalas a
mano con `gh pr list` (skill `github-actions`).

## Después

- Si el cambio pedido corresponde a una migración ya existente, **no** uses
  un número nuevo: edítala (ver agente `flyway-migration-author`).
- Confirma el techo REAL aplicado en el servidor de test con la skill
  `/server-status` antes de asumir que un hueco bajo está libre.
