# images/

Las imágenes que el sistema sirve desde S3: los fondos institucionales de los
documentos impresos y los iconos de calificación.

Están en el repositorio **como fuente**, no como algo que se sirva desde aquí.
Ningún servicio lee esta carpeta en tiempo de ejecución: la lee
`scripts/cargar-imagenes-s3.py` para subirlas, y a partir de ahí todo el mundo
las pide por `file-service`.

```
images/
  fondos/
    fondo1 … fondo14      un modelo gráfico por carpeta, con todos sus formatos
    diploma/              diplomas por orientación (horizontal, vertical, peques)
    fondoDiplomas/        variantes sueltas de diploma
  iconos/
    icon_c/               40 caritas   → etiqueta graficaCarita
    icon_s/                9 símbolos  → etiqueta graficaSimbolo
```

## Cómo se cargan

```bash
python scripts/cargar-imagenes-s3.py              # todo, idempotente
python scripts/cargar-imagenes-s3.py --solo fondos
python scripts/cargar-imagenes-s3.py --dry-run    # qué haría, sin tocar nada
```

Un archivo servible son **tres** piezas, y las tres las escribe el script:

1. el objeto en el bucket, con clave `<SITE_CODE>/<etiqueta>/<pk_tarchivo>.<ext>`
2. una fila **activa** en `academico_test.tarchivo` con esa clave en `URLS3`
3. una fila en `public.file_reference_location` que diga en qué esquema vive ese
   pk — `file-service` no lo asume, lo consulta

Si falta cualquiera de las tres, `file-service` responde **404** aunque el objeto
esté subido. La tercera es la que más cuesta diagnosticar, porque todo lo
visible parece correcto.

## Etiquetas

La etiqueta sale del **nombre** del archivo, no de la carpeta: la carpeta es el
modelo gráfico y dentro de cada una están todos los formatos de ese modelo.

| Archivo | Etiqueta |
|---|---|
| `boletin*` | `fondoBoletin` |
| `acta*` | `fondoActa` |
| `constancia*` / `contancia*` (el typo existe) | `fondoConstancia` |
| `mencion*` | `fondoMencion` |
| el resto de fondos | `fondoDiploma` |
| `iconos/icon_c/*` | `graficaCarita` |
| `iconos/icon_s/*` | `graficaSimbolo` |

De todas ellas, **solo `graficaCarita` y `graficaSimbolo` son públicas**: son las
dos únicas en `PUBLIC_FILE_CLASSIFICATIONS`
([ParamTypes](../common/src/main/java/com/co/eurekatic/common/query/ParamTypes.java)),
así que solo esas se sirven por `GET /files/public/<clave>` sin autenticación.
Los fondos se bajan por `/files/download/{id}`, que es lo que hace
reporting-service con el token interno al imprimir un boletín.

## Cómo se usa un fondo

`TESTABLECIMIENTO.FK_TARCHIVO_FONDO_BOLETIN` (V465) apunta al `pk_tarchivo` del
fondo que esa institución imprime. En `NULL` el boletín sale sobre blanco:
degradado, no roto.

```sql
UPDATE academico_test.TESTABLECIMIENTO
   SET FK_TARCHIVO_FONDO_BOLETIN = (
       SELECT PK_TARCHIVO FROM academico_test.TARCHIVO
        WHERE NOMBRE = 'fondo8/boletinOficio.jpg' AND ETIQUETA = 'fondoBoletin')
 WHERE PK_ESTABLECIMIENTO = :ee;
```

El tamaño de página (Carta u Oficio) queda implícito en la imagen que se elija:
la plantilla del boletín es Oficio (613x894), que es el tamaño de los
`boletinOficio.jpg`.
