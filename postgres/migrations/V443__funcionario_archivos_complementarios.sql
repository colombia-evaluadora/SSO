-- ===========================================================================
-- V443 - Funcionarios (1/3): archivos complementarios, sin limite de cantidad.
--
--   fn_funcionario_archivo_crear(usuario, funcionario, archivo, nombre, desc)
--   fn_funcionario_archivo_eliminar(usuario, pk)
--   fn_funcionario_archivo_listar(usuario, funcionario)
--
--
-- LA TABLA YA EXISTIA
--   TFUNCIONARIO_ARCHIVO estaba en el esquema desde antes, vacia y sin una
--   sola funcion que la tocara: PK, FKs a TFUNCIONARIO y TARCHIVO, indices
--   por funcionario, por archivo y uno parcial sobre ACTIVE. No hace falta
--   DDL; esto solo le pone las funciones encima.
--
--   A diferencia de TMATRICULA_ARCHIVO, no tiene FK_TLV_TIPO_ARCHIVO sino
--   NOMBRE y DESCRIPCION, los dos NOT NULL. Encaja mejor con lo que se pidio
--   -- adjuntos libres, sin catalogo de tipos --, asi que se respeta: el
--   nombre cae al del propio TARCHIVO si no lo mandan, y la descripcion a
--   cadena vacia.
--
--
-- UNO POR PETICION, EN BUCLE
--   La subida va de a un archivo, igual que
--   POST /cobertura-academica/matricula/:ID/documentos. No es una decision de
--   diseno sino el limite que ya documenta docs/archivos/subida-archivos-a-
--   queries.md seccion 10: param_types no tiene un tipo FILE[] con el que
--   declarar un campo multi-archivo. El front llama el endpoint en bucle.
--
--   El tamaño maximo NO se configura aca ni por clasificacion: es global de
--   file-service (FILES_MAX_FILE_SIZE, 25MB por archivo; FILES_MAX_REQUEST_
--   SIZE, 30MB por peticion), asi que este endpoint hereda exactamente los
--   mismos limites que la subida de matricula.
--
--
-- EL GATE
--   Menu 'FUNCIONARIOS' -- VER para listar, EDITAR para crear y eliminar --,
--   con scope sobre el establecimiento del funcionario, que TFUNCIONARIO ya
--   guarda en FK_ESTABLECIMIENTO. Mismo modelo que
--   fn_fun_enlazar_establecimiento.
--
--
-- LA ETIQUETA DE AUDITORIA
--   Crear y eliminar declaran la suya, cada una justo antes de su escritura y
--   despues de todas las validaciones, como pide
--   docs/auditoria/etiqueta-cambios-por-funcion.md. No son helpers internos:
--   cada una es el punto de entrada de su propio endpoint, una llamada = una
--   accion del usuario, asi que no hay riesgo de que se pisen entre si.
--
-- Idempotente: CREATE OR REPLACE. Las tres llevan DROP previo por si una
-- version anterior declaro otra firma o retorno (42P13).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) Crear.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_funcionario_archivo_crear(
    BIGINT, BIGINT, BIGINT, VARCHAR, VARCHAR);

CREATE OR REPLACE FUNCTION academico_test.fn_funcionario_archivo_crear(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_funcionario          BIGINT,
    p_fk_tarchivo             BIGINT,
    p_nombre                  VARCHAR DEFAULT NULL,
    p_descripcion             VARCHAR DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_ee           BIGINT;
    v_func_nombre  VARCHAR;
    v_arch_nombre  VARCHAR;
    v_nombre       VARCHAR;
    v_pk           BIGINT;
    v_total        BIGINT;
BEGIN
    IF p_fk_tarchivo IS NULL THEN
        RAISE EXCEPTION 'No llego ningun archivo'
            USING ERRCODE = '22023',
                  HINT    = 'El campo ARCHIVO del multipart tiene que traer el fichero. '
                         || 'Se sube uno por peticion';
    END IF;

    -- El funcionario y su establecimiento, que es el scope del gate. De paso
    -- sale el nombre legible para la etiqueta y para los mensajes de error.
    SELECT f.FK_ESTABLECIMIENTO,
           NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.PRIMER_APELLIDO)), '')
      INTO v_ee, v_func_nombre
      FROM academico_test.TFUNCIONARIO f
      JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario
       AND f.ACTIVE = TRUE;

    IF v_func_nombre IS NULL AND v_ee IS NULL THEN
        RAISE EXCEPTION 'El funcionario con identificador % no existe o no esta activo',
            p_pk_funcionario
            USING ERRCODE = '23503';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'FUNCIONARIOS', 'EDITAR', v_ee);

    SELECT a.NOMBRE INTO v_arch_nombre
      FROM academico_test.TARCHIVO a
     WHERE a.PK_TARCHIVO = p_fk_tarchivo
       AND a.ACTIVE = TRUE;

    IF v_arch_nombre IS NULL THEN
        RAISE EXCEPTION 'El archivo con identificador % no existe o no esta activo',
            p_fk_tarchivo
            USING ERRCODE = '23503';
    END IF;

    -- NOMBRE y DESCRIPCION son NOT NULL en la tabla: el nombre cae al del
    -- archivo subido y la descripcion a vacio, que es lo que el front manda
    -- cuando el usuario no escribio nada.
    v_nombre := COALESCE(NULLIF(TRIM(p_nombre), ''), v_arch_nombre);

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        FORMAT('Carga del archivo %s del funcionario %s',
               v_nombre, COALESCE(v_func_nombre, p_pk_funcionario::TEXT)),
        v_ee);

    INSERT INTO academico_test.TFUNCIONARIO_ARCHIVO (
        FK_TFUNCIONARIO, FK_TARCHIVO, NOMBRE, DESCRIPCION, CREATED_BY
    ) VALUES (
        p_pk_funcionario, p_fk_tarchivo, v_nombre,
        COALESCE(TRIM(p_descripcion), ''),
        COALESCE((SELECT u.CUENTA FROM academico_test.TUSUARIO u
                   WHERE u.PK_TUSUARIO = p_pk_usuario_solicitante),
                 'fn_funcionario_archivo_crear')
    )
    RETURNING PK_TFUNCIONARIO_ARCHIVO INTO v_pk;

    SELECT COUNT(*) INTO v_total
      FROM academico_test.TFUNCIONARIO_ARCHIVO
     WHERE FK_TFUNCIONARIO = p_pk_funcionario AND ACTIVE = TRUE;

    RETURN JSONB_BUILD_OBJECT(
        'pkTfuncionarioArchivo', v_pk,
        'pkFuncionario',         p_pk_funcionario,
        'fkTarchivo',            p_fk_tarchivo,
        'nombre',                v_nombre,
        'total',                 v_total);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_funcionario_archivo_crear(BIGINT, BIGINT, BIGINT, VARCHAR, VARCHAR)
    IS 'Enlaza UN archivo ya subido (TARCHIVO) como complementario de un funcionario. Un archivo por llamada: no existe el tipo FILE[] en param_types, asi que el front llama el endpoint en bucle -- mismo patron que POST /cobertura-academica/matricula/:ID/documentos. NOMBRE cae al del propio TARCHIVO si no lo mandan y DESCRIPCION a cadena vacia, porque los dos son NOT NULL en la tabla. Gate FUNCIONARIOS/EDITAR con scope sobre el establecimiento del funcionario. Devuelve el pk creado y cuantos complementarios quedan.';

-- ---------------------------------------------------------------------------
-- 2) Eliminar (baja logica).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_funcionario_archivo_eliminar(BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_funcionario_archivo_eliminar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tfuncionario_archivo  BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_ee           BIGINT;
    v_func         BIGINT;
    v_func_nombre  VARCHAR;
    v_nombre       VARCHAR;
    v_total        BIGINT;
BEGIN
    SELECT fa.FK_TFUNCIONARIO, fa.NOMBRE, f.FK_ESTABLECIMIENTO,
           NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.PRIMER_APELLIDO)), '')
      INTO v_func, v_nombre, v_ee, v_func_nombre
      FROM academico_test.TFUNCIONARIO_ARCHIVO fa
      JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = fa.FK_TFUNCIONARIO
      JOIN academico_test.TUSUARIO     u ON u.PK_TUSUARIO     = f.FK_TUSUARIO
     WHERE fa.PK_TFUNCIONARIO_ARCHIVO = p_pk_tfuncionario_archivo
       AND fa.ACTIVE = TRUE;

    -- Idempotente: si ya estaba dado de baja no es un error, es que el front
    -- reintento. Se responde el estado actual sin tocar nada.
    IF v_func IS NULL THEN
        IF EXISTS (SELECT 1 FROM academico_test.TFUNCIONARIO_ARCHIVO
                    WHERE PK_TFUNCIONARIO_ARCHIVO = p_pk_tfuncionario_archivo) THEN
            RETURN JSONB_BUILD_OBJECT(
                'pkTfuncionarioArchivo', p_pk_tfuncionario_archivo,
                'eliminado',             FALSE,
                'motivo',                'ya estaba eliminado');
        END IF;

        RAISE EXCEPTION 'El archivo de funcionario con identificador % no existe',
            p_pk_tfuncionario_archivo
            USING ERRCODE = '23503';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'FUNCIONARIOS', 'EDITAR', v_ee);

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        FORMAT('Eliminacion del archivo %s del funcionario %s',
               v_nombre, COALESCE(v_func_nombre, v_func::TEXT)),
        v_ee);

    UPDATE academico_test.TFUNCIONARIO_ARCHIVO
       SET ACTIVE      = FALSE,
           MODIFIED_BY = COALESCE(
               (SELECT u.CUENTA FROM academico_test.TUSUARIO u
                 WHERE u.PK_TUSUARIO = p_pk_usuario_solicitante),
               'fn_funcionario_archivo_eliminar'),
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TFUNCIONARIO_ARCHIVO = p_pk_tfuncionario_archivo;

    SELECT COUNT(*) INTO v_total
      FROM academico_test.TFUNCIONARIO_ARCHIVO
     WHERE FK_TFUNCIONARIO = v_func AND ACTIVE = TRUE;

    RETURN JSONB_BUILD_OBJECT(
        'pkTfuncionarioArchivo', p_pk_tfuncionario_archivo,
        'pkFuncionario',         v_func,
        'eliminado',             TRUE,
        'total',                 v_total);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_funcionario_archivo_eliminar(BIGINT, BIGINT)
    IS 'Baja logica de UN archivo complementario de un funcionario. Idempotente: si ya estaba dado de baja responde eliminado=false con el motivo en vez de fallar, porque para el front reintentar no es un error. Gate FUNCIONARIOS/EDITAR con scope sobre el establecimiento del funcionario. El TARCHIVO y el objeto en S3 NO se tocan -- esto desenlaza, no borra el fichero.';

-- ---------------------------------------------------------------------------
-- 3) Listar.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_funcionario_archivo_listar(BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_funcionario_archivo_listar(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_funcionario          BIGINT
)
RETURNS TABLE (
    pk_tfuncionario_archivo  BIGINT,
    fk_tarchivo              BIGINT,
    nombre                   VARCHAR,
    descripcion              VARCHAR,
    archivo_nombre           VARCHAR,
    urls3                    VARCHAR,
    peso                     BIGINT,
    fecha                    TIMESTAMP
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_ee  BIGINT;
BEGIN
    SELECT f.FK_ESTABLECIMIENTO INTO v_ee
      FROM academico_test.TFUNCIONARIO f
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario
       AND f.ACTIVE = TRUE;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'FUNCIONARIOS', 'VER', v_ee);

    RETURN QUERY
    SELECT fa.PK_TFUNCIONARIO_ARCHIVO,
           fa.FK_TARCHIVO,
           fa.NOMBRE,
           fa.DESCRIPCION,
           a.NOMBRE,
           a.URLS3,
           a.PESO,
           fa.CREATED_AT
      FROM academico_test.TFUNCIONARIO_ARCHIVO fa
      JOIN academico_test.TARCHIVO a ON a.PK_TARCHIVO = fa.FK_TARCHIVO
     WHERE fa.FK_TFUNCIONARIO = p_pk_funcionario
       AND fa.ACTIVE = TRUE
     ORDER BY fa.CREATED_AT DESC, fa.PK_TFUNCIONARIO_ARCHIVO DESC;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_funcionario_archivo_listar(BIGINT, BIGINT)
    IS 'Los archivos complementarios ACTIVE de un funcionario, del mas reciente al mas viejo. Gate FUNCIONARIOS/VER con scope sobre el establecimiento del funcionario. Existe como funcion propia aunque el detalle del funcionario ya los traiga embebidos (ver fn_usu_empleado_buscar_por_pk): sirve para refrescar la lista despues de subir o quitar uno, sin recargar la ficha entera.';
