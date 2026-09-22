# Hooks del repo

Los scripts y su registro se comparten por git: `.claude/settings.json` está
versionado y solo lleva el bloque `hooks`. No hace falta configurar nada a mano.
Lo personal (permisos, plugins) va en `.claude/settings.local.json`, que sigue
ignorado y se fusiona encima.

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

La batería cubre las dos direcciones — lo que debe bloquear y lo que no:

```bash
python .claude/hooks/test_no_coautoria.py
```

## `post-edit.sh`

Tras cada `Write`/`Edit`:

1. **Codificación.** Busca secuencias tipo `Ã©` / `â€“` en `.sql`, `.md`, `.json`,
   `.java`, `.yml`. El locale de las máquinas de este equipo es cp1252 y un
   fichero mal guardado llega a producción con el texto roto.
2. **Invariantes de migración.** Si el fichero está en `postgres/migrations/`,
   corre `scripts/migration-lint.py` sobre él.

Sale con código 2 cuando hay errores, que es como el harness devuelve el
hallazgo al agente para que corrija antes de seguir. Los avisos no interrumpen.

## `session-start.sh`

Imprime rama, techo local de migraciones y si hay migraciones sin commitear.
A propósito **no** hace `git fetch`: el número libre real contra todas las ramas
lo da `.claude/skills/next-migration-number/scan.sh`, que tarda bastante más.

## Probarlos a mano

```bash
echo '{"tool_input":{"file_path":"postgres/migrations/V406__x.sql"}}' \
  | bash .claude/hooks/post-edit.sh; echo "exit=$?"
bash .claude/hooks/session-start.sh
```
