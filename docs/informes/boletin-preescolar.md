# Boletín de preescolar

Guía para el front: cómo pedir el boletín, qué vuelve y **por qué** funciona así.

Son **dos** endpoints, y sirven cosas distintas:

```
POST /api/eval-col/informes/boletin-preescolar   los datos (JSON)
POST /api/reportes/boletin-preescolar            el PDF ya armado
```

Casi siempre querés el segundo. El primero existe para previsualizar en pantalla
sin generar un archivo, y es el que el reporting-service consume por dentro.

> No confundir con `POST /informes/reporte`, que exporta la **tabla** de la
> pantalla en formato largo —una fila por (estudiante, periodo, asignatura)— y
> sirve para Excel. Eso no es un boletín.

---

## Índice

1. [El PDF](#1-el-pdf)
2. [Qué lleva cada página](#2-qué-lleva-cada-página) ← **leé esto**
3. [Los datos en JSON](#3-los-datos-en-json)
4. [Permisos y errores](#4-permisos-y-errores)
5. [Requisitos de entorno](#5-requisitos-de-entorno)

---

## 1. El PDF

```http
POST /api/reportes/boletin-preescolar
Authorization: Bearer <jwt>
Content-Type: application/json

{
  "format": "pdf",
  "filters": {
    "FK_TGRUPO": 136,
    "FK_TPERIODO_EVALUACION": 110,
    "FK_TMATRICULAS": [192, 193]
  }
}
```

| Filtro | Obligatorio | Qué hace |
|---|---|---|
| `FK_TGRUPO` | sí | el grupo |
| `FK_TPERIODO_EVALUACION` | sí | el periodo |
| `FK_TMATRICULAS` | no | acota a unos estudiantes; sin él sale **el grupo entero** |

La respuesta es el binario:

```
200 OK
Content-Type: application/pdf
Content-Disposition: attachment; filename="boletin-preescolar-20260921.pdf"
X-Report-Rows: 2
```

### `format` solo acepta `pdf`

Pedirlo en Excel responde **400**. Un boletín no es una grilla: en una hoja de
cálculo sería una fila ilegible por estudiante, con las fotos perdidas.

### ⚠️ Un grupo sin preescolar devuelve 200, no un error

Este es el caso que hay que manejar. Sobre un grupo **numérico** la respuesta es:

```
200 OK
Content-Type: application/pdf
X-Report-Rows: 0          ← mirá esto
```

…y el cuerpo es un PDF válido de ~839 bytes **sin ninguna página**. No es un
fallo: este boletín solo sabe imprimir lo cualitativo, y pedirlo sobre un grupo
de bachillerato no es un error del usuario, simplemente no hay nada que imprimir.

**Antes de ofrecer la descarga, mirá `X-Report-Rows`.** Si es `0`, mostrá un
mensaje en vez de bajar un archivo vacío que el usuario va a abrir y no va a
entender.

---

## 2. Qué lleva cada página

**Una página por estudiante.** El título del bloque de seguimiento **no es un
rótulo fijo**: son los nombres de las dimensiones que el estudiante cursa,
unidos en una sola línea y en el orden del plan —«Comunicación y exploración,
Valores»—, que en preescolar cambian por institución.

**No hay una observación por asignatura, y no es un olvido.** Se buscó en todo
el esquema: lo único que cuelga de una asignatura es materia prima sin revisar
(`TACTIVIDAD_NOTA.OBSERVACION` y las de rúbrica, escala y cotejo). Lo aprobado
por un humano es `TESTUDIANTE_PERIODO_OBSERVACION` —por (matrícula, periodo)— y
`TESTUDIANTE_ANIO_OBSERVACION` —por matrícula—, y ninguna lleva asignatura. Un
boletín publica lo que alguien aceptó, así que se imprime ese párrafo **una sola
vez**. Si algún día hace falta un texto aprobado *por* asignatura, el hueco
natural es `TASIGNATURA_NOTA`, que ya tiene el grano exacto y hoy no tiene
columna de texto.

### Los bloques

| Bloque | De dónde sale |
|---|---|
| Encabezado institucional | nombre, DANE, NIT y ciudad del establecimiento |
| Foto del estudiante | `TMATRICULA_ARCHIVO`, tipo `ARCHIVO_MATRICULA` = `05` |
| Sede · Nivel · Grado · Grupo · Periodo | el grupo y su periodo académico |
| Título del bloque | las dimensiones que cursa, en una línea (ver arriba) |
| Seguimiento y valoración | la observación del periodo que el docente aprobó, una sola vez |
| Evidencias (hasta **6**) | las **más recientes** de **todas** las materias: actividades del periodo con observación escrita, con su primera foto adjunta |
| Firma | el rector del establecimiento |

**La fecha de cada foto es la de su carga**, no la de la actividad. Una actividad
de marzo puede recibir una evidencia en mayo, y fecharla con la actividad sería
mentir sobre cuándo se tomó.

### Lo que **no** hace desaparecer a un estudiante

Un estudiante **sin observación** sale igual, con el bloque vacío. Lo mismo uno
sin ninguna asignatura: conserva su página con el rótulo genérico. Es
deliberado — filtrar por «tiene contenido» hacía desaparecer al estudiante entero
del boletín, sin aviso, y es un fallo que ya ocurrió antes en el reporte tabular.

Las imágenes que falten dejan el hueco vacío; ninguna tumba el boletín del curso.

---

## 3. Los datos en JSON

Mismo cuerpo, otra ruta:

```http
POST /api/eval-col/informes/boletin-preescolar
Content-Type: application/json

{ "FILTERS": { "FK_TGRUPO": 136, "FK_TPERIODO_EVALUACION": 110 } }
```

> Ojo con la forma del cuerpo: acá `FILTERS` va **en mayúsculas y en la raíz**
> (es el contrato del query-service); en `/api/reportes/...` va `filters` en
> minúsculas, junto a `format`.

```json
{
  "rows": [{
    "ee_nombre": "Institución Educativa Fundación Pies Descalzos",
    "ee_dane": "113001800019",
    "ee_nit": "9018038088",
    "ciudad": "Cartagena",
    "sede_nombre": "Sede principal",
    "nivel_ensenanza": "Preescolar",
    "grado_nombre": "Jardín I",
    "grupo_etiqueta": "101 Tarde",
    "periodo_nombre": "Segundo periodo",
    "anio": 2026,
    "fondo_archivo": 167,
    "estudiante": "BRAYAN DE JESUS ALFARO BARRERA",
    "documento": "1234567890",
    "foto_archivo": 901,
    "asignatura_nombre": "Comunicación y exploración",
    "area_nombre": "Dimensiones",
    "observacion": "Durante este segundo periodo…",
    "observacion_estado": "APROBADA",
    "evidencia1_titulo": "Exploración del entorno natural",
    "evidencia1_fecha": "2026-04-09",
    "evidencia1_archivo": 912,
    "evidencia2_titulo": null, "evidencia2_fecha": null, "evidencia2_archivo": null,
    "rector_nombre": "PAYARES HERAZO ALEJANDRA"
  }]
}
```

Las evidencias van en **seis ranuras planas** (`evidencia1_*` … `evidencia6_*`),
no en un arreglo. Las que sobran vienen en `null`.

### Las imágenes son `PK_TARCHIVO`, no URLs

`fondo_archivo`, `foto_archivo` y `evidenciaN_archivo` son ids de `TARCHIVO`. Para
mostrarlos hay que pedirle los bytes a file-service:

```
GET /api/files/download/{id}
POST /api/files/view-token/{id}   → devuelve una URL firmada de vida corta,
                                     que es lo que sirve para un <img src="…">
```

No intentes construir una URL a partir del id: `TARCHIVO.URLS3` guarda una clave
interna de S3, no una dirección navegable.

---

## 4. Permisos y errores

Hereda gate, alcance territorial y filtros de `POST /informes/grupo` — es la misma
función por dentro. Si no ves un grupo en la pantalla de informes, tampoco podés
imprimir su boletín.

| Situación | Respuesta |
|---|---|
| Sin permiso o fuera de alcance (`42501`) | **403** |
| Grupo o periodo que no existe (`P0002`) | **404** |
| `format` distinto de `pdf` | **400** |
| Grupo sin estudiantes cualitativos | **200** con `X-Report-Rows: 0` |
| Más filas que `REPORTING_MAX_ROWS` | **422**, pidiendo acotar |

Los roles con acceso son los mismos que los del listado de informes: se copian de
`/informes/grupo` al desplegar, para que no se desincronicen el día que alguien
agregue un rol a la pantalla y se olvide del boletín.

---

## 5. Requisitos de entorno

Esto no es código: si falta, el boletín sale **sin fondo** —sobre blanco— pero no
falla.

1. **Cargar las imágenes** una vez por entorno:

   ```bash
   python scripts/cargar-imagenes-s3.py
   ```

   Es idempotente; una segunda corrida informa `subidos 0 | ya estaban N`.
   Ver [`images/README.md`](../../images/README.md).

2. **Asignar el fondo al establecimiento.** Los que se creen de ahora en adelante
   reciben `fondo1/boletinOficio.jpg` automáticamente (trigger de V467). Los que ya
   existían siguen en `NULL` hasta que se les asigne uno:

   ```sql
   UPDATE academico_test.TESTABLECIMIENTO
      SET FK_TARCHIVO_FONDO_BOLETIN = (
          SELECT PK_TARCHIVO FROM academico_test.TARCHIVO
           WHERE NOMBRE = 'fondo8/boletinOficio.jpg' AND ETIQUETA = 'fondoBoletin')
    WHERE PK_ESTABLECIMIENTO = :ee;
   ```

3. **Variables de reporting-service**: `REPORTING_FILE_SERVICE_URL` y
   `REPORTING_FILE_INTERNAL_TOKEN`. Este último tiene que ser **el mismo** valor que
   `FILES_INTERNAL_TOKEN` de file-service. Si se desincronizan, el boletín sale sin
   imágenes **y sin error visible** — el síntoma es un PDF que pesa poco y llega con
   todos los huecos en blanco.

El tamaño de página es **Oficio** (613×894), que es el de los `boletinOficio.jpg`.
Un fondo de tamaño Carta se escala y deja franja.
