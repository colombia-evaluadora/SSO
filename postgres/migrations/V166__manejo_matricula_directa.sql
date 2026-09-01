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
--   2. Identificar el periodo academico del que cuelga el grupo elegido.
--   3. Validar ese periodo contra (sede, jornada, año actual), el alcance
--      del solicitante y el cierre del periodo de inscripcion
--      (fn_periodo_resolver_matricula, al que se le pasa el grupo).
--   4. Validar cupo disponible en el grupo (fn_matricula_validar_cupo).
--   5. Resolver o crear el TESTUDIANTE (reusa si el usuario ya tiene uno
--      activo -- p.ej. si el autocompletado por documento ya lo
--      encontro; si no, lo crea con fn_estudiante_crear).
--   6. Validar que ese estudiante no tenga ya una matricula activa este
--      año lectivo (fn_matricula_validar_estudiante_disponible).
--   7. Crear/reusar el TPADRE y su TNUCLEO_FAMILIAR (fn_padre_crear ya es
--      idempotente por usuario internamente).
--   8. Vincular a estudiante y acudiente con la SEDE en TSEDE_USUARIO
--      (roles 15 y 16), para que tengan acceso efectivo al sistema.
--   9. Crear la TMATRICULA (fn_matricula_crear).
--  10. Crear el TMATRICULA_SOCIOECONOMICO asociado (fn_matricula_socioeconomico_crear).
--  11. Enlazar los archivos de soporte (fn_matricula_archivo_crear_lote).
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
    -- Roles de TROL para el vinculo a la sede (paso 8).
    c_fk_trol_estudiante  CONSTANT BIGINT := 15;
    c_fk_trol_acudiente   CONSTANT BIGINT := 16;
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
    -- 2. Identificar el periodo academico del que cuelga el grupo elegido.
    --
    --    REV -- este paso iba DESPUES de resolver el periodo por
    --    (sede, jornada) y se limitaba a comparar. No alcanzaba: una misma
    --    sede/jornada puede tener mas de un periodo activo en el año en
    --    curso (ver V162), con lo cual el "periodo resuelto" no era
    --    determinista y el alta fallaba de forma intermitente aunque el
    --    grupo fuera correcto. Ahora el grupo -- que el usuario ya eligio
    --    explicitamente -- es lo que fija el periodo, y el resolver pasa a
    --    VALIDAR ese periodo en vez de adivinarlo.
    -- -----------------------------------------------------------------
    SELECT g.FK_TPERIODO_ACADEMICO
      INTO v_fk_periodo_del_grupo
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
     WHERE gr.PK_TGRUPO = p_fk_tgrupo
       AND gr.ACTIVE     = TRUE
       AND g.ACTIVE      = TRUE;

    IF v_fk_periodo_del_grupo IS NULL THEN
        RAISE EXCEPTION 'No se encontro un grupo activo con ese identificador'
            USING ERRCODE = '23503',
                  HINT    = 'p_fk_tgrupo debe apuntar a un TGRUPO activo con TGRADO activo';
    END IF;

    -- -----------------------------------------------------------------
    -- 3. Ese periodo debe ser un periodo vigente de (sede, jornada, año
    --    actual), visible para el solicitante, y con el periodo de
    --    inscripcion ya cerrado -- la matricula directa va DESPUES de ese
    --    cierre (ver V162). Las tres cosas las hace el resolver; se le
    --    pasa el grupo para que no tenga que desambiguar.
    -- -----------------------------------------------------------------
    v_pk_periodo := academico_test.fn_periodo_resolver_matricula(
        p_fk_sede := p_fk_sede,
        p_fk_tlv_jornada := p_fk_tlv_jornada,
        p_pk_usuario := p_pk_usuario_solicitante,
        p_fk_tgrupo := p_fk_tgrupo
    );

    -- Asercion defensiva: con p_fk_tgrupo el resolver solo puede devolver
    -- el periodo del grupo o levantar excepcion.
    IF v_fk_periodo_del_grupo <> v_pk_periodo THEN
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
    -- 8. Permisos de acceso: estudiante y acudiente quedan vinculados a
    --    la SEDE en TSEDE_USUARIO, con su rol (15 = Estudiante,
    --    16 = Acudiente) y la jornada del periodo resuelto -- mismo
    --    layout que las 73.460 / 54.080 filas que ya existen para esos
    --    roles (ORDEN=0, TLV_ESTADO='ACTIVO', PREDETERMINADO=0).
    --
    --    INSERT directo y no fn_sede_usuario_crear a proposito: el gate
    --    de esa funcion exige fn_puede_afectar_usuarios (roles 1-3/7-8/9
    --    via TSEDE_USUARIO) o coordinador, y su rama de coordinador
    --    EXCLUYE explicitamente los roles 15/16 -- no fue pensada para
    --    este caso. Un rector/secretaria asignado solo por FK
    --    (TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR, sin TSEDE_USUARIO
    --    propio todavia -- el caso que documenta el fallback de
    --    fn_usu_crear) pasa el gate estricto del paso 1 de esta funcion
    --    pero NO el de fn_sede_usuario_crear: delegar ahi haria fallar
    --    con 42501 un alta legitima, despues de haber creado ya
    --    estudiante, acudiente y nucleo familiar. La autorizacion sobre
    --    esta sede ya quedo validada en el paso 1.
    --
    --    Idempotente por el indice unico uk_tsede_usuario_1
    --    (fk_tsede, fk_trol, fk_tusuario, fk_tlv_jornada) WHERE active:
    --    si la persona ya tenia ese permiso (p.ej. un acudiente que ya
    --    era acudiente de otro hijo en la misma sede y jornada, o una
    --    rematricula), no se duplica.
    --
    --    REV -- TSEDE_USUARIO tiene un SEGUNDO indice unico parcial que
    --    esta version no contemplaba:
    --
    --      uk_tsede_usuario_2 (fk_tsede, fk_trol, fk_tusuario, orden)
    --
    --    Con ORDEN fijo en 0, una persona que ya tenia un permiso en
    --    esta sede y rol pero en OTRA JORNADA pasa el primer indice (la
    --    jornada cambia) y viola el segundo (misma terna, ORDEN=0 otra
    --    vez). El caso salio a la luz en V175 al promover a un grupo de
    --    otra jornada; aca es mucho menos alcanzable -- lo tapa la
    --    validacion de "una matricula activa por año lectivo" -- pero es
    --    la misma falla, asi que se cierra igual: ORDEN pasa a ser el
    --    siguiente disponible para esa terna. Mismo calculo que
    --    fn_matricula_mover_lote.
    -- -----------------------------------------------------------------
    INSERT INTO academico_test.TSEDE_USUARIO (
        FK_TSEDE, FK_TROL, FK_TUSUARIO, FK_TLV_JORNADA,
        ORDEN, TLV_ESTADO, PREDETERMINADO,
        CREATED_BY, CREATED_AT, ACTIVE
    )
    SELECT p_fk_sede, v.rol, v.usuario, p_fk_tlv_jornada,
           COALESCE((SELECT MAX(su2.ORDEN) + 1
                       FROM academico_test.TSEDE_USUARIO su2
                      WHERE su2.FK_TSEDE    = p_fk_sede
                        AND su2.FK_TROL     = v.rol
                        AND su2.FK_TUSUARIO = v.usuario
                        AND su2.ACTIVE      = TRUE), 0),
           'ACTIVO', 0,
           p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
      FROM (VALUES
                (c_fk_trol_estudiante, p_pk_usuario_estudiante),
                (c_fk_trol_acudiente,  p_pk_usuario_padre)
           ) AS v(rol, usuario)
     WHERE v.usuario IS NOT NULL
       AND NOT EXISTS (
           SELECT 1
             FROM academico_test.TSEDE_USUARIO su
            WHERE su.FK_TSEDE        = p_fk_sede
              AND su.FK_TROL         = v.rol
              AND su.FK_TUSUARIO     = v.usuario
              AND su.FK_TLV_JORNADA  = p_fk_tlv_jornada
              AND su.ACTIVE          = TRUE
       );

    -- -----------------------------------------------------------------
    -- 9. Crear la TMATRICULA. FK_TLV_ESTADO_MATRICULA se resuelve aca
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
    -- 10. Crear el TMATRICULA_SOCIOECONOMICO asociado -- se crea siempre
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
    -- 11. Enlazar los archivos de soporte.
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

-- =============================================================================
-- fn_matricula_directa_eliminar -- ORQUESTADOR de baja, contraparte de
-- fn_matricula_directa_crear. Da de baja (logica, como todo el sistema) una
-- matricula y arrastra lo que corresponda de estudiante y acudiente.
--
-- Orden y politica de cada paso:
--
--   1. Gate estricto sede-especifico (el mismo del alta), resuelto contra la
--      sede de la matricula.
--   2. DEPENDENCIAS BLOQUEANTES: si de la matricula cuelga cualquier cosa que
--      no sea cascada libre -- calificaciones, comportamiento, asistencia,
--      actas, diplomas, promociones, retiros, traslados, convenios, carnet,
--      videos, asignaturas matriculadas, u otra matricula que la referencie
--      como antecedente -- se ABORTA nombrando la dependencia. No se borra
--      nada en cascada por conveniencia: el usuario tiene que eliminarlas
--      primero. Lo valida fn_matricula_soft_delete (V163) en el paso 5, pero
--      se consulta aca ANTES de tocar nada para que la cascada libre no se
--      desactive en una operacion que va a abortar igual.
--   3. Cascada libre: TMATRICULA_SOCIOECONOMICO (V164).
--   4. Cascada libre: TMATRICULA_ARCHIVO (V165) -- el enlace, no el binario.
--   5. La TMATRICULA (V163).
--   6. El estudiante (V160): retira siempre sus permisos de rol 15 en esa
--      sede; da de baja el TESTUDIANTE y sus vinculos de nucleo familiar solo
--      si no le queda nada colgando (observador incluido); y el TUSUARIO solo
--      si no cumple ningun otro papel.
--   7. Cada acudiente vinculado (V161): retira sus permisos de rol 16 en esa
--      sede; da de baja el TPADRE solo si dejo de ser acudiente de todos; y el
--      TUSUARIO bajo la misma condicion que el estudiante. Si sigue siendo
--      acudiente de otro estudiante, su vinculo con ESE otro no se toca.
--
-- Del 3 al 7 nada aborta: lo que no se pudo dar de baja se reporta en el
-- resultado con su motivo. Solo el gate, una matricula inexistente y las
-- dependencias bloqueantes producen error.
--
-- Atomica de punta a punta, como el alta: una sola funcion, sin bloque
-- EXCEPTION, invocada como una sola sentencia.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_directa_eliminar(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_tmatricula           BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_sede             BIGINT;
    v_fk_establecimiento  BIGINT;
    v_fk_testudiante  BIGINT;
    v_dependencia     TEXT;
    v_socio           INTEGER;
    v_archivos        INTEGER;
    v_est             RECORD;
    v_pad             RECORD;
    v_acudientes      JSONB := '[]'::jsonb;
    v_pk_tpadre       BIGINT;
BEGIN
    -- -----------------------------------------------------------------
    -- 1. Resolver sede y estudiante. El gate lo aplica en detalle
    --    fn_matricula_soft_delete; aca solo se necesita ubicar la
    --    matricula para saber contra que sede trabajar despues.
    -- -----------------------------------------------------------------
    SELECT pa.FK_TSEDE, m.FK_TESTUDIANTE
      INTO v_fk_sede, v_fk_testudiante
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr              ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO g               ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa   ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s                 ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE m.PK_TMATRICULA = p_pk_tmatricula
       AND m.ACTIVE        = TRUE
       AND gr.ACTIVE       = TRUE
       AND g.ACTIVE        = TRUE
       AND pa.ACTIVE       = TRUE
       AND s.ACTIVE        = TRUE;

    IF v_fk_sede IS NULL THEN
        RAISE EXCEPTION 'No se encontro una matricula activa con ese identificador'
            USING ERRCODE = '22023';
    END IF;

    -- -----------------------------------------------------------------
    -- 1b. Gate TEMPRANO, contra la sede de la matricula.
    --     fn_matricula_soft_delete (paso 5) aplica este mismo gate -- es su
    --     garantia si se la llama suelta -- pero adelantarlo evita que los
    --     pasos 3 y 4 desactiven la cascada libre antes de saber si el
    --     usuario podia siquiera tocar esta matricula. La transaccion lo
    --     revertiria igual, pero no tiene sentido hacer el trabajo.
    -- -----------------------------------------------------------------
    SELECT s.FK_TESTABLECIMIENTO INTO v_fk_establecimiento
      FROM academico_test.TSEDE s WHERE s.PK_TSEDE = v_fk_sede;

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
    -- 2. Chequeo temprano de dependencias bloqueantes. fn_matricula_soft_delete
    --    lo repite (es su propia garantia si se la llama suelta), pero
    --    adelantarlo evita desactivar la cascada libre de los pasos 3 y 4
    --    en una operacion que va a abortar de todas formas.
    -- -----------------------------------------------------------------
    v_dependencia := academico_test.fn_matricula_dependencias_bloqueantes(p_pk_tmatricula);

    IF v_dependencia IS NOT NULL THEN
        RAISE EXCEPTION 'No se puede eliminar la matricula: tiene % asociada(s)', v_dependencia
            USING ERRCODE = '23503',
                  HINT    = 'Elimine primero esa informacion y vuelva a intentarlo';
    END IF;

    -- -----------------------------------------------------------------
    -- 3-4. Cascada libre.
    -- -----------------------------------------------------------------
    v_socio    := academico_test.fn_matricula_socioeconomico_soft_delete(
                      p_pk_usuario_solicitante, p_pk_tmatricula);
    v_archivos := academico_test.fn_matricula_archivo_soft_delete(
                      p_pk_usuario_solicitante, p_pk_tmatricula);

    -- -----------------------------------------------------------------
    -- 5. La matricula (aplica el gate estricto y revalida dependencias).
    -- -----------------------------------------------------------------
    PERFORM academico_test.fn_matricula_soft_delete(
                p_pk_usuario_solicitante, p_pk_tmatricula);

    -- -----------------------------------------------------------------
    -- 6. Acudientes ANTES que el estudiante: fn_estudiante_soft_delete
    --    desactiva los vinculos de nucleo familiar de este estudiante, y
    --    fn_padre_soft_delete necesita leerlos para saber a quien tenia
    --    a cargo. Se recorren los que estaban vinculados a este
    --    estudiante; cada uno decide por su cuenta si se conserva.
    -- -----------------------------------------------------------------
    FOR v_pk_tpadre IN
        SELECT DISTINCT nf.FK_TPADRE
          FROM academico_test.TNUCLEO_FAMILIAR nf
          JOIN academico_test.TPADRE p ON p.PK_TPADRE = nf.FK_TPADRE
         WHERE nf.FK_TESTUDIANTE = v_fk_testudiante
           AND nf.ACTIVE         = TRUE
           AND p.ACTIVE          = TRUE
         ORDER BY nf.FK_TPADRE
    LOOP
        -- El vinculo con ESTE estudiante se desactiva aca, para que el
        -- conteo de fn_padre_soft_delete refleje solo a los demas.
        UPDATE academico_test.TNUCLEO_FAMILIAR
           SET ACTIVE      = FALSE,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TESTUDIANTE = v_fk_testudiante
           AND FK_TPADRE      = v_pk_tpadre
           AND ACTIVE         = TRUE;

        SELECT * INTO v_pad
          FROM academico_test.fn_padre_soft_delete(
                   p_pk_usuario_solicitante, v_pk_tpadre, v_fk_sede);

        v_acudientes := v_acudientes || jsonb_build_array(jsonb_build_object(
            'pkTpadre',           v_pk_tpadre,
            'permisosRetirados',  v_pad.permisos_retirados,
            'padreEliminado',     v_pad.padre_eliminado,
            'usuarioEliminado',   v_pad.usuario_eliminado,
            'motivoConservacion', v_pad.motivo_conservacion));
    END LOOP;

    -- -----------------------------------------------------------------
    -- 7. El estudiante.
    -- -----------------------------------------------------------------
    SELECT * INTO v_est
      FROM academico_test.fn_estudiante_soft_delete(
               p_pk_usuario_solicitante, v_fk_testudiante, v_fk_sede, p_pk_tmatricula);

    RETURN jsonb_build_object(
        'pkTmatricula',            p_pk_tmatricula,
        'socioeconomicoEliminado', v_socio,
        'archivosEliminados',      v_archivos,
        'estudiante', jsonb_build_object(
            'pkTestudiante',       v_fk_testudiante,
            'permisosRetirados',   v_est.permisos_retirados,
            'estudianteEliminado', v_est.estudiante_eliminado,
            'usuarioEliminado',    v_est.usuario_eliminado,
            'motivoConservacion',  v_est.motivo_conservacion),
        'acudientes', v_acudientes
    );
END;
$function$;

-- =============================================================================
-- fn_matricula_directa_eliminar_bulk -- baja de varias matriculas en una sola
-- llamada. Mismo patron que fn_sed_soft_delete_bulk /
-- fn_fun_baja_establecimiento_bulk: cada PK corre en su propio bloque
-- BEGIN/EXCEPTION (savepoint implicito), asi que un fallo en una NO aborta
-- las demas ni deshace lo ya dado de baja.
--
-- Devuelve una fila por PK recibido, con:
--   status  -- 'eliminado' o 'error:<motivo>'
--   detalle -- el JSONB de fn_matricula_directa_eliminar cuando salio bien
--              (que estudiante/acudiente se conservaron y por que), o el
--              mensaje exacto cuando fallo. Para 'error:dependencias' ese
--              mensaje es el que nombra la dependencia que bloqueo, que es
--              justo lo que el usuario necesita leer para saber que borrar
--              primero.
--
-- Los PK se deduplican y se ordenan: repetir uno en la lista no lo procesa
-- dos veces (el segundo intento daria 'error:no_encontrado', que seria ruido).
--
-- OJO con la atomicidad: a diferencia del alta y de la baja individual, esta
-- funcion NO es todo-o-nada por diseño -- eso es exactamente lo que se pide
-- ("se borran las que se puedan asi otras hayan fallado"). Cada matricula si
-- es atomica en si misma.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_directa_eliminar_bulk(
    p_pk_usuario_solicitante  BIGINT,
    p_pks                     BIGINT[]
)
RETURNS TABLE (
    pk_tmatricula  BIGINT,
    status         VARCHAR,
    detalle        JSONB
)
LANGUAGE plpgsql
AS $function$
DECLARE
    v_pk  BIGINT;
    v_res JSONB;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;
    IF p_pks IS NULL OR CARDINALITY(p_pks) = 0 THEN
        RAISE EXCEPTION 'p_pks es obligatorio y debe contener al menos un PK_TMATRICULA'
            USING ERRCODE = '22023';
    END IF;

    FOR v_pk IN SELECT DISTINCT x FROM unnest(p_pks) AS x ORDER BY x
    LOOP
        BEGIN
            v_res := academico_test.fn_matricula_directa_eliminar(
                         p_pk_usuario_solicitante, v_pk);
            pk_tmatricula := v_pk;
            status        := 'eliminado';
            detalle       := v_res;
            RETURN NEXT;
        EXCEPTION
            WHEN SQLSTATE '22023' THEN
                pk_tmatricula := v_pk;
                status        := 'error:no_encontrado';
                detalle       := jsonb_build_object('mensaje', SQLERRM);
                RETURN NEXT;
            WHEN SQLSTATE '42501' THEN
                pk_tmatricula := v_pk;
                status        := 'error:sin_permiso';
                detalle       := jsonb_build_object('mensaje', SQLERRM);
                RETURN NEXT;
            WHEN SQLSTATE '23503' THEN
                pk_tmatricula := v_pk;
                status        := 'error:dependencias';
                detalle       := jsonb_build_object('mensaje', SQLERRM);
                RETURN NEXT;
            WHEN OTHERS THEN
                pk_tmatricula := v_pk;
                status        := 'error:' || SQLSTATE;
                detalle       := jsonb_build_object('mensaje', SQLERRM);
                RETURN NEXT;
        END;
    END LOOP;
END;
$function$;

-- =============================================================================
-- fn_matricula_retirar -- retiro de una matricula: cambio de estado
-- "Cursando" -> "Retirado", mas el registro del retiro en
-- TRETIRO_MATRICULA (fecha, hora y usuario responsable).
--
-- NO es una baja: la fila y toda su informacion historica (socioeconomico,
-- archivos, vinculos del nucleo familiar, permisos de sede) quedan intactos.
-- De TMATRICULA solo cambia FK_TLV_ESTADO_MATRICULA.
--
-- Unica transicion permitida: Cursando -> Retirado. Si la matricula esta en
-- cualquier otro estado (Aprobado, Retirado ya, Trasladado, Graduado...) se
-- aborta nombrando el estado actual, para que el caller sepa por que.
--
-- Los dos estados se resuelven por VALOR contra TLISTA_VALOR
-- (CATEGORIA='ESTADO_MATRICULA', '1'=Cursando, '4'=Retirado) y no por PK
-- hardcodeado -- mismo criterio que fn_matricula_directa_crear.
--
-- ---------------------------------------------------------------------------
-- GATE: igual al del resto del modulo PERO SIN LA RAMA DE SUPER-ADMIN
-- ---------------------------------------------------------------------------
-- A diferencia de crear/eliminar/consultar, aca NO se acepta a alguien solo
-- por ser super-admin (fn_puede_afectar_establecimiento). El retiro es una
-- decision administrativa del establecimiento sobre sus propios estudiantes,
-- y se pidio explicitamente que un super-admin no pueda ejecutarla para
-- evitar conflictos en el manejo de los datos de cada institucion.
--
-- Quedan entonces tres caminos, todos con vinculo REAL con la sede de la
-- matricula: rector del EE (por FK), secretaria del EE (por FK), o jefe de
-- sistema (rol 8) en alguna sede del EE. Un super-admin que ADEMAS sea
-- rector/secretaria/jefe de sistema de ese EE si pasa -- entra por su vinculo
-- con la institucion, no por su condicion de super-admin.
--
-- NOTA: esto lo deja inconsistente a proposito con las funciones ya
-- existentes del modulo, donde el super-admin si tiene acceso. Cuando el
-- validador de permisos dinamico este listo, esta funcion y las demas se
-- adaptan a el y se unifica el criterio.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_retirar(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_tmatricula           BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_establecimiento  BIGINT;
    v_estado_actual       BIGINT;
    v_estado_actual_nom   VARCHAR;
    v_pk_cursando         BIGINT;
    v_pk_retirado         BIGINT;
    v_pk_retiro           BIGINT;
    v_fecha_retiro        DATE;
    v_hora_retiro         TIMESTAMP;
BEGIN
    -- -----------------------------------------------------------------
    -- 1. Ubicar la matricula y su EE.
    -- -----------------------------------------------------------------
    SELECT s.FK_TESTABLECIMIENTO, m.FK_TLV_ESTADO_MATRICULA
      INTO v_fk_establecimiento, v_estado_actual
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr              ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO g               ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa   ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s                 ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE m.PK_TMATRICULA = p_pk_tmatricula
       AND m.ACTIVE        = TRUE
       AND gr.ACTIVE       = TRUE
       AND g.ACTIVE        = TRUE
       AND pa.ACTIVE       = TRUE
       AND s.ACTIVE        = TRUE;

    IF v_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'No se encontro una matricula activa con ese identificador'
            USING ERRCODE = '22023',
                  HINT    = 'p_pk_tmatricula debe apuntar a un TMATRICULA activo, con grupo/grado/periodo/sede activos';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Gate -- SIN rama de super-admin (ver cabecera).
    -- -----------------------------------------------------------------
    IF EXISTS (
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
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para retirar esta matricula'
            USING ERRCODE = '42501',
                  HINT    = 'El retiro solo puede hacerlo el rector, la secretaria o el jefe de sistema del establecimiento de la matricula';
    END IF;

    -- -----------------------------------------------------------------
    -- 3. Resolver los dos estados por VALOR.
    -- -----------------------------------------------------------------
    SELECT PK_LISTA_VALOR INTO v_pk_cursando
      FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ESTADO_MATRICULA' AND VALOR = '1' AND ACTIVE = TRUE;
    SELECT PK_LISTA_VALOR INTO v_pk_retirado
      FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ESTADO_MATRICULA' AND VALOR = '4' AND ACTIVE = TRUE;

    IF v_pk_cursando IS NULL OR v_pk_retirado IS NULL THEN
        RAISE EXCEPTION 'El catalogo ESTADO_MATRICULA no tiene los estados requeridos (VALOR 1=Cursando, 4=Retirado)'
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 4. Solo se puede retirar lo que esta Cursando.
    -- -----------------------------------------------------------------
    IF v_estado_actual IS DISTINCT FROM v_pk_cursando THEN
        SELECT NOMBRE INTO v_estado_actual_nom
          FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = v_estado_actual;

        RAISE EXCEPTION 'Solo se puede retirar una matricula en estado "Cursando"; esta figura como "%"',
            COALESCE(v_estado_actual_nom, 'sin estado')
            USING ERRCODE = '22023';
    END IF;

    -- -----------------------------------------------------------------
    -- 5. Cambio de estado. Nada mas se toca: la matricula sigue ACTIVE y
    --    conserva socioeconomico, archivos, nucleo familiar y permisos.
    -- -----------------------------------------------------------------
    UPDATE academico_test.TMATRICULA
       SET FK_TLV_ESTADO_MATRICULA = v_pk_retirado,
           MODIFIED_BY             = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT             = CURRENT_TIMESTAMP
     WHERE PK_TMATRICULA = p_pk_tmatricula;

    -- -----------------------------------------------------------------
    -- 6. Registro del retiro en TRETIRO_MATRICULA -- fecha, hora y usuario
    --    responsable.
    --
    --    OJO con la hora: FECHA_RETIRO es DATE, o sea SOLO el dia, sin
    --    hora. La hora exacta queda en CREATED_AT (timestamp), que es de
    --    donde hay que leerla si el negocio la necesita. El usuario
    --    responsable va en CREATED_BY, igual que en el resto del modulo.
    --
    --    MOTIVO_RETIRO y FK_TLV_TIPO_MOTIVO_RETIRO quedan en NULL: por
    --    ahora no se captura el motivo (ambas columnas son nullable).
    --    FECHA_REINTEGRO tambien -- esa la llenaria el reingreso.
    --
    --    El PK es IDENTITY, asi que no se pasa explicito.
    -- -----------------------------------------------------------------
    INSERT INTO academico_test.TRETIRO_MATRICULA (
        FK_TMATRICULA, FECHA_RETIRO,
        CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        p_pk_tmatricula, CURRENT_DATE,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TRETIRO_MATRICULA, FECHA_RETIRO, CREATED_AT
         INTO v_pk_retiro, v_fecha_retiro, v_hora_retiro;

    RETURN jsonb_build_object(
        'pkTmatricula',  p_pk_tmatricula,
        'estadoAnterior', jsonb_build_object('id', v_pk_cursando, 'nombre', 'Cursando'),
        'estadoNuevo',    jsonb_build_object('id', v_pk_retirado, 'nombre', 'Retirado'),
        'retiro', jsonb_build_object(
            'pkTretiroMatricula', v_pk_retiro,
            'fecha',              v_fecha_retiro,
            'hora',               v_hora_retiro,
            'responsable',        p_pk_usuario_solicitante)
    );
END;
$function$;

-- =============================================================================
-- fn_matricula_reingresar -- reingreso de una matricula retirada: cambio de
-- estado "Retirado" -> "Cursando", y cierre del registro de retiro
-- correspondiente (TRETIRO_MATRICULA.FECHA_REINTEGRO).
--
-- Contraparte exacta de fn_matricula_retirar: mismo gate, misma logica de
-- transicion unica, mismos catalogos resueltos por VALOR. La unica transicion
-- permitida es Retirado -> Cursando; cualquier otro estado aborta nombrando
-- el actual.
--
-- No hay tabla propia de reingreso: se cierra el retiro llenando su
-- FECHA_REINTEGRO. Se actualiza el registro ACTIVO MAS RECIENTE que aun no
-- tenga FECHA_REINTEGRO -- no deberia haber mas de uno abierto a la vez, pero
-- si los hubiera se cierra el ultimo, que es el que corresponde al estado
-- actual de la matricula.
--
-- IMPORTANTE -- puede no haber ningun registro que cerrar, y eso NO es error:
-- las 3.542 matriculas que ya estaban en "Retirado" antes de que existiera
-- fn_matricula_retirar no tienen fila en TRETIRO_MATRICULA (la tabla estaba
-- vacia). Para esas, el reingreso hace el cambio de estado igual y lo informa
-- en el resultado con retiroCerrado = null.
--
-- GATE: identico a fn_matricula_retirar -- SIN rama de super-admin. Solo
-- rector, secretaria o jefe de sistema del establecimiento de la matricula.
-- Un super-admin que ademas tenga alguno de esos cargos en ese EE si pasa,
-- por su vinculo con la institucion.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_reingresar(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_tmatricula           BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_establecimiento  BIGINT;
    v_estado_actual       BIGINT;
    v_estado_actual_nom   VARCHAR;
    v_pk_cursando         BIGINT;
    v_pk_retirado         BIGINT;
    v_pk_retiro           BIGINT;
    v_fecha_reintegro     DATE;
BEGIN
    -- -----------------------------------------------------------------
    -- 1. Ubicar la matricula y su EE.
    -- -----------------------------------------------------------------
    SELECT s.FK_TESTABLECIMIENTO, m.FK_TLV_ESTADO_MATRICULA
      INTO v_fk_establecimiento, v_estado_actual
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr              ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO g               ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa   ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s                 ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE m.PK_TMATRICULA = p_pk_tmatricula
       AND m.ACTIVE        = TRUE
       AND gr.ACTIVE       = TRUE
       AND g.ACTIVE        = TRUE
       AND pa.ACTIVE       = TRUE
       AND s.ACTIVE        = TRUE;

    IF v_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'No se encontro una matricula activa con ese identificador'
            USING ERRCODE = '22023',
                  HINT    = 'p_pk_tmatricula debe apuntar a un TMATRICULA activo, con grupo/grado/periodo/sede activos';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Gate -- SIN rama de super-admin (ver cabecera).
    -- -----------------------------------------------------------------
    IF EXISTS (
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
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para reingresar esta matricula'
            USING ERRCODE = '42501',
                  HINT    = 'El reingreso solo puede hacerlo el rector, la secretaria o el jefe de sistema del establecimiento de la matricula';
    END IF;

    -- -----------------------------------------------------------------
    -- 3. Resolver los dos estados por VALOR.
    -- -----------------------------------------------------------------
    SELECT PK_LISTA_VALOR INTO v_pk_cursando
      FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ESTADO_MATRICULA' AND VALOR = '1' AND ACTIVE = TRUE;
    SELECT PK_LISTA_VALOR INTO v_pk_retirado
      FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ESTADO_MATRICULA' AND VALOR = '4' AND ACTIVE = TRUE;

    IF v_pk_cursando IS NULL OR v_pk_retirado IS NULL THEN
        RAISE EXCEPTION 'El catalogo ESTADO_MATRICULA no tiene los estados requeridos (VALOR 1=Cursando, 4=Retirado)'
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 4. Solo se puede reingresar lo que esta Retirado.
    -- -----------------------------------------------------------------
    IF v_estado_actual IS DISTINCT FROM v_pk_retirado THEN
        SELECT NOMBRE INTO v_estado_actual_nom
          FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = v_estado_actual;

        RAISE EXCEPTION 'Solo se puede reingresar una matricula en estado "Retirado"; esta figura como "%"',
            COALESCE(v_estado_actual_nom, 'sin estado')
            USING ERRCODE = '22023';
    END IF;

    -- -----------------------------------------------------------------
    -- 5. Cambio de estado.
    -- -----------------------------------------------------------------
    UPDATE academico_test.TMATRICULA
       SET FK_TLV_ESTADO_MATRICULA = v_pk_cursando,
           MODIFIED_BY             = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT             = CURRENT_TIMESTAMP
     WHERE PK_TMATRICULA = p_pk_tmatricula;

    -- -----------------------------------------------------------------
    -- 6. Cerrar el retiro abierto mas reciente, si lo hay.
    --    ORDER BY CREATED_AT DESC + PK como desempate: dos retiros del
    --    mismo instante (poco probable, pero el timestamp no es unico)
    --    se resuelven por el PK, que si lo es.
    -- -----------------------------------------------------------------
    SELECT PK_TRETIRO_MATRICULA
      INTO v_pk_retiro
      FROM academico_test.TRETIRO_MATRICULA
     WHERE FK_TMATRICULA    = p_pk_tmatricula
       AND ACTIVE           = TRUE
       AND FECHA_REINTEGRO IS NULL
     ORDER BY CREATED_AT DESC, PK_TRETIRO_MATRICULA DESC
     LIMIT 1;

    IF v_pk_retiro IS NOT NULL THEN
        UPDATE academico_test.TRETIRO_MATRICULA
           SET FECHA_REINTEGRO = CURRENT_DATE,
               MODIFIED_BY     = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT     = CURRENT_TIMESTAMP
         WHERE PK_TRETIRO_MATRICULA = v_pk_retiro
        RETURNING FECHA_REINTEGRO INTO v_fecha_reintegro;
    END IF;

    RETURN jsonb_build_object(
        'pkTmatricula',   p_pk_tmatricula,
        'estadoAnterior', jsonb_build_object('id', v_pk_retirado, 'nombre', 'Retirado'),
        'estadoNuevo',    jsonb_build_object('id', v_pk_cursando, 'nombre', 'Cursando'),
        'retiroCerrado',  CASE WHEN v_pk_retiro IS NULL THEN NULL
                               ELSE jsonb_build_object(
                                   'pkTretiroMatricula', v_pk_retiro,
                                   'fechaReintegro',     v_fecha_reintegro,
                                   'responsable',        p_pk_usuario_solicitante)
                          END
    );
END;
$function$;

-- =============================================================================
-- fn_matricula_reactivar -- reactivacion de una matricula CERRADA por fin de
-- ciclo, para corregir o completar informacion academica antes del cierre
-- definitivo. Cambia el estado a "Cursando".
--
-- Se diferencia del reingreso (fn_matricula_reingresar) SOLO en los estados
-- de origen: el reingreso atiende "Retirado" (el estudiante se fue), esta
-- atiende los estados de cierre academico. Ninguna de las dos toca
-- TRETIRO_MATRICULA aca -- reactivar no cierra ningun retiro porque no hubo
-- retiro que cerrar.
--
-- ESTADOS DE ORIGEN PERMITIDOS (resueltos por VALOR, no por PK):
--     '2'  Aprobado
--     '3'  Reprobado
--     '13' Promovido   -- creado en V174
--     '14' Reubicado   -- creado en V174
--
-- REV -- la primera version usaba '6' "Promovido Anticipadamente" como
-- sustituto de "Promovido", porque "Promovido" y "Reubicado" no existian en
-- el catalogo (se busco en ESTADO_MATRICULA y en TODO TLISTA_VALOR). V174
-- creo ambos como estados propios y la nueva app NO usa el anticipado, asi
-- que '6' SALE de la lista: las 6 matriculas heredadas que hoy lo tienen no
-- se pueden reactivar por esta via. Si el negocio pide cubrirlas, se suma
-- '6' al array de abajo y no hace falta tocar nada mas.
--
-- Quedan FUERA los demas estados heredados: "Retirado" (4, tiene su propio
-- endpoint de reingreso), "Graduado" (5), "Promovido Anticipadamente" (6),
-- "Trasladado" (7), "Sin definir" (9), "Desertor" (10), "Esperando
-- Aprobacion" (11) y "Rechazado" (12). El negocio todavia esta definiendo
-- cuales de esos conserva la nueva version; ninguno se desactivo. A medida
-- que se confirmen, entrar aca es agregar su VALOR al array.
--
-- Sin restriccion temporal: se puede reactivar una matricula de cualquier
-- año lectivo, incluso cerrado. Asi se pidio explicitamente.
--
-- GATE: identico a retirar/reingresar -- SIN rama de super-admin.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_reactivar(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_tmatricula           BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_establecimiento  BIGINT;
    v_estado_actual       BIGINT;
    v_estado_actual_nom   VARCHAR;
    v_pk_cursando         BIGINT;
    v_reactivables        BIGINT[];
    v_permitidos_nom      TEXT;
    -- Estados de cierre desde los que SI se puede volver a Cursando:
    -- Aprobado, Reprobado, Promovido, Reubicado (ver cabecera).
    c_valores_reactivables CONSTANT VARCHAR[] := ARRAY['2', '3', '13', '14'];
BEGIN
    -- -----------------------------------------------------------------
    -- 1. Ubicar la matricula y su EE.
    -- -----------------------------------------------------------------
    SELECT s.FK_TESTABLECIMIENTO, m.FK_TLV_ESTADO_MATRICULA
      INTO v_fk_establecimiento, v_estado_actual
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr              ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO g               ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa   ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s                 ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE m.PK_TMATRICULA = p_pk_tmatricula
       AND m.ACTIVE        = TRUE
       AND gr.ACTIVE       = TRUE
       AND g.ACTIVE        = TRUE
       AND pa.ACTIVE       = TRUE
       AND s.ACTIVE        = TRUE;

    IF v_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'No se encontro una matricula activa con ese identificador'
            USING ERRCODE = '22023',
                  HINT    = 'p_pk_tmatricula debe apuntar a un TMATRICULA activo, con grupo/grado/periodo/sede activos';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Gate -- SIN rama de super-admin (ver cabecera).
    -- -----------------------------------------------------------------
    IF EXISTS (
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
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para reactivar esta matricula'
            USING ERRCODE = '42501',
                  HINT    = 'La reactivacion solo puede hacerla el rector, la secretaria o el jefe de sistema del establecimiento de la matricula';
    END IF;

    -- -----------------------------------------------------------------
    -- 3. Resolver el estado destino y los de origen permitidos, por VALOR.
    -- -----------------------------------------------------------------
    SELECT PK_LISTA_VALOR INTO v_pk_cursando
      FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ESTADO_MATRICULA' AND VALOR = '1' AND ACTIVE = TRUE;

    SELECT ARRAY_AGG(PK_LISTA_VALOR), STRING_AGG(NOMBRE, ', ' ORDER BY VALOR::INT)
      INTO v_reactivables, v_permitidos_nom
      FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ESTADO_MATRICULA'
       AND VALOR = ANY(c_valores_reactivables)
       AND ACTIVE = TRUE;

    IF v_pk_cursando IS NULL OR v_reactivables IS NULL OR CARDINALITY(v_reactivables) = 0 THEN
        RAISE EXCEPTION 'El catalogo ESTADO_MATRICULA no tiene los estados requeridos para reactivar'
            USING ERRCODE = '23503';
    END IF;

    -- Nombre del estado actual: se resuelve SIEMPRE, no solo en el camino
    -- de error -- tambien se devuelve en el resultado como estadoAnterior.
    SELECT NOMBRE INTO v_estado_actual_nom
      FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = v_estado_actual;

    -- -----------------------------------------------------------------
    -- 4. El estado actual debe ser uno de los reactivables.
    -- -----------------------------------------------------------------
    IF NOT (v_estado_actual = ANY(v_reactivables)) THEN
        RAISE EXCEPTION 'Solo se puede reactivar una matricula en estado %; esta figura como "%"',
            v_permitidos_nom, COALESCE(v_estado_actual_nom, 'sin estado')
            USING ERRCODE = '22023';
    END IF;

    -- -----------------------------------------------------------------
    -- 5. Cambio de estado. Igual que retirar/reingresar, la matricula
    --    conserva todo lo demas intacto.
    -- -----------------------------------------------------------------
    UPDATE academico_test.TMATRICULA
       SET FK_TLV_ESTADO_MATRICULA = v_pk_cursando,
           MODIFIED_BY             = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT             = CURRENT_TIMESTAMP
     WHERE PK_TMATRICULA = p_pk_tmatricula;

    RETURN jsonb_build_object(
        'pkTmatricula',   p_pk_tmatricula,
        'estadoAnterior', jsonb_build_object('id', v_estado_actual, 'nombre', v_estado_actual_nom),
        'estadoNuevo',    jsonb_build_object('id', v_pk_cursando,   'nombre', 'Cursando'),
        'responsable',    p_pk_usuario_solicitante
    );
END;
$function$;
