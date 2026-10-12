# Hooks del repo

Los scripts y su registro se comparten por git: `.claude/settings.json` está
versionado y solo lleva el bloque `hooks`. No hace falta configurar nada a mano.
Lo personal (permisos, plugins) va en `.claude/settings.local.json`, que sigue
ignorado y se fusiona encima.

## Estructura

Un fichero por hook en la raíz, y lo que no es un hook en `comun/`:

```
README.md          esta guía
comun/             módulos compartidos, no se registran en ningún evento
pre_shell.py       PreToolUse   Bash|PowerShell  (corre las tres guardias)
  no_coautoria.py    guardia: atribución en commit/PR
  no_prod.py         guardia: escribir en una base que no es la local
  no_fugas.py        guardia: direcciones de servidor en commit/PR
post_edit.py       PostToolUse  Write|Edit       (codificación, YAML, linter)
  informe_fondo.py   no registrado: informe HTML + poda de baseline en segundo plano
cierre_limpio.py   Stop
fallo_conocido.py  PostToolUseFailure  Bash|PowerShell
session-start.sh   SessionStart
```

`settings.json` invoca cada `.py` directamente con `python`; no hay envoltorios
`.sh` que solo hagan `exec`.

**Un proceso por evento.** En Windows arrancar Python cuesta ~200 ms y el
harness lanza el hook sobre *cada* llamada a la herramienta: con tres
`PreToolUse` separados, todo comando de shell pagaba ~1,1 s, y toda edición
~1,4 s con `post-edit.sh` + `migration_lint.py`. Por eso cada evento tiene un
solo despachador (`pre_shell.py`, `post_edit.py`) que corre todas sus
comprobaciones en el mismo proceso: ~0,36 s. Una comprobación nueva se añade
como función o módulo que el despachador llama, no como otra entrada en
`settings.json`.

**Fallar cerrado donde hay política.** `pre_shell.py` lleva
`"onFailure": "block"` (Claude Code ≥ 2.1.295): si el hook no puede ni arrancar
(Python ausente, error de sintaxis) el comando se bloquea, en vez de pasar con
exit 1 sin que nadie se entere. Dentro, si una sola guardia revienta por un bug
suyo se avisa y se siguen las otras, para que un fallo interno no tumbe todos
los comandos de la sesión.

## Núcleo compartido (`comun/`)

`shell_scan.py` trocea un comando (segmentos de nivel superior respetando
comillas, cuerpos de heredoc y here-strings de PowerShell) y `git_text.py`
saca de ahi el texto que un comando va a publicar: mensaje de commit o cuerpo
de PR, venga por `-m`, heredoc, here-string o `--body-file`. Los hooks son
envoltorios finos sobre eso; ninguno vuelve a resolver como se parte un
comando. `comando.py` lee el JSON del harness una vez. `yaml_estricto.py` es la
herramienta que usa `post_edit.py`. Es la
misma forma que la convención de funciones del repo: la lógica en un núcleo
reutilizable, y encima lo que decide.

## `no_coautoria.py` (guardia de `pre_shell.py`)

Bloquea (`PreToolUse`, exit 2) la atribución a Claude en dos sitios: el mensaje
de un `git commit` (trailer `Co-Authored-By`, venga en `-m`, en un heredoc o en
un fichero de `-F`) y la descripción de un `gh pr create/edit/comment` (el mismo
trailer, y además la firma *"Generated with Claude Code"*).

`CLAUDE.md` ya lo prohibía, pero un `CLAUDE.md` es contexto, no configuración:
se le cuela al agente aunque lo haya leído. Un `PreToolUse` lo impide decida lo
que decida el modelo.

La detección exige que el comando que *escribe* la atribución esté **en posición
de comando**: se parte por separadores de nivel superior respetando comillas, y
se descartan los segmentos que solo leen (`git log --grep`, `grep`, `rg`).
Buscar el texto a secas bloqueaba scripts que solo documentan la regla o la
auditan. Lo que sí se mira entero, porque es donde vive un mensaje multilínea:
los cuerpos de heredoc, los here-strings `@'...'@` de PowerShell y los ficheros
de `--body-file` / `-F`. El matcher cubre `Bash|PowerShell`: un commit desde la
herramienta PowerShell no pasaba por el hook.

## `no_prod.py` (guardia de `pre_shell.py`)

Bloquea (`PreToolUse`, exit 2) los comandos que **escriben** en la base de un
servidor real: `flyway migrate/repair/clean/undo/baseline`, `psql` con DDL/DML
(venga por `-c` o por heredoc) y aplicar un `.sql` entero con `-f`.

Lo que **no** bloquea, a proposito: diagnosticar. `SELECT`, `\df`, `flyway
info`, `pg_dump`, `docker ps/logs` siguen pasando — el agente
`server-drift-detector` vive de eso. Y todo lo que apunte al Postgres local no
lo mira siquiera.

**El repo no guarda la direccion de ningun servidor.** El criterio es una lista
blanca de destinos locales (`sso-postgres`, `localhost`, `127.0.0.1`, ...): lo
que no sea uno de esos es remoto. Ademas de no almacenar nada, falla del lado
seguro — un servidor nuevo queda bloqueado por no estar en la lista, en vez de
colarse por no estar en una lista negra.

Las opciones de host solo cuentan en el segmento que invoca la herramienta, para
que un `-h` suelto en el texto de un comando no se confunda con un destino.

Limitacion conocida: un tunel SSH (`psql -h localhost -p 5435` contra una base
remota) se ve local y pasa. No hay forma de distinguirlo desde el comando.

## `no_fugas.py` (guardia de `pre_shell.py`)

Bloquea (`PreToolUse`, exit 2) publicar la direccion de un servidor en un
mensaje de commit o en la descripcion de un PR. Eso sale del repo y el
historial no se reescribe; en un commit el servidor se nombra por su papel
("el servidor de test", "produccion").

No hay lista que consultar: se reconoce por la forma. Las IP privadas
(127.x, 10.x, 192.168.x, 172.16-31.x) y las versiones de cuatro numeros de un
digito (`1.2.3.4`, `Boot 4.1.1.1`) no cuentan.

## `post_edit.py`

Salud del fichero recién escrito, de lo más barato a lo más caro:

1. **Codificación** (`.sql`, `.md`, `.json`, `.java`, `.yml`). El fichero tiene
   que ser UTF-8 válido —el locale de este equipo es cp1252 y un fichero
   guardado con él llega a producción con el texto roto— y sin mojibake tipo
   `Ã©` / `â€“`. El mojibake solo cuenta si es **nuevo** respecto a `HEAD`: este
   README y el test de plantillas de correo lo citan a propósito.
2. **YAML con claves duplicadas.** Se carga con un loader estricto
   (`comun/yaml_estricto.py`). PyYAML se queda con la última definición sin
   avisar, así que un merge que concatena dos bloques hermanos pasa la revisión
   y tumba el servicio al arrancar — pasó con el `application.yml` de
   reporting-service.
3. **Invariantes de migración** (`postgres/migrations/*.sql`): pasa
   `scripts/migration-analysis/comandos/lint.py`. Cada regla corresponde a una
   regresión que ya ocurrió; no valida SQL —para eso está el Postgres local—
   sino las convenciones que se violan en silencio. Exit 2 con los **errores**;
   los avisos salen por stdout y no interrumpen, porque el baseline ya hace que
   solo hablen de lo nuevo. Lo editado desde Bash no dispara `Write|Edit`: de
   eso se ocupa `cierre_limpio.py` al cerrar el turno.

Sale con código 2 en el primer error.

## `informe_fondo.py` (lo lanzan `post_edit.py` y `cierre_limpio.py`)

No es un hook registrado. Mantiene al día `docs/auditoria/migraciones-analisis.html`
y la baseline del lint sin hacer esperar a nadie: generar el informe cuesta
~15 s, así que `post_edit.py` (al editar una migración) y `cierre_limpio.py` (al
cerrar un turno con migraciones tocadas, que cubre lo editado desde Bash) solo
llaman a `lanzar()`, que marca *pendiente* y arranca un proceso desacoplado.

- **Un solo generador a la vez** (`%TEMP%/sso-informe.lock`, caduca a los 10
  min). Las ediciones que llegan mientras genera dejan *pendiente* y se atienden
  con **una** vuelta más al terminar, no una por edición.
- **No regenera si nada cambió**: compara la huella del modelo más `vista/`,
  `lint.py` y la baseline con la de la última generación buena (0,45 s).
- Después del HTML corre `lint --all --baseline-podar`, que **solo quita** de la
  baseline la deuda que ya no aparece. Nunca congela nada nuevo: hacerlo en
  segundo plano sería silenciar el lint justo donde tiene que hablar. Por eso
  `lint-baseline.json` puede aparecer modificado en `git status`: es deuda
  corregida, y va en el commit.
- Salida en `%TEMP%/sso-informe.log`.

## `cierre_limpio.py`

`Stop`: al terminar el turno, y **solo si el working tree tiene migraciones
tocadas**, hace dos cosas.

1. **El linter de invariantes**, que **bloquea el cierre (exit 2) si hay
   errores**. Existe porque `post_edit.py` solo cubre `Write`/`Edit`: una
   migración editada desde Bash —un `sed -i`, un heredoc, un script de Python—
   no dispara aquel hook y se iba sin revisar. Los avisos se imprimen pero no
   interrumpen.
2. **`docs/MAPA.md` desfasado**, que solo **avisa**. El índice es lo que la
   regla de `postgres/**` manda consultar antes de hacer grep, así que
   desactualizado manda a editar la migración que no es. El generador ya traía
   `--check` para esto y no estaba enganchado a nada: `V475` y `V476` entraron
   en `dev` sin regenerarlo y nadie se enteró.

Bloquea **una sola vez por prompt**: si tras el aviso el turno vuelve a cerrar
con el mismo fallo, deja pasar. Un hook que no se puede satisfacer no debe
secuestrar la sesión.

**Coste**, que es lo que decide si un hook así se puede tener:

| Situación | Cuesta |
|---|---|
| No tocaste migraciones | 0,2 s — ni siquiera mira |
| El linter bloquea | 0,3 s — corta antes de preguntar por el mapa |
| Migración **nueva** | 0,3 s — la cabecera del mapa dice cuántas hay y hasta qué `V<n>`; si no cuadra, ya está la respuesta |
| Migración editada, primera vez | ~11 s — la comprobación de verdad |
| Lo mismo, sin cambios desde entonces | 0,4 s — reusa el veredicto |

Los ~11 s son de `--check`, que fuerza recalcular el modelo del analizador
(`migration-analysis mapa`: `load_model(refresh or check)`). Eso está bien para CI y
mal para un hook, así que aquí se paga **una vez por cambio, no una por turno**:
se guarda el veredicto junto a una huella del directorio de migraciones y del
propio `MAPA.md`.

## `fallo_conocido.py`

`PostToolUseFailure`: cuando un comando revienta, traduce el error a su causa
real en este repo y la devuelve como contexto. No bloquea nada — el comando ya
falló.

Cubre lo que ya se investigó una vez: `42501` (tildes en el CODIGO del menú,
alcance no pasado, falta la fila en `role_query`), `23503` (tiene dependientes →
409), `23505` (los UNIQUE parciales `WHERE active = true` de V65), `42725` (dos
sobrecargas vivas), los `UnicodeDecodeError` de cp1252, el `Could not resolve
dependencies` de Maven multi-módulo, el checksum de Flyway y el 404 de una fila
nueva de `public.query`. El 404 se casa como número, no como "Not Found": eso
casaba con cualquier `command not found` y metía la pista de query-service donde
no venía a cuento.

## `session-start.sh`

Imprime rama, techo local de migraciones y si hay migraciones sin commitear.
A propósito **no** hace `git fetch`: el número libre real contra todas las ramas
lo da `.claude/skills/next-migration-number/scan.sh`, que tarda bastante más.

## Probarlos a mano

El despachador `pre_shell.py` y cada guardia por separado leen el comando por
stdin y salen con 2 cuando bloquean:

```bash
echo '{"tool_input":{"command":"git commit -m \"x\n\nCo-Authored-By: y\""}}' \
  | python .claude/hooks/no_coautoria.py; echo "exit=$?"
echo '{"tool_input":{"command":"ssh root@un.servidor \"flyway migrate\""}}' \
  | python .claude/hooks/no_prod.py; echo "exit=$?"
echo '{"tool_input":{"command":"git commit -m \"fix: apunta a 203.0.113.70\""}}' \
  | python .claude/hooks/no_fugas.py; echo "exit=$?"
```

Y el resto:

```bash
echo '{"tool_input":{"file_path":"postgres/migrations/V406__x.sql"}}' \
  | python .claude/hooks/post_edit.py; echo "exit=$?"
echo '{"prompt_id":"prueba"}' | python .claude/hooks/cierre_limpio.py; echo "exit=$?"
echo '{"error":"SQLSTATE 42501"}' | python .claude/hooks/fallo_conocido.py
bash .claude/hooks/session-start.sh
```
