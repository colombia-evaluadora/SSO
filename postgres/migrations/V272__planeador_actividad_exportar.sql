-- =============================================================================
-- V272 -- fn_actividad_exportar: saca actividades del planeador al formato JSON
-- de intercambio, el mismo que leera el importador.
--
-- -----------------------------------------------------------------------------
-- Que hace y por que asi
-- -----------------------------------------------------------------------------
-- El modulo del planeador ya esta construido: unas 70 funciones y 43 endpoints.
-- Asi que esto NO lee tablas: llama a las lecturas que ya existen y reensambla.
-- En concreto:
--
--   fn_actividad_buscar_por_pk        -- 50 columnas, con TODAS las etiquetas ya
--                                        resueltas (tipo, modalidad, instrumento,
--                                        evidencia) y materiales / adaptaciones /
--                                        unidad_configuracion en JSONB
--   fn_actividad_instrumento_obtener  -- el instrumento y su definicion anidada,
--                                        sea rubrica, cotejo, escala u otro
--
-- Ganancia de hacerlo asi: no hay una segunda copia de las lecturas ni de sus
-- reglas, y el gate es exactamente el mismo que ve el usuario al abrir la
-- actividad en pantalla.
--
-- OJO con el alcance de ese gate, que es mas ancho de lo que parece:
-- fn_actividad_buscar_por_pk solo llama a fn_assert_permiso_seccion con
-- (PLANEADOR, VER) -- comprueba el permiso del MENU y NO acota por
-- establecimiento. Se verifico: un usuario del EE 745 con ese permiso exporta
-- sin problema una actividad del EE 877. Es el comportamiento de la funcion de
-- lectura del modulo, no algo que introduzca el exportador, y por eso no se
-- corrige aqui -- pero conviene saberlo antes de exponer el endpoint a roles
-- territoriales.
--
-- -----------------------------------------------------------------------------
-- El bloque _identificadores
-- -----------------------------------------------------------------------------
-- Cada actividad exportada lleva un bloque _identificadores con las PKs. No es
-- decorativo: resuelve el problema mas duro del importador. Los nombres NO
-- identifican nada en esta base --hay 3.591 asignaturas activas con solo 304
-- nombres distintos, unas 12 filas por nombre, porque la asignatura se acota
-- por area curricular-- asi que un archivo que solo trajera "Diseño" y "3o A"
-- obligaria a adivinar. Con las PKs, un archivo exportado por nosotros se
-- reimporta sin ambiguedad. El de un tercero seguira necesitando que el front
-- aporte asignatura y grupo por fuera del JSON.
--
-- -----------------------------------------------------------------------------
-- Diferencias deliberadas con el JSON de ejemplo que llego de negocio
-- -----------------------------------------------------------------------------
--   * duracion  -- el ejemplo trae texto libre ("20 horas", "3 sesiones",
--     "N/A") y la columna es DURACION_ESTIMADA NUMERIC. Se exporta el numero,
--     que es lo que hay; la unidad no esta guardada en ninguna parte y
--     inventarla al exportar seria mentir. El importador aceptara ambas formas.
--   * rubrica / escala -- en la base los niveles tienen ETIQUETA + DESCRIPCION
--     + PONDERACION; el ejemplo los llama "nombre" y "descriptor" y no lleva
--     ponderacion. Se exporta con los nombres del ejemplo y se AÑADE
--     ponderacion, que hace falta para poder reimportar sin perder el peso.
--   * evaluativa / genera_evidencias / requiere_validacion -- en la base son
--     el dominio bool_sn ('S'/'N'); se exportan como "Si"/"No" como el ejemplo.
--
-- -----------------------------------------------------------------------------
-- Filtros
-- -----------------------------------------------------------------------------
-- Hay que dar al menos uno, y se combinan con AND:
--   p_pk_tactividades  lista explicita
--   p_pk_tunidad       todas las de una unidad
--   p_fk_tasignatura   todas las de una asignatura
--   p_fk_tgrupo        todas las de un grupo
-- Sin ningun filtro lanza 22023 en vez de intentar exportar la base entera.
--
-- -----------------------------------------------------------------------------
-- Un array vacio no significa lo mismo segun como se pidio
-- -----------------------------------------------------------------------------
-- Devolver '[]' para todo lo que no encuentra nada obliga a quien llama a
-- adivinar cual de tres cosas distintas paso, y esa distincion solo existe
-- aqui. Asi que se separan:
--
--   p_pk_tactividades con elementos
--       CADA identificador nombrado tiene que resolver. El que no, se reporta
--       con su numero: pedir la actividad 42 y recibir una lista vacia no es
--       "no hay actividades", es que la 42 no esta donde el llamante cree.
--
--   p_pk_tactividades = '{}' (lista vacia)
--       es "no pediste nada", igual que no mandarla: 22023. Antes devolvia '[]'
--       en silencio, o sea el mismo caso con dos respuestas distintas.
--
--   solo p_pk_tunidad / p_fk_tasignatura / p_fk_tgrupo
--       '[]' SI es una respuesta legitima: esa unidad no tiene actividades, y
--       eso es un hecho, no un error. Aqui levantar seria incorrecto.
--
-- Nota sobre el alcance: el gate de fn_actividad_buscar_por_pk comprueba el
-- permiso del MENU (PLANEADOR/VER), no el establecimiento -- se verifico que un
-- usuario con ese permiso exporta actividades de otros EE. Asi que un
-- identificador que no resuelve es siempre "no existe, esta inactivo o los
-- otros filtros lo excluyen", nunca "no tienes permiso": eso ultimo rechaza la
-- llamada entera antes de mirar nada.
--
-- Idempotente: CREATE OR REPLACE.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_exportar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividades        BIGINT[] DEFAULT NULL,
    p_pk_tunidad             BIGINT   DEFAULT NULL,
    p_fk_tasignatura         BIGINT   DEFAULT NULL,
    p_fk_tgrupo              BIGINT   DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_pedidos   BIGINT[];  -- la lista explicita, ya sin el caso "vacia"
    v_faltan    BIGINT[];  -- los identificadores pedidos que no resolvieron
    v_ids       BIGINT[];
    v_pk        BIGINT;
    v_salida    JSONB := '[]'::JSONB;
    v_a         RECORD;   -- fila de fn_actividad_buscar_por_pk
    v_i         RECORD;   -- fila de fn_actividad_instrumento_obtener
    v_creado    TIMESTAMP;
    v_uni       RECORD;
    v_meta      JSONB;
    v_recursos  JSONB;
    v_adapt     JSONB;
    v_item      JSONB;
BEGIN
    -- -----------------------------------------------------------------
    -- 1. Al menos un filtro. Exportar "todo" no es un caso de uso: son
    --    decenas de miles de filas y ningun formulario lo pide.
    --
    --    Una lista VACIA no es un filtro: es "no pediste nada", y se
    --    trata igual que no mandarla. Antes '{}' se colaba como filtro
    --    valido que no casaba con ninguna fila, y la llamada respondia
    --    '[]' en vez del error.
    -- -----------------------------------------------------------------
    v_pedidos := CASE
                     WHEN COALESCE(ARRAY_LENGTH(p_pk_tactividades, 1), 0) = 0
                     THEN NULL
                     ELSE p_pk_tactividades
                 END;

    IF v_pedidos IS NULL
       AND p_pk_tunidad IS NULL
       AND p_fk_tasignatura IS NULL
       AND p_fk_tgrupo IS NULL THEN
        RAISE EXCEPTION 'Hay que indicar al menos un filtro para exportar'
            USING ERRCODE = '22023',
                  HINT    = 'Use p_pk_tactividades, p_pk_tunidad, p_fk_tasignatura o p_fk_tgrupo. '
                         || 'Una lista de identificadores vacia no cuenta como filtro';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Resolver que actividades entran. El gate NO se aplica aca: lo
    --    aplica fn_actividad_buscar_por_pk una por una, mas abajo.
    -- -----------------------------------------------------------------
    SELECT ARRAY_AGG(a.PK_TACTIVIDAD ORDER BY a.FK_TUNIDAD NULLS LAST, a.PK_TACTIVIDAD)
      INTO v_ids
      FROM academico_test.TACTIVIDAD a
     WHERE a.ACTIVE = TRUE
       AND (v_pedidos        IS NULL OR a.PK_TACTIVIDAD = ANY(v_pedidos))
       AND (p_pk_tunidad      IS NULL OR a.FK_TUNIDAD      = p_pk_tunidad)
       AND (p_fk_tasignatura  IS NULL OR a.FK_TASIGNATURA  = p_fk_tasignatura)
       AND (p_fk_tgrupo       IS NULL OR a.FK_TGRUPO       = p_fk_tgrupo);

    -- -----------------------------------------------------------------
    -- 2.b Si se pidieron identificadores concretos, TODOS tienen que
    --     haber resuelto. Se dice cuales no, con su numero: es la unica
    --     forma de que el llamante sepa que corregir.
    --
    --     Se incluye a proposito el caso "los otros filtros lo excluyen":
    --     los filtros se combinan con AND, asi que pedir la actividad 42
    --     junto con una unidad a la que no pertenece la deja fuera, y eso
    --     desde el otro lado se ve igual que si no existiera.
    -- -----------------------------------------------------------------
    IF v_pedidos IS NOT NULL THEN
        SELECT ARRAY_AGG(x ORDER BY x)
          INTO v_faltan
          FROM UNNEST(v_pedidos) AS x
         WHERE NOT (x = ANY(COALESCE(v_ids, ARRAY[]::BIGINT[])));

        IF v_faltan IS NOT NULL THEN
            RAISE EXCEPTION 'No se encontraron las actividades %',
                ARRAY_TO_STRING(v_faltan, ', ')
                USING ERRCODE = '22023',
                      HINT    = 'Cada identificador enviado tiene que existir y estar activo. '
                             || 'Si tambien se enviaron unidad, asignatura o grupo, recuerde que '
                             || 'los filtros se combinan con AND y pueden estar excluyendolas';
        END IF;
    END IF;

    -- Sin identificadores explicitos, un resultado vacio SI es una
    -- respuesta valida: esa unidad, asignatura o grupo no tiene
    -- actividades.
    IF v_ids IS NULL THEN
        RETURN '[]'::JSONB;
    END IF;

    FOREACH v_pk IN ARRAY v_ids
    LOOP
        -- Lectura completa, con su gate. Si el solicitante no tiene el
        -- permiso del menu, la funcion levanta en la PRIMERA actividad y la
        -- exportacion aborta entera: es lo correcto, no se devuelve media
        -- exportacion en silencio. Es un permiso de modulo, asi que o pasan
        -- todas o ninguna -- no filtra por establecimiento (ver la cabecera).
        SELECT * INTO v_a
          FROM academico_test.fn_actividad_buscar_por_pk(p_pk_usuario_solicitante, v_pk);

        IF v_a.pk_tactividad IS NULL THEN
            CONTINUE;
        END IF;

        SELECT a.CREATED_AT INTO v_creado
          FROM academico_test.TACTIVIDAD a
         WHERE a.PK_TACTIVIDAD = v_pk;

        -- -------------------------------------------------------------
        -- unidad_meta -- sale de unidad_configuracion, que ya viene en la
        -- lectura de la actividad. La descripcion de la unidad no esta
        -- ahi, asi que se lee aparte. Se mantiene como ARRAY porque asi
        -- llego el formato de negocio, aunque la columna sea un solo
        -- texto: cambiar la forma rompiria al consumidor.
        -- -------------------------------------------------------------
        v_meta := NULL;
        IF v_a.fk_tunidad IS NOT NULL THEN
            -- El nombre del grado no viene en unidad_configuracion, asi que
            -- se resuelve aca: la unidad es la que cuelga del grado.
            SELECT u.DESCRIPCION AS descripcion, u.NOMBRE AS nombre,
                   gr.NOMBRE AS grado
              INTO v_uni
              FROM academico_test.TUNIDAD u
              LEFT JOIN academico_test.TGRADO gr ON gr.PK_TGRADO = u.FK_TGRADO
             WHERE u.PK_TUNIDAD = v_a.fk_tunidad;

            v_meta := jsonb_build_object(
                'nombre',      COALESCE(v_a.unidad_configuracion->>'nombre', v_uni.nombre),
                'contenidos',  COALESCE((
                    SELECT jsonb_agg(x->>'descripcion' ORDER BY (x->>'orden')::NUMERIC)
                      FROM jsonb_array_elements(
                               COALESCE(v_a.unidad_configuracion->'contenidos', '[]'::JSONB)) x),
                    '[]'::JSONB),
                'objetivos',   COALESCE((
                    SELECT jsonb_agg(x->>'descripcion' ORDER BY (x->>'orden')::NUMERIC)
                      FROM jsonb_array_elements(
                               COALESCE(v_a.unidad_configuracion->'objetivos', '[]'::JSONB)) x),
                    '[]'::JSONB),
                'descripcion', CASE WHEN NULLIF(TRIM(COALESCE(v_uni.descripcion, '')), '') IS NULL
                                    THEN '[]'::JSONB
                                    ELSE jsonb_build_array(v_uni.descripcion) END);
        END IF;

        -- -------------------------------------------------------------
        -- recursos -- materiales de la actividad. tipoRecurso viene como
        -- FK; se traduce a la etiqueta "origen" del formato de negocio.
        -- -------------------------------------------------------------
        SELECT COALESCE(jsonb_agg(
                   jsonb_strip_nulls(jsonb_build_object(
                       'origen',      CASE lv.VALOR
                                          WHEN 'URL'         THEN 'url'
                                          WHEN 'ARCHIVO'     THEN 'archivo'
                                          WHEN 'REPOSITORIO' THEN 'unidad'
                                          ELSE LOWER(COALESCE(lv.VALOR, 'otro'))
                                      END,
                       'url',         m->>'url',
                       'fkTarchivo',  m->'fkTarchivo',
                       'descripcion', m->>'descripcion'))
                   ORDER BY (m->>'orden')::NUMERIC), '[]'::JSONB)
          INTO v_recursos
          FROM jsonb_array_elements(COALESCE(v_a.materiales, '[]'::JSONB)) m
          LEFT JOIN academico_test.TLISTA_VALOR lv
                 ON lv.PK_LISTA_VALOR = (m->>'tipoRecurso')::BIGINT;

        -- -------------------------------------------------------------
        -- adaptaciones -- fn_actividad_buscar_por_pk las devuelve con la
        -- forma de la base (tipoAdaptacion como FK, usaVersionModificada y
        -- formatoAdaptacion por separado). Aqui se pasan a la forma del
        -- formato de negocio, que junta la bandera y el formato en un solo
        -- "instrumento_modificado" y el destino en un solo "adjunto". Sin
        -- esta traduccion el archivo exportado NO se puede reimportar: el
        -- importador no reconoce las llaves de la base.
        --
        -- "estudiantes" son PKs de matricula, no nombres. Se dejan tal cual
        -- a proposito: son lo unico con lo que el importador puede volver a
        -- atar la adaptacion a alumnos concretos. Eso ata el archivo al
        -- grupo del que salio; para llevar la actividad a otro grupo hay que
        -- quitarlas y dejar la adaptacion en "grupo".
        -- -------------------------------------------------------------
        SELECT COALESCE(jsonb_agg(
                   jsonb_strip_nulls(jsonb_build_object(
                       'tipo',        BTRIM(COALESCE(ad->>'tipoAdaptacionNombre', ''),
                                            CHR(32) || CHR(9) || CHR(13) || CHR(10)),
                       'descripcion', ad->>'descripcion',
                       'instrumento_modificado',
                                      CASE WHEN ad->>'usaVersionModificada' <> 'S' THEN 'no'
                                           WHEN lfa.VALOR = 'ENLACE'               THEN 'si_url'
                                           ELSE 'si_file'   -- ARCHIVO y BIBLIOTECA
                                      END,
                       'adjunto',     COALESCE(ad->>'url', ad->>'fkTarchivo'),
                       'aplica',      CASE WHEN lap.VALOR = 'ESTUDIANTES_SELECCIONADOS'
                                           THEN 'especificos' ELSE 'grupo' END,
                       'estudiantes', CASE WHEN lap.VALOR = 'ESTUDIANTES_SELECCIONADOS'
                                           THEN ad->'estudiantes' END))
                   ORDER BY (ad->>'pk')::NUMERIC), '[]'::JSONB)
          INTO v_adapt
          FROM jsonb_array_elements(COALESCE(v_a.adaptaciones, '[]'::JSONB)) ad
          LEFT JOIN academico_test.TLISTA_VALOR lfa
                 ON lfa.PK_LISTA_VALOR = (ad->>'formatoAdaptacion')::BIGINT
          LEFT JOIN academico_test.TLISTA_VALOR lap
                 ON lap.PK_LISTA_VALOR = (ad->>'aplicaA')::BIGINT;

        -- -------------------------------------------------------------
        -- El cuerpo comun.
        -- -------------------------------------------------------------
        v_item := jsonb_build_object(
            'nombre',              v_a.titulo,
            -- BTRIM y no TRIM: TRIM en Postgres quita solo ESPACIOS, y varios
            -- NOMBRE de TLISTA_VALOR traen salto de linea al final -- el
            -- catalogo TIPO_ACTIVIDAD guarda literalmente 'Tarea' + LF. Sin
            -- esto el JSON sale con un salto de linea pegado y el importador
            -- no lo reconoceria.
            'tipo',                BTRIM(COALESCE(v_a.tipo_actividad, ''), CHR(32) || CHR(9) || CHR(13) || CHR(10)),
            'unidad',              v_a.unidad,
            'asignatura',          v_a.asignatura,
            -- grado y grupo van SEPARADOS a proposito. El ejemplo de negocio
            -- los junta en un solo "3o A", pero en la base son cosas
            -- distintas: el grado cuelga del periodo academico y el grupo del
            -- grado. Juntarlos haria imposible reimportar sin adivinar.
            'grado',               v_uni.grado,
            'grupo',               v_a.grupo,
            'unidad_meta',         v_meta,
            'fecha_inicio',        v_a.fecha_inicio,
            'fecha_entrega',       v_a.fecha_cierre,
            'duracion',            v_a.duracion_estimada,
            'semana',              v_a.semana_cronograma,
            'modalidad',           BTRIM(COALESCE(v_a.modalidad, ''), CHR(32) || CHR(9) || CHR(13) || CHR(10)),
            'evaluativa',          CASE WHEN v_a.es_evaluativa = 'S' THEN 'Si' ELSE 'No' END,
            'instrumento',         BTRIM(COALESCE(v_a.instrumento_evaluacion, ''), CHR(32) || CHR(9) || CHR(13) || CHR(10)),
            'ponderacion',         v_a.ponderacion,
            'descripcion',         v_a.descripcion,
            'materiales',          v_a.material_requerido,
            'recursos',            v_recursos,
            'adaptaciones',        v_adapt,
            'genera_evidencias',   CASE WHEN v_a.genera_evidencias = 'S' THEN 'Si' ELSE 'No' END,
            'tipo_evidencia',      BTRIM(COALESCE(v_a.tipo_evidencia, ''), CHR(32) || CHR(9) || CHR(13) || CHR(10)),
            'requiere_validacion', CASE WHEN v_a.requiere_validacion_coordinador = 'S' THEN 'Si' ELSE 'No' END,
            'observaciones',       v_a.observaciones_docente,
            'creado',              v_creado,
            -- Las PKs, para que un archivo nuestro se reimporte sin adivinar.
            '_identificadores',    jsonb_strip_nulls(jsonb_build_object(
                                       'pkTactividad',   v_a.pk_tactividad,
                                       'pkTunidad',      v_a.fk_tunidad,
                                       'fkTasignatura',  v_a.fk_tasignatura,
                                       'fkTgrupo',       v_a.fk_tgrupo,
                                       'fkTgrado',       academico_test.fn_actividad_grado_resolver(v_pk))));

        -- -------------------------------------------------------------
        -- El instrumento, si lo tiene. La definicion ya viene anidada de
        -- fn_actividad_instrumento_obtener; solo se renombra a las claves
        -- del formato de negocio ("nombre"/"descriptor" en vez de
        -- "etiqueta"/"descripcion") y se conserva la ponderacion, que el
        -- ejemplo no traia y hace falta para no perderla al reimportar.
        -- -------------------------------------------------------------
        IF v_a.fk_tlv_instrumento_evaluacion IS NOT NULL THEN
            SELECT * INTO v_i
              FROM academico_test.fn_actividad_instrumento_obtener(p_pk_usuario_solicitante, v_pk);

            IF v_i.instrumento = 'RUBRICA' THEN
                v_item := v_item || jsonb_build_object('rubrica', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                               'nombre',  cr->>'nombre',
                               'niveles', COALESCE((
                                   SELECT jsonb_agg(jsonb_build_object(
                                              'nombre',      ni->>'etiqueta',
                                              'descriptor',  ni->>'descripcion',
                                              'ponderacion', ni->'ponderacion'))
                                     FROM jsonb_array_elements(COALESCE(cr->'niveles', '[]'::JSONB)) ni),
                                   '[]'::JSONB))
                               ORDER BY (cr->>'orden')::NUMERIC)
                      FROM jsonb_array_elements(COALESCE(v_i.definicion, '[]'::JSONB)) cr),
                    '[]'::JSONB));

            ELSIF v_i.instrumento = 'LISTA_COTEJO' THEN
                -- El ejemplo trae el cotejo como lista de textos planos. Se
                -- respeta, y la ponderacion de cada item va aparte para no
                -- perderla: cotejo_detalle.
                v_item := v_item || jsonb_build_object(
                    'cotejo', COALESCE((
                        SELECT jsonb_agg(it->>'descripcion' ORDER BY (it->>'orden')::NUMERIC)
                          FROM jsonb_array_elements(COALESCE(v_i.definicion, '[]'::JSONB)) it),
                        '[]'::JSONB),
                    'cotejo_detalle', COALESCE(v_i.definicion, '[]'::JSONB));

            ELSIF v_i.instrumento = 'ESCALA_VALORACION' THEN
                v_item := v_item || jsonb_build_object('escala', jsonb_build_object(
                    -- definicion trae tipoEscala como FK a TLISTA_VALOR; el
                    -- formato de intercambio lleva la etiqueta legible.
                    'tipo',           (SELECT BTRIM(lv.NOMBRE, CHR(32) || CHR(9) || CHR(13) || CHR(10))
                                         FROM academico_test.TLISTA_VALOR lv
                                        WHERE lv.PK_LISTA_VALOR = (v_i.definicion->>'tipoEscala')::BIGINT),
                    'min',            v_i.definicion->'valorMin',
                    'max',            v_i.definicion->'valorMax',
                    'interpretacion', v_i.definicion->>'interpretacionRangos',
                    'criterios',      v_i.definicion->>'criteriosGenerales',
                    'niveles',        COALESCE((
                        SELECT jsonb_agg(jsonb_build_object(
                                   'nombre',      ni->>'etiqueta',
                                   'descriptor',  ni->>'descripcion',
                                   'ponderacion', ni->'ponderacion')
                                   ORDER BY (ni->>'orden')::NUMERIC)
                          FROM jsonb_array_elements(
                                   COALESCE(v_i.definicion->'niveles', '[]'::JSONB)) ni),
                        '[]'::JSONB)));

            ELSIF v_i.instrumento = 'OTRO' THEN
                v_item := v_item || jsonb_build_object('otro', COALESCE(v_i.definicion, '{}'::JSONB));
            END IF;
        END IF;

        v_salida := v_salida || jsonb_build_array(jsonb_strip_nulls(v_item));
    END LOOP;

    RETURN v_salida;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_actividad_exportar(BIGINT, BIGINT[], BIGINT, BIGINT, BIGINT)
    IS 'Exporta actividades del planeador al formato JSON de intercambio (el que lee el importador). Reensambla sobre fn_actividad_buscar_por_pk y fn_actividad_instrumento_obtener en vez de leer tablas, asi que el gate se aplica actividad por actividad. Filtros combinables por lista de PKs, unidad, asignatura o grupo; sin ninguno lanza 22023, y una lista de identificadores vacia cuenta como "sin filtro". Si se piden PKs concretas, las que no resuelvan se reportan por numero en vez de devolver un array vacio ambiguo; con solo unidad/asignatura/grupo, en cambio, el array vacio es una respuesta legitima. Cada actividad lleva un bloque _identificadores con las PKs para que un archivo exportado se reimporte sin resolver nombres (hay 3.591 asignaturas activas con 304 nombres distintos, asi que el nombre no identifica). Las adaptaciones se traducen a la forma del formato de negocio (usaVersionModificada + formatoAdaptacion se juntan en instrumento_modificado, y el destino en adjunto), sin lo cual el archivo exportado no se podria reimportar; "estudiantes" se deja como PKs de matricula, que es lo unico con lo que el importador puede volver a atar la adaptacion a alumnos concretos. V272.';
