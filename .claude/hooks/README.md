# Hooks del repo

Los scripts se comparten por git, pero `.claude/settings.json` **no** (está en
`.gitignore` junto con el resto de `.claude/*`). Para que se ejecuten, cada
persona los registra una vez en su `settings.json` o `settings.local.json`:

```json
{
  "hooks": {
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
