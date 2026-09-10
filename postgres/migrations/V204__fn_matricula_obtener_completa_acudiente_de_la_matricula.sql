-- =============================================================================
-- V204 -- fn_matricula_obtener_completa: el acudiente de la matricula sale de
-- TMATRICULA.FK_TPADRE, no de la bandera del nucleo familiar.
--
-- Es la MISMA correccion que V270 hizo en fn_matricula_listar, en la funcion
-- del detalle. Se hicieron por separado porque el sintoma aparecio por
-- separado: primero el listado mostraba el acudiente equivocado, y ahora se
-- vio que el editar tambien -- y que los dos discrepaban entre si, que fue la
-- pista.
--
-- Va en migracion nueva y no editando V166, que es donde vive la funcion,
-- porque V166 YA esta aplicada y registrada en flyway_schema_history (28 de
-- agosto). Mismo motivo que V270 respecto de V200.
--
-- -----------------------------------------------------------------------------
-- El sintoma
-- -----------------------------------------------------------------------------
-- Se sustituye el acudiente de una matricula. El listado muestra al nuevo (V270
-- ya lo arreglo) pero la ficha de edicion sigue mostrando al anterior. Se
-- concluia que la sustitucion no habia funcionado, cuando si habia funcionado:
-- lo que fallaba era como el detalle elige a quien mostrar.
--
-- El front toma `acudientes.find(a => a.vinculo.acudiente === 'S') ?? [0]`, o
-- sea la bandera TNUCLEO_FAMILIAR.ACUDIENTE. Replicando esa logica exacta sobre
-- los datos reales: de 29.695 matriculas activas con FK_TPADRE, en **2.038
-- (6,9%)** elige a una persona distinta de la que la matricula tiene. Es
-- practicamente la misma poblacion que el bug del listado.
--
-- -----------------------------------------------------------------------------
-- Por que la bandera del nucleo NO puede responder esta pregunta
-- -----------------------------------------------------------------------------
-- No es que este mal poblada: es que es de OTRA granularidad.
--
-- TNUCLEO_FAMILIAR es por (padre, estudiante) -- el vinculo familiar, que no
-- cambia de un año a otro. TMATRICULA es por año. Un estudiante puede tener
-- varias matriculas con acudientes distintos, y de hecho las tiene: **602
-- estudiantes** tienen varias matriculas activas con FK_TPADRE distinto entre
-- ellas. Una bandera por vinculo no puede decir cual de esos es el acudiente de
-- UNA matricula concreta, porque la pregunta depende de la matricula.
--
-- Y ademas no discrimina: **657 estudiantes** tienen mas de un vinculo marcado
-- ACUDIENTE = 'S', con un maximo de **26** vinculos marcados para un mismo
-- estudiante. Toda la familia marcada como acudiente. El `.find('S')` del front
-- estaba eligiendo, en esos casos, esencialmente al azar (el primero por PK).
--
-- Por eso NO se corrige tocando la bandera. Se penso en que la sustitucion
-- (V177) pusiera 'N' en el vinculo del que sale, y seria un error: ese vinculo
-- es por estudiante y lo comparten las demas matriculas del mismo estudiante,
-- que pueden seguir teniendo a esa persona como acudiente. Una accion sobre una
-- matricula no debe reescribir el vinculo familiar -- justamente por eso la
-- sustitucion lo deja intacto, y esta bien que lo haga.
--
-- La unica fuente correcta es TMATRICULA.FK_TPADRE, que es por matricula.
--
-- -----------------------------------------------------------------------------
-- Y el acudiente de la matricula puede NO estar en el nucleo familiar
-- -----------------------------------------------------------------------------
-- Al medir el arreglo aparecio esto: en **777 matriculas activas** el FK_TPADRE
-- apunta a un padre que NO tiene ninguna fila de TNUCLEO_FAMILIAR con ese
-- estudiante. No es que el vinculo este inactivo -- esta AUSENTE (0 casos de
-- vinculo inactivo), y el TPADRE en si esta activo en las 777.
--
-- De esas, **382** son estudiantes SIN ningun vinculo activo: recorriendo solo
-- el nucleo, la lista de acudientes salia VACIA y el front no tenia a nadie que
-- mostrar. En las otras 395 mostraba a otro familiar.
--
-- Asi que no basta con marcar al correcto dentro del nucleo: hay que INCLUIRLO
-- aunque no este. La lista se arma como el nucleo activo MAS el acudiente de la
-- matricula si no aparece ahi. Su parentesco sale de
-- TMATRICULA.FK_TLV_ACUDIENTE_PARENTESCO, que existe justamente para esto, y el
-- vinculo se marca con sinVinculoFamiliar = true para que quien lea sepa que la
-- relacion familiar no esta registrada.
--
-- -----------------------------------------------------------------------------
-- Que cambia en la respuesta
-- -----------------------------------------------------------------------------
-- La lista `acudientes` sigue trayendo a TODO el nucleo familiar, que es
-- informacion legitima. Lo que cambia es como se identifica al de la matricula:
--
--   vinculo.acudiente                  -> DERIVADO: 'S' solo para el que
--                                         señala TMATRICULA.FK_TPADRE
--   vinculo.acudienteNucleo            -> el valor CRUDO de la columna, que se
--                                         conserva bajo un nombre honesto
--   vinculo.esAcudienteDeLaMatricula   -> el mismo hecho como booleano, para
--                                         quien lo quiera sin ambiguedad
--
-- y el de la matricula se ordena PRIMERO, asi que el `?? [0]` del front tambien
-- cae bien cuando ninguno esta marcado.
--
-- Se cambia el significado de `vinculo.acudiente` a proposito, en vez de solo
-- añadir el campo nuevo: es lo que hace que el front quede correcto SIN tocarlo
-- y sin migrar datos, y en un detalle DE UNA MATRICULA "es el acudiente" no
-- puede significar otra cosa. El valor de la columna no se pierde.
--
-- Idempotente: CREATE OR REPLACE.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_obtener_completa(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tmatricula          BIGINT
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
    v_fk_tpadre       BIGINT;
    v_fk_parentesco   BIGINT;
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

    -- Quien es el acudiente de ESTA matricula. Se lee de la tabla y no del
    -- JSON de arriba para no depender de que fn_matricula_obtener_por_id
    -- exponga la columna. El gate ya paso, asi que leerla es seguro.
    SELECT m.FK_TPADRE, m.FK_TLV_ACUDIENTE_PARENTESCO
      INTO v_fk_tpadre, v_fk_parentesco
      FROM academico_test.TMATRICULA m
     WHERE m.PK_TMATRICULA = p_pk_tmatricula;

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
    -- 4. Acudientes (0..N) -- se sigue recorriendo TNUCLEO_FAMILIAR,
    --    porque la lista es el nucleo familiar entero y eso es
    --    informacion legitima. Lo que NO sale de ahi es QUIEN es el
    --    acudiente de la matricula: eso lo dice FK_TPADRE.
    --
    --    La bandera del nucleo es por (padre, estudiante) y la matricula
    --    es por año, asi que no puede responderlo -- 602 estudiantes
    --    tienen varias matriculas con acudientes distintos, y 657 tienen
    --    mas de un vinculo marcado 'S' (hasta 26). Ver la cabecera.
    -- -----------------------------------------------------------------
    WITH vinculos AS (
        -- El nucleo familiar activo, tal cual.
        SELECT nf.FK_TPADRE, nf.PK_TNUCLEO_FAMILIAR, nf.FK_TLV_PARENTESCO,
               nf.ACUDIENTE, nf.ASISTE_REUNIONES, nf.ASISTE_INFORMES,
               nf.FK_TLV_TIPO_EMPLEO, nf.FK_TLV_FRECUENCIA_DOMICILIO,
               FALSE AS sin_vinculo
          FROM academico_test.TNUCLEO_FAMILIAR nf
         WHERE nf.FK_TESTUDIANTE = v_fk_testudiante
           AND nf.ACTIVE         = TRUE

        UNION ALL

        -- Y el acudiente de la matricula, si no aparece arriba. Sin esto la
        -- ficha mostraba a otro familiar, o a nadie -- 777 matriculas.
        SELECT v_fk_tpadre, NULL::BIGINT, v_fk_parentesco,
               NULL::VARCHAR, NULL::VARCHAR, NULL::VARCHAR,
               NULL::BIGINT, NULL::BIGINT,
               TRUE
         WHERE v_fk_tpadre IS NOT NULL
           AND NOT EXISTS (
               SELECT 1 FROM academico_test.TNUCLEO_FAMILIAR nf2
                WHERE nf2.FK_TESTUDIANTE = v_fk_testudiante
                  AND nf2.FK_TPADRE      = v_fk_tpadre
                  AND nf2.ACTIVE         = TRUE)
    )
    SELECT jsonb_agg(
               COALESCE(to_jsonb(pa), '{}'::JSONB) || jsonb_build_object(
                   'vinculo', jsonb_build_object(
                       'pkTnucleoFamiliar',        v.PK_TNUCLEO_FAMILIAR,
                       'fkTlvParentesco',          v.FK_TLV_PARENTESCO,
                       'parentescoNombre',         par.NOMBRE,
                       -- Derivado de FK_TPADRE, no copiado de la columna.
                       'acudiente',                CASE WHEN v.FK_TPADRE = v_fk_tpadre
                                                        THEN 'S' ELSE 'N' END,
                       -- El valor crudo, para no perderlo.
                       'acudienteNucleo',          v.ACUDIENTE,
                       'esAcudienteDeLaMatricula', (v.FK_TPADRE = v_fk_tpadre),
                       -- TRUE = es el acudiente de la matricula pero no tiene
                       -- fila de nucleo familiar con este estudiante.
                       'sinVinculoFamiliar',       v.sin_vinculo,
                       'asisteReuniones',          v.ASISTE_REUNIONES,
                       'asisteInformes',           v.ASISTE_INFORMES,
                       'fkTlvTipoEmpleo',          v.FK_TLV_TIPO_EMPLEO,
                       'tipoEmpleoNombre',         te.NOMBRE,
                       'fkTlvFrecuenciaDomicilio', v.FK_TLV_FRECUENCIA_DOMICILIO,
                       'frecuenciaDomicilioNombre', fd.NOMBRE
                   ))
               -- El de la matricula primero, para que un consumidor que
               -- tome el elemento [0] tambien acierte.
               ORDER BY (v.FK_TPADRE = v_fk_tpadre) DESC NULLS LAST,
                        v.PK_TNUCLEO_FAMILIAR NULLS LAST)
      INTO v_acudientes
      FROM vinculos v
      LEFT JOIN academico_test.TLISTA_VALOR par ON par.PK_LISTA_VALOR = v.FK_TLV_PARENTESCO
      LEFT JOIN academico_test.TLISTA_VALOR te  ON te.PK_LISTA_VALOR  = v.FK_TLV_TIPO_EMPLEO
      LEFT JOIN academico_test.TLISTA_VALOR fd  ON fd.PK_LISTA_VALOR  = v.FK_TLV_FRECUENCIA_DOMICILIO
      -- LEFT y no CROSS: si la lectura del padre no devuelve fila, antes la
      -- entrada DESAPARECIA de la lista en silencio. Perder al acudiente es
      -- peor que devolverlo con los datos de persona vacios.
      LEFT JOIN LATERAL academico_test.fn_padre_obtener_por_id(
                     p_pk_usuario_solicitante, v.FK_TPADRE) AS pa ON TRUE;

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

COMMENT ON FUNCTION academico_test.fn_matricula_obtener_completa(BIGINT, BIGINT)
    IS 'Ficha completa de una matricula: matricula + socioeconomico + estudiante + acudientes + archivos. El acudiente DE LA MATRICULA se identifica por TMATRICULA.FK_TPADRE, no por la bandera TNUCLEO_FAMILIAR.ACUDIENTE: esa bandera es por (padre, estudiante) y la matricula es por año, asi que no puede responder la pregunta -- 602 estudiantes tienen varias matriculas con acudientes distintos y 657 tienen mas de un vinculo marcado (hasta 26). Con la bandera, el detalle mostraba a otra persona en 2.038 de 29.695 matriculas activas (6,9%). vinculo.acudiente va DERIVADO de FK_TPADRE, el valor crudo se conserva en vinculo.acudienteNucleo, y el de la matricula se ordena primero. Ademas incluye al acudiente de la matricula aunque no tenga fila de TNUCLEO_FAMILIAR: en 777 matriculas activas el FK_TPADRE apunta a un padre sin vinculo registrado con ese estudiante, y en 382 de ellas la lista salia vacia. Esa entrada llega con sinVinculoFamiliar = true y el parentesco de TMATRICULA.FK_TLV_ACUDIENTE_PARENTESCO. Misma correccion que V270 hizo en fn_matricula_listar. V204.';
