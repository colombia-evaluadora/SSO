-- =============================================================================
-- V274 -- Importacion de actividades del planeador desde el JSON de
-- intercambio, el mismo formato que produce fn_actividad_exportar (V272).
--
-- Tres funciones:
--   fn_planeador_etiqueta_a_lv  -- resuelve una etiqueta legible a su
--                                  PK_LISTA_VALOR, tolerando acentos,
--                                  mayusculas y separadores
--   fn_planeador_sn             -- "Si"/"No" (y S/N, true/false, 1/0) al
--                                  dominio bool_sn
--   fn_actividad_importar       -- valida o aplica un lote de actividades
--
-- -----------------------------------------------------------------------------
-- Dos fases: validar y aplicar
-- -----------------------------------------------------------------------------
-- p_solo_validar = TRUE (por defecto) no escribe NADA: devuelve el informe fila
-- por fila con lo que casa y lo que no. Asi el front puede mostrar "12
-- actividades, 3 con problemas" antes de tocar la base.
--
-- Con p_solo_validar = FALSE se aplica, pero es TODO O NADA: si alguna fila
-- tiene errores no se escribe ninguna. Media importacion es peor que ninguna --
-- deja al usuario sin saber que quedo dentro.
--
-- -----------------------------------------------------------------------------
-- Como se identifica el destino, que es el problema real del importador
-- -----------------------------------------------------------------------------
-- Los nombres NO identifican nada: hay 3.591 asignaturas activas con solo 304
-- nombres distintos, unas 12 filas por nombre, porque la asignatura se acota por
-- area curricular. "Diseño" no es una asignatura, son doce. Igual el grado, que
-- cuelga del periodo academico.
--
-- Asi que el destino sale, por orden de precedencia:
--   1. del bloque _identificadores de cada actividad, si viene -- es lo que
--      pone fn_actividad_exportar, de modo que un archivo nuestro se reimporta
--      sin adivinar nada;
--   2. de los parametros p_fk_tasignatura / p_fk_tgrupo / p_fk_tgrado, que el
--      front tiene en contexto porque el importador se abre desde la pantalla
--      de una asignatura.
-- Si no hay ninguno de los dos, la fila se reporta con error. NUNCA se resuelve
-- por nombre: acertar la asignatura equivocada es peor que fallar.
--
-- -----------------------------------------------------------------------------
-- Etiquetas que no existen en el catalogo
-- -----------------------------------------------------------------------------
-- Se rechaza la fila diciendo cual es la etiqueta y en que categoria se busco.
-- No hay valores por defecto ni equivalencias inventadas: el catalogo es la
-- verdad. El JSON de ejemplo que llego de negocio, por ejemplo, trae seis tipos
-- de actividad que no existen (Proyecto, Practica, Ensayo, Actividad,
-- Investigacion, Entrega) -- de los siete solo casa "Exposicion".
--
-- -----------------------------------------------------------------------------
-- Reglas del dominio que el importador NO puede saltarse
-- -----------------------------------------------------------------------------
-- Son de fn_actividad_crear y de los *_definir, y conviene conocerlas porque el
-- JSON de negocio las incumple:
--
--   * Una actividad solo admite instrumento de evaluacion si el referente
--     curricular de SU UNIDAD tiene enfoque pedagogico EVALUATIVO.
--   * Una escala NUMERICA no lleva niveles: se define con valorMin/valorMax e
--     interpretacionRangos. Los niveles son de la CUALITATIVA.
--   * El instrumento "Otro" no necesita ningun catalogo nuevo: su
--     metodoValoracion reutiliza INSTRUMENTO_EVALUACION restringido a RUBRICA,
--     LISTA_COTEJO o ESCALA_VALORACION (nunca OTRO), y su tipoEvidencia sale de
--     TIPO_EVIDENCIA_OTRO.
--
-- Estas no se replican aca: se dejan levantar desde las funciones que ya las
-- validan, y su mensaje se recoge en el informe de la fila. Duplicar la regla
-- seria garantizar que las dos copias divergan.
--
-- Idempotente: CREATE OR REPLACE.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- fn_planeador_etiqueta_a_lv
-- -----------------------------------------------------------------------------
-- Resuelve "Rúbrica", "RUBRICA", "rubrica" o "Lista de cotejo" al
-- PK_LISTA_VALOR de su categoria. Compara contra NOMBRE y contra VALOR, y
-- normaliza antes: quita acentos, pasa a mayusculas, colapsa blancos y admite
-- guion bajo por espacio.
--
-- El BTRIM con CHR(9)/CHR(13)/CHR(10) no es paranoia: varios NOMBRE del
-- catalogo TIPO_ACTIVIDAD traen un salto de linea al final -- 'Tarea' + LF
-- literal en la base -- y TRIM en Postgres quita solo espacios.
--
-- Devuelve NULL si no hay equivalente; quien llama decide si eso es un error.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_planeador_etiqueta_a_lv(
    p_categoria VARCHAR,
    p_etiqueta  TEXT
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $function$
    WITH norm AS (
        SELECT UPPER(REGEXP_REPLACE(
                   TRANSLATE(BTRIM(COALESCE(p_etiqueta, ''),
                                   CHR(32) || CHR(9) || CHR(13) || CHR(10)),
                             'ÁÉÍÓÚÑÜáéíóúñü', 'AEIOUNUaeiounu'),
                   '[[:space:]_]+', ' ', 'g')) AS v
    )
    SELECT lv.PK_LISTA_VALOR
      FROM academico_test.TLISTA_VALOR lv, norm
     WHERE lv.CATEGORIA = p_categoria
       AND lv.ACTIVE    = TRUE
       AND norm.v <> ''
       AND (
            UPPER(REGEXP_REPLACE(
                TRANSLATE(BTRIM(COALESCE(lv.NOMBRE, ''),
                                CHR(32) || CHR(9) || CHR(13) || CHR(10)),
                          'ÁÉÍÓÚÑÜáéíóúñü', 'AEIOUNUaeiounu'),
                '[[:space:]_]+', ' ', 'g')) = norm.v
            OR
            UPPER(REGEXP_REPLACE(COALESCE(lv.VALOR, ''), '[[:space:]_]+', ' ', 'g')) = norm.v
       )
     ORDER BY lv.PK_LISTA_VALOR
     LIMIT 1;
$function$;

COMMENT ON FUNCTION academico_test.fn_planeador_etiqueta_a_lv(VARCHAR, TEXT)
    IS 'Resuelve una etiqueta legible ("Rubrica", "Lista de cotejo") al PK_LISTA_VALOR de su categoria, comparando contra NOMBRE y VALOR sin acentos, sin distinguir mayusculas y tratando guion bajo como espacio. NULL si no hay equivalente. Usa BTRIM con CHR(9)/CHR(13)/CHR(10) porque varios NOMBRE del catalogo traen salto de linea al final y TRIM solo quita espacios. V274.';


-- -----------------------------------------------------------------------------
-- fn_planeador_sn
-- -----------------------------------------------------------------------------
-- El formato de negocio escribe los booleanos como "Si" / "No"; las columnas
-- son del dominio bool_sn ('S' / 'N'). Se aceptan tambien 'S'/'N', true/false y
-- 1/0 porque un archivo de un tercero puede traer cualquiera de las tres, y
-- ninguna es ambigua. Lo que no se reconoce cae al valor por defecto que pide
-- quien llama, que es el mismo que usa fn_actividad_crear.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_planeador_sn(
    p_valor       TEXT,
    p_por_defecto academico_test.bool_sn DEFAULT 'N'
)
RETURNS academico_test.bool_sn
LANGUAGE sql
IMMUTABLE
AS $function$
    SELECT CASE
               WHEN UPPER(TRANSLATE(BTRIM(COALESCE(p_valor, '')), 'ÍíÓó', 'IiOo'))
                    IN ('SI', 'S', 'TRUE', 'T', '1')            THEN 'S'
               WHEN UPPER(BTRIM(COALESCE(p_valor, '')))
                    IN ('NO', 'N', 'FALSE', 'F', '0')           THEN 'N'
               ELSE p_por_defecto
           END::academico_test.bool_sn;
$function$;

COMMENT ON FUNCTION academico_test.fn_planeador_sn(TEXT, academico_test.bool_sn)
    IS 'Traduce los booleanos del formato de intercambio ("Si"/"No", tambien S/N, true/false y 1/0) al dominio bool_sn. Lo no reconocido cae al valor por defecto que indique quien llama. V274.';


-- -----------------------------------------------------------------------------
-- fn_actividad_importar
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_importar(
    p_pk_usuario_solicitante    BIGINT,
    p_actividades               JSONB,
    p_fk_tasignatura            BIGINT  DEFAULT NULL,
    p_fk_tgrupo                 BIGINT  DEFAULT NULL,
    p_fk_tgrado                 BIGINT  DEFAULT NULL,
    p_fk_tfuncionario           BIGINT  DEFAULT NULL,
    p_fk_tlv_calculo_definitiva BIGINT  DEFAULT NULL,
    p_fk_referente_curricular   BIGINT  DEFAULT NULL,
    p_solo_validar              BOOLEAN DEFAULT TRUE
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_act        JSONB;
    v_idx        INTEGER := -1;
    v_err        TEXT[];
    v_filas      JSONB := '[]'::JSONB;
    v_ok         INTEGER := 0;
    v_malas      INTEGER := 0;
    v_aplicadas  INTEGER := 0;
    v_unidades   JSONB := '[]'::JSONB;

    -- resueltos por fila
    v_ident      JSONB;
    v_asig       BIGINT;
    v_grupo      BIGINT;
    v_grado      BIGINT;
    v_unidad     BIGINT;
    v_tipo       BIGINT;
    v_jerarquia  BIGINT;
    v_modalidad  BIGINT;
    v_instr      BIGINT;
    v_instr_val  VARCHAR;
    v_evid       BIGINT;
    v_dur        NUMERIC;
    v_nom_unidad TEXT;
    v_materiales JSONB;
    v_adapt      JSONB;
    v_pk_act     BIGINT;
    v_resuelto   JSONB;
    v_r          JSONB;
    v_tmp        BIGINT;
    v_pond       NUMERIC;
    v_es_eval    academico_test.bool_sn;
    v_matriculas BIGINT[];
BEGIN
    IF p_actividades IS NULL OR jsonb_typeof(p_actividades) <> 'array' THEN
        RAISE EXCEPTION 'p_actividades debe ser un array JSON de actividades'
            USING ERRCODE = '22023',
                  HINT    = 'Es el mismo formato que produce fn_actividad_exportar';
    END IF;

    IF jsonb_array_length(p_actividades) = 0 THEN
        RETURN jsonb_build_object(
            'modo',     CASE WHEN p_solo_validar THEN 'validacion' ELSE 'aplicacion' END,
            'total',    0, 'validas', 0, 'conError', 0, 'aplicadas', 0,
            'filas',    '[]'::JSONB,
            'mensaje',  'No se recibio ninguna actividad');
    END IF;

    -- =================================================================
    -- FASE 1 -- Resolver y validar cada fila. No escribe nada.
    -- =================================================================
    FOR v_act IN SELECT e FROM jsonb_array_elements(p_actividades) AS e
    LOOP
        v_idx := v_idx + 1;
        v_err := ARRAY[]::TEXT[];
        v_ident := COALESCE(v_act->'_identificadores', '{}'::JSONB);

        -- ---- titulo ----
        IF NULLIF(BTRIM(COALESCE(v_act->>'nombre', '')), '') IS NULL THEN
            v_err := v_err || ('nombre: es obligatorio')::TEXT;
        END IF;

        -- ---- destino: _identificadores manda; si no, los parametros ----
        v_asig  := COALESCE(NULLIF(v_ident->>'fkTasignatura', '')::BIGINT, p_fk_tasignatura);
        v_grupo := COALESCE(NULLIF(v_ident->>'fkTgrupo', '')::BIGINT,      p_fk_tgrupo);
        v_grado := COALESCE(NULLIF(v_ident->>'fkTgrado', '')::BIGINT,      p_fk_tgrado);

        IF v_asig IS NULL THEN
            v_err := v_err || ('asignatura: no se pudo determinar. El archivo no trae '
                           || '_identificadores.fkTasignatura y no se recibio p_fk_tasignatura. '
                           || 'No se resuelve por nombre: hay 304 nombres para 3.591 asignaturas')::TEXT;
        ELSIF NOT EXISTS (SELECT 1 FROM academico_test.TASIGNATURA
                           WHERE PK_TASIGNATURA = v_asig AND ACTIVE) THEN
            v_err := v_err || (('asignatura: no existe o esta inactiva (' || v_asig || ')'))::TEXT;
        END IF;

        IF v_grupo IS NOT NULL AND NOT EXISTS (SELECT 1 FROM academico_test.TGRUPO
                                                WHERE PK_TGRUPO = v_grupo AND ACTIVE) THEN
            v_err := v_err || (('grupo: no existe o esta inactivo (' || v_grupo || ')'))::TEXT;
        END IF;

        -- ---- catalogos ----
        v_tipo := academico_test.fn_planeador_etiqueta_a_lv('TIPO_ACTIVIDAD', v_act->>'tipo');
        IF v_tipo IS NULL THEN
            v_err := v_err || (('tipo: "' || COALESCE(v_act->>'tipo', '(vacio)')
                            || '" no existe en el catalogo TIPO_ACTIVIDAD'))::TEXT;
        END IF;

        -- La jerarquia no viene en el formato de negocio: una actividad
        -- importada es siempre una Actividad, nunca un Criterio de otra.
        v_jerarquia := academico_test.fn_planeador_etiqueta_a_lv('TIPO_JERARQUIA_ACTIVIDAD', 'Actividad');
        IF v_jerarquia IS NULL THEN
            v_err := v_err || ('jerarquia: el catalogo TIPO_JERARQUIA_ACTIVIDAD no tiene "Actividad"')::TEXT;
        END IF;

        v_modalidad := NULL;
        IF NULLIF(BTRIM(COALESCE(v_act->>'modalidad', '')), '') IS NOT NULL THEN
            v_modalidad := academico_test.fn_planeador_etiqueta_a_lv('MODALIDAD', v_act->>'modalidad');
            IF v_modalidad IS NULL THEN
                v_err := v_err || (('modalidad: "' || (v_act->>'modalidad')
                                || '" no existe en el catalogo MODALIDAD'))::TEXT;
            END IF;
        END IF;

        v_instr := NULL; v_instr_val := NULL;
        IF NULLIF(BTRIM(COALESCE(v_act->>'instrumento', '')), '') IS NOT NULL THEN
            v_instr := academico_test.fn_planeador_etiqueta_a_lv('INSTRUMENTO_EVALUACION', v_act->>'instrumento');
            IF v_instr IS NULL THEN
                -- Caso real del JSON de negocio: "Observacion", que es un
                -- TIPO_EVIDENCIA y no un instrumento. Se dice explicitamente
                -- para que quien corrija el archivo sepa donde mirar.
                v_err := v_err || (('instrumento: "' || (v_act->>'instrumento')
                                || '" no existe en el catalogo INSTRUMENTO_EVALUACION '
                                || '(solo Rubrica, Lista de cotejo, Escala de valoracion y Otro)'))::TEXT;
            ELSE
                SELECT VALOR INTO v_instr_val FROM academico_test.TLISTA_VALOR
                 WHERE PK_LISTA_VALOR = v_instr;
            END IF;
        END IF;

        v_evid := NULL;
        IF NULLIF(BTRIM(COALESCE(v_act->>'tipo_evidencia', '')), '') IS NOT NULL THEN
            v_evid := academico_test.fn_planeador_etiqueta_a_lv('TIPO_EVIDENCIA', v_act->>'tipo_evidencia');
            IF v_evid IS NULL THEN
                v_err := v_err || (('tipo_evidencia: "' || (v_act->>'tipo_evidencia')
                                || '" no existe en el catalogo TIPO_EVIDENCIA'))::TEXT;
            END IF;
        END IF;

        -- ---- duracion: el formato de negocio trae texto libre ("20 horas",
        --      "3 sesiones", "N/A") y la columna es NUMERIC. Se toma el primer
        --      numero que aparezca; sin numero, NULL. La unidad se pierde
        --      porque no hay donde guardarla.
        v_dur := NULL;
        IF v_act ? 'duracion' AND jsonb_typeof(v_act->'duracion') = 'number' THEN
            v_dur := (v_act->>'duracion')::NUMERIC;
        ELSIF NULLIF(BTRIM(COALESCE(v_act->>'duracion', '')), '') IS NOT NULL THEN
            v_dur := NULLIF(REGEXP_REPLACE(v_act->>'duracion', '^[^0-9]*([0-9]+([.,][0-9]+)?).*$', '\1'),
                            v_act->>'duracion')::NUMERIC;
        END IF;

        -- ---- unidad: se busca por (nombre, asignatura, grado) ----
        v_unidad := NULLIF(v_ident->>'pkTunidad', '')::BIGINT;
        v_nom_unidad := NULLIF(BTRIM(COALESCE(v_act->>'unidad',
                                              v_act->'unidad_meta'->>'nombre', '')), '');

        IF v_unidad IS NOT NULL THEN
            IF NOT EXISTS (SELECT 1 FROM academico_test.TUNIDAD
                            WHERE PK_TUNIDAD = v_unidad AND ACTIVE) THEN
                v_err := v_err || (('unidad: _identificadores.pkTunidad no existe o esta inactiva ('
                                || v_unidad || ')'))::TEXT;
                v_unidad := NULL;
            END IF;
        ELSIF v_nom_unidad IS NOT NULL AND v_asig IS NOT NULL AND v_grado IS NOT NULL THEN
            SELECT u.PK_TUNIDAD INTO v_unidad
              FROM academico_test.TUNIDAD u
             WHERE u.ACTIVE
               AND u.FK_TASIGNATURA = v_asig
               AND u.FK_TGRADO      = v_grado
               AND UPPER(BTRIM(u.NOMBRE)) = UPPER(v_nom_unidad)
             ORDER BY u.PK_TUNIDAD
             LIMIT 1;

            -- Si no existe habra que crearla, y para eso fn_unidad_crear exige
            -- dueño y forma de calculo de la nota. Si no llegan, se dice aqui
            -- en vez de reventar a mitad de la aplicacion.
            IF v_unidad IS NULL THEN
                IF p_fk_tfuncionario IS NULL THEN
                    v_err := v_err || (('unidad: hay que crear "' || v_nom_unidad
                                    || '" y falta p_fk_tfuncionario (el docente dueño)'))::TEXT;
                END IF;
                IF p_fk_tlv_calculo_definitiva IS NULL THEN
                    v_err := v_err || (('unidad: hay que crear "' || v_nom_unidad
                                    || '" y falta p_fk_tlv_calculo_definitiva'))::TEXT;
                END IF;
                -- Aviso, no error: sin referente EVALUATIVO la unidad nueva no
                -- admitira instrumento, y fn_actividad_crear lo rechazara.
                IF v_instr IS NOT NULL AND p_fk_referente_curricular IS NULL THEN
                    v_err := v_err || (('unidad: la actividad trae instrumento y hay que crear la '
                                    || 'unidad sin referente curricular; un instrumento exige que el '
                                    || 'referente de la unidad tenga enfoque EVALUATIVO. '
                                    || 'Envie p_fk_referente_curricular'))::TEXT;
                END IF;
            END IF;
        ELSIF v_nom_unidad IS NOT NULL THEN
            v_err := v_err || ('unidad: para resolverla por nombre hacen falta asignatura y grado')::TEXT;
        END IF;

        -- ---- recursos -> materiales de fn_actividad_crear ----
        v_materiales := NULL;
        IF jsonb_typeof(COALESCE(v_act->'recursos', 'null'::JSONB)) = 'array'
           AND jsonb_array_length(v_act->'recursos') > 0 THEN
            SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                       'tipoRecurso', academico_test.fn_planeador_etiqueta_a_lv(
                                          'TIPO_RECURSO',
                                          CASE LOWER(BTRIM(COALESCE(r->>'origen', '')))
                                              WHEN 'url'      THEN 'URL'
                                              WHEN 'archivo'  THEN 'ARCHIVO'
                                              WHEN 'unidad'   THEN 'REPOSITORIO'
                                              ELSE r->>'origen'
                                          END),
                       'url',         r->>'url',
                       'fkTarchivo',  NULLIF(COALESCE(r->>'fkTarchivo', r->>'archivo'), '')::BIGINT,
                       'descripcion', r->>'descripcion')))
              INTO v_materiales
              FROM jsonb_array_elements(v_act->'recursos') r;

            -- El origen es obligatorio del lado de la base
            -- (TACTIVIDAD_MATERIAL.FK_TLV_TIPO_RECURSO es NOT NULL).
            IF EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(v_materiales, '[]'::JSONB)) m
                        WHERE (m->>'tipoRecurso') IS NULL) THEN
                v_err := v_err || ('recursos: hay recursos cuyo "origen" no casa con el catalogo '
                               || 'TIPO_RECURSO (se esperan url, archivo o unidad)')::TEXT;
            END IF;

            -- fn_actividad_material_reemplazar exige EXACTAMENTE uno de los dos
            -- destinos: url o fkTarchivo. Se valida aca y no se deja para el
            -- aplicar, que es justo lo que la fase de validacion existe para
            -- evitar.
            --
            -- Ojo con origen "unidad" (REPOSITORIO): el formato de negocio le
            -- pone un campo "unidad" con el NOMBRE de la carpeta, y eso no
            -- tiene donde guardarse -- TACTIVIDAD_MATERIAL solo sabe de URL y
            -- de PK_TARCHIVO. Un recurso de repositorio tiene que llegar con
            -- su url o con su fkTarchivo; el nombre de la carpeta, si importa,
            -- va en la descripcion.
            IF EXISTS (
                SELECT 1 FROM jsonb_array_elements(COALESCE(v_materiales, '[]'::JSONB)) m
                 WHERE (NULLIF(BTRIM(COALESCE(m->>'url', '')), '') IS NULL)
                       = (NULLIF(m->>'fkTarchivo', '') IS NULL)
            ) THEN
                v_err := v_err || ('recursos: cada recurso tiene que traer exactamente uno de '
                               || '"url" o "fkTarchivo". Un recurso de origen "unidad" tambien: '
                               || 'el nombre de la carpeta no es un destino que la base pueda '
                               || 'guardar')::TEXT;
            END IF;
        END IF;

        -- ---- adaptaciones ----
        v_adapt := NULL;
        IF jsonb_typeof(COALESCE(v_act->'adaptaciones', 'null'::JSONB)) = 'array'
           AND jsonb_array_length(v_act->'adaptaciones') > 0 THEN
            SELECT jsonb_agg(
                       jsonb_strip_nulls(jsonb_build_object(
                           'tipoAdaptacion',       academico_test.fn_planeador_etiqueta_a_lv(
                                                       'TIPO_ADAPTACION', a->>'tipo'),
                           'descripcion',          a->>'descripcion',
                           -- "si_url" / "si_file" se parten en tres: la bandera, el formato y el
                           -- destino. Con usaVersionModificada = 'N' el formato NO puede ir --
                           -- fn_actividad_adaptacion_reemplazar lo rechaza expresamente.
                           'usaVersionModificada', CASE WHEN LOWER(BTRIM(COALESCE(a->>'instrumento_modificado', '')))
                                                             LIKE 'si%' THEN 'S' ELSE 'N' END,
                           'formatoAdaptacion',    CASE LOWER(BTRIM(COALESCE(a->>'instrumento_modificado', '')))
                                                       WHEN 'si_url'  THEN academico_test.fn_planeador_etiqueta_a_lv(
                                                                               'FORMATO_ADAPTACION', 'ENLACE')
                                                       WHEN 'si_file' THEN academico_test.fn_planeador_etiqueta_a_lv(
                                                                               'FORMATO_ADAPTACION', 'ARCHIVO')
                                                   END,
                           -- ENLACE va por url; ARCHIVO y BIBLIOTECA exigen fkTarchivo, que tiene
                           -- que ser una PK de TARCHIVO: el nombre de fichero que trae el ejemplo
                           -- ("plantilla.docx") no sirve, y se reporta en la validacion.
                           'url',                  CASE WHEN LOWER(BTRIM(COALESCE(a->>'instrumento_modificado', ''))) = 'si_url'
                                                        THEN a->>'adjunto' END,
                           'fkTarchivo',           CASE WHEN LOWER(BTRIM(COALESCE(a->>'instrumento_modificado', ''))) = 'si_file'
                                                             AND a->>'adjunto' ~ '^[0-9]+$'
                                                        THEN (a->>'adjunto')::BIGINT END,
                           'aplicaA',              academico_test.fn_planeador_etiqueta_a_lv('APLICA_A',
                                                       CASE LOWER(BTRIM(COALESCE(a->>'aplica', '')))
                                                           WHEN 'grupo'       THEN 'TODO_EL_GRUPO'
                                                           WHEN 'especificos' THEN 'ESTUDIANTES_SELECCIONADOS'
                                                           ELSE a->>'aplica'
                                                       END),
                           'estudiantes',          CASE WHEN LOWER(BTRIM(COALESCE(a->>'aplica', ''))) = 'especificos'
                                                        THEN a->'estudiantes' END)))
              INTO v_adapt
              FROM jsonb_array_elements(v_act->'adaptaciones') a;

            IF EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(v_adapt, '[]'::JSONB)) x
                        WHERE (x->>'tipoAdaptacion') IS NULL) THEN
                v_err := v_err || ('adaptaciones: hay adaptaciones cuyo "tipo" no casa con el '
                               || 'catalogo TIPO_ADAPTACION')::TEXT;
            END IF;

            IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_act->'adaptaciones') a
                        WHERE NULLIF(BTRIM(COALESCE(a->>'descripcion', '')), '') IS NULL
                           OR LENGTH(BTRIM(a->>'descripcion')) > 500) THEN
                v_err := v_err || ('adaptaciones: la "descripcion" es obligatoria y no puede '
                               || 'pasar de 500 caracteres')::TEXT;
            END IF;

            -- ARCHIVO exige una PK de TARCHIVO. El ejemplo de negocio pone el
            -- nombre del fichero, que no es un destino.
            IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_act->'adaptaciones') a
                        WHERE LOWER(BTRIM(COALESCE(a->>'instrumento_modificado', ''))) = 'si_file'
                          AND COALESCE(a->>'adjunto', '') !~ '^[0-9]+$') THEN
                v_err := v_err || ('adaptaciones: con instrumento_modificado = "si_file" el '
                               || '"adjunto" tiene que ser el identificador del archivo ya '
                               || 'subido, no su nombre')::TEXT;
            END IF;

            -- aplica = "especificos" exige la lista de MATRICULAS, y las
            -- matriculas tienen que quedar asignadas a la actividad antes de
            -- escribir la adaptacion. Eso ultimo se resuelve solo, porque
            -- fn_actividad_crear asigna estudiantes antes de las adaptaciones.
            --
            -- Lo que no se puede resolver son los NOMBRES: el formato de
            -- negocio escribe "estudiantes": ["Alumno 3"], y un nombre no
            -- identifica una matricula (hay homonimos, y el mismo alumno tiene
            -- una matricula por año). Un archivo salido de nuestro exportador
            -- si trae las PKs, y por eso ese si se reimporta.
            IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_act->'adaptaciones') a
                        WHERE LOWER(BTRIM(COALESCE(a->>'aplica', ''))) = 'especificos'
                          AND (jsonb_typeof(COALESCE(a->'estudiantes', 'null'::JSONB)) <> 'array'
                               OR jsonb_array_length(a->'estudiantes') = 0
                               OR EXISTS (SELECT 1 FROM jsonb_array_elements(a->'estudiantes') e
                                           WHERE jsonb_typeof(e) <> 'number'))) THEN
                v_err := v_err || ('adaptaciones: con "aplica": "especificos" la lista '
                               || '"estudiantes" tiene que traer identificadores de matricula '
                               || '(numeros), no nombres de alumno: un nombre no identifica una '
                               || 'matricula. Importe con "grupo" y elija los estudiantes despues, '
                               || 'desde la actividad')::TEXT;
            END IF;

            -- Las matriculas nombradas tienen que ser del grupo al que se
            -- importa; si no, la actividad quedaria con alumnos de otro curso.
            IF v_grupo IS NOT NULL AND EXISTS (
                SELECT 1
                  FROM jsonb_array_elements(v_act->'adaptaciones') a,
                       jsonb_array_elements(COALESCE(a->'estudiantes', '[]'::JSONB)) e
                 WHERE LOWER(BTRIM(COALESCE(a->>'aplica', ''))) = 'especificos'
                   AND jsonb_typeof(e) = 'number'
                   AND NOT EXISTS (SELECT 1 FROM academico_test.TMATRICULA m
                                    WHERE m.PK_TMATRICULA = (e#>>'{}')::BIGINT
                                      AND m.ACTIVE AND m.FK_TGRUPO = v_grupo)
            ) THEN
                v_err := v_err || ('adaptaciones: hay matriculas en "estudiantes" que no estan '
                               || 'activas en el grupo al que se importa')::TEXT;
            END IF;
        END IF;

        -- ---- ponderacion: solo tiene sentido si la actividad es evaluativa ----
        -- fn_actividad_crear rechaza de plano cualquier ponderacion cuando
        -- p_es_evaluativa = 'N'. El formato de negocio, en cambio, escribe
        -- "ponderacion": 0 en las actividades no evaluativas: eso no es un peso,
        -- es un hueco relleno, y se descarta. Un peso REAL (> 0) sobre una
        -- actividad no evaluativa si es una contradiccion y se reporta, porque
        -- descartarlo en silencio perderia una nota que el docente si puso.
        v_es_eval := academico_test.fn_planeador_sn(v_act->>'evaluativa', 'S');
        v_pond    := NULLIF(BTRIM(COALESCE(v_act->>'ponderacion', '')), '')::NUMERIC;
        IF v_es_eval = 'N' THEN
            IF COALESCE(v_pond, 0) <> 0 THEN
                v_err := v_err || (('ponderacion: la actividad no es evaluativa ("evaluativa": "No") '
                                || 'pero trae una ponderacion de ' || v_pond || '. Marquela como '
                                || 'evaluativa o quite la ponderacion'))::TEXT;
            END IF;
            v_pond := NULL;
        END IF;

        -- ---- coherencia del instrumento con su definicion ----
        IF v_instr_val = 'RUBRICA' THEN
            IF jsonb_typeof(COALESCE(v_act->'rubrica', 'null'::JSONB)) <> 'array' THEN
                v_err := v_err || ('rubrica: el instrumento es Rubrica pero no viene el array "rubrica"')::TEXT;
            ELSE
                -- La ponderacion de un nivel es la NOTA que ese nivel otorga, no
                -- un adorno: sin ella la rubrica no puede calificar. Y
                -- fn_actividad_rubrica_definir exige que sean DISTINTAS dentro
                -- del criterio, porque dos niveles con el mismo peso son el
                -- mismo nivel.
                --
                -- El formato de negocio no las trae. No se inventan: poner una
                -- escala descendente "razonable" seria fabricar pesos de
                -- calificacion. Se exige que el archivo las traiga; el
                -- exportador siempre las incluye, asi que un archivo nuestro
                -- pasa sin tocarlo.
                IF EXISTS (
                    SELECT 1
                      FROM jsonb_array_elements(v_act->'rubrica') cr,
                           jsonb_array_elements(COALESCE(cr->'niveles', '[]'::JSONB)) ni
                     WHERE jsonb_typeof(COALESCE(ni->'ponderacion', 'null'::JSONB)) <> 'number'
                ) THEN
                    v_err := v_err || ('rubrica: cada nivel necesita "ponderacion" numerica, que '
                                   || 'es la nota que otorga ese nivel. El formato de ejemplo no '
                                   || 'la trae y no se inventa')::TEXT;
                ELSIF EXISTS (
                    SELECT 1
                      FROM jsonb_array_elements(v_act->'rubrica') cr
                     WHERE (SELECT COUNT(*) FROM jsonb_array_elements(COALESCE(cr->'niveles', '[]'::JSONB)) x)
                           <> (SELECT COUNT(DISTINCT x->>'ponderacion')
                                 FROM jsonb_array_elements(COALESCE(cr->'niveles', '[]'::JSONB)) x)
                ) THEN
                    v_err := v_err || ('rubrica: hay criterios con dos niveles de la misma '
                                   || 'ponderacion; dentro de un criterio tienen que ser distintas')::TEXT;
                END IF;
            END IF;
        END IF;
        IF v_instr_val = 'LISTA_COTEJO' AND jsonb_typeof(COALESCE(v_act->'cotejo', 'null'::JSONB)) <> 'array'
           AND jsonb_typeof(COALESCE(v_act->'cotejo_detalle', 'null'::JSONB)) <> 'array' THEN
            v_err := v_err || ('cotejo: el instrumento es Lista de cotejo pero no viene "cotejo"')::TEXT;
        END IF;
        IF v_instr_val = 'ESCALA_VALORACION' THEN
            IF jsonb_typeof(COALESCE(v_act->'escala', 'null'::JSONB)) <> 'object' THEN
                v_err := v_err || ('escala: el instrumento es Escala de valoracion pero no viene "escala"')::TEXT;
            ELSE
                v_tmp := academico_test.fn_planeador_etiqueta_a_lv('TIPO_ESCALA', v_act->'escala'->>'tipo');
                IF v_tmp IS NOT NULL AND EXISTS (
                    -- Misma regla que la rubrica, para los niveles de la escala
                    -- CUALITATIVA. La NUMERICA no lleva niveles: se define con
                    -- min/max e interpretacion, y fn_actividad_escala_definir
                    -- rechaza que los traiga.
                    SELECT 1
                      FROM jsonb_array_elements(COALESCE(v_act->'escala'->'niveles', '[]'::JSONB)) ni
                     WHERE jsonb_typeof(COALESCE(ni->'ponderacion', 'null'::JSONB)) <> 'number'
                ) THEN
                    v_err := v_err || ('escala.niveles: cada nivel necesita "ponderacion" '
                                   || 'numerica, que es la nota que otorga')::TEXT;
                END IF;
                IF v_tmp IS NULL THEN
                    v_err := v_err || (('escala.tipo: "' || COALESCE(v_act->'escala'->>'tipo', '(vacio)')
                                    || '" no existe en el catalogo TIPO_ESCALA (Numerica o Cualitativa)'))::TEXT;
                END IF;
            END IF;
        END IF;
        IF v_instr_val = 'OTRO' AND jsonb_typeof(COALESCE(v_act->'otro', 'null'::JSONB)) <> 'object' THEN
            v_err := v_err || ('otro: el instrumento es Otro (personalizado) pero no viene "otro"')::TEXT;
        END IF;

        -- ---- informe de la fila ----
        v_resuelto := jsonb_strip_nulls(jsonb_build_object(
            'fkTasignatura', v_asig, 'fkTgrupo', v_grupo, 'fkTgrado', v_grado,
            'pkTunidad', v_unidad, 'unidadPorCrear',
                CASE WHEN v_unidad IS NULL AND v_nom_unidad IS NOT NULL THEN v_nom_unidad END,
            'fkTlvTipoActividad', v_tipo, 'fkTlvModalidad', v_modalidad,
            'instrumento', v_instr_val, 'fkTlvTipoEvidencia', v_evid,
            'duracionEstimada', v_dur, 'ponderacion', v_pond));

        IF array_length(v_err, 1) IS NULL THEN
            v_ok := v_ok + 1;
            v_r := jsonb_build_object('indice', v_idx, 'nombre', v_act->>'nombre',
                                      'estado', 'ok', 'resuelto', v_resuelto);
        ELSE
            v_malas := v_malas + 1;
            v_r := jsonb_build_object('indice', v_idx, 'nombre', v_act->>'nombre',
                                      'estado', 'error', 'errores', to_jsonb(v_err),
                                      'resuelto', v_resuelto);
        END IF;
        v_filas := v_filas || jsonb_build_array(v_r);
    END LOOP;

    -- =================================================================
    -- Solo validar, o hay errores: se devuelve el informe sin escribir.
    -- =================================================================
    IF p_solo_validar OR v_malas > 0 THEN
        RETURN jsonb_build_object(
            'modo',      CASE WHEN p_solo_validar THEN 'validacion' ELSE 'aplicacion' END,
            'total',     jsonb_array_length(p_actividades),
            'validas',   v_ok,
            'conError',  v_malas,
            'aplicadas', 0,
            'filas',     v_filas,
            'mensaje',   CASE
                             WHEN p_solo_validar AND v_malas = 0
                                 THEN 'Todas las actividades son importables'
                             WHEN p_solo_validar
                                 THEN v_malas || ' de ' || jsonb_array_length(p_actividades)
                                      || ' actividades tienen problemas'
                             ELSE 'No se importo nada: ' || v_malas || ' de '
                                  || jsonb_array_length(p_actividades)
                                  || ' actividades tienen problemas. La importacion es todo o nada'
                         END);
    END IF;

    -- =================================================================
    -- FASE 2 -- Aplicar. Todo o nada: cualquier excepcion de las
    -- funciones del modulo aborta la transaccion completa, que es lo que
    -- queremos. No se capturan: sus mensajes ya son especificos.
    -- =================================================================
    v_idx := -1;
    v_filas := '[]'::JSONB;

    FOR v_act IN SELECT e FROM jsonb_array_elements(p_actividades) AS e
    LOOP
        v_idx   := v_idx + 1;
        v_ident := COALESCE(v_act->'_identificadores', '{}'::JSONB);
        v_asig  := COALESCE(NULLIF(v_ident->>'fkTasignatura', '')::BIGINT, p_fk_tasignatura);
        v_grupo := COALESCE(NULLIF(v_ident->>'fkTgrupo', '')::BIGINT,      p_fk_tgrupo);
        v_grado := COALESCE(NULLIF(v_ident->>'fkTgrado', '')::BIGINT,      p_fk_tgrado);

        v_tipo      := academico_test.fn_planeador_etiqueta_a_lv('TIPO_ACTIVIDAD', v_act->>'tipo');
        v_jerarquia := academico_test.fn_planeador_etiqueta_a_lv('TIPO_JERARQUIA_ACTIVIDAD', 'Actividad');
        v_modalidad := academico_test.fn_planeador_etiqueta_a_lv('MODALIDAD', v_act->>'modalidad');
        v_instr     := academico_test.fn_planeador_etiqueta_a_lv('INSTRUMENTO_EVALUACION', v_act->>'instrumento');
        v_evid      := academico_test.fn_planeador_etiqueta_a_lv('TIPO_EVIDENCIA', v_act->>'tipo_evidencia');
        v_instr_val := NULL;
        IF v_instr IS NOT NULL THEN
            SELECT VALOR INTO v_instr_val FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = v_instr;
        END IF;

        v_dur := NULL;
        IF v_act ? 'duracion' AND jsonb_typeof(v_act->'duracion') = 'number' THEN
            v_dur := (v_act->>'duracion')::NUMERIC;
        ELSIF NULLIF(BTRIM(COALESCE(v_act->>'duracion', '')), '') IS NOT NULL THEN
            v_dur := NULLIF(REGEXP_REPLACE(v_act->>'duracion', '^[^0-9]*([0-9]+([.,][0-9]+)?).*$', '\1'),
                            v_act->>'duracion')::NUMERIC;
        END IF;

        -- ---- unidad: reusar o crear ----
        v_unidad := NULLIF(v_ident->>'pkTunidad', '')::BIGINT;
        v_nom_unidad := NULLIF(BTRIM(COALESCE(v_act->>'unidad',
                                              v_act->'unidad_meta'->>'nombre', '')), '');
        IF v_unidad IS NULL AND v_nom_unidad IS NOT NULL THEN
            SELECT u.PK_TUNIDAD INTO v_unidad
              FROM academico_test.TUNIDAD u
             WHERE u.ACTIVE AND u.FK_TASIGNATURA = v_asig AND u.FK_TGRADO = v_grado
               AND UPPER(BTRIM(u.NOMBRE)) = UPPER(v_nom_unidad)
             ORDER BY u.PK_TUNIDAD LIMIT 1;

            IF v_unidad IS NULL THEN
                v_unidad := academico_test.fn_unidad_crear(
                    p_pk_usuario_solicitante    := p_pk_usuario_solicitante,
                    p_nombre                    := v_nom_unidad,
                    p_fk_tasignatura            := v_asig,
                    p_fk_tgrado                 := v_grado,
                    p_fk_tfuncionario           := p_fk_tfuncionario,
                    p_fk_tlv_calculo_definitiva := p_fk_tlv_calculo_definitiva,
                    p_descripcion               := (
                        SELECT string_agg(d, ' ')
                          FROM jsonb_array_elements_text(
                                   COALESCE(v_act->'unidad_meta'->'descripcion', '[]'::JSONB)) d),
                    p_fk_referente_curricular   := p_fk_referente_curricular,
                    p_objetivos                 := (
                        SELECT ARRAY_AGG(o)::VARCHAR[]
                          FROM jsonb_array_elements_text(
                                   COALESCE(v_act->'unidad_meta'->'objetivos', '[]'::JSONB)) o),
                    p_contenidos                := (
                        SELECT ARRAY_AGG(cn)::VARCHAR[]
                          FROM jsonb_array_elements_text(
                                   COALESCE(v_act->'unidad_meta'->'contenidos', '[]'::JSONB)) cn));

                v_unidades := v_unidades || jsonb_build_array(jsonb_build_object(
                    'pkTunidad', v_unidad, 'nombre', v_nom_unidad));
            END IF;
        END IF;

        -- ---- recursos y adaptaciones (mismo mapeo que en la validacion) ----
        SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                   'tipoRecurso', academico_test.fn_planeador_etiqueta_a_lv('TIPO_RECURSO',
                                      CASE LOWER(BTRIM(COALESCE(r->>'origen', '')))
                                          WHEN 'url'     THEN 'URL'
                                          WHEN 'archivo' THEN 'ARCHIVO'
                                          WHEN 'unidad'  THEN 'REPOSITORIO'
                                          ELSE r->>'origen' END),
                   'url',         r->>'url',
                   'fkTarchivo',  NULLIF(COALESCE(r->>'fkTarchivo', r->>'archivo'), '')::BIGINT,
                   'descripcion', r->>'descripcion')))
          INTO v_materiales
          FROM jsonb_array_elements(COALESCE(v_act->'recursos', '[]'::JSONB)) r;

        SELECT jsonb_agg(
                   jsonb_strip_nulls(jsonb_build_object(
                       'tipoAdaptacion',       academico_test.fn_planeador_etiqueta_a_lv(
                                                   'TIPO_ADAPTACION', a->>'tipo'),
                       'descripcion',          a->>'descripcion',
                       -- "si_url" / "si_file" se parten en tres: la bandera, el formato y el
                       -- destino. Con usaVersionModificada = 'N' el formato NO puede ir --
                       -- fn_actividad_adaptacion_reemplazar lo rechaza expresamente.
                       'usaVersionModificada', CASE WHEN LOWER(BTRIM(COALESCE(a->>'instrumento_modificado', '')))
                                                         LIKE 'si%' THEN 'S' ELSE 'N' END,
                       'formatoAdaptacion',    CASE LOWER(BTRIM(COALESCE(a->>'instrumento_modificado', '')))
                                                   WHEN 'si_url'  THEN academico_test.fn_planeador_etiqueta_a_lv(
                                                                           'FORMATO_ADAPTACION', 'ENLACE')
                                                   WHEN 'si_file' THEN academico_test.fn_planeador_etiqueta_a_lv(
                                                                           'FORMATO_ADAPTACION', 'ARCHIVO')
                                               END,
                       -- ENLACE va por url; ARCHIVO y BIBLIOTECA exigen fkTarchivo, que tiene
                       -- que ser una PK de TARCHIVO: el nombre de fichero que trae el ejemplo
                       -- ("plantilla.docx") no sirve, y se reporta en la validacion.
                       'url',                  CASE WHEN LOWER(BTRIM(COALESCE(a->>'instrumento_modificado', ''))) = 'si_url'
                                                    THEN a->>'adjunto' END,
                       'fkTarchivo',           CASE WHEN LOWER(BTRIM(COALESCE(a->>'instrumento_modificado', ''))) = 'si_file'
                                                         AND a->>'adjunto' ~ '^[0-9]+$'
                                                    THEN (a->>'adjunto')::BIGINT END,
                       'aplicaA',              academico_test.fn_planeador_etiqueta_a_lv('APLICA_A',
                                                   CASE LOWER(BTRIM(COALESCE(a->>'aplica', '')))
                                                       WHEN 'grupo'       THEN 'TODO_EL_GRUPO'
                                                       WHEN 'especificos' THEN 'ESTUDIANTES_SELECCIONADOS'
                                                       ELSE a->>'aplica'
                                                   END),
                       'estudiantes',          CASE WHEN LOWER(BTRIM(COALESCE(a->>'aplica', ''))) = 'especificos'
                                                    THEN a->'estudiantes' END)))
          INTO v_adapt
          FROM jsonb_array_elements(COALESCE(v_act->'adaptaciones', '[]'::JSONB)) a;

        -- Una adaptacion "para estudiantes concretos" solo se puede escribir si
        -- esas matriculas ya estan asignadas a la actividad. Se recogen aqui y
        -- se pasan en la misma llamada: fn_actividad_crear asigna estudiantes
        -- ANTES de escribir las adaptaciones, asi que basta con eso.
        SELECT ARRAY_AGG(DISTINCT (e#>>'{}')::BIGINT)
          INTO v_matriculas
          FROM jsonb_array_elements(COALESCE(v_act->'adaptaciones', '[]'::JSONB)) a,
               jsonb_array_elements(COALESCE(a->'estudiantes', '[]'::JSONB)) e
         WHERE LOWER(BTRIM(COALESCE(a->>'aplica', ''))) = 'especificos';

        -- ---- la actividad ----
        -- Misma regla que en la validacion: sin evaluativa no va ponderacion.
        v_es_eval := academico_test.fn_planeador_sn(v_act->>'evaluativa', 'S');
        v_pond    := CASE WHEN v_es_eval = 'S'
                          THEN NULLIF(BTRIM(COALESCE(v_act->>'ponderacion', '')), '')::NUMERIC END;

        v_pk_act := academico_test.fn_actividad_crear(
            p_pk_usuario_solicitante          := p_pk_usuario_solicitante,
            p_titulo                          := v_act->>'nombre',
            p_fk_tasignatura                  := v_asig,
            p_fk_tlv_tipo_actividad           := v_tipo,
            p_fk_tlv_jerarquia                := v_jerarquia,
            p_descripcion                     := v_act->>'descripcion',
            p_fk_tgrupo                       := v_grupo,
            p_fk_tunidad                      := v_unidad,
            p_ponderacion                     := v_pond,
            p_fecha_inicio                    := NULLIF(v_act->>'fecha_inicio', '')::DATE,
            p_fecha_cierre                    := NULLIF(v_act->>'fecha_entrega', '')::DATE,
            p_duracion_estimada               := v_dur,
            p_semana_cronograma               := v_act->>'semana',
            p_fk_tlv_modalidad                := v_modalidad,
            p_material_requerido              := v_act->>'materiales',
            p_es_evaluativa                   := v_es_eval,
            p_fk_tlv_instrumento_evaluacion   := v_instr,
            p_fk_tlv_tipo_evidencia           := v_evid,
            p_genera_evidencias               := academico_test.fn_planeador_sn(v_act->>'genera_evidencias', 'N'),
            p_requiere_validacion_coordinador := academico_test.fn_planeador_sn(v_act->>'requiere_validacion', 'N'),
            p_observaciones_docente           := v_act->>'observaciones',
            p_materiales                      := v_materiales,
            p_adaptaciones                    := v_adapt,
            p_fk_tmatriculas                  := v_matriculas);

        -- ---- el instrumento, delegando en la funcion de cada uno ----
        IF v_instr_val = 'RUBRICA' THEN
            PERFORM academico_test.fn_actividad_rubrica_definir(
                p_pk_usuario_solicitante, v_pk_act, (
                    SELECT jsonb_agg(jsonb_build_object(
                               'nombre',  cr->>'nombre',
                               'niveles', (SELECT jsonb_agg(jsonb_build_object(
                                                      'etiqueta',    ni->>'nombre',
                                                      'descripcion', ni->>'descriptor',
                                                      'ponderacion', ni->'ponderacion'))
                                             FROM jsonb_array_elements(
                                                      COALESCE(cr->'niveles', '[]'::JSONB)) ni)))
                      FROM jsonb_array_elements(v_act->'rubrica') cr));

        ELSIF v_instr_val = 'LISTA_COTEJO' THEN
            -- Se prefiere cotejo_detalle si viene (trae ponderacion); si no,
            -- la lista de textos planos del formato de negocio.
            PERFORM academico_test.fn_actividad_cotejo_definir(
                p_pk_usuario_solicitante, v_pk_act,
                CASE WHEN jsonb_typeof(COALESCE(v_act->'cotejo_detalle', 'null'::JSONB)) = 'array'
                     THEN v_act->'cotejo_detalle'
                     ELSE (SELECT jsonb_agg(jsonb_build_object('descripcion', it))
                             FROM jsonb_array_elements_text(v_act->'cotejo') it)
                END);

        ELSIF v_instr_val = 'ESCALA_VALORACION' THEN
            PERFORM academico_test.fn_actividad_escala_definir(
                p_pk_usuario_solicitante, v_pk_act, jsonb_strip_nulls(jsonb_build_object(
                    'tipoEscala',           academico_test.fn_planeador_etiqueta_a_lv(
                                                'TIPO_ESCALA', v_act->'escala'->>'tipo'),
                    'valorMin',             v_act->'escala'->'min',
                    'valorMax',             v_act->'escala'->'max',
                    'interpretacionRangos', v_act->'escala'->>'interpretacion',
                    'criteriosGenerales',   COALESCE(v_act->'escala'->>'criterios',
                                                     v_act->'escala'->>'criterios_generales'),
                    'niveles',              (SELECT jsonb_agg(jsonb_build_object(
                                                        'etiqueta',    ni->>'nombre',
                                                        'descripcion', ni->>'descriptor',
                                                        'ponderacion', ni->'ponderacion'))
                                               FROM jsonb_array_elements(
                                                        COALESCE(v_act->'escala'->'niveles', '[]'::JSONB)) ni))));

        ELSIF v_instr_val = 'OTRO' THEN
            PERFORM academico_test.fn_actividad_otro_definir(
                p_pk_usuario_solicitante, v_pk_act, v_act->'otro');
        END IF;

        v_aplicadas := v_aplicadas + 1;
        v_filas := v_filas || jsonb_build_array(jsonb_build_object(
            'indice', v_idx, 'nombre', v_act->>'nombre', 'estado', 'importada',
            'pkTactividad', v_pk_act, 'pkTunidad', v_unidad));
    END LOOP;

    RETURN jsonb_build_object(
        'modo',            'aplicacion',
        'total',           jsonb_array_length(p_actividades),
        'validas',         v_ok,
        'conError',        0,
        'aplicadas',       v_aplicadas,
        'unidadesCreadas', v_unidades,
        'filas',           v_filas,
        'mensaje',         v_aplicadas || ' actividades importadas');
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_actividad_importar(BIGINT, JSONB, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BOOLEAN)
    IS 'Importa actividades del planeador desde el JSON de intercambio que produce fn_actividad_exportar. Dos fases: p_solo_validar = TRUE (por defecto) devuelve el informe fila por fila sin escribir nada; FALSE aplica, y es todo o nada -- si alguna fila tiene errores no se escribe ninguna. El destino sale del bloque _identificadores del archivo y, si no viene, de los parametros p_fk_tasignatura / p_fk_tgrupo / p_fk_tgrado: nunca se resuelve por nombre, porque hay 304 nombres para 3.591 asignaturas activas. Las etiquetas que no existan en catalogo se reportan con la categoria donde se busco, sin equivalencias inventadas. Orquesta fn_unidad_crear, fn_actividad_crear y los *_definir del instrumento en vez de escribir tablas. Tampoco se inventan notas: si un nivel de rubrica o de escala no trae ponderacion se rechaza la fila, y una ponderacion sobre una actividad no evaluativa tambien (el "ponderacion": 0 que pone el formato de negocio en esas si se descarta, porque no es una nota). Una adaptacion "para estudiantes concretos" solo se importa si trae PKs de matricula del grupo destino: un nombre de alumno no identifica una matricula. V274.';
