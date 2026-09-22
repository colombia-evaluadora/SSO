"""Bateria del hook no_fugas.py: `python .claude/hooks/test_no_fugas.py`.

Los casos que esperan 0 son los que distinguen "publicar una direccion" de
"trabajar con ella": documentarla en el repo, verla en un puerto local o en
una version, o auditar el historial buscandola.
"""
import json
import subprocess
import sys

PROD = "172.233.184.248"

CASOS = [
    # --- debe bloquear: la direccion sale del repo ---
    (2, "IP en el cuerpo del commit",
     f'git commit -m "fix(db): aplicado en {PROD}"'),
    (2, "IP en un heredoc del commit",
     f"git commit -F - <<'EOF'\nfix(db): drift\n\nComprobado contra {PROD}.\nEOF"),
    (2, "IP en el body de un PR",
     f'gh pr create --title x --body "Verificado en vivo contra {PROD}"'),
    (2, "otra IP publica cualquiera",
     'git commit -m "chore: apunta a 203.0.113.7"'),
    (2, "host .interno en un PR",
     'gh pr create --title x --body "corre en db01.interno"'),
    (2, "PowerShell here-string",
     f"git commit -m @'\nfix: algo\n\nservidor {PROD}\n'@"),

    # --- NO debe bloquear ---
    (0, "commit limpio nombrando el papel",
     'git commit -m "fix(db): drift entre el servidor de test y el repo"'),
    (0, "PR limpio",
     'gh pr create --title x --body "## Que resuelve\ntexto normal"'),
    (0, "localhost y puerto",
     'git commit -m "chore: el tunel queda en 127.0.0.1:5435"'),
    (0, "IP privada de docker",
     'git commit -m "fix(compose): la red interna usa 172.18.0.2"'),
    (0, "IP privada de LAN",
     'git commit -m "chore: probado desde 192.168.1.40"'),
    (0, "numero de version con 4 partes",
     'git commit -m "chore: sube la libreria a 1.2.3.4"'),
    (0, "version de Boot con 4 partes",
     'git commit -m "chore(deps): Spring Boot 4.1.1.1"'),
    (2, "IP publica con octetos de 2+ digitos",
     'git commit -m "fix: apunta a 203.0.113.70"'),
    (0, "documentar la IP en un fichero del repo",
     f"cat > .claude/hooks/hosts-prod.txt <<'EOF'\n{PROD}\nEOF"),
    (0, "auditar el historial buscando la IP",
     f'git log --all --grep="{PROD}" -i | head'),
    (0, "grep de la IP en las reglas",
     f'grep -rn "{PROD}" .claude/rules/'),
]


def main() -> int:
    fallos = 0
    for esperado, nombre, cmd in CASOS:
        rc = subprocess.run([sys.executable, ".claude/hooks/no_fugas.py"],
                            input=json.dumps({"tool_input": {"command": cmd}}),
                            capture_output=True, text=True).returncode
        ok = rc == esperado
        fallos += not ok
        print(("OK   " if ok else "FALLA") + f" [{rc}/{esperado}] {nombre}")
    return 1 if fallos else 0


if __name__ == "__main__":
    sys.exit(main())
