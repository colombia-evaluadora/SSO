-- TLISTA_VALOR.ACCION no se usaba para nada en GRAFICA_CARITA/GRAFICA_SIMBOLO
-- (columna libre, sin significado hasta ahora). El picker de iconografia del
-- front (RatingSymbolPicker, dialog-create-rating-scale.tsx) necesita agrupar
-- las caritas por color para mostrarlas en filas -- hoy ese agrupamiento no
-- existe en la data, solo se ve "a ojo" en el orden en que vienen. Se usa
-- ACCION para guardar "<COLOR>_<NOMBRE>_<N>" (p.ej. 'AMARILLO_SUPERIOR_1'):
-- combina el color (confirmado visualmente contra el picker real) con el
-- NOMBRE ya existente de la fila (Alto/Bajo/Basico/Superior) y un consecutivo
-- (1/2) porque cada color tiene dos caritas del mismo NOMBRE. El front arma
-- el orden del picker parseando este campo, no hay ids hardcodeados.
--
-- GET /eval-col/select/:CATEGORIA (fetch-select-category.ts en el front) ya
-- devuelve la columna ACCION tal cual -- no requiere cambios de backend, solo
-- llenar el dato.
--
-- IMPORTANTE al correr esto a mano en pgAdmin/DBeaver: seleccionar TODO el
-- archivo antes de ejecutar (o usar "Execute Script", no "Execute current
-- statement") -- son dos UPDATE, cada uno es una sola sentencia.

UPDATE academico_test.TLISTA_VALOR
SET ACCION = CASE PK_LISTA_VALOR

       -- AMARILLO (8)
       WHEN 989 THEN 'AMARILLO_SUPERIOR_1' WHEN 990 THEN 'AMARILLO_ALTO_1'
       WHEN 993 THEN 'AMARILLO_SUPERIOR_2' WHEN 991 THEN 'AMARILLO_BASICO_1'
       WHEN 995 THEN 'AMARILLO_BASICO_2' WHEN 992 THEN 'AMARILLO_BAJO_1'
       WHEN 996 THEN 'AMARILLO_BAJO_2' WHEN 994 THEN 'AMARILLO_ALTO_2'

       -- VERDE (8)
       WHEN 1027 THEN 'VERDE_BAJO_2' WHEN 1022 THEN 'VERDE_BASICO_1'
       WHEN 1024 THEN 'VERDE_SUPERIOR_2' WHEN 1023 THEN 'VERDE_BAJO_1'
       WHEN 1025 THEN 'VERDE_ALTO_2' WHEN 1020 THEN 'VERDE_SUPERIOR_1'
       WHEN 1021 THEN 'VERDE_ALTO_1' WHEN 1026 THEN 'VERDE_BASICO_2'

       -- CELESTE (8)
       WHEN 997 THEN 'CELESTE_SUPERIOR_1' WHEN 1028 THEN 'CELESTE_SUPERIOR_2'
       WHEN 998 THEN 'CELESTE_ALTO_1' WHEN 1001 THEN 'CELESTE_ALTO_2'
       WHEN 1002 THEN 'CELESTE_BASICO_2' WHEN 1000 THEN 'CELESTE_BAJO_1'
       WHEN 999 THEN 'CELESTE_BASICO_1' WHEN 1003 THEN 'CELESTE_BAJO_2'

       -- NARANJA (8)
       WHEN 1019 THEN 'NARANJA_BAJO_2' WHEN 1014 THEN 'NARANJA_BASICO_1'
       WHEN 1017 THEN 'NARANJA_ALTO_2' WHEN 1015 THEN 'NARANJA_BAJO_1'
       WHEN 1016 THEN 'NARANJA_SUPERIOR_2' WHEN 1012 THEN 'NARANJA_SUPERIOR_1'
       WHEN 1013 THEN 'NARANJA_ALTO_1' WHEN 1018 THEN 'NARANJA_BASICO_2'

       -- ROJO (8)
       WHEN 1007 THEN 'ROJO_BAJO_1' WHEN 1006 THEN 'ROJO_BASICO_1'
       WHEN 1009 THEN 'ROJO_ALTO_2' WHEN 1011 THEN 'ROJO_BAJO_2'
       WHEN 1008 THEN 'ROJO_SUPERIOR_2' WHEN 1004 THEN 'ROJO_SUPERIOR_1'
       WHEN 1005 THEN 'ROJO_ALTO_1' WHEN 1010 THEN 'ROJO_BASICO_2'

       ELSE ACCION

END,
   MODIFIED_BY = 'V94_migration', MODIFIED_AT = CURRENT_TIMESTAMP
 WHERE CATEGORIA = 'GRAFICA_CARITA'
   AND PK_LISTA_VALOR IN (
       989, 990, 993, 991, 995, 992, 996, 994,
       1027, 1022, 1024, 1023, 1025, 1020, 1021, 1026,
       997, 1028, 998, 1001, 1002, 1000, 999, 1003,
       1019, 1014, 1017, 1015, 1016, 1012, 1013, 1018,
       1007, 1006, 1009, 1011, 1008, 1004, 1005, 1010
   );

UPDATE academico_test.TLISTA_VALOR
   SET ACCION = CASE PK_LISTA_VALOR
       WHEN 578 THEN 'CELESTE_ALTO'
       WHEN 580 THEN 'ROJO_BAJO'
       WHEN 579 THEN 'ROSADO_BASICO'
       WHEN 577 THEN 'AMARILLO_SUPERIOR'
       ELSE ACCION
   END,
   MODIFIED_BY = 'V94_migration', MODIFIED_AT = CURRENT_TIMESTAMP
 WHERE CATEGORIA = 'GRAFICA_SIMBOLO'
   AND PK_LISTA_VALOR IN (578, 580, 579, 577);
