"""Bateria del hook no_coautoria.py: `python .claude/hooks/test_no_coautoria.py`.

Los casos que esperan 0 son los que NO se pueden bloquear: auditar el historial
o documentar la regla tiene que seguir funcionando.
"""
import json, subprocess, sys, os, tempfile
CASOS = [
 (2, "commit -m simple", 'git commit -m "fix: x\n\nCo-Authored-By: Claude <n@a.com>"'),
 (2, "commit heredoc -F -", "git commit -F - <<'EOF'\nfix: x\n\nCo-Authored-By: Claude <n@a.com>\nEOF"),
 (2, "commit -m $(cat <<EOF)", 'git commit -m "$(cat <<\'EOF\'\nfix: x\n\nCo-Authored-By: Claude <n@a.com>\nEOF\n)"'),
 (2, "gh pr create --body", 'gh pr create --title x --body "texto\n\nCo-Authored-By: Claude <n@a.com>"'),
 (2, "gh pr create heredoc", "gh pr create --title x --body \"$(cat <<'EOF'\ntexto\n\nCo-Authored-By: Claude <n@a.com>\nEOF\n)\""),
 (2, "gh pr create firma", 'gh pr create --title x --body "texto\n\nGenerated with [Claude Code](https://claude.com/claude-code)"'),
 (2, "gh pr edit --body", 'gh pr edit 400 --body "x\nCo-authored-by: Claude <n@a.com>"'),
 (2, "PowerShell here-string", "git commit -m @'\nfix: x\n\nCo-Authored-By: Claude <n@a.com>\n'@"),
 (2, "body-file", 'gh pr create --title x --body-file BODYFILE'),
 (2, "backslash-n escapado", 'gh pr create --title x --body "texto\n\nCo-Authored-By: Claude <n@a.com>"'),
 (2, "git -C ruta commit", 'git -C /repo commit -m "x\n\nCo-Authored-By: Claude <n@a.com>"'),
 (0, "commit limpio", 'git commit -m "fix: x\n\ndescripcion normal"'),
 (0, "gh pr create limpio", 'gh pr create --title x --body "## Que resuelve\ntexto"'),
 (0, "auditar el historial", "git log --all --grep='Co-authored-by' -i | head"),
 (0, "grep de la regla", "grep -rn 'Co-Authored-By' .claude/"),
 (0, "commit + auditoria posterior", 'git commit -m "fix: x" && git log --grep="Co-Authored-By" -i'),
 (0, "documentar la regla", "cat > nota.md <<'EOF'\nNo usar Co-Authored-By.\nEOF"),
]
bf = os.path.join(tempfile.gettempdir(), "bodyfile.md")
open(bf, "w", encoding="utf-8").write("texto\n\nCo-Authored-By: Claude <n@a.com>\n")
fallos = 0
for esperado, nombre, cmd in CASOS:
    cmd = cmd.replace("BODYFILE", bf)
    p = subprocess.run([sys.executable, ".claude/hooks/no_coautoria.py"],
                       input=json.dumps({"tool_input": {"command": cmd}}),
                       capture_output=True, text=True)
    ok = p.returncode == esperado
    fallos += not ok
    print(("OK   " if ok else "FALLA") + f" [{p.returncode}/{esperado}] {nombre}")
sys.exit(1 if fallos else 0)
