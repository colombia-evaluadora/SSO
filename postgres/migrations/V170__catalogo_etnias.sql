-- =============================================================================
-- V170 -- Catalogo para el select "Etnia / Resguardo" del formulario de
-- matricula, y su endpoint.
--
-- QUE DEVUELVE Y POR QUE ESTA ARMADO ASI
-- ---------------------------------------------------------------------------
-- Una fila por RESGUARDO activo (11), cada una con su etnia resuelta. El PK
-- que se devuelve para ligar es PK_RESGUARDO, porque es lo que se persiste:
-- el campo del formulario se guarda en TESTUDIANTE.FK_TRESGUARDO, que apunta
-- a TRESGUARDO. TETNIA no se referencia desde el estudiante -- es
-- TRESGUARDO.FK_TETNIA quien apunta a ella.
--
-- Se recorre TRESGUARDO y no TETNIA aunque el campo se llame "Etnia /
-- Resguardo", porque en la direccion contraria el catalogo no sirve:
--   * 93 de las 99 etnias activas NO tienen ningun resguardo -> esas filas
--     no tendrian PK que ligar.
--   * 2 etnias tienen VARIOS (YUKO tiene 5, ARHUACO tiene 2) -> no existe
--     "el" resguardo de esa etnia.
--   * solo 4 etnias tienen exactamente uno.
-- Recorriendo resguardos, en cambio, cada fila tiene siempre su PK y una sola
-- etnia. Se muestran los dos nombres igual, que es lo que se pedia.
--
-- La columna `etiqueta` viene armada ("ARHUACO - BUSINCHAMA") para que el
-- select no tenga que concatenar; los nombres sueltos van igual por si se
-- quieren mostrar en columnas separadas.
--
-- Los NOMBRE de TETNIA y TRESGUARDO vienen de la migracion con espacios
-- sobrantes (' ARHUACO ', 'CAMPOALEGRE '); se devuelven con TRIM.
--
-- Sin gate: es un catalogo de referencia, igual que fn_cat_municipios_listar
-- (V58) o fn_cat_roles_listar (V121). Solo lectura, STABLE, sin datos
-- sensibles ni dependientes del solicitante. La query queda igual detras del
-- JWT del gateway y de su fila en role_query.
-- =============================================================================

-- La version anterior de esta migracion devolvia las 99 ETNIAS con el PK de
-- la etnia -- inservible para ligar (ver arriba). Cambia el nombre y la lista
-- de columnas, asi que hace falta el DROP explicito.
DROP FUNCTION IF EXISTS academico_test.fn_cat_etnias_listar();

CREATE OR REPLACE FUNCTION academico_test.fn_cat_etnia_resguardo_listar()
RETURNS TABLE (
    pk_resguardo      BIGINT,
    codigo_resguardo  VARCHAR,
    nombre_resguardo  VARCHAR,
    pk_etnia          BIGINT,
    nombre_etnia      VARCHAR,
    grupo_etnico      VARCHAR,
    etiqueta          VARCHAR
)
LANGUAGE sql
STABLE
AS $$
    SELECT r.PK_RESGUARDO,
           r.CODIGO,
           TRIM(r.NOMBRE)::VARCHAR,
           e.PK_ETNIA,
           TRIM(e.NOMBRE)::VARCHAR,
           TRIM(ge.NOMBRE)::VARCHAR,
           (TRIM(COALESCE(e.NOMBRE, '')) ||
            CASE WHEN e.NOMBRE IS NOT NULL THEN ' - ' ELSE '' END ||
            TRIM(r.NOMBRE))::VARCHAR
      FROM academico_test.TRESGUARDO r
 LEFT JOIN academico_test.TETNIA e
        ON e.PK_ETNIA = r.FK_TETNIA AND e.ACTIVE = TRUE
 LEFT JOIN academico_test.TLISTA_VALOR ge
        ON ge.PK_LISTA_VALOR = e.FK_TLV_GRUPO_ETNICO
     WHERE r.ACTIVE = TRUE
     ORDER BY TRIM(COALESCE(e.NOMBRE, '')) ASC, TRIM(r.NOMBRE) ASC;
$$;

COMMENT ON FUNCTION academico_test.fn_cat_etnia_resguardo_listar()
    IS 'Catalogo del select "Etnia / Resguardo" del formulario de matricula: una fila por TRESGUARDO activo (11) con su TETNIA resuelta. El PK que se devuelve es PK_RESGUARDO porque es lo que se persiste en TESTUDIANTE.FK_TRESGUARDO -- TETNIA no se referencia desde el estudiante. Se recorre TRESGUARDO y no TETNIA porque 93 de las 99 etnias no tienen resguardo (no tendrian PK que ligar) y 2 tienen varios (YUKO 5, ARHUACO 2). Trae `etiqueta` ya armada ("ARHUACO - BUSINCHAMA") y los nombres sueltos. NOMBRE con TRIM: las filas migradas traen espacios sobrantes. Sin gate -- catalogo de referencia, solo lectura.';

-- ---------------------------------------------------------------------------
-- Endpoint: GET /catalogos/etnias
--
-- Se mantiene la ruta aunque la funcion cambio de nombre: es la que consume
-- el select "Etnia / Resguardo", y renombrarla obligaria a tocar el front sin
-- ganar nada. Se cuelga de /catalogos/... como fn_cat_roles_listar
-- (/catalogos/roles), no de /select/{CATEGORIA}, que es exclusivo de las
-- categorias de TLISTA_VALOR -- TRESGUARDO y TETNIA son tablas propias.
--
-- Sin parametros: son 11 filas, no amerita paginar ni filtrar.
--
-- Sin fila en role_query responde 403 -- los permisos por rol se configuran
-- aparte, en la plataforma.
-- ---------------------------------------------------------------------------
INSERT INTO public.query (
    uuid, query, type, public_end, captcha, microservice_id,
    path_template, execution_mode, http_method, param_types, detail
)
SELECT
    'q-mtb2d9k4-catetnia1',
    'SELECT * FROM academico_test.fn_cat_etnia_resguardo_listar();',
    'postgres', false, false,
    m.id_microservice,
    '/catalogos/etnias', 'SELECT', 'GET',
    '{}'::jsonb,
    'V170 -- catalogo del select "Etnia / Resguardo" del formulario de matricula: resguardos activos con su etnia; el PK que se liga es PK_RESGUARDO'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query,
       param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template,
       http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode,
       microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;
