-- ============================================================================
-- V381 — "Por tablas" (catalogo y detalle) tampoco veia operaciones cuyo
-- audit_log.tabla llega sin el prefijo de esquema (mismo bug de fondo
-- que V380, ver su cabecera para la causa raiz real en cdc-worker).
--
-- A diferencia de V380 (que solo tenia que aflojar el filtro de tabla,
-- porque ya estaba acotado por sesion_id): estas dos consultas NO tienen
-- ningun scope de sesion, y PIGSE/CEVAL comparten nombres de tabla
-- identicos (tsede, tusuario, tfuncionario, tdocumento_institucional,
-- etc. -- PIGSE se modelo sobre CEVAL). Aflojar el match de `tabla` a
-- "con o sin prefijo" a ciegas ahi habria vuelto a abrir el mismo hueco
-- de cruce CEVAL/PIGSE que V377 cerro para las sesiones.
--
-- Fix real: en vez de confiar en el prefijo de esquema de `tabla` para
-- saber a que app pertenece una operacion, se usa la MISMA fuente de
-- verdad de V377 -- el `sesion_id` de la fila de audit_log, resuelto
-- contra `auditoria.tsesion_web.app_name` (el mirror de sesiones, ya
-- trae la app real desde el login). Una operacion sin sesion_id
-- reconocible (datos historicos de sesiones ya recolectadas por el GC
-- de 40 dias, o cambios sin contexto HTTP) queda invisible en vez de
-- arriesgar mostrarse en la app equivocada -- mismo criterio que V380.
--
-- El match de tabla en si tambien se afloja (con prefijo O sin el) dado
-- que ahora el scoping de app ya no depende de ese prefijo.
-- ============================================================================

UPDATE public.query q
   SET query = $Q$
WITH raw AS (
    SELECT arrayJoin([
        ('pigse.tdocumento_institucional', 'Documentos Institucionales', 'FileTextIcon'),
        ('pigse.tdocumento_institucional_hist', 'Historial de Documentos Institucionales', 'ClockCountdownIcon'),
        ('pigse.tente', 'Entes Territoriales', 'BankIcon'),
        ('pigse.tente_establecimiento', 'Entes - Establecimientos', 'BuildingsIcon'),
        ('pigse.tente_usuario', 'Usuarios de Ente Territorial', 'UsersIcon'),
        ('pigse.testablecimiento', 'Establecimientos Educativos', 'BuildingsIcon'),
        ('pigse.testablecimiento_usuario', 'Usuarios de Establecimiento', 'UsersIcon'),
        ('pigse.tfuncionario', 'Funcionarios', 'IdentificationCardIcon'),
        ('pigse.tusuario', 'Usuarios', 'UserIcon'),
        ('pigse.tsede', 'Sedes Educativas', 'HouseLineIcon'),
        ('pigse.tsede_usuario', 'Usuarios de Sede', 'UsersIcon')
    ]) AS fila
),
catalogo AS (
    SELECT
        tupleElement(fila, 1) AS tabla_real,
        substring(tupleElement(fila, 1), length('pigse.') + 1) AS tabla_bare,
        concat('t', arrayStringConcat(arrayMap(w -> concat(upper(substring(w,1,1)), lower(substring(w,2))), splitByChar('_', substring(tupleElement(fila, 1), length('pigse.') + 2))), '')) AS slug,
        tupleElement(fila, 2) AS name,
        tupleElement(fila, 3) AS icon
    FROM raw
)
SELECT
    c.slug,
    c.name,
    c.icon,
    countIf(
        (a.tabla = c.tabla_real OR a.tabla = c.tabla_bare)
        AND toDate(a.ts) = today() AND a.operacion != 'r'
        AND a.sesion_id IN (SELECT family_id FROM auditoria.tsesion_web WHERE app_name = 'PIGSE')
    ) AS operationsToday,
    count() OVER() AS totalCount
FROM catalogo c
LEFT JOIN auditoria.audit_log a ON (a.tabla = c.tabla_real OR a.tabla = c.tabla_bare)
WHERE coalesce(:BODY.FILTERS.NAME, '') = '' OR positionCaseInsensitive(c.name, :BODY.FILTERS.NAME) > 0
GROUP BY c.slug, c.name, c.icon
ORDER BY c.name
LIMIT :BODY.PAGESIZE OFFSET :BODY.PAGEOFFSET;
$Q$
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid = 'audit-clickhouse-pigse'
   AND q.path_template = '/audit-tables/query';

UPDATE public.query q
   SET query = $Q$
WITH raw AS (
    SELECT arrayJoin([
        'academico_test.tacta_grado','academico_test.tacta_grado_detalle','academico_test.tactividad',
        'academico_test.tactividad_adaptacion','academico_test.tactividad_adaptacion_estudiante',
        'academico_test.tactividad_cotejo_evaluacion','academico_test.tactividad_cotejo_item',
        'academico_test.tactividad_criterio_unidad','academico_test.tactividad_escala',
        'academico_test.tactividad_escala_evaluacion','academico_test.tactividad_escala_nivel',
        'academico_test.tactividad_estudiante','academico_test.tactividad_evidencia',
        'academico_test.tactividad_extracurricular','academico_test.tactividad_material',
        'academico_test.tactividad_nota','academico_test.tactividad_otro',
        'academico_test.tactividad_recuperacion','academico_test.tactividad_rubrica_criterio',
        'academico_test.tactividad_rubrica_evaluacion','academico_test.tactividad_rubrica_nivel',
        'academico_test.tactividad_soporte','academico_test.tano_lectivo','academico_test.taplico_encuesta',
        'academico_test.tarchivo','academico_test.tarea','academico_test.tarea_asignatura',
        'academico_test.tarea_definitiva','academico_test.tarea_gestion','academico_test.tarea_gestion_porcentaje',
        'academico_test.tarea_nota','academico_test.tasignatura','academico_test.tasignatura_definitiva',
        'academico_test.tasignatura_nota','academico_test.tasignatura_plan','academico_test.tasistencia',
        'academico_test.tcalendario','academico_test.tcalendario_detalle','academico_test.tcompetencia_gestion',
        'academico_test.tcomportamiento','academico_test.tcomportamiento_calificado',
        'academico_test.tconfiguracion_membrete','academico_test.tconfiguracion_reporte',
        'academico_test.tcriterio_evaluacion','academico_test.tcriterio_evaluacion_asignatura_plan',
        'academico_test.tcriterio_promocion','academico_test.tcriterio_promocion_asignatura_obligatoria',
        'academico_test.tcriterio_promocion_grado','academico_test.tcriterio_unidad',
        'academico_test.tdenominacion','academico_test.tdepartamento','academico_test.tdescansos',
        'academico_test.tdiploma','academico_test.tdiploma_detalle','academico_test.tdiscapacidad',
        'academico_test.tdocente_asignatura','academico_test.tdocumento_institucional',
        'academico_test.tdocumento_institucional_hist','academico_test.tencuesta','academico_test.tenfasis',
        'academico_test.tente','academico_test.tente_establecimiento','academico_test.tente_usuario',
        'academico_test.tescala','academico_test.tescala_valoracion','academico_test.tespecialidad',
        'academico_test.testablecimiento','academico_test.testrategia_actual','academico_test.testrategia_futura',
        'academico_test.testudiante','academico_test.tetnia','academico_test.teval_docente_detalle',
        'academico_test.teval_docente_mejora','academico_test.tevaluacion_docente','academico_test.tfuncionario',
        'academico_test.tfuncionario_archivo','academico_test.tgrado','academico_test.tgrupo',
        'academico_test.thorario','academico_test.tinf_informatica','academico_test.tinf_infraestructura',
        'academico_test.tinf_perifericos_medios','academico_test.tinscripcion','academico_test.tlista_valor',
        'academico_test.tlog_carnet','academico_test.tlogro_reconocimiento','academico_test.tmatricula',
        'academico_test.tmatricula_archivo','academico_test.tmatricula_asignatura','academico_test.tmatricula_campo',
        'academico_test.tmatricula_config','academico_test.tmatricula_promocion',
        'academico_test.tmatricula_socioeconomico','academico_test.tmatricula_valor',
        'academico_test.tmensaje_enviado','academico_test.tmensaje_enviado_archivo',
        'academico_test.tmensaje_promocion','academico_test.tmensaje_recibido',
        'academico_test.tmensaje_recibido_archivo','academico_test.tmensaje_usuarios','academico_test.tmenu',
        'academico_test.tmunicipio','academico_test.tnivel_criterio_unidad','academico_test.tnivel_ensenanza',
        'academico_test.tnivel_escala','academico_test.tnoticia_enviada','academico_test.tnoticia_enviada_archivo',
        'academico_test.tnoticia_recibida','academico_test.tnoticia_recibida_archivo',
        'academico_test.tnoticia_usuarios','academico_test.tnucleo_familiar',
        'academico_test.tobs_servicio_vivienda','academico_test.tobservador',
        'academico_test.tobservador_anotacion','academico_test.tobservador_anotacion_evidencia',
        'academico_test.tobservador_historico','academico_test.tobservador_recomendacion',
        'academico_test.tpadre','academico_test.tperiodo_academico','academico_test.tperiodo_academico_config',
        'academico_test.tperiodo_evaluacion','academico_test.tperiodo_permiso','academico_test.tplan',
        'academico_test.tpregunta','academico_test.tprematricula','academico_test.tpropiedad_juridica',
        'academico_test.trecomendaciones_calificacion','academico_test.trecurso_compartido',
        'academico_test.treferente_curricular','academico_test.treferente_curricular_area',
        'academico_test.treferente_curricular_nivel','academico_test.treferente_enunciado',
        'academico_test.treserva_cupo','academico_test.tresguardo','academico_test.trespuesta',
        'academico_test.tresultado_encuesta','academico_test.tretiro_accion','academico_test.tretiro_matricula',
        'academico_test.trol','academico_test.trol_menu','academico_test.trubrica_unidad','academico_test.tsede',
        'academico_test.tsede_convenio','academico_test.tsede_convenio_matricula','academico_test.tsede_nivel',
        'academico_test.tsede_usuario','academico_test.tsesion','academico_test.ttraslado_estudiante',
        'academico_test.ttraslado_matricula','academico_test.tunidad','academico_test.tunidad_contenido',
        'academico_test.tunidad_enunciado','academico_test.tunidad_nota','academico_test.tunidad_objetivo',
        'academico_test.tuso_dispositivo_estudiante','academico_test.tuso_equipo_computo','academico_test.tusuario',
        'academico_test.tusuario_rol_permiso','academico_test.tvaloracion','academico_test.tvideo_clase',
        'academico_test.tvideo_usuarios'
    ]) AS tabla_real
),
catalogo AS (
    SELECT
        tabla_real,
        substring(tabla_real, length('academico_test.') + 1) AS tabla_bare,
        substring(tabla_real, length('academico_test.') + 2) AS sin_prefijo,
        concat('t', arrayStringConcat(arrayMap(w -> concat(upper(substring(w,1,1)), lower(substring(w,2))), splitByChar('_', substring(tabla_real, length('academico_test.') + 2))), '')) AS slug,
        arrayStringConcat(arrayMap(w -> concat(upper(substring(w,1,1)), lower(substring(w,2))), splitByChar('_', substring(tabla_real, length('academico_test.') + 2))), ' ') AS name
    FROM raw
),
con_icono AS (
    SELECT
        tabla_real, tabla_bare, slug, name,
        multiIf(
            positionCaseInsensitive(sin_prefijo, 'usuario') > 0, 'UsersIcon',
            positionCaseInsensitive(sin_prefijo, 'documento') > 0, 'FileTextIcon',
            positionCaseInsensitive(sin_prefijo, 'archivo') > 0, 'PaperclipIcon',
            positionCaseInsensitive(sin_prefijo, 'establecimiento') > 0, 'BuildingsIcon',
            positionCaseInsensitive(sin_prefijo, 'sede') > 0, 'HouseLineIcon',
            positionCaseInsensitive(sin_prefijo, 'estudiante') > 0, 'GraduationCapIcon',
            positionCaseInsensitive(sin_prefijo, 'docente') > 0, 'ChalkboardTeacherIcon',
            positionCaseInsensitive(sin_prefijo, 'matricula') > 0, 'ClipboardTextIcon',
            positionCaseInsensitive(sin_prefijo, 'inscripcion') > 0, 'ClipboardTextIcon',
            positionCaseInsensitive(sin_prefijo, 'asignatura') > 0, 'BookIcon',
            positionCaseInsensitive(sin_prefijo, 'plan') > 0, 'BookIcon',
            positionCaseInsensitive(sin_prefijo, 'evaluacion') > 0, 'ChartBarIcon',
            positionCaseInsensitive(sin_prefijo, 'calificacion') > 0, 'ChartBarIcon',
            positionCaseInsensitive(sin_prefijo, 'nota') > 0, 'ChartBarIcon',
            positionCaseInsensitive(sin_prefijo, 'escala') > 0, 'ChartBarIcon',
            positionCaseInsensitive(sin_prefijo, 'observador') > 0, 'EyeIcon',
            positionCaseInsensitive(sin_prefijo, 'mensaje') > 0, 'EnvelopeIcon',
            positionCaseInsensitive(sin_prefijo, 'noticia') > 0, 'EnvelopeIcon',
            positionCaseInsensitive(sin_prefijo, 'municipio') > 0, 'MapPinIcon',
            positionCaseInsensitive(sin_prefijo, 'departamento') > 0, 'MapPinIcon',
            positionCaseInsensitive(sin_prefijo, 'calendario') > 0, 'CalendarIcon',
            positionCaseInsensitive(sin_prefijo, 'periodo') > 0, 'CalendarIcon',
            positionCaseInsensitive(sin_prefijo, 'horario') > 0, 'CalendarIcon',
            positionCaseInsensitive(sin_prefijo, 'rol') > 0, 'ShieldIcon',
            positionCaseInsensitive(sin_prefijo, 'permiso') > 0, 'ShieldIcon',
            positionCaseInsensitive(sin_prefijo, 'menu') > 0, 'SidebarIcon',
            positionCaseInsensitive(sin_prefijo, 'grado') > 0, 'GraduationCapIcon',
            positionCaseInsensitive(sin_prefijo, 'grupo') > 0, 'UsersThreeIcon',
            positionCaseInsensitive(sin_prefijo, 'padre') > 0, 'UsersIcon',
            positionCaseInsensitive(sin_prefijo, 'familiar') > 0, 'UsersIcon',
            positionCaseInsensitive(sin_prefijo, 'video') > 0, 'VideoIcon',
            positionCaseInsensitive(sin_prefijo, 'encuesta') > 0, 'ClipboardTextIcon',
            positionCaseInsensitive(sin_prefijo, 'pregunta') > 0, 'ClipboardTextIcon',
            positionCaseInsensitive(sin_prefijo, 'respuesta') > 0, 'ClipboardTextIcon',
            positionCaseInsensitive(sin_prefijo, 'diploma') > 0, 'MedalIcon',
            positionCaseInsensitive(sin_prefijo, 'logro') > 0, 'MedalIcon',
            positionCaseInsensitive(sin_prefijo, 'reconocimiento') > 0, 'MedalIcon',
            positionCaseInsensitive(sin_prefijo, 'traslado') > 0, 'ArrowRightIcon',
            positionCaseInsensitive(sin_prefijo, 'retiro') > 0, 'ArrowRightIcon',
            positionCaseInsensitive(sin_prefijo, 'prematricula') > 0, 'ArrowRightIcon',
            positionCaseInsensitive(sin_prefijo, 'reserva_cupo') > 0, 'ArrowRightIcon',
            'FileTextIcon'
        ) AS icon
    FROM catalogo
)
SELECT
    c.slug,
    c.name,
    c.icon,
    countIf(
        (a.tabla = c.tabla_real OR a.tabla = c.tabla_bare)
        AND toDate(a.ts) = today() AND a.operacion != 'r'
        AND a.sesion_id IN (SELECT family_id FROM auditoria.tsesion_web WHERE app_name = 'COLOMBIA-EVALUADORA')
    ) AS operationsToday,
    count() OVER() AS totalCount
FROM con_icono c
LEFT JOIN auditoria.audit_log a ON (a.tabla = c.tabla_real OR a.tabla = c.tabla_bare)
WHERE coalesce(:BODY.FILTERS.NAME, '') = '' OR positionCaseInsensitive(c.name, :BODY.FILTERS.NAME) > 0
GROUP BY c.slug, c.name, c.icon
ORDER BY c.name
LIMIT :BODY.PAGESIZE OFFSET :BODY.PAGEOFFSET;
$Q$
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid = 'audit-clickhouse-cval'
   AND q.path_template = '/audit-tables/query';

UPDATE public.query q
   SET query = $Q$
WITH slug_calc AS (
    SELECT concat('t', substring(lower(replaceRegexpAll(substring(:PARAM.SLUG, 2), '([A-Z])', '_\1')), 2)) AS tabla_bare
)
SELECT
    concat(toString(lsn), '-', toString(seq)) AS id,
    CASE operacion WHEN 'c' THEN 'INSERT' WHEN 'u' THEN 'UPDATE' WHEN 'd' THEN 'DELETE' ELSE 'SNAPSHOT' END AS operation,
    app_user AS authorName,
    NULL AS authorAvatarUrl,
    false AS authorVerified,
    toString(client_ip) AS ip,
    etiqueta AS entityName,
    pk AS entityId,
    ts AS occurredAt,
    fila_new_raw AS entityFieldsRaw,
    count() OVER() AS totalCount
FROM auditoria.audit_log, slug_calc
WHERE (tabla = concat('pigse.', tabla_bare) OR tabla = tabla_bare)
  AND operacion != 'r'
  AND sesion_id IN (SELECT family_id FROM auditoria.tsesion_web WHERE app_name = 'PIGSE')
  AND (coalesce(:BODY.FILTERS.AUTHOR, '') = '' OR positionCaseInsensitive(app_user, :BODY.FILTERS.AUTHOR) > 0
                                   OR positionCaseInsensitive(toString(client_ip), :BODY.FILTERS.AUTHOR) > 0)
  AND (coalesce(:BODY.FILTERS.OPERATIONCH, '') = '' OR operacion = :BODY.FILTERS.OPERATIONCH)
  AND ts >= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDFROM = '', '1970-01-01', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDTO = '', '2999-12-31', :BODY.FILTERS.OCCURREDTO))
  AND (
      position(concat(',', :CONTEXT.ROLES, ','), ',PIGSE-ADMINISTRADOR,') > 0
      OR position(concat(',', :CONTEXT.ROLES, ','), ',PIGSE-SECRETARIA_TERRITORIAL,') > 0
      OR (:CONTEXT.ESTABLISHMENT != '' AND JSONExtractString(contexto, 'establecimiento') = :CONTEXT.ESTABLISHMENT)
  )
ORDER BY ts DESC
LIMIT :BODY.PAGESIZE OFFSET :BODY.PAGEOFFSET;
$Q$
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid = 'audit-clickhouse-pigse'
   AND q.path_template = '/audit-tables/:SLUG/operations/query';

UPDATE public.query q
   SET query = $Q$
WITH slug_calc AS (
    SELECT concat('t', substring(lower(replaceRegexpAll(substring(:PARAM.SLUG, 2), '([A-Z])', '_\1')), 2)) AS tabla_bare
)
SELECT
    concat(toString(lsn), '-', toString(seq)) AS id,
    CASE operacion WHEN 'c' THEN 'INSERT' WHEN 'u' THEN 'UPDATE' WHEN 'd' THEN 'DELETE' ELSE 'SNAPSHOT' END AS operation,
    app_user AS authorName,
    NULL AS authorAvatarUrl,
    false AS authorVerified,
    toString(client_ip) AS ip,
    etiqueta AS entityName,
    pk AS entityId,
    ts AS occurredAt,
    fila_new_raw AS entityFieldsRaw,
    count() OVER() AS totalCount
FROM auditoria.audit_log, slug_calc
WHERE (tabla = concat('academico_test.', tabla_bare) OR tabla = tabla_bare)
  AND operacion != 'r'
  AND sesion_id IN (SELECT family_id FROM auditoria.tsesion_web WHERE app_name = 'COLOMBIA-EVALUADORA')
  AND (coalesce(:BODY.FILTERS.AUTHOR, '') = '' OR positionCaseInsensitive(app_user, :BODY.FILTERS.AUTHOR) > 0
                                   OR positionCaseInsensitive(toString(client_ip), :BODY.FILTERS.AUTHOR) > 0)
  AND (coalesce(:BODY.FILTERS.OPERATIONCH, '') = '' OR operacion = :BODY.FILTERS.OPERATIONCH)
  AND ts >= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDFROM = '', '1970-01-01', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDTO = '', '2999-12-31', :BODY.FILTERS.OCCURREDTO))
  AND (
      position(concat(',', :CONTEXT.ROLES, ','), ',CEVAL-SUPER_ADMINISTRADOR,') > 0
      OR (:CONTEXT.ESTABLISHMENT != '' AND JSONExtractString(contexto, 'establecimiento') = :CONTEXT.ESTABLISHMENT)
  )
ORDER BY ts DESC
LIMIT :BODY.PAGESIZE OFFSET :BODY.PAGEOFFSET;
$Q$
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid = 'audit-clickhouse-cval'
   AND q.path_template = '/audit-tables/:SLUG/operations/query';

DO $$
DECLARE
    v_ok BOOLEAN;
BEGIN
    SELECT bool_and(q.query ILIKE '%tabla_bare%' OR q.query ILIKE '%app_name%')
      INTO v_ok
      FROM public.query q
      JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid IN ('audit-clickhouse-pigse', 'audit-clickhouse-cval')
       AND q.path_template IN ('/audit-tables/query', '/audit-tables/:SLUG/operations/query');

    IF NOT coalesce(v_ok, false) THEN
        RAISE EXCEPTION 'V381: alguna de las 4 filas no se actualizo';
    END IF;

    RAISE NOTICE 'V381 OK: catalogo y detalle de /audit-tables (pigse+cval) ahora escopan por sesion_id -> tsesion_web.app_name en vez de por el prefijo de esquema de tabla.';
END $$;
