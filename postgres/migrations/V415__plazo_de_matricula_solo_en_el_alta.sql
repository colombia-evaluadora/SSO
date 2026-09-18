-- ===========================================================================
-- V415 - El plazo de matricula se valida en el ALTA, no al resolver el
--        periodo. Arregla la edicion y el modificar de matricula.
--
--   fn_matricula_validar_plazo_matricula  la regla, ahora con nombre propio
--   fn_periodo_resolver_matricula         pierde el gate: vuelve a resolver
--   fn_matricula_directa_crear            lo hereda, que es de quien era
--
--
-- EL SINTOMA
--   Editar una matricula, o abrir el dialogo de modificar (promover,
--   reubicar, cambiar de sede), respondia 22023 "La fecha limite de
--   matricula de este periodo academico ya paso" en cuanto el plazo habia
--   vencido -- que es el caso de casi todos los periodos configurados.
--
--
-- LA CAUSA
--   La validacion estaba dentro de fn_periodo_resolver_matricula, que NO es
--   una funcion de alta: es la consulta que traduce (sede, jornada, año) al
--   periodo academico correspondiente. El front la llama por
--   POST /periodos/resolver-matricula desde TRES pantallas, y solo una de
--   las tres matricula:
--
--     alta de matricula        necesita el gate
--     edicion de la matricula  solo quiere el periodo, para poder listar
--                              los grados y los grupos del formulario
--     modificar matricula      idem
--
--   Con el gate ahi dentro, las dos que no matriculan fallaban por una
--   regla que no las gobierna. La suya es otra y ya existe:
--   fn_matricula_validar_periodo_vigente, que corta por FECHA_FIN -- que el
--   periodo no haya TERMINADO --, y que ambas siguen respetando.
--
--   Conviene ser preciso sobre V352: NO introdujo el defecto, lo hizo
--   visible. Antes de V352 el gate exigia lo contrario (que la fecha YA
--   hubiera vencido), asi que el bloqueo caia sobre el otro lado de la
--   raya: se podia editar una matricula de plazo vencido y no una de plazo
--   vigente. Igual de arbitrario, y con los datos de hoy -- 20 periodos
--   vencidos contra 2 vigentes -- practicamente invisible.
--
--
-- IMPACTO MEDIDO (servidor de test, hoy)
--   De los 22 periodos activos del año en curso:
--
--     11  plazo vencido pero periodo TODAVIA en curso  <- los rotos
--      2  plazo vigente y periodo en curso
--      9  periodo ya terminado (esos los bloquea, con razon,
--         fn_matricula_validar_periodo_vigente)
--
--   Esos 11 periodos agrupan 1.612 matriculas activas que la regla de
--   edicion si permite tocar y que el resolver estaba bloqueando.
--
--
-- LO QUE NO CAMBIA
--   La regla de negocio: solo se puede matricular hasta la fecha limite.
--   Sigue siendo exactamente el mismo corte (CURRENT_DATE > fecha limite),
--   el mismo SQLSTATE 22023 y el mismo texto de error; lo unico distinto es
--   que se evalua al guardar el alta en vez de al resolver el periodo. El
--   alta sigue siendo imposible fuera de plazo.
--
--   El resto del resolver queda igual: la resolucion por (sede, jornada,
--   año), el desempate determinista por FECHA_LIMITE_MATRICULA DESC + PK
--   DESC -- la fecha se sigue usando para ordenar, solo que ya no para
--   rechazar --, la verificacion contra p_fk_tgrupo y el filtro por alcance
--   del solicitante.
--
--   Tampoco cambia el endpoint: misma ruta, mismo cuerpo, mismos
--   parametros. El front no se toca.
--
--
-- POR QUE UNA FUNCION Y NO UN IF SUELTO EN EL ALTA
--   Porque el dia que la prematricula y la reserva de cupo entren -- las
--   dos vias de alta que quedaron fuera de este entregable, ver V352 --
--   van a necesitar el mismo corte, y entonces sera una llamada y no una
--   copia del IF. Y porque un nombre dice lo que un IF de dos lineas no:
--   esta validando el PLAZO DE MATRICULA, que es distinto de que el
--   periodo siga vigente.
--
-- Idempotente: CREATE OR REPLACE con las mismas firmas. La funcion nueva
-- devuelve VOID y las dos que se reemplazan conservan su tipo de retorno
-- (BIGINT y RETURNS TABLE, respectivamente), asi que ninguna necesita DROP
-- previo.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. La regla, con nombre propio.
--
--    Mismo corte, mismo SQLSTATE y mismo texto que tenia dentro del
--    resolver desde V352: solo se puede matricular hasta la fecha limite
--    configurada en el periodo academico.
--
--    Se llama fn_matricula_validar_PLAZO_matricula para no confundirla con
--    fn_matricula_validar_PERIODO_vigente (V162), que es la otra regla
--    temporal del modulo y decide otra cosa: aquella corta por FECHA_FIN
--    ("el año ya termino, esta matricula es historia") y gobierna TODAS las
--    acciones sobre una matricula ya creada -- editar, retirar, reingresar,
--    reactivar, promover, reubicar. Esta corta por FECHA_LIMITE_MATRICULA
--    ("el plazo para matricular se cerro") y gobierna unicamente el alta.
--
--    Un periodo puede estar en curso con el plazo vencido: es justo el caso
--    de 11 de los 22 periodos del año en el servidor de test. Ahi se puede
--    editar pero no matricular, que es exactamente lo que el negocio pide.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_matricula_validar_plazo_matricula(
    p_pk_periodo BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_fecha_limite DATE;
BEGIN
    SELECT pa.FECHA_LIMITE_MATRICULA
      INTO v_fecha_limite
      FROM academico_test.TPERIODO_ACADEMICO pa
     WHERE pa.PK_TPERIODO_ACADEMICO = p_pk_periodo;

    -- Sin fecha configurada no se bloquea: es la misma tolerancia que tenia
    -- el IF anterior, donde CURRENT_DATE > NULL daba NULL y no entraba. Hoy
    -- la columna esta llena en los 367 periodos activos, asi que es una red
    -- de seguridad, no un caso real.
    IF v_fecha_limite IS NOT NULL AND CURRENT_DATE > v_fecha_limite THEN
        RAISE EXCEPTION 'La fecha limite de matricula de este periodo academico ya paso (vencio %)',
            v_fecha_limite
            USING ERRCODE = '22023',
                  HINT    = 'Solo se puede matricular hasta la fecha limite configurada en el periodo academico';
    END IF;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_matricula_validar_plazo_matricula(BIGINT)
    IS 'Levanta 22023 si el plazo para matricular de ese periodo academico ya vencio (CURRENT_DATE > FECHA_LIMITE_MATRICULA). Gobierna UNICAMENTE el alta -- es fn_matricula_directa_crear quien la invoca --, no las acciones sobre una matricula ya creada: esas las gobierna fn_matricula_validar_periodo_vigente, que corta por FECHA_FIN. Son dos reglas distintas y un periodo puede estar en curso con el plazo vencido, en cuyo caso se puede editar o reubicar pero no matricular. Vivio dentro de fn_periodo_resolver_matricula desde V162 hasta V415, donde bloqueaba tambien a la edicion y al modificar, que llaman al mismo resolver solo para saber que periodo listar. Tolera FECHA_LIMITE_MATRICULA nula sin bloquear, igual que el IF que reemplaza. V415.';


-- ---------------------------------------------------------------------------
-- 2. fn_periodo_resolver_matricula: vuelve a ser solo un resolvedor.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_resolver_matricula(p_fk_sede bigint, p_fk_tlv_jornada bigint, p_pk_usuario bigint DEFAULT NULL::bigint, p_fk_tgrupo bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_pk_periodo    BIGINT;
    v_ano_actual    VARCHAR(4);
BEGIN
    v_ano_actual := EXTRACT(YEAR FROM CURRENT_DATE)::VARCHAR;

    -- -----------------------------------------------------------------
    -- 1. Resolver el periodo academico vigente para (sede, jornada, año
    --    actual). fn_periodo_usuario_puede_ver aplica el mismo gate de
    --    visibilidad que el resto del modulo de periodos -- si el
    --    solicitante no puede ver el periodo, se trata igual que si no
    --    existiera (no se filtra informacion de existencia a quien no
    --    tiene alcance).
    --
    --    REV -- fallback para rector/secretaria asignados SOLO por FK
    --    (TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR/SECRETARIA, sin
    --    TSEDE_USUARIO propio todavia). fn_periodo_usuario_puede_ver
    --    resuelve el alcance unicamente por TSEDE_USUARIO, asi que a esa
    --    persona le devolvia FALSE y esta funcion concluia "no existe el
    --    periodo" -- un mensaje ademas enganoso, porque el periodo si
    --    existe. El gate de fn_matricula_directa_crear SI acepta esa
    --    asignacion por FK, con lo cual el alta pasaba el gate y moria
    --    aca.
    --
    --    El fallback vive en NUESTRA funcion a proposito: no se toca
    --    fn_periodo_usuario_puede_ver ni el resto del modulo de periodos,
    --    que es de otro dueño y alimenta sus propias pantallas.
    --
    --    En la practica los permisos de rector/secretaria se crean solos
    --    al crear la sede (ver fn_sed_crear paso 6), asi que este camino
    --    deberia ser raro; queda como red de seguridad para el intervalo
    --    entre asignar el cargo y tener el permiso.
    -- -----------------------------------------------------------------
    -- Solo el PK: la fecha limite ya no se lee aca (ver V415 abajo). El
    -- ORDER BY si la sigue usando, como desempate.
    SELECT pa.PK_TPERIODO_ACADEMICO
      INTO v_pk_periodo
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TANO_LECTIVO al
        ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
      JOIN academico_test.TSEDE s
        ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE pa.FK_TSEDE        = p_fk_sede
       AND pa.FK_TLV_JORNADA  = p_fk_tlv_jornada
       AND al.NOMBRE          = v_ano_actual
       AND pa.ACTIVE          = TRUE
       AND al.ACTIVE          = TRUE
       AND (
             academico_test.fn_periodo_usuario_puede_ver(p_pk_usuario, pa.PK_TPERIODO_ACADEMICO)
             OR EXISTS (
                 SELECT 1
                   FROM academico_test.TESTABLECIMIENTO e
                   JOIN academico_test.TFUNCIONARIO f
                     ON f.PK_TFUNCIONARIO IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA)
                  WHERE e.PK_ESTABLECIMIENTO = s.FK_TESTABLECIMIENTO
                    AND e.ACTIVE      = TRUE
                    AND f.ACTIVE      = TRUE
                    AND f.FK_TUSUARIO = p_pk_usuario
             )
           )
       -- Desambiguacion por grupo: si el llamador ya eligio un grupo, el
       -- periodo buscado es el del grupo y no hay nada que elegir.
       AND (
             p_fk_tgrupo IS NULL
             OR pa.PK_TPERIODO_ACADEMICO = (
                    SELECT g.FK_TPERIODO_ACADEMICO
                      FROM academico_test.TGRUPO gr
                      JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
                     WHERE gr.PK_TGRUPO = p_fk_tgrupo
                       AND gr.ACTIVE    = TRUE
                       AND g.ACTIVE     = TRUE
                )
           )
     -- Desempate determinista para el caso sin grupo: el ultimo periodo
     -- configurado para esa sede/jornada/año.
     ORDER BY pa.FECHA_LIMITE_MATRICULA DESC, pa.PK_TPERIODO_ACADEMICO DESC
     LIMIT 1;

    IF v_pk_periodo IS NULL AND p_fk_tgrupo IS NOT NULL THEN
        -- Con grupo dado, "no hay periodo" significa en realidad que el
        -- grupo cuelga de otro periodo (otra sede, otra jornada, otro año)
        -- o que su grado/grupo esta inactivo. Mensaje propio para no
        -- confundirlo con una sede sin periodo configurado.
        RAISE EXCEPTION 'El grupo indicado no pertenece al periodo academico vigente de la sede y jornada dadas'
            USING ERRCODE = '22023',
                  HINT    = 'p_fk_tgrupo debe pertenecer (via TGRADO) a un periodo activo de p_fk_sede/p_fk_tlv_jornada en el año en curso';
    END IF;

    IF v_pk_periodo IS NULL THEN
        RAISE EXCEPTION 'No existe un periodo academico activo para la sede indicada, esa jornada y el año actual (%)',
            v_ano_actual
            USING ERRCODE = '23503',
                  HINT    = 'Verifique que la sede tenga un periodo academico configurado para esta jornada en el año en curso, o que el usuario tenga alcance sobre el';
    END IF;

    -- -----------------------------------------------------------------
    -- V415 -- AQUI YA NO SE VALIDA LA FECHA LIMITE DE MATRICULA.
    --
    --   El gate estuvo aca desde V162 y V352 lo invirtio (antes exigia que
    --   la fecha YA hubiera vencido; ahora, que NO). La regla es correcta,
    --   pero el sitio no: esta funcion no autoriza nada, RESUELVE cual es
    --   el periodo de (sede, jornada, año) -- y esa pregunta tiene la misma
    --   respuesta este el plazo abierto o cerrado.
    --
    --   El front la llama desde TRES pantallas a traves de
    --   POST /periodos/resolver-matricula, y solo una es un alta:
    --
    --     alta de matricula        necesita el gate
    --     edicion de la matricula  solo necesita el periodo, para listar
    --                              grados y grupos
    --     modificar matricula      idem (promover / reubicar / cambiar sede)
    --
    --   Con el gate aca, las dos ultimas fallaban con 22023 en cuanto el
    --   plazo vencia, aunque ni editar ni reubicar tengan nada que ver con
    --   el plazo para matricular: su regla temporal es otra y ya existe --
    --   fn_matricula_validar_periodo_vigente, que corta por FECHA_FIN (que
    --   el periodo no haya TERMINADO). Medido hoy en el servidor de test:
    --   11 de los 22 periodos del año en curso tienen el plazo vencido pero
    --   el periodo todavia corriendo, y con ellos 1.612 matriculas que la
    --   regla de edicion si permite tocar y esta funcion bloqueaba.
    --
    --   No es un efecto de V352 sino de tener la validacion en el sitio
    --   equivocado: antes de V352 el bloqueo caia sobre el lado contrario
    --   de la raya -- se podia editar lo vencido y no lo vigente --, que
    --   era igual de arbitrario y simplemente se notaba menos.
    --
    --   El gate se mueve al alta, que es quien lo necesita: ver
    --   fn_matricula_validar_plazo_matricula mas abajo, invocada desde
    --   fn_matricula_directa_crear (su unico llamador en el esquema).
    -- -----------------------------------------------------------------
    RETURN v_pk_periodo;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3. fn_matricula_directa_crear: hereda el gate, que es de quien era.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_matricula_directa_crear(p_pk_usuario_solicitante bigint, p_fk_sede bigint, p_fk_tlv_jornada bigint, p_fk_tgrupo bigint, p_fk_enfasis bigint DEFAULT NULL::bigint, p_pk_usuario_estudiante bigint DEFAULT NULL::bigint, p_fk_tresguardo bigint DEFAULT NULL::bigint, p_fk_tdiscapacidad bigint DEFAULT NULL::bigint, p_fk_tlv_talento bigint DEFAULT NULL::bigint, p_fk_tmunicipio_documento_est bigint DEFAULT NULL::bigint, p_fk_tmunicipio_nacimiento_est bigint DEFAULT NULL::bigint, p_fk_tmunicipio_residencia_est bigint DEFAULT NULL::bigint, p_direccion_residencia_est character varying DEFAULT NULL::character varying, p_fk_tlv_estrato bigint DEFAULT NULL::bigint, p_fk_tlv_sisben bigint DEFAULT NULL::bigint, p_fk_tlv_situacion_academica bigint DEFAULT NULL::bigint, p_estudiante_nuevo character varying DEFAULT 'S'::character varying, p_pk_usuario_padre bigint DEFAULT NULL::bigint, p_fk_tlv_parentesco bigint DEFAULT NULL::bigint, p_fk_tmunicipio_documento_padre bigint DEFAULT NULL::bigint, p_fk_tmunicipio_residencia_padre bigint DEFAULT NULL::bigint, p_direccion_residencia_padre character varying DEFAULT NULL::character varying, p_fk_tlv_zona bigint DEFAULT NULL::bigint, p_fk_tlv_nivel_educativo bigint DEFAULT NULL::bigint, p_fk_tlv_estado_civil bigint DEFAULT NULL::bigint, p_ocupacion character varying DEFAULT NULL::character varying, p_profesion character varying DEFAULT NULL::character varying, p_entidad character varying DEFAULT NULL::character varying, p_direccion_entidad character varying DEFAULT NULL::character varying, p_telefono_entidad character varying DEFAULT NULL::character varying, p_cargo_entidad character varying DEFAULT NULL::character varying, p_acudiente character varying DEFAULT 'S'::character varying, p_asiste_reuniones character varying DEFAULT NULL::character varying, p_asiste_informes character varying DEFAULT NULL::character varying, p_fk_tlv_tipo_empleo bigint DEFAULT NULL::bigint, p_fk_tlv_frecuencia_domicilio bigint DEFAULT NULL::bigint, p_proviene_sector_privado character varying DEFAULT NULL::character varying, p_proviene_otro_municipio character varying DEFAULT NULL::character varying, p_proviene_otro_municipio_cual character varying DEFAULT NULL::character varying, p_institucion_origen character varying DEFAULT NULL::character varying, p_fk_tlv_tipo_institucion_origen bigint DEFAULT NULL::bigint, p_fk_tlv_condicion_promocion bigint DEFAULT NULL::bigint, p_fk_tlv_victima_conflicto bigint DEFAULT NULL::bigint, p_fk_tmunicipio_victima bigint DEFAULT NULL::bigint, p_seguridad_social_ars character varying DEFAULT NULL::character varying, p_seguridad_social_eps character varying DEFAULT NULL::character varying, p_estudiante_subsidiado character varying DEFAULT NULL::character varying, p_fk_tlv_fuente_recurso bigint DEFAULT NULL::bigint, p_beneficiario_cabeza_familia character varying DEFAULT NULL::character varying, p_ben_hijo_cabeza_familia character varying DEFAULT NULL::character varying, p_beneficiario_veterano character varying DEFAULT NULL::character varying, p_beneficiario_heroe character varying DEFAULT NULL::character varying, p_fk_tarchivo_documento_identidad bigint DEFAULT NULL::bigint, p_fk_tarchivo_certificado_estudios bigint DEFAULT NULL::bigint, p_fk_tarchivo_certificado_medico bigint DEFAULT NULL::bigint, p_fk_tarchivo_foto bigint DEFAULT NULL::bigint, p_fk_tarchivo_otros jsonb DEFAULT NULL::jsonb)
 RETURNS TABLE(pk_testudiante bigint, pk_tpadre bigint, pk_tnucleo_familiar bigint, pk_tmatricula bigint, pk_tmatricula_socioeconomico bigint, archivos_creados jsonb)
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
        RAISE EXCEPTION 'No se encontro una sede activa con el identificador %',
            p_fk_sede
            USING ERRCODE = '22023', HINT = 'p_fk_sede debe apuntar a una TSEDE activa';
    END IF;

    PERFORM academico_test.fn_matricula_gate_escritura(
        p_pk_usuario_solicitante, p_fk_tgrupo, 'CREAR');

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
        RAISE EXCEPTION 'No se encontro un grupo activo con el identificador %',
            p_fk_tgrupo
            USING ERRCODE = '23503',
                  HINT    = 'p_fk_tgrupo debe apuntar a un TGRUPO activo con TGRADO activo';
    END IF;

    -- -----------------------------------------------------------------
    -- 3. Ese periodo debe ser un periodo vigente de (sede, jornada, año
    --    actual) y visible para el solicitante. Las dos cosas las hace el
    --    resolver; se le pasa el grupo para que no tenga que desambiguar.
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
    -- 3b. V415 -- El plazo para matricular no puede haber vencido.
    --
    --     La validacion vivia dentro del resolver, que es una consulta de
    --     lectura compartida por el alta, la edicion y el modificar; ahi
    --     bloqueaba tambien a las dos que no matriculan nada. Baja aca,
    --     que es el unico sitio donde la pregunta "¿todavia se puede
    --     matricular?" tiene sentido.
    -- -----------------------------------------------------------------
    PERFORM academico_test.fn_matricula_validar_plazo_matricula(v_pk_periodo);

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
    -- 9.b REV -- Dejar apuntada en la matricula CUAL de los acudientes del
    --      estudiante es el de ESTA matricula.
    --
    --      TMATRICULA.FK_TPADRE es el vinculo matricula <-> acudiente: un
    --      estudiante puede tener varios acudientes en TNUCLEO_FAMILIAR
    --      --que es la relacion familiar, con sus datos-- y la matricula
    --      señala a uno. Medido en los datos heredados: de las 32.070
    --      matriculas activas que lo tienen relleno, 31.293 coinciden con
    --      una fila ACTIVA de TNUCLEO_FAMILIAR del mismo par, y en los
    --      estudiantes con 2 o 3 vinculos apunta a uno de ellos.
    --
    --      El alta no lo llenaba, asi que toda matricula creada por la app
    --      quedaba con el puntero vacio y la lectura tenia que adivinar
    --      (ver V270). Se rellena aqui y no en fn_matricula_crear porque
    --      esa funcion es de otro modulo y no recibe el acudiente.
    --
    --      FK_TLV_ACUDIENTE_PARENTESCO acompaña al puntero: es el
    --      parentesco del acudiente DE LA MATRICULA, el mismo que se
    --      guardo en el nucleo familiar.
    -- -----------------------------------------------------------------
    IF v_pk_tpadre IS NOT NULL THEN
        -- El alias "mm" no es cosmetico: esta funcion es
        -- RETURNS TABLE(... pk_tmatricula ...), asi que dentro del cuerpo
        -- pk_tmatricula es una VARIABLE de salida y una referencia sin
        -- calificar a la columna homonima falla en ejecucion con 42702
        -- ("column reference is ambiguous"). Compila igual: el error solo
        -- aparece al ejecutar la sentencia.
        UPDATE academico_test.TMATRICULA mm
           SET FK_TPADRE                   = v_pk_tpadre,
               FK_TLV_ACUDIENTE_PARENTESCO = COALESCE(p_fk_tlv_parentesco,
                                                      mm.FK_TLV_ACUDIENTE_PARENTESCO),
               MODIFIED_BY                 = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT                 = CURRENT_TIMESTAMP
         WHERE mm.PK_TMATRICULA = v_pk_matricula;
    END IF;

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
