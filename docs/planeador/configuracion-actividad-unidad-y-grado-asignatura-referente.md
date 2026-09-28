# Cambios de contrato: configuración de actividad desde la unidad y grado-asignatura por referente

Migraciones: **V496** y **V497**. Aquí solo se describe lo que cambia en cada
endpoint; lo que no se menciona sigue igual.

---

## 1. `GET /api/eval-col/planeador/unidades/:ID/configuracion-actividad` (V496)

Ahora responde lo mismo que `GET /planeador/actividades/configuracion?grupo=&asignatura=&unidad=`,
porque las dos usan la misma función por debajo. La asignatura se toma de la unidad.

### Entradas

| Parámetro | Dónde | Tipo | Obligatorio | Estado | Descripción |
|---|---|---|---|---|---|
| `ID` | ruta | BIGINT | sí | igual | `PK_TUNIDAD` |
| `ES_SUMATIVO` | query | `S` \| `N` | no (default `S`) | igual | Con `N` solo se apagan `recuperacion` y `ponderacion` |
| `grupo` | query | BIGINT | no | **nuevo** | `PK_TGRUPO`. Debe ser del grado de la unidad |
| `RECUPERAR` | query | `S` \| `N` | no (default `N`) | **nuevo** | Con `S`, `recuperacion.actividadesRecuperables` lista las actividades sumativas del (grupo, asignatura) |
| `ACTIVIDAD_RECUPERAR` | query | BIGINT | no | **nuevo** | `PK_TACTIVIDAD` elegida en "¿Qué desea recuperar?". Devuelve `recuperacion.origen` con sus estudiantes |

**Cómo se resuelve el grupo.** La unidad es de un grado y el horario es de un grupo:

| Caso | Grupo usado | `origenGrupo` | `programacion` |
|---|---|---|---|
| Llega `?grupo=` del grado de la unidad | ese | `PARAMETRO` | con límites |
| No llega y el grado tiene **un** grupo activo | ese | `UNICO_DEL_GRADO` | con límites |
| No llega y el grado tiene varios grupos (o ninguno) | ninguno | `null` | límites en `null`, motivo *"Falta el grupo…"* |

En el último caso el front debe pedir el grupo y volver a consultar con `?grupo=`.

### Salida

Una fila con la columna `configuracion` (JSONB). Claves **nuevas** marcadas con ★:

```jsonc
{
  "rows": [{
    "configuracion": {
      // --- ya existían ---
      "pkTunidad": 123,
      "unidad": "Unidad 1",
      "nivelEnsenanza": "Básica primaria",
      "esSumativoConsultado": "S",
      "esFormativo": false,
      "esSumativoSugerido": "S",
      "campos_disponibles": {
        "criterio":     { "visible": true, "requerido": false, "motivo": "..." },
        "evaluacion":   { "visible": true, "requerido": true, "motivo": "...",
                          "tipoEvaluacion": "...", "instrumentosPermitidos": [ /* {pk, valor, nombre, variantes, campos} */ ] },
        "ponderacion":  { "visible": true, "requerido": true, "modo": "PORCENTAJE", "campo": "PONDERACION", "motivo": "..." },
        "recuperacion": { "visible": true, "requerido": false, "motivo": "...",
                          "recuperarConsultado": "N",              // antes siempre N; ahora refleja ?RECUPERAR=
                          "catalogos": { "destino": [], "tipoAplicacion": [], "tipoCalculo": [] },
                          "reglas": { /* ... */ },
                          "actividadesRecuperables": null,          // antes siempre null; ahora lista si ?RECUPERAR=S
                          "origen": null }                          // antes siempre null; ahora objeto si ?ACTIVIDAD_RECUPERAR=
      },

      // --- ★ nuevas: contexto resuelto ---
      "origenConfiguracion": "UNIDAD",
      "origenGrupo": "PARAMETRO",          // PARAMETRO | UNICO_DEL_GRADO | null
      "fkTgrupo": 456,   "grupo": "1A",    // null si no se pudo resolver el grupo
      "fkTgrado": 789,   "grado": "Primero",
      "fkTasignatura": 10, "asignatura": "Matemáticas",
      "referente": { "pk": 5, "nombre": "..." },   // null si la unidad no tiene referente

      // --- ★ nueva: programación (límites de fechas, semanas, duración y horario) ---
      "programacion": {
        "periodoAcademico": { "pk": 1780, "nombre": "2026", "fechaInicio": "2026-01-19",
                              "fechaFin": "2026-11-27", "semanas": 45 },     // null sin periodo/grupo
        "intensidadHoraria": {
          "bloquesPorSemana": 4, "minutosPorBloque": 55, "minutosPorSemana": 220,
          "diasHabiles": [ { "valor": 2, "nombre": "LUNES" } ],
          "horario": [ { "valor": 2, "nombre": "LUNES",
                         "bloques": [ { "numero": 1, "horaInicio": "07:00", "horaFin": "07:55", "minutos": 55 } ] } ],
          "motivo": "..."
        },
        "fechaInicio":      { "min": "2026-01-19", "max": "2026-11-27", "diasHabiles": [2, 4], "motivo": "..." },
        "fechaCierre":      { "min": "2026-01-19", "max": "2026-11-27", "diasHabiles": [2, 4], "motivo": "..." },
        "semanaCronograma": { "min": 1, "max": 45, "motivo": "..." },
        "duracionEstimada": { "min": 1, "max": 9900, "unidad": "MINUTOS", "paso": 55, "motivo": "..." }
      }
    }
  }]
}
```

`diasHabiles` usa `DIA_SEMANA.VALOR` (Domingo = 1). Los `pk` de catálogo no son
estables entre entornos: el front decide por `valor`.

### Errores

| HTTP | SQLSTATE | Cuándo | Estado |
|---|---|---|---|
| 404 | P0002 | La unidad no existe o está inactiva | igual |
| 404 | P0002 | El `?grupo=` no existe o está inactivo | **nuevo** |
| 404 | P0002 | La `?ACTIVIDAD_RECUPERAR=` no existe o está inactiva | **nuevo** |
| 422 | 22023 | El `?grupo=` no pertenece al grado de la unidad | **nuevo** |
| 422 | 22023 | La actividad a recuperar no es sumativa, ya es una recuperación o es de otra asignatura | **nuevo** |
| 403 | 42501 | Sin permiso VER sobre PLANEADOR o sin alcance sobre la unidad o el grupo | igual |

---

## 2. `GET /api/eval-col/planeador/docentes/grado-asignatura` (V497)

### Entradas

| Parámetro | Dónde | Tipo | Obligatorio | Estado | Descripción |
|---|---|---|---|---|---|
| `periodo` | query | BIGINT | no | igual | `PK_TPERIODO_ACADEMICO`; por defecto, el periodo vigente del docente |
| `referente` | query | BIGINT | no | **nuevo** | `pk_referente_curricular` de la pestaña de unidad desde la que se abre (lo da `GET /planeador/unidades/tabs`) |

Con `?referente=`, solo quedan los pares (grado, asignatura) cuyo referente
aplicable es ese. Se calcula con la misma regla que arma las pestañas, así que el
combo muestra justo los grados de esa pestaña. Sin `?referente=` responde igual que antes.

Una pestaña agrupada por nivel (sin referente, `pk_referente_curricular = null`)
no se puede filtrar: en ese caso no se envía el parámetro.

### Salida

Sin cambios de forma: la misma lista, filtrada.

```json
{
  "rows": [
    { "grado_id": 3744, "grado_codigo": "-1", "grado_nombre": "Jardin I",
      "asignatura_id": 4190, "asignatura_codigo": "MAT", "asignatura_nombre": "MATEMATICAS" }
  ]
}
```

Un referente que no existe, o que no aplica a ningún par del docente, devuelve
`rows: []` (no es error).

### Errores

Sin cambios: 403 (42501) sin permiso VER sobre PLANEADOR. Un usuario que no es
funcionario sigue recibiendo 200 con lista vacía.
