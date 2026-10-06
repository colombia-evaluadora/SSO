# Archivos migrados: los dos S3 y cómo se leen

Los archivos de los colegios que vienen del sistema anterior (Oracle
`ACADEMIC`) **no se copian** al almacén de SSO. Su fila de `TARCHIVO` se
migra, pero los bytes se quedan en el bucket del sistema anterior y el
file-service los lee de ahí. Este documento explica:

- los dos almacenes;
- cómo decide el file-service de cuál leer;
- qué formatos de `urls3` trae Oracle y cómo los deja la migración.

## 1. Los dos almacenes

| | Bucket propio | Bucket legado |
|---|---|---|
| Qué es | El almacén de SSO: Garage en local y dev, S3 en producción | El S3 de AWS del sistema anterior (`coleva-files`) |
| Qué guarda | Todo lo que se sube desde SSO | Los archivos de los colegios migrados |
| Operaciones | Subir, leer, borrar | **Solo leer** |
| Configuración | `files.s3.*` (`S3_ENDPOINT`, `S3_REGION`, `S3_BUCKET`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`, `S3_PATH_STYLE`) | `files.s3.legado.*` (`S3_LEGADO_BUCKET`, `S3_LEGADO_REGION`, `S3_LEGADO_ACCESS_KEY`, `S3_LEGADO_SECRET_KEY`) |
| Si no se configura | El servicio no arranca | Desactivado: las filas migradas dan 404 |

Las credenciales van en el `.env` de cada servidor, nunca en el repo.
`application.yml`, `docker-compose.yml` y `.env.example` solo llevan
placeholders vacíos.

El bucket legado usa siempre el endpoint estándar de AWS, sin endpoint propio
y con estilo virtual-hosted. El access point de AWS no hace falta.

## 2. Cómo se lee un archivo

El front nunca ve una URL de S3. Pide `GET /api/files/download/{id}`,
`/view/{id}` o `/public/...` al api-gateway, y el file-service:

1. Autoriza al llamante: JWT, token de vista o token interno, más los
   permisos sobre el archivo.
2. Lee la fila de `TARCHIVO` y saca de `urls3` dos cosas:
   - la **clave** del objeto (`DownloadController.extraerClave`);
   - el **bucket**, si la URL lo nombra (`DownloadController.extraerBucket`).
3. Elige el almacén:
   - si el bucket de la URL es `files.s3.legado.bucket`, lee del **bucket
     legado** (`AlmacenObjetos.abrirLegado`);
   - en cualquier otro caso (clave cruda, bucket propio, otro bucket) lee del
     **bucket propio** (`AlmacenObjetos.abrir`), como siempre.
4. Streamea los bytes. Los objetos de hasta 2 MB se cachean en Redis; la
   clave de caché de un archivo legado lleva el prefijo `legado:` para no
   chocar con una clave igual del bucket propio.

Si el objeto no existe en el bucket, la respuesta es **404**, y el log dice
"fila activa pero objeto ausente en S3".

### Cómo se extraen clave y bucket

| Forma de `urls3` | Bucket | Clave |
|---|---|---|
| `s3://<bucket>/<clave>` | `<bucket>` | `<clave>` |
| `https://<bucket>.s3[.<región>].amazonaws.com/<clave>` (virtual-hosted) | `<bucket>` (del host) | todo el path |
| `http(s)://<host>/<bucket>/<clave>` (path-style, p. ej. Garage) | primer segmento del path | el resto del path |
| `<clave>` (sin esquema) | ninguno → bucket propio | tal cual |

Las claves crudas (`ACADEMICO_VALLEDUPAR/perfilUsuario/141906.jpeg`) son el
formato con el que SSO guarda lo que sube. Por eso la migración **no** puede
dejar las claves de Oracle sin bucket: el file-service las buscaría en el
bucket propio.

## 3. Formatos de `urls3` en Oracle

Recuento de `TARCHIVO` en Oracle `ACADEMIC` (2026-10-06), toda la base:

| Forma | Filas | Cómo queda en SSO |
|---|---:|---|
| Clave relativa | 1.697.292 | `s3://coleva-files/<clave>` |
| URL absoluta `https://coleva-files.s3.amazonaws.com/…` | 465.240 | igual (ya nombra el bucket) |
| Nula | 310.458 | nula |
| `s3://…` u otra URL `http` | 0 | — |

En Oracle no hay BLOBs: el contenido siempre está en el bucket.

### Claves relativas (1.697.292)

Patrón general: `<tenant>/<código DANE de la sede>/<tipo>/…`. En Cartagena el
tenant es `SEDCARTAUSER2015`.

| Tipo | Filas | Ejemplo |
|---|---:|---|
| `informePeriodo` (boletín de periodo) | 1.114.743 | `SEDCARTAUSER2015/000000000001/informePeriodo/PA2019PPL/PRIMER_PERIODO/1123019.pdf` |
| `informeFinal` (boletín final) | 460.139 | `SEDCARTAUSER2015/000000000001/informeFinal/PA2019PPL/1086068.pdf` |
| `actividad` (adjuntos de actividades) | 119.429 | `SEDCARTAUSER2015/000000000001/actividad/1099601.png` |
| `notificaciones` | 2.169 | `SEDCARTAUSER2015/notificaciones/Enviados/1958869.pdf` |
| `mensajes` | 563 | `SEDCARTAUSER2015/mensajes/Enviados/1628997.png` |
| `certificacion` | 203 | `SEDCARTAUSER2015/113001000143/certificacion/PA2022/1705737.pdf` |

Casos raros:

- **36 filas sin tenant**, por ejemplo
  `informePeriodo/PA2021/PEPRIMERPERIODO/1397877.pdf`. La muestra revisada no
  está en el bucket.
- **9 filas que no son clave**, por ejemplo `12j.pdf_actividad`: nombre de
  fichero con sufijo y sin carpeta. No existen en el bucket.
- **1 fila con el prefijo `sistema/`**: `sistema/1096018.pdf`. Sí existe.

Todas pasan igual a `s3://coleva-files/<clave>`. Las que no existen darán 404,
como en el sistema anterior.

### URLs absolutas (465.240)

Todas son virtual-hosted sobre `coleva-files`.

| Tipo | Filas | Ejemplo (path) |
|---|---:|---|
| `perfilUsuario` (fotos de perfil) | 369.334 | `SEDCARTAUSER2015/perfilUsuario/100018.jpeg` |
| `sistema/<tenant>/…` (escudos y recursos del colegio) | 61.637 | `sistema/SEDCARTAUSER2015/000000000001/escudo/250.JPG` |
| Por sede: `candidato`, `escudo`, `matricula/<pk>`, `documentosAnexos`, `recursoCompartido` | ≈ 33.900 | `SEDCARTAUSER2015/313001028225/matricula/2139323/<uuid>.pdf` |
| `firmaMecanica` | 383 | `SEDCARTAUSER2015/firmaMecanica/72105.jpeg` |
| `sistema/icono_perfil.png` (ícono por defecto) | 3 | `sistema/icono_perfil.png`: no existe en el bucket |

En estas URLs la clave es el path entero, **incluido** el primer segmento
(`sistema/` o el tenant). Tratarlas como path-style le quitaría ese segmento
y pediría una clave inexistente.

### ¿Existen los objetos?

Se tomaron muestras aleatorias de 40 filas por tipo:

| Tipo | Objetos encontrados |
|---|---:|
| `informePeriodo` | 40/40 |
| `informeFinal` | 40/40 |
| `actividad` | 39/40 |
| `perfilUsuario` | 40/40 |
| `sistema/…` | 40/40 |

Faltan casos puntuales: algún boletín de 2019 y los casos raros de arriba.

## 4. Qué hace la migración

Regla `TARCHIVO` en `db-migrations` (`config/mappings/L4_establecimiento.yaml`):

```sql
CASE WHEN TRIM(URLS3) IS NULL OR LOWER(URLS3) LIKE 'http%' OR LOWER(URLS3) LIKE 's3://%'
     THEN TRIM(URLS3)
     ELSE 's3://coleva-files/' || LTRIM(TRIM(URLS3), '/') END
```

- Las claves relativas reciben el bucket explícito.
- Las URL absolutas y las nulas pasan igual.
- Tras cargar, cada archivo se registra en `public.file_reference_location`.
  Sin esa fila el file-service no encuentra el archivo por su id.

Si algún día se copian los objetos al bucket propio (`migracion archivos
copiar` sigue disponible), basta con reescribir `urls3` a la clave cruda y
apagar `S3_LEGADO_BUCKET`.

## 5. Activarlo en un entorno

1. En el `.env` del servidor:
   - `S3_LEGADO_BUCKET=coleva-files`
   - `S3_LEGADO_REGION=us-east-1`
   - `S3_LEGADO_ACCESS_KEY` y `S3_LEGADO_SECRET_KEY` con una credencial **de
     solo lectura** sobre ese bucket.
2. Recrear el file-service. Al arrancar, el log dice
   `AlmacenObjetos: bucket legado (solo lectura) coleva-files`.
3. Probar la descarga de un archivo migrado por el api-gateway
   (`/api/files/download/{id}`). Si devuelve 502 con "S3 respondió 403", la
   credencial no tiene permiso de lectura sobre el bucket.
