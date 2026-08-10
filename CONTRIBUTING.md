# Contribuir al SSO Modernizado

Esta guía aplica a **todo el repo** (`sso_postgres/` raíz y sub-módulos
bajo `modernize/`). Es el contrato que un PR debe cumplir para que un
reviewer lo apruebe sin rehacer trabajo.

---

## 1. Modelo de ramas — **tres ramas, una dirección**

Tres ramas de vida larga. Un cambio siempre viaja en la misma
dirección y **nunca al revés**:

```
feature/CU-xxxx  --squash-->  dev  --merge-->  test  --merge+tag-->  main
                               │
                               └── único entorno desplegado (Linode)
```

| Rama | Qué contiene | Cómo se lee |
|---|---|---|
| **`dev`** | Todo el trabajo, **un commit por tarea** | historial completo |
| **`test`** | Lo que pasó QA | `git log --first-parent test` = una línea por promoción |
| **`main`** | Releases, con tag SemVer | `git log --first-parent main` = una línea por release |

**El método de merge de cada paso no es un detalle, es lo que hace
que el modelo funcione:**

| Paso | Método | Por qué |
|---|---|---|
| `feature/CU-xxxx` → `dev` | **squash** | Un commit por tarea. Los WIP y los "fix typo" no ensucian el historial |
| `dev` → `test` | **merge commit** | Agrupa la promoción sin destruir los commits que la componen |
| `test` → `main` | **merge commit + tag** | El release lo marca el tag, no un commit aplastado |

### Por qué NO se hace squash entre `dev`, `test` y `main`

Es tentador —dejaría un `main` con historial corto— y rompe el modelo.

Un squash de `dev → test` crea en `test` un commit **que no existe en
`dev`**. Las dos ramas quedan divergidas para siempre, y en la
siguiente promoción el PR vuelve a mostrar los commits ya promovidos,
porque para git nunca llegaron. Cuando un cambio nuevo toque líneas
que un cambio ya promovido tocó, aparece un conflicto **con contenido
que ya está aplicado**. Cada promoción arrastra más ruido que la
anterior.

Además se pierde `git bisect`: si en `test` una promoción entera es un
solo commit, no hay forma de localizar cuál de los veinte cambios
rompió algo.

Con merge commits se consigue lo mismo que se buscaba —un historial
legible por bloques— sin pagar ninguna de las dos cosas: **agrupar es
una forma de leer, no de destruir.** Ver `--first-parent` en la tabla
de arriba.

**Reglas por rama:**

| | `dev` | `test` | `main` |
|---|---|---|---|
| Branch protection | estricta | estricta | estricta |
| Required approvals | 1 | 1 | 1 |
| Status checks | full matrix | full matrix | full matrix |
| Force-push | bloqueado | bloqueado | bloqueado |
| Deletion | bloqueado | bloqueado | bloqueado |
| Conversation resolve | requerido | requerido | requerido |
| Origen de PRs | `feature/*`, `fix/*`, `refactor/*`, `chore/*` | `dev` (promoción) | `test` (release) |
| Método de merge | squash | merge commit | merge commit + tag |
| Deploy | **sí** — servidor de pruebas | no | no |

`test` y `main` no despliegan hoy porque sólo hay un entorno. Cuando
tengan el suyo, cada una engancha su workflow sin tocar el resto.

**Hotfix:** si `main` está roto y la fix es urgente y NO puede esperar
a que pase por `test`, abrí la rama `fix/<slug>` desde el SHA de main,
PR directo a `main` con label `hotifx`, y tag nuevo después. Después
mergéate la misma fix en `test` (cherry-pick o PR inversa) para no
divergir. Si el hotfix ya está en `test`, promovélo antes de mergear
directo a main para evitar que `test` quede atrás.

**Convención de nombre de rama:**

| Tipo | Prefijo | Ejemplo |
|---|---|---|
| Nueva capacidad | `feat/` | `feat/v13-query-caching` |
| Corrección | `fix/` | `fix/login-redirect-loop` |
| Refactor sin cambio de comportamiento | `refactor/` | `refactor/auth-center-concerns` |
| Tareas de mantenimiento | `chore/` | `chore/bump-spring-boot` |
| Documentación | `docs/` | `docs/contributing` |
| Tests sin cambio de lógica | `test/` | `test/admin-ui-login-edge-cases` |

Si la rama toca un módulo específico, codificalo en el nombre:
`feat/sso-admin-csv-export`, `fix/api-gateway-cors`. Evita prefijos
duplicados como `feat/feat-foo`.

---

## 2. Modelo de commits — **Conventional Commits**

Cada commit:

```
<tipo>(<scope>): <descripción en imperativo, ≤72 chars>

<parrafo(s) opcional(es) — qué cambia, por qué, cómo>
<footer>     — BREAKING CHANGE, refs, Co-Authored-By
```

- **Tipos permitidos:** `feat`, `fix`, `refactor`, `perf`, `test`,
  `docs`, `chore`, `build`, `ci`, `style` (cosmético).
- **Scope** debe ser uno de: `common`, `auth-center`, `sso-admin`,
  `api-gateway`, `admin-ui`, `postgres`, `compose`, `notification-service`,
  `provisioner`, `query-service`, o varios separados por coma:
  `feat(sso-admin,admin-ui): ...`.
- **Breaking changes** deben llevar `BREAKING CHANGE:` en el footer y,
  si la PR toca API pública, el campo `!` después del tipo:
  `feat(api)!: drop /getRolesByUsername endpoint`.

El CI no valida el mensaje (no usamos commitlint todavía); el reviewer
sí. Mensajes flojos → PR rebotada.

---

## 3. Pull Requests

### 3.1 Antes de abrir

- [ ] `git fetch origin && git rebase origin/dev` sobre tu rama.
      La base de una feature es **`dev`**, no `main` (§1).
- [ ] `mvn -B clean verify` por cada módulo afectado corre localmente.
- [ ] `npm run typecheck && npm test -- --run && npm run build`
      corre localmente si tocaste admin-ui.
- [ ] Si cambia wire del SPA, regeneraste el bundle:
      `cd admin-ui && npm run build`,
      `rm -rf api-gateway/src/main/resources/static/admin`,
      `cp -R admin-ui/dist api-gateway/src/main/resources/static/admin`
      y recompuilas el jar.
- [ ] Si hay nueva migración Flyway, escribiste el `IF NOT EXISTS` /
      `DROP IF EXISTS` correspondiente para que sea reentrante.

### 3.2 Plantilla

Usa `.github/PULL_REQUEST_TEMPLATE.md`. Las secciones
"Plan de prueba" y "Riesgos y rollback" no son opcionales — si la PR
rompe el flujo principal de login/CRUD, explica cómo revertir.

### 3.3 Reglas de merge

Configuradas como branch protection sobre `dev`, `test` y `main`
(`scripts/branch-protection.sh`):

- 1 aprobación de un CODEOWNER del archivo tocado.
- Todos los checks verdes (`maven-common`, `maven-auth-center`,
  `maven-sso-admin`, `maven-api-gateway`, `admin-ui-*`).
- Rama actualizada con la base antes de mergear.

**El método depende del paso** (§1): squash para entrar a `dev`,
merge commit para promover a `test` y a `main`. GitHub no permite
fijarlo por rama, así que es una convención — pero es la que sostiene
el modelo, no una preferencia estética.

```bash
gh pr merge <n> --squash --delete-branch   # feature → dev
gh pr merge <n> --merge                    # dev → test, test → main
```

### 3.4 Borra ramas viejas

Una vez mergeada, `gh pr merge --delete-branch` se encarga. No
dejes ramas zombies en el remote.

**Y no sigas commiteando a una rama cuyo PR ya se mergeó.** El commit
se queda ahí, sin PR, sin llegar a ninguna parte, y nadie vuelve a
mirar esa rama. Pasó tres veces el 2026-08-08 y sólo se detectó por
casualidad; uno de esos commits estaba desplegado en el servidor y no
existía en `main`.

Antes de dar una rama por terminada:

```bash
git log origin/main..<rama>   # si devuelve algo, hay trabajo que no llegó
```

### 3.5 Promover `dev` → `test` (pasar a QA)

Cuando lo que hay en `dev` se considera listo para que QA lo mire:

```bash
gh pr create --base test --head dev \
  --title "promote: dev → test" \
  --body "Resumen de lo que entra y qué probar."
gh pr merge <n> --merge      # merge commit, NO squash (ver §1)
```

El PR listará todos los commits desde la última promoción. Eso es lo
correcto: es exactamente el lote que QA va a validar. El merge commit
los agrupa en una sola línea de `--first-parent`.

Recordá que **`dev` es lo que está desplegado**, así que esta
promoción no cambia lo que corre en el servidor — sólo marca qué se
está validando.

### 3.6 Promover `test` → `main` (release procedural)

Esta subsección es **para quien coordina la liberación**, no para cada
PR. La promoción es optativa: si no hay release a la vista, no se hace.

1. **Verificación previa.** Asegurate de que `test` está verde en CI y
   de que QA dio el visto bueno sobre lo desplegado.
2. **Sincronización local.**

   ```bash
   git fetch origin
   git checkout main && git pull --ff-only origin main
   git checkout test && git pull --ff-only origin test
   ```

3. **Promoción.** La forma más limpia es PR (recomendado). Permite
   que el cambio sea visible y tenga su propia revisión:

   ```bash
   gh pr create \
     --base main \
     --head test \
     --title "chore(release): promote test → main" \
     --body "Promoción de los commits acumulados en \`test\` desde la última promoción. Sin código propio; revisa \`git log origin/main..origin/test --oneline\` antes de aprobar."
   ```

   La PR tiene que pasar los checks de main (mismos 8) y 1 review. Su
   commit de merge es la **liberación**; taguealo con SemVer al
   mergear (§5).

   **Atajo sólo para emergencias** (ej. hotfix ya mergeado en main
   pero el release no se tageó hace tiempo) — fast-forward directo:

   ```bash
   git checkout main
   git merge --ff-only origin/test
   git push origin main   # falla si protection lo bloquea
   ```

4. **Tag + release.** Inmediatamente después del merge, ver §5.

5. **Devolver a `test` los commits de hotfix.** Si durante la
   semana mergeaste a `main` cosas que NO están en `test` (hotfixes
   urgentes), al promover test→main te quedás con esa divergencia.
   Traelas con cherry-pick:

   ```bash
   git checkout test
   git cherry-pick <sha-en-main-que-no-esta-en-test>
   git push origin test
   ```

   El CI de `test` re-corre los 8 checks. Una divergencia > 5 commits
   es señal de que el flujo `test → main` se está cumpliendo a
   medias.

---

## 4. Migraciones de BD

`postgres/migrations/V<n>__<descripcion>.sql` — el número se asigna
correlativo a la última aplicada (consultar `flyway_schema_history`).
Reglas no negociables:

1. **Reentrante.** Cada migración debe poder aplicarse dos veces sin
   error. Usa `CREATE … IF NOT EXISTS`, `DROP … IF EXISTS`,
   `ALTER … ADD CONSTRAINT IF NOT EXISTS`. Si no podés hacer eso,
   declara explícitamente "no reentrante, requiere reset de DB" en el
   cuerpo de la migración.
2. **Forward-only.** Flyway Community no soporta `undo`. Para
   "revertir" algo, escribí una migración nueva V(n+1).
3. **Pre-flight para drops.** Si vas a tirar una columna/tabla que
   pueda contener datos relevantes, primero comprobá con un
   `RAISE EXCEPTION` si hay filas no migradas, y describí en el Javadoc
   de la migración cómo backfillearlas.
4. **Naming de objeto.** No uses nombres sensibles a mayúsculas; la BD
   usa lower-case por convención.

---

## 5. Releases

Cuando una serie de commits en `main` constituye un release:

1. `git tag -a vX.Y.Z -m "vX.Y.Z: <one-liner>"` desde el SHA que va
   a producción.
2. Actualizá las versiones Docker (`eurekatic/<servicio>:X.Y.Z`) en los
   manifiestos de despliegue.
3. Creá un GitHub Release con las notas (`gh release create vX.Y.Z
   --notes-from-tag` o `--notes` libre).

`main` queda libre para el próximo ciclo — la cadencia la marca el
equipo, no un calendario fijo.

---

## 6. Secretos y configuración

- **Nunca** commitees `.env` ni credenciales reales. El template va
  en `.env.example` con placeholders y un comentario que apunte al
  secret manager.
- Los `application*.yml` deben referenciar env vars con defaults
  razonables para dev local, pero nunca con credenciales de prod.
- Si tu PR toca un `application*.yml`, justificá cada valor nuevo
  en la descripción de la PR.

---

## 7. Comunicación

- PRs y code review son asíncronos y viven en GitHub — no
  Slack/Discord/email. Si hay desacuerdo, abrimos un hilo en
  Discussions y referenciamos la PR.
- Issues son la lista de TODO oficial; las tarjetas mentales no
  cuentan. Cualquier trabajo >2 horas abre issue.
- Si sos nuevo en el repo, leé primero `CLAUDE.md` (si existe) y los
  archivos `*.md` en `~/.claude/projects/.../memory/` del repo —
  tienen contexto que acorta onboarding.
