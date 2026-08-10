-- =============================================================================
-- V36 — baja a migración las dos queries del catálogo eval-col que tocan
-- archivos, y las corrige.
--
-- Las tres queries `eval-col-funcionario-*` se crearon a mano contra la BD
-- del servidor de pruebas mientras se montaba el flujo de binarios. Nunca
-- estuvieron en una migración, así que un rebuild del entorno las perdía.
-- Ésta las fija. (La tercera, `-listar-001`, no toca archivos y se deja
-- como está.)
--
-- Además de fijarlas, corrige dos cosas que estaban mal:
--
--   1. `-archivo-firmado-001` emitía '/api/files/sign/' || pk. Ese
--      endpoint ya no existe: se sustituyó por
--      GET /api/files/download/{id}, que streamea los bytes a través
--      del gateway en vez de entregar al navegador una URL prefirmada
--      contra el bucket. Quedó apuntando a una ruta muerta.
--      Su `detail` decía "URL prefirmada (TTL 15 min)", que describe un
--      mecanismo que ya no se usa — también se actualiza, porque un
--      comentario que miente es peor que no tenerlo.
--
--   2. `-crear-001` no guardaba el archivo. file-service sube el binario,
--      lo registra en TARCHIVO y sustituye el campo del multipart por su
--      id (`firma=<binario>` → `firma: 489905`), pero el INSERT ignoraba
--      ese `:BODY.FIRMA` y nunca ponía `fk_tarchivo`. El fichero se subía
--      y quedaba sin dueño: el funcionario se creaba sin firma y el
--      archivo huérfano en el bucket.
--
-- IDEMPOTENTE por partida doble: `ON CONFLICT (uuid) DO UPDATE` corrige
-- las filas ya existentes en los entornos donde se crearon a mano, y las
-- crea donde no existan.
--
-- OJO — el `INSERT ... SELECT` sólo mete filas si el microservicio
-- `eval-col` existe. No es un descuido: `eval-col` es una fila kind=QUERY
-- que crea el PROVISIONER en tiempo de ejecución (levanta su contenedor y
-- registra la fila), no una migración. En una BD recién creada todavía no
-- existe, y esta migración no puede inventarlo sin usurpar ese ciclo de
-- vida: dejaría una fila apuntando a una instancia que nadie arrancó.
-- Así que en un entorno virgen esto no inserta nada, y al aprovisionar
-- eval-col hay que volver a crear estas queries (o re-ejecutar este SQL).
-- =============================================================================

INSERT INTO query (uuid, query, type, public_end, captcha, detail,
                   microservice_id, path_template, execution_mode, http_method)
SELECT
    'eval-col-funcionario-crear-001',
    'INSERT INTO academico_test.tfuncionario (fk_tmunicipio_expedicion, telefonos, fk_tarchivo, created_by) '
        || 'VALUES (CAST(:BODY.MUNICIPIO AS BIGINT), CAST(:BODY.TELEFONOS AS VARCHAR), '
        || 'CAST(:BODY.FIRMA AS BIGINT), :CONTEXT.EMAIL) RETURNING pk_tfuncionario AS id',
    'postgres', false, false,
    'Catalogo eval-col: crear funcionario con su firma (INSERT tfuncionario, devuelve el id nuevo)',
    m.id_microservice, '/funcionario/crear', 'DML', 'POST'
FROM microservice m
WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
    SET query   = EXCLUDED.query,
        detail  = EXCLUDED.detail;

INSERT INTO query (uuid, query, type, public_end, captcha, detail,
                   microservice_id, path_template, execution_mode, http_method)
SELECT
    'eval-col-funcionario-archivo-firmado-001',
    'SELECT f.pk_tfuncionario AS id, f.telefonos, a.pk_tarchivo AS archivo_id, '
        || 'a.nombre AS archivo_nombre, a.urls3 AS archivo_url, '
        || '''/api/files/download/'' || a.pk_tarchivo AS archivo_firmado_url '
        || 'FROM academico_test.tfuncionario f '
        || 'JOIN academico_test.tarchivo a ON a.pk_tarchivo = f.fk_tarchivo '
        || 'WHERE f.active = TRUE AND f.pk_tfuncionario = CAST(:PARAM.ID AS BIGINT)',
    'postgres', false, false,
    'Catalogo eval-col: funcionario por id con la ruta de descarga de su archivo (via api-gateway)',
    m.id_microservice, '/funcionario/:ID/archivo-firmado', 'SELECT', 'GET'
FROM microservice m
WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
    SET query   = EXCLUDED.query,
        detail  = EXCLUDED.detail;

-- Red de seguridad: si en algún entorno quedó otra query apuntando al
-- endpoint muerto, se corrige aquí. Es un reemplazo de texto plano, y
-- vale para cualquier catálogo — no sólo eval-col.
UPDATE query
   SET query = REPLACE(query, '/api/files/sign/', '/api/files/download/')
 WHERE query LIKE '%/api/files/sign/%';
