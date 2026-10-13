-- ===========================================================================
-- V41 - Modulo de criterios de evaluacion: columnas y catalogos de
-- TCRITERIO_EVALUACION y backfill de FK_TLV_MODO_REDONDEAR (no-op si la
-- columna de origen ya no existe). Las funciones del modulo viven en
-- V41.2 (validaciones) / V41.3 (nucleos) / V41.4 (wrappers).
-- ===========================================================================


SET search_path TO academico_test, public;

ALTER TABLE academico_test.TCRITERIO_EVALUACION
    ADD COLUMN IF NOT EXISTS FK_TLV_MODO_REDONDEAR BIGINT
        REFERENCES academico_test.TLISTA_VALOR (PK_LISTA_VALOR),
    ADD COLUMN IF NOT EXISTS FK_TLV_CRITERIO_ASIGNATURA BIGINT
        REFERENCES academico_test.TLISTA_VALOR (PK_LISTA_VALOR),
    ADD COLUMN IF NOT EXISTS PORCENTAJE_MAXIMO_RECUPERACION NUMERIC(5,2);

CREATE INDEX IF NOT EXISTS IDX_TCRITERIO_EVALUACION_MODO_REDONDEAR
    ON academico_test.TCRITERIO_EVALUACION (FK_TLV_MODO_REDONDEAR);

CREATE INDEX IF NOT EXISTS IDX_TCRITERIO_EVALUACION_CRITERIO_ASIGNATURA
    ON academico_test.TCRITERIO_EVALUACION (FK_TLV_CRITERIO_ASIGNATURA);

COMMENT ON COLUMN academico_test.TCRITERIO_EVALUACION.FK_TLV_MODO_REDONDEAR IS
    'Campo UI "Regla de redondeo" (imagen, columna 3 fila 2). Llave foranea de lista valor, categoria MODO_REDONDEAR: "Hacia arriba" / "Hacia Abajo" / "Depende del valor" (~ "Al mas cercano") / "No redondear" (extra, sin campo UI). Trasladada desde TPERIODO_ACADEMICO_CONFIG (V62) — vivia en la tabla equivocada; fn_criterio_eval_actualizar/obtener (V41) la exponen como "criterios de evaluacion" del periodo, no TPERIODO_ACADEMICO_CONFIG.';

COMMENT ON COLUMN academico_test.TCRITERIO_EVALUACION.FK_TLV_CRITERIO_ASIGNATURA IS
    'Campo UI "Criterio para calcular la nota de la asignatura" (imagen, columna 2 fila 3). Llave foranea de lista valor, categoria TIPO_CALCULO: "Promediado" / "Ponderado" / "Sumatoria" / "Nota Directa" (extra, sin campo UI) — misma categoria que TACTIVIDAD.FK_TLV_TIPO_CALCULO usa a nivel de actividad, reutilizada aqui a nivel de periodo. fn_criterio_eval_actualizar (V41) ya tenia un parametro "subject_grade_criteria" pensado para esto, pero escribia por error FK_TLV_MODIF_FINAL_PERACA (un SI/NO no relacionado).';

COMMENT ON COLUMN academico_test.TCRITERIO_EVALUACION.PORCENTAJE_MAXIMO_RECUPERACION IS
    'Campo UI "Nota maxima de recuperacion" (imagen, columna 2 fila 2). Tope para que una actividad de nivelacion no iguale la nota de quien aprobo de una. Numero libre, sin lookup de TLISTA_VALOR (no existe categoria que calce con este concepto en todo el esquema).';

COMMENT ON COLUMN academico_test.TCRITERIO_EVALUACION.FK_TESCALA IS
    'Campo UI "Escala de valoracion" (imagen, columna 1 fila 1). Llave foranea a TESCALA — NO a TLISTA_VALOR. Verificado contra el servidor de test: no existe una fila unica "Escala Nacional" en TESCALA (22 escalas, todas institucionales: "ESCALA DE VALORACION INSTITUCIONAL", "DECRETO 1290...", etc.) — el concepto de "escala nacional" es el marco legal (Superior/Alto/Basico/Bajo, Decreto 1290), no una fila del catalogo; TVALORACION tiene 27 filas con nombres tipo Superior/Alto/Basico/Bajo repartidas entre distintas TESCALA institucionales, cada institucion las nombra/codifica a su manera (ej. pk_tvaloracion 158-165, 218-223, 336-339). El vinculo TESCALA<->periodo pasa por TNIVEL_ESCALA (fk_tescala + fk_periodo_academico), no hay columna fk_tescala directa en TVALORACION.';

COMMENT ON COLUMN academico_test.TCRITERIO_EVALUACION.FK_TLV_FORMATO_CALIFICACION IS
    'Campo UI "Formato de calificacion" (imagen, columna 2 fila 1). Llave foranea de lista valor, categoria FORMATO_CALIFICACION. Verificado contra el servidor de test: 6 filas activas, no 3 — "DE CERO A CINCO" (51857), "DE CERO A DIEZ" (51882), "DE CERO A CIEN" (51889) calzan con la especificacion; la categoria tiene ademas "Simbolos" (51861), "Valoraciones" (51893) y "Caritas" (51914), formatos no numericos fuera del alcance de la especificacion de esta pestaña (probablemente usados en otra UI, no en "Criterios de evaluacion").';

COMMENT ON COLUMN academico_test.TCRITERIO_EVALUACION.FK_TLV_DESEMPENO_SIN_CALIF IS
    'Campo UI "Sin calificaciones" (imagen, columna 3 fila 1). Llave foranea de lista valor, categoria DESEMPENIOSUGERIR. Verificado contra el servidor de test, texto exacto: "Menor calificación posible" (521) / "Ninguna Calificación" (522) — nota que asume el sistema si un docente deja una actividad o asignatura sin calificar.';

COMMENT ON COLUMN academico_test.TCRITERIO_EVALUACION.PORCENTAJE_INICIAL_CALIF IS
    'Campo UI "Nota inicial para las calificaciones" (imagen, columna 1 fila 2). Numero libre, sin lookup de TLISTA_VALOR — limite inferior real de la escala institucional (ej. 0, 1, 10); valores reales observados en la tabla: 0,1,10,20,30,40.';

COMMENT ON COLUMN academico_test.TCRITERIO_EVALUACION.FK_TLV_ELEMENTO_DEF IS
    'Campo UI "Elementos para calcular la nota de la asignatura" (imagen, columna 1 fila 3). Llave foranea de lista valor, categoria ELEMENTO_CALCULO_DEF: "Actividades" (495) / "Unidades" (494, renombrada por V62 desde "Descriptores de desempeño" — ver seccion 1c).';

COMMENT ON COLUMN academico_test.TCRITERIO_EVALUACION.FK_TLV_CRITERIO_AREA IS
    'Campo UI "Criterio para calcular la nota del area" (imagen, columna 3 fila 3). Llave foranea de lista valor, categoria CRITERIO_AREA. Verificado contra el servidor de test, texto exacto (distinto de la redaccion de la especificacion funcional, mismo significado): "Promediar las Asignaturas" (510, ~"Promediar las asignaturas") / "Cada asignatura tiene un porcentaje" (508, ~"Ponderar las asignaturas") / "Proporcional a la intensidad horaria" (509, ~"De acuerdo a la intensidad horaria").';

COMMENT ON COLUMN academico_test.TCRITERIO_EVALUACION.FK_TLV_CRITERIO_FINAL IS
    'Campo UI "Criterio para calcular la nota final" (imagen, columna 1 fila 4). Llave foranea de lista valor, categoria CRITERIO_FINAL_PERACA. Verificado contra el servidor de test, texto exacto (distinto de la redaccion de la especificacion funcional, mismo significado): "Equitativamente de acuerdo al número de PE" (501, ~"Promedio de periodos") / "De acuerdo al porcentaje de cada PE" (502, ~"Ponderacion de periodos"). PE = Periodo de Evaluacion.';

UPDATE academico_test.TLISTA_VALOR
   SET NOMBRE = 'Unidades',
       MODIFIED_BY = CURRENT_USER,
       MODIFIED_AT = CURRENT_TIMESTAMP
 WHERE PK_LISTA_VALOR = 494
   AND CATEGORIA = 'ELEMENTO_CALCULO_DEF'
   AND NOMBRE = 'Descriptores de desempeño';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM information_schema.columns
         WHERE table_schema = 'academico_test'
           AND table_name   = 'tperiodo_academico_config'
           AND column_name  = 'fk_tlv_modo_redondear'
    ) THEN
        RETURN;
    END IF;

    UPDATE academico_test.TCRITERIO_EVALUACION ce
       SET FK_TLV_MODO_REDONDEAR = cfg.FK_TLV_MODO_REDONDEAR
      FROM academico_test.TPERIODO_ACADEMICO_CONFIG cfg
     WHERE cfg.PK_TPERIODO_ACADEMICO_CONFIG = ce.PK_TCRITERIO_EVALUACION
       AND cfg.FK_TLV_MODO_REDONDEAR IS NOT NULL
       AND ce.FK_TLV_MODO_REDONDEAR IS NULL;

    EXECUTE 'DROP INDEX IF EXISTS academico_test.IDX_TPERIODO_ACADEMICO_CFG_21';
    EXECUTE 'ALTER TABLE academico_test.TPERIODO_ACADEMICO_CONFIG
                DROP CONSTRAINT IF EXISTS FK_TPERIDO_ACADEMICO_CONFIG_14,
                DROP COLUMN IF EXISTS FK_TLV_MODO_REDONDEAR';
END $$;
