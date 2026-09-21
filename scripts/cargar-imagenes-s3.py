#!/usr/bin/env python
"""Carga las imagenes de images/ en S3 y las registra en TARCHIVO.

Un archivo servible por file-service son DOS piezas, no una:

  1. el objeto en el bucket, con clave  <SITE_CODE>/<etiqueta>/<pk_tarchivo>.<ext>
  2. una fila ACTIVA en academico_test.tarchivo con esa clave en URLS3
  3. una fila en public.file_reference_location que diga en que esquema vive
     ese pk -- file-service no lo asume, lo consulta

Sin cualquiera de las tres, file-service responde 404 aunque el objeto este
subido y la fila activa, que es el 404 mas desconcertante de los tres. Y como la
clave lleva el pk, el orden es: insertar la fila (inactiva) -> subir el objeto
con el pk que devolvio -> activar la fila. Ese orden tambien es el que deja el
sistema consistente si el script se corta a la mitad: quedan filas inactivas,
que no sirven nada, en vez de filas activas que apuntan a un objeto que no
esta.

Idempotente: la pareja (NOMBRE, ETIQUETA) identifica un archivo. Si ya existe
activo, se salta; si quedo inactivo de una corrida anterior, se reintenta la
subida sobre la misma fila en vez de crear otra.

Sin dependencias: firma SigV4 con la libreria estandar y habla con la base por
psql. Instalar boto3 solo para esto no compensa.

Uso:
    python scripts/cargar-imagenes-s3.py                  # todo
    python scripts/cargar-imagenes-s3.py --solo fondos    # o iconos
    python scripts/cargar-imagenes-s3.py --dry-run
    python scripts/cargar-imagenes-s3.py --endpoint http://127.0.0.1:3900

Configuracion por entorno (los valores por defecto son los del compose local):
    S3_ENDPOINT S3_BUCKET S3_ACCESS_KEY S3_SECRET_KEY S3_REGION
    FILES_SITE_CODE    prefijo de la clave; vacio = sin prefijo
    PSQL_CMD           como hablar con la base
"""

import argparse
import datetime as dt
import hashlib
import hmac
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
IMAGENES = RAIZ / 'images'

# Solo graficaCarita y graficaSimbolo estan en PUBLIC_FILE_CLASSIFICATIONS
# (common/ParamTypes), asi que solo esos dos se sirven por
# GET /files/public/<clave> sin autenticacion. Los fondos se bajan por
# /files/download/{id}, que es lo que hace reporting-service con el token
# interno. Cambiar eso es tocar ese Set, no este script.
ETIQUETA_ICONOS = {'icon_c': 'graficaCarita', 'icon_s': 'graficaSimbolo'}

# El tipo de documento sale del nombre del archivo, no de la carpeta: la
# carpeta es el MODELO grafico (fondo1..fondo14) y dentro de cada una estan
# todos los formatos del mismo modelo.
ETIQUETA_FONDOS = [
    ('boletin',    'fondoBoletin'),
    ('acta',       'fondoActa'),
    ('constancia', 'fondoConstancia'),
    ('contancia',  'fondoConstancia'),   # el typo existe en los archivos
    ('mencion',    'fondoMencion'),
]
ETIQUETA_FONDO_POR_DEFECTO = 'fondoDiploma'   # vertical_*, horizontal_*, modelo*

TIPOS = {'.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png'}


# ---------------------------------------------------------------- S3 (SigV4)
class S3:

    def __init__(self, endpoint, bucket, access_key, secret_key, region):
        self.endpoint = endpoint.rstrip('/')
        self.bucket = bucket
        self.access_key = access_key
        self.secret_key = secret_key
        self.region = region

    def _firmar(self, clave, mensaje):
        return hmac.new(clave, mensaje.encode('utf-8'), hashlib.sha256).digest()

    def put(self, clave_objeto, datos, content_type):
        """Sube un objeto. Devuelve None si fue bien, o el error como texto."""
        ahora = dt.datetime.now(dt.timezone.utc)
        amz_date = ahora.strftime('%Y%m%dT%H%M%SZ')
        fecha = ahora.strftime('%Y%m%d')
        host = urllib.parse.urlparse(self.endpoint).netloc
        sha = hashlib.sha256(datos).hexdigest()

        # Path-style: <endpoint>/<bucket>/<clave>. Cada segmento se codifica
        # por separado para que las barras de la clave sigan siendo barras.
        ruta = '/' + self.bucket + '/' + '/'.join(
            urllib.parse.quote(p, safe='') for p in clave_objeto.split('/'))

        firmados = 'host;x-amz-content-sha256;x-amz-date'
        canonica = '\n'.join([
            'PUT', ruta, '',
            'host:' + host,
            'x-amz-content-sha256:' + sha,
            'x-amz-date:' + amz_date,
            '', firmados, sha])

        alcance = '/'.join([fecha, self.region, 's3', 'aws4_request'])
        por_firmar = '\n'.join([
            'AWS4-HMAC-SHA256', amz_date, alcance,
            hashlib.sha256(canonica.encode('utf-8')).hexdigest()])

        k = self._firmar(('AWS4' + self.secret_key).encode('utf-8'), fecha)
        k = self._firmar(k, self.region)
        k = self._firmar(k, 's3')
        k = self._firmar(k, 'aws4_request')
        firma = hmac.new(k, por_firmar.encode('utf-8'), hashlib.sha256).hexdigest()

        req = urllib.request.Request(self.endpoint + ruta, data=datos, method='PUT')
        req.add_header('Host', host)
        req.add_header('Content-Type', content_type)
        req.add_header('x-amz-content-sha256', sha)
        req.add_header('x-amz-date', amz_date)
        req.add_header('Authorization',
                       'AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s'
                       % (self.access_key, alcance, firmados, firma))
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                if r.status not in (200, 204):
                    return 'HTTP %s' % r.status
            return None
        except urllib.error.HTTPError as e:
            return 'HTTP %s: %s' % (e.code, e.read().decode('utf-8', 'replace')[:200])
        except Exception as e:                                  # noqa: BLE001
            return str(e)


# ---------------------------------------------------------------- base
class Base:

    def __init__(self, psql_cmd, dry_run):
        self.psql_cmd = psql_cmd
        self.dry_run = dry_run

    def consultar(self, sql):
        """Devuelve la primera columna de la primera fila, o None."""
        r = subprocess.run(self.psql_cmd + ['-t', '-A', '-v', 'ON_ERROR_STOP=1', '-c', sql],
                           capture_output=True, text=True, encoding='utf-8')
        if r.returncode != 0:
            raise RuntimeError((r.stderr or '').strip()[:400])
        salida = (r.stdout or '').strip()
        return salida.splitlines()[0] if salida else None

    def ejecutar(self, sql):
        if self.dry_run:
            return
        r = subprocess.run(self.psql_cmd + ['-v', 'ON_ERROR_STOP=1', '-c', sql],
                           capture_output=True, text=True, encoding='utf-8')
        if r.returncode != 0:
            raise RuntimeError((r.stderr or '').strip()[:400])


def escapar(s):
    return s.replace("'", "''")


# ---------------------------------------------------------------- catalogo
def etiqueta_de(ruta):
    """La etiqueta con la que se archiva un fichero de images/."""
    partes = ruta.relative_to(IMAGENES).parts
    if partes[0] == 'iconos':
        return ETIQUETA_ICONOS.get(partes[1])
    if partes[0] == 'fondos':
        minus = ruta.name.lower()
        for aguja, etiqueta in ETIQUETA_FONDOS:
            if minus.startswith(aguja):
                return etiqueta
        return ETIQUETA_FONDO_POR_DEFECTO
    return None


def nombre_de(ruta):
    """El NOMBRE con el que la fila queda identificada.

    Para los iconos es el nombre del archivo, como ya estan cargados en los
    servidores. Para los fondos lleva la carpeta delante, porque las 16
    carpetas repiten los mismos nombres y sin eso 'boletinCarta.jpg' seria
    ambiguo entre modelos.
    """
    partes = ruta.relative_to(IMAGENES).parts
    if partes[0] == 'iconos':
        return ruta.name
    return '/'.join(partes[1:])


def inventario(solo):
    for ruta in sorted(IMAGENES.rglob('*')):
        if not ruta.is_file() or ruta.suffix.lower() not in TIPOS:
            continue
        grupo = ruta.relative_to(IMAGENES).parts[0]
        if solo and grupo != solo:
            continue
        etiqueta = etiqueta_de(ruta)
        if etiqueta:
            yield ruta, etiqueta, nombre_de(ruta)


# ---------------------------------------------------------------- principal
def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--solo', choices=['fondos', 'iconos'])
    p.add_argument('--dry-run', action='store_true')
    p.add_argument('--endpoint', default=os.environ.get('S3_ENDPOINT', 'http://127.0.0.1:3900'))
    p.add_argument('--bucket', default=os.environ.get('S3_BUCKET', 'eval-col'))
    p.add_argument('--region', default=os.environ.get('S3_REGION', 'garage'))
    p.add_argument('--site-code', default=os.environ.get('FILES_SITE_CODE', ''))
    p.add_argument('--schema', default=os.environ.get('FILES_SCHEMA', 'academico_test'),
                   help='esquema donde vive TARCHIVO, tal como lo ve file-service')
    p.add_argument('--tabla', default='tarchivo')
    p.add_argument('--psql', default=os.environ.get(
        'PSQL_CMD', 'docker exec -i sso-postgres psql -U neondb_owner -d sso_db'))
    args = p.parse_args()

    access = os.environ.get('S3_ACCESS_KEY')
    secret = os.environ.get('S3_SECRET_KEY')
    if not args.dry_run and not (access and secret):
        # Comodidad local: si no vienen por entorno se leen del contenedor de
        # file-service, que es quien las tiene de verdad.
        try:
            env = subprocess.run(
                ['docker', 'exec', 'sso-file-service', 'env'],
                capture_output=True, text=True).stdout
            for linea in env.splitlines():
                if linea.startswith('S3_ACCESS_KEY='):
                    access = access or linea.split('=', 1)[1]
                elif linea.startswith('S3_SECRET_KEY='):
                    secret = secret or linea.split('=', 1)[1]
        except Exception:                                       # noqa: BLE001
            pass
    if not args.dry_run and not (access and secret):
        sys.exit('Faltan S3_ACCESS_KEY / S3_SECRET_KEY.')

    s3 = S3(args.endpoint, args.bucket, access, secret, args.region)
    base = Base(args.psql.split(), args.dry_run)
    prefijo = args.site_code.strip('/')

    archivos = list(inventario(args.solo))
    if not archivos:
        sys.exit('No hay imagenes que cargar en %s' % IMAGENES)

    print('%d archivos | bucket %s | endpoint %s | prefijo %r%s'
          % (len(archivos), args.bucket, args.endpoint, prefijo,
             '  [DRY RUN]' if args.dry_run else ''))

    subidos = saltados = fallidos = 0
    for ruta, etiqueta, nombre in archivos:
        datos = ruta.read_bytes()
        ext = ruta.suffix.lower()

        # El estado se pide como 'si'/'no' y no como el booleano: psql imprime
        # ACTIVE::TEXT como 'true', no como 't', y comparar contra 't' hacia
        # que el salto por idempotencia no se activara nunca.
        existente = base.consultar(
            "SELECT PK_TARCHIVO || '|' || CASE WHEN ACTIVE THEN 'si' ELSE 'no' END "
            "FROM academico_test.TARCHIVO "
            "WHERE NOMBRE = '%s' AND ETIQUETA = '%s' "
            "ORDER BY PK_TARCHIVO DESC LIMIT 1" % (escapar(nombre), escapar(etiqueta)))

        if existente:
            pk, activo = existente.split('|')
            if activo == 'si':
                saltados += 1
                continue
        elif args.dry_run:
            pk = '?'
        else:
            # Nace inactiva y con una URLS3 provisional: la definitiva lleva el
            # pk, que solo se conoce despues de insertar.
            pk = base.consultar(
                "INSERT INTO academico_test.TARCHIVO "
                "(NOMBRE, URLS3, PESO, ETIQUETA, FECHA, CREATED_BY, CREATED_AT, ACTIVE) "
                "VALUES ('%s', 'pendiente-%s-%s', %d, '%s', CURRENT_DATE, "
                "'cargar-imagenes-s3', CURRENT_TIMESTAMP, FALSE) "
                "RETURNING PK_TARCHIVO"
                % (escapar(nombre), escapar(etiqueta), escapar(ruta.name),
                   len(datos), escapar(etiqueta)))

        clave = '/'.join(x for x in [prefijo, etiqueta, '%s%s' % (pk, ext)] if x)

        if args.dry_run:
            print('  [dry] %-34s -> %s' % (nombre, clave))
            subidos += 1
            continue

        error = s3.put(clave, datos, TIPOS[ext])
        if error:
            print('  FALLA %-34s %s' % (nombre, error))
            fallidos += 1
            continue

        # Recien ahora se activa: la fila apunta a un objeto que ya esta.
        base.ejecutar(
            "UPDATE academico_test.TARCHIVO SET URLS3 = '%s', PESO = %d, ACTIVE = TRUE, "
            "MODIFIED_BY = 'cargar-imagenes-s3', MODIFIED_AT = CURRENT_TIMESTAMP "
            "WHERE PK_TARCHIVO = %s" % (escapar(clave), len(datos), pk))

        # LA TERCERA PIEZA, y la que se olvida: file-service no sabe en que
        # esquema vive un TARCHIVO. ArchivoRepository.ubicacionDe consulta
        # public.file_reference_location y, si no hay fila, buscarActivo
        # devuelve vacio y el endpoint responde 404 -- con el objeto subido y
        # la fila activa, que es el 404 mas desconcertante posible.
        base.ejecutar(
            "INSERT INTO public.file_reference_location "
            "(pk_tarchivo, schema_name, table_name, urls3) "
            "VALUES (%s, '%s', '%s', '%s') "
            "ON CONFLICT (pk_tarchivo) DO UPDATE SET urls3 = EXCLUDED.urls3"
            % (pk, escapar(args.schema), escapar(args.tabla), escapar(clave)))
        subidos += 1
        print('  ok    %-34s -> %s' % (nombre, clave))

    print('\nsubidos %d | ya estaban %d | fallidos %d' % (subidos, saltados, fallidos))
    return 1 if fallidos else 0


if __name__ == '__main__':
    sys.exit(main())
