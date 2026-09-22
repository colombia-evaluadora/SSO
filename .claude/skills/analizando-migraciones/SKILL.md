---
name: analizando-migraciones
description: >-
  Responde qué migración define hoy un objeto, qué quedó obsoleto tras una
  edición, qué firmas cambiaron y qué llamadores se quedaron desalineados, y
  cuál es el siguiente V<n> realmente libre. Corre
  scripts/migration-analysis/analyze_migrations.py y lee su modelo JSON. Usar
  tras crear o editar una migración, antes de decidir un número de versión, al
  investigar por qué un endpoint responde 500 tras un deploy, o cuando se pida
  el informe de análisis de migraciones.
---

# Analizando migraciones

`postgres/migrations/` tiene más de 400 ficheros y casi todos reescriben algo de
otro anterior. La pregunta útil casi nunca es "¿qué dice esta migración?" sino
**"¿qué de lo que dice sigue vivo?"**. Eso no se contesta leyendo: se contesta
con el modelo que construye el analizador.

## Lo que hay que saber antes de correrlo

El analizador atribuye cada sentencia a un objeto y las ordena por versión.
Sobre cada objeto conviven **dos cadenas**: la de *identidad* (existe) y la de
*cuerpo* (lo que dice hoy). Un `CREATE OR REPLACE` posterior mata el cuerpo
anterior pero no la identidad; un `DROP` mata las dos. Un parche
(`ALTER TABLE`, cambiar solo `param_types`) deriva del estado anterior: no lo
mata, lo modifica.

De ahí salen los veredictos: `obsoleta`, `residual`, `parcial`, `viva`,
`solo-binds` y `sin-cambios`.

**Una migración obsoleta no se borra.** Rompería el checksum de Flyway en los
servidores que ya la aplicaron. El informe sirve para saber qué texto ya no
describe el estado real, no para limpiar el directorio.

## Cómo se usa

```bash
git fetch --all --quiet          # el techo de version se calcula contra TODAS las ramas
python scripts/migration-analysis/analyze_migrations.py --json modelo.json
```

- Sin argumentos escribe `docs/auditoria/migraciones-analisis.html`, que está
  **gitignored**: es un documento local y nunca se commitea.
- `--json <fichero>` es lo que interesa para leerlo tú. **No parsees el HTML.**
- `--from N --to M` acota el rango; `--no-git` salta el cálculo del techo.
- Solo stdlib, Python 3.10+.

Si el script avisa de que no pudo usar `git`/`origin`, **dilo**: el techo de
versión no es fiable y hay que resolverlo con `scan.sh`.

## Para una pregunta concreta, no corras el informe entero

`deps.py` lee el mismo modelo y contesta directo:

```bash
python .claude/skills/next-migration-number/deps.py fn_actividad_listar
python .claude/skills/next-migration-number/deps.py /planeador/actividades
python .claude/skills/next-migration-number/deps.py --version 224
```

Imprime quién define el objeto hoy, su historial con las versiones muertas, si
la firma cambió y qué migraciones lo usan. Cachea el modelo en temp; `--refresh`
lo recalcula tras editar migraciones.

Regla práctica: **`deps.py` para una pregunta, el informe para una revisión.**

## Qué mirar tras editar una migración

1. **Firmas cambiadas** — si la aridad cambió, hace falta
   `DROP FUNCTION IF EXISTS` de la firma vieja o quedan dos sobrecargas vivas
   (42725).
2. **Llamadores desalineados** — la causa habitual de que un endpoint responda
   500 justo después del deploy.
3. **Qué quedó obsoleto** — si tu edición mató el cuerpo de algo que otra
   migración posterior ya había reescrito, la estás revirtiendo: ver la skill
   `reaplicando-migraciones`.
4. **Siguiente `V<n>` libre y huecos** — un hueco casi nunca es un número libre.

## Dónde vive cada pieza

El código está en `scripts/migration-analysis/` y no en esta skill a propósito:
lo usan también dos hooks, dos comandos, dos agentes, `generar-mapa.py` y el
propio `migration-lint.py` (que importa su `sqlscan`). Es infraestructura
compartida; esta skill es la puerta de entrada, no su dueña.

`scripts/migration-analysis/README.md` tiene la referencia completa de
veredictos, cobertura por tipo de sentencia y límites del análisis.
