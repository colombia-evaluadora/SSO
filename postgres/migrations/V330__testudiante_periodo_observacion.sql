-- ===========================================================================
-- V330 - TESTUDIANTE_PERIODO_OBSERVACION: el comentario de seguimiento que
--        redacta la IA para un estudiante en un periodo, y que el docente
--        aprueba o corrige al guardarlo.
--
-- EL GRANO ES (MATRICULA, PERIODO DE EVALUACION). NO INTERVIENE LA ASIGNATURA
--   Es la definicion del negocio para preescolar: la IA lee TODAS las
--   observaciones que el docente dejo por actividad en el periodo -- sin
--   importar de que dimension venga cada una -- y produce UN texto de
--   seguimiento del estudiante.
--
--   Por eso no hay FK_TASIGNATURA. Una version anterior de esta tabla la
--   tenia, por simetria con TASIGNATURA_NOTA, y por eso se llamaba
--   TASIGNATURA_NOTA_OBSERVACION; al confirmarse que el resumen es del
--   estudiante y no de la dimension, esa simetria dejo de existir y el nombre
--   con ella.
--
--   Nota sobre el nombre: dice ESTUDIANTE pero la FK es a TMATRICULA. Es
--   deliberado y es como el esquema ya lo hace (TASIGNATURA_NOTA tambien
--   apunta a TMATRICULA): la matricula es lo que ata a un estudiante con un
--   grupo y un ano concretos, y sin ella "el estudiante en el primer periodo"
--   seria ambiguo para quien repite o cambia de sede.
--
-- POR QUE NO ES TRECOMENDACIONES_CALIFICACION
--   Esa tabla existe desde V22 con un grano parecido (FK_TMATRICULA +
--   FK_TPERIODO_EVALUACION + RECOMENDACION TEXT) y CERO filas. Se descarto
--   reutilizarla porque le falta lo esencial de este flujo: conservar el
--   texto ORIGINAL de la IA aparte del que se muestra, y el estado de
--   revision. Eso son columnas nuevas sobre una tabla de otro proposito.
--
-- SOLO DOS ESTADOS: APROBADA Y MODIFICADA
--   No hay PENDIENTE. No existe el momento "la IA ya escribio pero nadie
--   reviso", porque la generacion NO PERSISTE: el usuario pide el texto, lo
--   ve, y recien al GUARDARLO nace la fila. Si lo guarda tal cual queda
--   APROBADA; si lo edito, MODIFICADA.
--
--   Una fila en esta tabla es, por definicion, un texto que un humano ya
--   acepto. Eso es lo que la hace publicable en un boletin sin mas preguntas.
--
-- LAS DOS COLUMNAS DE TEXTO
--   OBSERVACION_IA  el borrador que produjo la IA. Se escribe al guardar y no
--                   se toca nunca mas.
--   OBSERVACION     lo que se muestra. Igual al anterior si se aprobo tal
--                   cual, distinto si se corrigio.
--
--   Tenerlas separadas permite responder "esto lo escribio la IA o lo
--   reescribio el docente?" comparando, sin llevar historial. El estado es
--   el atajo a esa misma pregunta.
--
-- REGENERAR REEMPLAZA
--   Pedir de nuevo el texto a la IA y guardarlo PISA la fila anterior. No se
--   conserva la version vieja: la unica verdad es lo que el docente acepto
--   por ultima vez. Por eso el indice unico es total sobre (matricula,
--   periodo) y no parcial sobre ACTIVE -- no hay versiones conviviendo.
--
-- Idempotente: DROP de la tabla anterior (nunca tuvo filas), CREATE TABLE IF
-- NOT EXISTS, y el catalogo con guarda por NOT EXISTS mas la baja explicita
-- de PENDIENTE si quedo de una ejecucion previa.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 0. La version anterior de esta tabla, si existe.
--
--    Solo llego a existir en el servidor de pruebas y siempre con 0 filas, de
--    modo que no hay dato que migrar. Se elimina en vez de renombrar +
--    ALTER porque cambian el nombre, el grano, una columna y un indice: un
--    CREATE limpio se lee mejor que cuatro ALTER encadenados.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS academico_test.TASIGNATURA_NOTA_OBSERVACION;


-- ---------------------------------------------------------------------------
-- 1. Catalogo de estados.
--
--    PK_LISTA_VALOR no es IDENTITY en TLISTA_VALOR (se siembra con PKs
--    explicitas desde V22), asi que se toma el siguiente libre con MAX+1.
-- ---------------------------------------------------------------------------
INSERT INTO academico_test.TLISTA_VALOR
    (PK_LISTA_VALOR, CATEGORIA, NOMBRE, VALOR, CREATED_BY, CREATED_AT, ACTIVE)
SELECT (SELECT COALESCE(MAX(PK_LISTA_VALOR), 0) FROM academico_test.TLISTA_VALOR)
           + ROW_NUMBER() OVER (ORDER BY v.orden),
       'ESTADO_OBSERVACION_IA',
       v.nombre,
       v.valor,
       'V330',
       CURRENT_TIMESTAMP,
       TRUE
  FROM (VALUES
            (1, 'APROBADA',   'Aprobada por el docente'),
            (2, 'MODIFICADA', 'Modificada por el docente')
       ) AS v(orden, valor, nombre)
 WHERE NOT EXISTS (
           SELECT 1 FROM academico_test.TLISTA_VALOR lv
            WHERE lv.CATEGORIA = 'ESTADO_OBSERVACION_IA'
              AND lv.VALOR     = v.valor
       );

-- PENDIENTE existio en una version anterior de esta migracion. Se da de baja
-- en vez de borrarse: es un valor de catalogo y borrarlo podria romper una FK
-- si alguna fila llego a apuntarlo.
UPDATE academico_test.TLISTA_VALOR
   SET ACTIVE      = FALSE,
       MODIFIED_BY = 'V330',
       MODIFIED_AT = CURRENT_TIMESTAMP
 WHERE CATEGORIA = 'ESTADO_OBSERVACION_IA'
   AND VALOR     = 'PENDIENTE'
   AND ACTIVE    = TRUE;


-- ---------------------------------------------------------------------------
-- 2. La tabla.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS academico_test.TESTUDIANTE_PERIODO_OBSERVACION (
    PK_TESTUDIANTE_PERIODO_OBSERVACION BIGINT GENERATED BY DEFAULT AS IDENTITY,

    FK_TMATRICULA              BIGINT    NOT NULL,
    FK_TPERIODO_EVALUACION     BIGINT    NOT NULL,
    FK_TLV_ESTADO_OBSERVACION  BIGINT    NOT NULL,

    -- Lo que se muestra en el boletin.
    OBSERVACION                TEXT      NOT NULL,
    -- El borrador original de la IA. Se escribe una vez y queda fijo.
    OBSERVACION_IA             TEXT      NOT NULL,

    -- Cuantas TACTIVIDAD_NOTA.OBSERVACION se resumieron. No es estadistica:
    -- es lo que permite detectar despues que el docente dejo observaciones
    -- nuevas y el resumen quedo viejo.
    OBSERVACIONES_ORIGEN       NUMERIC,

    CREATED_BY                 VARCHAR(50) NOT NULL,
    CREATED_AT                 TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    MODIFIED_BY                VARCHAR(50),
    MODIFIED_AT                TIMESTAMP,
    ACTIVE                     BOOLEAN     NOT NULL DEFAULT TRUE,

    CONSTRAINT PK_TESTUDIANTE_PERIODO_OBSERVACION
        PRIMARY KEY (PK_TESTUDIANTE_PERIODO_OBSERVACION),
    CONSTRAINT FK_TESTUDIANTE_PERIODO_OBSERVACION_1
        FOREIGN KEY (FK_TMATRICULA)
        REFERENCES academico_test.TMATRICULA (PK_TMATRICULA),
    CONSTRAINT FK_TESTUDIANTE_PERIODO_OBSERVACION_2
        FOREIGN KEY (FK_TPERIODO_EVALUACION)
        REFERENCES academico_test.TPERIODO_EVALUACION (PK_TPERIODO_EVALUACION),
    CONSTRAINT FK_TESTUDIANTE_PERIODO_OBSERVACION_3
        FOREIGN KEY (FK_TLV_ESTADO_OBSERVACION)
        REFERENCES academico_test.TLISTA_VALOR (PK_LISTA_VALOR)
);


-- ---------------------------------------------------------------------------
-- 3. Indices.
--
--    El unico es TOTAL, no parcial sobre ACTIVE: regenerar REEMPLAZA, no
--    versiona, asi que nunca conviven dos filas para el mismo estudiante y
--    periodo. Es la diferencia con TASIGNATURA_NOTA, cuyo unico si es
--    parcial.
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS IDX_TESTUDIANTE_PERIODO_OBSERVACION_1
    ON academico_test.TESTUDIANTE_PERIODO_OBSERVACION (FK_TMATRICULA);
CREATE INDEX IF NOT EXISTS IDX_TESTUDIANTE_PERIODO_OBSERVACION_2
    ON academico_test.TESTUDIANTE_PERIODO_OBSERVACION (FK_TPERIODO_EVALUACION);
CREATE INDEX IF NOT EXISTS IDX_TESTUDIANTE_PERIODO_OBSERVACION_3
    ON academico_test.TESTUDIANTE_PERIODO_OBSERVACION (FK_TLV_ESTADO_OBSERVACION);

CREATE UNIQUE INDEX IF NOT EXISTS U_TESTUDIANTE_PERIODO_OBSERVACION_1
    ON academico_test.TESTUDIANTE_PERIODO_OBSERVACION
       (FK_TMATRICULA, FK_TPERIODO_EVALUACION);


-- ---------------------------------------------------------------------------
-- 4. Documentacion.
-- ---------------------------------------------------------------------------
COMMENT ON TABLE academico_test.TESTUDIANTE_PERIODO_OBSERVACION
    IS 'Comentario de seguimiento de UN estudiante en UN periodo de evaluacion, redactado por la IA a partir de todas las TACTIVIDAD_NOTA.OBSERVACION que el docente dejo en ese periodo, y aprobado o corregido por el docente al guardarlo. EL GRANO NO INCLUYE LA ASIGNATURA: en preescolar la IA lee todas las observaciones del periodo sin importar de que dimension vengan y produce un unico texto del estudiante; una version previa de esta tabla si tenia FK_TASIGNATURA, por simetria con TASIGNATURA_NOTA, y se llamaba TASIGNATURA_NOTA_OBSERVACION, pero al confirmarse que el resumen es del estudiante esa simetria y ese nombre dejaron de tener sentido. El nombre dice ESTUDIANTE aunque la FK sea a TMATRICULA, igual que TASIGNATURA_NOTA: la matricula es lo que ata al estudiante con un grupo y un ano concretos. SOLO DOS ESTADOS, APROBADA y MODIFICADA: no hay PENDIENTE porque la generacion NO PERSISTE -- el usuario pide el texto, lo ve, y la fila nace recien al guardarlo, de modo que toda fila aqui es por definicion un texto que un humano ya acepto, y por eso es publicable en un boletin sin mas preguntas. Guarda dos textos: OBSERVACION_IA es el borrador original, se escribe al guardar y no se toca nunca mas; OBSERVACION es lo que se muestra. Comparandolos se responde si lo reescribio el docente, sin historial. Regenerar REEMPLAZA la fila anterior -- la unica verdad es lo que el docente acepto por ultima vez -- y por eso el indice unico es total sobre (matricula, periodo) y no parcial sobre ACTIVE: nunca conviven dos versiones. No se guarda quien lo genero: la tabla es exclusivamente para lo que produce la IA, asi que esa columna tendria un solo valor posible.';

COMMENT ON COLUMN academico_test.TESTUDIANTE_PERIODO_OBSERVACION.PK_TESTUDIANTE_PERIODO_OBSERVACION
    IS 'Llave primaria de la tabla';
COMMENT ON COLUMN academico_test.TESTUDIANTE_PERIODO_OBSERVACION.FK_TMATRICULA
    IS 'Llave foranea a tabla TMATRICULA: el estudiante en su grupo y ano concretos';
COMMENT ON COLUMN academico_test.TESTUDIANTE_PERIODO_OBSERVACION.FK_TPERIODO_EVALUACION
    IS 'Llave foranea a tabla TPERIODO_EVALUACION: el periodo que resume la observacion';
COMMENT ON COLUMN academico_test.TESTUDIANTE_PERIODO_OBSERVACION.FK_TLV_ESTADO_OBSERVACION
    IS 'Llave foranea de lista valor para obtener ESTADO_OBSERVACION_IA (APROBADA / MODIFICADA). No existe PENDIENTE: la fila nace recien cuando un humano acepta el texto';
COMMENT ON COLUMN academico_test.TESTUDIANTE_PERIODO_OBSERVACION.OBSERVACION
    IS 'El texto que se muestra en el boletin: igual a OBSERVACION_IA si se aprobo tal cual, distinto si el docente lo corrigio';
COMMENT ON COLUMN academico_test.TESTUDIANTE_PERIODO_OBSERVACION.OBSERVACION_IA
    IS 'El borrador original de la IA. Se escribe al guardar y queda fijo, para poder comparar contra OBSERVACION y saber si hubo edicion';
COMMENT ON COLUMN academico_test.TESTUDIANTE_PERIODO_OBSERVACION.OBSERVACIONES_ORIGEN
    IS 'Cuantas TACTIVIDAD_NOTA.OBSERVACION se resumieron para producir el texto. Permite detectar despues que el docente dejo observaciones nuevas y el resumen quedo viejo';
