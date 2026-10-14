-- V557.2 -- Semillas del agente: herramientas, rutas de UI y formularios
-- Que hace: 6 herramientas de control, 25 de escritura, 24 de lectura y 1 analitica.
--   Las de datos resuelven public.query por (metodo, path) en eval-col al aplicar; si
--   una ruta no existe no se inserta. Luego 22 rutas de menu y 4 formularios.
-- Por que aqui: ON CONFLICT DO UPDATE para que editar una descripcion la actualice.
--   parametros = allowlist: el invocador solo acepta las claves de param_types que estan aqui
--   (sin baja, sin FILE, sin flags de quitar).
-- Depende de: V557 y V557.1 (ai.*), public.query y public.microservice (eval-col).

-- ---------------------------------------------------------------------------
-- 1. Control (sin ruta): las ejecuta el propio agente.
-- ---------------------------------------------------------------------------
INSERT INTO ai.herramienta (codigo, tipo, query_uuid, menu_codigo, descripcion_modelo, parametros,
                            requiere_confirmacion, ejemplos, version, created_by)
SELECT v.codigo, v.tipo, NULL::VARCHAR, NULL::VARCHAR, v.descripcion, v.parametros::jsonb,
       FALSE, '[]'::jsonb, 1, 'migracion'
  FROM (VALUES
    ('pedir_datos_faltantes', 'CONTROL',
     'Usala cuando falte un dato obligatorio y no se pueda resolver con certeza. Devuelve la pregunta al usuario y termina el turno; el borrador queda en memoria.',
     '{"faltantes":{"descripcion":"Lista de campos que faltan, cada uno con su pregunta y opciones si las hay","resuelve_con":null,"inferible":false},"borrador":{"descripcion":"Valores ya conocidos","resuelve_con":null,"inferible":false}}'),
    ('preparar_confirmacion', 'CONTROL',
     'Usala cuando una accion de escritura tiene todos sus datos. Registra la accion pendiente con su resumen para que el usuario la confirme con botones. No ejecuta nada.',
     '{"herramienta":{"descripcion":"Codigo de la herramienta ESCRITURA a ejecutar","resuelve_con":null,"inferible":false},"argumentos":{"descripcion":"Valores completos, validados contra el schema de la herramienta","resuelve_con":null,"inferible":false}}'),
    ('buscar_pantalla', 'CONTROL',
     'Busca en que pantalla de la aplicacion se hace algo, por texto o sinonimo. Solo devuelve pantallas de menus que el usuario puede ver.',
     '{"texto":{"descripcion":"Lo que el usuario quiere hacer o encontrar","resuelve_con":null,"inferible":false}}'),
    ('accion_ui', 'CONTROL',
     'Devuelve acciones de interfaz (NAVEGAR, RELLENAR, RESALTAR, APLICAR_FILTROS) sobre formularios y pantallas. No envia formularios: el envio lo hace la persona.',
     '{"acciones":{"descripcion":"Lista de acciones cerradas con su ruta o formulario y sus valores","resuelve_con":null,"inferible":false}}'),
    ('esquema_de_accion', 'CONTROL',
     'Devuelve los parametros de una accion de escritura: cuales son obligatorios, su formato y de donde sale cada valor. Usala antes de preguntar datos.',
     '{"herramienta":{"descripcion":"Codigo de la herramienta ESCRITURA","resuelve_con":null,"inferible":false}}'),
    ('consulta_analitica', 'CONTROL',
     'Ejecuta una consulta analitica curada (nivel 1) entre las herramientas ANALITICA que el usuario puede usar. No genera SQL.',
     '{"herramienta":{"descripcion":"Codigo de la herramienta ANALITICA","resuelve_con":null,"inferible":false},"parametros":{"descripcion":"Filtros de la consulta curada","resuelve_con":null,"inferible":false}}')
  ) AS v (codigo, tipo, descripcion, parametros)
ON CONFLICT (codigo) WHERE active = TRUE DO UPDATE SET
    tipo                  = EXCLUDED.tipo,
    query_uuid            = EXCLUDED.query_uuid,
    menu_codigo           = EXCLUDED.menu_codigo,
    descripcion_modelo    = EXCLUDED.descripcion_modelo,
    parametros            = EXCLUDED.parametros,
    requiere_confirmacion = EXCLUDED.requiere_confirmacion,
    ejemplos              = EXCLUDED.ejemplos,
    version               = EXCLUDED.version,
    modified_by           = 'migracion',
    modified_at           = CURRENT_TIMESTAMP;

-- ---------------------------------------------------------------------------
-- 2. Rutas de eval-col: escritura (confirmacion), lectura y analitica.
--    DISTINCT ON evita "affect row a second time" si una ruta se repite.
-- ---------------------------------------------------------------------------
INSERT INTO ai.herramienta (codigo, tipo, query_uuid, menu_codigo, descripcion_modelo, parametros,
                            requiere_confirmacion, ejemplos, version, created_by)
SELECT DISTINCT ON (v.codigo)
       v.codigo, v.tipo, q.uuid, v.menu_codigo, v.descripcion, v.parametros::jsonb,
       v.confirma, '[]'::jsonb, 1, 'migracion'
  FROM (VALUES
    -- ===== ESCRITURA (requiere confirmacion) =====
    ('editar_funcionario', 'ESCRITURA', 'PATCH', '/establecimientos/funcionarios/:ID', 'FUNCIONARIOS',
     'Edita datos de un funcionario existente: nombre, documento, contacto, cargo y vinculacion. No cambia su estado ni su foto. Requiere confirmacion.',
     '{"PARAM.ID":{"descripcion":"Pk del funcionario","resuelve_con":"funcionarios_listar","inferible":false},"BODY.PERSON.FIRSTNAME":{"descripcion":"Primer nombre","resuelve_con":null,"inferible":false},"BODY.PERSON.MIDDLENAME":{"descripcion":"Segundo nombre","resuelve_con":null,"inferible":false},"BODY.PERSON.LASTNAME":{"descripcion":"Primer apellido","resuelve_con":null,"inferible":false},"BODY.PERSON.SECONDLASTNAME":{"descripcion":"Segundo apellido","resuelve_con":null,"inferible":false},"BODY.PERSON.IDENTIFICATION":{"descripcion":"Numero de documento","resuelve_con":null,"inferible":false},"BODY.PERSON.DOCUMENTTYPE.ID":{"descripcion":"Tipo de documento (pk de catalogo)","resuelve_con":"catalogo_valores","inferible":false},"BODY.PERSON.BIRTHDATE":{"descripcion":"Fecha de nacimiento AAAA-MM-DD","resuelve_con":null,"inferible":false},"BODY.PERSON.GENDER.ID":{"descripcion":"Genero (pk de catalogo)","resuelve_con":"catalogo_valores","inferible":false},"BODY.PERSON.PHONE":{"descripcion":"Telefono de contacto","resuelve_con":null,"inferible":false},"BODY.ADDRESS":{"descripcion":"Direccion","resuelve_con":null,"inferible":false},"BODY.GRADE.ID":{"descripcion":"Grado de escalafon (pk de catalogo)","resuelve_con":"catalogo_valores","inferible":false},"BODY.EMPLOYEECLASS.ID":{"descripcion":"Clase de funcionario (pk de catalogo)","resuelve_con":"catalogo_valores","inferible":false},"BODY.FUNDINGSOURCE.ID":{"descripcion":"Fuente de recurso (pk de catalogo)","resuelve_con":"catalogo_valores","inferible":false},"BODY.EDUCATIONLEVEL.ID":{"descripcion":"Nivel educativo (pk de catalogo)","resuelve_con":"catalogo_valores","inferible":false},"BODY.EMPLOYMENTTYPE.ID":{"descripcion":"Tipo de vinculacion (pk de catalogo)","resuelve_con":"catalogo_valores","inferible":false},"BODY.FUNCTIONALPOSITION.ID":{"descripcion":"Cargo (pk de catalogo)","resuelve_con":"catalogo_valores","inferible":false},"BODY.HIGHESTEDUCATIONLEVEL.ID":{"descripcion":"Nivel de educacion mas alto (pk de catalogo)","resuelve_con":"catalogo_valores","inferible":false}}',
     TRUE),
    ('crear_actividad_planeador', 'ESCRITURA', 'POST', '/planeador/actividades', 'PLANEADOR',
     'Crea una actividad del planeador dentro de una unidad, para un grupo y una asignatura del docente. Pregunta titulo, fechas y grupo si no son inferibles. Requiere confirmacion.',
     '{"BODY.TITULO":{"descripcion":"Titulo de la actividad","resuelve_con":null,"inferible":false},"BODY.DESCRIPCION":{"descripcion":"Descripcion de la actividad","resuelve_con":null,"inferible":false},"BODY.FK_TUNIDAD":{"descripcion":"Unidad a la que pertenece","resuelve_con":"unidades_listar","inferible":true},"BODY.FK_TGRUPO":{"descripcion":"Grupo","resuelve_con":"docentes_grupos_listar","inferible":true},"BODY.FK_TASIGNATURA":{"descripcion":"Asignatura","resuelve_con":"docentes_grado_asignatura_listar","inferible":true},"BODY.FECHA_INICIO":{"descripcion":"Fecha de inicio AAAA-MM-DD","resuelve_con":null,"inferible":false},"BODY.FECHA_CIERRE":{"descripcion":"Fecha de cierre AAAA-MM-DD","resuelve_con":null,"inferible":false},"BODY.DURACION_ESTIMADA":{"descripcion":"Duracion estimada","resuelve_con":null,"inferible":false},"BODY.SEMANA_CRONOGRAMA":{"descripcion":"Semana del cronograma","resuelve_con":null,"inferible":false},"BODY.ES_EVALUATIVA":{"descripcion":"Si es evaluativa (S/N)","resuelve_con":null,"inferible":true},"BODY.FK_TLV_TIPO_ACTIVIDAD":{"descripcion":"Tipo de actividad (catalogo)","resuelve_con":"catalogo_valores","inferible":false},"BODY.FK_TLV_MODALIDAD":{"descripcion":"Modalidad (catalogo)","resuelve_con":"catalogo_valores","inferible":false},"BODY.FK_TLV_JERARQUIA":{"descripcion":"Jerarquia (catalogo)","resuelve_con":"catalogo_valores","inferible":true},"BODY.FK_TLV_TIPO_CALCULO":{"descripcion":"Tipo de calculo de la nota (catalogo)","resuelve_con":"catalogo_valores","inferible":true},"BODY.FK_TLV_METODO_VALORACION":{"descripcion":"Metodo de valoracion (catalogo)","resuelve_con":"catalogo_valores","inferible":true},"BODY.FK_TLV_INSTRUMENTO_EVALUACION":{"descripcion":"Instrumento de evaluacion (catalogo)","resuelve_con":"catalogo_valores","inferible":true},"BODY.FK_TLV_TIPO_EVIDENCIA":{"descripcion":"Tipo de evidencia (catalogo)","resuelve_con":"catalogo_valores","inferible":true},"BODY.DESCRIPCION_INSTRUMENTO":{"descripcion":"Descripcion del instrumento","resuelve_con":null,"inferible":false},"BODY.PONDERACION":{"descripcion":"Ponderacion en la unidad (0-100)","resuelve_con":null,"inferible":false},"BODY.NOTA_MAXIMA":{"descripcion":"Nota maxima","resuelve_con":null,"inferible":true},"BODY.INFLUENCIA":{"descripcion":"Influencia en la definitiva (porcentaje)","resuelve_con":null,"inferible":true},"BODY.FK_TMATRICULAS":{"descripcion":"Estudiantes asignados (matriculas)","resuelve_con":"estudiantes_grupo_listar","inferible":true},"BODY.ASIGNAR_TODO_EL_GRUPO":{"descripcion":"Asignar a todo el grupo (true/false)","resuelve_con":null,"inferible":true},"BODY.CRITERIOS":{"descripcion":"Criterios de la unidad vinculados","resuelve_con":"unidad_criterios_listar","inferible":true},"BODY.EVIDENCIAS":{"descripcion":"Enunciados de evidencia vinculados","resuelve_con":"referente_enunciados_listar","inferible":true},"BODY.ADAPTACIONES":{"descripcion":"Adaptaciones para estudiantes con necesidades","resuelve_con":null,"inferible":false},"BODY.MATERIALES":{"descripcion":"Materiales requeridos","resuelve_con":null,"inferible":false},"BODY.MATERIAL_REQUERIDO":{"descripcion":"Material requerido (texto)","resuelve_con":null,"inferible":false},"BODY.REQUIERE_TEXTO":{"descripcion":"Pide texto como evidencia (S/N)","resuelve_con":null,"inferible":true},"BODY.REQUIERE_ARCHIVO":{"descripcion":"Pide archivo como evidencia (S/N); el agente no sube archivos, dejar N","resuelve_con":null,"inferible":true},"BODY.GENERA_EVIDENCIAS":{"descripcion":"Genera evidencias (S/N)","resuelve_con":null,"inferible":true},"BODY.REQUIERE_VALIDACION_COORDINADOR":{"descripcion":"Requiere validacion del coordinador (S/N)","resuelve_con":null,"inferible":true},"BODY.OBSERVACIONES_DOCENTE":{"descripcion":"Observaciones del docente","resuelve_con":null,"inferible":false},"BODY.RECUPERACION":{"descripcion":"Configuracion de recuperacion","resuelve_con":null,"inferible":true}}',
     TRUE),
    ('editar_actividad_planeador', 'ESCRITURA', 'PUT', '/planeador/actividades/:ID', 'PLANEADOR',
     'Edita una actividad existente del planeador: titulo, fechas, ponderacion, instrumento, grupo y estudiantes. No la desvincula de su unidad ni quita recuperacion. Requiere confirmacion.',
     '{"PARAM.ID":{"descripcion":"Pk de la actividad","resuelve_con":"actividades_mias_listar","inferible":false},"BODY.TITULO":{"descripcion":"Titulo","resuelve_con":null,"inferible":false},"BODY.DESCRIPCION":{"descripcion":"Descripcion","resuelve_con":null,"inferible":false},"BODY.FK_TUNIDAD":{"descripcion":"Unidad","resuelve_con":"unidades_listar","inferible":true},"BODY.FK_TGRUPO":{"descripcion":"Grupo","resuelve_con":"docentes_grupos_listar","inferible":true},"BODY.FK_TASIGNATURA":{"descripcion":"Asignatura","resuelve_con":"docentes_grado_asignatura_listar","inferible":true},"BODY.FECHA_INICIO":{"descripcion":"Fecha de inicio AAAA-MM-DD","resuelve_con":null,"inferible":false},"BODY.FECHA_CIERRE":{"descripcion":"Fecha de cierre AAAA-MM-DD","resuelve_con":null,"inferible":false},"BODY.DURACION_ESTIMADA":{"descripcion":"Duracion estimada","resuelve_con":null,"inferible":false},"BODY.SEMANA_CRONOGRAMA":{"descripcion":"Semana del cronograma","resuelve_con":null,"inferible":false},"BODY.ES_EVALUATIVA":{"descripcion":"Si es evaluativa (S/N)","resuelve_con":null,"inferible":true},"BODY.FK_TLV_TIPO_ACTIVIDAD":{"descripcion":"Tipo de actividad (catalogo)","resuelve_con":"catalogo_valores","inferible":false},"BODY.FK_TLV_MODALIDAD":{"descripcion":"Modalidad (catalogo)","resuelve_con":"catalogo_valores","inferible":false},"BODY.FK_TLV_TIPO_CALCULO":{"descripcion":"Tipo de calculo (catalogo)","resuelve_con":"catalogo_valores","inferible":true},"BODY.FK_TLV_METODO_VALORACION":{"descripcion":"Metodo de valoracion (catalogo)","resuelve_con":"catalogo_valores","inferible":true},"BODY.FK_TLV_INSTRUMENTO_EVALUACION":{"descripcion":"Instrumento de evaluacion (catalogo)","resuelve_con":"catalogo_valores","inferible":true},"BODY.FK_TLV_TIPO_EVIDENCIA":{"descripcion":"Tipo de evidencia (catalogo)","resuelve_con":"catalogo_valores","inferible":true},"BODY.DESCRIPCION_INSTRUMENTO":{"descripcion":"Descripcion del instrumento","resuelve_con":null,"inferible":false},"BODY.PONDERACION":{"descripcion":"Ponderacion en la unidad (0-100)","resuelve_con":null,"inferible":false},"BODY.NOTA_MAXIMA":{"descripcion":"Nota maxima","resuelve_con":null,"inferible":true},"BODY.INFLUENCIA":{"descripcion":"Influencia en la definitiva (porcentaje)","resuelve_con":null,"inferible":true},"BODY.FK_TMATRICULAS":{"descripcion":"Estudiantes asignados (matriculas)","resuelve_con":"estudiantes_grupo_listar","inferible":true},"BODY.ASIGNAR_TODO_EL_GRUPO":{"descripcion":"Asignar a todo el grupo (true/false)","resuelve_con":null,"inferible":true},"BODY.CRITERIOS":{"descripcion":"Criterios de la unidad vinculados","resuelve_con":"unidad_criterios_listar","inferible":true},"BODY.EVIDENCIAS":{"descripcion":"Enunciados de evidencia vinculados","resuelve_con":"referente_enunciados_listar","inferible":true},"BODY.ADAPTACIONES":{"descripcion":"Adaptaciones","resuelve_con":null,"inferible":false},"BODY.MATERIALES":{"descripcion":"Materiales requeridos","resuelve_con":null,"inferible":false},"BODY.MATERIAL_REQUERIDO":{"descripcion":"Material requerido (texto)","resuelve_con":null,"inferible":false},"BODY.REQUIERE_TEXTO":{"descripcion":"Pide texto (S/N)","resuelve_con":null,"inferible":true},"BODY.REQUIERE_ARCHIVO":{"descripcion":"Pide archivo (S/N); el agente no sube archivos, dejar N","resuelve_con":null,"inferible":true},"BODY.GENERA_EVIDENCIAS":{"descripcion":"Genera evidencias (S/N)","resuelve_con":null,"inferible":true},"BODY.REQUIERE_VALIDACION_COORDINADOR":{"descripcion":"Requiere validacion del coordinador (S/N)","resuelve_con":null,"inferible":true},"BODY.OBSERVACIONES_DOCENTE":{"descripcion":"Observaciones del docente","resuelve_con":null,"inferible":false},"BODY.RECUPERACION":{"descripcion":"Configuracion de recuperacion","resuelve_con":null,"inferible":true}}',
     TRUE),
    ('actualizar_adaptaciones_actividad', 'ESCRITURA', 'PUT', '/planeador/actividades/:ID/adaptaciones', 'PLANEADOR',
     'Reemplaza las adaptaciones de una actividad. Requiere confirmacion.',
     '{"PARAM.ID":{"descripcion":"Pk de la actividad","resuelve_con":"actividades_mias_listar","inferible":false},"BODY.ADAPTACIONES":{"descripcion":"Adaptaciones (estructura JSON de la pantalla)","resuelve_con":null,"inferible":false}}',
     TRUE),
    ('actualizar_instrumento_actividad', 'ESCRITURA', 'PUT', '/planeador/actividades/:ID/instrumento', 'PLANEADOR',
     'Reemplaza la definicion del instrumento de evaluacion de una actividad. Requiere confirmacion.',
     '{"PARAM.ID":{"descripcion":"Pk de la actividad","resuelve_con":"actividades_mias_listar","inferible":false},"BODY.DEFINICION":{"descripcion":"Definicion del instrumento (JSON de la pantalla)","resuelve_con":"actividad_instrumento","inferible":false}}',
     TRUE),
    ('actualizar_materiales_actividad', 'ESCRITURA', 'PUT', '/planeador/actividades/:ID/materiales', 'PLANEADOR',
     'Reemplaza los materiales de una actividad. Requiere confirmacion.',
     '{"PARAM.ID":{"descripcion":"Pk de la actividad","resuelve_con":"actividades_mias_listar","inferible":false},"BODY.MATERIALES":{"descripcion":"Lista de materiales (JSON)","resuelve_con":null,"inferible":false}}',
     TRUE),
    ('crear_unidad_planeador', 'ESCRITURA', 'POST', '/planeador/unidades', 'PLANEADOR',
     'Crea una unidad del planeador para una asignatura y un grado del docente. Requiere confirmacion.',
     '{"BODY.NOMBRE":{"descripcion":"Nombre de la unidad","resuelve_con":null,"inferible":false},"BODY.DESCRIPCION":{"descripcion":"Descripcion","resuelve_con":null,"inferible":false},"BODY.OBJETIVOS":{"descripcion":"Objetivos","resuelve_con":null,"inferible":false},"BODY.PONDERACION":{"descripcion":"Ponderacion (0-100)","resuelve_con":null,"inferible":false},"BODY.FK_TASIGNATURA":{"descripcion":"Asignatura","resuelve_con":"docentes_grado_asignatura_listar","inferible":true},"BODY.FK_TGRADO":{"descripcion":"Grado","resuelve_con":"docentes_grado_asignatura_listar","inferible":true},"BODY.FK_TFUNCIONARIO":{"descripcion":"Docente responsable; omitelo si es la propia persona: el sistema la pone","resuelve_con":"funcionarios_listar","inferible":true},"BODY.FK_REFERENTE_CURRICULAR":{"descripcion":"Referente curricular","resuelve_con":"referentes_listar","inferible":true},"BODY.FK_TLV_CALCULO_DEFINITIVA":{"descripcion":"Calculo de la definitiva (catalogo)","resuelve_con":"catalogo_valores","inferible":true},"BODY.CONTENIDOS":{"descripcion":"Contenidos de la unidad","resuelve_con":null,"inferible":false},"BODY.CONTENIDOS_TITULOS":{"descripcion":"Titulos de los contenidos","resuelve_con":null,"inferible":false},"BODY.ENUNCIADOS":{"descripcion":"Enunciados del referente vinculados","resuelve_con":"referente_enunciados_listar","inferible":true}}',
     TRUE),
    ('editar_unidad_planeador', 'ESCRITURA', 'PUT', '/planeador/unidades/:ID', 'PLANEADOR',
     'Edita una unidad del planeador: nombre, objetivos, ponderacion, referente y contenidos. No quita el referente ni la ponderacion. Requiere confirmacion.',
     '{"PARAM.ID":{"descripcion":"Pk de la unidad","resuelve_con":"unidades_listar","inferible":false},"BODY.NOMBRE":{"descripcion":"Nombre","resuelve_con":null,"inferible":false},"BODY.DESCRIPCION":{"descripcion":"Descripcion","resuelve_con":null,"inferible":false},"BODY.OBJETIVOS":{"descripcion":"Objetivos","resuelve_con":null,"inferible":false},"BODY.PONDERACION":{"descripcion":"Ponderacion (0-100)","resuelve_con":null,"inferible":false},"BODY.FK_TASIGNATURA":{"descripcion":"Asignatura","resuelve_con":"docentes_grado_asignatura_listar","inferible":true},"BODY.FK_TGRADO":{"descripcion":"Grado","resuelve_con":"docentes_grado_asignatura_listar","inferible":true},"BODY.FK_TFUNCIONARIO":{"descripcion":"Docente responsable","resuelve_con":"funcionarios_listar","inferible":true},"BODY.FK_REFERENTE_CURRICULAR":{"descripcion":"Referente curricular","resuelve_con":"referentes_listar","inferible":true},"BODY.FK_TLV_CALCULO_DEFINITIVA":{"descripcion":"Calculo de la definitiva (catalogo)","resuelve_con":"catalogo_valores","inferible":true},"BODY.CONTENIDOS":{"descripcion":"Contenidos","resuelve_con":null,"inferible":false},"BODY.CONTENIDOS_TITULOS":{"descripcion":"Titulos de los contenidos","resuelve_con":null,"inferible":false},"BODY.ENUNCIADOS":{"descripcion":"Enunciados vinculados","resuelve_con":"referente_enunciados_listar","inferible":true}}',
     TRUE),
    ('vincular_actividad_unidad', 'ESCRITURA', 'PUT', '/planeador/unidades/:ID/actividades/:ACTIVIDADID', 'PLANEADOR',
     'Asigna una actividad a esta unidad con su ponderacion, o la mueve de unidad si se permite. Requiere confirmacion.',
     '{"PARAM.ID":{"descripcion":"Pk de la unidad destino","resuelve_con":"unidades_listar","inferible":false},"PARAM.ACTIVIDADID":{"descripcion":"Pk de la actividad","resuelve_con":"actividades_mias_listar","inferible":false},"BODY.PONDERACION":{"descripcion":"Ponderacion en la unidad (0-100)","resuelve_con":null,"inferible":false},"BODY.PERMITIR_MOVER_DE_UNIDAD":{"descripcion":"Permitir mover la actividad desde otra unidad (true/false)","resuelve_con":null,"inferible":true}}',
     TRUE),
    ('ponderar_actividad_unidad', 'ESCRITURA', 'PUT', '/planeador/unidades/actividades/:ACTIVIDADID/ponderacion', 'PLANEADOR',
     'Cambia la ponderacion de una actividad dentro de su unidad. Requiere confirmacion.',
     '{"PARAM.ACTIVIDADID":{"descripcion":"Pk de la actividad","resuelve_con":"actividades_mias_listar","inferible":false},"BODY.PONDERACION":{"descripcion":"Ponderacion (0-100)","resuelve_con":null,"inferible":false}}',
     TRUE),
    ('crear_criterio_unidad', 'ESCRITURA', 'POST', '/planeador/unidades/:ID/criterios', 'PLANEADOR',
     'Agrega un criterio de evaluacion a una unidad, con sus niveles. Requiere confirmacion.',
     '{"PARAM.ID":{"descripcion":"Pk de la unidad","resuelve_con":"unidades_listar","inferible":false},"BODY.CODIGO":{"descripcion":"Codigo del criterio","resuelve_con":null,"inferible":false},"BODY.DESCRIPCION":{"descripcion":"Descripcion del criterio","resuelve_con":null,"inferible":false},"BODY.DESCRIPTOR_PROM":{"descripcion":"Descriptor de promocion","resuelve_con":null,"inferible":true},"BODY.NIVELES":{"descripcion":"Niveles del criterio (JSON)","resuelve_con":null,"inferible":false},"BODY.PUBLICO":{"descripcion":"Visible para estudiantes (S/N)","resuelve_con":null,"inferible":true}}',
     TRUE),
    ('editar_criterio_unidad', 'ESCRITURA', 'PUT', '/planeador/unidades/criterios/:ID', 'PLANEADOR',
     'Edita un criterio de evaluacion de una unidad. Requiere confirmacion.',
     '{"PARAM.ID":{"descripcion":"Pk del criterio","resuelve_con":"unidad_criterios_listar","inferible":false},"BODY.CODIGO":{"descripcion":"Codigo del criterio","resuelve_con":null,"inferible":true},"BODY.DESCRIPCION":{"descripcion":"Descripcion del criterio","resuelve_con":null,"inferible":false},"BODY.DESCRIPTOR_PROM":{"descripcion":"Descriptor de promocion","resuelve_con":null,"inferible":true},"BODY.NIVELES":{"descripcion":"Niveles del criterio (JSON)","resuelve_con":null,"inferible":true},"BODY.PUBLICO":{"descripcion":"Visible para estudiantes (S/N)","resuelve_con":null,"inferible":true}}',
     TRUE),
    ('vincular_enunciado_unidad', 'ESCRITURA', 'POST', '/planeador/unidades/:ID/enunciados', 'PLANEADOR',
     'Vincula un enunciado del referente curricular a una unidad. Requiere confirmacion.',
     '{"PARAM.ID":{"descripcion":"Pk de la unidad","resuelve_con":"unidades_listar","inferible":false},"BODY.FK_REFERENTE_ENUNCIADO":{"descripcion":"Enunciado del referente","resuelve_con":"referente_enunciados_listar","inferible":false}}',
     TRUE),
    ('vincular_criterio_actividad', 'ESCRITURA', 'POST', '/planeador/actividades/:ID/criterios', 'PLANEADOR',
     'Vincula un criterio de la unidad a una actividad. Requiere confirmacion.',
     '{"PARAM.ID":{"descripcion":"Pk de la actividad","resuelve_con":"actividades_mias_listar","inferible":false},"BODY.FK_TCRITERIO_UNIDAD":{"descripcion":"Criterio de la unidad","resuelve_con":"unidad_criterios_listar","inferible":false}}',
     TRUE),
    ('vincular_evidencia_actividad', 'ESCRITURA', 'POST', '/planeador/actividades/:ID/evidencias', 'PLANEADOR',
     'Vincula un enunciado de evidencia a una actividad. Requiere confirmacion.',
     '{"PARAM.ID":{"descripcion":"Pk de la actividad","resuelve_con":"actividades_mias_listar","inferible":false},"BODY.FK_REFERENTE_ENUNCIADO":{"descripcion":"Enunciado de evidencia","resuelve_con":"referente_enunciados_listar","inferible":false}}',
     TRUE),
    ('asignar_estudiantes_actividad', 'ESCRITURA', 'PUT', '/planeador/actividades/:ID/estudiantes', 'PLANEADOR',
     'Fija la lista completa de estudiantes de una actividad, o todo el grupo. Reemplaza: los que no incluyas salen de la actividad. Requiere confirmacion.',
     '{"PARAM.ID":{"descripcion":"Pk de la actividad","resuelve_con":"actividades_mias_listar","inferible":false},"BODY.FK_TMATRICULAS":{"descripcion":"Matriculas de los estudiantes","resuelve_con":"estudiantes_grupo_listar","inferible":false},"BODY.ASIGNAR_TODO_EL_GRUPO":{"descripcion":"Asignar a todo el grupo (true/false)","resuelve_con":null,"inferible":true}}',
     TRUE),
    ('calificar_estudiante_actividad', 'ESCRITURA', 'PUT', '/planeador/actividades/estudiantes/:ID/calificar', 'PLANEADOR',
     'Registra la calificacion de un estudiante en una actividad, en la escala de la actividad. Requiere confirmacion.',
     '{"PARAM.ID":{"descripcion":"Pk del estudiante en la actividad","resuelve_con":"actividad_detalle","inferible":false},"BODY.CALIFICACION":{"descripcion":"Calificacion (porcentaje 0-100 o escala de la actividad)","resuelve_con":null,"inferible":false},"BODY.FECHA":{"descripcion":"Fecha de la calificacion AAAA-MM-DD","resuelve_con":null,"inferible":true}}',
     TRUE),
    ('calificar_grupo_escala', 'ESCRITURA', 'PUT', '/planeador/actividades/:ID/calificar-bulk/escala', 'PLANEADOR',
     'Califica a varios estudiantes con una escala numerica o de niveles en una actividad. Requiere confirmacion.',
     '{"PARAM.ID":{"descripcion":"Pk de la actividad","resuelve_con":"actividades_mias_listar","inferible":false},"BODY.ESTUDIANTES":{"descripcion":"Pks de estudiantes en la actividad","resuelve_con":"actividad_detalle","inferible":false},"BODY.VALOR_NUMERICO":{"descripcion":"Valor numerico de la escala","resuelve_con":null,"inferible":false},"BODY.PK_NIVEL":{"descripcion":"Nivel de la escala (pk)","resuelve_con":"actividad_instrumento","inferible":false},"BODY.CRITERIOS":{"descripcion":"Criterios a los que aplica","resuelve_con":"unidad_criterios_listar","inferible":true},"BODY.FECHA":{"descripcion":"Fecha AAAA-MM-DD","resuelve_con":null,"inferible":true}}',
     TRUE),
    ('calificar_grupo_rubrica', 'ESCRITURA', 'PUT', '/planeador/actividades/:ID/calificar-bulk/rubrica', 'PLANEADOR',
     'Califica a varios estudiantes por rubrica: un nivel por criterio. Requiere confirmacion.',
     '{"PARAM.ID":{"descripcion":"Pk de la actividad","resuelve_con":"actividades_mias_listar","inferible":false},"BODY.ESTUDIANTES":{"descripcion":"Pks de estudiantes en la actividad","resuelve_con":"actividad_detalle","inferible":false},"BODY.PK_CRITERIO":{"descripcion":"Criterio de la rubrica (pk)","resuelve_con":"actividad_instrumento","inferible":false},"BODY.PK_NIVEL":{"descripcion":"Nivel elegido (pk)","resuelve_con":"actividad_instrumento","inferible":false},"BODY.FECHA":{"descripcion":"Fecha AAAA-MM-DD","resuelve_con":null,"inferible":true}}',
     TRUE),
    ('calificar_grupo_cotejo', 'ESCRITURA', 'PUT', '/planeador/actividades/:ID/calificar-bulk/cotejo', 'PLANEADOR',
     'Marca a varios estudiantes como cumplido o no en una lista de cotejo. Requiere confirmacion.',
     '{"PARAM.ID":{"descripcion":"Pk de la actividad","resuelve_con":"actividades_mias_listar","inferible":false},"BODY.ESTUDIANTES":{"descripcion":"Pks de estudiantes en la actividad","resuelve_con":"actividad_detalle","inferible":false},"BODY.PK_ITEM":{"descripcion":"Item de la lista de cotejo (pk)","resuelve_con":"actividad_instrumento","inferible":false},"BODY.CUMPLIDO":{"descripcion":"Cumplido (true/false)","resuelve_con":null,"inferible":false},"BODY.FECHA":{"descripcion":"Fecha AAAA-MM-DD","resuelve_con":null,"inferible":true}}',
     TRUE),
    ('estado_resultado_estudiante', 'ESCRITURA', 'PUT', '/planeador/actividades/estudiantes/:ID/estado-resultado', 'PLANEADOR',
     'Cambia el estado del resultado de un estudiante en una actividad. Requiere confirmacion.',
     '{"PARAM.ID":{"descripcion":"Pk del estudiante en la actividad","resuelve_con":"actividad_detalle","inferible":false},"BODY.ESTADO":{"descripcion":"Estado del resultado (catalogo de estados del planeador)","resuelve_con":null,"inferible":false}}',
     TRUE),
    ('estado_resultado_grupo', 'ESCRITURA', 'PUT', '/planeador/actividades/:ID/estado-resultado-bulk', 'PLANEADOR',
     'Cambia el estado del resultado de varios estudiantes de una actividad. Requiere confirmacion.',
     '{"PARAM.ID":{"descripcion":"Pk de la actividad","resuelve_con":"actividades_mias_listar","inferible":false},"BODY.ESTUDIANTES":{"descripcion":"Pks de estudiantes en la actividad","resuelve_con":"actividad_detalle","inferible":false},"BODY.ESTADO":{"descripcion":"Estado del resultado","resuelve_con":null,"inferible":false}}',
     TRUE),
    ('registrar_asistencia_actividad', 'ESCRITURA', 'PUT', '/planeador/actividades/estudiantes/:ID/asistencia', 'PLANEADOR',
     'Registra la asistencia de un estudiante a una actividad. Requiere confirmacion.',
     '{"PARAM.ID":{"descripcion":"Pk del estudiante en la actividad","resuelve_con":"actividad_detalle","inferible":false},"BODY.TIPO_ASISTENCIA":{"descripcion":"Tipo de asistencia (catalogo)","resuelve_con":"catalogo_valores","inferible":false}}',
     TRUE),
    ('observar_estudiante_actividad', 'ESCRITURA', 'PUT', '/planeador/actividades/estudiantes/:ID/observar', 'PLANEADOR',
     'Registra una observacion sobre un estudiante en una actividad. Requiere confirmacion.',
     '{"PARAM.ID":{"descripcion":"Pk del estudiante en la actividad","resuelve_con":"actividad_detalle","inferible":false},"BODY.OBSERVACION":{"descripcion":"Texto de la observacion","resuelve_con":null,"inferible":false},"BODY.MOMENTO":{"descripcion":"Momento de la observacion (catalogo)","resuelve_con":"catalogo_valores","inferible":true},"BODY.FECHA":{"descripcion":"Fecha AAAA-MM-DD","resuelve_con":null,"inferible":true},"BODY.ENLACE":{"descripcion":"Enlace a evidencia (URL)","resuelve_con":null,"inferible":false},"BODY.EVIDENCIAS":{"descripcion":"Evidencias vinculadas","resuelve_con":"referente_enunciados_listar","inferible":true}}',
     TRUE),
    ('observar_grupo_actividad', 'ESCRITURA', 'POST', '/planeador/actividades/:ID/observar-grupal', 'PLANEADOR',
     'Registra una observacion grupal sobre una actividad. Requiere confirmacion.',
     '{"PARAM.ID":{"descripcion":"Pk de la actividad","resuelve_con":"actividades_mias_listar","inferible":false},"BODY.OBSERVACION":{"descripcion":"Texto de la observacion","resuelve_con":null,"inferible":false},"BODY.MOMENTO":{"descripcion":"Momento de la observacion (catalogo)","resuelve_con":"catalogo_valores","inferible":true},"BODY.FECHA":{"descripcion":"Fecha AAAA-MM-DD","resuelve_con":null,"inferible":true},"BODY.ENLACE":{"descripcion":"Enlace a evidencia (URL)","resuelve_con":null,"inferible":false},"BODY.EVIDENCIAS":{"descripcion":"Evidencias vinculadas","resuelve_con":"referente_enunciados_listar","inferible":true}}',
     TRUE),
    -- ===== LECTURA (sin confirmacion; resuelven ids y responden consultas puntuales) =====
    ('mis_menus', 'LECTURA', 'GET', '/my-menus', NULL,
     'Lista los menus que el usuario tiene asignados. Sirve para saber a que pantallas puede llegar.',
     '{}', FALSE),
    ('establecimientos_listar', 'LECTURA', 'GET', '/establecimientos/opciones', 'ESTABLECIMIENTO_EDUCATIVO',
     'Lista los establecimientos educativos a los que el usuario tiene acceso.',
     '{}', FALSE),
    ('sedes_listar', 'LECTURA', 'GET', '/establecimientos/sedes/opciones', 'SEDES_EDUCATIVAS',
     'Lista las sedes a las que el usuario tiene acceso. Usala para resolver una sede por nombre.',
     '{}', FALSE),
    ('jornadas_listar', 'LECTURA', 'POST', '/sedes/jornadas-activas', 'SEDES_EDUCATIVAS',
     'Lista las jornadas activas de una sede.',
     '{"BODY.FK_SEDE":{"descripcion":"Sede (pk)","resuelve_con":"sedes_listar","inferible":false}}', FALSE),
    ('periodos_listar', 'LECTURA', 'POST', '/periodos-academicos/query', 'PERIODOS_ACADEMICOS',
     'Lista periodos academicos con filtro de ano, sede y estado.',
     '{"BODY.ANO":{"descripcion":"Ano lectivo","resuelve_con":"anos_lectivos_listar","inferible":true},"BODY.FK_SEDE":{"descripcion":"Sede (pk)","resuelve_con":"sedes_listar","inferible":true},"BODY.NOMBRE_SEDE":{"descripcion":"Nombre de la sede (texto)","resuelve_con":null,"inferible":true},"BODY.FK_ESTADO":{"descripcion":"Estado (catalogo)","resuelve_con":"catalogo_valores","inferible":true},"BODY.FECHA_DESDE":{"descripcion":"Desde AAAA-MM-DD","resuelve_con":null,"inferible":true},"BODY.FECHA_HASTA":{"descripcion":"Hasta AAAA-MM-DD","resuelve_con":null,"inferible":true},"BODY.PAGEINDEX":{"descripcion":"Numero de pagina","resuelve_con":null,"inferible":true},"BODY.PAGESIZE":{"descripcion":"Filas por pagina","resuelve_con":null,"inferible":true},"BODY.SORT_BY":{"descripcion":"Campo de orden","resuelve_con":null,"inferible":true},"BODY.SORT_DIR":{"descripcion":"Sentido del orden","resuelve_con":null,"inferible":true}}', FALSE),
    ('anos_lectivos_listar', 'LECTURA', 'GET', '/periodos-academicos/anos-lectivos', 'PERIODOS_ACADEMICOS',
     'Lista los anos lectivos disponibles.',
     '{}', FALSE),
    ('funcionarios_listar', 'LECTURA', 'POST', '/establecimientos/funcionarios/query', 'FUNCIONARIOS',
     'Busca funcionarios (docentes y personal) por texto, rol, estado, sede o jornada. Para resolver un funcionario por nombre o documento.',
     '{"BODY.FILTERS.SEARCH":{"descripcion":"Texto: nombre, apellido o documento","resuelve_con":null,"inferible":true},"BODY.FILTERS.ROLES":{"descripcion":"Roles (lista de texto)","resuelve_con":null,"inferible":true},"BODY.FILTERS.STATUSES":{"descripcion":"Estados A/I (lista)","resuelve_con":null,"inferible":true},"BODY.FILTERS.CAMPUSID":{"descripcion":"Sede (pk)","resuelve_con":"sedes_listar","inferible":true},"BODY.FILTERS.WORKSCHEDULES":{"descripcion":"Jornadas (lista)","resuelve_con":"jornadas_listar","inferible":true},"BODY.SORTING.ID":{"descripcion":"Campo de orden","resuelve_con":null,"inferible":true},"BODY.SORTING.DESC":{"descripcion":"Orden descendente (true/false)","resuelve_con":null,"inferible":true},"BODY.PAGEINDEX":{"descripcion":"Numero de pagina","resuelve_con":null,"inferible":true},"BODY.PAGESIZE":{"descripcion":"Filas por pagina","resuelve_con":null,"inferible":true}}', FALSE),
    ('funcionario_detalle', 'LECTURA', 'GET', '/establecimientos/funcionarios/:ID', 'FUNCIONARIOS',
     'Devuelve el detalle de un funcionario. Usala antes de editarlo, para ver los valores actuales.',
     '{"PARAM.ID":{"descripcion":"Pk del funcionario","resuelve_con":"funcionarios_listar","inferible":false}}', FALSE),
    ('catalogo_valores', 'LECTURA', 'GET', '/select/:CATEGORIA', NULL,
     'Lista los valores de un catalogo por su categoria (texto de TLISTA_VALOR). Resuelve pks de catalogo; nunca inventar un pk.',
     '{"PARAM.CATEGORIA":{"descripcion":"Categoria del catalogo, por texto","resuelve_con":null,"inferible":false}}', FALSE),
    ('docentes_grupos_listar', 'LECTURA', 'GET', '/planeador/docentes/grupos', 'PLANEADOR',
     'Lista los grupos que el docente tiene en un periodo. Resuelve el grupo de una actividad.',
     '{"QUERY.PERIODO":{"descripcion":"Periodo academico (pk)","resuelve_con":"periodos_listar","inferible":true}}', FALSE),
    ('docentes_grado_asignatura_listar', 'LECTURA', 'GET', '/planeador/docentes/grado-asignatura', 'PLANEADOR',
     'Lista los pares grado-asignatura que el docente dicta. Resuelve la asignatura y el grado de una unidad o actividad.',
     '{"QUERY.PERIODO":{"descripcion":"Periodo academico (pk)","resuelve_con":"periodos_listar","inferible":true},"QUERY.REFERENTE":{"descripcion":"Referente curricular (pk)","resuelve_con":"referentes_listar","inferible":true}}', FALSE),
    ('estudiantes_grupo_listar', 'LECTURA', 'GET', '/planeador/actividades/estudiantes-grupo', 'PLANEADOR',
     'Lista los estudiantes de un grupo con su matricula. Resuelve FK_TMATRICULAS.',
     '{"QUERY.GRUPO":{"descripcion":"Grupo (pk)","resuelve_con":"docentes_grupos_listar","inferible":false}}', FALSE),
    ('actividades_mias_listar', 'LECTURA', 'GET', '/planeador/actividades/mias', 'PLANEADOR',
     'Lista las actividades del docente con filtros de grupo, unidad, asignatura, dia y estado. Resuelve el pk de una actividad.',
     '{"QUERY.SEARCH":{"descripcion":"Texto del titulo","resuelve_con":null,"inferible":true},"QUERY.GRUPO":{"descripcion":"Grupo (pk)","resuelve_con":"docentes_grupos_listar","inferible":true},"QUERY.ASIGNATURA":{"descripcion":"Asignatura (pk)","resuelve_con":"docentes_grado_asignatura_listar","inferible":true},"QUERY.UNIDAD":{"descripcion":"Unidad (pk)","resuelve_con":"unidades_listar","inferible":true},"QUERY.GRADO_ASIGNATURA_PARES":{"descripcion":"Pares grado-asignatura","resuelve_con":"docentes_grado_asignatura_listar","inferible":true},"QUERY.ESTADOS":{"descripcion":"Estados de la actividad (lista)","resuelve_con":null,"inferible":true},"QUERY.DIA":{"descripcion":"Dia de la semana","resuelve_con":null,"inferible":true},"QUERY.DIAS_GRACIA":{"descripcion":"Dias de gracia","resuelve_con":null,"inferible":true},"QUERY.ORDEN_POR":{"descripcion":"Campo de orden","resuelve_con":null,"inferible":true},"QUERY.ORDEN_ASC":{"descripcion":"Orden ascendente (true/false)","resuelve_con":null,"inferible":true},"QUERY.OFFSET":{"descripcion":"Desplazamiento","resuelve_con":null,"inferible":true},"QUERY.SIZE":{"descripcion":"Filas","resuelve_con":null,"inferible":true}}', FALSE),
    ('actividad_detalle', 'LECTURA', 'GET', '/planeador/actividades/:ID', 'PLANEADOR',
     'Devuelve una actividad con sus estudiantes y sus pks de resultado. Resuelve los ids de estudiante de las escrituras.',
     '{"PARAM.ID":{"descripcion":"Pk de la actividad","resuelve_con":"actividades_mias_listar","inferible":false},"QUERY.DIAS_GRACIA":{"descripcion":"Dias de gracia","resuelve_con":null,"inferible":true}}', FALSE),
    ('actividad_configuracion', 'LECTURA', 'GET', '/planeador/actividades/:ID/configuracion', 'PLANEADOR',
     'Devuelve que campos aplican a una actividad ya creada (evaluacion, instrumento, recuperacion). Usala antes de editarla.',
     '{"PARAM.ID":{"descripcion":"Pk de la actividad","resuelve_con":"actividades_mias_listar","inferible":false}}', FALSE),
    ('actividad_instrumento', 'LECTURA', 'GET', '/planeador/actividades/:ID/instrumento', 'PLANEADOR',
     'Devuelve el instrumento de evaluacion de una actividad, con sus niveles, criterios e items. Resuelve pks de nivel, criterio e item.',
     '{"PARAM.ID":{"descripcion":"Pk de la actividad","resuelve_con":"actividades_mias_listar","inferible":false}}', FALSE),
    ('unidades_listar', 'LECTURA', 'GET', '/planeador/unidades', 'PLANEADOR',
     'Lista las unidades del docente con filtros de asignatura, grado, docente y texto.',
     '{"QUERY.SEARCH":{"descripcion":"Texto del nombre","resuelve_con":null,"inferible":true},"QUERY.ASIGNATURA":{"descripcion":"Asignatura (pk)","resuelve_con":"docentes_grado_asignatura_listar","inferible":true},"QUERY.GRADO":{"descripcion":"Grado (pk)","resuelve_con":"docentes_grado_asignatura_listar","inferible":true},"QUERY.FUNCIONARIO":{"descripcion":"Docente (pk)","resuelve_con":"funcionarios_listar","inferible":true},"QUERY.DIA":{"descripcion":"Dia de la semana","resuelve_con":null,"inferible":true},"QUERY.DIAS_GRACIA":{"descripcion":"Dias de gracia","resuelve_con":null,"inferible":true},"QUERY.INCLUIR_INACTIVOS":{"descripcion":"Incluir inactivas (true/false)","resuelve_con":null,"inferible":true},"QUERY.ORDEN_POR":{"descripcion":"Campo de orden","resuelve_con":null,"inferible":true},"QUERY.ORDEN_ASC":{"descripcion":"Orden ascendente (true/false)","resuelve_con":null,"inferible":true},"QUERY.OFFSET":{"descripcion":"Desplazamiento","resuelve_con":null,"inferible":true},"QUERY.SIZE":{"descripcion":"Filas","resuelve_con":null,"inferible":true}}', FALSE),
    ('unidad_detalle', 'LECTURA', 'GET', '/planeador/unidades/:ID', 'PLANEADOR',
     'Devuelve el detalle de una unidad del planeador.',
     '{"PARAM.ID":{"descripcion":"Pk de la unidad","resuelve_con":"unidades_listar","inferible":false}}', FALSE),
    ('unidad_criterios_listar', 'LECTURA', 'GET', '/planeador/unidades/:ID/criterios', 'PLANEADOR',
     'Lista los criterios de evaluacion de una unidad. Resuelve pks de criterio.',
     '{"PARAM.ID":{"descripcion":"Pk de la unidad","resuelve_con":"unidades_listar","inferible":false},"QUERY.INCLUIR_INACTIVOS":{"descripcion":"Incluir inactivos (true/false)","resuelve_con":null,"inferible":true}}', FALSE),
    ('unidad_actividades_listar', 'LECTURA', 'GET', '/planeador/unidades/:ID/actividades', 'PLANEADOR',
     'Lista las actividades de una unidad. Resuelve pks de actividad dentro de la unidad.',
     '{"PARAM.ID":{"descripcion":"Pk de la unidad","resuelve_con":"unidades_listar","inferible":false},"QUERY.GRUPO":{"descripcion":"Grupo (pk)","resuelve_con":"docentes_grupos_listar","inferible":true},"QUERY.SEARCH":{"descripcion":"Texto del titulo","resuelve_con":null,"inferible":true},"QUERY.INCLUIR_INACTIVAS":{"descripcion":"Incluir inactivas (true/false)","resuelve_con":null,"inferible":true},"QUERY.ORDEN_POR":{"descripcion":"Campo de orden","resuelve_con":null,"inferible":true},"QUERY.ORDEN_ASC":{"descripcion":"Orden ascendente (true/false)","resuelve_con":null,"inferible":true},"QUERY.OFFSET":{"descripcion":"Desplazamiento","resuelve_con":null,"inferible":true},"QUERY.SIZE":{"descripcion":"Filas","resuelve_con":null,"inferible":true}}', FALSE),
    ('referente_curricular_planeador', 'LECTURA', 'GET', '/planeador/referente-curricular', 'PLANEADOR',
     'Devuelve el referente curricular que aplica a una asignatura y grado en un ano.',
     '{"QUERY.ANIO":{"descripcion":"Ano lectivo AAAA (un ano, no un id); omitelo para el ano en curso","resuelve_con":null,"inferible":true},"QUERY.ASIGNATURA":{"descripcion":"Asignatura (pk)","resuelve_con":"docentes_grado_asignatura_listar","inferible":true},"QUERY.GRADO":{"descripcion":"Grado (pk)","resuelve_con":"docentes_grado_asignatura_listar","inferible":true}}', FALSE),
    ('referentes_listar', 'LECTURA', 'POST', '/referentes-curriculares/query', 'REFERENTES_CURRICULARES',
     'Busca referentes curriculares por texto, estado, nivel, enfoque y tipo de evaluacion.',
     '{"BODY.FILTERS.SEARCH":{"descripcion":"Texto","resuelve_con":null,"inferible":true},"BODY.FILTERS.ESTADO":{"descripcion":"Estado","resuelve_con":null,"inferible":true},"BODY.FILTERS.NIVEL_EDUCATIVO":{"descripcion":"Nivel educativo (catalogo)","resuelve_con":"catalogo_valores","inferible":true},"BODY.FILTERS.ENFOQUE_PEDAGOGICO":{"descripcion":"Enfoque pedagogico (catalogo)","resuelve_con":"catalogo_valores","inferible":true},"BODY.FILTERS.TIPO_EVALUACION":{"descripcion":"Tipo de evaluacion (catalogo)","resuelve_con":"catalogo_valores","inferible":true},"BODY.SORTING.ID":{"descripcion":"Campo de orden","resuelve_con":null,"inferible":true},"BODY.SORTING.DESC":{"descripcion":"Orden descendente (true/false)","resuelve_con":null,"inferible":true},"BODY.PAGEINDEX":{"descripcion":"Numero de pagina","resuelve_con":null,"inferible":true},"BODY.PAGESIZE":{"descripcion":"Filas por pagina","resuelve_con":null,"inferible":true}}', FALSE),
    ('referente_enunciados_listar', 'LECTURA', 'GET', '/referentes-curriculares/:ID/enunciados', 'REFERENTES_CURRICULARES',
     'Lista los enunciados de un referente curricular. Resuelve pks de enunciado para evidencias.',
     '{"PARAM.ID":{"descripcion":"Pk del referente","resuelve_con":"referentes_listar","inferible":false},"QUERY.AREA":{"descripcion":"Area (pk)","resuelve_con":"catalogo_valores","inferible":true},"QUERY.GRADO":{"descripcion":"Grado (pk)","resuelve_con":"docentes_grado_asignatura_listar","inferible":true}}', FALSE),
    ('periodos_evaluacion_planeador', 'LECTURA', 'GET', '/planeador/periodos-evaluacion', 'PLANEADOR',
     'Lista los periodos de evaluacion de un grupo y un periodo academico.',
     '{"QUERY.PERIODO":{"descripcion":"Periodo academico (pk)","resuelve_con":"periodos_listar","inferible":true},"QUERY.GRUPO":{"descripcion":"Grupo (pk)","resuelve_con":"docentes_grupos_listar","inferible":true},"QUERY.ESTADO":{"descripcion":"Estado","resuelve_con":null,"inferible":true}}', FALSE),
    -- ===== ANALITICA nivel 1 =====
    ('planeador_estadisticas', 'ANALITICA', 'GET', '/planeador/actividades/stats', 'PLANEADOR',
     'Cuenta actividades del docente por estado. Todos los filtros son opcionales: si la persona no da fechas, grupo ni asignatura, llamala sin ellos en vez de preguntar. Consulta curada, no SQL.',
     '{"QUERY.FECHA_DESDE":{"descripcion":"Desde AAAA-MM-DD","resuelve_con":null,"inferible":true},"QUERY.FECHA_HASTA":{"descripcion":"Hasta AAAA-MM-DD","resuelve_con":null,"inferible":true},"QUERY.GRUPO":{"descripcion":"Grupo (pk)","resuelve_con":"docentes_grupos_listar","inferible":true},"QUERY.ASIGNATURA":{"descripcion":"Asignatura (pk)","resuelve_con":"docentes_grado_asignatura_listar","inferible":true},"QUERY.UNIDAD":{"descripcion":"Unidad (pk)","resuelve_con":"unidades_listar","inferible":true},"QUERY.GRADO_ASIGNATURA_PARES":{"descripcion":"Pares grado-asignatura","resuelve_con":"docentes_grado_asignatura_listar","inferible":true},"QUERY.DIAS_GRACIA":{"descripcion":"Dias de gracia","resuelve_con":null,"inferible":true}}', FALSE)
  ) AS v (codigo, tipo, http_method, path_template, menu_codigo, descripcion, parametros, confirma)
  JOIN public.microservice ms ON ms.serviceid = 'eval-col'
  JOIN public.query q
    ON q.microservice_id = ms.id_microservice
   AND q.http_method     = v.http_method
   AND q.path_template   = v.path_template
 ORDER BY v.codigo, q.id_query
ON CONFLICT (codigo) WHERE active = TRUE DO UPDATE SET
    tipo                  = EXCLUDED.tipo,
    query_uuid            = EXCLUDED.query_uuid,
    menu_codigo           = EXCLUDED.menu_codigo,
    descripcion_modelo    = EXCLUDED.descripcion_modelo,
    parametros            = EXCLUDED.parametros,
    requiere_confirmacion = EXCLUDED.requiere_confirmacion,
    ejemplos              = EXCLUDED.ejemplos,
    version               = EXCLUDED.version,
    modified_by           = 'migracion',
    modified_at           = CURRENT_TIMESTAMP;

-- ---------------------------------------------------------------------------
-- 2b. obligatorio: lo que la funcion destino exige de verdad (columna NOT NULL sin
--     default que el INSERT llena, o RAISE si IS NULL). Los PARAM.* son siempre
--     obligatorios. Va despues del upsert porque este reescribe parametros.
--     Observar: OBSERVACION es obligatoria solo si no hay evidencias (no se marca).
-- ---------------------------------------------------------------------------
UPDATE ai.herramienta h
   SET parametros = h.parametros || COALESCE(
           (SELECT jsonb_object_agg(e.key, e.value || '{"obligatorio": true}'::jsonb)
              FROM jsonb_each(h.parametros) e
             WHERE e.key LIKE 'PARAM.%'), '{}'::jsonb)
 WHERE h.active = TRUE
   AND h.parametros::text LIKE '%"PARAM.%';

UPDATE ai.herramienta h
   SET parametros = h.parametros || COALESCE((
         SELECT jsonb_object_agg(v.param, (h.parametros -> v.param) || '{"obligatorio": true}'::jsonb)
           FROM (VALUES
    ('crear_actividad_planeador', 'BODY.TITULO'),
    ('crear_actividad_planeador', 'BODY.FK_TASIGNATURA'),
    ('crear_actividad_planeador', 'BODY.FK_TLV_TIPO_ACTIVIDAD'),
    ('crear_actividad_planeador', 'BODY.FK_TLV_JERARQUIA'),
    ('crear_unidad_planeador', 'BODY.NOMBRE'),
    ('crear_unidad_planeador', 'BODY.FK_TASIGNATURA'),
    ('crear_unidad_planeador', 'BODY.FK_TGRADO'),
    ('ponderar_actividad_unidad', 'BODY.PONDERACION'),
    ('crear_criterio_unidad', 'BODY.DESCRIPCION'),
    ('crear_criterio_unidad', 'BODY.NIVELES'),
    ('vincular_enunciado_unidad', 'BODY.FK_REFERENTE_ENUNCIADO'),
    ('vincular_criterio_actividad', 'BODY.FK_TCRITERIO_UNIDAD'),
    ('vincular_evidencia_actividad', 'BODY.FK_REFERENTE_ENUNCIADO'),
    ('calificar_estudiante_actividad', 'BODY.CALIFICACION')
  ) AS v (codigo, param)
          WHERE v.codigo = h.codigo AND h.parametros ? v.param), '{}'::jsonb)
 WHERE h.active = TRUE;

-- de_sesion: fk que el agente pone desde la sesion si el modelo no la manda (ninguna
-- lectura le da al docente su propio funcionario antes de tener unidades).
UPDATE ai.herramienta h
   SET parametros = jsonb_set(h.parametros, ARRAY[v.param],
                              (h.parametros -> v.param) || jsonb_build_object('de_sesion', v.valor))
  FROM (VALUES ('crear_unidad_planeador', 'BODY.FK_TFUNCIONARIO', 'FUNCIONARIO')) AS v (codigo, param, valor)
 WHERE h.codigo = v.codigo AND h.active = TRUE AND h.parametros ? v.param;

-- Categoria real de cada fk de catalogo, la que valida fn_actividad_validar_catalogo: sin ella
-- el modelo la adivina (JERARQUIA es TIPO_JERARQUIA_ACTIVIDAD) y catalogo_valores vuelve vacio.
UPDATE ai.herramienta h
   SET parametros = h.parametros || (
         SELECT jsonb_object_agg(c.param, (h.parametros -> c.param) || jsonb_build_object('descripcion',
                    (h.parametros -> c.param ->> 'descripcion') || '; catalogo_valores con categoria ' || c.categoria))
           FROM (VALUES ('BODY.FK_TLV_TIPO_ACTIVIDAD', 'TIPO_ACTIVIDAD'),
                        ('BODY.FK_TLV_MODALIDAD', 'MODALIDAD'),
                        ('BODY.FK_TLV_JERARQUIA', 'TIPO_JERARQUIA_ACTIVIDAD'),
                        ('BODY.FK_TLV_TIPO_CALCULO', 'TIPO_CALCULO'),
                        ('BODY.FK_TLV_METODO_VALORACION', 'METODO_VALORACION'),
                        ('BODY.FK_TLV_INSTRUMENTO_EVALUACION', 'INSTRUMENTO_EVALUACION'),
                        ('BODY.FK_TLV_TIPO_EVIDENCIA', 'TIPO_EVIDENCIA'),
                        ('BODY.FK_TLV_CALCULO_DEFINITIVA', 'CALCULO_DEFINITIVA')) AS c (param, categoria)
          WHERE h.parametros ? c.param)
 WHERE h.active = TRUE
   AND h.parametros ?| ARRAY['BODY.FK_TLV_TIPO_ACTIVIDAD', 'BODY.FK_TLV_MODALIDAD', 'BODY.FK_TLV_JERARQUIA',
                             'BODY.FK_TLV_TIPO_CALCULO', 'BODY.FK_TLV_METODO_VALORACION',
                             'BODY.FK_TLV_INSTRUMENTO_EVALUACION', 'BODY.FK_TLV_TIPO_EVIDENCIA',
                             'BODY.FK_TLV_CALCULO_DEFINITIVA'];

-- ---------------------------------------------------------------------------
-- 2c. Escrituras que reemplazan un conjunto: la funcion destino da de baja lo que
--     no se incluye. Se permiten, pero la confirmacion lo dice; el resto queda sin aviso.
-- ---------------------------------------------------------------------------
UPDATE ai.herramienta h
   SET aviso_confirmacion = a.aviso
  FROM (SELECT h2.id, v.aviso
          FROM ai.herramienta h2
          LEFT JOIN (VALUES
    ('asignar_estudiantes_actividad', 'Reemplaza la lista: los estudiantes que no incluyas saldrán de la actividad junto con sus adaptaciones.'),
    ('editar_actividad_planeador', 'Si cambias los estudiantes, los que no incluyas saldrán de la actividad.'),
    ('actualizar_instrumento_actividad', 'Reemplaza el instrumento: la rúbrica, escala o lista de cotejo anterior se dará de baja.'),
    ('actualizar_adaptaciones_actividad', 'Reemplaza las adaptaciones: las que no incluyas se darán de baja.'),
    ('actualizar_materiales_actividad', 'Reemplaza los materiales: los que no incluyas se darán de baja.'),
    ('editar_unidad_planeador', 'Si cambias los enunciados, se quitarán las evidencias de las actividades ligadas a los que retires.'),
    ('observar_estudiante_actividad', 'Reemplaza la observación: los soportes anteriores que no incluyas se darán de baja.'),
    ('observar_grupo_actividad', 'Reemplaza la observación de cada estudiante: los soportes anteriores que no incluyas se darán de baja.')
          ) AS v (codigo, aviso) ON v.codigo = h2.codigo
         WHERE h2.active = TRUE) a
 WHERE a.id = h.id
   AND h.aviso_confirmacion IS DISTINCT FROM a.aviso;

-- ---------------------------------------------------------------------------
-- 3. ruta_ui: una fila por menu. Enriquece TMENU; la URL sale de academico_test.tmenu.
-- ---------------------------------------------------------------------------
INSERT INTO ai.ruta_ui (codigo, menu_codigo, descripcion, sinonimos, created_by)
SELECT v.codigo, v.menu_codigo, v.descripcion, v.sinonimos, 'migracion'
  FROM (VALUES
    ('establecimiento_educativo', 'ESTABLECIMIENTO_EDUCATIVO', 'Datos del establecimiento educativo: nombre, sedes y configuracion general.', ARRAY['colegio','institucion','escuela','EE']::TEXT[]),
    ('administracion', 'ADMINISTRACION', 'Administracion general del sistema.', ARRAY['administracion','configuracion general']::TEXT[]),
    ('usuarios', 'USUARIOS', 'Cuentas de usuario del sistema.', ARRAY['usuarios','cuentas','accesos']::TEXT[]),
    ('cobertura_educativa', 'COBERTURA_EDUCATIVA', 'Cobertura: estudiantes atendidos y matriculas por sede o grado.', ARRAY['cobertura','cupos']::TEXT[]),
    ('informes', 'INFORMES', 'Informes y reportes academicos: boletines y observaciones.', ARRAY['informe','reporte','boletin']::TEXT[]),
    ('gestion_academica', 'GESTION_ACADEMICA', 'Gestion academica: grados, grupos, asignaturas y planes.', ARRAY['gestion academica','grados','grupos','asignaturas','plan de estudios']::TEXT[]),
    ('establecimiento', 'ESTABLECIMIENTO', 'Ficha del establecimiento.', ARRAY['ficha','establecimiento']::TEXT[]),
    ('sedes_educativas', 'SEDES_EDUCATIVAS', 'Sedes del establecimiento y sus jornadas.', ARRAY['sedes','sede','jornadas','jornada']::TEXT[]),
    ('funcionarios', 'FUNCIONARIOS', 'Funcionarios: crear, editar y consultar docentes y personal.', ARRAY['colaborador','profesor','docente','personal','funcionario','empleado']::TEXT[]),
    ('periodos_academicos', 'PERIODOS_ACADEMICOS', 'Anos lectivos y periodos academicos.', ARRAY['periodo','ano lectivo','semestre','trimestre','bimestre']::TEXT[]),
    ('registro_actividad', 'REGISTRO_ACTIVIDAD', 'Historial de cambios visible para el usuario.', ARRAY['auditoria','registro','historial']::TEXT[]),
    ('config_roles_menus', 'CONFIG_ROLES_MENUS', 'Configuracion de roles y menus.', ARRAY['roles','menus','permisos']::TEXT[]),
    ('listas_valor', 'LISTAS_VALOR', 'Listas de valor: catalogos del sistema.', ARRAY['catalogo','listas','valores']::TEXT[]),
    ('equipo', 'EQUIPO', 'Equipo de trabajo del establecimiento.', ARRAY['equipo']::TEXT[]),
    ('roles', 'ROLES', 'Roles del sistema.', ARRAY['roles','perfiles']::TEXT[]),
    ('pre_matricula', 'PRE_MATRICULA', 'Pre-matricula de estudiantes.', ARRAY['preinscripcion','pre matricula']::TEXT[]),
    ('inscritos', 'INSCRITOS', 'Estudiantes inscritos.', ARRAY['inscritos','inscripciones']::TEXT[]),
    ('matricula', 'MATRICULA', 'Matricula de estudiantes en grupos.', ARRAY['matricula','matricular','estudiantes']::TEXT[]),
    ('asistencia', 'ASISTENCIA', 'Asistencia de estudiantes.', ARRAY['asistencia','faltas']::TEXT[]),
    ('referentes_curriculares', 'REFERENTES_CURRICULARES', 'Referentes curriculares: enunciados, niveles y criterios.', ARRAY['referente','referentes','estandares']::TEXT[]),
    ('planeador', 'PLANEADOR', 'Planeador: unidades, actividades, calificacion, asistencia y observaciones.', ARRAY['planeador','planear','actividades','unidades','evaluacion','calificar','notas']::TEXT[]),
    ('asistencias', 'ASISTENCIAS', 'Registro de asistencias por sesion.', ARRAY['asistencias','asistencia por sesion']::TEXT[])
  ) AS v (codigo, menu_codigo, descripcion, sinonimos)
ON CONFLICT (codigo) WHERE active = TRUE DO UPDATE SET
    menu_codigo = EXCLUDED.menu_codigo,
    descripcion = EXCLUDED.descripcion,
    sinonimos   = EXCLUDED.sinonimos,
    modified_by = 'migracion',
    modified_at = CURRENT_TIMESTAMP;

-- ---------------------------------------------------------------------------
-- 4. ui_formulario. FRONT: los campos los manda la UI. DB: campos_fuente es la herramienta de
--    lectura que da su configuracion con el gate del usuario (no se llama a la funcion directa).
--    funcionario.crear no lleva herramienta: crear funcionario no es escritura del agente.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM ai.ruta_ui WHERE codigo = 'funcionarios' AND active)
       OR NOT EXISTS (SELECT 1 FROM ai.ruta_ui WHERE codigo = 'planeador' AND active) THEN
        RAISE EXCEPTION 'ai.ruta_ui sin las filas funcionarios/planeador: no se pueden enlazar los formularios';
    END IF;
END $$;

INSERT INTO ai.ui_formulario (codigo, ruta_ui_id, origen, campos_fuente, herramienta_escritura, created_by)
SELECT v.codigo, r.id, v.origen, v.campos_fuente, h.id, 'migracion'
  FROM (VALUES
    ('funcionario.crear',  'funcionarios', 'FRONT', NULL::VARCHAR, NULL::VARCHAR),
    ('funcionario.editar', 'funcionarios', 'FRONT', NULL::VARCHAR, 'editar_funcionario'),
    ('planeador.actividad', 'planeador', 'DB', 'actividad_configuracion', 'editar_actividad_planeador'),
    ('planeador.unidad',    'planeador', 'DB', 'unidad_detalle',          'editar_unidad_planeador')
  ) AS v (codigo, ruta, origen, campos_fuente, herramienta)
  JOIN ai.ruta_ui r ON r.codigo = v.ruta AND r.active = TRUE
  LEFT JOIN ai.herramienta h ON h.codigo = v.herramienta AND h.active = TRUE
ON CONFLICT (codigo) WHERE active = TRUE DO UPDATE SET
    ruta_ui_id            = EXCLUDED.ruta_ui_id,
    origen                = EXCLUDED.origen,
    campos_fuente         = EXCLUDED.campos_fuente,
    herramienta_escritura = EXCLUDED.herramienta_escritura,
    modified_by           = 'migracion',
    modified_at           = CURRENT_TIMESTAMP;
