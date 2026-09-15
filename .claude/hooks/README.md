# Hooks del repo

Los scripts se comparten por git, pero `.claude/settings.json` **no** (está en
`.gitignore` junto con el resto de `.claude/*`). Para que se ejecuten, cada
persona los registra una vez en su `settings.json` o `settings.local.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash",
        "hooks": [{ "type": "command",
                    "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/no-coautoria.sh\"",
                    "timeout": 15 }] }
    ],
    "PostToolUse": [
      { "matcher": "Write|Edit",
        "hooks": [{ "type": "command",
                    "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/post-edit.sh\"",
                    "timeout": 120 }] }
    ],
    "SessionStart": [
      { "hooks": [{ "type": "command",
                    "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh\"",
                    "timeout": 20 }] }
    ]
  }
}
```

## `no-coautoria.sh` (+ `no_coautoria.py`)

Bloquea (`PreToolUse`, exit 2) cualquier `git commit` cuyo mensaje lleve un
trailer `Co-Authored-By`, venga en `-m` o en un fichero pasado con `-F`.

`CLAUDE.md` ya lo prohibía, pero un `CLAUDE.md` es contexto, no configuración:
se le cuela al agente aunque lo haya leído. Un `PreToolUse` lo impide decida lo
que decida el modelo.

La detección exige que el `git commit` esté **en posición de comando**: se
descartan los cuerpos de heredoc y se parte por separadores de nivel superior
respetando comillas. Buscar el texto a secas bloqueaba scripts que solo
documentan la regla o la auditan (`grep -rn ...`, un `python - <<EOF` que edita
esta misma documentación). La batería de casos cubre las dos direcciones: lo
que debe bloquear y lo que no.

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
