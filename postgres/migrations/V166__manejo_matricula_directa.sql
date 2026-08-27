-- =============================================================================
-- V166 -- fn_matricula_directa_crear: funcion ORQUESTADORA que unifica
-- todo el proceso de "Agregar estudiante" (matricula directa) descrito en
-- las migraciones V160-V165. Es la funcion que va a llamar el endpoint
-- de alta -- todo lo demas (fn_estudiante_crear, fn_padre_crear,
-- fn_periodo_resolver_matricula, fn_matricula_validar_cupo,
-- fn_matricula_validar_estudiante_disponible, fn_matricula_crear,
-- fn_matricula_socioeconomico_crear, fn_matricula_archivo_crear_lote)
-- sigue existiendo y sigue siendo llamable por separado, pero esta es la
-- unica que agrupa el proceso completo en el orden correcto.
--
-- Precondiciones que YA resolvio el caller antes de llegar aqui (front +
-- Java, no esta funcion):
--   - p_pk_usuario_estudiante y p_pk_usuario_padre son PKs de TUSUARIO ya
--     creados (o reutilizados, si el autocompletado por documento -- ver
--     fn_usu_autocompletar_por_documento -- encontro uno) via
--     POST /register/usuario -> fn_usu_crear.
--   - p_fk_sede / p_fk_tlv_jornada / p_fk_tgrupo son los que el usuario
--     eligio en los selects encadenados del formulario (sede -> jornada
--     -> grado -> grupo, ver fn_jornadas_activas_por_sede/fn_grado_listar/
--     fn_grupo_listar).
--   - Los pk_tarchivo de los 5 campos de soporte ya fueron subidos via
--     file-service (ver V165) y llegan como PKs listos.
--
-- Orden de ejecucion (cada paso puede abortar todo -- una sola funcion,
-- una sola transaccion, atomico de punta a punta):
--   1. Gate temprano (falla rapido, antes de tocar nada).
--   2. Resolver el periodo academico vigente + validar que el periodo de
--      inscripcion ya cerro (fn_periodo_resolver_matricula).
--   3. Verificar que el grupo elegido pertenece a ESE periodo (evita
--      mezclar sede/jornada del paso 2 con un grupo de otro periodo).
--   4. Validar cupo disponible en el grupo (fn_matricula_validar_cupo).
--   5. Resolver o crear el TESTUDIANTE (reusa si el usuario ya tiene uno
--      activo -- p.ej. si el autocompletado por documento ya lo
--      encontro; si no, lo crea con fn_estudiante_crear).
--   6. Validar que ese estudiante no tenga ya una matricula activa este
--      año lectivo (fn_matricula_validar_estudiante_disponible).
--   7. Crear/reusar el TPADRE y su TNUCLEO_FAMILIAR (fn_padre_crear ya es
--      idempotente por usuario internamente).
--   8. Crear la TMATRICULA (fn_matricula_crear).
--   9. Crear el TMATRICULA_SOCIOECONOMICO asociado (fn_matricula_socioeconomico_crear).
--  10. Enlazar los archivos de soporte (fn_matricula_archivo_crear_lote).
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_directa_crear(
    p_pk_usuario_solicitante              BIGINT,

    -- --- Informacion de matricula (selects encadenados) ---
    p_fk_sede                             BIGINT,
    p_fk_tlv_jornada                      BIGINT,
    p_fk_tgrupo                           BIGINT,
    p_fk_enfasis                          BIGINT  DEFAULT NULL,

    -- --- Estudiante: usuario ya creado/resuelto + delta de TUSUARIO/TESTUDIANTE ---
    p_pk_usuario_estudiante               BIGINT  DEFAULT NULL,
    p_fk_tresguardo                       BIGINT  DEFAULT NULL,
    p_fk_tdiscapacidad                    BIGINT  DEFAULT NULL,
    p_fk_tlv_talento                      BIGINT  DEFAULT NULL,
    p_fk_tmunicipio_documento_est         BIGINT  DEFAULT NULL,
    p_fk_tmunicipio_nacimiento_est        BIGINT  DEFAULT NULL,
    p_fk_tmunicipio_residencia_est        BIGINT  DEFAULT NULL,
    p_direccion_residencia_est            VARCHAR DEFAULT NULL,
    p_fk_tlv_estrato                      BIGINT  DEFAULT NULL,
    p_fk_tlv_sisben                       BIGINT  DEFAULT NULL,

    -- --- Informacion academica del año anterior (TMATRICULA) ---
    p_fk_tlv_situacion_academica          BIGINT  DEFAULT NULL,
    p_estudiante_nuevo                    VARCHAR DEFAULT 'S',

    -- --- Acudiente: usuario ya creado/resuelto + delta de TUSUARIO/TPADRE/TNUCLEO_FAMILIAR ---
    p_pk_usuario_padre                    BIGINT  DEFAULT NULL,
    p_fk_tlv_parentesco                   BIGINT  DEFAULT NULL,
    p_fk_tmunicipio_documento_padre       BIGINT  DEFAULT NULL,
    p_fk_tmunicipio_residencia_padre      BIGINT  DEFAULT NULL,
    p_direccion_residencia_padre          VARCHAR DEFAULT NULL,
    p_fk_tlv_zona                         BIGINT  DEFAULT NULL,
    p_fk_tlv_nivel_educativo              BIGINT  DEFAULT NULL,
    p_fk_tlv_estado_civil                 BIGINT  DEFAULT NULL,
    p_ocupacion                           VARCHAR DEFAULT NULL,
    p_profesion                           VARCHAR DEFAULT NULL,
    p_entidad                             VARCHAR DEFAULT NULL,
    p_direccion_entidad                   VARCHAR DEFAULT NULL,
    p_telefono_entidad                    VARCHAR DEFAULT NULL,
    p_cargo_entidad                       VARCHAR DEFAULT NULL,
    p_acudiente                           VARCHAR DEFAULT 'S',
    p_asiste_reuniones                    VARCHAR DEFAULT NULL,
    p_asiste_informes                     VARCHAR DEFAULT NULL,
    p_fk_tlv_tipo_empleo                  BIGINT  DEFAULT NULL,
    p_fk_tlv_frecuencia_domicilio         BIGINT  DEFAULT NULL,

    -- --- Sector de origen / victima conflicto / complementaria / subsidio (TMATRICULA_SOCIOECONOMICO) ---
    p_proviene_sector_privado             VARCHAR DEFAULT NULL,
    p_proviene_otro_municipio             VARCHAR DEFAULT NULL,
    p_proviene_otro_municipio_cual        VARCHAR DEFAULT NULL,
    p_institucion_origen                  VARCHAR DEFAULT NULL,
    p_fk_tlv_tipo_institucion_origen      BIGINT  DEFAULT NULL,
    p_fk_tlv_condicion_promocion          BIGINT  DEFAULT NULL,
    p_fk_tlv_victima_conflicto            BIGINT  DEFAULT NULL,
    p_fk_tmunicipio_victima               BIGINT  DEFAULT NULL,
    p_seguridad_social_ars                VARCHAR DEFAULT NULL,
    p_seguridad_social_eps                VARCHAR DEFAULT NULL,
    p_estudiante_subsidiado               VARCHAR DEFAULT NULL,
    p_fk_tlv_fuente_recurso               BIGINT  DEFAULT NULL,
    p_beneficiario_cabeza_familia         VARCHAR DEFAULT NULL,
    p_ben_hijo_cabeza_familia             VARCHAR DEFAULT NULL,
    p_beneficiario_veterano               VARCHAR DEFAULT NULL,
    p_beneficiario_heroe                  VARCHAR DEFAULT NULL,

    -- --- Archivo de soporte ---
    p_fk_tarchivo_documento_identidad     BIGINT  DEFAULT NULL,
    p_fk_tarchivo_certificado_estudios    BIGINT  DEFAULT NULL,
    p_fk_tarchivo_certificado_medico      BIGINT  DEFAULT NULL,
    p_fk_tarchivo_foto                    BIGINT  DEFAULT NULL,
    p_fk_tarchivo_otros                   JSONB   DEFAULT NULL
)
RETURNS TABLE (
    pk_testudiante                 BIGINT,
    pk_tpadre                      BIGINT,
    pk_tnucleo_familiar             BIGINT,
    pk_tmatricula                    BIGINT,
    pk_tmatricula_socioeconomico     BIGINT,
    archivos_creados                 JSONB
)
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_establecimiento     BIGINT;
    v_pk_periodo              BIGINT;
    v_fk_periodo_del_grupo    BIGINT;
    v_pk_testudiante          BIGINT;
    v_pk_tpadre               BIGINT;
    v_pk_tnucleo_familiar     BIGINT;
    v_pk_matricula            BIGINT;
    v_pk_socioeconomico       BIGINT;
    v_archivos                JSONB;
BEGIN
    -- -----------------------------------------------------------------
    -- 1. Gate temprano -- mismo patron de fn_sed_crear/V160-V165,
    --    resuelto contra la sede recibida. Falla rapido, antes de tocar
    --    cualquier tabla; cada funcion delegada abajo re-valida su
    --    propio gate igual (defensa en profundidad), pero repetirlo aca
    --    evita crear usuario/estudiante/padre solo para reventar despues
    --    en el ultimo paso por falta de permisos.
    -- -----------------------------------------------------------------
    SELECT s.FK_TESTABLECIMIENTO
      INTO v_fk_establecimiento
      FROM academico_test.TSEDE s
     WHERE s.PK_TSEDE = p_fk_sede
       AND s.ACTIVE   = TRUE;

    IF v_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'No se encontro una sede activa con ese identificador'
            USING ERRCODE = '22023', HINT = 'p_fk_sede debe apuntar a una TSEDE activa';
    END IF;

    IF academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TESTABLECIMIENTO e
            ON e.FK_TFUNCIONARIO_RECTOR = f.PK_TFUNCIONARIO
         WHERE e.PK_ESTABLECIMIENTO = v_fk_establecimiento
           AND e.ACTIVE             = TRUE
           AND f.ACTIVE             = TRUE
           AND f.FK_TUSUARIO        = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TESTABLECIMIENTO e
            ON e.FK_TFUNCIONARIO_SECRETARIA = f.PK_TFUNCIONARIO
         WHERE e.PK_ESTABLECIMIENTO = v_fk_establecimiento
           AND e.ACTIVE             = TRUE
           AND f.ACTIVE             = TRUE
           AND f.FK_TUSUARIO        = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TSEDE_USUARIO su
          JOIN academico_test.TSEDE s
            ON s.PK_TSEDE = su.FK_TSEDE
         WHERE s.FK_TESTABLECIMIENTO = v_fk_establecimiento
           AND s.ACTIVE              = TRUE
           AND su.ACTIVE             = TRUE
           AND su.FK_TROL            = 8
           AND su.FK_TUSUARIO        = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSE
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Resolver el periodo academico vigente + validar que ya cerro el
    --    periodo de inscripcion (matricula directa va DESPUES de ese
    --    cierre -- ver V162).
    -- -----------------------------------------------------------------
    v_pk_periodo := academico_test.fn_periodo_resolver_matricula(
        p_fk_sede := p_fk_sede,
        p_fk_tlv_jornada := p_fk_tlv_jornada,
        p_pk_usuario := p_pk_usuario_solicitante
    );

    -- -----------------------------------------------------------------
    -- 3. El grupo elegido debe pertenecer a ESE periodo -- evita mezclar
    --    la sede/jornada del paso 2 con un grupo de otro periodo/sede.
    -- -----------------------------------------------------------------
    SELECT g.FK_TPERIODO_ACADEMICO
      INTO v_fk_periodo_del_grupo
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
     WHERE gr.PK_TGRUPO = p_fk_tgrupo
       AND gr.ACTIVE     = TRUE
       AND g.ACTIVE      = TRUE;

    IF v_fk_periodo_del_grupo IS NULL OR v_fk_periodo_del_grupo <> v_pk_periodo THEN
        RAISE EXCEPTION 'El grupo indicado no pertenece al periodo academico resuelto para la sede y jornada dadas'
            USING ERRCODE = '22023',
                  HINT    = 'p_fk_tgrupo debe pertenecer (via TGRADO) al periodo vigente de p_fk_sede/p_fk_tlv_jornada';
    END IF;

    -- -----------------------------------------------------------------
    -- 4. Validar cupo disponible en el grupo.
    -- -----------------------------------------------------------------
    PERFORM academico_test.fn_matricula_validar_cupo(p_fk_grupo := p_fk_tgrupo);

    -- -----------------------------------------------------------------
    -- 5. Resolver o crear el TESTUDIANTE. Si el usuario ya tiene uno
    --    activo (p.ej. lo trajo el autocompletado por documento -- ver
    --    fn_usu_autocompletar_por_documento), se reutiliza; si no, se
    --    crea. fn_estudiante_crear en cambio SI rechaza duplicados (a
    --    diferencia de fn_padre_crear) -- por eso el find-or-create se
    --    hace aca, no dentro de esa funcion.
    -- -----------------------------------------------------------------
    SELECT e.PK_TESTUDIANTE
      INTO v_pk_testudiante
      FROM academico_test.TESTUDIANTE e
     WHERE e.FK_TUSUARIO = p_pk_usuario_estudiante
       AND e.ACTIVE      = TRUE;

    IF v_pk_testudiante IS NULL THEN
        v_pk_testudiante := academico_test.fn_estudiante_crear(
            p_pk_usuario_solicitante := p_pk_usuario_solicitante,
            p_fk_sede := p_fk_sede,
            p_pk_usuario := p_pk_usuario_estudiante,
            p_fk_tresguardo := p_fk_tresguardo,
            p_fk_tdiscapacidad := p_fk_tdiscapacidad,
            p_fk_tlv_talento := p_fk_tlv_talento,
            p_fk_tmunicipio_documento := p_fk_tmunicipio_documento_est,
            p_fk_tmunicipio_nacimiento := p_fk_tmunicipio_nacimiento_est,
            p_fk_tmunicipio_residencia := p_fk_tmunicipio_residencia_est,
            p_direccion_residencia := p_direccion_residencia_est,
            p_fk_tlv_estrato := p_fk_tlv_estrato,
            p_fk_tlv_sisben := p_fk_tlv_sisben
        );
    END IF;

    -- -----------------------------------------------------------------
    -- 6. El estudiante no puede tener ya otra matricula activa este año
    --    lectivo.
    -- -----------------------------------------------------------------
    PERFORM academico_test.fn_matricula_validar_estudiante_disponible(p_fk_testudiante := v_pk_testudiante);

    -- -----------------------------------------------------------------
    -- 7. Crear/reusar el TPADRE y su TNUCLEO_FAMILIAR -- ya es
    --    idempotente por usuario internamente.
    -- -----------------------------------------------------------------
    SELECT o_pk_tpadre, o_pk_tnucleo_familiar
      INTO v_pk_tpadre, v_pk_tnucleo_familiar
      FROM academico_test.fn_padre_crear(
          p_pk_usuario_solicitante := p_pk_usuario_solicitante,
          p_fk_sede := p_fk_sede,
          p_pk_usuario := p_pk_usuario_padre,
          p_pk_testudiante := v_pk_testudiante,
          p_fk_tlv_parentesco := p_fk_tlv_parentesco,
          p_fk_tmunicipio_documento := p_fk_tmunicipio_documento_padre,
          p_fk_tmunicipio_residencia := p_fk_tmunicipio_residencia_padre,
          p_direccion_residencia := p_direccion_residencia_padre,
          p_fk_tlv_zona := p_fk_tlv_zona,
          p_fk_tlv_nivel_educativo := p_fk_tlv_nivel_educativo,
          p_fk_tlv_estado_civil := p_fk_tlv_estado_civil,
          p_ocupacion := p_ocupacion,
          p_profesion := p_profesion,
          p_entidad := p_entidad,
          p_direccion_entidad := p_direccion_entidad,
          p_telefono_entidad := p_telefono_entidad,
          p_cargo_entidad := p_cargo_entidad,
          p_acudiente := p_acudiente,
          p_asiste_reuniones := p_asiste_reuniones,
          p_asiste_informes := p_asiste_informes,
          p_fk_tlv_tipo_empleo := p_fk_tlv_tipo_empleo,
          p_fk_tlv_frecuencia_domicilio := p_fk_tlv_frecuencia_domicilio
      );

    -- -----------------------------------------------------------------
    -- 8. Crear la TMATRICULA. FK_TLV_ESTADO_MATRICULA se resuelve aca
    --    (no lo elige el formulario): VALOR='1' ("Cursando") en
    --    CATEGORIA='ESTADO_MATRICULA' -- por VALOR, no PK hardcodeado.
    -- -----------------------------------------------------------------
    v_pk_matricula := academico_test.fn_matricula_crear(
        p_pk_usuario_solicitante := p_pk_usuario_solicitante,
        p_fk_testudiante := v_pk_testudiante,
        p_fk_tgrupo := p_fk_tgrupo,
        p_fk_tlv_estado_matricula := (
            SELECT PK_LISTA_VALOR FROM academico_test.TLISTA_VALOR
             WHERE CATEGORIA = 'ESTADO_MATRICULA' AND VALOR = '1' AND ACTIVE = TRUE
        ),
        p_estudiante_nuevo := p_estudiante_nuevo,
        p_fk_enfasis := p_fk_enfasis,
        p_fk_tlv_situacion_academica := p_fk_tlv_situacion_academica
    );

    -- -----------------------------------------------------------------
    -- 9. Crear el TMATRICULA_SOCIOECONOMICO asociado -- se crea siempre
    --    (fila 1-a-1), aunque llegue todo NULL: es el perfil
    --    socioeconomico de ESA matricula, no un dato opcional aparte.
    -- -----------------------------------------------------------------
    v_pk_socioeconomico := academico_test.fn_matricula_socioeconomico_crear(
        p_pk_usuario_solicitante := p_pk_usuario_solicitante,
        p_fk_tmatricula := v_pk_matricula,
        p_proviene_sector_privado := p_proviene_sector_privado,
        p_proviene_otro_municipio := p_proviene_otro_municipio,
        p_proviene_otro_municipio_cual := p_proviene_otro_municipio_cual,
        p_institucion_origen := p_institucion_origen,
        p_fk_tlv_tipo_institucion_origen := p_fk_tlv_tipo_institucion_origen,
        p_fk_tlv_condicion_promocion := p_fk_tlv_condicion_promocion,
        p_fk_tlv_victima_conflicto := p_fk_tlv_victima_conflicto,
        p_fk_tmunicipio_victima := p_fk_tmunicipio_victima,
        p_seguridad_social_ars := p_seguridad_social_ars,
        p_seguridad_social_eps := p_seguridad_social_eps,
        p_estudiante_subsidiado := p_estudiante_subsidiado,
        p_fk_tlv_fuente_recurso := p_fk_tlv_fuente_recurso,
        p_beneficiario_cabeza_familia := p_beneficiario_cabeza_familia,
        p_ben_hijo_cabeza_familia := p_ben_hijo_cabeza_familia,
        p_beneficiario_veterano := p_beneficiario_veterano,
        p_beneficiario_heroe := p_beneficiario_heroe
    );

    -- -----------------------------------------------------------------
    -- 10. Enlazar los archivos de soporte.
    -- -----------------------------------------------------------------
    SELECT jsonb_agg(jsonb_build_object(
               'pkTmatriculaArchivo', lote.pk_tmatricula_archivo,
               'fkTlvTipoArchivo', lote.fk_tlv_tipo_archivo
           ))
      INTO v_archivos
      FROM academico_test.fn_matricula_archivo_crear_lote(
          p_pk_usuario_solicitante := p_pk_usuario_solicitante,
          p_fk_tmatricula := v_pk_matricula,
          p_fk_tarchivo_documento_identidad := p_fk_tarchivo_documento_identidad,
          p_fk_tarchivo_certificado_estudios := p_fk_tarchivo_certificado_estudios,
          p_fk_tarchivo_certificado_medico := p_fk_tarchivo_certificado_medico,
          p_fk_tarchivo_foto := p_fk_tarchivo_foto,
          p_fk_tarchivo_otros := p_fk_tarchivo_otros
      ) AS lote;

    RETURN QUERY SELECT
        v_pk_testudiante, v_pk_tpadre, v_pk_tnucleo_familiar,
        v_pk_matricula, v_pk_socioeconomico, COALESCE(v_archivos, '[]'::jsonb);
END;
$function$;

-- =============================================================================
-- fn_matricula_obtener_completa -- GET ORQUESTADOR: la contraparte de
-- lectura de fn_matricula_directa_crear. Devuelve, en un solo JSONB, todo
-- lo que el formulario de matricula necesita para reconstruirse:
--
--   {
--     "matricula":      { ...contexto academico + campos de TMATRICULA... },
--     "socioeconomico": { ... } | null,
--     "estudiante":     { ...TUSUARIO + TESTUDIANTE... } | null,
--     "acudientes":     [ { ...TUSUARIO + TPADRE..., "vinculo": {...} } ],
--     "archivos":       [ { ...TMATRICULA_ARCHIVO + TARCHIVO... } ]
--   }
--
-- Se apoya en las funciones granulares de cada modulo, cada una en su
-- propio archivo: fn_matricula_obtener_por_id (V163),
-- fn_matricula_socioeconomico_obtener_por_matricula (V164),
-- fn_matricula_archivo_listar_por_matricula (V165),
-- fn_estudiante_obtener_por_id (V160) y fn_padre_obtener_por_id (V161).
-- Todas siguen siendo llamables por separado.
--
-- Gate: el estricto (sede-especifico) lo aplica fn_matricula_obtener_por_id
-- en el primer paso; si no pasa, esta funcion aborta ahi con 42501 y no
-- llega a leer nada mas. Las granulares de estudiante/acudiente usan el
-- gate amplio (ver V160), que es un superconjunto del estricto -- quien
-- pasa el primero pasa el segundo, asi que no hay 42501 sorpresa a mitad
-- de camino.
--
-- Devuelve NULL si la matricula no existe, esta inactiva, o su cadena
-- grupo/grado/periodo/sede tiene algun eslabon inactivo -- el caller lo
-- traduce a 404. No lanza excepcion para ese caso (simetrico con las
-- granulares, que devuelven 0 filas).
--
-- El binario de cada archivo NO viaja aca: la lista trae los pk_tarchivo
-- para que el front los pida a file-service por separado.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_obtener_completa(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_tmatricula           BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_matricula       JSONB;
    v_socioeconomico  JSONB;
    v_estudiante      JSONB;
    v_acudientes      JSONB;
    v_archivos        JSONB;
    v_fk_testudiante  BIGINT;
BEGIN
    -- -----------------------------------------------------------------
    -- 1. Matricula -- aplica el gate estricto y resuelve el contexto
    --    academico. Si no devuelve fila, la matricula no existe o no
    --    esta accesible: NULL y se corta aca.
    -- -----------------------------------------------------------------
    SELECT to_jsonb(m), m.fk_testudiante
      INTO v_matricula, v_fk_testudiante
      FROM academico_test.fn_matricula_obtener_por_id(
               p_pk_usuario_solicitante, p_pk_tmatricula) AS m;

    IF v_matricula IS NULL THEN
        RETURN NULL;
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Detalle socioeconomico (0..1).
    -- -----------------------------------------------------------------
    SELECT to_jsonb(se)
      INTO v_socioeconomico
      FROM academico_test.fn_matricula_socioeconomico_obtener_por_matricula(
               p_pk_usuario_solicitante, p_pk_tmatricula) AS se;

    -- -----------------------------------------------------------------
    -- 3. Estudiante (TUSUARIO + TESTUDIANTE).
    -- -----------------------------------------------------------------
    SELECT to_jsonb(e)
      INTO v_estudiante
      FROM academico_test.fn_estudiante_obtener_por_id(
               p_pk_usuario_solicitante, v_fk_testudiante) AS e;

    -- -----------------------------------------------------------------
    -- 4. Acudientes (0..N) -- se llega por TNUCLEO_FAMILIAR, no por
    --    TMATRICULA.FK_TPADRE: ese campo existe en el DDL pero
    --    fn_matricula_crear no lo llena (ver V163), y ademas un
    --    estudiante puede tener varios acudientes. Cada uno trae sus
    --    datos de persona mas el "vinculo" (parentesco y banderas del
    --    nucleo familiar), que es informacion de la RELACION, no del
    --    acudiente en si.
    -- -----------------------------------------------------------------
    SELECT jsonb_agg(
               to_jsonb(pa) || jsonb_build_object(
                   'vinculo', jsonb_build_object(
                       'pkTnucleoFamiliar',        nf.PK_TNUCLEO_FAMILIAR,
                       'fkTlvParentesco',          nf.FK_TLV_PARENTESCO,
                       'parentescoNombre',         par.NOMBRE,
                       'acudiente',                nf.ACUDIENTE,
                       'asisteReuniones',          nf.ASISTE_REUNIONES,
                       'asisteInformes',           nf.ASISTE_INFORMES,
                       'fkTlvTipoEmpleo',          nf.FK_TLV_TIPO_EMPLEO,
                       'tipoEmpleoNombre',         te.NOMBRE,
                       'fkTlvFrecuenciaDomicilio', nf.FK_TLV_FRECUENCIA_DOMICILIO,
                       'frecuenciaDomicilioNombre', fd.NOMBRE
                   ))
               ORDER BY nf.PK_TNUCLEO_FAMILIAR)
      INTO v_acudientes
      FROM academico_test.TNUCLEO_FAMILIAR nf
      LEFT JOIN academico_test.TLISTA_VALOR par ON par.PK_LISTA_VALOR = nf.FK_TLV_PARENTESCO
      LEFT JOIN academico_test.TLISTA_VALOR te  ON te.PK_LISTA_VALOR  = nf.FK_TLV_TIPO_EMPLEO
      LEFT JOIN academico_test.TLISTA_VALOR fd  ON fd.PK_LISTA_VALOR  = nf.FK_TLV_FRECUENCIA_DOMICILIO
      CROSS JOIN LATERAL academico_test.fn_padre_obtener_por_id(
                     p_pk_usuario_solicitante, nf.FK_TPADRE) AS pa
     WHERE nf.FK_TESTUDIANTE = v_fk_testudiante
       AND nf.ACTIVE         = TRUE;

    -- -----------------------------------------------------------------
    -- 5. Archivos de soporte (0..N).
    -- -----------------------------------------------------------------
    SELECT jsonb_agg(to_jsonb(ar) ORDER BY ar.pk_tmatricula_archivo)
      INTO v_archivos
      FROM academico_test.fn_matricula_archivo_listar_por_matricula(
               p_pk_usuario_solicitante, p_pk_tmatricula) AS ar;

    RETURN jsonb_build_object(
        'matricula',      v_matricula,
        'socioeconomico', v_socioeconomico,
        'estudiante',     v_estudiante,
        'acudientes',     COALESCE(v_acudientes, '[]'::jsonb),
        'archivos',       COALESCE(v_archivos,   '[]'::jsonb)
    );
END;
$function$;
