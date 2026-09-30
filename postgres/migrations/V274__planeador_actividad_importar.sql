-- ===========================================================================
-- V274 - Helpers de la importacion de actividades del Planeador:
--   fn_planeador_etiqueta_a_lv (etiqueta -> TLISTA_VALOR) y fn_planeador_sn.
--
--   fn_actividad_importar nacio aqui; la vigente es la de V340 y su COMMENT
--   esta en V516.
-- ===========================================================================


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
