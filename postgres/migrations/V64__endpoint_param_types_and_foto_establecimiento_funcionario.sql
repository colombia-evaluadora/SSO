-- V64 — dos cosas relacionadas: (1) le da a la tabla `endpoint` la
-- misma capacidad de tipado por-campo que `query` ya tenía
-- (`param_types` jsonb), y (2) usa esa capacidad + la ya existente en
-- `query` para que crear/editar un establecimiento y registrar un
-- funcionario/usuario acepten su foto/escudo con el formato
-- retrocompatible de TARCHIVO (ver docs/subida-archivos-a-queries.md).
--
-- Por qué `endpoint` necesitaba esto: `/register/usuario` y
-- `/register/funcionario` (auth-center) son controllers REST
-- estáticos, no filas de `query` — están en el catálogo `endpoint`,
-- que nunca tuvo columna de metadatos por campo.
-- FileDestinationAccessService trataba TODO destino `endpoint` como
-- permisivo a propósito (ver su javadoc), así que un campo de archivo
-- ahí nunca podía declarar `FILE:clasificacion` — quedaba con el
-- formato de clave genérico `<pk>/<nombre>` sin importar qué campo
-- fuera. Con `param_types` en `endpoint`, el mismo mecanismo
-- `FILE:clasificacion[:campo]` que ya usa `query` aplica también acá
-- (misma convención de claves canónicas `BODY.X` — ver
-- FileDestinationAccessService#destinoDe, reutilizado tal cual para
-- las dos tablas).

ALTER TABLE public.endpoint ADD COLUMN param_types jsonb NOT NULL DEFAULT '{}'::jsonb;

-- `RegisterUsuarioRequest.fkTarchivoFoto` (ambos endpoints comparten
-- el mismo DTO) ya llega como el pk_tarchivo de un archivo YA subido
-- — file-service lo sustituye antes de reenviar. Clasificación
-- `perfilUsuario`: la foto de la CUENTA (tusuario.fk_tarchivo, ver
-- fn_fun_actualizar/p_fk_tarchivo_foto), no ligada a un
-- establecimiento — mismo layout que ya usan las filas históricas
-- migradas (ACADEMICO_VALLEDUPAR/perfilUsuario/<pk>.<ext>).
UPDATE public.endpoint
   SET param_types = param_types || '{"BODY.FKTARCHIVOFOTO": "FILE:perfilUsuario"}'::jsonb
 WHERE method = 'POST'
   AND path IN ('/register/usuario', '/register/funcionario');

-- `fn_est_crear` / `fn_est_actualizar` YA tienen `p_fk_archivo bigint
-- DEFAULT NULL` (inserta/actualiza TESTABLECIMIENTO.FK_TARCHIVO,
-- valida que exista en TARCHIVO) — el hueco estaba sólo en la fila
-- `query`, que nunca lo pasaba en la llamada ni lo declaraba en
-- param_types.
--
-- Clasificación `escudo`, SIN el tercer componente (código de
-- establecimiento) en NINGUNA de las dos — ni crear ni editar:
--   - Crear: el código todavía no existe en TESTABLECIMIENTO en el
--     momento de la subida (se está creando en la MISMA operación),
--     así que codigoEstablecimientoValido() fallaría siempre.
--   - Editar: PATCH es parcial — el cliente no necesariamente
--     reenvía BODY.BASICINFO.DANE si sólo está cambiando el escudo,
--     así que no hay garantía de tener el código a mano; y derivarlo
--     del usuario autenticado (V66) resolvería SU PROPIO
--     establecimiento, no necesariamente el que :PARAM.ID identifica.
-- La clave nueva queda ACADEMICO_VALLEDUPAR/escudo/<pk_tarchivo>.<ext>
-- — sin el segmento de establecimiento que sí llevan las filas
-- históricas, pero clasificada (a diferencia del formato genérico) y
-- consistente entre alta y edición.
UPDATE public.query
   SET query = 'SELECT academico_test.fn_est_crear(
    p_pk_usuario_solicitante => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_nombre => CAST(:BODY.BASICINFO.NAME AS VARCHAR),
    p_nit => CAST(:BODY.BASICINFO.NIT AS VARCHAR),
    p_fk_municipio => CAST(:BODY.ADDRESS.MUNICIPALITY AS BIGINT),
    p_fk_propiedad_juridica => CAST(:BODY.BASICINFO.OWNERSHIPTYPE AS BIGINT),
    p_codigo => CAST(:BODY.BASICINFO.DANE AS VARCHAR),
    p_localidad => CAST(:BODY.ADDRESS.LOCALITY AS VARCHAR),
    p_comuna => CAST(:BODY.ADDRESS.COMMUNE AS VARCHAR),
    p_barrio => CAST(:BODY.ADDRESS.DISTRICT AS VARCHAR),
    p_direccion => CAST(:BODY.ADDRESS.ADDRESS AS VARCHAR),
    p_correo_electronico => CAST(:BODY.CONTACT.EMAIL AS VARCHAR),
    p_telefono => CAST(:BODY.CONTACT.PHONE AS VARCHAR),
    p_fax => CAST(:BODY.CONTACT.FAX AS VARCHAR),
    p_pagina_web => CAST(:BODY.CONTACT.WEBSITE AS VARCHAR),
    p_fk_lista_valor_zona => CAST(:BODY.ADDRESS.ZONE AS BIGINT),
    p_resolucion_aprobacion => CAST(:BODY.ADDITIONALINFO.APPROVALRESOLUTION AS VARCHAR),
    p_licencia_funcionamiento => CAST(:BODY.ADDITIONALINFO.LICENSESTATUS AS VARCHAR),
    p_fecha_licencia => CAST(:BODY.ADDITIONALINFO.LICENSEDATE AS DATE),
    p_fk_lv_calendario => CAST(:BODY.ADDITIONALINFO.CALENDAR AS BIGINT),
    p_fk_lv_idioma => CAST(:BODY.ADDITIONALINFO.TEACHINGLANGUAGE AS BIGINT),
    p_fk_lv_genero_est => CAST(:BODY.ADDITIONALINFO.POPULATIONGENDER AS BIGINT),
    p_fk_discapacidad => CAST(:BODY.ADDITIONALINFO.DISABILITYTYPE AS BIGINT),
    p_talento => CAST(CASE WHEN CAST(:BODY.ADDITIONALINFO.GIFTEDATTENTION AS BOOLEAN) THEN ''S'' ELSE ''N'' END AS academico_test.bool_sn),
    p_etnias => CAST(CASE WHEN CAST(:BODY.ADDITIONALINFO.ETHNICATTENTION AS BOOLEAN) THEN ''S'' ELSE ''N'' END AS academico_test.bool_sn),
    p_fk_tfuncionario_rector => CAST(:BODY.PRINCIPAL AS BIGINT),
    p_fk_tfuncionario_secretaria => CAST(:BODY.SECRETARY AS BIGINT),
    p_subsidio => CAST(CASE WHEN CAST(:BODY.ADDITIONALINFO.SUBSIDY AS BOOLEAN) THEN ''S'' ELSE ''N'' END AS academico_test.bool_sn),
    p_fk_lv_regimen_catcosto => CAST(:BODY.ADDITIONALINFO.COSTREGIME AS BIGINT),
    p_fk_lv_rango_tarifa => CAST(:BODY.ADDITIONALINFO.TUITIONRANGE AS BIGINT),
    p_fk_archivo => CAST(:BODY.LOGO AS BIGINT)
) AS pk_establecimiento_creado',
       param_types = param_types || '{"BODY.LOGO": "FILE:escudo"}'::jsonb
 WHERE uuid = 'q-msnu438k-mbe0cg26';

UPDATE public.query
   SET query = 'SELECT academico_test.fn_est_actualizar(
    p_pk_establecimiento => CAST(:PARAM.ID AS BIGINT),
    p_nombre => CAST(:BODY.BASICINFO.NAME AS VARCHAR),
    p_nit => CAST(:BODY.BASICINFO.NIT AS VARCHAR),
    p_fk_municipio => CAST(:BODY.ADDRESS.MUNICIPALITY AS BIGINT),
    p_fk_propiedad_juridica => CAST(:BODY.BASICINFO.OWNERSHIPTYPE AS BIGINT),
    p_codigo => CAST(:BODY.BASICINFO.DANE AS VARCHAR),
    p_localidad => CAST(:BODY.ADDRESS.LOCALITY AS VARCHAR),
    p_comuna => CAST(:BODY.ADDRESS.COMMUNE AS VARCHAR),
    p_barrio => CAST(:BODY.ADDRESS.DISTRICT AS VARCHAR),
    p_direccion => CAST(:BODY.ADDRESS.ADDRESS AS VARCHAR),
    p_correo_electronico => CAST(:BODY.CONTACT.EMAIL AS VARCHAR),
    p_telefono => CAST(:BODY.CONTACT.PHONE AS VARCHAR),
    p_fax => CAST(:BODY.CONTACT.FAX AS VARCHAR),
    p_pagina_web => CAST(:BODY.CONTACT.WEBSITE AS VARCHAR),
    p_fk_lista_valor_zona => CAST(:BODY.ADDRESS.ZONE AS BIGINT),
    p_resolucion_aprobacion => CAST(:BODY.ADDITIONALINFO.APPROVALRESOLUTION AS VARCHAR),
    p_licencia_funcionamiento => CAST(:BODY.ADDITIONALINFO.LICENSESTATUS AS VARCHAR),
    p_fecha_licencia => CAST(:BODY.ADDITIONALINFO.LICENSEDATE AS DATE),
    p_fk_lv_calendario => CAST(:BODY.ADDITIONALINFO.CALENDAR AS BIGINT),
    p_fk_lv_idioma => CAST(:BODY.ADDITIONALINFO.TEACHINGLANGUAGE AS BIGINT),
    p_fk_lv_genero_est => CAST(:BODY.ADDITIONALINFO.POPULATIONGENDER AS BIGINT),
    p_fk_discapacidad => CAST(:BODY.ADDITIONALINFO.DISABILITYTYPE AS BIGINT),
    p_talento => CAST(CASE WHEN CAST(:BODY.ADDITIONALINFO.GIFTEDATTENTION AS BOOLEAN) THEN ''S'' ELSE ''N'' END AS academico_test.bool_sn),
    p_etnias => CAST(CASE WHEN CAST(:BODY.ADDITIONALINFO.ETHNICATTENTION AS BOOLEAN) THEN ''S'' ELSE ''N'' END AS academico_test.bool_sn),
    p_fk_tfuncionario_rector => CAST(:BODY.PRINCIPAL AS BIGINT),
    p_fk_tfuncionario_secretaria => CAST(:BODY.SECRETARY AS BIGINT),
    p_subsidio => CAST(CASE WHEN CAST(:BODY.ADDITIONALINFO.SUBSIDY AS BOOLEAN) THEN ''S'' ELSE ''N'' END AS academico_test.bool_sn),
    p_fk_lv_regimen_catcosto => CAST(:BODY.ADDITIONALINFO.COSTREGIME AS BIGINT),
    p_fk_lv_rango_tarifa => CAST(:BODY.ADDITIONALINFO.TUITIONRANGE AS BIGINT),
    p_fk_archivo => CAST(:BODY.LOGO AS BIGINT),
    p_pk_usuario_solicitante => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
) AS pk_establecimiento_actualizado',
       param_types = param_types || '{"BODY.LOGO": "FILE:escudo"}'::jsonb
 WHERE uuid = 'q-msq4nazf-j5jti48l';
