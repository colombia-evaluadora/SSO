-- Que hace: deja cada fila GRAFICA_CARITA/GRAFICA_SIMBOLO de TLISTA_VALOR con
-- su ACCION '<COLOR>_<NOMBRE>[_N]' (p.ej. 'AMARILLO_SUPERIOR_1') y con VALOR
-- apuntando a la clave S3 real del icono.
--
-- Por que aqui: el picker del front (RatingSymbolPicker) agrupa las caritas
-- por color parseando ACCION; sin ese dato el orden solo se ve "a ojo".
-- GET /eval-col/select/:CATEGORIA ya devuelve la columna tal cual.
-- Depende de: TARCHIVO con los iconos subidos (etiqueta graficaCarita /
-- graficaSimbolo). Estas filas llegan por el dump base, NO por migraciones:
-- en una base limpia no hay nada que casar y esto actualiza 0 filas sin fallar.

-- Empareja por NOMBRE DE ARCHIVO, no por PK: keyear por PK_LISTA_VALOR dejo
-- esta migracion en no-op silencioso en produccion. TARCHIVO.nombre es lo
-- unico estable entre entornos.
-- Sin ON COMMIT DROP: el paso de re-aplicacion de deploy.yml corre este
-- fichero por `psql -f` en autocommit y la temporal no sobreviviria.
DROP TABLE IF EXISTS v94_icono;
DROP TABLE IF EXISTS v94_clave;
CREATE TEMP TABLE v94_icono (categoria text, archivo text, accion text);

INSERT INTO v94_icono (categoria, archivo, accion) VALUES
  ('GRAFICA_CARITA','s.png'               ,'AMARILLO_SUPERIOR_1'),
  ('GRAFICA_CARITA','cSuperFeliz.png'     ,'AMARILLO_SUPERIOR_2'),
  ('GRAFICA_CARITA','cSuperFeliz2.png'    ,'AMARILLO_ALTO_1'),
  ('GRAFICA_CARITA','cfeliz.png'          ,'AMARILLO_ALTO_2'),
  ('GRAFICA_CARITA','bs.png'              ,'AMARILLO_BASICO_1'),
  ('GRAFICA_CARITA','cNormal2.png'        ,'AMARILLO_BASICO_2'),
  ('GRAFICA_CARITA','bj.png'              ,'AMARILLO_BAJO_1'),
  ('GRAFICA_CARITA','cTriste2.png'        ,'AMARILLO_BAJO_2'),
  ('GRAFICA_CARITA','sV.png'              ,'VERDE_SUPERIOR_1'),
  ('GRAFICA_CARITA','cSuperFelizV.png'    ,'VERDE_SUPERIOR_2'),
  ('GRAFICA_CARITA','cSuperFeliz2V.png'   ,'VERDE_ALTO_1'),
  ('GRAFICA_CARITA','cfelizV.png'         ,'VERDE_ALTO_2'),
  ('GRAFICA_CARITA','bsV.png'             ,'VERDE_BASICO_1'),
  ('GRAFICA_CARITA','cNormal2V.png'       ,'VERDE_BASICO_2'),
  ('GRAFICA_CARITA','bjV.png'             ,'VERDE_BAJO_1'),
  ('GRAFICA_CARITA','cTriste2V.png'       ,'VERDE_BAJO_2'),
  ('GRAFICA_CARITA','a.png'               ,'CELESTE_SUPERIOR_1'),
  ('GRAFICA_CARITA','cSuperFelizA.png'    ,'CELESTE_SUPERIOR_2'),
  ('GRAFICA_CARITA','cfeliz2.png'         ,'CELESTE_ALTO_1'),
  ('GRAFICA_CARITA','cfelizA.png'         ,'CELESTE_ALTO_2'),
  ('GRAFICA_CARITA','cNormal.png'         ,'CELESTE_BASICO_1'),
  ('GRAFICA_CARITA','cNormal2A.png'       ,'CELESTE_BASICO_2'),
  ('GRAFICA_CARITA','cTriste.png'         ,'CELESTE_BAJO_1'),
  ('GRAFICA_CARITA','cTriste2A.png'       ,'CELESTE_BAJO_2'),
  ('GRAFICA_CARITA','sN.png'              ,'NARANJA_SUPERIOR_1'),
  ('GRAFICA_CARITA','cSuperFelizN.png'    ,'NARANJA_SUPERIOR_2'),
  ('GRAFICA_CARITA','cSuperFeliz2N.png'   ,'NARANJA_ALTO_1'),
  ('GRAFICA_CARITA','cfelizN.png'         ,'NARANJA_ALTO_2'),
  ('GRAFICA_CARITA','bsN.png'             ,'NARANJA_BASICO_1'),
  ('GRAFICA_CARITA','cNormal2N.png'       ,'NARANJA_BASICO_2'),
  ('GRAFICA_CARITA','bjN.png'             ,'NARANJA_BAJO_1'),
  ('GRAFICA_CARITA','cTriste2N.png'       ,'NARANJA_BAJO_2'),
  ('GRAFICA_CARITA','sR.png'              ,'ROJO_SUPERIOR_1'),
  ('GRAFICA_CARITA','cSuperFelizR.png'    ,'ROJO_SUPERIOR_2'),
  ('GRAFICA_CARITA','cSuperFeliz2R.png'   ,'ROJO_ALTO_1'),
  ('GRAFICA_CARITA','cfelizR.png'         ,'ROJO_ALTO_2'),
  ('GRAFICA_CARITA','bsR.png'             ,'ROJO_BASICO_1'),
  ('GRAFICA_CARITA','cNormal2R.png'       ,'ROJO_BASICO_2'),
  ('GRAFICA_CARITA','bjR.png'             ,'ROJO_BAJO_1'),
  ('GRAFICA_CARITA','cTriste2R.png'       ,'ROJO_BAJO_2'),
  ('GRAFICA_SIMBOLO','s.png'              ,'AMARILLO_SUPERIOR'),
  ('GRAFICA_SIMBOLO','a.png'              ,'CELESTE_ALTO'),
  ('GRAFICA_SIMBOLO','bs.png'             ,'ROSADO_BASICO'),
  ('GRAFICA_SIMBOLO','bj.png'             ,'ROJO_BAJO'),
  ('GRAFICA_SIMBOLO','calA03.png'         ,'MORADO_ACEPTABLE'),
  ('GRAFICA_SIMBOLO','calD05.png'         ,'ROJO_DEFICIENTE'),
  ('GRAFICA_SIMBOLO','calE01.png'         ,'VERDE_EXCELENTE'),
  ('GRAFICA_SIMBOLO','calI04.png'         ,'ROSADO_INSUFICIENTE'),
  ('GRAFICA_SIMBOLO','calS02.png'         ,'NARANJA_SOBRESALIENTE');

-- DISTINCT ON: en test el mismo icono se subio dos veces; las copias son
-- identicas, sirve cualquiera.
CREATE TEMP TABLE v94_clave AS
SELECT DISTINCT ON (i.categoria, i.archivo)
       i.categoria, i.archivo, i.accion, a.urls3
  FROM v94_icono i
  JOIN academico_test.TARCHIVO a
    ON a.ACTIVE IS TRUE
   AND a.NOMBRE = i.archivo
   AND a.ETIQUETA = CASE i.categoria WHEN 'GRAFICA_CARITA' THEN 'graficaCarita'
                                     ELSE 'graficaSimbolo' END
 ORDER BY i.categoria, i.archivo, a.PK_TARCHIVO;

-- Idempotente: casa la fila con VALOR legacy ('img/caritas/<archivo>') y la
-- que ya apunta a su clave S3.
UPDATE academico_test.TLISTA_VALOR lv
   SET VALOR = k.urls3,
       ACCION = k.accion,
       MODIFIED_BY = 'V94_migration', MODIFIED_AT = CURRENT_TIMESTAMP
  FROM v94_clave k
 WHERE lv.CATEGORIA = k.categoria
   AND (split_part(lv.VALOR, '/', 3) = k.archivo OR lv.VALOR = k.urls3)
   AND (lv.VALOR IS DISTINCT FROM k.urls3 OR lv.ACCION IS DISTINCT FROM k.accion);

-- Los 5 simbolos Excelente..Deficiente no vienen en el dump base: hay que
-- crearlos. El PK se calcula (la tabla no tiene secuencia) y la guardia va por
-- ACCION, no por PK, para no insertar de nuevo donde ya existen.
INSERT INTO academico_test.TLISTA_VALOR
       (PK_LISTA_VALOR, CATEGORIA, NOMBRE, VALOR, ACCION, CREATED_BY, CREATED_AT, ACTIVE)
SELECT (SELECT max(PK_LISTA_VALOR) FROM academico_test.TLISTA_VALOR)
         + row_number() OVER (ORDER BY n.accion),
       'GRAFICA_SIMBOLO', n.nombre, k.urls3, n.accion, 'V94_migration', CURRENT_TIMESTAMP, TRUE
  FROM (VALUES ('MORADO_ACEPTABLE','Aceptable'), ('ROJO_DEFICIENTE','Deficiente'),
               ('VERDE_EXCELENTE','Excelente'), ('ROSADO_INSUFICIENTE','Insuficiente'),
               ('NARANJA_SOBRESALIENTE','Sobresaliente')) AS n(accion, nombre)
  JOIN v94_clave k ON k.categoria = 'GRAFICA_SIMBOLO' AND k.accion = n.accion
 WHERE NOT EXISTS (
         SELECT 1 FROM academico_test.TLISTA_VALOR e
          WHERE e.CATEGORIA = 'GRAFICA_SIMBOLO' AND e.ACCION = n.accion);

DROP TABLE IF EXISTS v94_icono;
DROP TABLE IF EXISTS v94_clave;
