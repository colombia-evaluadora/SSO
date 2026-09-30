-- ===========================================================================
-- V444 - Funcionarios (2/3): el detalle trae sus archivos complementarios.
--
--   fn_usu_empleado_buscar_por_pk  gana la columna `archivos`
--
--
-- QUE CAMBIA
--   Una columna JSONB al final del RETURNS TABLE y su COALESCE(JSONB_AGG(...))
--   en la consulta, justo despues del de `permisos` y con la misma forma: una
--   subconsulta correlacionada al funcionario, '[]' cuando no hay nada. El
--   resto del cuerpo -- el gate por sedes accesibles, el recorte del array de
--   permisos, los LEFT JOIN de catalogos -- queda intacto.
--
--   Cada elemento trae el id del enlace (el que se le pasa al endpoint de
--   borrado), el id del TARCHIVO (el que se le pasa a /files para
--   descargarlo), el nombre y la descripcion que puso el usuario, el nombre y
--   el peso del fichero real, y cuando se subio.
--
--
-- POR QUE EMBEBIDO Y NO SOLO EN SU ENDPOINT
--   Para que la ficha se pinte con una sola llamada, que es como ya viaja
--   `permisos`. La lista suelta (fn_funcionario_archivo_listar, V443) sigue
--   existiendo para refrescar despues de subir o quitar uno sin recargar todo.
--
--
-- HACE FALTA DROP
--   CREATE OR REPLACE no puede agregar una columna al RETURNS TABLE: da 42P13
--   ("cannot change return type of existing function"). Por eso el DROP
--   explicito de abajo, con la firma completa.
--
-- Idempotente: el DROP ... IF EXISTS mas el CREATE se pueden repetir.
-- ===========================================================================

DROP FUNCTION IF EXISTS academico_test.fn_usu_empleado_buscar_por_pk(BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_usu_empleado_buscar_por_pk(p_pk_usuario_solicitante bigint, p_pk_funcionario bigint)
 RETURNS TABLE(pk_empleado bigint, fk_tlv_tipo_documento bigint, tipo_documento_nombre character varying, identificacion character varying, primer_nombre character varying, segundo_nombre character varying, primer_apellido character varying, segundo_apellido character varying, fecha_nacimiento date, fk_tlv_genero bigint, genero_nombre character varying, correo_electronico character varying, telefono character varying, fk_estado character varying, estado_label character varying, fk_establecimiento bigint, fk_tlv_clase_funcionario bigint, clase_funcionario_nombre character varying, fk_tlv_nivel_esenanza bigint, nivel_esenanza_nombre character varying, fk_tlv_grado_escalafon bigint, grado_escalafon_nombre character varying, fk_tlv_nivel_educativo bigint, nivel_educativo_nombre character varying, fk_tlv_fuente_recurso bigint, fuente_recurso_nombre character varying, fk_tlv_cargo bigint, cargo_nombre character varying, fk_tlv_tipo_vinculacion bigint, tipo_vinculacion_nombre character varying, direccion character varying, fk_tarchivo_foto bigint, permisos jsonb, archivos jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_pk_usuario        BIGINT;
    v_active            BOOLEAN;
    v_visible           BOOLEAN;
    v_nivel             INT;
    v_es_super          BOOLEAN;
    -- REV4 -- todas las sedes donde el solicitante tiene autoridad (las de
    -- sus EE accesibles, mas la suya propia si es coordinador). Se usa
    -- para acotar el array `permisos`: antes, una vez que el gate dejaba
    -- ver a un funcionario compartido entre EE (por UN permiso en un EE
    -- accesible), se devolvian TODOS sus permisos, incluidos los de
    -- sedes/EE totalmente ajenos al solicitante.
    v_sedes_accesibles  BIGINT[];
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;
    IF p_pk_funcionario IS NULL OR p_pk_funcionario <= 0 THEN
        RAISE EXCEPTION 'p_pk_funcionario es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    SELECT f.FK_TUSUARIO, f.ACTIVE
      INTO v_pk_usuario, v_active
      FROM academico_test.TFUNCIONARIO f
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario;

    IF NOT FOUND OR v_active = FALSE THEN
        RAISE EXCEPTION 'No se encontro un funcionario activo con ese identificador'
            USING ERRCODE = 'P0002';
    END IF;

    -- REV2 -- gate por "union de EE accesibles" (mismo patron que
    -- fn_usu_empleados_listar/fn_fun_baja_establecimiento), ya NO por
    -- TFUNCIONARIO.FK_ESTABLECIMIENTO: esa columna quedo sin proposito,
    -- siempre NULL desde que TFUNCIONARIO paso a ser una fila por persona
    -- (antes esto dejaba a rector/secretaria SIEMPRE fuera del gate, ya
    -- que v_fk_ee IS NOT NULL nunca se cumplia -- solo super-admin podia
    -- ver el detalle de un funcionario).
    -- REV7 -- gate por el modelo dinamico de permisos (CU-86e2zenhr).
    -- La CAPABILITY (menu FUNCIONARIOS, accion VER) sustituye a
    -- fn_puede_afectar_usuarios, que era la lista fija de roles 1,2,3,7,8,9.
    -- Es la que responde la pregunta de la REV5 --"¿tengo un rol que me
    -- habilite a consultar funcionarios?"-- y ahora se administra desde la
    -- pantalla de roles del super-admin, sin tocar SQL.
    --
    -- Se mantiene la REV5 a proposito: este gate NO pregunta si el
    -- funcionario objetivo esta a mi alcance. Por eso no se usa aca
    -- fn_assert_permiso_funcionario, que si lo hace (y ademas aplica rango):
    -- reintroduciria el fallo que la REV5 arreglo -- el autocompletado por
    -- documento del alta (findPersonByDocument) reventando con 42501 cuando
    -- la persona ya era funcionario en otro establecimiento. El alcance
    -- sigue acotando lo que si es sede-especifico: el array `permisos`,
    -- via v_sedes_accesibles (REV4).
    v_nivel    := academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante);
    v_es_super := v_nivel IS NOT NULL AND v_nivel <= 1;   -- nivel 0 y 1: sin recorte

    IF v_nivel IS NULL THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    IF v_nivel <> 0
       AND NOT academico_test.fn_usuario_puede_en_menu(
                   p_pk_usuario_solicitante, 'FUNCIONARIOS', 'VER') THEN
        RAISE EXCEPTION 'El usuario no tiene permiso para ver en el modulo FUNCIONARIOS'
            USING ERRCODE = '42501';
    END IF;

    IF NOT v_es_super THEN
        WITH ee_accesibles AS (
            -- REV7 -- alcance de ESTABLECIMIENTO por el modelo dinamico. Da
            -- filas para nivel 2 (rector, jefe de sistema, auxiliar) y vacio
            -- para nivel 3, que se acota por sede en sedes_coordinador.
            SELECT DISTINCT ee.establecimiento_id AS PK_ESTABLECIMIENTO
              FROM academico_test.fn_usuario_ee_accesibles(p_pk_usuario_solicitante) ee
        ),
        -- REV3 -- coordinador (rol 11) de una sede puntual: alcance de
        -- SEDE, no de establecimiento.
        sedes_coordinador AS (
            -- REV7 -- alcance de SEDE por el modelo dinamico. Sustituye al
            -- "rol 11 en TSEDE_USUARIO" fijo: ahora vale para cualquier rol
            -- de nivel 3 (coordinador, psico-orientador, jefe de area,
            -- director de grupo, docente) con el menu FUNCIONARIOS concedido.
            SELECT DISTINCT sj.sede_id AS FK_TSEDE
              FROM academico_test.fn_usuario_sedes_jornadas_accesibles(p_pk_usuario_solicitante) sj
        )
        SELECT
            -- REV5 -- el gate deja de preguntar "¿este funcionario esta a mi
            -- alcance?" y pasa a preguntar "¿tengo un rol que me habilite a
            -- consultar funcionarios?". La ficha de una persona (datos de
            -- TUSUARIO + info complementaria de TFUNCIONARIO) no es
            -- informacion sede-especifica: lo que SI lo es son sus permisos,
            -- y esos ya van acotados por v_sedes_accesibles en el array
            -- `permisos` de mas abajo (REV4). Quien no comparte sede con la
            -- persona la ve con `permisos: []`.
            --
            -- Lo que este gate protegia de verdad -- que alguien pudiera dar
            -- o quitar permisos de sedes ajenas -- se valida donde
            -- corresponde: fn_fun_permisos_actualizar comprueba sede por
            -- sede cada operacion, y fn_sede_usuario_crear /
            -- fn_sede_usuario_soft_delete tienen ademas su propio gate. El
            -- gate estricto aca no aportaba a eso y si rompia un flujo real:
            -- el autocompletado por documento del alta de funcionario
            -- (findPersonByDocument) encuentra a la persona sin gate alguno,
            -- llena el formulario, y acto seguido el front dispara este GET
            -- por PK -- que reventaba con 42501 cuando la persona ya era
            -- funcionario en otro establecimiento, dejando el alta a medias.
            -- REV7 -- ya no entra fn_puede_afectar_usuarios (lista fija de
            -- roles 1,2,3,7,8,9): esa pregunta la responde la capability
            -- comprobada arriba. Aqui solo queda el ALCANCE.
            (
                EXISTS (SELECT 1 FROM ee_accesibles)
                OR EXISTS (SELECT 1 FROM sedes_coordinador)
            ),
            -- REV4 -- union de todas las sedes con autoridad, para acotar
            -- el array `permisos` mas abajo.
            ARRAY(
                SELECT s.PK_TSEDE
                  FROM academico_test.TSEDE s
                 WHERE s.ACTIVE = TRUE AND s.FK_TESTABLECIMIENTO IN (SELECT PK_ESTABLECIMIENTO FROM ee_accesibles)
                UNION
                SELECT FK_TSEDE FROM sedes_coordinador
            )
        INTO v_visible, v_sedes_accesibles;

        IF NOT v_visible THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    RETURN QUERY
    SELECT
        f.PK_TFUNCIONARIO,
        u.FK_TLV_TIPO_DOCUMENTO, tdoc.NOMBRE,
        u.IDENTIFICACION,
        u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO,
        u.FECHA_NACIMIENTO,
        u.FK_TLV_GENERO, gen.NOMBRE,
        u.CORREO_ELECTRONICO, u.TELEFONO,
        u.ESTADO::VARCHAR,
        (CASE u.ESTADO WHEN 'A' THEN 'ACTIVE' WHEN 'I' THEN 'SUSPENDED' ELSE NULL END)::VARCHAR,
        f.FK_ESTABLECIMIENTO,
        f.FK_TLV_CLASE_FUNCIONARIO, clase.NOMBRE,
        f.FK_TLV_NIVEL_ESENANZA, nesenanza.NOMBRE,
        f.FK_TLV_GRADO_ESCALAFON, grado.NOMBRE,
        f.FK_TLV_NIVEL_EDUCATIVO, neducativo.NOMBRE,
        f.FK_TLV_FUENTE_RECURSO, fuente.NOMBRE,
        f.FK_TLV_CARGO, cargo.NOMBRE,
        f.FK_TLV_TIPO_VINCULACION, vinculacion.NOMBRE,
        f.DIRECCION,
        u.FK_TARCHIVO,
        COALESCE(
            (SELECT jsonb_agg(
                        jsonb_build_object(
                            'id', su.PK_TSEDE_USUARIO,
                            'orden', su.ORDEN,
                            'role', jsonb_build_object('id', r.PK_TROL, 'code', r.CODIGO, 'name', r.NOMBRE),
                            'campus', jsonb_build_object(
                                'id', s.PK_TSEDE, 'name', s.NOMBRE, 'dane', s.CODIGO,
                                'zone', CASE WHEN zn.PK_LISTA_VALOR IS NULL THEN NULL
                                             ELSE jsonb_build_object('id', zn.PK_LISTA_VALOR, 'code', zn.VALOR, 'name', zn.NOMBRE) END,
                                'neighborhood', s.BARRIO, 'commune', s.COMUNA,
                                'address', s.DIRECCION, 'phone', s.TELEFONO
                            ),
                            'workSchedule', jsonb_build_object('id', jor.PK_LISTA_VALOR, 'code', jor.VALOR, 'name', jor.NOMBRE),
                            'status', CASE su.TLV_ESTADO WHEN 'ACTIVO' THEN 'ACTIVE' ELSE 'SUSPENDED' END
                        )
                        ORDER BY su.ORDEN
                    )
               FROM academico_test.TSEDE_USUARIO su
               JOIN academico_test.TSEDE         s   ON s.PK_TSEDE = su.FK_TSEDE
               JOIN academico_test.TROL          r   ON r.PK_TROL  = su.FK_TROL
               JOIN academico_test.TLISTA_VALOR  jor ON jor.PK_LISTA_VALOR = su.FK_TLV_JORNADA
          LEFT JOIN academico_test.TLISTA_VALOR  zn  ON zn.PK_LISTA_VALOR = s.FK_TLV_ZONA
              WHERE su.FK_TUSUARIO = u.PK_TUSUARIO
                AND su.ACTIVE      = TRUE
                AND su.FK_TROL >= 7 AND su.FK_TROL NOT IN (15, 16)
                AND (v_es_super OR su.FK_TSEDE = ANY(v_sedes_accesibles))),
            '[]'::JSONB
        ),
        -- Los complementarios de la ficha (V443). Van embebidos para que el
        -- detalle se pinte con una sola llamada, igual que `permisos`; la
        -- lista tambien existe suelta en fn_funcionario_archivo_listar, para
        -- refrescarla despues de subir o quitar uno.
        COALESCE(
            (SELECT JSONB_AGG(
                        JSONB_BUILD_OBJECT(
                            'id',          fa.PK_TFUNCIONARIO_ARCHIVO,
                            'fileId',      fa.FK_TARCHIVO,
                            'name',        fa.NOMBRE,
                            'description', fa.DESCRIPCION,
                            'fileName',    ar.NOMBRE,
                            'size',        ar.PESO,
                            'createdAt',   fa.CREATED_AT
                        )
                        ORDER BY fa.CREATED_AT DESC, fa.PK_TFUNCIONARIO_ARCHIVO DESC
                    )
               FROM academico_test.TFUNCIONARIO_ARCHIVO fa
               JOIN academico_test.TARCHIVO ar ON ar.PK_TARCHIVO = fa.FK_TARCHIVO
              WHERE fa.FK_TFUNCIONARIO = f.PK_TFUNCIONARIO
                AND fa.ACTIVE = TRUE),
            '[]'::JSONB
        )
      FROM academico_test.TFUNCIONARIO f
      JOIN academico_test.TUSUARIO      u ON u.PK_TUSUARIO = f.FK_TUSUARIO
 LEFT JOIN academico_test.TLISTA_VALOR  tdoc         ON tdoc.PK_LISTA_VALOR = u.FK_TLV_TIPO_DOCUMENTO
 LEFT JOIN academico_test.TLISTA_VALOR  gen          ON gen.PK_LISTA_VALOR  = u.FK_TLV_GENERO
 LEFT JOIN academico_test.TLISTA_VALOR  clase        ON clase.PK_LISTA_VALOR = f.FK_TLV_CLASE_FUNCIONARIO
 LEFT JOIN academico_test.TLISTA_VALOR  nesenanza    ON nesenanza.PK_LISTA_VALOR = f.FK_TLV_NIVEL_ESENANZA
 LEFT JOIN academico_test.TLISTA_VALOR  grado        ON grado.PK_LISTA_VALOR = f.FK_TLV_GRADO_ESCALAFON
 LEFT JOIN academico_test.TLISTA_VALOR  neducativo   ON neducativo.PK_LISTA_VALOR = f.FK_TLV_NIVEL_EDUCATIVO
 LEFT JOIN academico_test.TLISTA_VALOR  fuente       ON fuente.PK_LISTA_VALOR = f.FK_TLV_FUENTE_RECURSO
 LEFT JOIN academico_test.TLISTA_VALOR  cargo        ON cargo.PK_LISTA_VALOR = f.FK_TLV_CARGO
 LEFT JOIN academico_test.TLISTA_VALOR  vinculacion  ON vinculacion.PK_LISTA_VALOR = f.FK_TLV_TIPO_VINCULACION
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario;
END;
$function$
