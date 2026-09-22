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
no_coautoria.py    PreToolUse   Bash|PowerShell
no_prod.py         PreToolUse   Bash|PowerShell
no_fugas.py        PreToolUse   Bash|PowerShell
post-edit.sh       PostToolUse  Write|Edit
migration_lint.py  PostToolUse  Write|Edit
cierre_limpio.py   Stop
fallo_conocido.py  PostToolUseFailure  Bash|PowerShell
session-start.sh   SessionStart
```

`settings.json` invoca cada `.py` directamente con `python`; no hay envoltorios
`.sh` que solo hagan `exec`.

## Núcleo compartido (`comun/`)

`shell_scan.py` trocea un comando (segmentos de nivel superior respetando
comillas, cuerpos de heredoc y here-strings de PowerShell) y `git_text.py`
saca de ahi el texto que un comando va a publicar: mensaje de commit o cuerpo
de PR, venga por `-m`, heredoc, here-string o `--body-file`. Los hooks son
envoltorios finos sobre eso; ninguno vuelve a resolver como se parte un
comando. `yaml_estricto.py` es la herramienta que usa `post-edit.sh`. Es la
misma forma que la convención de funciones del repo: la lógica en un núcleo
reutilizable, y encima lo que decide.

## `no_coautoria.py`

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

## `no_prod.py`

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

## `no_fugas.py`

Bloquea (`PreToolUse`, exit 2) publicar la direccion de un servidor en un
mensaje de commit o en la descripcion de un PR. Eso sale del repo y el
historial no se reescribe; en un commit el servidor se nombra por su papel
("el servidor de test", "produccion").

No hay lista que consultar: se reconoce por la forma. Las IP privadas
(127.x, 10.x, 192.168.x, 172.16-31.x) y las versiones de cuatro numeros de un
digito (`1.2.3.4`, `Boot 4.1.1.1`) no cuentan.

## `post-edit.sh`

Salud del fichero recién escrito, sea el que sea:

1. **Codificación.** Busca secuencias tipo `Ã©` / `â€“` en `.sql`, `.md`, `.json`,
   `.java`, `.yml`. El locale de las máquinas de este equipo es cp1252 y un
   fichero mal guardado llega a producción con el texto roto.
2. **YAML con claves duplicadas.** Un `.yml`/`.yaml` se carga con un loader
   estricto (`comun/yaml_estricto.py`). PyYAML se queda con la última definición
   sin avisar, así que un merge que concatena dos bloques hermanos pasa la
   revisión y tumba el servicio al arrancar — pasó con el `application.yml` de
   reporting-service.

Sale con código 2 cuando hay un error.

## `migration_lint.py`

`PostToolUse` sobre `Write`/`Edit`: pasa `scripts/migration-lint.py` a la
migración recién editada. Cada una de sus reglas corresponde a una regresión que
ya ocurrió; no valida SQL —para eso está el Postgres local— sino las
convenciones que se violan en silencio.

Exit 2 con los **errores**; los avisos salen por stdout y no interrumpen, porque
el baseline ya se encarga de que solo hablen de lo nuevo.

Era el punto 3 de `post-edit.sh`. Va aparte para que cada hook diga una sola
cosa, y porque tiene una pareja: lo editado desde Bash no dispara `Write|Edit`,
y de eso se ocupa `cierre_limpio.py` al cerrar el turno.

## `cierre_limpio.py`

`Stop`: al terminar el turno, y **solo si el working tree tiene migraciones
tocadas**, hace dos cosas.

1. **El linter de invariantes**, que **bloquea el cierre (exit 2) si hay
   errores**. Existe porque `migration_lint.py` solo cubre `Write`/`Edit`: una
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

Coste: nada si no tocaste migraciones (0,2 s) y nada si el linter bloquea
—corta antes—. Los ~14 s del mapa solo se pagan cuando hay migraciones tocadas
y están limpias.

## `fallo_conocido.py`

`PostToolUseFailure`: cuando un comando revienta, traduce el error a su causa
real en este repo y la devuelve como contexto. No bloquea nada — el comando ya
falló.

Cubre lo que ya se investigó una vez: `42501` (tildes en el CODIGO del menú,
alcance no pasado, falta la fila en `role_query`), `23503` (tiene dependientes →
409), `23505` (los UNIQUE parciales `WHERE active = true` de V65), `42725` (dos
sobrecargas vivas), los `UnicodeDecodeError` de cp1252, el `Could not resolve
dependencies` de Maven multi-módulo, el checksum de Flyway y el 404 de una fila
nueva de `public.query`.

## `session-start.sh`

Imprime rama, techo local de migraciones y si hay migraciones sin commitear.
A propósito **no** hace `git fetch`: el número libre real contra todas las ramas
lo da `.claude/skills/next-migration-number/scan.sh`, que tarda bastante más.

## Probarlos a mano

Los tres `PreToolUse` leen el comando por stdin y salen con 2 cuando bloquean:

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
  | bash .claude/hooks/post-edit.sh; echo "exit=$?"
echo '{"prompt_id":"prueba"}' | python .claude/hooks/cierre_limpio.py; echo "exit=$?"
echo '{"error":"SQLSTATE 42501"}' | python .claude/hooks/fallo_conocido.py
bash .claude/hooks/session-start.sh
```
