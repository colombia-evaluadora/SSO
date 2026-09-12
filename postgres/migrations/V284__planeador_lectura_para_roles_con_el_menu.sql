-- ===========================================================================
-- V284 - el planeador se puede ABRIR desde los roles que ya tienen su menu.
--        Hoy un rector ve la opcion "Planeador", entra, y cada peticion de
--        la pantalla responde 403.
--
-- EL SINTOMA
--   Un rector abre Gestion Academica > Planeador y la pantalla muestra
--   "Ocurrio un error al cargar las actividades". En la consola, todas las
--   llamadas de esa vista fallan igual:
--
--       GET /planeador/actividades/mias?dia=...   403
--       GET /planeador/actividades/stats          403
--       GET /planeador/unidades/tabs              403
--       GET /planeador/actividades/calendario     403
--
--       {"code":"403 FORBIDDEN","message":"El catalogo rechazo la consulta: "}
--
--   Reproducido en produccion con un rector real: el JWT trae CEVAL-RECTOR
--   correctamente, asi que no es un problema de sesion ni de sincronizacion
--   de roles -- es role_query, que no lo autoriza sobre esos endpoints.
--
-- NO ES DRIFT ENTRE ENTORNOS
--   Conviene decirlo porque es lo primero que uno sospecha: produccion y el
--   servidor de pruebas tienen EXACTAMENTE los mismos permisos en todos los
--   endpoints del planeador. Un rector recibiria el mismo 403 en pruebas.
--   No hay nada que copiar de un entorno al otro; lo que esta desalineado es
--   role_query respecto al resto del modelo de permisos.
--
-- LA INCOHERENCIA REAL
--   El menu PLANEADOR esta concedido en TROL_MENU a cuatro roles, pero solo
--   dos tienen las queries que ese menu necesita:
--
--       DOCENTE                        menu + queries   OK
--       SUPER_ADMINISTRADOR            menu + queries   OK
--       RECTOR                         menu SIN queries -> 403
--       JEFE_SISTEMA_ESTABLECIMIENTO   menu SIN queries -> 403
--
--   Es el mismo patron que ya aparecio con los funcionarios: el sidebar se
--   pinta desde una fuente (TROL_MENU / fn_list_my_menus) y el contenido se
--   autoriza desde otra (role_query). Cuando solo se actualiza una, el
--   usuario ve la puerta pero no puede abrirla.
--
-- POR QUE CONCEDER Y NO QUITAR EL MENU
--   Porque el resto del modelo ya da por hecho que estos perfiles entran.
--   fn_actividad_listar_docente -- la funcion detras de /mias -- hace
--   exactamente esto:
--
--       PERFORM fn_assert_permiso_seccion(solicitante, 'PLANEADOR', 'VER');
--       v_fk_tfuncionario := fn_funcionario_actual(solicitante);
--       IF v_fk_tfuncionario IS NULL THEN  -> devuelve 0 filas
--
--   Es decir: valida la capability PLANEADOR/VER (que el rector SI tiene,
--   por TROL_MENU) y para quien no es docente devuelve vacio en vez de
--   fallar. La funcion ya esta escrita para que entren perfiles sin
--   actividades propias. El unico que lo impide es el gate del catalogo.
--
--   Resultado esperado tras esta migracion: el rector abre el planeador y ve
--   su propia vista, vacia si no imparte clases. Sin error.
--
-- SOLO LECTURA
--   Se conceden unicamente los 31 endpoints GET del planeador. Los de
--   escritura (POST/PUT/PATCH de actividades, unidades, calificaciones) NO
--   se tocan: el sintoma reportado es de lectura, y ampliar la escritura a
--   un rector es una decision de negocio distinta que merece plantearse
--   aparte. Si mas adelante se necesita, se anaden esos verbos.
--
-- NUMERACION
--   Ocupa el hueco libre V284, que es POSTERIOR a V282 -- la ultima
--   migracion que crea queries de /planeador/ en el repo. Los huecos mas
--   bajos disponibles (209, 229, 256-269) correrian ANTES de que esas filas
--   de public.query existan, y el INSERT seria un no-op silencioso: el
--   mismo fallo que el CI rechazo cuando una migracion de esta serie se
--   numero sin mirar sus dependencias.
--
-- IDEMPOTENTE
--   ON CONFLICT DO NOTHING. Empareja por (serviceid, ruta, metodo) y por
--   nombre de rol, nunca por id -- no son estables entre entornos.
-- ===========================================================================

INSERT INTO public.role_query (role_id, query_id)
SELECT DISTINCT r.id_role, q.id_query
  FROM (VALUES
            ('/planeador/actividades'),
            ('/planeador/actividades/:ID'),
            ('/planeador/actividades/:ID/calificaciones'),
            ('/planeador/actividades/:ID/configuracion'),
            ('/planeador/actividades/:ID/instrumento'),
            ('/planeador/actividades/:ID/materiales-reutilizables'),
            ('/planeador/actividades/calendario'),
            ('/planeador/actividades/estudiantes/:ID/nota'),
            ('/planeador/actividades/huerfanas'),
            ('/planeador/actividades/mias'),
            ('/planeador/actividades/stats'),
            ('/planeador/actividades/tablero'),
            ('/planeador/asignaturas/:ID/ponderacion-disponible'),
            ('/planeador/docentes/grado-asignatura'),
            ('/planeador/docentes/grupos'),
            ('/planeador/periodos-evaluacion'),
            ('/planeador/planilla/calificaciones'),
            ('/planeador/planilla/columnas'),
            ('/planeador/referente-curricular'),
            ('/planeador/unidades'),
            ('/planeador/unidades/:ID'),
            ('/planeador/unidades/:ID/actividades'),
            ('/planeador/unidades/:ID/actividades-disponibles'),
            ('/planeador/unidades/:ID/configuracion-actividad'),
            ('/planeador/unidades/:ID/contenidos'),
            ('/planeador/unidades/:ID/criterios'),
            ('/planeador/unidades/:ID/objetivos'),
            ('/planeador/unidades/:ID/ponderacion-disponible'),
            ('/planeador/unidades/:ID/referente'),
            ('/planeador/unidades/:ID/valoraciones'),
            ('/planeador/unidades/tabs')
       ) AS d(ruta)
  CROSS JOIN (VALUES
            ('CEVAL-RECTOR'),
            ('CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO')
       ) AS roles(nombre)
  JOIN public.role r          ON r.name = roles.nombre
  JOIN public.microservice m  ON m.serviceid = 'eval-col'
  JOIN public.query q         ON q.microservice_id = m.id_microservice
                             AND q.path_template   = d.ruta
                             AND q.http_method     = 'GET'
ON CONFLICT DO NOTHING;

DO $$
DECLARE
    v_rector BIGINT;
    v_jefe   BIGINT;
BEGIN
    SELECT count(*) INTO v_rector
      FROM public.role_query rq
      JOIN public.role r  ON r.id_role  = rq.role_id
      JOIN public.query q ON q.id_query = rq.query_id
     WHERE r.name = 'CEVAL-RECTOR' AND q.path_template LIKE '/planeador/%' AND q.http_method = 'GET';

    SELECT count(*) INTO v_jefe
      FROM public.role_query rq
      JOIN public.role r  ON r.id_role  = rq.role_id
      JOIN public.query q ON q.id_query = rq.query_id
     WHERE r.name = 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO' AND q.path_template LIKE '/planeador/%' AND q.http_method = 'GET';

    RAISE NOTICE 'V284: GET de planeador -- RECTOR=% JEFE_SISTEMA_ESTABLECIMIENTO=% (se esperaban 31)',
        v_rector, v_jefe;

    IF v_rector < 31 THEN
        RAISE WARNING 'V284: CEVAL-RECTOR quedo con % de 31 endpoints. Revisa que las queries de /planeador/ existan en public.query y que el rol se llame asi exactamente.', v_rector;
    END IF;
END $$;
