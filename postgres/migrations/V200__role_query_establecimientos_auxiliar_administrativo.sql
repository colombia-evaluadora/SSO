-- ===========================================================================
-- V200 - role_query: la secretaria de un EE puede listar y exportar
--        establecimientos.
--
--   POST /establecimientos/query   (q-mspam6ud-e0dpwwnm)          <- la tabla
--   POST /establecimientos/reporte (eval-col-establecimientos-reporte-001)
--
--
-- EL SINTOMA
--   Entrando como secretaria de un establecimiento, la tabla de
--   establecimientos respondia 403 "No tienes acceso a esta consulta, o no
--   existe". Reportado en produccion.
--
--
-- DONDE MORIA
--   Ese texto no es de PL/pgSQL: lo arma CatalogClient (query-service) cuando
--   sso-admin le responde 403 al pedirle la query por uuid -- o sea, cuando
--   quien llama no tiene ningun rol atado a ella. La peticion nunca llego a
--   Postgres, asi que ni los permisos de menu ni el alcance por rol tuvieron
--   nada que ver. Se verifico en test sobre cinco secretarias reales:
--
--     TSEDE_USUARIO   AUXILIAR_ADMINISTRATIVO (nivel 2)
--     ee_lectura      1 establecimiento (el suyo)
--     menu VER        true
--     roles del JWT   CEVAL-AUXILIAR_ADMINISTRATIVO
--
--   Todo en verde del lado SQL. Lo que faltaba era la fila en role_query.
--
--
-- POR QUE FALTABA
--   La lista de roles de estas dos queries se armo a mano y quedo desfasada.
--   Se nota comparandola con su hermana /establecimientos/opciones, que SI
--   tiene AUXILIAR_ADMINISTRATIVO: por eso a la secretaria le cargaba el
--   combo de establecimientos pero no la tabla.
--
--   La "secretaria" de un EE no es el TROL SECRETARIA (PK 17, sin categoria,
--   que nadie usa): por decision explicita de la V111,
--   TESTABLECIMIENTO.FK_TFUNCIONARIO_SECRETARIA mapea a
--   CEVAL-AUXILIAR_ADMINISTRATIVO.
--
--
-- POR QUE ES SEGURO
--   role_query es la puerta gruesa -- dice quien puede INVOCAR la consulta,
--   no que datos recibe. Que establecimientos ve lo sigue decidiendo
--   fn_usuario_ee_lectura dentro de fn_est_listar, que para un rol de
--   categoria establecimiento devuelve solo los EE donde la persona es
--   rector, secretaria o tiene un TSEDE_USUARIO. Una secretaria sigue viendo
--   exactamente su establecimiento.
--
--   Es el criterio de siempre para role_query: abre la capa del JWT y deja
--   que el gate PL/pgSQL de cada funcion decida el resto.
--
--
-- LO QUE NO SE TOCA
--   Las dos listas tienen ademas otras diferencias contra /opciones -- les
--   falta JEFE_SISTEMA_ESTABLECIMIENTO y DIRECTOR_ENTE_TERRITORIAL, y en
--   cambio incluyen JEFE_AREA, que es un rol de sede. No se corrigen aca:
--   dar o quitar acceso a un rol es una decision de negocio y el reporte fue
--   sobre la secretaria.
--
-- POSICION EN LA SECUENCIA
--   Va en el hueco de la 200 a pedido del equipo. Se verifico que las dos
--   queries ya existen para entonces -- las crea la V98
--   (query_endpoints_establecimientos) --, porque un INSERT ... SELECT que
--   no encuentra la fila de public.query no falla: no inserta nada y la
--   migracion queda muda.
--
--   Ojo al desplegar donde ya se aplicaron migraciones posteriores: Flyway
--   la va a ver fuera de orden y la rechaza salvo que corra con
--   outOfOrder=true.
--
-- Idempotente: el NOT EXISTS evita duplicar la fila si ya esta.
-- ===========================================================================

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.role r ON r.name = 'CEVAL-AUXILIAR_ADMINISTRATIVO'
 WHERE q.uuid IN ('q-mspam6ud-e0dpwwnm',
                  'eval-col-establecimientos-reporte-001')
   AND NOT EXISTS (
       SELECT 1 FROM public.role_query rq
        WHERE rq.query_id = q.id_query AND rq.role_id = r.id_role
   );
