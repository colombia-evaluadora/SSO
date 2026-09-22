# Hooks del repo

Los scripts y su registro se comparten por git: `.claude/settings.json` está
versionado y solo lleva el bloque `hooks`. No hace falta configurar nada a mano.
Lo personal (permisos, plugins) va en `.claude/settings.local.json`, que sigue
ignorado y se fusiona encima.

## Nucleo compartido

`shell_scan.py` trocea un comando (segmentos de nivel superior respetando
comillas, cuerpos de heredoc y here-strings de PowerShell) y `git_text.py`
saca de ahi el texto que un comando va a publicar: mensaje de commit o cuerpo
de PR, venga por `-m`, heredoc, here-string o `--body-file`. Los hooks son
envoltorios finos sobre eso; ninguno vuelve a resolver como se parte un
comando. Es la misma forma que la convencion de funciones del repo: la logica
en un nucleo reutilizable, y encima lo que decide.

## `no-coautoria.sh` (+ `no_coautoria.py`)

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

## `no-prod.sh` (+ `no_prod.py`)

Bloquea (`PreToolUse`, exit 2) los comandos que **escriben** en la base de un
servidor real: `flyway migrate/repair/clean/undo/baseline`, `psql` con DDL/DML
(venga por `-c` o por heredoc) y aplicar un `.sql` entero con `-f`.

Lo que **no** bloquea, a proposito: diagnosticar. `SELECT`, `\df`, `flyway
info`, `pg_dump`, `docker ps/logs` siguen pasando — el agente
`server-drift-detector` vive de eso. Y todo lo que apunte al Postgres local no
lo mira siquiera.

Los hosts salen de `hosts-prod.txt` (uno por linea) y de la variable
`SSO_HOSTS_PROD`, no del script: cambiar de servidor no deberia ser editar
codigo.

## `no-fugas.sh` (+ `no_fugas.py`)

Bloquea (`PreToolUse`, exit 2) publicar la direccion de un servidor en un
mensaje de commit o en la descripcion de un PR. Eso sale del repo y el
historial no se reescribe; en un commit el servidor se nombra por su papel
("el servidor de test", "produccion").

Dentro del repo esas direcciones si viven (`CLAUDE.md`, las reglas, el propio
`hosts-prod.txt`): el hook solo mira el texto que se publica. Las IP privadas
(127.x, 10.x, 192.168.x, 172.16-31.x) y las versiones de cuatro numeros de un
digito (`1.2.3.4`, `Boot 4.1.1.1`) no cuentan.

## `post-edit.sh`

Tras cada `Write`/`Edit`:

1. **Codificación.** Busca secuencias tipo `Ã©` / `â€“` en `.sql`, `.md`, `.json`,
   `.java`, `.yml`. El locale de las máquinas de este equipo es cp1252 y un
   fichero mal guardado llega a producción con el texto roto.
2. **YAML con claves duplicadas.** Un `.yml`/`.yaml` se carga con un loader
   estricto (`yaml_estricto.py`). PyYAML se queda con la última definición sin
   avisar, así que un merge que concatena dos bloques hermanos pasa la revisión
   y tumba el servicio al arrancar — pasó con el `application.yml` de
   reporting-service.
3. **Invariantes de migración.** Si el fichero está en `postgres/migrations/`,
   corre `scripts/migration-lint.py` sobre él.

Sale con código 2 cuando hay errores, que es como el harness devuelve el
hallazgo al agente para que corrija antes de seguir. Los avisos no interrumpen.

## `session-start.sh`

Imprime rama, techo local de migraciones y si hay migraciones sin commitear.
A propósito **no** hace `git fetch`: el número libre real contra todas las ramas
lo da `.claude/skills/next-migration-number/scan.sh`, que tarda bastante más.

## Probarlos a mano

Los tres `PreToolUse` leen el comando por stdin y salen con 2 cuando bloquean:

```bash
echo '{"tool_input":{"command":"git commit -m \"x\n\nCo-Authored-By: y\""}}' \
  | bash .claude/hooks/no-coautoria.sh; echo "exit=$?"
echo '{"tool_input":{"command":"ssh root@<host-de-hosts-prod> \"flyway migrate\""}}' \
  | bash .claude/hooks/no-prod.sh; echo "exit=$?"
echo '{"tool_input":{"command":"git commit -m \"fix: apunta a 203.0.113.70\""}}' \
  | bash .claude/hooks/no-fugas.sh; echo "exit=$?"
```

Y los otros dos, por fichero:

```bash
echo '{"tool_input":{"file_path":"postgres/migrations/V406__x.sql"}}' \
  | bash .claude/hooks/post-edit.sh; echo "exit=$?"
bash .claude/hooks/session-start.sh
```
