-- =============================================================================
-- V37 — la query de listado de eval-col expone una URL de archivo que el
-- navegador no puede usar. Le añade la que sí sirve.
--
-- `eval-col-funcionario-listar-001` devuelve `a.urls3 AS archivo_url`, o sea
-- la URL cruda del bucket:
--
--   http://172.233.184.248:3900/eval-col/489907/t.png
--
-- Eso no es consumible desde el front. El bucket no es público, y aunque lo
-- fuera se saltaría el gateway: cualquiera con la URL descargaría el fichero
-- sin sesión y sin quedar registrado. Es exactamente el motivo por el que la
-- descarga pasó a ser GET /api/files/download/{id} — ver V36 y
-- DownloadController.
--
-- V36 arregló esto en la query POR ID (`-archivo-firmado-001`) pero dejó
-- fuera la de listado, que tiene el mismo defecto. Se detectó probando el
-- flujo completo contra el servidor: la respuesta del listado traía una URL
-- de Garage que ningún cliente puede abrir.
--
-- Se AÑADE `archivo_descarga_url` en vez de reemplazar `archivo_url`:
--
--   · `archivo_url` sigue siendo útil para operar y auditar (dice en qué
--     objeto del bucket están los bytes), y quitarla rompería a cualquiera
--     que ya la lea.
--   · `archivo_descarga_url` es la que el front pone en un fetch.
--
-- El nombre difiere del `archivo_firmado_url` de la query por id, que se
-- quedó de cuando esto devolvía URLs prefirmadas. Ese nombre ya no describe
-- nada — no hay firma en juego — pero renombrarlo ahora rompería a quien lo
-- consuma, así que se deja y el nombre nuevo es el correcto. Cuando se
-- unifiquen, el bueno es `archivo_descarga_url`.
--
-- El LEFT JOIN se conserva: hay funcionarios sin archivo, y con un JOIN
-- normal desaparecerían del listado. Para esas filas `archivo_id` es NULL y
-- la URL también lo será, que es lo que el front espera para no pintar nada.
-- =============================================================================

UPDATE query
   SET query = 'SELECT f.pk_tfuncionario AS id, f.telefonos, f.created_by, f.created_at, '
            || 'a.pk_tarchivo AS archivo_id, a.nombre AS archivo_nombre, '
            || 'a.peso AS archivo_peso, a.urls3 AS archivo_url, '
            || 'CASE WHEN a.pk_tarchivo IS NULL THEN NULL '
            || 'ELSE ''/api/files/download/'' || a.pk_tarchivo END AS archivo_descarga_url, '
            || '''/api/eval-col/funcionario/'' || f.pk_tfuncionario AS url '
            || 'FROM academico_test.tfuncionario f '
            || 'LEFT JOIN academico_test.tarchivo a ON a.pk_tarchivo = f.fk_tarchivo '
            || 'WHERE f.active = TRUE ORDER BY f.pk_tfuncionario DESC',
       detail = 'Listar funcionarios activos con su archivo y la ruta de descarga (via api-gateway)'
 WHERE uuid = 'eval-col-funcionario-listar-001';
