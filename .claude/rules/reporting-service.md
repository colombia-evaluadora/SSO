---
paths:
  - "reporting-service/**"
---

# Reglas — reporting-service

Genera los PDF/Excel. No tiene SQL propio: cada reporte es una **clave** en su
`application.yml` que apunta a una fila de `public.query`. Complementa el
`CLAUDE.md` raíz.

## Skills y agentes

| Trabajo | Usar |
|---|---|
| La fila `public.query` del reporte | `/new-query-endpoint` + agente `query-service-endpoint-builder` |
| Código del servicio | skill `java-spring-boot` |
| Reportes contra la auditoría (ClickHouse) | skill `clickhouse-best-practices` |

## Restricciones

- **Un reporte reusa la MISMA función del listado**, con los mismos filtros y el
  mismo gate, solo que sin paginar. Escribir una `fn_*_reporte` aparte hace que
  el reporte y la pantalla diverjan en el `WHERE` o en el alcance territorial, y
  entonces el usuario exporta filas que no puede ver.
- **"Sin paginar" es `LIMIT NULL`, no un número grande.** Cuidado con
  `GREATEST(p_limite, 1)`: `GREATEST(NULL, 1) = 1` en PostgreSQL, así que pasar
  NULL a una función escrita así exporta **una** fila. El freno real es
  `REPORTING_MAX_ROWS` (50000 por defecto).
- **Los binds de un reporte van bajo `BODY.FILTERS.*`** aunque el listado los
  reciba por query-string, y con los **mismos nombres** que el `GET`: es el
  contrato único de `POST /reportes/{clave}` y permite que el front mande el
  objeto de filtros que ya arma.
- **`FILTERS.IDS` ("exportar seleccionados") se aplica DESPUÉS del gate**, en un
  `WHERE` por fuera de la función. Mandar el id de una fila que el usuario no
  puede ver no debe revelarla.
- **Los roles se copian de los del listado**: quien ve el listado puede
  exportarlo. Cópialos con un `INSERT ... SELECT` desde la fila hermana, no a
  mano, o se desincronizan.
- **El servicio corre multi-instancia**: nada de estado en memoria entre
  peticiones ni ficheros temporales que se asuman locales a la siguiente llamada.
- **La auditoría en ClickHouse limita las filas por su lado.** Si un export de
  auditoría sale corto, mira ese límite antes de tocar el reporting-service.

## Al cerrar

Verifica el export **en los dos formatos** (PDF y Excel) y con filtros activos,
no solo sin filtros: el caso que se rompe es el de los filtros combinados.
