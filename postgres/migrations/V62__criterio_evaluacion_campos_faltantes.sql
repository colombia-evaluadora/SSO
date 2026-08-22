-- ===========================================================================
-- V62 — TCRITERIO_EVALUACION: campos que faltaban de la pestaña "Criterios
-- de evaluación" del periodo académico, más dos bugs de wiring que salieron
-- a la luz al investigar por qué no estaban.
--
-- Contexto: los 10 campos de la pestaña y su especificación funcional
-- (valores posibles + detalle de negocio) vienen confirmados directamente
-- por quien conoce el dominio — no son una inferencia de esta migración a
-- partir del esquema. Cruzados contra TCRITERIO_EVALUACION (V22),
-- TPERIODO_ACADEMICO_CONFIG (V22) y el contenido real de TLISTA_VALOR en
-- el servidor de test:
--
--   1. Escala de valoración — Nacional (Superior/Alto/Básico/Bajo).
--      -> TCRITERIO_EVALUACION.FK_TESCALA (ya existe; la escala nacional
--         vive en TESCALA/TVALORACION, no en TLISTA_VALOR).
--   2. Formato de calificación — Cero a cinco / diez / cien.
--      -> FK_TLV_FORMATO_CALIFICACION / TLISTA_VALOR.FORMATO_CALIFICACION
--         (ya existe; "DE CERO A CINCO/DIEZ/CIEN" están las 3).
--   3. Sin calificaciones (desempeño sugerido) — Menor calificación
--      posible / Ninguna.
--      -> FK_TLV_DESEMPENO_SIN_CALIF / TLISTA_VALOR.DESEMPENIOSUGERIR
--         (ya existe, calce exacto con las 2 filas de la categoría).
--   4. Nota inicial para las calificaciones — rango numérico (0, 1, 10…):
--      límite inferior real de la escala institucional.
--      -> PORCENTAJE_INICIAL_CALIF (ya existe — valores reales en la
--         tabla hoy: 0,1,10,20,30,40, exactamente el rango descrito).
--   5. Nota máxima de recuperación — rango numérico (3.0, 4.0, 80…): tope
--      para que una nivelación no iguale la nota de quien aprobó de una.
--      -> NINGUNA columna en ninguna de las dos tablas ni categoría de
--         TLISTA_VALOR que calce (es un número libre, no un lookup) — se
--         agrega PORCENTAJE_MAXIMO_RECUPERACION.
--   6. Regla de redondeo — Hacia arriba / Hacia abajo / Al más cercano.
--      -> TPERIODO_ACADEMICO_CONFIG.FK_TLV_MODO_REDONDEAR / TLISTA_VALOR.
--         MODO_REDONDEAR (existe — "Hacia arriba", "Hacia Abajo",
--         "Depende del valor" ~ "al más cercano", + "No redondear" extra
--         — pero en la tabla EQUIVOCADA; se traslada acá).
--   7. Elementos para calcular la nota de la asignatura — Actividades /
--      Unidades (antes Logros o Descriptores).
--      -> FK_TLV_ELEMENTO_DEF / TLISTA_VALOR.ELEMENTO_CALCULO_DEF (ya
--         existe: "Actividades" calza exacto; "Descriptores de
--         desempeño" es el nombre viejo de "Unidades" — V62 renombra el
--         dato (ver seccion 1c abajo).
--   8. Criterio para calcular la nota de la asignatura — Promediar /
--      Ponderar / Sumatoria.
--      -> NINGUNA columna en ninguna de las dos tablas. Sus valores
--         calzan casi exacto con TLISTA_VALOR.TIPO_CALCULO ("Promediado",
--         "Ponderado", "Sumatoria", + "Nota Directa" extra) — NO con
--         CRITERIO_DESEMPENO como se pensó en un análisis previo de esta
--         misma migración (esa categoría tiene frases largas del tipo
--         "Promediar la calificación de las actividades", que no calzan
--         con el listado corto de 3 opciones de la especificación). Se
--         agrega FK_TLV_CRITERIO_ASIGNATURA apuntando conceptualmente a
--         TIPO_CALCULO — misma categoría que ya usa TACTIVIDAD.
--         FK_TLV_TIPO_CALCULO a nivel de actividad; reutilizarla a nivel
--         de periodo es consistente con el patrón del resto del esquema
--         (una categoría, varios consumidores en distintos scopes).
--   9. Criterio para calcular la nota del área — Promediar las
--      asignaturas / Ponderar las asignaturas / Según intensidad horaria.
--      -> FK_TLV_CRITERIO_AREA / TLISTA_VALOR.CRITERIO_AREA (ya existe,
--         calce con las 3 filas de la categoría).
--   10. Criterio para calcular la nota final — Promedio de períodos /
--       Ponderación de períodos.
--      -> FK_TLV_CRITERIO_FINAL / TLISTA_VALOR.CRITERIO_FINAL_PERACA (ya
--         existe, calce semántico con las 2 filas de la categoría).
--
-- Lo que NO se agrega acá, por falta de dato de respaldo (ni columna ni
-- categoría de TLISTA_VALOR que calce en ningún lugar del esquema, no hay
-- nada de donde partir sin adivinar semántica):
--   - "Número de desempeños que deben modificar los digitados" (de las
--     condiciones de aceptación, no aparece en la imagen) — no es lo
--     mismo que FK_TLV_MODIF_FINAL_PERACA (ver bug 1 abajo): esa columna
--     es SI/NO ("¿se puede modificar la nota final?"), no un conteo.
--
-- ---------------------------------------------------------------------------
-- Bug 1 — fn_criterio_eval_actualizar/obtener (V41): el parámetro
-- "subject_grade_criteria" ("criterio para calcular la nota de la
-- asignatura") en realidad lee/escribe FK_TLV_MODIF_FINAL_PERACA — la
-- columna SI/NO de "¿el digitador puede modificar la nota final del
-- periodo?", un concepto totalmente distinto (confirmado con datos reales:
-- esa columna sólo tiene valores SI/NO en TLISTA_VALOR). El nombre del
-- parámetro es correcto — apunta a donde el campo SIEMPRE debió estar,
-- sólo que esa columna nunca se creó.
--
-- Bug 2 — mismas funciones: el parámetro "rounding_mode" ("regla de
-- redondeo") en realidad lee/escribe NUMERO_DECIMALES — la CANTIDAD de
-- decimales a mostrar (comentario propio de V22: "Cantidad de decimales a
-- usar en las calificaciones"), no el MODO de redondear (hacia arriba /
-- hacia abajo / depende del valor / no redondear, que es lo que
-- MODO_REDONDEAR en TLISTA_VALOR realmente representa). Son dos conceptos
-- independientes que se conflaron en un solo parámetro porque el dato real
-- de redondeo vivía en la tabla equivocada (TPERIODO_ACADEMICO_CONFIG) y
-- esta función nunca la tocaba.
--
-- Ninguna fila del catálogo llama estas funciones por nombre de argumento
-- (confirmado: la fila 51, PUT /periodos/:ID/criterio-evaluacion, pasa los
-- 12 argumentos posicionalmente) — así que el fix se limita al CUERPO de
-- las funciones. Firma (orden, cantidad de parámetros existentes) sin
-- tocar; los parámetros nuevos van al final para no romper la llamada
-- posicional existente.
--
-- ADVERTENCIA — drift confirmado antes de escribir el fix: el archivo V41
-- (tal como vive en el repo) NO es lo que corre en el servidor de test.
-- fn_criterio_eval_obtener EN VIVO tiene un parámetro extra
-- (p_pk_usuario_solicitante, con gate de visibilidad
-- fn_periodo_usuario_puede_ver) y resuelve cada FK a su NOMBRE via LEFT
-- JOIN (columnas *_name) — ninguna de las dos cosas existe en el V41 del
-- repo. Confirmado con pg_get_functiondef contra el server antes de
-- escribir este CREATE OR REPLACE, para no pisar funcionalidad que el
-- archivo nunca reflejó (mismo patrón de drift que V42/V52/V53 —
-- ediciones post-aplicación nunca re-corridas). Este migration se basa en
-- la definición REAL, no en la del archivo.
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 1. Columnas nuevas en TCRITERIO_EVALUACION.
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- 1b. Comentarios de mapeo UI <-> columna <-> lista_valor para los 7 campos
--     restantes de la pestaña "Criterios de evaluacion" (imagen del periodo
--     academico). Estas columnas ya existian desde V22 y nunca habian sido
--     documentadas con el nombre exacto del campo de UI ni con la
--     categoria/valores de TLISTA_VALOR (o TESCALA) a la que corresponden;
--     se documentan aqui junto con las 3 nuevas de arriba para dejar los 10
--     campos de la pestaña cubiertos en un solo lugar.
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- 1c. Renombra el dato de TLISTA_VALOR pk_lista_valor=494 (categoria
--     ELEMENTO_CALCULO_DEF) de "Descriptores de desempeño" a "Unidades",
--     confirmado por quien conoce el negocio como el nombre vigente del
--     campo UI "Elementos para calcular la nota de la asignatura" (ver
--     item 7 arriba). Grep sobre el repo completo confirma que ningun
--     codigo de aplicacion referencia este NOMBRE como literal (todos los
--     consumidores pasan por PK_LISTA_VALOR=494), asi que renombrar el
--     dato no rompe wiring existente. WHERE por PK + NOMBRE viejo hace el
--     UPDATE idempotente (reintentar la migracion o correrla dos veces no
--     produce un doble renombre ni error).
-- ---------------------------------------------------------------------------

UPDATE academico_test.TLISTA_VALOR
   SET NOMBRE = 'Unidades',
       MODIFIED_BY = CURRENT_USER,
       MODIFIED_AT = CURRENT_TIMESTAMP
 WHERE PK_LISTA_VALOR = 494
   AND CATEGORIA = 'ELEMENTO_CALCULO_DEF'
   AND NOMBRE = 'Descriptores de desempeño';

-- ---------------------------------------------------------------------------
-- 2. Backfill: copiar el valor vigente de TPERIODO_ACADEMICO_CONFIG antes
--    de borrar la columna de origen. Relacion 1:1 via PK compartida con
--    TPERIODO_ACADEMICO (mismo patron que TCRITERIO_EVALUACION — ver V22,
--    ambas tablas tienen PK_x = PK_TPERIODO_ACADEMICO).
-- ---------------------------------------------------------------------------

UPDATE academico_test.TCRITERIO_EVALUACION ce
   SET FK_TLV_MODO_REDONDEAR = cfg.FK_TLV_MODO_REDONDEAR
  FROM academico_test.TPERIODO_ACADEMICO_CONFIG cfg
 WHERE cfg.PK_TPERIODO_ACADEMICO_CONFIG = ce.PK_TCRITERIO_EVALUACION
   AND cfg.FK_TLV_MODO_REDONDEAR IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 3. Traslado completo: la columna deja de existir en TPERIODO_ACADEMICO_CONFIG
--    (drop del indice + la FK antes de la columna, Postgres los arrastra con
--    CASCADE de todas formas al hacer DROP COLUMN, pero se listan explicitos
--    por trazabilidad con lo que V22 registro).
-- ---------------------------------------------------------------------------

DROP INDEX IF EXISTS academico_test.IDX_TPERIODO_ACADEMICO_CFG_21;

ALTER TABLE academico_test.TPERIODO_ACADEMICO_CONFIG
    DROP CONSTRAINT IF EXISTS FK_TPERIDO_ACADEMICO_CONFIG_14,
    DROP COLUMN IF EXISTS FK_TLV_MODO_REDONDEAR;

-- ---------------------------------------------------------------------------
-- 4. fn_criterio_eval_obtener — reconstruida sobre la definicion REAL (ver
--    advertencia de drift arriba), no sobre el V41 del repo. Se preserva:
--    el parametro p_pk_usuario_solicitante + el gate de visibilidad
--    fn_periodo_usuario_puede_ver, y el patron de resolver cada FK a su
--    NOMBRE via LEFT JOIN (columnas *_name). Se corrige el mapeo de
--    rounding_mode / subject_grade_criteria a las columnas reales (ahora
--    con su propio *_name, igual que el resto de lookups) y se agregan
--    decimal_places y final_grade_editable al final de RETURNS TABLE
--    (posicion nueva, no rompe "SELECT *" existente de la fila 50 del
--    catalogo).
--
--    Postgres rechaza CREATE OR REPLACE cuando cambia el RETURNS TABLE
--    (aunque los parametros de entrada sean identicos) — hay que DROP
--    primero, mismo patron ya usado en V52/V53 para el error analogo de
--    "cannot change name of input parameter". Se dropea tambien la firma
--    de 1 argumento del V41 del repo por si alguna instalacion la tiene
--    (nunca debio existir en el servidor de test, pero es gratis cubrirla).
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS academico_test.fn_criterio_eval_obtener(BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_criterio_eval_obtener(BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_eval_obtener(
    p_pk_periodo BIGINT, p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (
    academic_period_id BIGINT,
    grading_format BIGINT, grading_format_name VARCHAR,
    grading_scale BIGINT, grading_scale_name VARCHAR,
    period_calculation_elements BIGINT, period_calculation_elements_name VARCHAR,
    subject_grade_criteria BIGINT, subject_grade_criteria_name VARCHAR,
    final_grade_criteria BIGINT, final_grade_criteria_name VARCHAR,
    area_grade_criteria BIGINT, area_grade_criteria_name VARCHAR,
    student_without_grades_performance BIGINT, student_without_grades_performance_name VARCHAR,
    rounding_mode BIGINT, rounding_mode_name VARCHAR,
    initial_grade NUMERIC,
    decimal_places NUMERIC,
    final_grade_editable BIGINT, final_grade_editable_name VARCHAR,
    max_recovery_grade NUMERIC
)
LANGUAGE sql STABLE AS $$
    SELECT
        ce.PK_TCRITERIO_EVALUACION,

        ce.FK_TLV_FORMATO_CALIFICACION,
        formato.NOMBRE,

        ce.FK_TESCALA,
        escala.NOMBRE,

        ce.FK_TLV_ELEMENTO_DEF,
        elemento.NOMBRE,

        ce.FK_TLV_CRITERIO_ASIGNATURA,
        criterio_asignatura.NOMBRE,

        ce.FK_TLV_CRITERIO_FINAL,
        criterio_final.NOMBRE,

        ce.FK_TLV_CRITERIO_AREA,
        criterio_area.NOMBRE,

        ce.FK_TLV_DESEMPENO_SIN_CALIF,
        desempeno.NOMBRE,

        ce.FK_TLV_MODO_REDONDEAR,
        modo_redondear.NOMBRE,

        round(ce.PORCENTAJE_INICIAL_CALIF / 100
              * (CASE UPPER(TRIM(COALESCE(formato.NOMBRE, ''))) WHEN 'DE CERO A CINCO' THEN 5 WHEN 'DE CERO A DIEZ' THEN 10 ELSE 100 END), 2),

        ce.NUMERO_DECIMALES,

        ce.FK_TLV_MODIF_FINAL_PERACA,
        modif_final.NOMBRE,

        round(ce.PORCENTAJE_MAXIMO_RECUPERACION / 100
              * (CASE UPPER(TRIM(COALESCE(formato.NOMBRE, ''))) WHEN 'DE CERO A CINCO' THEN 5 WHEN 'DE CERO A DIEZ' THEN 10 ELSE 100 END), 2)

    FROM academico_test.TCRITERIO_EVALUACION ce

    LEFT JOIN academico_test.TLISTA_VALOR formato
        ON formato.PK_LISTA_VALOR = ce.FK_TLV_FORMATO_CALIFICACION

    LEFT JOIN academico_test.TESCALA escala
        ON escala.PK_TESCALA = ce.FK_TESCALA

    LEFT JOIN academico_test.TLISTA_VALOR elemento
        ON elemento.PK_LISTA_VALOR = ce.FK_TLV_ELEMENTO_DEF

    LEFT JOIN academico_test.TLISTA_VALOR criterio_asignatura
        ON criterio_asignatura.PK_LISTA_VALOR = ce.FK_TLV_CRITERIO_ASIGNATURA

    LEFT JOIN academico_test.TLISTA_VALOR criterio_final
        ON criterio_final.PK_LISTA_VALOR = ce.FK_TLV_CRITERIO_FINAL

    LEFT JOIN academico_test.TLISTA_VALOR criterio_area
        ON criterio_area.PK_LISTA_VALOR = ce.FK_TLV_CRITERIO_AREA

    LEFT JOIN academico_test.TLISTA_VALOR desempeno
        ON desempeno.PK_LISTA_VALOR = ce.FK_TLV_DESEMPENO_SIN_CALIF

    LEFT JOIN academico_test.TLISTA_VALOR modo_redondear
        ON modo_redondear.PK_LISTA_VALOR = ce.FK_TLV_MODO_REDONDEAR

    LEFT JOIN academico_test.TLISTA_VALOR modif_final
        ON modif_final.PK_LISTA_VALOR = ce.FK_TLV_MODIF_FINAL_PERACA

    WHERE ce.PK_TCRITERIO_EVALUACION = p_pk_periodo
      AND ce.ACTIVE = TRUE
      AND academico_test.fn_periodo_usuario_puede_ver(
          p_pk_usuario_solicitante,
          p_pk_periodo
      );
$$;

COMMENT ON FUNCTION academico_test.fn_criterio_eval_obtener(BIGINT, BIGINT) IS
    'V62: rounding_mode ahora lee FK_TLV_MODO_REDONDEAR (antes leia NUMERO_DECIMALES por error) y gana su propio rounding_mode_name, igual que el resto de lookups. subject_grade_criteria ahora lee la columna dedicada FK_TLV_CRITERIO_ASIGNATURA (antes leia FK_TLV_MODIF_FINAL_PERACA por error). initial_grade y max_recovery_grade ahora convierten PORCENTAJE_INICIAL_CALIF/PORCENTAJE_MAXIMO_RECUPERACION de vuelta al rango real del formato de calificacion (V22: "Porcentaje inicial del rango de calificaciones" -- la columna SIEMPRE fue un %, nunca el valor crudo; V41 jamas convirtio, bug heredado corregido aqui). Regla identica a V42 (fn_escala_guardar_bulk/fn_escala_listar: "las notas se guardan en % contra el formato del periodo"), pero comparando contra TLISTA_VALOR.NOMBRE en vez de VALOR -- V42 compara contra VALOR ("CINCO"/"DIEZ"/"CIEN", confirmado con datos reales), que nunca calza con los literales "DE CERO A CINCO"/"DE CERO A DIEZ" de su propio CASE, asi que su rango cae siempre al ELSE (100); no se replica ese bug aca. decimal_places y final_grade_editable son nuevos, exponen NUMERO_DECIMALES y FK_TLV_MODIF_FINAL_PERACA bajo su nombre real para no perder esa capacidad.';

-- ---------------------------------------------------------------------------
-- 5. fn_criterio_eval_actualizar — misma correccion en el UPDATE; tres
--    parametros nuevos al FINAL de la firma (p_decimal_places,
--    p_final_grade_editable, p_max_recovery_grade), DEFAULT NULL, para no
--    romper la llamada posicional de 12 argumentos que ya usa el catalogo
--    (fila 51). El parametro que en un borrador previo de esta migracion se
--    llamaba "p_max_recovery_grade" en la posicion 11 se renombro a
--    "p_initial_grade" (misma posicion, mismo COALESCE contra
--    PORCENTAJE_INICIAL_CALIF) porque se confirmo con la especificacion
--    funcional real que esa columna SI es la nota inicial. El nuevo
--    "p_max_recovery_grade" (posicion 15) es el que alimenta la columna
--    nueva PORCENTAJE_MAXIMO_RECUPERACION -- son dos parametros distintos,
--    no hay que confundirlos por compartir nombre con el borrador anterior.
--
--    Igual que con fn_criterio_eval_obtener: Postgres NO trata "agregar
--    parametros nuevos con DEFAULT al final" como un simple REPLACE — crea
--    un OVERLOAD nuevo y deja el de 12 argumentos intacto. Sin el DROP
--    explicito, la fila 51 del catalogo (que llama con exactamente 12
--    argumentos posicionales) seguiria resolviendo al overload VIEJO —
--    el fix no tendria ningun efecto en produccion pese a que la migracion
--    "corre limpia". Se dropea la firma vieja por su lista de tipos exacta.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS academico_test.fn_criterio_eval_actualizar(
    BIGINT, BIGINT, BIGINT, BOOLEAN, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, NUMERIC, NUMERIC, BIGINT
);

-- p_rounding_mode se queda NUMERIC (no BIGINT) a proposito, aunque ahora
-- alimenta un FK BIGINT: la fila 51 del catalogo lo declara
-- "BODY.ROUNDING_MODE": "NUMERIC" y hace CAST(:BODY.ROUNDING_MODE AS
-- NUMERIC) antes de pasarlo. Cambiar el tipo del parametro habria exigido
-- tocar esa fila tambien (fuera del alcance de esta migracion, que es
-- puramente de esquema/DDL+funciones); en vez de eso, el cast a BIGINT
-- pasa DENTRO del cuerpo, sobre el valor ya recibido.
CREATE OR REPLACE FUNCTION academico_test.fn_criterio_eval_actualizar(
    p_pk_periodo             BIGINT,
    p_grading_format         BIGINT DEFAULT NULL,
    p_grading_scale          BIGINT DEFAULT NULL,   -- nullable a proposito
    p_set_grading_scale      BOOLEAN DEFAULT FALSE, -- TRUE = aplicar p_grading_scale (incl. NULL)
    p_period_calc_elements   BIGINT DEFAULT NULL,
    p_subject_grade_criteria BIGINT DEFAULT NULL,
    p_final_grade_criteria   BIGINT DEFAULT NULL,
    p_area_grade_criteria    BIGINT DEFAULT NULL,
    p_student_wo_grades      BIGINT DEFAULT NULL,
    p_rounding_mode          NUMERIC DEFAULT NULL,
    p_initial_grade          NUMERIC DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL,
    p_decimal_places         NUMERIC DEFAULT NULL,
    p_final_grade_editable   BIGINT DEFAULT NULL,
    p_max_recovery_grade     NUMERIC DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_escala_actual BIGINT;
    v_fmt_nombre TEXT; v_max NUMERIC;
BEGIN
    -- Alcance por rol (como V37): grueso + fino (el criterio comparte PK con el
    -- periodo, asi que el establecimiento sale de p_pk_periodo).
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, academico_test.fn_periodo_establecimiento(p_pk_periodo));
    -- Rango real del formato de calificacion VIGENTE TRAS este UPDATE (el
    -- nuevo si se manda p_grading_format, si no el que ya tenia el
    -- periodo) -- para convertir p_initial_grade / p_max_recovery_grade a
    -- porcentaje antes de guardar (V22: PORCENTAJE_INICIAL_CALIF es
    -- "Porcentaje inicial del rango de calificaciones", nunca el valor
    -- crudo; V42: "las notas se guardan en % (0-100) contra el formato
    -- del periodo; la lectura convierte de vuelta"). Compara contra
    -- TLISTA_VALOR.NOMBRE, NO contra VALOR: V42 (fn_escala_guardar_bulk)
    -- compara contra VALOR, pero esa columna guarda "CINCO"/"DIEZ"/"CIEN"
    -- (confirmado con datos reales), nunca "DE CERO A CINCO"/"DE CERO A
    -- DIEZ" -- su CASE nunca matchea y cae siempre al ELSE (100). NOMBRE
    -- si contiene el texto completo; no se replica ese bug aca.
    SELECT lv.NOMBRE INTO v_fmt_nombre
      FROM academico_test.TLISTA_VALOR lv
     WHERE lv.PK_LISTA_VALOR = COALESCE(p_grading_format, (
         SELECT FK_TLV_FORMATO_CALIFICACION FROM academico_test.TCRITERIO_EVALUACION
          WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo AND ACTIVE = TRUE
     ));
    v_max := CASE UPPER(TRIM(COALESCE(v_fmt_nombre, '')))
                WHEN 'DE CERO A CINCO' THEN 5
                WHEN 'DE CERO A DIEZ'  THEN 10
                ELSE 100
              END;
    -- FK_TESCALA solo cambia si p_set_grading_scale = TRUE (permite ponerla o
    -- limpiarla explicitamente); en FALSE no se toca. El resto es COALESCE.
    -- Si se va a asignar una escala no nula, debe existir y estar activa.
    IF p_set_grading_scale AND p_grading_scale IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM academico_test.TESCALA WHERE PK_TESCALA = p_grading_scale AND ACTIVE = TRUE
        ) THEN
            RAISE EXCEPTION 'La escala de valoracion % no existe o esta inactiva', p_grading_scale USING ERRCODE = '23503';
        END IF;
        -- La escala maestra debe pertenecer al periodo (estar ligada via TNIVEL_ESCALA).
        IF NOT EXISTS (
            SELECT 1 FROM academico_test.TNIVEL_ESCALA
             WHERE FK_TESCALA = p_grading_scale AND FK_PERIODO_ACADEMICO = p_pk_periodo AND ACTIVE = TRUE
        ) THEN
            RAISE EXCEPTION 'La escala % no pertenece al periodo academico %', p_grading_scale, p_pk_periodo
                USING ERRCODE = '22023';
        END IF;
    END IF;
    -- Escala maestra actual (para decidir si hay que propagar).
    SELECT FK_TESCALA INTO v_escala_actual
      FROM academico_test.TCRITERIO_EVALUACION
     WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo AND ACTIVE = TRUE;
    UPDATE academico_test.TCRITERIO_EVALUACION SET
        FK_TLV_FORMATO_CALIFICACION = COALESCE(p_grading_format, FK_TLV_FORMATO_CALIFICACION),
        FK_TESCALA                  = CASE WHEN p_set_grading_scale THEN p_grading_scale ELSE FK_TESCALA END,
        FK_TLV_ELEMENTO_DEF         = COALESCE(p_period_calc_elements, FK_TLV_ELEMENTO_DEF),
        FK_TLV_CRITERIO_ASIGNATURA  = COALESCE(p_subject_grade_criteria, FK_TLV_CRITERIO_ASIGNATURA),
        FK_TLV_CRITERIO_FINAL       = COALESCE(p_final_grade_criteria, FK_TLV_CRITERIO_FINAL),
        FK_TLV_CRITERIO_AREA        = COALESCE(p_area_grade_criteria, FK_TLV_CRITERIO_AREA),
        FK_TLV_DESEMPENO_SIN_CALIF  = COALESCE(p_student_wo_grades, FK_TLV_DESEMPENO_SIN_CALIF),
        FK_TLV_MODO_REDONDEAR       = COALESCE(p_rounding_mode::BIGINT, FK_TLV_MODO_REDONDEAR),
        PORCENTAJE_INICIAL_CALIF    = COALESCE(p_initial_grade / v_max * 100, PORCENTAJE_INICIAL_CALIF),
        NUMERO_DECIMALES            = COALESCE(p_decimal_places, NUMERO_DECIMALES),
        FK_TLV_MODIF_FINAL_PERACA   = COALESCE(p_final_grade_editable, FK_TLV_MODIF_FINAL_PERACA),
        PORCENTAJE_MAXIMO_RECUPERACION = COALESCE(p_max_recovery_grade / v_max * 100, PORCENTAJE_MAXIMO_RECUPERACION),
        MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'No existe criterio de evaluacion activo para el periodo %', p_pk_periodo
            USING ERRCODE = 'P0002';
    END IF;

    -- Solo al ELEGIR una escala maestra distinta a la actual se propaga a las
    -- demas escalas del periodo. Guardar otros campos (o re-guardar la misma
    -- escala) no vuelve a pisar las personalizaciones de las otras escalas.
    IF p_set_grading_scale AND p_grading_scale IS NOT NULL
       AND p_grading_scale IS DISTINCT FROM v_escala_actual THEN
        PERFORM academico_test.fn_escala_propagar(p_pk_periodo, p_grading_scale, v_audit);
    END IF;

    RETURN p_pk_periodo;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_criterio_eval_actualizar(
    BIGINT, BIGINT, BIGINT, BOOLEAN, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, NUMERIC, NUMERIC, BIGINT, NUMERIC, BIGINT, NUMERIC
) IS
    'V62: corrige el wiring de p_rounding_mode (antes escribia NUMERO_DECIMALES; ahora FK_TLV_MODO_REDONDEAR, columna trasladada desde TPERIODO_ACADEMICO_CONFIG) y de p_subject_grade_criteria (antes escribia FK_TLV_MODIF_FINAL_PERACA; ahora la columna dedicada FK_TLV_CRITERIO_ASIGNATURA). p_initial_grade y p_max_recovery_grade ahora se convierten a porcentaje (v_max = 5/10/100 segun el formato de calificacion vigente tras el UPDATE) antes de guardarse en PORCENTAJE_INICIAL_CALIF/PORCENTAJE_MAXIMO_RECUPERACION, en vez de escribir el valor crudo (bug heredado de V41, que jamas convirtio pese a que V22 documenta la columna como "Porcentaje inicial del rango de calificaciones"; ver comentario en el cuerpo de la funcion para el detalle del bug analogo en V42 que se evito no replicar). p_decimal_places y p_final_grade_editable son nuevos, exponen NUMERO_DECIMALES y FK_TLV_MODIF_FINAL_PERACA -- todos al final de la firma para no romper la llamada posicional del catalogo (fila 51).';
