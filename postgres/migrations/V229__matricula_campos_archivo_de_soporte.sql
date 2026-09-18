-- ===========================================================================
-- V229 - los adjuntos de la matricula pasan a ser campos configurables,
--        como los otros 65.
--
-- QUE AÑADE
--   La seccion "Archivo de soporte" del formulario de matricula pide cinco
--   documentos, pero ninguno existia en TMATRICULA_CAMPO: estaban fijos en
--   el front, sin forma de que un establecimiento decidiera cuales exige o
--   cuales muestra. Los otros 65 campos si son configurables desde
--   "Configuracion de matricula", y estos quedaban fuera.
--
--   Se suman como una seccion nueva, la 14, en el mismo orden que la
--   pantalla:
--
--       01  Documento de Identidad                     requerido
--       04  Certificado de Estudios del Año Anterior   requerido
--       02  Certificado Medico                         opcional
--       05  Foto del Estudiante                        opcional
--       06  Otros Documentos Relevantes                opcional
--
--   Los dos primeros llevan asterisco en la pantalla, asi que nacen con
--   REQUERIDO_DEFECTO = 'S'; los otros tres con 'N'. Los cinco visibles.
--
-- EL NOMBRE NO SE ESCRIBE AQUI: SALE DE TLISTA_VALOR
--   Estos cinco documentos ya existen como catalogo en
--   TLISTA_VALOR CATEGORIA = 'ARCHIVO_MATRICULA' -- es a lo que apunta
--   TMATRICULA_ARCHIVO.FK_TLV_TIPO_ARCHIVO cuando se sube un adjunto. Copiar
--   los nombres a mano crearia una segunda fuente para el mismo dato y
--   bastaria una tilde de diferencia para que el campo configurable y el
--   adjunto real dejaran de corresponderse.
--
--   Por eso el INSERT los LEE de ahi y empareja por VALOR ('01', '02', ...),
--   que es el codigo estable del catalogo. No por nombre -- texto editable y
--   con tildes -- ni por PK_LISTA_VALOR, que no es estable entre entornos
--   (en produccion 'Certificado de Estudios del Año Anterior' es 51968 y
--   podria no serlo en una base nueva).
--
--   Efecto: si el catalogo se renombra, estos campos quedan desalineados en
--   el nombre pero el emparejamiento por VALOR sigue siendo el correcto para
--   volver a sincronizarlos.
--
-- EL SEXTO DOCUMENTO QUEDA FUERA
--   ARCHIVO_MATRICULA tiene SEIS valores. El que falta es
--   '03 Informe descriptivo / Boletin de periodo', que no aparece en la
--   pantalla de "Archivo de soporte". No se añade a proposito: hacerlo
--   mostraria en la configuracion un documento que el formulario no pide.
--   Si mas adelante entra en esa pantalla, se suma aqui con su codigo.
--
-- TODOS EDITABLES
--   EDITABLE = 'S' en los cinco, que ademas es el valor por defecto de la
--   columna. EDITABLE no dice si el usuario rellena el campo: dice si un
--   establecimiento puede cambiar su comportamiento -- exigirlo o esconderlo
--   -- desde la configuracion. Los 17 campos en 'N' son los que el sistema
--   necesita siempre (sede, grado, jornada, estado de la matricula) y
--   ninguno de estos adjuntos esta en ese caso.
--
-- LA PARTE QUE SE OLVIDA: LAS CONFIGURACIONES YA CREADAS
--   TMATRICULA_VALOR guarda el (requerido, visible) de cada campo PARA CADA
--   establecimiento. Añadir filas solo a TMATRICULA_CAMPO dejaria a las
--   configuraciones existentes con 65 valores de 70: los cinco nuevos no
--   apareceria en la pantalla de configuracion de ningun establecimiento ya
--   dado de alta, solo en los que se crearan despues.
--
--   El paso 2 los siembra en todas las configuraciones actuales con su valor
--   por defecto. Es el mismo INSERT que fn_matricula_config_crear_interno ya
--   hace al crear una configuracion, cuyo comentario dice que sirve para
--   "rellenar configs viejas cuando aparecen campos nuevos en el catalogo";
--   aqui se ejecuta una vez para las que existen hoy.
--
--   Medido antes de escribir esto: 53 configuraciones en produccion y 103 en
--   el servidor de pruebas, todas con exactamente 65 valores, sin
--   establecimientos sin configurar ni valores huerfanos.
--
-- NUMERACION
--   Ocupa el hueco libre V229, POSTERIOR a V158 (que crea los campos) y a
--   V181 (que les asigna seccion). Un numero por debajo correria antes de
--   que la tabla este sembrada, y el UPDATE de seccion de V181 no
--   alcanzaria a estas filas.
--
-- IDEMPOTENTE
--   Los campos se insertan con NOT EXISTS por nombre (mismo criterio que
--   V158) y los valores con ON CONFLICT DO NOTHING sobre
--   (FK_TMATRICULA_CONFIG, FK_TMATRICULA_CAMPO). Reaplicarla no duplica nada.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Los cinco campos, con el nombre que ya tiene el catalogo de adjuntos.
-- ---------------------------------------------------------------------------
INSERT INTO academico_test.TMATRICULA_CAMPO
    (NOMBRE, SECCION, SECCION_ORDEN, EDITABLE, REQUERIDO_DEFECTO, VISIBLE_DEFECTO, CREATED_BY)
SELECT lv.NOMBRE, 'Archivo de soporte', 14, 'S', d.requerido, 'S', 'V229_seed'
  FROM (VALUES
        ('01', 'S'),   -- Documento de Identidad
        ('04', 'S'),   -- Certificado de Estudios del Año Anterior
        ('02', 'N'),   -- Certificado Medico
        ('05', 'N'),   -- Foto del Estudiante
        ('06', 'N')    -- Otros Documentos Relevantes
       ) AS d(codigo, requerido)
  JOIN academico_test.TLISTA_VALOR lv
    ON lv.CATEGORIA = 'ARCHIVO_MATRICULA'
   AND TRIM(lv.VALOR) = d.codigo
   AND lv.ACTIVE = TRUE
 WHERE lv.NOMBRE IS NOT NULL
   AND NOT EXISTS (
       SELECT 1 FROM academico_test.TMATRICULA_CAMPO c
        WHERE UPPER(TRIM(c.NOMBRE)) = UPPER(TRIM(lv.NOMBRE))
   );

-- ---------------------------------------------------------------------------
-- 2. Sembrarlos en las configuraciones que YA existen, con su valor por
--    defecto. Sin esto no apareceria en la pantalla de configuracion de
--    ningun establecimiento dado de alta antes de esta migracion.
-- ---------------------------------------------------------------------------
INSERT INTO academico_test.TMATRICULA_VALOR
    (REQUERIDO, VISIBLE, FK_TMATRICULA_CONFIG, FK_TMATRICULA_CAMPO, CREATED_BY)
SELECT c.REQUERIDO_DEFECTO, c.VISIBLE_DEFECTO, cfg.PK_MATRICULA_CONFIG, c.PK_MATRICULA_CAMPO, 'V229_seed'
  FROM academico_test.TMATRICULA_CAMPO c
 CROSS JOIN academico_test.TMATRICULA_CONFIG cfg
 WHERE c.SECCION = 'Archivo de soporte'
   AND c.ACTIVE  = TRUE
ON CONFLICT (FK_TMATRICULA_CONFIG, FK_TMATRICULA_CAMPO) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. Comprobacion: cada configuracion debe tener un valor por cada campo
--    activo. Si no cuadra, algo quedo a medias y conviene verlo ahora.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_campos    BIGINT;
    v_configs   BIGINT;
    v_nuevos    BIGINT;
    v_desparejo BIGINT;
BEGIN
    SELECT count(*) INTO v_campos  FROM academico_test.TMATRICULA_CAMPO WHERE ACTIVE = TRUE;
    SELECT count(*) INTO v_configs FROM academico_test.TMATRICULA_CONFIG;
    SELECT count(*) INTO v_nuevos  FROM academico_test.TMATRICULA_CAMPO WHERE SECCION = 'Archivo de soporte';

    SELECT count(*) INTO v_desparejo
      FROM (
            SELECT cfg.PK_MATRICULA_CONFIG
              FROM academico_test.TMATRICULA_CONFIG cfg
              LEFT JOIN academico_test.TMATRICULA_VALOR v
                     ON v.FK_TMATRICULA_CONFIG = cfg.PK_MATRICULA_CONFIG
             GROUP BY cfg.PK_MATRICULA_CONFIG
            HAVING count(v.PK_MATRICULA_VALOR) <> v_campos
           ) d;

    RAISE NOTICE 'V229: campos de "Archivo de soporte"=% | campos activos=% | configuraciones=%',
        v_nuevos, v_campos, v_configs;

    IF v_nuevos <> 5 THEN
        RAISE WARNING 'V229: se esperaban 5 campos en "Archivo de soporte" y hay %. Revisa TLISTA_VALOR CATEGORIA=ARCHIVO_MATRICULA: los codigos 01, 02, 04, 05 y 06 deben existir y estar activos.', v_nuevos;
    END IF;

    IF v_desparejo > 0 THEN
        RAISE WARNING 'V229: % configuracion(es) no tienen un valor por cada campo activo.', v_desparejo;
    END IF;
END $$;
