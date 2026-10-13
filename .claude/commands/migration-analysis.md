---
description: Regenera docs/auditoria/migraciones-analisis.html con scripts/migration-analysis y resume obsoletas, firmas cambiadas, llamadores desalineados y el siguiente V<n> libre
argument-hint: '[--from N --to M] [--open] [migraciones concretas en las que centrarse]'
allowed-tools: 'Bash(git fetch:*), Bash(python scripts/migration-analysis informe:*), Read'
context: fork
---

Regenera el informe HTML del análisis de migraciones Flyway
(`docs/auditoria/migraciones-analisis.html`, gitignored: documento local,
**nunca** se commitea) y devuelve solo el resumen. Corre en un subagente para
que la salida del analizador no llene la conversación principal.

Cómo se leen los veredictos, cuándo basta `deps.py` en vez del informe entero y
por qué una migración obsoleta no se borra a la ligera: skill
`analizando-migraciones`. Referencia completa: `scripts/migration-analysis/README.md`.

## Pasos

1. `git fetch --all --quiet` — el techo de versión se calcula contra TODAS las
   ramas de `origin` (regla de CLAUDE.md).
2. Genera el HTML y, a la vez, el modelo JSON para leerlo:
   `python scripts/migration-analysis informe --json "$TMP/migraciones-modelo.json" [flags]`
   (stdlib, Python 3.10+). De `$ARGUMENTS` pasa al script solo los flags
   (`--from N --to M`, `--open`); los nombres de migraciones son para centrar
   el resumen. Usa el scratchpad para el JSON; **no** parsees el HTML.
3. Confirma que el HTML se escribió (ruta, tamaño, fecha).
4. Si el script avisa que no pudo usar `git`/`origin`, dilo explícitamente: el
   techo de versión no es fiable, remite a `/next-migration-number`.

## Qué reportar

- Total de migraciones analizadas y rango.
- Veredictos: obsoletas / residuales / parciales / vivas / solo-binds /
  sin-cambios, con los `V<n>` concretos de obsoletas y residuales.
- Cambios de firma y **llamadores desalineados** (SQL y Java) con
  `archivo:línea` — son candidatos: el conteo de argumentos es textual.
- Funciones sin llamadores y sentencias no clasificadas (cobertura).
- Siguiente `V<n>` libre, huecos de numeración y números que solo existen en
  `origin` (falta pull).
- Si te pasaron migraciones concretas (p. ej. las de la rama actual), céntrate
  en ellas: qué reescriben, a quién dejan obsoleto y si rompen alguna firma.

No propongas borrar migraciones obsoletas: eso es la skill
`limpiando-migraciones`, con su banco y sus gates.
