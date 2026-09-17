-- ===========================================================================
-- V416 - Ningun archivo de soporte es obligatorio al crear la matricula.
--
--   fn_matricula_archivo_crear_lote  pierde el gate de obligatoriedad
--
--
-- QUE CAMBIA
--   La funcion rechazaba con 23502 si no llegaba el documento de identidad
--   ("El documento de identidad del estudiante es obligatorio") o el
--   certificado de estudios del año anterior. Los otros tres archivos --
--   certificado medico, foto y "otros documentos" -- ya eran opcionales.
--
--   Ahora los cinco se tratan igual: el que llega se enlaza, el que no
--   llega se omite.
--
--
-- POR QUE
--   Porque la obligatoriedad de esos campos NO se decide aqui. Se decide en
--   TMATRICULA_CAMPO / TMATRICULA_VALOR, la configuracion por
--   establecimiento de que campos del formulario de matricula son
--   requeridos y cuales visibles. Los cinco archivos son campos de esa
--   configuracion -- seccion "Archivo de soporte", PK 66 a 70, seed de
--   V229 -- y el colegio los puede marcar o desmarcar desde la pantalla de
--   configuracion de matricula.
--
--   El front ya lee esa configuracion y pide cada archivo segun lo que
--   diga. El IF de esta funcion no la leia: daba igual que el
--   establecimiento hubiera marcado el campo como no requerido, el alta
--   seguia rechazando. Eran dos fuentes de verdad para la misma pregunta, y
--   la que mandaba era justo la que nadie puede configurar.
--
--
-- ESTADO DE LOS DATOS
--   Los 104 establecimientos con configuracion tienen hoy REQUERIDO = 'S'
--   en esos dos campos y 'N' en los otros tres, que es el default sembrado
--   por V229. Es decir: mientras nadie cambie nada, el formulario los sigue
--   pidiendo exactamente igual que hasta ahora. Lo que esta migracion
--   habilita es que desmarcarlos SIRVA de algo.
--
--   En TMATRICULA_ARCHIVO hay 13 documentos de identidad, 13 certificados
--   de estudios y 3 "otros" cargados; ninguno se toca.
--
--
-- LO QUE NO CAMBIA
--   * La edicion. fn_matricula_archivo_actualizar_lote nunca tuvo el gate:
--     ya trabajaba con banderas p_tocar_* y no exigia ningun archivo.
--   * El resto de fn_matricula_archivo_crear_lote: la resolucion de los
--     tipos por VALOR contra ARCHIVO_MATRICULA (nunca por PK, que difiere
--     por ambiente) y el manejo de "otros documentos", que sigue aceptando
--     tanto el escalar como el array que manda TransformadorMultipart.
--   * El endpoint: esta funcion no se expone directamente, la llama
--     fn_matricula_directa_crear. Ni la ruta ni el cuerpo cambian, y el
--     front no se toca -- ya manda estos campos como opcionales.
--
--   La comprobacion de que el catalogo tenga los tipos 01 y 04 se conserva,
--   pero pasa a hacerse por archivo en vez de al entrar: un catalogo
--   incompleto solo debe estorbar a quien necesita ese tipo concreto, no a
--   un alta que no manda ninguno de los dos.
--
--   Los dos parametros pasan a tener DEFAULT NULL, como los otros tres. Los
--   dos llamadores pasan los argumentos por nombre, asi que no se rompe
--   ninguna llamada existente.
--
-- Idempotente: CREATE OR REPLACE, misma firma y mismo RETURNS TABLE. Añadir
-- DEFAULT a dos parametros no crea sobrecarga -- los tipos no cambian --,
-- asi que no hace falta DROP previo.
-- ===========================================================================


CREATE OR REPLACE FUNCTION academico_test.fn_matricula_archivo_crear_lote(p_pk_usuario_solicitante bigint, p_fk_tmatricula bigint, p_fk_tarchivo_documento_identidad bigint DEFAULT NULL::bigint, p_fk_tarchivo_certificado_estudios bigint DEFAULT NULL::bigint, p_fk_tarchivo_certificado_medico bigint DEFAULT NULL::bigint, p_fk_tarchivo_foto bigint DEFAULT NULL::bigint, p_fk_tarchivo_otros jsonb DEFAULT NULL::jsonb)
 RETURNS TABLE(pk_tmatricula_archivo bigint, fk_tlv_tipo_archivo bigint)
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_tipo_doc_identidad  BIGINT;
    v_tipo_cert_estudios  BIGINT;
    v_tipo_cert_medico    BIGINT;
    v_tipo_foto           BIGINT;
    v_tipo_otros          BIGINT;
    v_pk                  BIGINT;
    v_item                JSONB;
BEGIN
    -- -----------------------------------------------------------------
    -- V416 -- YA NO HAY ARCHIVOS OBLIGATORIOS.
    --
    --   Aqui habia un paso 0 que rechazaba con 23502 si faltaba el
    --   documento de identidad o el certificado de estudios del año
    --   anterior. Era una copia endurecida de lo que ya decide
    --   TMATRICULA_CAMPO / TMATRICULA_VALOR, la configuracion por
    --   establecimiento de que campos del formulario son requeridos:
    --   los cinco archivos de soporte son campos configurables de la
    --   seccion "Archivo de soporte" (PK 66 a 70, seed de V229), y esos
    --   dos venian con REQUERIDO_DEFECTO = 'S'.
    --
    --   El front ya lee esa configuracion y pide o no cada archivo segun
    --   lo que diga. El IF de aqui no la leia: daba igual que el colegio
    --   marcara el campo como no requerido, el alta seguia rechazando.
    --   Dos fuentes de verdad para la misma pregunta, y la que mandaba
    --   era la que no se puede configurar.
    --
    --   Los cinco archivos quedan tratados igual: si viene, se enlaza; si
    --   no viene, no pasa nada. La obligatoriedad la decide la config.
    -- -----------------------------------------------------------------

    -- -----------------------------------------------------------------
    -- 1. Resolver cada tipo de archivo contra el catalogo, por VALOR
    --    (no por PK hardcodeado -- ver V165 mas arriba para el seed).
    -- -----------------------------------------------------------------
    SELECT PK_LISTA_VALOR INTO v_tipo_doc_identidad
      FROM academico_test.TLISTA_VALOR WHERE CATEGORIA = 'ARCHIVO_MATRICULA' AND VALOR = '01' AND ACTIVE = TRUE;
    SELECT PK_LISTA_VALOR INTO v_tipo_cert_medico
      FROM academico_test.TLISTA_VALOR WHERE CATEGORIA = 'ARCHIVO_MATRICULA' AND VALOR = '02' AND ACTIVE = TRUE;
    SELECT PK_LISTA_VALOR INTO v_tipo_cert_estudios
      FROM academico_test.TLISTA_VALOR WHERE CATEGORIA = 'ARCHIVO_MATRICULA' AND VALOR = '04' AND ACTIVE = TRUE;
    SELECT PK_LISTA_VALOR INTO v_tipo_foto
      FROM academico_test.TLISTA_VALOR WHERE CATEGORIA = 'ARCHIVO_MATRICULA' AND VALOR = '05' AND ACTIVE = TRUE;
    SELECT PK_LISTA_VALOR INTO v_tipo_otros
      FROM academico_test.TLISTA_VALOR WHERE CATEGORIA = 'ARCHIVO_MATRICULA' AND VALOR = '06' AND ACTIVE = TRUE;

    -- -----------------------------------------------------------------
    -- 2. Los cuatro documentos uno-a-uno. Todos con el mismo trato desde
    --    V416: el que llega se enlaza, el que no llega se omite.
    --
    --    La comprobacion de que el tipo exista en el catalogo se hace por
    --    archivo, y no de entrada como antes: un catalogo incompleto solo
    --    debe estorbar a quien realmente necesita ese tipo. Se mantiene
    --    para 01 y 04, que son los que la tenian.
    -- -----------------------------------------------------------------
    IF p_fk_tarchivo_documento_identidad IS NOT NULL THEN
        IF v_tipo_doc_identidad IS NULL THEN
            RAISE EXCEPTION 'El catalogo ARCHIVO_MATRICULA no tiene el tipo de documento de identidad (VALOR 01) -- ejecute el seed de V165'
                USING ERRCODE = '23503';
        END IF;
        v_pk := academico_test.fn_matricula_archivo_crear(
            p_pk_usuario_solicitante, p_fk_tmatricula, p_fk_tarchivo_documento_identidad, v_tipo_doc_identidad);
        RETURN QUERY SELECT v_pk, v_tipo_doc_identidad;
    END IF;

    IF p_fk_tarchivo_certificado_estudios IS NOT NULL THEN
        IF v_tipo_cert_estudios IS NULL THEN
            RAISE EXCEPTION 'El catalogo ARCHIVO_MATRICULA no tiene el tipo de certificado de estudios (VALOR 04) -- ejecute el seed de V165'
                USING ERRCODE = '23503';
        END IF;
        v_pk := academico_test.fn_matricula_archivo_crear(
            p_pk_usuario_solicitante, p_fk_tmatricula, p_fk_tarchivo_certificado_estudios, v_tipo_cert_estudios);
        RETURN QUERY SELECT v_pk, v_tipo_cert_estudios;
    END IF;

    IF p_fk_tarchivo_certificado_medico IS NOT NULL THEN
        v_pk := academico_test.fn_matricula_archivo_crear(
            p_pk_usuario_solicitante, p_fk_tmatricula, p_fk_tarchivo_certificado_medico, v_tipo_cert_medico);
        RETURN QUERY SELECT v_pk, v_tipo_cert_medico;
    END IF;

    IF p_fk_tarchivo_foto IS NOT NULL THEN
        v_pk := academico_test.fn_matricula_archivo_crear(
            p_pk_usuario_solicitante, p_fk_tmatricula, p_fk_tarchivo_foto, v_tipo_foto);
        RETURN QUERY SELECT v_pk, v_tipo_foto;
    END IF;

    -- -----------------------------------------------------------------
    -- 3. "Otros documentos relevantes" -- 0..N, cantidad variable.
    --    TransformadorMultipart (file-service) entrega el campo como
    --    escalar cuando el multipart trae UN solo archivo bajo ese
    --    nombre de campo, y como array cuando trae varios ("Un solo
    --    fichero en el campo -> id suelto. Varios -> lista.") -- hay que
    --    aceptar ambas formas, no solo la de array.
    -- -----------------------------------------------------------------
    IF p_fk_tarchivo_otros IS NOT NULL THEN
        IF jsonb_typeof(p_fk_tarchivo_otros) = 'array' THEN
            FOR v_item IN SELECT * FROM jsonb_array_elements(p_fk_tarchivo_otros)
            LOOP
                v_pk := academico_test.fn_matricula_archivo_crear(
                    p_pk_usuario_solicitante, p_fk_tmatricula, (v_item#>>'{}')::BIGINT, v_tipo_otros);
                RETURN QUERY SELECT v_pk, v_tipo_otros;
            END LOOP;
        ELSE
            v_pk := academico_test.fn_matricula_archivo_crear(
                p_pk_usuario_solicitante, p_fk_tmatricula, (p_fk_tarchivo_otros#>>'{}')::BIGINT, v_tipo_otros);
            RETURN QUERY SELECT v_pk, v_tipo_otros;
        END IF;
    END IF;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_matricula_archivo_crear_lote(BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, JSONB)
    IS 'Enlaza a la matricula los archivos de soporte que vengan, resolviendo cada tipo por VALOR contra el catalogo ARCHIVO_MATRICULA (nunca por PK, que difiere por ambiente). Desde V416 NINGUNO es obligatorio: el que llega se enlaza y el que no llega se omite. Antes rechazaba con 23502 si faltaba el documento de identidad o el certificado de estudios del año anterior, duplicando -- y endureciendo -- lo que ya decide la configuracion por establecimiento de TMATRICULA_CAMPO/TMATRICULA_VALOR, donde los cinco archivos son campos configurables de la seccion "Archivo de soporte" (PK 66-70, seed de V229). Esa configuracion es la unica fuente de verdad de que campos son requeridos, y el front ya la respeta. "Otros documentos relevantes" admite 0..N y acepta tanto el escalar como el array, porque TransformadorMultipart manda un id suelto cuando el multipart trae un solo archivo bajo ese campo. La llaman fn_matricula_directa_crear y nadie mas; la edicion va por fn_matricula_archivo_actualizar_lote, que nunca exigio archivos.';
