-- V559.1 — Verificación del boletín por QR, capa 3 de 4: núcleos sin gate.
--
-- Qué hace: código aleatorio, huella de los datos del boletín por estudiante,
-- registro de una emisión (reemplaza la VIGENTE anterior o reutiliza su código
-- si la huella no cambió), consulta por código y revocación.
-- Depende de: V559 (tabla), V540/V541 (núcleos de los boletines),
-- V536 (fn_informe_grupo_listar_interno).

-- 18 bytes aleatorios en base64url (24 caracteres): 122 bits de un UUID v4 más
-- 16 de otro = 138 bits. gen_random_uuid es nativo; pgcrypto no está en todas
-- las bases.
CREATE OR REPLACE FUNCTION academico_test.fn_boletin_emision_codigo_nuevo()
RETURNS VARCHAR
LANGUAGE sql
VOLATILE
AS $function$
    SELECT translate(
               encode(decode(replace(gen_random_uuid()::TEXT, '-', '')
                             || left(replace(gen_random_uuid()::TEXT, '-', ''), 4), 'hex'),
                      'base64'),
               '+/', '-_')::VARCHAR;
$function$;

COMMENT ON FUNCTION academico_test.fn_boletin_emision_codigo_nuevo()
    IS 'INTERNO: codigo nuevo de emision de boletin, 24 caracteres base64url con 138 bits aleatorios (dos gen_random_uuid). No enumerable: no deriva de ningun id.';

CREATE OR REPLACE FUNCTION academico_test.fn_boletin_huella_interno(
    p_fk_tgrupo              BIGINT,
    p_fk_tperiodo_evaluacion BIGINT,
    p_nivel                  VARCHAR,
    p_fk_tmatriculas         BIGINT[] DEFAULT NULL
)
RETURNS TABLE(fk_tmatricula bigint, clave character varying, documento character varying,
              estudiante character varying, huella character varying)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    -- Fuera de la huella: encabezado, firmantes, imagenes y lo que depende de
    -- los demas estudiantes (puesto, total). Dentro: notas, desempeños, logros,
    -- observacion, comportamientos, inasistencias y evidencias.
    v_fuera CONSTANT TEXT[] := ARRAY[
        'ee_nombre', 'ee_dane', 'ee_nit', 'ciudad', 'departamento', 'sede_nombre',
        'nivel_ensenanza', 'grado_nombre', 'grupo_etiqueta', 'jornada', 'anio',
        'periodo_nombre', 'fondo_archivo', 'escudo_archivo', 'foto_archivo',
        'puesto', 'total_estudiantes', 'rector_nombre', 'rector_documento',
        'director_nombre', 'director_documento', 'auxiliar_nombre', 'auxiliar_documento',
        'docentes', 'intensidad', 'influencia', 'tipo_documento', 'observacion_estado',
        'matricula'];
BEGIN
    IF lower(TRIM(p_nivel)) = 'preescolar' THEN
        -- Sus filas no traen la matricula: se resuelve con el mismo listado
        -- del que salen, por documento y nombre (la clave de la plantilla).
        RETURN QUERY
        WITH filas AS (
            SELECT COALESCE(b.documento, '') || '|' || COALESCE(b.estudiante, '') AS k,
                   b.documento AS doc, b.estudiante AS nom,
                   (to_jsonb(b) - v_fuera)::TEXT AS f
              FROM academico_test.fn_informe_boletin_preescolar_interno(
                       p_fk_tgrupo, p_fk_tperiodo_evaluacion, p_fk_tmatriculas) b
        ),
        mats AS (
            SELECT l.k, MIN(l.mat) AS mat
              FROM (SELECT COALESCE(g.documento, '') || '|' || COALESCE(g.estudiante, '') AS k,
                           g.fk_tmatricula AS mat
                      FROM academico_test.fn_informe_grupo_listar_interno(
                               p_fk_tgrupo, ARRAY[p_fk_tperiodo_evaluacion], NULL) g) l
             GROUP BY l.k
        )
        SELECT m.mat, f.k::VARCHAR, MIN(f.doc)::VARCHAR, MIN(f.nom)::VARCHAR,
               encode(sha256(convert_to(string_agg(f.f, E'\n' ORDER BY f.f), 'UTF8')), 'hex')::VARCHAR
          FROM filas f
          JOIN mats m ON m.k = f.k
         GROUP BY m.mat, f.k;
    ELSE
        RETURN QUERY
        WITH filas AS (
            SELECT b.matricula AS mat, b.documento AS doc, b.estudiante AS nom,
                   (to_jsonb(b) - v_fuera)::TEXT AS f
              FROM academico_test.fn_informe_boletin_notas_interno(
                       p_fk_tgrupo, p_fk_tperiodo_evaluacion, p_fk_tmatriculas) b
        )
        SELECT f.mat, f.mat::VARCHAR, MIN(f.doc)::VARCHAR, MIN(f.nom)::VARCHAR,
               encode(sha256(convert_to(string_agg(f.f, E'\n' ORDER BY f.f), 'UTF8')), 'hex')::VARCHAR
          FROM filas f
         GROUP BY f.mat;
    END IF;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_boletin_huella_interno(BIGINT, BIGINT, VARCHAR, BIGINT[])
    IS 'INTERNO: huella sha-256 (hex) de los datos del boletin de cada estudiante: filas del nucleo del nivel como jsonb (orden de claves canonico), sin encabezado, firmantes, imagenes, puesto ni total, ordenadas y unidas. CLAVE es la de la plantilla (matricula, o documento|estudiante en preescolar). La misma regla al emitir y al verificar: datos iguales, misma huella. Sin gate.';

CREATE OR REPLACE FUNCTION academico_test.fn_boletin_emision_registrar_interno(
    p_actor                  VARCHAR,
    p_fk_tmatricula          BIGINT,
    p_fk_tperiodo_evaluacion BIGINT,
    p_nivel                  VARCHAR,
    p_huella                 VARCHAR
)
RETURNS VARCHAR
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    v_previa  academico_test.TBOLETIN_EMISION%ROWTYPE;
    v_pk      BIGINT;
    v_codigo  VARCHAR;
BEGIN
    -- FOR UPDATE: dos impresiones simultaneas del mismo boletin se serializan
    -- aqui en vez de chocar contra UX_TBOLETIN_EMISION_VIGENTE.
    SELECT * INTO v_previa
      FROM academico_test.TBOLETIN_EMISION e
     WHERE e.FK_TMATRICULA = p_fk_tmatricula
       AND e.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
       AND e.ESTADO = 'VIGENTE'
     FOR UPDATE;

    -- Reimprimir lo mismo no invalida los QR ya entregados.
    IF FOUND AND v_previa.HUELLA = p_huella AND v_previa.NIVEL = p_nivel THEN
        RETURN v_previa.CODIGO;
    END IF;

    IF FOUND THEN
        UPDATE academico_test.TBOLETIN_EMISION
           SET ESTADO = 'REEMPLAZADA', MODIFIED_BY = p_actor, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TBOLETIN_EMISION = v_previa.PK_TBOLETIN_EMISION;
    END IF;

    v_codigo := academico_test.fn_boletin_emision_codigo_nuevo();
    INSERT INTO academico_test.TBOLETIN_EMISION (
        CODIGO, FK_TMATRICULA, FK_TPERIODO_EVALUACION, NIVEL, HUELLA, CREATED_BY)
    VALUES (v_codigo, p_fk_tmatricula, p_fk_tperiodo_evaluacion, p_nivel, p_huella, p_actor)
    RETURNING PK_TBOLETIN_EMISION INTO v_pk;

    IF v_previa.PK_TBOLETIN_EMISION IS NOT NULL THEN
        UPDATE academico_test.TBOLETIN_EMISION
           SET REEMPLAZADA_POR = v_pk
         WHERE PK_TBOLETIN_EMISION = v_previa.PK_TBOLETIN_EMISION;
    END IF;

    RETURN v_codigo;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_boletin_emision_registrar_interno(VARCHAR, BIGINT, BIGINT, VARCHAR, VARCHAR)
    IS 'INTERNO: registra la emision del boletin de una matricula en un periodo y devuelve su CODIGO. Si ya hay una VIGENTE con la misma huella y nivel devuelve ese codigo (reimprimir no invalida QR entregados); si la huella cambio la marca REEMPLAZADA, enlazada por REEMPLAZADA_POR a la nueva. Sin gate: lo aplica fn_boletin_emision_registrar.';

CREATE OR REPLACE FUNCTION academico_test.fn_boletin_emision_consultar_interno(
    p_codigo VARCHAR
)
RETURNS TABLE(pk_tboletin_emision bigint, codigo character varying, fk_tmatricula bigint,
              fk_tperiodo_evaluacion bigint, fk_tgrupo bigint, nivel character varying,
              huella character varying, estado character varying,
              emitido_en timestamp, reemplazada_en timestamp,
              pk_ee bigint, pk_sede bigint,
              institucion character varying, sede character varying,
              periodo character varying, anio integer, estudiante character varying)
LANGUAGE sql
STABLE
AS $function$
    SELECT e.PK_TBOLETIN_EMISION, e.CODIGO, e.FK_TMATRICULA, e.FK_TPERIODO_EVALUACION,
           m.FK_TGRUPO, e.NIVEL, e.HUELLA::VARCHAR, e.ESTADO, e.CREATED_AT, nueva.CREATED_AT,
           c.pk_ee, c.pk_sede, c.ee_nombre, c.sede_nombre, pe.NOMBRE::VARCHAR, c.anio,
           NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                      u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)), '')::VARCHAR
      FROM academico_test.TBOLETIN_EMISION e
      JOIN academico_test.TMATRICULA m ON m.PK_TMATRICULA = e.FK_TMATRICULA
      JOIN academico_test.TPERIODO_EVALUACION pe
        ON pe.PK_TPERIODO_EVALUACION = e.FK_TPERIODO_EVALUACION
      LEFT JOIN academico_test.TBOLETIN_EMISION nueva
             ON nueva.PK_TBOLETIN_EMISION = e.REEMPLAZADA_POR
      LEFT JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
      LEFT JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = es.FK_TUSUARIO
      LEFT JOIN LATERAL academico_test.fn_informe_boletin_cabecera_interno(m.FK_TGRUPO) c ON TRUE
     WHERE e.CODIGO = p_codigo;
$function$;

COMMENT ON FUNCTION academico_test.fn_boletin_emision_consultar_interno(VARCHAR)
    IS 'INTERNO: la emision de boletin de un CODIGO: matricula, periodo, grupo actual de la matricula, nivel, huella, estado, fecha de emision y la de la que la reemplazo, establecimiento, sede, periodo, año y nombre del estudiante (este solo para la revocacion autenticada; la lectura publica no lo expone). Sin gate.';

CREATE OR REPLACE FUNCTION academico_test.fn_boletin_emision_revocar_interno(
    p_actor               VARCHAR,
    p_pk_tboletin_emision BIGINT,
    p_motivo              VARCHAR
)
RETURNS VOID
LANGUAGE sql
VOLATILE
AS $function$
    UPDATE academico_test.TBOLETIN_EMISION
       SET ESTADO = 'REVOCADA', REVOCADA_POR = p_actor, REVOCADA_AT = CURRENT_TIMESTAMP,
           MOTIVO = NULLIF(TRIM(p_motivo), ''),
           MODIFIED_BY = p_actor, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TBOLETIN_EMISION = p_pk_tboletin_emision;
$function$;

COMMENT ON FUNCTION academico_test.fn_boletin_emision_revocar_interno(VARCHAR, BIGINT, VARCHAR)
    IS 'INTERNO: marca REVOCADA una emision de boletin con quien, cuando y el motivo. Al verificar, una revocada responde igual que un codigo inexistente. Sin gate: lo aplica fn_boletin_emision_revocar.';
