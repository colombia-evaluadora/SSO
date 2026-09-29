---
name: limpiando-migraciones
description: >-
  Borra o recorta el codigo muerto de migraciones Flyway sin regresiones:
  diagnostico por firma exacta y contexto de uso, plan de recorte, banco de dos
  Postgres locales con huella de esquema/permisos/datos, simulacion del deploy
  (repair + re-aplicacion) y gates. Usar cuando se pida borrar migraciones
  obsoletas, quitar codigo muerto de una migracion, reducir su tamano o sus
  comentarios, o revisar si una migracion "obsoleta" del informe de analisis se
  puede eliminar.
---

# Limpiando migraciones

El objetivo es que **nada cambie en la base**: una base limpia y una ya
desplegada tienen que quedar logicamente identicas a las de `dev` despues del
recorte. El informe de analisis (`/migration-analysis`) sirve para elegir
candidatas; su porcentaje de "sin efecto" engaña en los dos sentidos, asi que
nunca se decide con el. No commitees hasta que el paso 5 salga limpio.

Herramientas de esta skill (todas locales, nunca contra un servidor):

| Script | Para que |
|---|---|
| `propuesta.py V<n> ...` | Esqueleto del plan de recorte + lista `REVISAR` (stderr) |
| `recorte.py plan.json` | Aplica el plan copiando sentencias literales de `origin/dev` |
| `banco.sh arranque\|comparar\|deploy V<n>...\|limpiar` | Banco de dos Postgres 16 + Flyway 11 |
| `huella.sql`, `binds.sql`, `datos.sql` | Esquema, permisos por nombre, contenido de tablas |
| `usos.py V<n> ...` | Usos que se ejecutan al migrar y se quedaron sin definicion |

Y las del repo: `scripts/migration-analysis/analyze_migrations.py` (modelo),
`.claude/skills/next-migration-number/deps.py` (+ `precision.py`),
`scripts/migration-reapply-set.py`, `scripts/migration-orden.py`,
`scripts/migration-lint.py`, `scripts/generar-mapa.py`, `scan.sh`.

## 0. Rama

```bash
git fetch origin --quiet
git switch -c chore/limpieza-migraciones-muertas-<n> --no-track origin/dev
```

Nunca sobre `dev`/`main`. `--no-track` evita que un `git push` a secas vaya a dev.

## 1. Diagnostico

```bash
python .claude/skills/next-migration-number/deps.py --refresh --version <n>   # cada candidata
python .claude/skills/limpiando-migraciones/propuesta.py <n> <n> > plan.json
```

La seccion **PRECISION** de `deps.py` lee por firma exacta y por contexto:

| Aviso | Que hacer |
|---|---|
| `VIVA POR FIRMA` | Sobrecarga viva: otra firma posterior no la reemplaza. **No se quita.** |
| `MUERTA` | Se puede quitar. |
| `MUERTA PERO NECESARIA` | Algo la ejecuta al migrar (DO, backfill, trigger, `LANGUAGE sql`, tambien en el propio fichero). Se conserva con `solo_si_falta` (CREATE condicionado a `to_regprocedure(...) IS NULL`). |
| `DROP PELIGROSO` | Borraria la vigente al re-aplicar: se quita junto con su `CREATE`. |
| `ALTER POSTERIOR` | Si la funcion se queda, copiar la clausula (`ROWS 1`...) a su `CREATE`. |
| `BACKFILL` | Re-aplicar recalcula datos con las reglas de hoy. Si cambia datos reales (notas, estados), **no editar el fichero**. |
| `VERIFICACION` | `DO` con `RAISE EXCEPTION` sobre conteos: si ya no se cumple tumba el deploy. Se quita. |
| `SEMILLA NECESARIA` | Fila/rol/extension que migraciones intermedias usan. Se queda (idempotente). |
| `PARCHE 'PISADO'` | Mirar el `WHERE` de la posterior: si toca otras filas, sigue vivo. |

Usos (`deps.py <funcion>`): `migracion` y `sql-body` atan el orden; `plpgsql`
(enlace tardio) y `texto` (filas de `public.query`, comentarios) no.

## 2. Revision del plan (a mano)

`propuesta.py` deja por defecto lo dudoso DENTRO (`mantener`). Revisa cada
`REVISAR` y ademas:

- **Retorno sin DROP**: si la version quitada cambia el `RETURNS TABLE` y la que
  la reescribe hace `CREATE OR REPLACE` sin `DROP`, una base limpia falla ->
  `drop_si_retorno_viejo` con una columna que solo tenga la version nueva.
- **COMMENT**: el `COMMENT ON FUNCTION` vivo de una funcion quitada va a
  `mover_comment` (migracion nueva, numero con `scan.sh`). Los dinamicos por OID
  (V111) pisan los anteriores: esos no se mueven. `COMMENT ON TRIGGER/INDEX`
  sigue a su objeto.
- **Binds y datos**: `INSERT`/`UPDATE` en `public.query`, `role_*`, `route`,
  catalogos -> la posterior tiene que escribir de verdad (no `DO NOTHING`), las
  mismas columnas y las mismas filas, y ninguna intermedia puede leer la fila
  (V495 copia `/documentos/todos/query`).
- **Sobrecargas**: otra firma no reemplaza la vieja; un `DROP` por firma si.
- **Cabecera**: <= 12 lineas (que queda, donde vive lo quitado, de que depende);
  comentarios cortos solo en funciones clave. Los de dentro de los cuerpos no se
  tocan: forman parte de la definicion.

Si no queda nada vivo, se borra el fichero (`git rm`); si queda algo:

```bash
python .claude/skills/limpiando-migraciones/recorte.py plan.json
```

## 3. Banco

```bash
B=.claude/skills/limpiando-migraciones/banco.sh
bash $B arranque          # A = origin/dev, B = arbol. Los dos tienen que migrar limpios
bash $B comparar          # esquema, permisos y datos: IGUAL x3
bash $B deploy <n> <n>    # repair + outOfOrder + re-aplicar editados x2 + validate, y compara
bash $B limpiar
```

Si B no migra, algo quitado hacia falta al migrar (vuelve al paso 1). Si
`deploy` difiere, re-aplicar resucita o borra algo: tipicamente un `CREATE`
muerto que se quedo, un `DROP` de la vigente o un `ALTER` deshecho.

## 4. Dependencias sobre el arbol recortado

```bash
python .claude/skills/limpiando-migraciones/usos.py <n> <n>          # 0 usos rotos
python scripts/migration-reapply-set.py --why <n> <n>                # extras explicables
python .claude/skills/next-migration-number/deps.py --refresh --version <n>
```

`migration-reapply-set.py` empareja por nombre: cada extra tiene que ser una
sobrecarga o un `DROP` de otra firma. `deps.py` ya no debe marcar `MUERTA` ni
`DROP PELIGROSO`.

## 5. Gates

```bash
python scripts/migration-lint.py <editados>                 # sin errores; --all no sube
python scripts/generar-mapa.py --refresh
git grep -n "V<n>__" -- ':!docs/MAPA.md'                     # refs a ficheros borrados
# tras commitear:
python scripts/migration-orden.py --base origin/dev
```

Podar de `scripts/migration-lint-baseline.json` las entradas de ficheros
borrados y de hallazgos que ya no se dan.

## 6. Commits y PR

Commits granulares por dominio, baseline + mapa en su propio commit, sin
coautoria. El PR (`/publicar-pr`) lleva: tabla de lineas antes/despues y que
queda, lo que se conserva aunque el modelo lo diera por muerto (y por que), el
comportamiento del deploy (repair + re-aplicacion de los editados, si hay
posteriores que re-aplicar) y el rollback: **siempre con una migracion nueva**;
restaurar los ficheros haria que `-outOfOrder` re-ejecutara las versiones viejas
encima de las vigentes.

## Casos reales que el modelo no ve

- Sobrecargas vivas por otros tipos o aridad: V116 (V130), V257 (V360).
- Funciones borradas por firma que re-aplicar resucita: V59 (V113).
- Necesarias al migrar: V216 (V243 sql + backfill V280), V224 (fn_unidad_estado
  en el propio fichero), V243 (V450), V334/V411 (V420 sql).
- `ALTER FUNCTION ROWS 1` de V493 sobre V474. COMMENT por OID de V111.
- Semillas usadas antes: rol de V59 (V63-V87), `pg_trgm` de V112.
- Parche "pisado" que toca otra fila: codigo de ruta en V370.
- Backfill de notas en V469: no se edita.
